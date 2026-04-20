Param(
    [Hashtable]$parameters
)

$persistentContainerName = 'bcDEpersistent'
$currentContainerName = $parameters.containerName

if (Test-BcContainer -containerName $currentContainerName) {
    Write-Host "Preserving container '$currentContainerName' as '$persistentContainerName' for reuse."

    if (Test-BcContainer -containerName $persistentContainerName) {
        docker rm -f $persistentContainerName 2>&1 | Out-Null
    }

    docker rename $currentContainerName $persistentContainerName 2>&1 | Out-Null
}