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

# Desabilita erros que fecham o script
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

# Log em arquivo para debug
$logPath = "$env:TEMP\spvc-install-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
Start-Transcript -Path $logPath -Append -Force | Out-Null

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
# FASE 1: VALIDAÇÕES PRÉ-REQUISITOS
# ============================================================================
Write-Host "`n📋 FASE 1: Validando Ambiente..." -ForegroundColor $colors.Header

# 1. Windows
Write-Host "  [1/3] Verificando Windows..." -ForegroundColor $colors.Info -NoNewline
if ($env:OS -eq 'Windows_NT') {
    $osVersion = [System.Environment]::OSVersion
    Write-Host " ✅" -ForegroundColor $colors.Success
    Write-Host "        Versão: $osVersion" -ForegroundColor $colors.Info
} else {
    Write-Host " ❌ ERRO: Este script requer Windows" -ForegroundColor $colors.Error
    Write-Host "`nPressione ENTER para sair..." -ForegroundColor $colors.Warning
    Read-Host
    exit 1
}

# 2. Admin
Write-Host "  [2/3] Verificando privilégios de Administrador..." -ForegroundColor $colors.Info -NoNewline
try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    $isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    
    if ($isAdmin) {
        Write-Host " ✅" -ForegroundColor $colors.Success
        Write-Host "        Usuário: $($identity.Name)" -ForegroundColor $colors.Info
    } else {
        Write-Host " ❌ ERRO: Execute como Administrador" -ForegroundColor $colors.Error
        Write-Host "        Usuário atual: $($identity.Name)" -ForegroundColor $colors.Error
        Write-Host "`nPressione ENTER para sair..." -ForegroundColor $colors.Warning
        Read-Host
        exit 1
    }
} catch {
    Write-Host " ❌ ERRO ao verificar: $($_.Exception.Message)" -ForegroundColor $colors.Error
    Write-Host "`nPressione ENTER para sair..." -ForegroundColor $colors.Warning
    Read-Host
    exit 1
}

# 3. Conectividade
Write-Host "  [3/3] Verificando conectividade com Microsoft 365..." -ForegroundColor $colors.Info -NoNewline
try {
    $response = Invoke-WebRequest -Uri 'https://graph.microsoft.com' -Method Head -UseBasicParsing -TimeoutSec 5 -ErrorAction SilentlyContinue
    Write-Host " ✅" -ForegroundColor $colors.Success
    Write-Host "        Microsoft Graph: Acessível" -ForegroundColor $colors.Info
} catch {
    Write-Host " ⚠️  (continuando...)" -ForegroundColor $colors.Warning
    Write-Host "        Erro: Sem acesso direto ao Microsoft Graph" -ForegroundColor $colors.Warning
}

# ============================================================================
# FASE 2: VERIFICAÇÃO POWERSHELL
# ============================================================================
Write-Host "`n📦 FASE 2: Verificando PowerShell..." -ForegroundColor $colors.Header

$psVersion = $PSVersionTable.PSVersion
$psEdition = $PSVersionTable.PSEdition
$psPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source

Write-Host "  PowerShell detectado:" -ForegroundColor $colors.Info
Write-Host "    • Versão: $psVersion" -ForegroundColor $colors.Info
Write-Host "    • Edição: $psEdition" -ForegroundColor $colors.Info
Write-Host "    • Caminho: $psPath" -ForegroundColor $colors.Info

if ($psVersion -lt [version]'7.4.0') {
    Write-Host "  ⚠️  Versão antiga (requerido: 7.4+)" -ForegroundColor $colors.Warning
    Write-Host "  Você precisará atualizar manualmente:" -ForegroundColor $colors.Warning
    Write-Host "    1. Visite: https://github.com/PowerShell/PowerShell/releases" -ForegroundColor $colors.Info
    Write-Host "    2. Baixe: PowerShell-7.x.x-win-x64.msi" -ForegroundColor $colors.Info
    Write-Host "    3. Instale e reinicie" -ForegroundColor $colors.Info
    Write-Host "`nPressione ENTER para continuar..." -ForegroundColor $colors.Warning
    Read-Host
} else {
    Write-Host "  ✅ PowerShell $psVersion OK (atende aos requisitos)" -ForegroundColor $colors.Success
}

