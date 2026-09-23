#requires -Version 5.1
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$InstallPath = "$env:ProgramData\SharePointVersionCleanup",
    [string]$RepositoryRawUrl,
    [ValidatePattern('^[a-zA-Z0-9._-]+$')][string]$ReleaseVersion = 'v1.4.5',
    [switch]$Uninstall,
    [switch]$CleanInstall,
    [switch]$Force,
    [switch]$SkipAppRegistration,
    [switch]$SkipEmailTest,
    [string]$AdminClientId
)
$ErrorActionPreference = 'Stop'
function Find-CleanupPowerShell {
    $candidates = @(
        (Join-Path $PSHOME 'pwsh.exe')
        $(if ($env:ProgramW6432) { Join-Path $env:ProgramW6432 'PowerShell\7\pwsh.exe' })
        $(if ($env:ProgramFiles) { Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe' })
        $(Get-Command pwsh.exe -CommandType Application -ErrorAction SilentlyContinue | Where-Object { $_ } | ForEach-Object Source)
    ) | Where-Object { $_ } | Select-Object -Unique
    foreach ($candidate in $candidates) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        try {
            $output = & $candidate -NoLogo -NoProfile -NonInteractive -Command '$PSVersionTable.PSVersion.ToString()' 2>$null
            $version = $null
            if ($LASTEXITCODE -eq 0 -and [version]::TryParse(([string]($output | Select-Object -Last 1)).Trim(), [ref]$version) -and $version -ge [version]'7.4.6') {
                return $candidate
            }
        } catch { Write-Verbose "PowerShell indisponivel em ${candidate}: $($_.Exception.Message)" }
    }
}

function Install-CleanupPowerShell {
    $winget = Get-Command winget.exe -CommandType Application -ErrorAction SilentlyContinue
    if ($winget) {
        try {
            & $winget.Source install --id Microsoft.PowerShell --exact --source winget --silent --accept-source-agreements --accept-package-agreements --disable-interactivity | Out-Host
            $installed = Find-CleanupPowerShell
            if ($installed) { return $installed }
            Write-Warning 'WinGet nao disponibilizou PowerShell compativel. Tentando MSI oficial.'
        } catch { Write-Warning "WinGet indisponivel: $($_.Exception.Message). Tentando MSI oficial." }
    }
    $msi = Join-Path ([IO.Path]::GetTempPath()) ('spvc-pwsh-' + [guid]::NewGuid().ToString('N') + '.msi')
    $msiLog = "$msi.log"
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $architecture = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
        $platform = switch ($architecture) { 'AMD64' { 'x64' }; 'ARM64' { 'arm64' }; 'x86' { 'x86' }; default { throw "Arquitetura nao suportada: $architecture" } }
        $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/PowerShell/PowerShell/releases/latest' -TimeoutSec 60
        $asset = @($release.assets | Where-Object { $_.name -match "^PowerShell-[0-9.]+-win-$platform\.msi$" })
        if ($asset.Count -ne 1) { throw "MSI oficial para $platform nao encontrado na versao $($release.tag_name)." }
        Invoke-WebRequest -UseBasicParsing -Uri $asset[0].browser_download_url -OutFile $msi -TimeoutSec 300
        $signature = Get-AuthenticodeSignature -LiteralPath $msi
        if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch '(^|,\s*)O=Microsoft Corporation(,|$)') {
            throw 'Assinatura Microsoft do MSI nao validada. O pacote nao sera executado.'
        }
        $process = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\msiexec.exe') -ArgumentList "/i `"$msi`" /quiet /norestart /L*v `"$msiLog`"" -WindowStyle Hidden -Wait -PassThru
        if ($process.ExitCode -notin 0,3010) { throw "Windows Installer retornou $($process.ExitCode). Log: $msiLog" }
        if ($process.ExitCode -eq 3010) { Write-Warning 'Windows Installer solicitou reinicializacao. Reinicie se o novo PowerShell nao iniciar.' }
        $installed = Find-CleanupPowerShell
        if (-not $installed) { throw 'O PowerShell instalado nao iniciou ou nao atingiu a versao 7.4.6.' }
        return $installed
    } catch {
        throw "[SPVC-RUNTIME] Nao foi possivel preparar PowerShell 7.4.6+. Verifique proxy, TLS, acesso a github.com/api.github.com e politicas do Windows Installer. Instale manualmente em https://github.com/PowerShell/PowerShell/releases e repita. Log MSI, se criado: $msiLog. Erro original: $($_.Exception.Message)"
    } finally { if (Test-Path -LiteralPath $msi) { Remove-Item -LiteralPath $msi -Force -ErrorAction SilentlyContinue } }
}

