Param(
    [Hashtable]$parameters = @{}
)

function Get-DefaultParams() {
    [Hashtable]$defaultParams = @{
        type                 = "CD" # Type of delivery (CD or Release)
        apps                 = $null # Path to folder containing apps to deploy
        EnvironmentType      = "SaaS" # Environment type
        EnvironmentName      = $null # Environment name
        Branches             = $null # Branches which should deploy to this environment (from settings)
        AuthContext          = '{}' # AuthContext in a compressed Json structure
        BranchesFromPolicy   = $null # Branches which should deploy to this environment (from GitHub environments)
        Projects             = "." # Projects to deploy to this environment
        ContinuousDeployment = $false # Is this environment setup for continuous deployment?
        runs_on              = "windows-latest" # GitHub runner to be used to run the deployment script
        syncMode             = "Add" # Sync mode for the deployment. (Add, Clean, Development, ForceSync or None)
        navAdminTool         = $true # If true, the NavAdminTool.ps1 will be used to import the modules. Otherwise, modules will be located using the Cloud Ready NAV module and imported individually.
        navAdminToolPath     = "" # Path to the NavAdminTool.ps1
        navVersion           = "" # Version string of the Business Central server to deploy to.
        navVersionFolder     = "*" # Name of the folder leading to the system files of the Business Central server. If given without NavAdminToolPath, NavAdminToolPath will be set to "C:\Program Files\Microsoft Dynamics 365 Business Central\$NavVersionFolder\Service\NavAdminTool.ps1".
        scriptVersion        = "v0.3.0" # Version of the deployment script to download.
        dryRun               = $false # If true, the update script won't write any changes to the environment.
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

function Get-Script {
    param (
        [Parameter(Mandatory = $true)]
        [string]$ScriptVersion,
        [Parameter(Mandatory = $true)]
        [string]$scriptName,
        [string]$scriptDescription = $scriptName,
        [string]$ScriptUrl,
        [Parameter(Mandatory = $true)]
        [string]$outputPath
    )
    Write-Host "`nDownloading ${scriptDescription}..."
    if (-not $ScriptUrl) {
        $ScriptUrl = "https://raw.githubusercontent.com/CBS-BC-AT-Internal/INT.utilities/$ScriptVersion/powershell/${ScriptName}"
    }
    Write-Host "URL: $ScriptUrl"
    if (-not (Test-Path -Path $outputPath)) {
        throw "Output path '$outputPath' does not exist."
    }
    $filename = [System.IO.Path]::GetFileName($ScriptUrl)
    $dplScriptPath = Join-Path -Path $outputPath -ChildPath $filename
    Write-Host "::debug::Downloading $ScriptUrl..."
    Invoke-WebRequest -Uri $ScriptUrl -OutFile $dplScriptPath
    Write-Host "Downloaded ${scriptDescription} to $dplScriptPath"

    return $dplScriptPath
}

function Remove-TempFiles {
    param (
        [string]$tempPath
    )
    Remove-Item -Path $tempPath -Recurse -Force | Out-Null
    Write-Host "Removed temporary files."
}

function Get-CRSNModule {
    param(
        [string]$ModuleName = "Cloud.Ready.Software.NAV"
    )

    $CRSNInstalled = Get-Module -Name "Cloud.Ready.Software.NAV" -ErrorAction SilentlyContinue
    if (-not $CRSNInstalled) {
        Write-Host "Cloud.Ready.Software.NAV module is not installed. Installing..."
        Install-Module -Name $ModuleName -Scope CurrentUser -Force -AllowClobber
    }
}

$ErrorActionPreference = "Stop"
InitParameters -parameters $parameters
$tempPath = New-TemporaryFolder
Copy-AppFilesToFolder -appFiles $apps -folder $tempPath | Out-Null
$appsList = Get-AppList -outputPath $tempPath

$reqScripts = @{
    HelperFunctions = @{
        ScriptPath = "modules/HelperFunctions.psm1"
        Description = "common functions"
    }
    ImportNAVModules2 = @{
        ScriptPath = "misc/Import-NAVModules2.ps1"
        Description = "NAV modules setup script"
    }
    UpdateNAVApp = @{
        ScriptPath = "app/Update-NAVApp.ps1"
        Description = "deployment script"
    }
    GetNAVAppUninstallList = @{
        ScriptPath = "app/Get-NAVAppUninstallList.ps1"
        Description = "app management script"
    }
    UninstallNAVAppList = @{
        ScriptPath = "app/Uninstall-NAVAppList.ps1"
        Description = "app uninstall script"
    }
}

Write-Host "`nDownloading required scripts..."
foreach ($reqScript in $reqScripts.GetEnumerator()) {
    $scriptName = $reqScript.Key
    $scriptDetails = $reqScript.Value
    $scriptPath = $scriptDetails.ScriptPath
    $scriptDescription = $scriptDetails.Description

    $getScriptParams = @{
        ScriptVersion     = $scriptVersion
        ScriptName        = $scriptPath
        scriptDescription = $scriptDescription
        outputPath        = $tempPath
    }
    $scriptFullPath = Get-Script @getScriptParams
    Set-Variable -Name $scriptName -Value $scriptFullPath -Scope Script -Force
}

# Install Cloud Ready NAV module if not already installed
Get-CRSNModule

# Import helper functions
Import-Module -Name $HelperFunctions -Force

# Import NAV modules
$navModuleParams = @{
    NavAdminTool = $NavAdminTool
    NavVersion = $navVersion
    NavVersionFolder = $navVersionFolder
    NavAdminToolPath = $NavAdminToolPath
}
& $ImportNAVModules2 @navModuleParams

# Setup deployment parameters
if ($forceSync) {
    $SyncMode = "ForceSync"
}

$deployAppParams = @{
    ServerInstance = $EnvironmentName
    AppFilePath = $null
    Tenant = "default"
    SyncMode = $SyncMode
    installedApps = $null
    DryRun = $dryRun
    getAppsScriptPath = $GetNAVAppUninstallList
    uninstallScriptPath = $UninstallNAVAppList
}

# Deploy each app
foreach ($app in $appsList) {
    $deployAppParams["AppFilePath"] = $app.FullName
    Write-Host "`nDeploying app '$($app.Name)'"

    $paramString = Get-ParameterString -Params $deployAppParams
    Write-Host "::debug::$UpdateNAVApp $paramString"
    $installedApps = & $scripts["UpdateNAVApp"] @deployAppParams
    $deployAppParams["installedApps"] = $installedApps
}

Write-Host "`nSuccessfully deployed all apps to $EnvironmentName."
Remove-TempFiles -tempPath $tempPath
