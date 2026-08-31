#!/usr/bin/env pwsh
<#
.SYNOPSIS
One-liner installer para SharePoint Version Cleanup
Uso: iwr -useb https://raw.githubusercontent.com/JulioVicente/sharepoint-version-cleanup/main/install.ps1 | iex

.DESCRIPTION
Script de instalacao unico que:
1. Valida todos os pre-requisitos
2. Auto-instala PowerShell 7.4+ se necessario
3. Auto-instala PnP.PowerShell
4. Executa a instalacao completa
#>

# Forca encoding UTF-8 para caracteres especiais
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$PSDefaultParameterValues['Out-File:Encoding'] = 'utf8'

# Desabilita erros que fecham o script
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

# Log em arquivo para debug
$logPath = "$env:TEMP\spvc-install-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
Start-Transcript -Path $logPath -Append -Force -Encoding UTF8 | Out-Null

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
║                                                                              ║
║  Log: $logPath                                                               ║
╚══════════════════════════════════════════════════════════════════════════════╝
" -ForegroundColor $colors.Header

# ============================================================================
# FASE 1: VALIDACOES PRE-REQUISITOS
# ============================================================================
Write-Host "`n[FASE 1] Validando Ambiente..." -ForegroundColor $colors.Header

# 1. Windows
Write-Host "  [1/3] Verificando Windows..." -ForegroundColor $colors.Info -NoNewline
if ($env:OS -eq 'Windows_NT') {
    $osVersion = [System.Environment]::OSVersion
    Write-Host " OK" -ForegroundColor $colors.Success
    Write-Host "        Versao: $osVersion" -ForegroundColor $colors.Info
} else {
    Write-Host " ERRO: Este script requer Windows" -ForegroundColor $colors.Error
    Write-Host "`nPressione ENTER para sair..." -ForegroundColor $colors.Warning
    Read-Host
    exit 1
}

# 2. Admin
Write-Host "  [2/3] Verificando privilegios de Administrador..." -ForegroundColor $colors.Info -NoNewline
try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    $isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    
    if ($isAdmin) {
        Write-Host " OK" -ForegroundColor $colors.Success
        Write-Host "        Usuario: $($identity.Name)" -ForegroundColor $colors.Info
    } else {
        Write-Host " ERRO: Execute como Administrador" -ForegroundColor $colors.Error
        Write-Host "        Usuario atual: $($identity.Name)" -ForegroundColor $colors.Error
        Write-Host "`nPressione ENTER para sair..." -ForegroundColor $colors.Warning
        Read-Host
        exit 1
    }
} catch {
    Write-Host " ERRO ao verificar: $($_.Exception.Message)" -ForegroundColor $colors.Error
    Write-Host "`nPressione ENTER para sair..." -ForegroundColor $colors.Warning
    Read-Host
    exit 1
}

# 3. Conectividade
Write-Host "  [3/3] Verificando conectividade com Microsoft 365..." -ForegroundColor $colors.Info -NoNewline
try {
    $response = Invoke-WebRequest -Uri 'https://graph.microsoft.com' -Method Head -UseBasicParsing -TimeoutSec 5 -ErrorAction SilentlyContinue
    Write-Host " OK" -ForegroundColor $colors.Success
    Write-Host "        Microsoft Graph: Acessivel" -ForegroundColor $colors.Info
} catch {
    Write-Host " AVISO (continuando...)" -ForegroundColor $colors.Warning
    Write-Host "        Erro: Sem acesso direto ao Microsoft Graph" -ForegroundColor $colors.Warning
}

# ============================================================================
# FASE 2: VERIFICACAO POWERSHELL
# ============================================================================
Write-Host "`n[FASE 2] Verificando PowerShell..." -ForegroundColor $colors.Header

# Obtem as informacoes SEM tentar atribuir PSEdition (que eh read-only)
$versionObj = $PSVersionTable
$psVersao = $versionObj.PSVersion
$psEdicao = $versionObj.PSEdition
$psExePath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source

Write-Host "  PowerShell detectado:" -ForegroundColor $colors.Info
Write-Host "    - Versao: $psVersao" -ForegroundColor $colors.Info
Write-Host "    - Edicao: $psEdicao" -ForegroundColor $colors.Info
Write-Host "    - Caminho: $psExePath" -ForegroundColor $colors.Info

