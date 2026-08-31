#requires -Version 5.1
<#
.SYNOPSIS
Valida todos os pré-requisitos para executar SharePoint Version Cleanup.

.DESCRIPTION
Verifica:
- Windows (versão)
- PowerShell 7.4+
- Privilégios de Administrador
- Conectividade com Microsoft 365
- PnP.PowerShell disponível
- Espaço em disco
- Certificados existentes
- Acesso ao site SharePoint

.EXAMPLE
& .\scripts\Validate-Prerequisites.ps1
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

Write-Host "
╔══════════════════════════════════════════════════════════════════════════════╗
║   SharePoint Version Cleanup - Validação de Pré-requisitos                  ║
║   BestSoft - teste03                                                        ║
╚══════════════════════════════════════════════════════════════════════════════╝
" -ForegroundColor Cyan

$validationResults = @()

# ============================================================================
# 1. SISTEMA OPERACIONAL
# ============================================================================
Write-Host "`n[1/8] Validando Sistema Operacional..." -ForegroundColor Yellow

$osCheck = if ($env:OS -eq 'Windows_NT') {
    $osVersion = [System.Environment]::OSVersion.VersionString
    Write-Host "  ✅ Windows detectado: $osVersion" -ForegroundColor Green
    $true
} else {
    Write-Host "  ❌ ERRO: Este script requer Windows (OS=$env:OS)" -ForegroundColor Red
    $false
}
$validationResults += $osCheck

# ============================================================================
# 2. PRIVILÉGIOS DE ADMINISTRADOR
# ============================================================================
Write-Host "`n[2/8] Validando Privilégios de Administrador..." -ForegroundColor Yellow

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
$isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

$adminCheck = if ($isAdmin) {
    Write-Host "  ✅ Executando como Administrador" -ForegroundColor Green
    $true
} else {
    Write-Host "  ❌ ERRO: Execute PowerShell como Administrador" -ForegroundColor Red
    $false
}
$validationResults += $adminCheck

# ============================================================================
# 3. POWERSHELL 7.4+
# ============================================================================
Write-Host "`n[3/8] Validando PowerShell 7.4+..." -ForegroundColor Yellow

$psVersion = $PSVersionTable.PSVersion
$pwshCheck = if ($psVersion -ge [version]'7.4.0') {
    Write-Host "  ✅ PowerShell $psVersion (requerido: 7.4+)" -ForegroundColor Green
    $true
} else {
    Write-Host "  ❌ ERRO: PowerShell $psVersion detectado (requerido: 7.4+)" -ForegroundColor Red
    Write-Host "    Instale com: winget install --id Microsoft.PowerShell --source winget" -ForegroundColor Yellow
    $false
}
$validationResults += $pwshCheck

# ============================================================================
# 4. CONECTIVIDADE COM MICROSOFT 365
# ============================================================================
Write-Host "`n[4/8] Validando Conectividade com Microsoft 365..." -ForegroundColor Yellow

$m365Check = try {
    $response = Invoke-WebRequest -Uri 'https://graph.microsoft.com' -Method Head -UseBasicParsing -TimeoutSec 5 -ErrorAction SilentlyContinue
    if ($response.StatusCode -eq 200) {
        Write-Host "  ✅ Conectividade com Microsoft Graph OK" -ForegroundColor Green
        $true
    } else {
        Write-Host "  ⚠️  Resposta inesperada: $($response.StatusCode)" -ForegroundColor Yellow
        $true
    }
} catch {
    Write-Host "  ❌ ERRO: Sem conectividade com Microsoft 365" -ForegroundColor Red
    Write-Host "    Verifique firewall, proxy ou DNS" -ForegroundColor Yellow
    $false
}
$validationResults += $m365Check

# ============================================================================
# 5. MÓDULO PNP.POWERSHELL
# ============================================================================
Write-Host "`n[5/8] Validando PnP.PowerShell..." -ForegroundColor Yellow

$pnpModule = Get-Module -ListAvailable PnP.PowerShell | Sort-Object Version -Descending | Select-Object -First 1

$pnpCheck = if ($pnpModule) {
    if ($pnpModule.Version -ge [version]'3.0.0') {
        Write-Host "  ✅ PnP.PowerShell $($pnpModule.Version) instalado" -ForegroundColor Green
        $true
    } else {
        Write-Host "  ⚠️  PnP.PowerShell $($pnpModule.Version) detectado (recomendado: 3.0+)" -ForegroundColor Yellow
        $true
    }
} else {
    Write-Host "  ℹ️  PnP.PowerShell não está instalado" -ForegroundColor Cyan
    Write-Host "    Iniciando instalação automática..." -ForegroundColor Yellow
    
    try {
        Write-Host "    Instalando PnP.PowerShell para todos os usuários..." -ForegroundColor Cyan
        Install-Module PnP.PowerShell -Scope AllUsers -Repository PSGallery -Force -AllowClobber -ErrorAction Stop
        Write-Host "  ✅ PnP.PowerShell instalado com sucesso!" -ForegroundColor Green
        $true
    } catch {
        Write-Host "  ❌ ERRO: Falha ao instalar PnP.PowerShell" -ForegroundColor Red
        Write-Host "    Erro: $($_.Exception.Message)" -ForegroundColor Red
        $false
    }
}
$validationResults += $pnpCheck

