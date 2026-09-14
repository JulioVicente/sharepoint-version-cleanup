#requires -Version 7.4
[CmdletBinding()]
param([switch]$SkipNetworkCheck)
$ErrorActionPreference = 'Stop'
$results = [Collections.Generic.List[object]]::new()
$results.Add([pscustomobject]@{ Check = 'Windows'; Passed = $IsWindows })
$results.Add([pscustomobject]@{ Check = 'PowerShell 7.4+'; Passed = $PSVersionTable.PSVersion -ge [version]'7.4' })
$admin = $false
if ($IsWindows) {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $admin = ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
$results.Add([pscustomobject]@{ Check = 'Administrador (instalacao)'; Passed = $admin })
$module = Get-Module -ListAvailable PnP.PowerShell | Sort-Object Version -Descending | Select-Object -First 1
$results.Add([pscustomobject]@{ Check = 'PnP.PowerShell 3.0+'; Passed = [bool]($module -and $module.Version -ge [version]'3.0') })
if (-not $SkipNetworkCheck) {
    $network = $false
    try {
        $null = Invoke-RestMethod -Uri 'https://login.microsoftonline.com/common/v2.0/.well-known/openid-configuration' -TimeoutSec 15
        $network = $true
    } catch { Write-Warning $_.Exception.Message }
    $results.Add([pscustomobject]@{ Check = 'Endpoint de autenticacao Microsoft 365'; Passed = $network })
}
$results | Format-Table -AutoSize | Out-Host
if (@($results | Where-Object { -not $_.Passed }).Count) {
    throw 'Pre-requisitos pendentes. Instale PowerShell 7.4+, PnP.PowerShell 3.0+ e execute o instalador como administrador.'
}
Write-Host 'Pre-requisitos locais aprovados. O acesso ao site e ao certificado deve ser validado no piloto.'
