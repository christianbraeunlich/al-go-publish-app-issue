Param(
    [hashtable]$parameters
)

$bcContainerHelperConfig.usePsSession = $false

$databaseServer   = 'host.containerhelper.internal'
$databaseInstance = ''
$databaseName     = 'CRONUS_W1'
$snapshotName     = 'CRONUS_W1_snapshot'
$databaseUsername = 'bc-docker-devops'
$databasePassword = '1234'
$backupPath       = 'C:\ProgramData\BcContainerHelper\temp\mydatabase_w1'
$hashFile         = "$backupPath.restore_hash"
$dataLogicalName  = 'Navision_NAV_DE_Data'
$logLogicalName   = 'Navision_NAV_DE_Log'
$mdfTarget        = 'C:\Program Files\Microsoft SQL Server\MSSQL16.MSSQLSERVER\MSSQL\DATA\Navision_NAV_W1_FullApplication.mdf'
$ldfTarget        = 'C:\Program Files\Microsoft SQL Server\MSSQL16.MSSQLSERVER\MSSQL\DATA\Navision_NAV_W1_FullApplication.ldf'
$snapshotFile     = 'C:\Program Files\Microsoft SQL Server\MSSQL16.MSSQLSERVER\MSSQL\DATA\CRONUS_W1_snapshot.ss'

$databaseSecurePassword = ConvertTo-SecureString -String $databasePassword -AsPlainText -Force
$databaseCredential     = New-Object pscredential $databaseUsername, $databaseSecurePassword
$connectionString       = "Server=localhost;Database=master;User Id=$databaseUsername;Password=$databasePassword;"

# Determine whether a valid snapshot exists for the current backup
$currentHash = (Get-FileHash -Path $backupPath -Algorithm MD5).Hash
$storedHash  = if (Test-Path $hashFile) { (Get-Content $hashFile -Raw).Trim() } else { '' }

$snapshotExistsResult = Invoke-Sqlcmd -ConnectionString $connectionString `
    -Query "SELECT CAST(CASE WHEN DB_ID(N'$snapshotName') IS NOT NULL THEN 1 ELSE 0 END AS BIT) AS SnapshotExists" `
    -QueryTimeout 30
$snapshotExists = [bool]$snapshotExistsResult.SnapshotExists

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

Invoke-Sqlcmd -ConnectionString $connectionString -Query $restoreScript -QueryTimeout 600

# Recreate snapshot (fast path dropped it automatically; slow path needs it fresh)
Write-Host "Creating database snapshot '$snapshotName' ..."
$snapshotScript = @"
CREATE DATABASE [$snapshotName] ON
    (NAME = N'$dataLogicalName', FILENAME = N'$snapshotFile')
AS SNAPSHOT OF [$databaseName];
"@
Invoke-Sqlcmd -ConnectionString $connectionString -Query $snapshotScript -QueryTimeout 120

# Persist hash so the next run can take the fast path
if ($currentHash -ne $storedHash) {
    Set-Content -Path $hashFile -Value $currentHash
}

$parameters.databaseServer     = $databaseServer
$parameters.databaseInstance   = $databaseInstance
$parameters.databaseName       = $databaseName
$parameters.databaseCredential = $databaseCredential

New-BcContainer @parameters
