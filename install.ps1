#!/usr/bin/env pwsh
<#
.SYNOPSIS
One-liner installer para SharePoint Version Cleanup
Uso: iwr -useb https://raw.githubusercontent.com/JulioVicente/sharepoint-version-cleanup/main/install.ps1 | iex

.DESCRIPTION
Script de instalação único que:
1. Valida todos os pré-requisitos
2. Auto-instala PowerShell 7.4+ se necessário
3. Auto-instala PnP.PowerShell
4. Executa a instalação completa
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# Cores
$colors = @{
    Header = 'Cyan'
    Success = 'Green'
    Warning = 'Yellow'
    Error = 'Red'
    Info = 'Blue'
}

Write-Host "
╔══════════════════════════════════════════════════════════════════════════════╗
║                  SharePoint Version Cleanup - Instalador                     ║
║                                                                              ║
║  OneLinr: iwr -useb https://raw.githubusercontent.com/JulioVicente/          ║
║           sharepoint-version-cleanup/main/install.ps1 | iex                  ║
╚══════════════════════════════════════════════════════════════════════════════╝
" -ForegroundColor $colors.Header

# ============================================================================
# FASE 1: VALIDAÇÕES PRÉ-REQUISITOS
# ============================================================================
Write-Host "`n📋 FASE 1: Validando Ambiente..." -ForegroundColor $colors.Header

$validations = @{}

# 1. Windows
Write-Host "  [1/3] Verificando Windows..." -ForegroundColor $colors.Info -NoNewline
if ($env:OS -eq 'Windows_NT') {
    Write-Host " ✅" -ForegroundColor $colors.Success
    $validations['Windows'] = $true
} else {
    Write-Host " ❌ ERRO: Este script requer Windows" -ForegroundColor $colors.Error
    exit 1
}

# 2. Admin
Write-Host "  [2/3] Verificando privilégios de Administrador..." -ForegroundColor $colors.Info -NoNewline
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host " ✅" -ForegroundColor $colors.Success
    $validations['Admin'] = $true
} else {
    Write-Host " ❌ ERRO: Execute como Administrador" -ForegroundColor $colors.Error
    exit 1
}

# 3. Conectividade
Write-Host "  [3/3] Verificando conectividade com Microsoft 365..." -ForegroundColor $colors.Info -NoNewline
try {
    $response = Invoke-WebRequest -Uri 'https://graph.microsoft.com' -Method Head -UseBasicParsing -TimeoutSec 5 -ErrorAction SilentlyContinue
    Write-Host " ✅" -ForegroundColor $colors.Success
    $validations['M365'] = $true
} catch {
    Write-Host " ⚠️  (Verificação falhou, mas continuando...)" -ForegroundColor $colors.Warning
    $validations['M365'] = $true
}

# ============================================================================
# FASE 2: ATUALIZAÇÃO POWERSHELL
# ============================================================================
Write-Host "`n📦 FASE 2: Verificando PowerShell..." -ForegroundColor $colors.Header

$psVersion = $PSVersionTable.PSVersion
if ($psVersion -lt [version]'7.4.0') {
    Write-Host "  ⚠️  PowerShell $psVersion detectado (requerido: 7.4+)" -ForegroundColor $colors.Warning
    Write-Host "  Iniciando atualização automática..." -ForegroundColor $colors.Info
    
    $wingetExists = $null -ne (Get-Command winget -ErrorAction SilentlyContinue)
    
    if ($wingetExists) {
        Write-Host "  Instalando PowerShell 7 via WinGet..." -ForegroundColor $colors.Info
        try {
            & winget install --id Microsoft.PowerShell --source winget --accept-source-agreements --accept-package-agreements -h 2>$null
            Write-Host "  ✅ PowerShell 7 instalado!" -ForegroundColor $colors.Success
            Write-Host "  ℹ️  Reinicie PowerShell e execute este comando novamente:`n" -ForegroundColor $colors.Warning
            Write-Host "     iwr -useb 'https://raw.githubusercontent.com/JulioVicente/sharepoint-version-cleanup/main/install.ps1' | iex" -ForegroundColor $colors.Info
            exit 0
        } catch {
            Write-Host "  ⚠️  Instalação via WinGet falhou, continuando..." -ForegroundColor $colors.Warning
        }
    } else {
        Write-Host "  ⚠️  WinGet não disponível. Download manual em:" -ForegroundColor $colors.Warning
        Write-Host "     https://github.com/PowerShell/PowerShell/releases" -ForegroundColor $colors.Info
    }
} else {
    Write-Host "  ✅ PowerShell $psVersion OK" -ForegroundColor $colors.Success
}

