(
    [hashtable]$parameters
)

Write-Host "Restoring database from backup ..."

$databaseServer = 'host.containerhelper.internal'
$databaseInstance = ''
$databaseName = 'MYDATABASE'
$databaseUsername = 'bc-docker-devops'
$databasePassword = '1234'
$databaseSecurePassword = ConvertTo-SecureString -String $databasePassword -AsPlainText -Force
$databaseCredential = New-Object pscredential $databaseUsername, $databaseSecurePassword

$connectionString = "Server=localhost;Database=master;User Id=$databaseUsername;Password=$databasePassword;"
$queryScript = @"
    DECLARE @terminate NVARCHAR(MAX) =N'';

    SELECT @terminate = @terminate + 'KILL ' + CAST(session_id AS NVARCHAR(10)) + ';'
    FROM sys.dm_exec_sessions
    WHERE database_id = DB_ID(N'$databaseName');

    EXEC(@terminate);

    IF DB_ID(N'$databaseName') IS NOT NULL
    BEGIN
        DROP DATABASE [$databaseName];
    END

    RESTORE DATABASE [$databaseName]
    FROM DISK = N'C:\ProgramData\BcContainerHelper\temp\mydatabase'
    WITH REPLACE,
        MOVE N'Demo Database BC (25-0)_Data' TO N'C:\Program Files\Microsoft SQL Server\MSSQL16.MSSQLSERVER\MSSQL\DATA\$databaseName.mdf',
        MOVE N'Demo Database BC (25-0)_Log'  TO N'C:\Program Files\Microsoft SQL Server\MSSQL16.MSSQLSERVER\MSSQL\Log\$databaseName.ldf';

    ALTER DATABASE [$databaseName] SET RECOVERY SIMPLE, MULTI_USER;
"@

Invoke-Sqlcmd `
    -ConnectionString $connectionString `
    -Query $queryScript

$parameters.databaseServer = $databaseServer
$parameters.databaseInstance = $databaseInstance
$parameters.databaseName = $databaseName
$parameters.databaseCredential = $databaseCredential

New-BcContainer @parameters

Invoke-ScriptInBcContainer -containerName $parameters.ContainerName -scriptblock { $progressPreference = 'SilentlyContinue' }