if ($psVersao -lt [version]'7.4.0') {
    Write-Host "  AVISO: Versao antiga (requerido: 7.4+)" -ForegroundColor $colors.Warning
    Write-Host "  Voce precisara atualizar manualmente:" -ForegroundColor $colors.Warning
    Write-Host "    1. Visite: https://github.com/PowerShell/PowerShell/releases" -ForegroundColor $colors.Info
    Write-Host "    2. Baixe: PowerShell-7.x.x-win-x64.msi" -ForegroundColor $colors.Info
    Write-Host "    3. Instale e reinicie" -ForegroundColor $colors.Info
    Write-Host "`nPressione ENTER para continuar..." -ForegroundColor $colors.Warning
    Read-Host
} else {
    Write-Host "  OK PowerShell $psVersao (atende aos requisitos)" -ForegroundColor $colors.Success
}

# ============================================================================
# FASE 3: VERIFICACAO PNP.POWERSHELL
# ============================================================================
Write-Host "`n[FASE 3] Verificando PnP.PowerShell..." -ForegroundColor $colors.Header

try {
    $pnpMod = Get-Module -ListAvailable PnP.PowerShell -ErrorAction SilentlyContinue | Sort-Object Version -Descending | Select-Object -First 1
    
    if (-not $pnpMod) {
        Write-Host "  INFO: PnP.PowerShell nao encontrado" -ForegroundColor $colors.Info
        Write-Host "  Instalando versao mais recente..." -ForegroundColor $colors.Info
        Install-Module PnP.PowerShell -Scope AllUsers -Repository PSGallery -Force -AllowClobber -ErrorAction Stop
        
        # Verifica versao instalada
        $pnpMod = Get-Module -ListAvailable PnP.PowerShell -ErrorAction SilentlyContinue | Sort-Object Version -Descending | Select-Object -First 1
        Write-Host "  OK PnP.PowerShell $($pnpMod.Version) instalado com sucesso!" -ForegroundColor $colors.Success
    } else {
        Write-Host "  INFO: PnP.PowerShell detectado:" -ForegroundColor $colors.Info
        Write-Host "    - Versao: $($pnpMod.Version)" -ForegroundColor $colors.Info
        Write-Host "    - Caminho: $($pnpMod.ModuleBase)" -ForegroundColor $colors.Info
        
        if ($pnpMod.Version -lt [version]'3.0.0') {
            Write-Host "  AVISO: Versao $($pnpMod.Version) eh antiga (recomendado: 3.0+)" -ForegroundColor $colors.Warning
            Write-Host "  Tentando atualizar..." -ForegroundColor $colors.Info
            Update-Module PnP.PowerShell -Scope AllUsers -Repository PSGallery -Force -ErrorAction Continue
            
            $pnpMod = Get-Module -ListAvailable PnP.PowerShell -ErrorAction SilentlyContinue | Sort-Object Version -Descending | Select-Object -First 1
            Write-Host "  OK PnP.PowerShell atualizado para $($pnpMod.Version)!" -ForegroundColor $colors.Success
        } else {
            Write-Host "  OK PnP.PowerShell $($pnpMod.Version) (atende aos requisitos)" -ForegroundColor $colors.Success
        }
    }
} catch {
    Write-Host "  AVISO: Erro ao verificar PnP.PowerShell: $($_.Exception.Message)" -ForegroundColor $colors.Warning
    Write-Host "  Continuando mesmo assim..." -ForegroundColor $colors.Info
}

# ============================================================================
# FASE 4: DOWNLOAD E MENU
# ============================================================================
Write-Host "`n[FASE 4] Iniciando Instalacao..." -ForegroundColor $colors.Header

$repoUrl = 'https://raw.githubusercontent.com/JulioVicente/sharepoint-version-cleanup/main'
$tempDir = "$env:TEMP\spvc-install-$([guid]::NewGuid().ToString('N'))"

