Param(
    [hashtable]$parameters
)

$bcContainerHelperConfig.usePsSession = $false

$databaseServer   = 'host.containerhelper.internal'
$databaseInstance = ''
$databaseName     = 'CRONUS'
$snapshotName     = 'CRONUS_snapshot'
$databaseUsername = 'bc-docker-devops'
$databasePassword = '1234'
$backupPath       = 'C:\ProgramData\BcContainerHelper\temp\mydatabase'
$hashFile         = "$backupPath.restore_hash"
$dataLogicalName  = 'Navision_NAV_DE_Data'
$logLogicalName   = 'Navision_NAV_DE_Log'
$mdfTarget        = 'C:\Program Files\Microsoft SQL Server\MSSQL16.MSSQLSERVER\MSSQL\DATA\Navision_NAV_DE_FullApplication.mdf'
$ldfTarget        = 'C:\Program Files\Microsoft SQL Server\MSSQL16.MSSQLSERVER\MSSQL\DATA\Navision_NAV_DE_FullApplication.ldf'
$snapshotFile     = 'C:\Program Files\Microsoft SQL Server\MSSQL16.MSSQLSERVER\MSSQL\DATA\CRONUS_snapshot.ss'

$databaseSecurePassword = ConvertTo-SecureString -String $databasePassword -AsPlainText -Force
$databaseCredential     = New-Object pscredential $databaseUsername, $databaseSecurePassword
$connectionString       = "Server=localhost;Database=master;User Id=$databaseUsername;Password=$databasePassword;"
$persistentContainerName = 'bcDEpersistent'

# Determine whether a valid snapshot exists for the current backup
$currentHash = (Get-FileHash -Path $backupPath -Algorithm MD5).Hash
$storedHash  = if (Test-Path $hashFile) { (Get-Content $hashFile -Raw).Trim() } else { '' }

$snapshotExistsResult = Invoke-Sqlcmd -ConnectionString $connectionString `
    -Query "SELECT CAST(CASE WHEN DB_ID(N'$snapshotName') IS NOT NULL THEN 1 ELSE 0 END AS BIT) AS SnapshotExists" `
    -QueryTimeout 30
$snapshotExists = [bool]$snapshotExistsResult.SnapshotExists

# Build the restore script (shared by both the container-reuse and fresh-container paths)
if ($currentHash -eq $storedHash -and $snapshotExists) {
    Write-Host "Restoring database from snapshot '$snapshotName' (fast path) ..."
    $restoreScript = @"
DECLARE @terminate NVARCHAR(MAX) = N'';
SELECT @terminate = @terminate + 'KILL ' + CAST(session_id AS NVARCHAR(10)) + ';'
FROM sys.dm_exec_sessions
WHERE database_id = DB_ID(N'$databaseName');
EXEC(@terminate);

RESTORE DATABASE [$databaseName] FROM DATABASE_SNAPSHOT = N'$snapshotName';

ALTER DATABASE [$databaseName] SET RECOVERY SIMPLE, MULTI_USER;
"@
} else {
    Write-Host "Restoring database from backup (full restore) ..."
    $restoreScript = @"
DECLARE @terminate NVARCHAR(MAX) = N'';
SELECT @terminate = @terminate + 'KILL ' + CAST(session_id AS NVARCHAR(10)) + ';'
FROM sys.dm_exec_sessions
WHERE database_id = DB_ID(N'$databaseName') OR database_id = DB_ID(N'$snapshotName');
EXEC(@terminate);

IF DB_ID(N'$snapshotName') IS NOT NULL DROP DATABASE [$snapshotName];
IF DB_ID(N'$databaseName') IS NOT NULL DROP DATABASE [$databaseName];

RESTORE DATABASE [$databaseName]
FROM DISK = N'$backupPath'
WITH REPLACE,
    MOVE N'$dataLogicalName' TO N'$mdfTarget',
    MOVE N'$logLogicalName'  TO N'$ldfTarget';

ALTER DATABASE [$databaseName] SET RECOVERY SIMPLE, MULTI_USER;
"@
}

$snapshotScript = @"
IF DB_ID(N'$snapshotName') IS NOT NULL DROP DATABASE [$snapshotName];
CREATE DATABASE [$snapshotName] ON
    (NAME = N'$dataLogicalName', FILENAME = N'$snapshotFile')
AS SNAPSHOT OF [$databaseName];
"@