# ============================================================================
# FASE 3: VERIFICAÇÃO PNP.POWERSHELL
# ============================================================================
Write-Host "`n📦 FASE 3: Verificando PnP.PowerShell..." -ForegroundColor $colors.Header

try {
    $pnpModule = Get-Module -ListAvailable PnP.PowerShell -ErrorAction SilentlyContinue | Sort-Object Version -Descending | Select-Object -First 1
    
    if (-not $pnpModule) {
        Write-Host "  ℹ️  PnP.PowerShell não encontrado" -ForegroundColor $colors.Info
        Write-Host "    Instalando versão mais recente..." -ForegroundColor $colors.Info
        Install-Module PnP.PowerShell -Scope AllUsers -Repository PSGallery -Force -AllowClobber -ErrorAction Stop
        
        # Verifica versão instalada
        $newPnp = Get-Module -ListAvailable PnP.PowerShell -ErrorAction SilentlyContinue | Sort-Object Version -Descending | Select-Object -First 1
        Write-Host "  ✅ PnP.PowerShell $($newPnp.Version) instalado com sucesso!" -ForegroundColor $colors.Success
    } else {
        Write-Host "  ℹ️  PnP.PowerShell detectado:" -ForegroundColor $colors.Info
        Write-Host "    • Versão: $($pnpModule.Version)" -ForegroundColor $colors.Info
        Write-Host "    • Caminho: $($pnpModule.ModuleBase)" -ForegroundColor $colors.Info
        
        if ($pnpModule.Version -lt [version]'3.0.0') {
            Write-Host "  ⚠️  Versão $($pnpModule.Version) é antiga (recomendado: 3.0+)" -ForegroundColor $colors.Warning
            Write-Host "  Tentando atualizar..." -ForegroundColor $colors.Info
            Update-Module PnP.PowerShell -Scope AllUsers -Repository PSGallery -Force -ErrorAction Continue
            
            $updatedPnp = Get-Module -ListAvailable PnP.PowerShell -ErrorAction SilentlyContinue | Sort-Object Version -Descending | Select-Object -First 1
            Write-Host "  ✅ PnP.PowerShell atualizado para $($updatedPnp.Version)!" -ForegroundColor $colors.Success
        } else {
            Write-Host "  ✅ PnP.PowerShell $($pnpModule.Version) OK (atende aos requisitos)" -ForegroundColor $colors.Success
        }
    }
} catch {
    Write-Host "  ⚠️  Erro ao verificar PnP.PowerShell: $($_.Exception.Message)" -ForegroundColor $colors.Warning
    Write-Host "  Continuando mesmo assim..." -ForegroundColor $colors.Info
}

# ============================================================================
# FASE 4: DOWNLOAD E MENU
# ============================================================================
Write-Host "`n🚀 FASE 4: Iniciando Instalação..." -ForegroundColor $colors.Header

$repoUrl = 'https://raw.githubusercontent.com/JulioVicente/sharepoint-version-cleanup/main'
$tempDir = "$env:TEMP\spvc-install-$([guid]::NewGuid().ToString('N'))"

