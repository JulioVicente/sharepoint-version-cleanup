#requires -Version 7.4
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
    [string]$RepositoryRawUrl = 'https://raw.githubusercontent.com/JulioVicente/sharepoint-version-cleanup/v1.2.0',
    [switch]$SkipEmailTest,
    [switch]$SkipAppRegistration,
    [string]$AdminClientId
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
    'scripts/Configuration.ps1',
    'scripts/Resilience.ps1',
    'scripts/Sampling.ps1',
    'scripts/Get-DailyAudit.ps1',
    'scripts/Invoke-Pilot.ps1',
    'scripts/Enable-Production.ps1',
    'scripts/Validate-Prerequisites.ps1',
    'config/config.example.json',
    'CONFIGURATION.md',
    'QUICK_START.md',
    'TROUBLESHOOTING.md',
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
    [CmdletBinding(SupportsShouldProcess)]
    param()
    Write-Step '1 de 5 - Validando e instalando dependencias'
    $module = Get-Module -ListAvailable PnP.PowerShell |
        Sort-Object Version -Descending |
        Select-Object -First 1

    if (-not $module -or $module.Version -lt [version]'3.0.0') {
        if ($PSCmdlet.ShouldProcess('PnP.PowerShell', 'Instalar modulo para todos os usuarios')) {
            Install-Module PnP.PowerShell -MinimumVersion 3.0.0 -Scope AllUsers -Repository PSGallery -Force -AllowClobber
        }
    }
    Import-Module PnP.PowerShell -MinimumVersion 3.0.0 -Force
}

function Copy-ProjectFiles {
    param([string]$Destination)

    Write-Step 'Obtendo os componentes da solucao e verificando SHA256'
    $localManifest = Join-Path $PSScriptRoot 'release-manifest.json'
    $manifest = if (Test-Path -LiteralPath $localManifest) {
        Get-Content -LiteralPath $localManifest -Raw | ConvertFrom-Json -AsHashtable
    } else {
        Invoke-RestMethod -Uri "$($RepositoryRawUrl.TrimEnd('/'))/release-manifest.json" -TimeoutSec 60 | ConvertTo-Json -Depth 6 | ConvertFrom-Json -AsHashtable
    }
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
        $downloaded = $false

        while (-not $downloaded -and $retryCount -lt $maxRetries) {
            try {
                Write-Host "  Baixando: $relativePath"
                Invoke-WebRequest -UseBasicParsing -Uri $uri -OutFile $target -TimeoutSec 30 -ErrorAction Stop
                $downloaded = $true
                Write-Host "    OK: $relativePath" -ForegroundColor Green
            } catch {
                $retryCount++
                if ($retryCount -lt $maxRetries) {
                    Write-Host "    AVISO: Falha na tentativa $retryCount de $maxRetries. Aguardando 5 segundos..." -ForegroundColor Yellow
                    Start-Sleep -Seconds 5
                } else {
                    # Limpa arquivo parcial
                    Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
                    throw "Componente obrigatorio indisponivel apos $maxRetries tentativas: $uri. $($_.Exception.Message)"
                }
            }
        }
    }
    foreach ($relativePath in $script:RequiredFiles) {
        $target = Join-Path $Destination $relativePath
        if (-not $manifest.Files.ContainsKey($relativePath) -or
            (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ne $manifest.Files[$relativePath]) {
            throw "Integridade SHA256 invalida: $relativePath. Gere novamente o manifesto para alteracoes locais revisadas."
        }
    }
    $manifest | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $Destination 'release-manifest.json') -Encoding utf8
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
    $certificatePassword = Read-Host 'Senha para proteger o backup PFX do certificado' -AsSecureString
    if ($certificatePassword.Length -eq 0) { throw 'Informe uma senha para proteger o PFX.' }
    $registration = Register-PnPEntraIDApp `
        -ApplicationName 'SharePoint Version Cleanup' `
        -Tenant $Tenant `
        -OutPath $CertificateDirectory `
        -Store CurrentUser `
        -CertificatePassword $certificatePassword `
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
    if (-not $AdminClientId) {
        Write-Host 'As concessoes Sites.Selected exigem um aplicativo administrativo interativo com Microsoft Graph Sites.FullControl.All delegado.'
        if (Read-YesNo 'Deseja registrar esse aplicativo administrativo agora?') {
            $adminRegistration = Register-PnPEntraIDAppForInteractiveLogin -ApplicationName 'SharePoint Cleanup Setup Admin' `
                -Tenant $Tenant -GraphDelegatePermissions 'Sites.FullControl.All' -Interactive
            Write-Host 'Conclua o consentimento administrativo na janela aberta. Esse aplicativo sera usado somente na configuracao.'
        }
        $AdminClientId = Read-Validated -Prompt 'Client ID do aplicativo administrativo interativo' -Validate {
            param($v)
            $id = [guid]::Empty
            if (-not [guid]::TryParse($v,[ref]$id) -or $id -eq [guid]::Empty) { throw 'Informe um GUID valido.' }
            $id.ToString()
        }
    }
    $adminConnection = Connect-PnPOnline -Url $AdminUrl -Tenant $Tenant -ClientId $AdminClientId -Interactive -ReturnConnection
    foreach ($site in $Sites) {
        Grant-PnPEntraIDAppSitePermission -AppId $clientId -DisplayName 'SharePoint Version Cleanup' `
            -Permissions Write -Site $site -Connection $adminConnection | Out-Null
    }

    return @{ ClientId = $clientId; CertificateThumbprint = $certificate.Thumbprint }
}

