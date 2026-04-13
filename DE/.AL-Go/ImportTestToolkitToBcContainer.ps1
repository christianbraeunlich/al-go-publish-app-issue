Param(
    [Hashtable]$parameters
)

$credential = New-Object pscredential 'deploy', (ConvertTo-SecureString -String '1234' -AsPlainText -Force)
$parameters.credential = $credential

$containerName = $parameters.containerName

# The restored database may contain test toolkit apps at a different version.
# Remove them before importing to avoid version conflicts.
Write-Host "Removing existing test toolkit apps from restored database to avoid version conflicts..."

$installedApps = Get-BcContainerAppInfo -containerName $containerName -tenantSpecificProperties -tenant "default" |
    Where-Object { $_.Publisher -eq "Microsoft" -and $_.IsInstalled -and ($_.Name -match "Test|Mock|Assert") }

foreach ($app in $installedApps) {
    Write-Host "  Uninstalling $($app.Name) v$($app.Version)"
    Uninstall-BcContainerApp -containerName $containerName -name $app.Name -version "$($app.Version)" -tenant "default" -Force -ErrorAction SilentlyContinue
}

# Unpublish in multiple passes to handle dependency ordering
for ($i = 0; $i -lt 5; $i++) {
    $publishedApps = Get-BcContainerAppInfo -containerName $containerName |
        Where-Object { $_.Publisher -eq "Microsoft" -and ($_.Name -match "Test|Mock|Assert") }
    if (-not $publishedApps) { break }
    foreach ($app in $publishedApps) {
        Write-Host "  Unpublishing $($app.Name) v$($app.Version)"
        Unpublish-BcContainerApp -containerName $containerName -name $app.Name -version "$($app.Version)" -ErrorAction SilentlyContinue
    }
}

Import-TestToolkitToBcContainer @parameters
