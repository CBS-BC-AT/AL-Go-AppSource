Param(
    [Hashtable]$parameters = @{}
)

function Get-DefaultParams() {
    [Hashtable]$defaultParams = @{
        "type"                 = "CD" # Type of delivery (CD or Release)
        "apps"                 = $null # Path to folder containing apps to deploy
        "EnvironmentType"      = "SaaS" # Environment type
        "EnvironmentName"      = $null # Environment name
        "Branches"             = $null # Branches which should deploy to this environment (from settings)
        "AuthContext"          = '{}' # AuthContext in a compressed Json structure
        "BranchesFromPolicy"   = $null # Branches which should deploy to this environment (from GitHub environments)
        "Projects"             = "." # Projects to deploy to this environment
        "ContinuousDeployment" = $false # Is this environment setup for continuous deployment?
        "runs_on"              = "windows-latest" # GitHub runner to be used to run the deployment script
        "SyncMode"             = "Add" # Sync mode for the deployment. (Add or ForceSync)
        "bcVersion"            = "" # Version string of the Business Central server to deploy to.
        "modulePath"           = "" # Path to the module to deploy the app to. Used to circumvent "Import-NAVModules" in the deployment script.
        "folderVersion"        = "" # Name of the folder leading to the system files of the Business Central server. If given without modulePath, modulePath will be set to "C:\Program Files\Microsoft Dynamics 365 Business Central\$folderVersion\Service\NavAdminTool.ps1".
        "dplScriptVersion"     = "v0.2.18" # Version of the deployment script to download.
        "dplScriptUrl"         = "" # URL to the deployment script to download.
        "dryRun"               = $false # If true, the update script won't write any changes to the environment.
    }
    return $defaultParams
}

function InitParameters {
    param (
        [hashtable]$parameters
    )
    $finalParams = Get-DefaultParams
    $parameters.GetEnumerator() | ForEach-Object {
        $finalParams[$_.Key] = $_.Value
    }
    $finalParams.Keys | ForEach-Object {
        Write-Host "$_ = $($finalParams[$_])"
        New-Variable -Name $_ -Value $finalParams[$_] -Force -Scope Script
    }
}

function New-TemporaryFolder {
    $tempPath = Join-Path -Path $PWD -ChildPath "_temp"
    New-Item -ItemType Directory -Path $tempPath | Out-Null

    return $tempPath
}

function Get-AppList {
    param (
        [string]$outputPath
    )
    $appsList = @(Get-ChildItem -Path $outputPath -Filter *.app)
    if (-not $appsList -or $appsList.Count -eq 0) {
        Write-Host "::error::No apps to publish found."
        exit 1
    }

    if ($appsList.Count -gt 1) {
        $appsList = Sort-AppFilesByDependencies -appFiles $appsList
        $appsList = $appsList | ForEach-Object { [System.IO.FileInfo]$_ }
        Write-Host "Publishing a total of $($appsList.Count) app(s):"
        $appsList | ForEach-Object { Write-Host "- $($_.Name)" }
    }
    else {
        Write-Host "Publishing $($appsList[0].Name)."
    }

    return $appsList
}

function Get-PublishScript {
    param (
        [Parameter(Mandatory = $true)]
        [string]$dplScriptVersion,
        [string]$dplScriptUrl,
        [Parameter(Mandatory = $true)]
        [string]$outputPath
    )
    Write-Host "`nDownloading the deployment script..."
    if (-not $dplScriptUrl) {
        $dplScriptUrl = "https://raw.githubusercontent.com/CBS-BC-AT-Internal/INT.utilities/$dplScriptVersion/powershell/Update-NAVApp.ps1"
    }
    Write-Host "URL: $dplScriptUrl"
    if (-not (Test-Path -Path $outputPath)) {
        throw "Output path '$outputPath' does not exist."
    }
    $filename = [System.IO.Path]::GetFileName($dplScriptUrl)
    $dplScriptPath = Join-Path -Path $outputPath -ChildPath $filename
    Invoke-WebRequest -Uri $dplScriptUrl -OutFile $dplScriptPath
    Write-Host "Downloaded the deployment script to $dplScriptPath"

    return $dplScriptPath
}

function Deploy-App {
    param (
        [Parameter(Mandatory = $true)]
        [string]$srvInst,
        [Parameter(Mandatory = $true)]
        [System.IO.FileInfo]$app,
        [Parameter(Mandatory = $true)]
        [string]$dplScriptPath,
        [string]$bcVersion,
        [string]$modulePath,
        [string]$folderVersion,
        [bool]$forceSync,
        [bool]$dryRun
    )

    Write-Host "`nDeploying app '$($app.Name)'"
    $params = @{
        "appPath" = $app.FullName;
    }
    $paramNames = @(
        "srvInst",
        "bcVersion",
        "modulePath",
        "folderVersion"
    )

    foreach ($paramName in $paramNames) {
        if (Get-Variable -Name $paramName -ErrorAction SilentlyContinue) {
            $params[$paramName] = Get-Variable -Name $paramName -ValueOnly
        }
    }

    $switchParams = @{}
    $switchParamNames = @(
        "forceSync",
        "dryRun"
    )

    foreach ($switchParamName in $switchParamNames) {
        if (Get-Variable -Name $switchParamName -ErrorAction SilentlyContinue) {
            $switchParams[$switchParamName] = Get-Variable -Name $switchParamName -ValueOnly
        }
    }

    $commandString = $dplScriptPath
    foreach ($key in $params.Keys) {
        Write-Host "::debug::${key}: $($params[$key])"
        $commandString += " -${key} '$($params[$key])'"
    }
    foreach ($key in $switchParams.Keys) {
        if ($switchParams[$key]) {
            Write-Host "::debug::${key}: true"
            $commandString += " -${key}"
        }
    }

    # Deploy the app using the downloaded script
    Write-Host "$commandString"
    Invoke-Expression -Command $commandString
}

function Remove-TempFiles {
    param (
        [string]$tempPath
    )
    Remove-Item -Path $tempPath -Recurse -Force | Out-Null
    Write-Host "Removed temporary files."
}

$ErrorActionPreference = "Stop"
InitParameters -parameters $parameters
$tempPath = New-TemporaryFolder
Copy-AppFilesToFolder -appFiles $apps -folder $tempPath | Out-Null
$appsList = Get-AppList -outputPath $tempPath
$dplScriptPath = Get-PublishScript -outputPath $tempPath -dplScriptVersion $dplScriptVersion -dplScriptUrl $dplScriptUrl
$forceSync = $SyncMode -eq "ForceSync"

$deployAppParams = @{
    srvInst       = $EnvironmentName
    dplScriptPath = $dplScriptPath
    bcVersion     = $bcVersion
    modulePath    = $modulePath
    folderVersion = $folderVersion
    forceSync     = $forceSync
    dryRun        = $dryRun
}

foreach ($app in $appsList) {
    $deployAppParams["app"] = $app
    Deploy-App @deployAppParams
}

Write-Host "`nSuccessfully deployed all apps to $EnvironmentName."
Remove-TempFiles -tempPath $tempPath
