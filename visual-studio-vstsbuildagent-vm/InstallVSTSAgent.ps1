﻿# Downloads the Visual Studio Team Services Build Agent and installs on the new machine
# and registers with the Visual Studio Team Services account and build agent pool

# Enable -Verbose option
[CmdletBinding()]
Param(
[Parameter(Mandatory=$true)]$VSTSAccount,
[Parameter(Mandatory=$true)]$PersonalAccessToken,
[Parameter(Mandatory=$true)]$AgentName,
[Parameter(Mandatory=$true)]$PoolName,
[Parameter(Mandatory=$true)]$runAsAutoLogon,
[Parameter(Mandatory=$false)]$vmAdminUserName,
[Parameter(Mandatory=$false)]$vmAdminPassword
)

Write-Verbose "Entering InstallVSOAgent.ps1" -verbose

$currentLocation = Split-Path -parent $MyInvocation.MyCommand.Definition
Write-Verbose "Current folder: $currentLocation" -verbose

#Create a temporary directory where to download from VSTS the agent package (vsts-agent.zip) and then launch the configuration.
$agentTempFolderName = Join-Path $env:temp ([System.IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Force -Path $agentTempFolderName
Write-Verbose "Temporary Agent download folder: $agentTempFolderName" -verbose

$serverUrl = "https://$VSTSAccount.visualstudio.com"
Write-Verbose "Server URL: $serverUrl" -verbose

$retryCount = 3
$retries = 1
Write-Verbose "Downloading Agent install files" -verbose
do
{
  try
  {
    Write-Verbose "Trying to get download URL for latest VSTS agent release..."
    $latestReleaseDownloadUrl = "https://vstsagentpackage.azureedge.net/agent/2.126.0/vsts-agent-win-x64-2.126.0.zip"
    Invoke-WebRequest -Uri $latestReleaseDownloadUrl -Method Get -OutFile "$agentTempFolderName\agent.zip"
    Write-Verbose "Downloaded agent successfully on attempt $retries" -verbose
    break
  }
  catch
  {
    $exceptionText = ($_ | Out-String).Trim()
    Write-Verbose "Exception occured downloading agent: $exceptionText in try number $retries" -verbose
    $retries++
    Start-Sleep -Seconds 30 
  }
} 
while ($retries -le $retryCount)

# Construct the agent folder under the main (hardcoded) C: drive.
$agentInstallationPath = Join-Path "C:" $AgentName 
# Create the directory for this agent.
New-Item -ItemType Directory -Force -Path $agentInstallationPath 

# Create a folder for the build work
New-Item -ItemType Directory -Force -Path (Join-Path $agentInstallationPath $WorkFolder)

Write-Verbose "Extracting the zip file for the agent" -verbose
$destShellFolder = (new-object -com shell.application).namespace("$agentInstallationPath")
$destShellFolder.CopyHere((new-object -com shell.application).namespace("$agentTempFolderName\agent.zip").Items(),16)

# Removing the ZoneIdentifier from files downloaded from the internet so the plugins can be loaded
# Don't recurse down _work or _diag, those files are not blocked and cause the process to take much longer
Write-Verbose "Unblocking files" -verbose
Get-ChildItem -Recurse -Path $agentInstallationPath | Unblock-File | out-null

# Retrieve the path to the config.cmd file.
$agentConfigPath = [System.IO.Path]::Combine($agentInstallationPath, 'config.cmd')
Write-Verbose "Agent Location = $agentConfigPath" -Verbose
if (![System.IO.File]::Exists($agentConfigPath))
{
    Write-Error "File not found: $agentConfigPath" -Verbose
    return
}

# Call the agent with the configure command and all the options (this creates the settings file) without prompting
# the user or blocking the cmd execution

Write-Verbose "Configuring agent" -Verbose

# Set the current directory to the agent dedicated one previously created.
Push-Location -Path $agentInstallationPath



$Computer = "localhost"
$domain = Hostname
$pass = ConvertTo-SecureString $vmAdminPassword -AsPlainText -Force
$cred= New-Object System.Management.Automation.PSCredential ("$domain\\$vmAdminUserName", $pass)
Enter-PSSession -ComputerName $Computer -Credential $cred
Start-Sleep(10)
Exit-PSSession


if ($runAsAutoLogon -ieq "true")
{
  $ErrorActionPreference = "stop"

  $timeout = 60 # seconds

  try
  {
    # Check if the HKU drive already exists
    Get-PSDrive -PSProvider Registry -Name HKU | Out-Null
    $canCheckRegistry = $true
  }
  catch [System.Management.Automation.DriveNotFoundException]
  {
    try 
    {
      # Create the HKU drive
      New-PSDrive -PSProvider Registry -Name HKU -Root HKEY_USERS | Out-Null
      $canCheckRegistry = $true
    }
    catch 
    {
      # Ignore the failure to create the drive and go ahead with trying to set the agent up
      Write-Warning "Moving ahead with agent setup as the script failed to create HKU drive necessary for checking if the registry entry for the user's SId exists.\n$_"
    }
  }

  dir Registry::HKU

  # Check if the registry key required for enabling autologon is present on the machine, if not wait for 120 seconds in case the user profile is still getting created
  while ($timeout -ge 0 -and $canCheckRegistry)
  {
    Write-Host $timeout

    $objUser = New-Object System.Security.Principal.NTAccount($vmAdminUserName)
    $securityId = $objUser.Translate([System.Security.Principal.SecurityIdentifier])
    $securityId = $securityId.Value
    
    #New-Item -Path "HKU:\\$securityId\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Run" -Force

    if (Test-Path "HKU:\\$securityId") #\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Run
    {
      Write-Host "Found the registry entry required to enable autologon."
      if (!(Test-Path "HKU:\\$securityId\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Run"))
      {
        New-Item -Path "HKU:\\$securityId\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Run" -Force
      }
      break
    }
    else
    {
      $timeout -= 10
      Start-Sleep(10)
    }
  }


  if ($timeout -lt 0)
  {
    Write-Warning "Failed to find the registry entry for the SId of the user, this is required to enable autologon. Trying to start the agent anyway."
  }

  # Setup the agent with autologon enabled
  .\config.cmd --unattended --url $serverUrl --auth PAT --token $PersonalAccessToken --pool $PoolName --agent $AgentName --runAsAutoLogon --overwriteAutoLogon --windowslogonaccount $vmAdminUserName --windowslogonpassword $vmAdminPassword
}
else 
{
  # Setup the agent as a service
  .\config.cmd --unattended --url $serverUrl --auth PAT --token $PersonalAccessToken --pool $PoolName --agent $AgentName --runasservice
}

Pop-Location

Write-Verbose "Agent install output: $LASTEXITCODE" -Verbose

Write-Verbose "Exiting InstallVSTSAgent.ps1" -Verbose

