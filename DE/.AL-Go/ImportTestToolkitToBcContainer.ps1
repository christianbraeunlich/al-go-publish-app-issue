Param(
    [Hashtable]$parameters
)

$credential = New-Object pscredential 'deploy', (ConvertTo-SecureString -String '1234' -AsPlainText -Force)
$parameters.credential = $credential

$containerName = $parameters.containerName

# The restored database may contain test toolkit apps at a different version.
# Uninstall with -ClearSchema to remove data tables, then unpublish.
Write-Host "Removing existing test toolkit apps from restored database to avoid version conflicts..."

Invoke-ScriptInBcContainer -containerName $containerName -scriptblock {
    $serverInstance = (Get-NAVServerInstance | Select-Object -First 1).ServerInstance

    # Uninstall all test/mock apps from tenant with -ClearSchema to remove data tables
    for ($pass = 0; $pass -lt 5; $pass++) {
        $installedApps = Get-NAVAppInfo -ServerInstance $serverInstance -Tenant "default" -TenantSpecificProperties |
            Where-Object { $_.Publisher -eq "Microsoft" -and $_.IsInstalled -and ($_.Name -match "Test|Mock|Assert|Library") }
        if (-not $installedApps) { break }
        foreach ($app in $installedApps) {
            Write-Host "  Uninstalling $($app.Name) v$($app.Version) (pass $($pass+1))"
            Uninstall-NAVApp -ServerInstance $serverInstance -Name $app.Name -Version "$($app.Version)" -Tenant "default" -Force -ClearSchema -ErrorAction SilentlyContinue
        }
    }

    # Unpublish in multiple passes to handle dependency ordering
    for ($pass = 0; $pass -lt 5; $pass++) {
        $publishedApps = Get-NAVAppInfo -ServerInstance $serverInstance |
            Where-Object { $_.Publisher -eq "Microsoft" -and ($_.Name -match "Test|Mock|Assert|Library") }
        if (-not $publishedApps) { break }
        foreach ($app in $publishedApps) {
            Write-Host "  Unpublishing $($app.Name) v$($app.Version) (pass $($pass+1))"
            Unpublish-NAVApp -ServerInstance $serverInstance -Name $app.Name -Version "$($app.Version)" -ErrorAction SilentlyContinue
        }
    }
}

Import-TestToolkitToBcContainer @parameters