# ============================================================================
# 6. ESPAÇO EM DISCO
# ============================================================================
Write-Host "`n[6/8] Validando Espaço em Disco..." -ForegroundColor Yellow

$programDataDrive = ([System.IO.DriveInfo]::GetDrives() | Where-Object { $_.Name -eq 'C:\' })
$freeMB = [math]::Round($programDataDrive.AvailableFreeSpace / 1MB)
$requiredMB = 500

$diskCheck = if ($freeMB -gt $requiredMB) {
    Write-Host "  ✅ Espaço disponível: $freeMB MB (requerido: $requiredMB MB)" -ForegroundColor Green
    $true
} else {
    Write-Host "  ⚠️  Espaço limitado: $freeMB MB (requerido: $requiredMB MB)" -ForegroundColor Yellow
    $true
}
$validationResults += $diskCheck

# ============================================================================
# 7. PERMISSÕES EM PROGRAMDATA
# ============================================================================
Write-Host "`n[7/8] Validando Permissões em %ProgramData%..." -ForegroundColor Yellow

$programDataPath = "$env:ProgramData\SharePointVersionCleanup"
$permissionsCheck = try {
    $testPath = "$env:ProgramData\spvc-perm-test-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $testPath -Force | Out-Null
    Remove-Item -Path $testPath -Force -ErrorAction SilentlyContinue
    Write-Host "  ✅ Permissões OK em %ProgramData%" -ForegroundColor Green
    $true
} catch {
    Write-Host "  ❌ ERRO: Sem permissão de escrita em %ProgramData%" -ForegroundColor Red
    Write-Host "    Execute como Administrador ou ajuste permissões" -ForegroundColor Yellow
    $false
}
$validationResults += $permissionsCheck

# ============================================================================
# 8. CERTIFICADOS DISPONÍVEIS
# ============================================================================
Write-Host "`n[8/8] Validando Certificados..." -ForegroundColor Yellow

$certs = @(Get-ChildItem Cert:\CurrentUser\My -ErrorAction SilentlyContinue)
if ($certs.Count -gt 0) {
    Write-Host "  ℹ️  $($certs.Count) certificado(s) encontrado(s) em Cert:\CurrentUser\My" -ForegroundColor Cyan
    $certs | ForEach-Object {
        $status = if ($_.NotAfter -gt (Get-Date)) { "✅ Válido" } else { "❌ Expirado" }
        Write-Host "     $status - $($_.Subject) (Expira: $($_.NotAfter.ToString('dd/MM/yyyy')))" -ForegroundColor Gray
    }
    $certificateCheck = $true
} else {
    Write-Host "  ℹ️  Nenhum certificado encontrado (será criado durante o registro)" -ForegroundColor Cyan
    $certificateCheck = $true
}
$validationResults += $certificateCheck

# ============================================================================
# RESUMO FINAL
# ============================================================================
Write-Host "`n" -ForegroundColor Cyan
Write-Host "╔══════════════════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║                              RESUMO FINAL                                   ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan

$passCount = ($validationResults | Measure-Object -Sum).Sum
$totalCount = $validationResults.Count

Write-Host "`n✅ Validações Aprovadas: $passCount/$totalCount`n" -ForegroundColor Green

if ($passCount -eq $totalCount) {
    Write-Host "🎯 AMBIENTE PRONTO PARA INSTALAÇÃO!" -ForegroundColor Green
    Write-Host "`nPróximos passos:" -ForegroundColor Cyan
    Write-Host "  1. Download do Install.ps1"
    Write-Host "  2. Inspecione o arquivo"
    Write-Host "  3. Execute com -WhatIf (dry-run)"
    Write-Host "  4. Execute a instalação real`n" -ForegroundColor White
    Write-Host "Comandos recomendados:" -ForegroundColor Cyan
    Write-Host "  `$RepositoryUrl = 'https://raw.githubusercontent.com/JulioVicente/sharepoint-version-cleanup/main'" -ForegroundColor Gray
    Write-Host "  Invoke-WebRequest -Uri `"`$RepositoryUrl/Install.ps1`" -OutFile `"`$env:TEMP\Install.ps1`"" -ForegroundColor Gray
    Write-Host "  & `"`$env:TEMP\Install.ps1`" -WhatIf -SkipEmailTest" -ForegroundColor Gray
    Write-Host "  & `"`$env:TEMP\Install.ps1`" -SkipEmailTest" -ForegroundColor Gray
    exit 0
} else {
    Write-Host "⚠️  CORREÇÕES NECESSÁRIAS ANTES DE INSTALAR" -ForegroundColor Yellow
    Write-Host "`nResolva os erros acima e execute este script novamente." -ForegroundColor Yellow
    exit 1
}
