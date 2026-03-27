Param(
    [Hashtable]$parameters
)
$credential = New-Object pscredential 'deploy', (ConvertTo-SecureString -String '1234' -AsPlainText -Force)

$parameters.credential = $credential
Run-TestsInBcContainer @parameters