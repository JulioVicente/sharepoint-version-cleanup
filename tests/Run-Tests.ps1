#requires -Version 7.4
[CmdletBinding()]
param([string]$PesterPath)
$ErrorActionPreference = 'Stop'
if ($PesterPath) { Import-Module $PesterPath -Force }
else { Import-Module Pester -MinimumVersion 5.7.1 -Force }
$config = New-PesterConfiguration
$config.Run.Path = $PSScriptRoot
$config.Run.PassThru = $true
$config.TestRegistry.Enabled = $false
$config.Output.Verbosity = 'Detailed'
$result = Invoke-Pester -Configuration $config
if ($result.FailedCount -or $result.FailedContainersCount) { exit 1 }