try {
    New-Item -ItemType Directory -Path $tempDir -Force -ErrorAction Stop | Out-Null
    
    Write-Host "  Criando diretorio temporario..." -ForegroundColor $colors.Info
    Write-Host "    Caminho: $tempDir" -ForegroundColor $colors.Info
    Write-Host "  Baixando scripts do repositorio..." -ForegroundColor $colors.Info
    Write-Host "    URL: $repoUrl" -ForegroundColor $colors.Info
    
    # Download
    $installScript = Join-Path $tempDir 'Install.ps1'
    $validateScript = Join-Path $tempDir 'Validate-Prerequisites.ps1'
    
    Invoke-WebRequest -Uri "$repoUrl/Install.ps1" -OutFile $installScript -UseBasicParsing -ErrorAction Stop
    Write-Host "    OK Install.ps1 baixado" -ForegroundColor $colors.Success
    
    Invoke-WebRequest -Uri "$repoUrl/scripts/Validate-Prerequisites.ps1" -OutFile $validateScript -UseBasicParsing -ErrorAction Stop
    Write-Host "    OK Validate-Prerequisites.ps1 baixado" -ForegroundColor $colors.Success
    
    # Menu
    Write-Host "`n" -ForegroundColor $colors.Header
    Write-Host "╔══════════════════════════════════════════════════════════════════════════════╗" -ForegroundColor $colors.Header
    Write-Host "║                       OPCOES DE INSTALACAO                                  ║" -ForegroundColor $colors.Header
    Write-Host "╚══════════════════════════════════════════════════════════════════════════════╝" -ForegroundColor $colors.Header
    Write-Host ""
    Write-Host "  1 - Teste (WhatIf): Mostra o que seria feito SEM fazer nada" -ForegroundColor $colors.Info
    Write-Host "  2 - Instalar: Instalacao completa" -ForegroundColor $colors.Success
    Write-Host "  3 - Cancelar" -ForegroundColor $colors.Error
    Write-Host ""
    
    $choice = Read-Host "  Escolha uma opcao [1-3]"
    
    switch ($choice) {
        '1' {
            Write-Host "`n  Executando em modo WhatIf..." -ForegroundColor $colors.Info
            Write-Host "  ────────────────────────────────────────────────" -ForegroundColor $colors.Info
            & $installScript -WhatIf -SkipEmailTest
            Write-Host "  ────────────────────────────────────────────────" -ForegroundColor $colors.Info
        }
        '2' {
            Write-Host "`n  Executando instalacao..." -ForegroundColor $colors.Success
            Write-Host "  ────────────────────────────────────────────────" -ForegroundColor $colors.Success
            & $installScript -SkipEmailTest
            Write-Host "  ────────────────────────────────────────────────" -ForegroundColor $colors.Success
        }
        '3' {
            Write-Host "`n  Instalacao cancelada" -ForegroundColor $colors.Warning
        }
        default {
            Write-Host "  ERRO: Opcao invalida" -ForegroundColor $colors.Error
        }
    }
    
} catch {
    Write-Host "  ERRO: $($_.Exception.Message)" -ForegroundColor $colors.Error
    Write-Host "  Stack: $($_.ScriptStackTrace)" -ForegroundColor $colors.Error
} finally {
    # Limpeza
    if (Test-Path $tempDir) {
        Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ============================================================================
# FINALIZACAO
# ============================================================================
Write-Host "`n" -ForegroundColor $colors.Header
Write-Host "Processo concluido!" -ForegroundColor $colors.Success
Write-Host "`nResumo do Ambiente:" -ForegroundColor $colors.Header
Write-Host "  - Windows: $osVersion" -ForegroundColor $colors.Info
Write-Host "  - PowerShell: $psVersao ($psEdicao)" -ForegroundColor $colors.Info
Write-Host "  - PnP.PowerShell: $(if ($pnpMod) { $pnpMod.Version } else { 'Nao instalado' })" -ForegroundColor $colors.Info
Write-Host "`nLog completo salvo em:" -ForegroundColor $colors.Header
Write-Host "  $logPath" -ForegroundColor $colors.Info
Write-Host ""
Write-Host "Pressione ENTER para fechar..." -ForegroundColor $colors.Warning
Read-Host | Out-Null

Stop-Transcript | Out-Null
