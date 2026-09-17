#requires -Version 5.1
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$InstallPath = "$env:ProgramData\SharePointVersionCleanup",
    [string]$RepositoryRawUrl,
    [ValidatePattern('^[a-zA-Z0-9._-]+$')][string]$ReleaseVersion = 'v1.3.0',
    [switch]$SkipAppRegistration,
    [switch]$SkipEmailTest,
    [string]$AdminClientId
)
$ErrorActionPreference = 'Stop'
if (-not $RepositoryRawUrl) { $RepositoryRawUrl = "https://raw.githubusercontent.com/JulioVicente/sharepoint-version-cleanup/$ReleaseVersion" }
# When invoked through `iwr ... | iex`, PowerShell does not create a
# PSCmdlet object for this script block. Keep WhatIf support for file execution
# while allowing the one-line launcher to run normally.
if ($PSCmdlet -and -not $PSCmdlet.ShouldProcess($InstallPath, 'Preparar PowerShell, baixar e iniciar o assistente')) { return }
if ($env:OS -ne 'Windows_NT') { throw 'Este instalador requer Windows.' }
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Abra PowerShell como Administrador e repita este comando.'
}
$pwsh = Get-Command pwsh.exe -ErrorAction SilentlyContinue
$ready = $false
if ($pwsh) {
    $version = & $pwsh.Source -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'
    $ready = $LASTEXITCODE -eq 0 -and [version]$version -ge [version]'7.4'
}
if (-not $ready) {
    Write-Host 'PowerShell 7.4+ e necessario. Vamos instalar pelo WinGet oficial.'
    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if (-not $winget) { throw 'WinGet ausente. Instale PowerShell 7.4+ em https://github.com/PowerShell/PowerShell/releases e repita o comando.' }
    & $winget.Source install --id Microsoft.PowerShell --exact --source winget
    if ($LASTEXITCODE -ne 0) { throw "A instalacao do PowerShell falhou (codigo $LASTEXITCODE)." }
    $installedPwsh = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
    if (-not (Test-Path -LiteralPath $installedPwsh)) { throw 'PowerShell nao encontrado apos instalacao. Abra um novo terminal e tente novamente.' }
    $pwsh = Get-Item -LiteralPath $installedPwsh
    $pwshPath = $pwsh.FullName
} else { $pwshPath = $pwsh.Source }
$installer = if ($PSScriptRoot) { Join-Path $PSScriptRoot 'Install.ps1' } else { $null }
$downloaded = $false
try {
    if (-not $installer -or -not (Test-Path -LiteralPath $installer)) {
        $installer = Join-Path ([IO.Path]::GetTempPath()) ('spvc-' + [guid]::NewGuid().ToString('N') + '.ps1')
        $downloaded = $true
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                $manifest = Invoke-RestMethod -Uri "$($RepositoryRawUrl.TrimEnd('/'))/release-manifest.json" -TimeoutSec 60
        Invoke-WebRequest -UseBasicParsing -Uri "$($RepositoryRawUrl.TrimEnd('/'))/Install.ps1" -OutFile $installer -TimeoutSec 60
        $expectedHash = $manifest.Files.'Install.ps1'
        if (-not $expectedHash -or (Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash -ne $expectedHash) {
            throw 'Hash SHA256 do instalador divergente. Nenhum instalador foi executado.'
        }
    }
    $arguments = @('-NoLogo','-NoProfile','-File',$installer,'-InstallPath',$InstallPath,'-RepositoryRawUrl',$RepositoryRawUrl)
    if ($SkipAppRegistration) { $arguments += '-SkipAppRegistration' }
    if ($SkipEmailTest) { $arguments += '-SkipEmailTest' }
    if ($AdminClientId) { $arguments += @('-AdminClientId',$AdminClientId) }
    & $pwshPath @arguments
    if ($LASTEXITCODE -ne 0) { throw "O assistente terminou com erro (codigo $LASTEXITCODE). Veja a mensagem acima." }
} finally {
    if ($downloaded) { Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue }
}