function Get-CleanupLauncherComponent {
    param([string]$RelativePath, [string]$RepositoryRawUrl, [string]$LocalRoot, [Collections.Generic.List[string]]$Downloads)
    $localFile = if ($LocalRoot) { Join-Path $LocalRoot $RelativePath } else { $null }
    if ($localFile -and (Test-Path -LiteralPath $localFile -PathType Leaf)) { return $localFile }
    $temporaryFile = Join-Path ([IO.Path]::GetTempPath()) ('spvc-' + [guid]::NewGuid().ToString('N') + '.ps1')
    $Downloads.Add($temporaryFile)
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $manifest = Invoke-RestMethod -Uri "$($RepositoryRawUrl.TrimEnd('/'))/release-manifest.json" -TimeoutSec 60
    Invoke-WebRequest -UseBasicParsing -Uri "$($RepositoryRawUrl.TrimEnd('/'))/$RelativePath" -OutFile $temporaryFile -TimeoutSec 60
    $expectedHash = $manifest.Files.$RelativePath
    if (-not $expectedHash -or (Get-FileHash -LiteralPath $temporaryFile -Algorithm SHA256).Hash -ne $expectedHash) {
        throw "Hash SHA256 divergente: $RelativePath. Nenhum componente foi executado."
    }
    return $temporaryFile
}

function Invoke-CleanupLauncher {
    param([string]$PowerShellPath, [string]$InstallPath, [string]$RepositoryRawUrl, [string]$LocalRoot,
        [switch]$Uninstall, [switch]$CleanInstall, [switch]$Force,
        [switch]$SkipAppRegistration, [switch]$SkipEmailTest, [string]$AdminClientId)
    $downloads = [Collections.Generic.List[string]]::new()
    try {
        if ($Uninstall -or $CleanInstall) {
            $remover = Get-CleanupLauncherComponent -RelativePath 'scripts/Uninstall.ps1' -RepositoryRawUrl $RepositoryRawUrl -LocalRoot $LocalRoot -Downloads $downloads
            $removeArguments = @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$remover,'-InstallPath',$InstallPath)
            if ($Force) { $removeArguments += '-Force' }
            & $PowerShellPath @removeArguments
            if ($LASTEXITCODE -ne 0) { throw "A desinstalacao nao foi concluida (codigo $LASTEXITCODE). Nenhuma nova instalacao foi iniciada." }
            if ($Uninstall) { return }
        }
        $installer = Get-CleanupLauncherComponent -RelativePath 'Install.ps1' -RepositoryRawUrl $RepositoryRawUrl -LocalRoot $LocalRoot -Downloads $downloads
        $arguments = @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$installer,'-InstallPath',$InstallPath,'-RepositoryRawUrl',$RepositoryRawUrl)
        if ($SkipAppRegistration) { $arguments += '-SkipAppRegistration' }
        if ($SkipEmailTest) { $arguments += '-SkipEmailTest' }
        if ($AdminClientId) { $arguments += @('-AdminClientId',$AdminClientId) }
        & $PowerShellPath @arguments
        if ($LASTEXITCODE -ne 0) { throw "O assistente terminou com erro (codigo $LASTEXITCODE). Veja a mensagem acima." }
    } finally {
        foreach ($download in $downloads) { if (Test-Path -LiteralPath $download) { Remove-Item -LiteralPath $download -Force -ErrorAction SilentlyContinue } }
    }
}

if ($Uninstall -and $CleanInstall) { throw 'Escolha somente -Uninstall ou -CleanInstall.' }
if ($Force -and -not ($Uninstall -or $CleanInstall)) { throw '-Force so se aplica a -Uninstall ou -CleanInstall.' }
if (-not $RepositoryRawUrl) { $RepositoryRawUrl = "https://raw.githubusercontent.com/JulioVicente/sharepoint-version-cleanup/$ReleaseVersion" }
# When invoked through `iwr ... | iex`, PowerShell does not create a
# PSCmdlet object for this script block. Keep WhatIf support for file execution
# while allowing the one-line launcher to run normally.
$operation = if ($Uninstall) { 'Desinstalar preservando backup, logs e certificados' } elseif ($CleanInstall) { 'Arquivar instalacao anterior e iniciar novo assistente' } else { 'Preparar PowerShell, baixar e iniciar o assistente' }
if ($PSCmdlet -and -not $PSCmdlet.ShouldProcess($InstallPath, $operation)) { return }
if ($env:OS -ne 'Windows_NT') { throw 'Este instalador requer Windows.' }
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Abra PowerShell como Administrador e repita este comando.'
}
$pwshPath = Find-CleanupPowerShell
if (-not $pwshPath) {
    Write-Host 'Preparando PowerShell 7.4.6+ para executar o assistente.'
    $pwshPath = Install-CleanupPowerShell
}
Invoke-CleanupLauncher -PowerShellPath $pwshPath -InstallPath $InstallPath -RepositoryRawUrl $RepositoryRawUrl -LocalRoot $PSScriptRoot `
    -Uninstall:$Uninstall -CleanInstall:$CleanInstall -Force:$Force -SkipAppRegistration:$SkipAppRegistration -SkipEmailTest:$SkipEmailTest -AdminClientId $AdminClientId
