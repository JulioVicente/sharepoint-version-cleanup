#requires -Version 7.4.6
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ModulePath)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not ([Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Este teste exige Windows elevado.'
}
. (Join-Path $PSScriptRoot '../scripts/TaskIdentity.ps1')
$parent = [IO.Path]::GetFullPath($env:ProgramData).TrimEnd('\')
$name = 'SPVC-WorkerIntegration-' + [guid]::NewGuid().ToString('N')
$root = Join-Path $parent $name
$cert = $null
$registered = $false
try {
    foreach ($folder in 'scripts','state','logs') { $null = New-Item -ItemType Directory -Path (Join-Path $root $folder) -Force }
    Copy-Item -Path (Join-Path $PSScriptRoot '../scripts/*.ps1') -Destination (Join-Path $root 'scripts')
    $config = Get-Content (Join-Path $PSScriptRoot '../config/config.example.json') -Raw | ConvertFrom-Json -AsHashtable
    $config.Paths.State = Join-Path $root 'state'
    $config.Paths.Logs = Join-Path $root 'logs'
    $configPath = Join-Path $root 'config.json'
    $resultPath = Join-Path $root 'state/result.json'
    # The actual production worker tests local prerequisites only. Its Scope=Local
    # result is deliberately not acceptable to the installation gate.
    foreach ($provider in 'Microsoft Software Key Storage Provider','Microsoft Enhanced RSA and AES Cryptographic Provider','Microsoft Base Cryptographic Provider v1.0') {
        # The legacy Base CSP cannot issue SHA256 certificates through CertEnroll.
        # Its disposable SHA1 certificate still has to pass the worker's SHA256
        # private-key signing probe, exactly like an existing legacy installation.
        $hash = if ($provider -like 'Microsoft Base*') { 'SHA1' } else { 'SHA256' }
        $keyOptions = @{}; if ($provider -like 'Microsoft Base*') { $keyOptions.KeySpec = 'Signature' }
        $cert = New-SelfSignedCertificate -Subject "CN=$name" -CertStoreLocation Cert:\LocalMachine\My -KeyAlgorithm RSA -KeyLength 2048 -Provider $provider -HashAlgorithm $hash @keyOptions -KeyExportPolicy Exportable -NotAfter (Get-Date).AddDays(1)
        $config.Authentication.CertificateThumbprint = $cert.Thumbprint
        $config | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $configPath -Encoding utf8
        Set-CleanupCertificatePrivateKeyAcl -Certificate $cert
        Set-CleanupServiceAcl -Path $root
        foreach ($entry in Get-ChildItem $root -Recurse -Force) { Set-CleanupServiceAcl -Path $entry.FullName }
        foreach ($path in $config.Paths.Values) { Set-CleanupServiceAcl -Path $path -ServiceRights Modify }
        $worker = Join-Path $root 'scripts/Test-ServiceContext.ps1'
        $action = New-ScheduledTaskAction -Execute (Join-Path $PSHOME 'pwsh.exe') -Argument "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$worker`" -ConfigPath `"$configPath`" -ResultPath `"$resultPath`" -ModulePath `"$ModulePath`" -LocalChecksOnly"
        $principal = New-ScheduledTaskPrincipal -UserId 'S-1-5-19' -LogonType ServiceAccount -RunLevel Limited
        $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 3) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
        $null = Register-ScheduledTask -TaskName $name -TaskPath '\' -Action $action -Principal $principal -Settings $settings
        $registered = $true
        Start-ScheduledTask -TaskName $name -TaskPath '\'
        $timer = [Diagnostics.Stopwatch]::StartNew()
        while (-not (Test-Path $resultPath) -and $timer.Elapsed.TotalSeconds -lt 150) { Start-Sleep -Seconds 1 }
        if (-not (Test-Path $resultPath)) {
            if (Test-Path "$resultPath.progress.json") { Get-Content "$resultPath.progress.json" | Write-Host }
            throw 'Worker real nao concluiu em 150 segundos.'
        }
        $result = Get-Content $resultPath -Raw | ConvertFrom-Json
        if ($result.Success -ne $true -or $result.Identity -ne 'S-1-5-19' -or $result.Scope -ne 'Local' -or
            $result.Stage -ne 'completed' -or -not $result.ModuleVersion) { throw ($result | ConvertTo-Json) }
        Get-Content "$resultPath.log" | Write-Host
        Write-Host "PASS: worker real LOCAL SERVICE, $provider, assinatura SHA256, pastas e PnP $($result.ModuleVersion)."
        Stop-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $name -Confirm:$false
        $registered = $false
        Remove-Item -LiteralPath "Cert:\LocalMachine\My\$($cert.Thumbprint)" -DeleteKey
        $cert.Dispose(); $cert = $null
        foreach ($file in Get-ChildItem (Join-Path $root 'state') -File) { Remove-Item -LiteralPath $file.FullName }
    }
} finally {
    if ($registered) {
        Stop-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
    }
    if ($cert) { Remove-Item -LiteralPath "Cert:\LocalMachine\My\$($cert.Thumbprint)" -DeleteKey; $cert.Dispose() }
    if (Test-Path -LiteralPath $root) {
        $resolved = (Resolve-Path -LiteralPath $root).Path
        if ((Split-Path $resolved -Parent) -ne $parent -or (Split-Path $resolved -Leaf) -ne $name -or
            (Get-Item -LiteralPath $resolved).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Destino de limpeza invalido.' }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