function Protect-Secret {
    param([Security.SecureString]$Secret)
    if (-not $Secret -or $Secret.Length -eq 0) { return $null }
    return ConvertFrom-SecureString -SecureString $Secret
}

function Read-Validated {
    param([string]$Prompt, [string]$Default, [scriptblock]$Validate, [switch]$AllowEmpty)
    while ($true) {
        $answer = Read-Default -Prompt $Prompt -Default $Default -Required:(-not $AllowEmpty)
        try { return (& $Validate $answer) }
        catch { Write-Host "Vamos corrigir: $($_.Exception.Message)" -ForegroundColor Yellow }
    }
}

function Read-YesNo {
    param([string]$Prompt, [bool]$Default = $false)
    $fallback = if ($Default) { 'S' } else { 'N' }
    return (Read-Validated -Prompt "$Prompt (S/N)" -Default $fallback -Validate {
        param($answer)
        if ($answer -notmatch '^(s|sim|n|nao|não)$') { throw 'Digite S para sim ou N para nao.' }
        return $answer -match '^(s|sim)$'
    })
}

function New-Configuration {
    param([string]$Destination)
    Write-Step '2 de 5 - Vamos configurar o acesso e o escopo'
    Write-Host 'O acesso usa um aplicativo e um certificado da conta que executara as tarefas.'
    $tenant = Read-Validated -Prompt 'Dominio do tenant (ex.: empresa.onmicrosoft.com)' -Validate {
        param($v)
        if ($v -notmatch '^[a-zA-Z0-9][a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$') { throw 'Informe um dominio valido.' }
        $v
    }
    $adminUrl = Read-Validated -Prompt 'URL administrativa do SharePoint' -Default "https://$($tenant.Split('.')[0])-admin.sharepoint.com" -Validate { param($v) ConvertTo-SiteUrl $v }
    $sites = @(Read-Validated -Prompt 'URLs dos sites, separadas por virgula (para teste03 use a URL raiz do site)' -Validate {
        param($v)
        @($v.Split(',') | ForEach-Object { ConvertTo-SiteUrl $_.Trim() } | Select-Object -Unique)
    })
    $scopes = @{}
    foreach ($site in $sites) {
        Write-Host "Site: $site"
        Write-Host 'Informe o caminho da biblioteca/pasta, ex.: /teste03. Inclua o caminho do site quando houver.'
        if (Read-YesNo 'Limitar a uma biblioteca ou pasta?' -Default $true) {
            $scopes[$site] = Read-Validated -Prompt 'Caminho completo dentro do servidor' -Validate {
                param($v)
                ConvertTo-CleanupFolder -Value $v -SiteUrl $site
            }
        } else {
            if (-not (Read-YesNo 'Confirma que o escopo sera TODO este site?')) { throw 'Escopo nao confirmado. Reinicie o assistente.' }
            $scopes[$site] = ''
        }
    }
    $keep = Read-Validated -Prompt 'Versoes HISTORICAS a manter (a atual sempre e preservada)' -Default '10' -Validate {
        param($v)
        $n = 0
        if (-not [int]::TryParse($v,[ref]$n) -or $n -lt 1) { throw 'Use um inteiro maior que zero.' }
        $n
    }
    $minimumAge = Read-Validated -Prompt 'Idade minima das versoes, em dias (0 somente para piloto descartavel)' -Default '30' -Validate {
        param($v)
        $n=0
        if (-not [int]::TryParse($v,[ref]$n) -or $n -lt 0 -or $n -gt 36500) { throw 'Use um inteiro de 0 a 36500.' }
        $n
    }
    $maximumDeletes = Read-Validated -Prompt 'Limite de exclusoes por execucao' -Default '1000' -Validate {
        param($v)
        $n=0
        if (-not [int]::TryParse($v,[ref]$n) -or $n -lt 1 -or $n -gt 1000000) { throw 'Use um inteiro de 1 a 1000000.' }
        $n
    }
    $auditCopy = Read-Validated -Prompt 'Pasta externa/UNC para copiar auditoria (vazio desabilita)' -Default '' -AllowEmpty -Validate {
        param($v)
        if ($v -and -not [IO.Path]::IsPathFullyQualified($v)) { throw 'Use uma pasta absoluta ou UNC.' }
        $v
    }
    $sampling = @{Enabled=$true;SamplesPerLibrary=1;SizeWeight=1;RecencyWeight=4;RecencyHalfLifeDays=30}
    $sampling.Enabled = Read-YesNo 'Conferir uma amostra dos arquivos inalterados, priorizando maiores e recentes?' -Default $true
    if ($sampling.Enabled) {
        $sampling.SamplesPerLibrary = Read-Validated -Prompt 'Arquivos a conferir por biblioteca em cada execucao incremental' -Default '1' -Validate {
            param($v)
            $n=0
            if (-not [int]::TryParse($v,[ref]$n) -or $n -lt 1 -or $n -gt 1000) { throw 'Use um inteiro de 1 a 1000.' }
            $n
        }
    }
    $auth = @{}
    if ($SkipAppRegistration -or (Read-YesNo 'Ja possui um aplicativo com certificado para esta limpeza?')) {
        $auth.ClientId = Read-Validated -Prompt 'Client ID do aplicativo' -Validate {
            param($v)
            $id = [guid]::Empty
            if (-not [guid]::TryParse($v,[ref]$id) -or $id -eq [guid]::Empty) { throw 'Informe um GUID valido.' }
            $id.ToString()
        }
        $auth.CertificateThumbprint = Read-Validated -Prompt 'Thumbprint do certificado instalado para este usuario' -Validate {
            param($v)
            $v = $v.Replace(' ','')
            if ($v -notmatch '^[a-fA-F0-9]{40}$') { throw 'Use os 40 caracteres do thumbprint.' }
            $cert = Get-Item -LiteralPath "Cert:\CurrentUser\My\$v" -ErrorAction Stop
            if (-not $cert.HasPrivateKey -or $cert.NotAfter -le (Get-Date) -or $cert.NotBefore -gt (Get-Date)) { throw 'O certificado precisa estar valido e possuir chave privada.' }
            $v
        }
    } else {
        $auth = Register-CleanupApplication -Tenant $tenant -CertificateDirectory (Join-Path $Destination 'certificates') -AdminUrl $adminUrl -Sites $sites
    }
    $email = @{ Enabled = $false; SmtpServer = ''; Port = 587; UseSsl = $true; From = ''; To = @(); UserName = ''; EncryptedPassword = $null }
    if (Read-YesNo 'Deseja enviar os relatorios por email SMTP?') {
        $email.Enabled = $true
        $email.SmtpServer = Read-Default 'Servidor SMTP' -Required
        $email.Port = Read-Validated -Prompt 'Porta SMTP' -Default '587' -Validate {
            param($v)
            $n = 0
            if (-not [int]::TryParse($v,[ref]$n) -or $n -lt 1 -or $n -gt 65535) { throw 'Use uma porta entre 1 e 65535.' }
            $n
        }
        $email.From = Read-Validated -Prompt 'Email remetente' -Validate { param($v) ([Net.Mail.MailAddress]::new($v)).Address }
        $email.To = @(Read-Validated -Prompt 'Destinatarios separados por virgula' -Default $email.From -Validate {
            param($v)
            @($v.Split(',') | ForEach-Object { ([Net.Mail.MailAddress]::new($_.Trim())).Address })
        })
        if (Read-YesNo 'O servidor SMTP exige usuario e senha?' -Default $true) {
            $email.UserName = Read-Default 'Usuario SMTP' -Default $email.From -Required
            do { $secret = Read-Host 'Senha SMTP (nao sera exibida)' -AsSecureString } while ($secret.Length -eq 0)
            $email.EncryptedPassword = Protect-Secret $secret
        }
    }
    $frequency = Read-Validated -Prompt 'Periodicidade: diaria ou semanal' -Default 'semanal' -Validate {
        param($v)
        if ($v -notin 'diaria','semanal') { throw 'Digite diaria ou semanal.' }
        $v
    }
    $time = Read-Validated -Prompt 'Horario local da tarefa (HH:mm)' -Default '22:00' -Validate {
        param($v)
        if ($v -notmatch '^([01]\d|2[0-3]):[0-5]\d$') { throw 'Use HH:mm, por exemplo 22:00.' }
        $v
    }
    return [ordered]@{
        SchemaVersion = 2; Tenant = $tenant; AdminUrl = $adminUrl; Sites = $sites
        FolderScopes = $scopes; VersionsToKeep = $keep; Authentication = $auth; Email = $email
        Schedule = @{ Frequency = $frequency; Time = $time }
        Safety = @{ MinimumVersionAgeDays = $minimumAge; MaxVersionsPerRun = $maximumDeletes }
        Retry = @{ MaxRetries = 3; BaseDelaySeconds = 2; MaxDelaySeconds = 60 }
        Audit = @{ CopyDirectory = $auditCopy }; Sampling = $sampling
        Paths = @{ State = (Join-Path $Destination 'state'); Logs = (Join-Path $Destination 'logs') }
    }
}