function Ensure-ReusedContainerServices {
    Param(
        [string]$containerName
    )

    # Reused containers can come back with SQL Server stopped; start it before BC service tier.
    Invoke-ScriptInBcContainer -containerName $containerName -scriptblock {
        $sql = Get-Service 'MSSQL$SQLEXPRESS' -ErrorAction SilentlyContinue
        if ($null -ne $sql -and $sql.Status -ne 'Running') {
            Write-Host "Starting SQL service MSSQL`$SQLEXPRESS in reused container..."
            Start-Service 'MSSQL$SQLEXPRESS'
            $sql.WaitForStatus('Running', [TimeSpan]::FromMinutes(2))
        }
    }
}

function Ensure-BcServiceRunningWithRecovery {
    Param(
        [string]$containerName
    )

    $alreadyRunning = Invoke-ScriptInBcContainer -containerName $containerName -scriptblock {
        (Get-Service 'MicrosoftDynamicsNavServer$BC').Status -eq 'Running'
    }
    if ([bool]$alreadyRunning) {
        Write-Host "BC service tier is already running - no restart needed."
        return
    }

    $lastErrorMessage = ''
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        try {
            Write-Host "Starting BC service tier (attempt $attempt)..."
            Invoke-ScriptInBcContainer -containerName $containerName -scriptblock {
                $bc = Get-Service 'MicrosoftDynamicsNavServer$BC'
                if ($bc.Status -ne 'Running') {
                    Start-Service 'MicrosoftDynamicsNavServer$BC'
                    $bc.WaitForStatus('Running', [TimeSpan]::FromMinutes(2))
                }
            }

            $serviceRunning = Invoke-ScriptInBcContainer -containerName $containerName -scriptblock {
                (Get-Service 'MicrosoftDynamicsNavServer$BC').Status -eq 'Running'
            }
            if ([bool]$serviceRunning) {
                return
            }

            $lastErrorMessage = 'BC service tier is not running after restart.'
        }
        catch {
            $lastErrorMessage = $_.Exception.Message
        }

        if ($attempt -lt 2) {
            Write-Host "BC service start failed, retrying after SQL service recovery..."
            Ensure-ReusedContainerServices -containerName $containerName
        }
    }

    throw $lastErrorMessage
}

function Ensure-TenantReadyForPublish {
    Param(
        [string]$containerName
    )

    Invoke-ScriptInBcContainer -containerName $containerName -scriptblock {
        $serverInstance = 'BC'
        $tenantId = 'default'

        if (-not (Get-Command Get-NAVTenant -ErrorAction SilentlyContinue)) {
            Write-Host 'Get-NAVTenant is not available in this container, skipping tenant state validation.'
            return
        }

        for ($attempt = 1; $attempt -le 3; $attempt++) {
            $tenant = Get-NAVTenant -ServerInstance $serverInstance -Tenant $tenantId -ErrorAction Stop
            Write-Host "Current tenant state (attempt $attempt): $($tenant.State)"

            if ($tenant.State -eq 'Operational') {
                Write-Host 'Tenant state is Operational.'
                return
            }

            if ($tenant.State -eq 'OperationalWithSyncPending') {
                if ($attempt -eq 1) {
                    Write-Host 'Tenant is OperationalWithSyncPending. Trying Sync-NAVTenant -Mode Sync...'
                    try {
                        Sync-NAVTenant -ServerInstance $serverInstance -Tenant $tenantId -Mode Sync -Force -ErrorAction Stop
                    }
                    catch {
                        Write-Host 'Sync mode failed, retrying with -Mode ForceSync...'
                        Sync-NAVTenant -ServerInstance $serverInstance -Tenant $tenantId -Mode ForceSync -Force -ErrorAction Stop
                    }
                }
                elseif ($attempt -eq 2) {
                    Write-Host 'Tenant still sync pending. Restarting BC service tier once and retrying...'
                    $bc = Get-Service 'MicrosoftDynamicsNavServer$BC' -ErrorAction Stop
                    if ($bc.Status -eq 'Running') {
                        Restart-Service 'MicrosoftDynamicsNavServer$BC' -Force -ErrorAction Stop
                    }
                    else {
                        Start-Service 'MicrosoftDynamicsNavServer$BC' -ErrorAction Stop
                    }
                    $bc.WaitForStatus('Running', [TimeSpan]::FromMinutes(2))
                }
                else {
                    Write-Host 'Final recovery attempt: ForceSync tenant after service restart...'
                    Sync-NAVTenant -ServerInstance $serverInstance -Tenant $tenantId -Mode ForceSync -Force -ErrorAction Stop
                }
            }
            else {
                Write-Host "Tenant state '$($tenant.State)' is not ready. Restarting BC service tier before retry..."
                $bc = Get-Service 'MicrosoftDynamicsNavServer$BC' -ErrorAction Stop
                if ($bc.Status -eq 'Running') {
                    Restart-Service 'MicrosoftDynamicsNavServer$BC' -Force -ErrorAction Stop
                }
                else {
                    Start-Service 'MicrosoftDynamicsNavServer$BC' -ErrorAction Stop
                }
                $bc.WaitForStatus('Running', [TimeSpan]::FromMinutes(2))
            }

            Start-Sleep -Seconds 5
        }

        $tenant = Get-NAVTenant -ServerInstance $serverInstance -Tenant $tenantId -ErrorAction Stop
        throw "Tenant state is '$($tenant.State)' and not ready for app publish after recovery attempts."
    }
}

