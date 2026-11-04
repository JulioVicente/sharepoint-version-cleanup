#requires -Version 7.4.6
param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [Parameter(Mandatory)][string]$ResultPath,
    [string]$ModulePath,
    # Diagnostic use only. The installer rejects a result with Scope=Local.
    [switch]$LocalChecksOnly
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$result = @{ Success=$false; Error=''; Identity=''; Scope='Full'; Stage='startup'; Detail=''; ModulePath=''; ModuleVersion='' }
if ($LocalChecksOnly) { $result.Scope = 'Local' }
$sequence = 0
$transcriptStarted = $false
$certificate = $null
$previousUpdateCheck = $env:PNPPOWERSHELL_UPDATECHECK

function Write-ServiceStage {
    param([string]$Stage,[string]$Detail='')
    $script:result.Stage = $Stage
    $script:result.Detail = $Detail
    $script:sequence++
    $progress = @{ Sequence=$script:sequence; Stage=$Stage; Detail=$Detail; StartedUtc=[datetime]::UtcNow.ToString('o') }
    $progress | ConvertTo-Json | Set-Content -LiteralPath "$ResultPath.progress.json.tmp" -Encoding utf8
    [IO.File]::Move("$ResultPath.progress.json.tmp","$ResultPath.progress.json",$true)
    Write-Host "[SPVC-SERVICE] $Stage : $Detail"
}

try {
    # Publish before loading dependencies so dependency failures are diagnosable.
    Write-ServiceStage 'startup' "PowerShell $($PSVersionTable.PSVersion)"
    $null = Start-Transcript -LiteralPath "$ResultPath.log" -Force
    $transcriptStarted = $true
    $result.Identity = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    if ($result.Identity -ne 'S-1-5-19') { throw 'O teste deve executar como LOCAL SERVICE.' }
    Write-ServiceStage 'configuration' $ConfigPath
    . (Join-Path $PSScriptRoot 'Configuration.ps1')
    $configuration = Read-CleanupConfiguration $ConfigPath

    Write-ServiceStage 'certificate' 'Certificado LocalMachine e assinatura RSA/SHA256'
    $certificate = Get-Item -LiteralPath "Cert:\LocalMachine\My\$($configuration.Authentication.CertificateThumbprint)"
    if (-not $certificate.HasPrivateKey -or $certificate.NotAfter.ToUniversalTime() -le [datetime]::UtcNow -or
        $certificate.NotBefore.ToUniversalTime() -gt [datetime]::UtcNow) { throw 'Certificado sem chave privada ou fora da validade.' }
    $rsa = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($certificate)
    try {
        if (-not $rsa) { throw 'Certificado nao possui chave RSA.' }
        $null = $rsa.SignData([byte[]]@(1,2,3),[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1)
    } finally { if ($rsa) { $rsa.Dispose() } }

    Write-ServiceStage 'storage' 'Escrita nas pastas de logs, estado e auditoria'
    $paths = @($configuration.Paths.Logs,$configuration.Paths.State)
    if ($configuration.Audit.CopyDirectory) { $paths += $configuration.Audit.CopyDirectory }
    foreach ($path in $paths) {
        $probe = Join-Path $path ('service-probe-' + [guid]::NewGuid().ToString('N') + '.tmp')
        try { [IO.File]::WriteAllText($probe,'probe') }
        finally { if (Test-Path -LiteralPath $probe) { Remove-Item -LiteralPath $probe } }
    }

    Write-ServiceStage 'module' $ModulePath
    # Import exactly the manifest validated by the installer, without depending
    # on LOCAL SERVICE's PSModulePath or an interactive user's module cache.
    if (-not $ModulePath) { throw 'Manifesto PnP nao informado. Execute novamente o instalador atualizado.' }
    $sharedRoot = [IO.Path]::GetFullPath((Join-Path $env:ProgramFiles 'PowerShell/Modules')).TrimEnd('\')
    $manifest = [IO.Path]::GetFullPath($ModulePath)
    if (-not $manifest.StartsWith("$sharedRoot\",[StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($manifest) -ne 'PnP.PowerShell.psd1') { throw 'PnP deve estar instalado para todos os usuarios em Program Files.' }
    Write-Host "[SPVC-MODULE] PowerShell $($PSVersionTable.PSVersion); minimo PnP 3.4.1; manifesto $manifest"
    $env:PNPPOWERSHELL_UPDATECHECK = 'false'
    $module = Import-CleanupPnPModule -ModulePath $manifest -PassThru -TraceImport |
        Where-Object Name -EQ 'PnP.PowerShell' | Select-Object -First 1
    if (-not $module) { throw 'Importacao nao retornou o modulo PnP.PowerShell.' }
    $result.ModulePath = $manifest
    $result.ModuleVersion = [string]$module.Version
    if (-not $LocalChecksOnly) {
        foreach ($site in $configuration.Sites) {
            $connection = $null
            try {
                Write-ServiceStage 'connect' $site
                $connection = Connect-PnPOnline -Url $site -Tenant $configuration.Tenant -ClientId $configuration.Authentication.ClientId -Thumbprint $configuration.Authentication.CertificateThumbprint -ReturnConnection -ErrorAction Stop
                if (-not $connection -or -not $connection.Context) { throw 'PnP nao retornou um contexto SharePoint.' }
                $connection.Context.RequestTimeout = 60000
                Write-ServiceStage 'libraries' $site
                $null = Get-CleanupLibraries -SiteUrl $site -FolderServerRelativeUrl $configuration.FolderScopes[$site] -Connection $connection
                if ($configuration.FolderScopes[$site]) {
                    Write-ServiceStage 'folder' "$site : $($configuration.FolderScopes[$site])"
                    $null = Get-PnPFolder -Url $configuration.FolderScopes[$site] -Connection $connection -ErrorAction Stop
                }
            } finally { if ($connection -and $connection.Context) { $connection.Context.Dispose() } }
        }
    }
    Write-ServiceStage 'completed' "Escopo $($result.Scope); PnP $($result.ModuleVersion)"
    $result.Success = $true
} catch {
    $failure = $_
    $hint = ''
    # A missing diagnostic helper must never mask the original failure.
    try { if (Get-Command Get-CleanupFailureHint -ErrorAction SilentlyContinue) { $hint = Get-CleanupFailureHint $failure } } catch { }
    $result.Error = "Etapa '$($result.Stage)' ($($result.Detail)). $hint Erro original: $($failure.Exception.Message)"
    Write-Host $result.Error
} finally {
    $env:PNPPOWERSHELL_UPDATECHECK = $previousUpdateCheck
    if ($certificate) { $certificate.Dispose() }
    if ($transcriptStarted) { try { $null = Stop-Transcript } catch { } }
}
$result | ConvertTo-Json | Set-Content -LiteralPath "$ResultPath.tmp" -Encoding utf8
[IO.File]::Move("$ResultPath.tmp",$ResultPath,$true)
if (-not $result.Success) { exit 1 }