function Invoke-SetupValidation {
    param([string]$ConfigPath)
    $config = Read-CleanupConfiguration $ConfigPath
    $installedCleanup = Join-Path (Split-Path (Split-Path $ConfigPath -Parent) -Parent) 'scripts/cleanup-versions.ps1'
    $approved = [Collections.Generic.List[string]]::new()
    Write-Step '3 de 5 - Conexao e simulacao'
    foreach ($site in $config.Sites) {
        $cleanupArguments = @{ ConfigPath = $ConfigPath; SiteUrl = $site; PassThru = $true }
        if ($config.FolderScopes[$site]) { $cleanupArguments.FolderServerRelativeUrl = $config.FolderScopes[$site] }
        Write-Host "Site: $site | Pasta: $($config.FolderScopes[$site]) | Historico mantido: $($config.VersionsToKeep)"
        if (-not (Read-YesNo 'Executar a simulacao agora?' -Default $true)) {
            throw 'A simulacao e obrigatoria antes de agendar. A instalacao sera revertida.'
        }
        while ($true) {
            try {
                $report = & $installedCleanup @args
                break
            } catch {
                Write-Host "Nao foi possivel concluir: $($_.Exception.Message)" -ForegroundColor Yellow
                Write-Host "Revise consentimento, certificado, acesso e configuracao em: $ConfigPath"
                if (-not (Read-YesNo 'Apos corrigir, deseja tentar novamente?')) { throw }
            }
        }
        Show-CleanupSummary $report
        Write-Step '4 de 5 - Aprovar o piloto'
        if ($report.VersionsEligible -gt 0 -and $report.FilesSkipped -eq 0 -and
            (Read-YesNo 'Aprova excluir as versoes antigas neste escopo para validar o piloto? A exclusao e permanente')) {
            $cleanupArguments.Apply = $true
            $applied = & $installedCleanup @args
            Show-CleanupSummary $applied
            if ($applied.Success -and $applied.VersionsDeleted -gt 0 -and $applied.FilesSkipped -eq 0 -and
                (Read-YesNo 'Piloto aprovado. Ativar execucoes incrementais agendadas neste escopo?')) {
                $approved.Add($site)
            }
        } else {
            Write-Host 'Este escopo sera agendado em simulacao. Sem exclusoes elegiveis, crie historico no piloto antes de promover.'
        }
    }
    return $approved.ToArray()
}