# If AL-Go generated a new run-specific name, map a persistent cache container to it.
if ((-not (Test-BcContainer -containerName $parameters.containerName)) -and (Test-BcContainer -containerName $persistentContainerName)) {
    Write-Host "Found persistent container '$persistentContainerName'. Renaming to '$($parameters.containerName)' for this run."
    docker rename $persistentContainerName $parameters.containerName 2>&1 | Out-Null
}

# If the container already exists, reuse it - only restore the DB and restart the service tier.
# RemoveBcContainer.ps1 is intentionally empty, so the container persists between CI runs.
if (Test-BcContainer -containerName $parameters.containerName) {
    Write-Host "Container '$($parameters.containerName)' already exists - reusing (skipping container rebuild)."

    try {
        # Ensure the container is running (no-op if already running)
        docker start $parameters.containerName 2>&1 | Out-Null

        # Give Docker a short moment to fully transition the container to running.
        $isRunning = $false
        for ($i = 0; $i -lt 15; $i++) {
            $state = docker inspect -f "{{.State.Running}}" $parameters.containerName 2>$null
            if ($state -eq 'true') {
                $isRunning = $true
                break
            }
            Start-Sleep -Seconds 2
        }
        if (-not $isRunning) {
            throw "Container '$($parameters.containerName)' did not reach running state after start."
        }

        Invoke-Sqlcmd -ConnectionString $connectionString -Query $restoreScript -QueryTimeout 600

        Write-Host "Recreating database snapshot '$snapshotName' ..."
        Invoke-Sqlcmd -ConnectionString $connectionString -Query $snapshotScript -QueryTimeout 120

        if ($currentHash -ne $storedHash) { Set-Content -Path $hashFile -Value $currentHash }

        Ensure-ReusedContainerServices -containerName $parameters.containerName
        Ensure-BcServiceRunningWithRecovery -containerName $parameters.containerName
        Ensure-TenantReadyForPublish -containerName $parameters.containerName

        return
    }
    catch {
        Write-Host "Reusable container failed health checks, falling back to fresh container build."
        Write-Host $_.Exception.Message

        try {
            Invoke-ScriptInBcContainer -containerName $parameters.containerName -scriptblock {
                Get-Service | Where-Object { $_.Name -like 'MicrosoftDynamicsNavServer*' -or $_.Name -like 'MSSQL*' } |
                    Select-Object Name, Status | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
            }
        }
        catch {
            Write-Host "Unable to query service status from reused container."
        }

        try {
            Remove-BcContainer -containerName $parameters.containerName -force
        }
        catch {
            docker rm -f $parameters.containerName 2>&1 | Out-Null
        }
    }
}

# Container does not exist - full setup
Invoke-Sqlcmd -ConnectionString $connectionString -Query $restoreScript -QueryTimeout 600

Write-Host "Creating database snapshot '$snapshotName' ..."
Invoke-Sqlcmd -ConnectionString $connectionString -Query $snapshotScript -QueryTimeout 120

if ($currentHash -ne $storedHash) { Set-Content -Path $hashFile -Value $currentHash }

$parameters.databaseServer     = $databaseServer
$parameters.databaseInstance   = $databaseInstance
$parameters.databaseName       = $databaseName
$parameters.databaseCredential = $databaseCredential

New-BcContainer @parameters
