#requires -Version 5.1
<#
.SYNOPSIS
Instala e configura o SharePoint Version Cleanup.

.DESCRIPTION
Baixa os componentes publicados, registra um aplicativo Entra ID com certificado,
grava a configuracao local e cria tarefas semanais no Agendador do Windows.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$InstallPath = "$env:ProgramData\SharePointVersionCleanup",
    [string]$RepositoryRawUrl = 'https://raw.githubusercontent.com/JulioVicente/sharepoint-version-cleanup/main',
    [switch]$SkipEmailTest,
    [switch]$SkipAppRegistration
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$script:TaskPrefix = 'SharePoint Version Cleanup'
$script:TaskBackups = @{}
$script:NewTasks = [Collections.Generic.List[string]]::new()
$script:RequiredFiles = @(
    'scripts/cleanup-versions.ps1',
    'scripts/Send-EmailReport.ps1',
    'templates/email-template.html'
)

function Write-Step {
    param([string]$Message)
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Read-Default {
    param(
        [Parameter(Mandatory = $true)][string]$Prompt,
        [string]$Default,
        [switch]$Required
    )
    do {
        $suffix = if ($Default) { " [$Default]" } else { '' }
        $answer = Read-Host "$Prompt$suffix"
        if ([string]::IsNullOrWhiteSpace($answer)) { $answer = $Default }
    } while ($Required -and [string]::IsNullOrWhiteSpace($answer))
    return $answer
}

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-Environment {
    if ($env:OS -ne 'Windows_NT') { throw 'Este instalador e exclusivo para Windows.' }
    if (-not (Test-Administrator)) {
        throw 'Execute o PowerShell como Administrador e rode novamente o comando de instalacao.'
    }

    # PnP.PowerShell 3.x exige PowerShell 7.4 ou mais recente.
    if ($PSVersionTable.PSVersion -lt [version]'7.4.0') {
        throw @"
PowerShell 7.4 ou superior e necessario. Instale-o com:
  winget install --id Microsoft.PowerShell --source winget
Depois abra o PowerShell 7 como Administrador e execute novamente o instalador.
"@
    }
}

function Ensure-PnPModule {
    Write-Step 'Validando o PnP.PowerShell'
    $module = Get-Module -ListAvailable PnP.PowerShell |
        Sort-Object Version -Descending |
        Select-Object -First 1

    if (-not $module) {
        if ($PSCmdlet.ShouldProcess('PnP.PowerShell', 'Instalar modulo para todos os usuarios')) {
            Install-Module PnP.PowerShell -Scope AllUsers -Repository PSGallery -Force -AllowClobber
        }
    }
    Import-Module PnP.PowerShell -MinimumVersion 3.0.0 -Force
}

function Copy-ProjectFiles {
    param([string]$Destination)

    Write-Step 'Obtendo os componentes da solucao'
    foreach ($relativePath in $script:RequiredFiles) {
        $target = Join-Path $Destination ($relativePath -replace '/', '\')
        $targetDirectory = Split-Path -Parent $target
        
        # Garante que a pasta existe ANTES de tentar baixar
        New-Item -ItemType Directory -Path $targetDirectory -Force -ErrorAction Stop | Out-Null

        # Ao executar de um clone, prefira os arquivos locais. No one-liner, baixe-os.
        $localSource = if ($PSScriptRoot) {
            Join-Path $PSScriptRoot ($relativePath -replace '/', '\')
        } else { $null }

        if ($localSource -and (Test-Path -LiteralPath $localSource -PathType Leaf)) {
            Write-Host "  Usando arquivo local: $relativePath"
            Copy-Item -LiteralPath $localSource -Destination $target -Force
            continue
        }

        $uri = "$($RepositoryRawUrl.TrimEnd('/'))/$relativePath"
        $maxRetries = 3
        $retryCount = 0
        $retriesPerformed = 0
        $backoffSeconds = 2
        $downloaded = $false
        $lastErrorMessage = $null

        while (-not $downloaded -and $retryCount -lt $maxRetries) {
            try {
                Write-Host "  Baixando: $relativePath"
                $response = Invoke-WebRequest -UseBasicParsing -Uri $uri -OutFile $target -PassThru -TimeoutSec 30 -ErrorAction Stop
                if (-not $response) {
                    throw "Resposta vazia ao baixar $uri."
                }
                if (-not ($response.PSObject.Properties.Name -contains 'StatusCode')) {
                    throw "Nao foi possivel validar o codigo HTTP retornado por $uri."
                }
                $statusCode = [int]$response.StatusCode
                if ($statusCode -ne 200) {
                    throw "Servidor retornou HTTP $statusCode para $uri."
                }
                $downloaded = $true
                Write-Host "    OK: $relativePath (HTTP $statusCode)" -ForegroundColor Green
            } catch {
                $retryCount++
                $lastErrorMessage = $_.Exception.Message
                Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
                if ($retryCount -lt $maxRetries) {
                    $retriesPerformed++
                    Write-Host "    AVISO: Falha na tentativa $retryCount de ${maxRetries}: $lastErrorMessage" -ForegroundColor Yellow
                    Write-Host "    Nova tentativa em $backoffSeconds segundos..." -ForegroundColor Yellow
                    Start-Sleep -Seconds $backoffSeconds
                    $backoffSeconds = [Math]::Min($backoffSeconds * 2, 30)
                } else {
                    throw @"
Componente obrigatorio indisponivel: $uri
Tentativas totais: $retryCount de $maxRetries
Retries executados: $retriesPerformed
Ultimo erro: $lastErrorMessage

Teste a conectividade e o download manualmente em uma sessao do PowerShell:
  Test-NetConnection raw.githubusercontent.com -Port 443
  Invoke-WebRequest -Uri '$uri' -OutFile '$env:TEMP\$(Split-Path -Leaf $target)'

Se o acesso ao GitHub estiver bloqueado, execute o instalador a partir de um clone local do repositorio:
  git clone https://github.com/JulioVicente/sharepoint-version-cleanup.git
  pwsh -NoProfile -File .\Install.ps1
"@
                }
            }
        }
    }
}

function Register-CleanupApplication {
    param(
        [string]$Tenant,
        [string]$CertificateDirectory,
        [string]$AdminUrl,
        [string[]]$Sites
    )

    Write-Step 'Registrando o aplicativo no Microsoft Entra ID'
    New-Item -ItemType Directory -Path $CertificateDirectory -Force | Out-Null
    $existingThumbprints = @(Get-ChildItem Cert:\CurrentUser\My | ForEach-Object Thumbprint)
    $registration = Register-PnPEntraIDApp `
        -ApplicationName 'SharePoint Version Cleanup' `
        -Tenant $Tenant `
        -OutPath $CertificateDirectory `
        -Store CurrentUser `
        -DeviceLogin `
        -SharePointApplicationPermissions 'Sites.Selected'

    $clientId = $null
    foreach ($property in 'AzureAppId', 'ClientId', 'ApplicationId', 'AppId') {
        if ($registration.PSObject.Properties.Name -contains $property -and $registration.$property) {
            $clientId = [string]$registration.$property
            break
        }
    }
    if (-not $clientId) {
        $clientId = Read-Default -Prompt 'Client ID exibido pelo registro' -Required
    }

    $certificate = Get-ChildItem Cert:\CurrentUser\My |
        Where-Object { $_.Thumbprint -notin $existingThumbprints } |
        Sort-Object NotBefore -Descending |
        Select-Object -First 1
    if (-not $certificate) {
        throw 'O aplicativo foi criado, mas o certificado nao foi encontrado em Cert:\CurrentUser\My.'
    }

    # Sites.Selected nao concede acesso por si so. Um administrador concede
    # somente Write nos sites explicitamente informados durante a instalacao.
    Write-Step 'Concedendo acesso apenas aos sites configurados'
    $adminConnection = Connect-PnPOnline -Url $AdminUrl -Tenant $Tenant -ClientId $clientId -Interactive -ReturnConnection
    foreach ($site in $Sites) {
        Grant-PnPAzureADAppSitePermission -AppId $clientId -DisplayName 'SharePoint Version Cleanup' `
            -Permissions Write -Site $site -Connection $adminConnection | Out-Null
    }

    return @{ ClientId = $clientId; CertificateThumbprint = $certificate.Thumbprint }
}

function Protect-Secret {
    param([Security.SecureString]$Secret)
    if (-not $Secret -or $Secret.Length -eq 0) { return $null }
    return ConvertFrom-SecureString -SecureString $Secret
}

function New-Configuration {
    param([string]$Destination)

    Write-Step 'Configuracao interativa'
    $tenant = Read-Default -Prompt 'Dominio do tenant' -Default 'contoso.onmicrosoft.com' -Required
    $adminUrl = Read-Default -Prompt 'URL do SharePoint Admin' -Default "https://$($tenant.Split('.')[0])-admin.sharepoint.com" -Required
    $siteInput = Read-Default -Prompt 'Sites (URLs ou caminhos, separados por virgula)' -Required
    $sites = @($siteInput.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($sites.Count -eq 0) { throw 'Informe ao menos um site.' }

    $keepVersionsText = Read-Default -Prompt 'Quantidade de versoes a manter' -Default '10' -Required
    $keepVersions = 0
    if (-not [int]::TryParse($keepVersionsText, [ref]$keepVersions) -or $keepVersions -lt 1) {
        throw 'A quantidade de versoes deve ser um numero inteiro maior que zero.'
    }

    $smtpServer = Read-Default -Prompt 'Servidor SMTP (vazio desabilita emails)'
    $email = @{
        Enabled = -not [string]::IsNullOrWhiteSpace($smtpServer)
        SmtpServer = $smtpServer
        Port = 587
        UseSsl = $true
        From = $null
        To = @()
        UserName = $null
        EncryptedPassword = $null
    }
    if ($email.Enabled) {
        $portText = Read-Default -Prompt 'Porta SMTP' -Default '587'
        $email.Port = [int]$portText
        $email.From = Read-Default -Prompt 'Email remetente' -Required
        $email.To = @((Read-Default -Prompt 'Destinatarios, separados por virgula' -Default $email.From -Required).Split(',') | ForEach-Object { $_.Trim() })
        $email.UserName = Read-Default -Prompt 'Usuario SMTP' -Default $email.From
        $email.EncryptedPassword = Protect-Secret (Read-Host 'Senha SMTP (criptografada para o usuario atual)' -AsSecureString)
    }

    $auth = if ($SkipAppRegistration) {
        @{
            ClientId = Read-Default -Prompt 'Client ID do aplicativo existente' -Required
            CertificateThumbprint = Read-Default -Prompt 'Thumbprint do certificado existente' -Required
        }
    } else {
        Register-CleanupApplication -Tenant $tenant -CertificateDirectory (Join-Path $Destination 'certificates') `
            -AdminUrl $adminUrl -Sites $sites
    }

    return [ordered]@{
        SchemaVersion = 1
        Tenant = $tenant
        AdminUrl = $adminUrl
        Sites = $sites
        VersionsToKeep = $keepVersions
        Authentication = $auth
        Email = $email
        Paths = @{
            State = (Join-Path $Destination 'state')
            Logs = (Join-Path $Destination 'logs')
        }
    }
}

function Install-ScheduledTasks {
    param(
        [System.Collections.IDictionary]$Configuration,
        [string]$Destination
    )

    Write-Step 'Criando tarefas semanais'
    $days = @('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday')
    $pwsh = (Get-Command pwsh.exe -ErrorAction Stop).Source
    $cleanupScript = Join-Path $Destination 'scripts\cleanup-versions.ps1'
    $configPath = Join-Path $Destination 'config\config.json'
    Write-Host 'Informe a senha da conta atual para que as tarefas possam acessar o SharePoint mesmo sem sessao interativa.'
    $taskUser = "$env:USERDOMAIN\$env:USERNAME"
    $taskCredential = Get-Credential -UserName $taskUser -Message 'Credencial da conta que executara as tarefas'
    if ($taskCredential.UserName -ne $taskUser) {
        throw "Use a conta atual ($taskUser), pois o certificado e a senha SMTP estao protegidos para ela."
    }
    $passwordPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($taskCredential.Password)
    $taskPassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($passwordPointer)

    try {
        for ($index = 0; $index -lt $Configuration.Sites.Count; $index++) {
            $site = $Configuration.Sites[$index]
            $day = $days[$index % $days.Count]
            $taskName = "$script:TaskPrefix - {0:D2}" -f ($index + 1)
            # Instalacoes novas iniciam deliberadamente em simulacao. O operador
            # deve validar os relatorios antes de acrescentar -Apply.
            $arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$cleanupScript`" -ConfigPath `"$configPath`" -SiteUrl `"$site`""
            $action = New-ScheduledTaskAction -Execute $pwsh -Argument $arguments
            $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $day -At '10:00'
            $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 12)

            if ($PSCmdlet.ShouldProcess($taskName, "Agendar $site para $day as 10:00")) {
                $existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
                if ($existingTask) {
                    $script:TaskBackups[$taskName] = Export-ScheduledTask -TaskName $taskName
                } else {
                    $script:NewTasks.Add($taskName)
                }
                Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
                    -Settings $settings -Description "Limpeza de versoes: $site" `
                    -User $taskUser -Password $taskPassword -RunLevel Highest -Force | Out-Null
            }
        }
    } finally {
        if ($passwordPointer -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($passwordPointer)
        }
        $taskPassword = $null
    }
}

$installExisted = Test-Path -LiteralPath $InstallPath
$rollbackRoot = Join-Path ([IO.Path]::GetTempPath()) ("spvc-install-rollback-" + [guid]::NewGuid().ToString('N'))
try {
    Write-Host 'SharePoint Version Cleanup - Instalacao' -ForegroundColor Green
    Assert-Environment
    Ensure-PnPModule

    if ($PSCmdlet.ShouldProcess($InstallPath, 'Criar diretorio de instalacao')) {
        New-Item -ItemType Directory -Path $InstallPath -Force | Out-Null
        foreach ($folder in 'config', 'state', 'logs', 'certificates', 'scripts', 'templates') {
            New-Item -ItemType Directory -Path (Join-Path $InstallPath $folder) -Force | Out-Null
        }
    }

    if ($installExisted) {
        New-Item -ItemType Directory -Path $rollbackRoot -Force | Out-Null
        Copy-Item -LiteralPath $InstallPath -Destination (Join-Path $rollbackRoot 'previous') -Recurse -Force
    }
    Copy-ProjectFiles -Destination $InstallPath
    $configuration = New-Configuration -Destination $InstallPath
    $configPath = Join-Path $InstallPath 'config\config.json'
    $configuration | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $configPath -Encoding utf8
    Install-ScheduledTasks -Configuration $configuration -Destination $InstallPath

    if ($configuration.Email.Enabled -and -not $SkipEmailTest) {
        Write-Step 'Enviando email de teste'
        $emailScript = Join-Path $InstallPath 'scripts\Send-EmailReport.ps1'
        & $emailScript -ConfigPath $configPath -Test
    }

    Write-Host "`nInstalacao concluida em: $InstallPath" -ForegroundColor Green
    Write-Host "Configuracao: $configPath"
    Write-Host "Tarefas criadas com o prefixo: $script:TaskPrefix"
} catch {
    $originalError = $_.Exception.Message
    Write-Warning 'Falha detectada; revertendo arquivos e tarefas locais da instalacao.'
    foreach ($taskName in $script:NewTasks) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    }
    foreach ($entry in $script:TaskBackups.GetEnumerator()) {
        Register-ScheduledTask -TaskName $entry.Key -Xml $entry.Value -Force -ErrorAction SilentlyContinue | Out-Null
    }
    if ($installExisted -and (Test-Path -LiteralPath (Join-Path $rollbackRoot 'previous'))) {
        Remove-Item -LiteralPath $InstallPath -Recurse -Force -ErrorAction SilentlyContinue
        Copy-Item -LiteralPath (Join-Path $rollbackRoot 'previous') -Destination $InstallPath -Recurse -Force
    } elseif (-not $installExisted -and (Test-Path -LiteralPath $InstallPath)) {
        Remove-Item -LiteralPath $InstallPath -Recurse -Force -ErrorAction SilentlyContinue
    }
    throw "Instalacao interrompida e alteracoes locais revertidas: $originalError. O registro Entra/certificado pode exigir remocao administrativa manual."
} finally {
    Remove-Item -LiteralPath $rollbackRoot -Recurse -Force -ErrorAction SilentlyContinue
}