function Show-CleanupSummary {
    param($Report)
    Write-Host "Arquivos analisados: $($Report.FilesProcessed); sem alteracao: $($Report.FilesUnchanged); ignorados: $($Report.FilesSkipped)"
    Write-Host "Versoes elegiveis: $($Report.VersionsEligible); excluidas: $($Report.VersionsDeleted)"
    Write-Host ('Espaco estimado: {0:N2} MB; liberado: {1:N2} MB' -f ($Report.BytesEligible / 1MB), ($Report.BytesFreed / 1MB))
    Write-Host "Relatorio: $($Report.ReportPath)"
    foreach ($warning in $Report.Warnings) { Write-Warning $warning }
}
function Install-ScheduledTasks {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [System.Collections.IDictionary]$Configuration,
        [string]$Destination,
        [string[]]$ProductionSites = @()
    )

    Write-Step '5 de 5 - Criando tarefas agendadas'
    $days = @('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday')
    $pwsh = (Get-Command pwsh.exe -ErrorAction Stop).Source
    $cleanupScript = Join-Path $Destination 'scripts\cleanup-versions.ps1'
    $configPath = Join-Path $Destination 'config\config.json'
    Write-Host 'Informe a senha da conta atual para que as tarefas possam acessar o SharePoint mesmo sem sessao interativa.'
    $taskUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $taskCredential = Get-Credential -UserName $taskUser -Message 'Credencial da conta que executara as tarefas'
    if (-not $taskCredential) { throw 'Credencial das tarefas nao informada.' }
    $script:TaskCredential = $taskCredential
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
            if ($Configuration.FolderScopes[$site]) { $arguments += " -FolderServerRelativeUrl `"$($Configuration.FolderScopes[$site])`"" }
            if ($site -in $ProductionSites) { $arguments += ' -Apply' }
            $action = New-ScheduledTaskAction -Execute $pwsh -Argument $arguments
            $trigger = if ($Configuration.Schedule.Frequency -eq 'diaria') {
                New-ScheduledTaskTrigger -Daily -At $Configuration.Schedule.Time
            } else { New-ScheduledTaskTrigger -Weekly -DaysOfWeek $day -At $Configuration.Schedule.Time }
            $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew `
                -ExecutionTimeLimit (New-TimeSpan -Hours 12) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 15)

            if ($PSCmdlet.ShouldProcess($taskName, "Agendar $site as $($Configuration.Schedule.Time)")) {
                $existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
                if ($existingTask) {
                    if ($existingTask.State -eq 'Running') { throw "A tarefa $taskName esta em execucao. Aguarde antes de atualizar." }
                    if (@($existingTask.Actions).Count -ne 1 -or
                        $existingTask.Actions[0].Arguments -notlike "*`"$configPath`"*") {
                        throw "A tarefa $taskName pertence a outra configuracao. Escolha nomes/destino sem conflito."
                    }
                    $script:TaskBackups[$taskName] = Export-ScheduledTask -TaskName $taskName
                } else {
                    $script:NewTasks.Add($taskName)
                }
                Register-ScheduledTask -TaskName $taskName -TaskPath '\' -Action $action -Trigger $trigger `
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

# A dry run must not import/install modules, prompt, write files or register apps.
if (-not $PSCmdlet.ShouldProcess($InstallPath, 'Instalar arquivos, configurar aplicativo e agendar simulacoes')) { return }
Assert-Environment
$InstallPath = [IO.Path]::GetFullPath($InstallPath).TrimEnd('\')
if ($InstallPath -eq [IO.Path]::GetPathRoot($InstallPath).TrimEnd('\') -or
    $InstallPath -eq [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')) {
    throw 'Escolha uma pasta dedicada de instalacao, diferente da raiz do disco e do codigo fonte.'
}
# Back up only files owned by the installer. Never delete the user's whole folder.
$rollbackRoot = Join-Path ([IO.Path]::GetTempPath()) ('spvc-install-' + [guid]::NewGuid().ToString('N'))
$managedFiles = @($script:RequiredFiles) + @('config/config.json', 'release-manifest.json')
$backups = @{}
$written = [Collections.Generic.List[string]]::new()
$script:TaskCredential = $null
try {
    Ensure-PnPModule
    New-Item -ItemType Directory -Path $rollbackRoot -Force | Out-Null
    foreach ($relative in $managedFiles) {
        $target = Join-Path $InstallPath $relative
        if (Test-Path -LiteralPath $target) {
            $backup = Join-Path $rollbackRoot ([guid]::NewGuid().ToString('N'))
            Copy-Item -LiteralPath $target -Destination $backup
            $backups[$target] = $backup
        }
    }
    foreach ($relative in $managedFiles) { $written.Add((Join-Path $InstallPath $relative)) }
    Copy-ProjectFiles -Destination $InstallPath
    . (Join-Path $InstallPath 'scripts/Configuration.ps1')
    $configuration = New-Configuration -Destination $InstallPath
    $configPath = Join-Path $InstallPath 'config/config.json'
    $configuration | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $configPath -Encoding utf8
    $null = Read-CleanupConfiguration $configPath
    foreach ($folder in 'state','logs') {
        New-Item -ItemType Directory -Path (Join-Path $InstallPath $folder) -Force | Out-Null
    }
    $cert = Get-Item -LiteralPath "Cert:\CurrentUser\My\$($configuration.Authentication.CertificateThumbprint)"
    if (-not $cert.HasPrivateKey -or $cert.NotAfter -le (Get-Date) -or $cert.NotBefore -gt (Get-Date)) {
        throw 'Certificado sem chave privada ou fora da validade.'
    }
    $productionSites = @(Invoke-SetupValidation -ConfigPath $configPath)
    Install-ScheduledTasks -Configuration $configuration -Destination $InstallPath -ProductionSites $productionSites
    if ($configuration.Email.Enabled -and -not $SkipEmailTest) {
        & (Join-Path $InstallPath 'scripts/Send-EmailReport.ps1') -ConfigPath $configPath -Test
    }
    Write-Host "Instalacao concluida em $InstallPath. Escopos em producao: $($productionSites.Count); restantes em simulacao." -ForegroundColor Green
} catch {
    $originalError = $_
    foreach ($taskName in $script:NewTasks) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Continue
    }
    foreach ($entry in $script:TaskBackups.GetEnumerator()) {
        if ($script:TaskCredential) {
            Register-ScheduledTask -TaskName $entry.Key -Xml $entry.Value -Force `
                -User $script:TaskCredential.UserName -Password $script:TaskCredential.GetNetworkCredential().Password -ErrorAction Continue | Out-Null
        }
    }
    foreach ($target in $written) {
        if ($backups.ContainsKey($target)) {
            Copy-Item -LiteralPath $backups[$target] -Destination $target -Force -ErrorAction Continue
        } else {
            Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
        }
    }
    Write-Warning 'Instalacao interrompida. Registro Entra, certificado e modulo instalado podem exigir revisao administrativa.'
    throw $originalError
} finally {
    $script:TaskCredential = $null
    # Only the exact per-file backups and our empty temporary directory are removed.
    foreach ($backup in $backups.Values) { Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $rollbackRoot) { Remove-Item -LiteralPath $rollbackRoot -ErrorAction SilentlyContinue }
}