# ============================================================================
# FASE 3: INSTALAÇÃO AUTOMÁTICA DO PNP.POWERSHELL
# ============================================================================
Write-Host "`n📦 FASE 3: Verificando PnP.PowerShell..." -ForegroundColor $colors.Header

$pnpModule = Get-Module -ListAvailable PnP.PowerShell | Sort-Object Version -Descending | Select-Object -First 1

if (-not $pnpModule) {
    Write-Host "  ℹ️  PnP.PowerShell não encontrado, instalando..." -ForegroundColor $colors.Info
    try {
        Install-Module PnP.PowerShell -Scope AllUsers -Repository PSGallery -Force -AllowClobber -ErrorAction Stop
        Write-Host "  ✅ PnP.PowerShell instalado com sucesso!" -ForegroundColor $colors.Success
    } catch {
        Write-Host "  ❌ ERRO: $($_.Exception.Message)" -ForegroundColor $colors.Error
        exit 1
    }
} elseif ($pnpModule.Version -lt [version]'3.0.0') {
    Write-Host "  ⚠️  PnP.PowerShell $($pnpModule.Version) é antiga (recomendado: 3.0+)" -ForegroundColor $colors.Warning
    Write-Host "  Atualizando..." -ForegroundColor $colors.Info
    try {
        Update-Module PnP.PowerShell -Scope AllUsers -Repository PSGallery -Force -ErrorAction Stop
        Write-Host "  ✅ PnP.PowerShell atualizado!" -ForegroundColor $colors.Success
    } catch {
        Write-Host "  ⚠️  Versão existente será usada" -ForegroundColor $colors.Warning
    }
} else {
    Write-Host "  ✅ PnP.PowerShell $($pnpModule.Version) OK" -ForegroundColor $colors.Success
}

# ============================================================================
# FASE 4: DOWNLOAD E EXECUÇÃO DA INSTALAÇÃO COMPLETA
# ============================================================================
Write-Host "`n🚀 FASE 4: Iniciando Instalação..." -ForegroundColor $colors.Header

$repoUrl = 'https://raw.githubusercontent.com/JulioVicente/sharepoint-version-cleanup/main'
$tempDir = "$env:TEMP\spvc-install-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

try {
    # Download do script de instalação principal
    Write-Host "  Baixando instalador..." -ForegroundColor $colors.Info
    $installScript = Join-Path $tempDir 'Install.ps1'
    Invoke-WebRequest -Uri "$repoUrl/Install.ps1" -OutFile $installScript -UseBasicParsing
    
    # Download do script de validação
    $validateScript = Join-Path $tempDir 'Validate-Prerequisites.ps1'
    Invoke-WebRequest -Uri "$repoUrl/scripts/Validate-Prerequisites.ps1" -OutFile $validateScript -UseBasicParsing
    
    Write-Host "  ✅ Arquivos baixados com sucesso" -ForegroundColor $colors.Success
    
    # Executa validação
    Write-Host "`n  Executando validações..." -ForegroundColor $colors.Info
    & $validateScript
    
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  ❌ Validações falharam" -ForegroundColor $colors.Error
        exit 1
    }
    
    # Menu de opções
    Write-Host "`n" -ForegroundColor $colors.Header
    Write-Host "╔══════════════════════════════════════════════════════════════════════════════╗" -ForegroundColor $colors.Header
    Write-Host "║                       OPÇÕES DE INSTALAÇÃO                                  ║" -ForegroundColor $colors.Header
    Write-Host "╚══════════════════════════════════════════════════════════════════════════════╝" -ForegroundColor $colors.Header
    Write-Host "  1. ℹ️  Teste (WhatIf) - Mostra o que seria feito SEM fazer nada" -ForegroundColor $colors.Info
    Write-Host "  2. ✅ Instalar - Instalação completa" -ForegroundColor $colors.Success
    Write-Host "  3. ❌ Cancelar" -ForegroundColor $colors.Error
    Write-Host ""
    
    $choice = Read-Host "  Escolha uma opção [1-3]"
    
    switch ($choice) {
        '1' {
            Write-Host "`n  Executando em modo WhatIf..." -ForegroundColor $colors.Info
            & $installScript -WhatIf -SkipEmailTest
        }
        '2' {
            Write-Host "`n  Executando instalação..." -ForegroundColor $colors.Info
            & $installScript -SkipEmailTest
        }
        '3' {
            Write-Host "`n  Instalação cancelada" -ForegroundColor $colors.Warning
            exit 0
        }
        default {
            Write-Host "  ❌ Opção inválida" -ForegroundColor $colors.Error
            exit 1
        }
    }
    
} catch {
    Write-Host "  ❌ ERRO: $($_.Exception.Message)" -ForegroundColor $colors.Error
    exit 1
} finally {
    # Limpa arquivos temporários
    Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "`n✅ Processo concluído!" -ForegroundColor $colors.Success
