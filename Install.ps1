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
    'scripts/Enable-Production.ps1',
    'scripts/Invoke-Pilot.ps1',
    'templates/email-template.html',
    'config/config.example.json'
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

function New-NoCacheHeaders {
    return @{
        'Cache-Control' = 'no-cache, no-store, must-revalidate'
        'Pragma' = 'no-cache'
        'Expires' = '0'
    }
}

function Get-RepositoryRawBaseUrl {
    $trimmedUrl = $RepositoryRawUrl.TrimEnd('/')
    if ($trimmedUrl -match '^(https://raw\.githubusercontent\.com/[^/]+/[^/]+)(?:/[^/]+(?:/.*)?)?$') {
        return $Matches[1]
    }

    return $trimmedUrl
}

function Get-RepositoryBranchCandidates {
    $trimmedUrl = $RepositoryRawUrl.TrimEnd('/')
    $branches = [Collections.Generic.List[string]]::new()
    if ($trimmedUrl -match '^https://raw\.githubusercontent\.com/[^/]+/[^/]+/([^/]+)(?:/.*)?$') {
        $configuredBranch = $Matches[1]
        if (-not [string]::IsNullOrWhiteSpace($configuredBranch)) {
            $branches.Add($configuredBranch)
        }
    }

    foreach ($branch in 'main', 'master') {
        if ($branch -notin $branches) {
            $branches.Add($branch)
        }
    }

    return @($branches)
}

function Test-RemoteUrlAvailable {
    param([Parameter(Mandatory = $true)][string]$Uri)

    foreach ($method in 'Head', 'Get') {
        $headers = New-NoCacheHeaders
        if ($method -eq 'Get') {
            $headers['Range'] = 'bytes=0-0'
        }

        try {
            Invoke-WebRequest -UseBasicParsing -Uri $Uri -Method $method -Headers $headers -SkipHeaderValidation -TimeoutSec 20 -ErrorAction Stop | Out-Null
            return $true
        } catch {
            Write-Host "    $method indisponivel para: $Uri ($($_.Exception.Message))" -ForegroundColor DarkYellow
        }
    }

    return $false
}

function Resolve-RequiredFileRemoteUrl {
    param([Parameter(Mandatory = $true)][string]$RelativePath)

    $baseUrl = Get-RepositoryRawBaseUrl
    $attemptedBranches = [Collections.Generic.List[string]]::new()
    foreach ($branch in Get-RepositoryBranchCandidates) {
        $attemptedBranches.Add($branch)
        $candidateUrl = '{0}/{1}/{2}' -f $baseUrl.TrimEnd('/'), $branch, $RelativePath
        Write-Host "  Verificando componente remoto: $RelativePath (branch '$branch')" -ForegroundColor DarkCyan
        if (Test-RemoteUrlAvailable -Uri $candidateUrl) {
            Write-Host "    Resolvido: $candidateUrl" -ForegroundColor Green
            return [pscustomobject]@{
                RelativePath      = $RelativePath
                Branch            = $branch
                Uri               = $candidateUrl
                AttemptedBranches = @($attemptedBranches)
            }
        }
    }

    throw "Componente obrigatorio remoto indisponivel: $RelativePath. Branches testadas: $($attemptedBranches -join ', ')."
}

function Assert-PreparedFile {
    param(
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$TargetPath,
        [Parameter(Mandatory = $true)][string]$SourceDescription
    )

    if (-not (Test-Path -LiteralPath $TargetPath -PathType Leaf)) {
        throw "Falha ao preparar o componente obrigatorio '$RelativePath' a partir de ${SourceDescription}: arquivo nao encontrado em $TargetPath."
    }

    $item = Get-Item -LiteralPath $TargetPath -ErrorAction Stop
    if ($item.Length -le 0) {
        throw "Falha ao preparar o componente obrigatorio '$RelativePath' a partir de ${SourceDescription}: arquivo vazio em $TargetPath."
    }
}

function Save-RequiredFileFromRepository {
    param(
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    $resolved = Resolve-RequiredFileRemoteUrl -RelativePath $RelativePath
    $target = Join-Path $Destination ($RelativePath -replace '/', '\')
    $targetDirectory = Split-Path -Parent $target
    New-Item -ItemType Directory -Path $targetDirectory -Force -ErrorAction Stop | Out-Null
    Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue

    $maxRetries = 3
    for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
        try {
            Write-Host "  Baixando componente obrigatorio: $RelativePath" -ForegroundColor DarkCyan
            Invoke-WebRequest -UseBasicParsing -Uri $resolved.Uri -Headers (New-NoCacheHeaders) -SkipHeaderValidation -OutFile $target -TimeoutSec 30 -ErrorAction Stop
            Assert-PreparedFile -RelativePath $RelativePath -TargetPath $target -SourceDescription "$($resolved.Uri) (branch $($resolved.Branch))"
            Write-Host "    OK: $RelativePath <- $($resolved.Uri)" -ForegroundColor Green
            return $target
        } catch {
            Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
            if ($attempt -ge $maxRetries) {
                throw "Falha ao baixar o componente obrigatorio '$RelativePath' de $($resolved.Uri) (branch $($resolved.Branch)) apos $maxRetries tentativas: $($_.Exception.Message)"
            }

            Write-Host "    AVISO: tentativa $attempt de $maxRetries falhou para $RelativePath. Repetindo em 5 segundos..." -ForegroundColor Yellow
            Start-Sleep -Seconds 5
        }
    }
}

function Copy-ProjectFiles {
    param([string]$Destination)

    Write-Step 'Obtendo os componentes da solucao'
    foreach ($relativePath in $script:RequiredFiles) {
        $target = Join-Path $Destination ($relativePath -replace '/', '\')
        $targetDirectory = Split-Path -Parent $target
        New-Item -ItemType Directory -Path $targetDirectory -Force -ErrorAction Stop | Out-Null

        $localSource = if ($PSScriptRoot) {
            Join-Path $PSScriptRoot ($relativePath -replace '/', '\')
        } else { $null }

        if ($localSource -and (Test-Path -LiteralPath $localSource -PathType Leaf)) {
            Write-Host "  Usando arquivo local: $relativePath"
            Copy-Item -LiteralPath $localSource -Destination $target -Force
            Assert-PreparedFile -RelativePath $relativePath -TargetPath $target -SourceDescription $localSource
            continue
        }

        try {
            Save-RequiredFileFromRepository -RelativePath $relativePath -Destination $Destination | Out-Null
        } catch {
            throw "Falha ao preparar o componente obrigatorio '$relativePath': $($_.Exception.Message)"
        }
    }
}

function Assert-InstalledRequiredFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$RelativePath
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Componente obrigatorio da instalacao ausente: $RelativePath. A etapa de obtencao remota nao concluiu com sucesso para $Path."
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
    Assert-InstalledRequiredFile -Path $cleanupScript -RelativePath 'scripts/cleanup-versions.ps1'
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

function Invoke-Installer {
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
            Assert-InstalledRequiredFile -Path $emailScript -RelativePath 'scripts/Send-EmailReport.ps1'
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
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-Installer
}