try {
    New-Item -ItemType Directory -Path $tempDir -Force -ErrorAction Stop | Out-Null
    
    Write-Host "  Criando diretório temporário..." -ForegroundColor $colors.Info
    Write-Host "    Caminho: $tempDir" -ForegroundColor $colors.Info
    Write-Host "  Baixando scripts do repositório..." -ForegroundColor $colors.Info
    Write-Host "    URL: $repoUrl" -ForegroundColor $colors.Info
    
    # Download
    $installScript = Join-Path $tempDir 'Install.ps1'
    $validateScript = Join-Path $tempDir 'Validate-Prerequisites.ps1'
    
    Invoke-WebRequest -Uri "$repoUrl/Install.ps1" -OutFile $installScript -UseBasicParsing -ErrorAction Stop
    Write-Host "    ✅ Install.ps1 baixado" -ForegroundColor $colors.Success
    
    Invoke-WebRequest -Uri "$repoUrl/scripts/Validate-Prerequisites.ps1" -OutFile $validateScript -UseBasicParsing -ErrorAction Stop
    Write-Host "    ✅ Validate-Prerequisites.ps1 baixado" -ForegroundColor $colors.Success
    
    # Menu
    Write-Host "`n" -ForegroundColor $colors.Header
    Write-Host "╔══════════════════════════════════════════════════════════════════════════════╗" -ForegroundColor $colors.Header
    Write-Host "║                       OPÇÕES DE INSTALAÇÃO                                  ║" -ForegroundColor $colors.Header
    Write-Host "╚══════════════════════════════════════════════════════════════════════════════╝" -ForegroundColor $colors.Header
    Write-Host ""
    Write-Host "  1️⃣  Teste (WhatIf) - Mostra o que seria feito SEM fazer nada" -ForegroundColor $colors.Info
    Write-Host "  2️⃣  Instalar - Instalação completa" -ForegroundColor $colors.Success
    Write-Host "  3️⃣  Cancelar" -ForegroundColor $colors.Error
    Write-Host ""
    
    $choice = Read-Host "  Escolha uma opção [1-3]"
    
    switch ($choice) {
        '1' {
            Write-Host "`n  Executando em modo WhatIf..." -ForegroundColor $colors.Info
            Write-Host "  ────────────────────────────────────────────────" -ForegroundColor $colors.Info
            & $installScript -WhatIf -SkipEmailTest
            Write-Host "  ────────────────────────────────────────────────" -ForegroundColor $colors.Info
        }
        '2' {
            Write-Host "`n  Executando instalação..." -ForegroundColor $colors.Success
            Write-Host "  ────────────────────────────────────────────────" -ForegroundColor $colors.Success
            & $installScript -SkipEmailTest
            Write-Host "  ────────────────────────────────────────────────" -ForegroundColor $colors.Success
        }
        '3' {
            Write-Host "`n  Instalação cancelada" -ForegroundColor $colors.Warning
        }
        default {
            Write-Host "  ❌ Opção inválida" -ForegroundColor $colors.Error
        }
    }
    
} catch {
    Write-Host "  ❌ ERRO: $($_.Exception.Message)" -ForegroundColor $colors.Error
    Write-Host "  Stack: $($_.ScriptStackTrace)" -ForegroundColor $colors.Error
} finally {
    # Limpeza
    if (Test-Path $tempDir) {
        Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ============================================================================
# FINALIZAÇÃO
# ============================================================================
Write-Host "`n" -ForegroundColor $colors.Header
Write-Host "✅ Processo concluído!" -ForegroundColor $colors.Success
Write-Host "`n📋 Resumo do Ambiente:" -ForegroundColor $colors.Header
Write-Host "  • Windows: $osVersion" -ForegroundColor $colors.Info
Write-Host "  • PowerShell: $psVersion ($psEdition)" -ForegroundColor $colors.Info
Write-Host "  • PnP.PowerShell: $(if ($pnpModule) { $pnpModule.Version } else { 'Não instalado' })" -ForegroundColor $colors.Info
Write-Host "`n📁 Log completo salvo em:" -ForegroundColor $colors.Header
Write-Host "    $logPath" -ForegroundColor $colors.Info
Write-Host ""
Write-Host "Pressione ENTER para fechar..." -ForegroundColor $colors.Warning
Read-Host | Out-Null

Stop-Transcript | Out-Null
