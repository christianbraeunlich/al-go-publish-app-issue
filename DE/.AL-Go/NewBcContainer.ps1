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

        # Stop BC service BEFORE database restore to prevent stale in-memory state.
        # If BC is running during snapshot restore, its metadata becomes inconsistent
        # with the DB, causing OperationalWithSyncPending and failed restarts.
        Invoke-ScriptInBcContainer -containerName $parameters.containerName -scriptblock {
            $bc = Get-Service 'MicrosoftDynamicsNavServer$BC' -ErrorAction SilentlyContinue
            if ($null -ne $bc -and $bc.Status -eq 'Running') {
                Write-Host "Stopping BC service tier before database restore..."
                Stop-Service 'MicrosoftDynamicsNavServer$BC' -Force
                $bc.WaitForStatus('Stopped', [TimeSpan]::FromMinutes(1))
            }
        }

        Invoke-Sqlcmd -ConnectionString $connectionString -Query $restoreScript -QueryTimeout 600

        Write-Host "Recreating database snapshot '$snapshotName' ..."
        Invoke-Sqlcmd -ConnectionString $connectionString -Query $snapshotScript -QueryTimeout 120

        if ($currentHash -ne $storedHash) { Set-Content -Path $hashFile -Value $currentHash }

        Ensure-ReusedContainerServices -containerName $parameters.containerName

        # Start BC service fresh against the restored database.
        Invoke-ScriptInBcContainer -containerName $parameters.containerName -scriptblock {
            Write-Host "Starting BC service tier after database restore..."
            Start-Service 'MicrosoftDynamicsNavServer$BC'
            (Get-Service 'MicrosoftDynamicsNavServer$BC').WaitForStatus('Running', [TimeSpan]::FromMinutes(2))
            Write-Host "BC service tier started successfully."
        }

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
