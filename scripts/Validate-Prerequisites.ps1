#requires -Version 5.1
[CmdletBinding()]
param([switch]$SkipNetworkCheck, [switch]$PassThru)
$ErrorActionPreference = 'Stop'
$results = [Collections.Generic.List[object]]::new()
$windows = $env:OS -eq 'Windows_NT'
$results.Add([pscustomobject]@{ Check = 'Windows'; Passed = $windows; Detail = 'Instalacao e agendamento exigem Windows.' })
$results.Add([pscustomobject]@{ Check = 'PowerShell 7.4.6+'; Passed = $PSVersionTable.PSVersion -ge [version]'7.4.6'; Detail = "Atual: $($PSVersionTable.PSVersion). Execute bootstrap.ps1 para instalar a versao compativel." })
$admin = $false
if ($windows) {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $admin = ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
$results.Add([pscustomobject]@{ Check = 'Administrador (instalacao)'; Passed = $admin; Detail = 'Abra PowerShell como Administrador para instalar; a tarefa definitiva usa LOCAL SERVICE.' })
$results.Add([pscustomobject]@{ Check = 'FullLanguage'; Passed = $ExecutionContext.SessionState.LanguageMode -eq 'FullLanguage'; Detail = 'Se bloqueado por politica corporativa, solicite liberacao ao administrador; nao altere politicas automaticamente.' })
$module = Get-Module -ListAvailable PnP.PowerShell | Where-Object { $_.Version.Major -eq 3 -and $_.PowerShellVersion -le $PSVersionTable.PSVersion } | Sort-Object Version -Descending | Select-Object -First 1
$moduleReady = $false
$moduleDetail = 'Execute bootstrap.ps1 para instalar PnP.PowerShell compativel para todos os usuarios.'
if ($module) {
    try { Import-Module $module.Path -ErrorAction Stop; $moduleReady = $true; $moduleDetail = "Importado: $($module.Path). O teste LOCAL SERVICE confirmara acesso sob a identidade agendada." }
    catch { $moduleDetail = "Modulo encontrado mas nao importavel: $($_.Exception.Message). Execute bootstrap.ps1 em um novo processo." }
}
$results.Add([pscustomobject]@{ Check = 'PnP.PowerShell 3.x importavel'; Passed = $moduleReady; Detail = $moduleDetail })
if (-not $SkipNetworkCheck) {
    $network = $false
    try {
        $null = Invoke-RestMethod -Uri 'https://login.microsoftonline.com/common/v2.0/.well-known/openid-configuration' -TimeoutSec 15
        $network = $true
    } catch { $networkError = $_.Exception.Message }
    $detail = if ($network) { 'HTTPS acessivel nesta identidade; nao comprova permissoes no tenant.' } else { "Verifique DNS/proxy/TLS. Erro original: $networkError" }
    $results.Add([pscustomobject]@{ Check = 'Endpoint de autenticacao Microsoft 365'; Passed = $network; Detail = $detail })
}
$results | Format-Table -AutoSize -Wrap | Out-Host
if ($PassThru) { $results.ToArray() }
if (@($results | Where-Object { -not $_.Passed }).Count) {
    $failed = @($results | Where-Object { -not $_.Passed } | ForEach-Object { "$($_.Check): $($_.Detail)" })
    throw "[SPVC-PREREQUISITE] $($failed -join '; ')"
}
Write-Host 'Pre-requisitos locais aprovados. O acesso ao site e ao certificado deve ser validado no piloto.'
