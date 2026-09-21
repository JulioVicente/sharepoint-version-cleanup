#requires -Version 7.4.6
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
    [string]$RepositoryRawUrl = 'https://raw.githubusercontent.com/JulioVicente/sharepoint-version-cleanup/v1.4.1',
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
$script:WizardDefaults = @{}
$script:WizardDefaultsPath = $null
$script:RequiredFiles = @(
    'scripts/cleanup-versions.ps1',
    'scripts/Send-EmailReport.ps1',
    'scripts/Configuration.ps1',
    'scripts/Diagnostics.ps1',
    'scripts/Progress.ps1',
    'scripts/TaskIdentity.ps1',
    'scripts/Test-ServiceContext.ps1',
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
    if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') { throw '[SPVC-POLICY] A politica da maquina restringe o PowerShell. Solicite liberacao administrativa para executar este instalador em FullLanguage.' }
    if (-not (Test-Administrator)) {
        throw 'Execute o PowerShell como Administrador e rode novamente o comando de instalacao.'
    }

    # PnP.PowerShell 3.x exige PowerShell 7.4.6 ou mais recente.
    if ($PSVersionTable.PSVersion -lt [version]'7.4.6') {
        throw @"
PowerShell 7.4.6 ou superior e necessario. Instale-o com:
  winget install --id Microsoft.PowerShell --source winget
Depois abra o PowerShell 7 como Administrador e execute novamente o instalador.
"@
    }
}

function Ensure-PnPModule {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    Write-Step '1 de 5 - Validando e instalando dependencias'
    if ($PSCmdlet.ShouldProcess('PnP.PowerShell', 'Preparar modulo para todos os usuarios')) {
        Ensure-CleanupModule -Name PnP.PowerShell -MinimumVersion 3.0.0 -InstallVersion 3.0.0
    }
}

function Ensure-CleanupModule {
    param([string]$Name, [version]$MinimumVersion, [string]$InstallVersion)
    $sharedModuleRoot = Join-Path $env:ProgramFiles 'PowerShell\Modules'
    # A customized PSModulePath must not hide the modules from the installer.
    if ($sharedModuleRoot -notin ($env:PSModulePath -split [IO.Path]::PathSeparator)) {
        $env:PSModulePath = "$sharedModuleRoot$([IO.Path]::PathSeparator)$env:PSModulePath"
    }
    $builtInModuleRoot = Join-Path $PSHOME 'Modules'
    if ($builtInModuleRoot -notin ($env:PSModulePath -split [IO.Path]::PathSeparator)) {
        $env:PSModulePath = "$builtInModuleRoot$([IO.Path]::PathSeparator)$env:PSModulePath"
    }
    $module = Get-Module -ListAvailable $Name | Where-Object {
        $_.ModuleBase.StartsWith("$sharedModuleRoot\", [StringComparison]::OrdinalIgnoreCase) -and
        $_.Version -ge $MinimumVersion -and $_.Version.Major -eq $MinimumVersion.Major -and (!$_.PowerShellVersion -or $_.PowerShellVersion -le $PSVersionTable.PSVersion)
    } | Sort-Object Version -Descending | Select-Object -First 1
    try {
        if (-not $module) {
            # PSResourceGet ships with PowerShell 7.4; it needs neither NuGet bootstrap nor PowerShellGet.
            Import-Module Microsoft.PowerShell.PSResourceGet -ErrorAction Stop
            $repository = Get-PSResourceRepository -Name PSGallery -ErrorAction SilentlyContinue
            if (-not $repository) { Register-PSResourceRepository -PSGallery -ErrorAction Stop }
            elseif ($repository.Uri.AbsoluteUri.TrimEnd('/') -ne 'https://www.powershellgallery.com/api/v2') {
                throw 'PSGallery aponta para um endereco diferente do oficial. Revise Get-PSResourceRepository.'
            }
            Install-PSResource -Name $Name -Version $InstallVersion -Scope AllUsers -Repository PSGallery -TrustRepository -Quiet -ErrorAction Stop
            $module = Get-Module -ListAvailable $Name | Where-Object {
                $_.ModuleBase.StartsWith("$sharedModuleRoot\", [StringComparison]::OrdinalIgnoreCase) -and $_.Version -eq [version]$InstallVersion
            } | Select-Object -First 1
            if (-not $module) { throw "Instalacao nao disponibilizou $Name $InstallVersion em $sharedModuleRoot." }
        }
        # Import the shared manifest, never a same-name CurrentUser module.
        Import-Module -Name $module.Path -Force -ErrorAction Stop
    } catch {
        throw [InvalidOperationException]::new("[SPVC-DEPENDENCY] Falha ao preparar $Name para todos os usuarios. PowerShell: $($PSVersionTable.PSVersion); destino: $sharedModuleRoot. Verifique acesso HTTPS a powershellgallery.com, proxy/TLS, espaco em disco e permissao administrativa. Se houver conflito de assemblies, execute bootstrap.ps1 em um novo processo. Erro original: $($_.Exception.Message)", $_.Exception)
    }
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
function Get-CleanupTenantContext {
    param([string]$SiteUrl)
    $siteUri = [uri]$SiteUrl
    try {
        $tenantId = [guid](Get-PnPTenantId -TenantUrl $siteUri.Host -ErrorAction Stop)
        if ($tenantId -eq [guid]::Empty) { throw 'Tenant nao identificado.' }
        $tenant = $tenantId.ToString()
        Write-Host "Tenant identificado pelo SharePoint: $tenant"
    } catch {
        Write-Warning 'Nao foi possivel identificar o tenant pela URL. Informe o dominio ou ID para continuar.'
        $tenant = Read-Validated -PreferenceKey Tenant -Prompt 'Dominio ou ID do tenant' -Validate {
            param($v)
            $id = [guid]::Empty
            if ([guid]::TryParse($v, [ref]$id) -and $id -ne [guid]::Empty) { return $id.ToString() }
            if ($v -notmatch '^[a-zA-Z0-9][a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$') { throw 'Informe um dominio ou GUID valido.' }
            $v
        }
    }
    $adminUrl = if ($siteUri.Host -match '^([a-zA-Z0-9-]+?)(?:-admin)?\.sharepoint\.com$') {
        "https://$($Matches[1])-admin.sharepoint.com"
    } else {
        Read-Validated -PreferenceKey AdminUrl -Prompt 'URL administrativa do SharePoint' -Validate { param($v) ConvertTo-SiteUrl $v }
    }
    Write-Host "URL administrativa: $adminUrl"
    return @{ Tenant = $tenant; AdminUrl = $adminUrl }
}

function Invoke-SetupGraph {
    param([string]$Path, [string]$Method = 'GET', [hashtable]$Body)
    $request = @{ Uri = "https://graph.microsoft.com/v1.0/$Path"; Method = $Method; OutputType = 'Hashtable'; ErrorAction = 'Stop' }
    if ($Body) { $request.Body = ($Body | ConvertTo-Json -Depth 20); $request.ContentType = 'application/json' }
    Invoke-CleanupActivity -Message 'Consultando Microsoft 365...' -Action { Invoke-MgGraphRequest @request }
}

function Get-SetupGraphCollection {
    param([string]$Path)
    do {
        $page = Invoke-SetupGraph -Path $Path
        foreach ($item in $page.value) { $item }
        $next = $page['@odata.nextLink']
        if ($next) {
            if (-not $next.StartsWith('https://graph.microsoft.com/v1.0/')) { throw 'Paginacao Graph inesperada.' }
            $Path = $next.Substring('https://graph.microsoft.com/v1.0/'.Length)
        }
    } while ($next)
}

function Connect-CleanupSetup {
    param([string]$Tenant)
    Ensure-CleanupModule -Name Microsoft.Graph.Authentication -MinimumVersion 2.0.0 -InstallVersion 2.25.0
    $login = @{ TenantId = $Tenant; Scopes = @('Application.ReadWrite.All','Sites.FullControl.All','User.Read'); ContextScope = 'Process'; NoWelcome = $true; ErrorAction = 'Stop' }
    if ($AdminClientId) { $login.ClientId = $AdminClientId }
    Connect-MgGraph @login | Out-Null
}

function Find-CleanupApplication {
    $apps = @(Get-SetupGraphCollection -Path 'applications?$filter=displayName%20eq%20%27SharePoint%20Version%20Cleanup%27&$select=id,appId,displayName')
    if ($apps.Count -eq 0) { return $null }
    $index = 0
    if ($apps.Count -gt 1) {
        Write-Warning 'Ha mais de um aplicativo com esse nome. Selecione o correto.'
        for ($i = 0; $i -lt $apps.Count; $i++) { Write-Host "$($i + 1): $($apps[$i].displayName) | $($apps[$i].appId)" }
        $index = (Read-Validated -Prompt 'Numero do aplicativo' -Validate {
            param($v)
            $n = 0
            if (-not [int]::TryParse($v, [ref]$n) -or $n -lt 1 -or $n -gt $apps.Count) { throw 'Escolha um numero da lista.' }
            $n
        }) - 1
    }
    Invoke-SetupGraph -Path ('applications/{0}?$select=id,appId,displayName,keyCredentials,requiredResourceAccess' -f $apps[$index].id)
}

function ConvertTo-CleanupUtcDate {
    param($Value)
    if ($Value -is [datetimeoffset]) { return $Value.UtcDateTime }
    if ($Value -is [datetime]) {
        if ($Value.Kind -eq [DateTimeKind]::Unspecified) { return [datetime]::SpecifyKind($Value, [DateTimeKind]::Utc) }
        return $Value.ToUniversalTime()
    }
    return [datetimeoffset]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AssumeUniversal).UtcDateTime
}

function Resolve-CleanupCertificate {
    param([hashtable]$Application, [string]$CertificateDirectory)
    $now = Get-Date
    $nowUtc = $now.ToUniversalTime()
    $thumbprints = @($Application.keyCredentials | Where-Object {
        $_.type -eq 'AsymmetricX509Cert' -and $_.usage -eq 'Verify' -and $_.customKeyIdentifier -and
        (ConvertTo-CleanupUtcDate $_.startDateTime) -le $nowUtc -and (ConvertTo-CleanupUtcDate $_.endDateTime) -gt $nowUtc
    } | ForEach-Object { [Convert]::ToHexString([Convert]::FromBase64String($_.customKeyIdentifier)) })
    $certificate = Get-ChildItem Cert:\CurrentUser\My,Cert:\LocalMachine\My | Where-Object {
        $_.Thumbprint -in $thumbprints -and $_.HasPrivateKey -and $_.NotAfter.ToUniversalTime() -gt $nowUtc -and $_.NotBefore.ToUniversalTime() -le $nowUtc
    } | Sort-Object NotAfter -Descending | Select-Object -First 1
    if ($certificate) {
        Write-Host 'Certificado local associado ao aplicativo identificado automaticamente.'
        return $certificate
    }
    Write-Warning 'Nenhum certificado local utilizavel foi encontrado. Um novo certificado sera associado ao aplicativo.'
    # A PATCH replaces the collection. Refuse to erase a credential whose key was not returned.
    $keys = @($Application.keyCredentials)
    foreach ($key in $keys) {
        if (-not $key.key) { throw 'Graph nao retornou uma chave existente. Nao e seguro atualizar os certificados automaticamente.' }
    }
    do {
        $password = Read-Host 'Senha para proteger o backup PFX do novo certificado' -AsSecureString
        if ($password.Length -eq 0) { Write-Warning 'Informe uma senha para proteger o PFX.' }
    } while ($password.Length -eq 0)
    New-Item -ItemType Directory -Path $CertificateDirectory -Force | Out-Null
    $certificate = New-SelfSignedCertificate -Subject "CN=SharePoint Version Cleanup $($Application.appId)" `
        -CertStoreLocation 'Cert:\CurrentUser\My' -KeyAlgorithm RSA -KeyLength 2048 -HashAlgorithm SHA256 `
        -KeySpec Signature -KeyExportPolicy Exportable -NotBefore $now.AddMinutes(-5) -NotAfter $now.AddYears(1)
    $backupBase = Join-Path $CertificateDirectory $certificate.Thumbprint
    Export-PfxCertificate -Cert $certificate -FilePath "$backupBase.pfx" -Password $password -ErrorAction Stop | Out-Null
    Export-Certificate -Cert $certificate -FilePath "$backupBase.cer" -ErrorAction Stop | Out-Null
    $keys += @{
        type = 'AsymmetricX509Cert'; usage = 'Verify'; keyId = [guid]::NewGuid().ToString()
        displayName = 'SharePoint Version Cleanup'
        key = [Convert]::ToBase64String($certificate.RawData)
        customKeyIdentifier = [Convert]::ToBase64String($certificate.GetCertHash())
        startDateTime = $certificate.NotBefore.ToUniversalTime().ToString('o')
        endDateTime = $certificate.NotAfter.ToUniversalTime().ToString('o')
    }
    $null = Invoke-SetupGraph -Path "applications/$($Application.id)" -Method PATCH -Body @{ keyCredentials = $keys }
    return $certificate
}

function Confirm-CleanupCertificateRegistration {
    param([string]$ApplicationObjectId, [string]$Thumbprint)
    for ($attempt = 1; $attempt -le 4; $attempt++) {
        $registered = Invoke-SetupGraph -Path ('applications/{0}?$select=appId,keyCredentials' -f $ApplicationObjectId)
        $found = @($registered.keyCredentials | Where-Object {
            $_['key'] -and $_.type -eq 'AsymmetricX509Cert' -and $_.usage -eq 'Verify' -and
            [Convert]::ToHexString([Security.Cryptography.SHA1]::HashData([Convert]::FromBase64String($_.key))) -eq $Thumbprint
        })
        if ($found.Count -gt 0) {
            Write-Host "Certificado $Thumbprint confirmado no registro do aplicativo."
            return
        }
        if ($attempt -lt 4) { Start-Sleep -Seconds 2 }
    }
    throw "Certificado $Thumbprint nao confirmado no aplicativo apos a gravacao. Revise Certificados e segredos; conceder consentimento de API nao corrige uma chave ausente."
}

function Connect-CleanupSite {
    param([string]$SiteUrl, [string]$Tenant, [hashtable]$Authentication, [string]$FolderServerRelativeUrl,
        [ValidateRange(1,12)][int]$MaxAttempts = 6, [ValidateRange(0,30)][int]$DelaySeconds = 10)
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            $connection = Invoke-CleanupActivity -Message 'Conectando ao SharePoint...' -Action {
                Connect-PnPOnline -Url $SiteUrl -Tenant $Tenant -ClientId $Authentication.ClientId `
                    -Thumbprint $Authentication.CertificateThumbprint -ReturnConnection -ErrorAction Stop
            }
            Invoke-CleanupActivity -Message 'Validando acesso as bibliotecas...' -Action {
                $null = Get-PnPWeb -Connection $connection -ErrorAction Stop
                $null = Get-CleanupLibraries -SiteUrl $SiteUrl -FolderServerRelativeUrl $FolderServerRelativeUrl -Connection $connection
            }
            return $connection
        } catch {
            if ($_.Exception.Message -notmatch 'AADSTS700027' -or $attempt -eq $MaxAttempts) { throw }
            Write-Warning "O servico de autenticacao ainda nao reconheceu a chave. Nova tentativa $($attempt + 1) de $MaxAttempts em $DelaySeconds segundos, usando o mesmo certificado."
            Invoke-CleanupActivity -Message 'Aguardando propagacao do certificado...' -Action { Start-Sleep -Seconds $DelaySeconds }
        }
    }
}

function Set-CleanupApplicationPermissions {
    param([hashtable]$Application, [switch]$EnableGraphMail)
    $required = @($Application.requiredResourceAccess)
    $specs = @(@{ AppId = '00000003-0000-0ff1-ce00-000000000000'; Role = 'Sites.Selected' })
    if ($EnableGraphMail) { $specs += @{ AppId = '00000003-0000-0000-c000-000000000000'; Role = 'Mail.Send' } }
    $changed = $false
    foreach ($spec in $specs) {
        $providers = @(Get-SetupGraphCollection -Path ("servicePrincipals?`$filter=appId%20eq%20%27$($spec.AppId)%27&`$select=appId,appRoles"))
        $role = @($providers.appRoles | Where-Object { $_.value -eq $spec.Role -and 'Application' -in $_.allowedMemberTypes -and $_.isEnabled })
        if ($role.Count -ne 1) { throw "Permissao de aplicativo nao encontrada: $($spec.Role)." }
        $resource = @($required | Where-Object resourceAppId -EQ $spec.AppId)
        if ($resource.Count -eq 0) {
            $entry = @{ resourceAppId = $spec.AppId; resourceAccess = @() }
            $required += $entry
        } else { $entry = $resource[0] }
        if (-not @($entry.resourceAccess | Where-Object { $_.id -eq $role[0].id -and $_.type -eq 'Role' }).Count) {
            $entry.resourceAccess = @($entry.resourceAccess) + @{ id = $role[0].id; type = 'Role' }
            $changed = $true
        }
    }
    if ($changed) {
        $null = Invoke-SetupGraph -Path "applications/$($Application.id)" -Method PATCH -Body @{ requiredResourceAccess = $required }
        Write-Host 'Permissoes configuradas. Conceda consentimento administrativo na pagina de permissoes do aplicativo:'
        Write-Host "https://entra.microsoft.com/#view/Microsoft_AAD_RegisteredApps/ApplicationMenuBlade/~/CallAnAPI/appId/$($Application.appId)"
        $null = Read-Host 'Depois de conceder o consentimento administrativo, pressione Enter para validar o acesso'
    }
}

function Test-SetupGraphNotFound {
    param([Management.Automation.ErrorRecord]$Record)
    if ($Record.Exception.PSObject.Properties['Response'] -and $Record.Exception.Response -and
        $Record.Exception.Response.PSObject.Properties['StatusCode']) {
        return [int]$Record.Exception.Response.StatusCode -eq 404
    }
    if ($Record.ErrorDetails -and $Record.ErrorDetails.Message) {
        try {
            $details = $Record.ErrorDetails.Message | ConvertFrom-Json -AsHashtable
            if ($details['error'] -and $details['error']['code'] -eq 'itemNotFound') { return $true }
        } catch { }
    }
    return $Record.Exception.Message -match 'HTTP/[\d.]+\s+404\b'
}

function Resolve-CleanupSiteInput {
    param([string]$Url)
    $inputUrl = ConvertTo-SiteUrl $Url
    $uri = [uri]$inputUrl
    $originalPath = $uri.AbsolutePath.TrimEnd('/')
    $candidatePath = $originalPath
    while ($true) {
        $endpoint = if ($candidatePath) { "sites/$($uri.Host):$candidatePath" } else { "sites/$($uri.Host)" }
        try {
            $target = Invoke-SetupGraph -Path $endpoint
        } catch {
            # Only a confirmed 404 permits trying an ancestor. Never turn 403/network failures into scope changes.
            if (-not (Test-SetupGraphNotFound $_)) { throw }
            if (-not $candidatePath) { throw "Site nao encontrado em $inputUrl. Confira a URL e o acesso da conta autenticada." }
            $candidatePath = $candidatePath.Substring(0, $candidatePath.LastIndexOf('/'))
            continue
        }
        if (-not $target['id']) { throw 'A consulta Graph nao retornou um site valido.' }
        $siteUrl = "https://$($uri.Host)$candidatePath"
        $folder = if ($candidatePath -ne $originalPath) {
            ConvertTo-CleanupFolder -Value ([uri]::UnescapeDataString($originalPath)) -SiteUrl $siteUrl
        } else { '' }
        if ($folder) { Write-Warning "A URL informada nao e um site. Site identificado: $siteUrl; escopo restrito a biblioteca/pasta: $folder." }
        return @{ SiteUrl = $siteUrl; Folder = $folder }
    }
}

function Test-CleanupFolderAccess {
    param([string]$SiteUrl, [string]$Folder)
    $folderPath = ConvertTo-CleanupFolder -Value $Folder -SiteUrl $SiteUrl
    $uri = [uri]$SiteUrl
    $endpoint = if ($uri.AbsolutePath -eq '/') { "sites/$($uri.Host)" } else { "sites/$($uri.Host):$($uri.AbsolutePath)" }
    $site = Invoke-SetupGraph -Path $endpoint
    $drives = @(Get-SetupGraphCollection -Path "sites/$($site.id)/drives")
    foreach ($drive in $drives) {
        $driveUri = [uri]$drive.webUrl
        if ($driveUri.Host -ne $uri.Host) { continue }
        $libraryPath = [uri]::UnescapeDataString($driveUri.AbsolutePath).TrimEnd('/')
        if ($folderPath -ne $libraryPath -and -not $folderPath.StartsWith("$libraryPath/", [StringComparison]::OrdinalIgnoreCase)) { continue }
        $relative = $folderPath.Substring($libraryPath.Length).TrimStart('/')
        $itemPath = "drives/$($drive.id)/root"
        if ($relative) { $itemPath += ':/' + (($relative.Split('/') | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/') }
        $item = Invoke-SetupGraph -Path $itemPath
        if (-not $item.ContainsKey('folder') -or $null -eq $item['folder']) { throw 'O caminho informado representa um arquivo, nao uma biblioteca/pasta.' }
        Write-Host "Biblioteca/pasta validada no SharePoint: $folderPath"
        return $folderPath
    }
    throw "Biblioteca/pasta nao encontrada neste site: $folderPath. Informe o caminho de uma biblioteca de documentos acessivel."
}

function Test-CleanupAuditDirectory {
    param([string]$Path)
    if ($Path -eq '-') { return '' }
    if (-not [IO.Path]::IsPathFullyQualified($Path)) { throw 'Use uma pasta absoluta ou UNC.' }
    $directory = New-Item -ItemType Directory -Path $Path -Force -ErrorAction Stop
    $probe = Join-Path $directory.FullName ('.spvc-write-test-' + [guid]::NewGuid().ToString('N'))
    try { [IO.File]::WriteAllText($probe, '') }
    finally { if (Test-Path -LiteralPath $probe) { Remove-Item -LiteralPath $probe -ErrorAction Stop } }
    return $directory.FullName
}

function Test-CleanupEmailConfiguration {
    param([string]$Tenant, [string[]]$Sites, [hashtable]$Authentication, [hashtable]$Email, [string]$Destination)
    $testConfig = Join-Path ([IO.Path]::GetTempPath()) ('spvc-email-' + [guid]::NewGuid().ToString('N') + '.json')
    try {
        @{ Tenant = $Tenant; Sites = $Sites; Authentication = $Authentication; Email = $Email } |
            ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $testConfig -Encoding utf8
        & (Join-Path $Destination 'scripts/Send-EmailReport.ps1') -ConfigPath $testConfig -Test
    } finally {
        if (Test-Path -LiteralPath $testConfig) { Remove-Item -LiteralPath $testConfig -ErrorAction Stop }
    }
}

function Grant-CleanupSites {
    param([string]$ClientId, [string[]]$Sites)
    foreach ($site in $Sites) {
        $uri = [uri]$site
        $sitePath = if ($uri.AbsolutePath -eq '/') { "sites/$($uri.Host)" } else { "sites/$($uri.Host):$($uri.AbsolutePath)" }
        $target = Invoke-SetupGraph -Path $sitePath
        $permissions = @(Get-SetupGraphCollection -Path "sites/$($target.id)/permissions")
        $existing = @($permissions | Where-Object {
            $identities = @($_['grantedToIdentities']) + @($_['grantedToIdentitiesV2'])
            @($identities | Where-Object { $_ -and $_['application'] -and $_['application']['id'] -eq $ClientId }).Count -gt 0
        })
        if ($existing.Count -gt 0) {
            if (-not @($existing.roles | Where-Object { $_ -in 'write','manage','fullcontrol','owner' }).Count) {
                $null = Invoke-SetupGraph -Path "sites/$($target.id)/permissions/$($existing[0].id)" -Method PATCH -Body @{ roles = @('write') }
            }
        } else {
            $null = Invoke-SetupGraph -Path "sites/$($target.id)/permissions" -Method POST -Body @{
                roles = @('write'); grantedToIdentities = @(@{ application = @{ id = $ClientId; displayName = 'SharePoint Version Cleanup' } })
            }
        }
        $confirmed = @()
        for ($attempt = 1; $attempt -le 4; $attempt++) {
            $confirmed = @(Get-SetupGraphCollection -Path "sites/$($target.id)/permissions" | Where-Object {
                $identities = @($_['grantedToIdentities']) + @($_['grantedToIdentitiesV2'])
                $matching = @($identities | Where-Object { $_ -and $_['application'] -and $_['application']['id'] -eq $ClientId })
                $matching.Count -gt 0 -and @($_.roles | Where-Object { $_ -in 'write','manage','fullcontrol','owner' }).Count -gt 0
            })
            if ($confirmed.Count) { break }
            if ($attempt -lt 4) { Start-Sleep -Seconds 2 }
        }
        if (-not $confirmed.Count) { throw "Concessao Sites.Selected nao confirmada para o aplicativo $ClientId no site $site." }
        Write-Host "Concessao Sites.Selected confirmada: aplicativo $ClientId | site $site | papel $($confirmed.roles -join ', ')."
    }
}

function Register-CleanupApplication {
    param([string]$Tenant, [string]$CertificateDirectory, [string[]]$Sites, [switch]$EnableGraphMail)
    Write-Step 'Localizando aplicativo e certificado no Microsoft Entra ID'
    $app = Find-CleanupApplication
    if ($app) {
        Write-Warning 'O aplicativo SharePoint Version Cleanup ja existe. Continuando com ele automaticamente.'
    } else {
        if ($SkipAppRegistration) { throw 'Nenhum aplicativo SharePoint Version Cleanup encontrado. Remova -SkipAppRegistration para permitir a criacao.' }
        $app = Invoke-SetupGraph -Path applications -Method POST -Body @{ displayName = 'SharePoint Version Cleanup'; signInAudience = 'AzureADMyOrg' }
        $app.keyCredentials = @()
        $app.requiredResourceAccess = @()
    }
    $principals = @(Get-SetupGraphCollection -Path ("servicePrincipals?`$filter=appId%20eq%20%27$($app.appId)%27&`$select=id"))
    if ($principals.Count -eq 0) { $null = Invoke-SetupGraph -Path servicePrincipals -Method POST -Body @{ appId = $app.appId } }
    $certificate = Resolve-CleanupCertificate -Application $app -CertificateDirectory $CertificateDirectory
    Confirm-CleanupCertificateRegistration -ApplicationObjectId $app.id -Thumbprint $certificate.Thumbprint
    Set-CleanupApplicationPermissions -Application $app -EnableGraphMail:$EnableGraphMail
    Grant-CleanupSites -ClientId $app.appId -Sites $Sites
    return @{ ClientId = $app.appId; CertificateThumbprint = $certificate.Thumbprint }
}
function Initialize-CleanupWizardDefaults {
    param([string]$Destination)
    $script:WizardDefaults = @{}
    $script:WizardDefaultsPath = Join-Path $Destination 'config/wizard-defaults.json'
    $configPath = Join-Path $Destination 'config/config.json'
    # Only a fixed allowlist of non-secret input fields is retained.
    foreach ($source in @($configPath, $script:WizardDefaultsPath)) {
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { continue }
        try {
            $saved = Get-Content -LiteralPath $source -Raw | ConvertFrom-Json -AsHashtable
            if ($saved -isnot [Collections.IDictionary]) { throw 'Objeto JSON esperado.' }
            if ($source -eq $configPath) {
                foreach ($key in 'Sites','Tenant','AdminUrl','VersionsToKeep') {
                    if ($saved.ContainsKey($key)) { $script:WizardDefaults[$key] = $saved[$key] }
                }
                foreach ($section in 'Email','Safety','Sampling','Schedule','Audit') {
                    if ($saved[$section] -isnot [Collections.IDictionary]) { continue }
                    foreach ($key in $saved[$section].Keys) {
                        $name = "$section.$key"
                        if (Test-CleanupWizardKey $name) { $script:WizardDefaults[$name] = $saved[$section][$key] }
                    }
                }
                if ($saved['FolderScopes'] -is [Collections.IDictionary]) {
                    foreach ($site in $saved['FolderScopes'].Keys) { $script:WizardDefaults["Folder:$site"] = $saved['FolderScopes'][$site] }
                }
            } elseif ($saved['Values'] -is [Collections.IDictionary]) {
                if ((Test-Path -LiteralPath $configPath) -and (Get-Item -LiteralPath $configPath).LastWriteTimeUtc -gt (Get-Item -LiteralPath $source).LastWriteTimeUtc) { continue }
                foreach ($key in $saved.Values.Keys) {
                    if (Test-CleanupWizardKey $key) { $script:WizardDefaults[$key] = $saved.Values[$key] }
                }
            }
        } catch { Write-Warning "Sugestoes de '$source' indisponiveis; preencha os campos normalmente. $($_.Exception.Message)" }
    }
    if ($script:WizardDefaults.Count) { Write-Host 'Ultimos valores carregados como sugestoes. Enter aceita; digite outro valor para alterar. As aprovacoes do piloto e da producao serao solicitadas novamente.' }
}

function Test-CleanupWizardKey {
    param([string]$Key)
    return $Key -in @('Sites','Tenant','AdminUrl','VersionsToKeep','Email.Enabled','Email.To',
        'Safety.MinimumVersionAgeDays','Safety.MaxVersionsPerRun','Audit.CopyDirectory',
        'Sampling.Enabled','Sampling.SamplesPerLibrary','Sampling.SizeWeight','Sampling.RecencyWeight',
        'Sampling.RecencyHalfLifeDays','Schedule.Frequency','Schedule.Time') -or $Key -match '^Folder:https://'
}

function Save-CleanupWizardPreference {
    param([string]$Key, $Value)
    if (-not $script:WizardDefaultsPath -or -not (Test-CleanupWizardKey $Key)) { return }
    $script:WizardDefaults[$Key] = $Value
    try {
        $null = New-Item -ItemType Directory -Path (Split-Path $script:WizardDefaultsPath -Parent) -Force
        @{ SchemaVersion = 1; Values = $script:WizardDefaults } | ConvertTo-Json -Depth 6 |
            Set-Content -LiteralPath "$script:WizardDefaultsPath.tmp" -Encoding utf8
        [IO.File]::Move("$script:WizardDefaultsPath.tmp", $script:WizardDefaultsPath, $true)
    } catch { Write-Warning "Nao foi possivel guardar as sugestoes em '$script:WizardDefaultsPath': $($_.Exception.Message)" }
}

function Read-Validated {
    param([string]$Prompt, [string]$Default, [scriptblock]$Validate, [switch]$AllowEmpty, [string]$PreferenceKey)
    if ($PreferenceKey -and $script:WizardDefaults.ContainsKey($PreferenceKey)) {
        $Default = @($script:WizardDefaults[$PreferenceKey]) -join ', '
        if ($PreferenceKey -eq 'Audit.CopyDirectory' -and -not $Default) { $Default = '-' }
    }
    while ($true) {
        $answer = Read-Default -Prompt $Prompt -Default $Default -Required:(-not $AllowEmpty)
        try {
            $result = & $Validate $answer
            if ($PreferenceKey) { Save-CleanupWizardPreference -Key $PreferenceKey -Value $result }
            return $result
        }
        catch { Write-Host "Vamos corrigir: $($_.Exception.Message)" -ForegroundColor Yellow }
    }
}

function Read-YesNo {
    param([string]$Prompt, [bool]$Default = $false, [string]$PreferenceKey)
    if ($PreferenceKey -and $script:WizardDefaults[$PreferenceKey] -is [bool]) { $Default = $script:WizardDefaults[$PreferenceKey] }
    $fallback = if ($Default) { 'S' } else { 'N' }
    $result = Read-Validated -Prompt "$Prompt (S/N)" -Default $fallback -Validate {
        param($answer)
        if ($answer -notmatch '^(s|sim|n|nao|não)$') { throw 'Digite S para sim ou N para nao.' }
        return $answer -match '^(s|sim)$'
    }
    if ($PreferenceKey) { Save-CleanupWizardPreference -Key $PreferenceKey -Value $result }
    return $result
}

function New-Configuration {
    param([string]$Destination)
    Initialize-CleanupWizardDefaults -Destination $Destination
    Write-Step '2 de 5 - Vamos configurar o acesso e o escopo'
    Write-Host 'O acesso usa um aplicativo e um certificado da conta que executara as tarefas.'
    $sites = @(Read-Validated -PreferenceKey Sites -Prompt 'URLs dos sites, separadas por virgula (para teste03 use a URL raiz do site)' -Validate {
        param($v)
        @($v.Split(',') | ForEach-Object { ConvertTo-SiteUrl $_.Trim() } | Select-Object -Unique)
    })
    $context = Get-CleanupTenantContext -SiteUrl $sites[0]
    $tenant = $context.Tenant
    $adminUrl = $context.AdminUrl
    Save-CleanupWizardPreference -Key Tenant -Value $tenant
    Save-CleanupWizardPreference -Key AdminUrl -Value $adminUrl
    $email = @{ Enabled = (Read-YesNo 'Enviar relatorios pelo Microsoft 365 (Graph)?' -PreferenceKey Email.Enabled -Default $true); Provider = 'Graph'; From = ''; SenderUserId = ''; To = @() }
    Write-Step 'Autenticando no Microsoft 365 antes de configurar a limpeza'
    Connect-CleanupSetup -Tenant $tenant
    # Resolve library/folder URLs before creating certificates or changing applications.
    $resolvedSites = [Collections.Generic.List[string]]::new()
    $suggestedScopes = @{}
    foreach ($inputSite in $sites) {
        while ($true) {
            try { $resolved = Resolve-CleanupSiteInput -Url $inputSite; break }
            catch {
                Write-Warning "Nao foi possivel validar o site: $($_.Exception.Message)"
                $inputSite = Read-Validated -Prompt 'URL corrigida do site ou biblioteca/pasta (mesmo tenant)' -Validate {
                    param($v)
                    $normalized = ConvertTo-SiteUrl $v
                    if (([uri]$normalized).Host -ne ([uri]$inputSite).Host) { throw 'Use o mesmo host SharePoint do login atual.' }
                    $normalized
                }
            }
        }
        if ($suggestedScopes.ContainsKey($resolved.SiteUrl) -and $suggestedScopes[$resolved.SiteUrl] -ne $resolved.Folder) {
            throw 'Foram informados escopos diferentes do mesmo site. Configure uma unica biblioteca/pasta por site nesta instalacao.'
        }
        if (-not $resolvedSites.Contains($resolved.SiteUrl)) { $resolvedSites.Add($resolved.SiteUrl) }
        $suggestedScopes[$resolved.SiteUrl] = $resolved.Folder
    }
    $sites = $resolvedSites.ToArray()
    $scopes = @{}
    foreach ($site in $sites) {
        Write-Host "Site: $site"
        if ($suggestedScopes[$site]) {
            try { $scopes[$site] = Test-CleanupFolderAccess -SiteUrl $site -Folder $suggestedScopes[$site] }
            catch {
                Write-Warning $_.Exception.Message
                $scopes[$site] = Read-Validated -Prompt 'Corrija o caminho da biblioteca/pasta' -Validate {
                    param($v)
                    Test-CleanupFolderAccess -SiteUrl $site -Folder $v
                }
            }
            Write-Host "Biblioteca/pasta identificada na URL: $($scopes[$site]). A limpeza ficara limitada a esse caminho."
            Save-CleanupWizardPreference -Key "Folder:$site" -Value $scopes[$site]
            continue
        }
        Write-Host 'Informe o caminho da biblioteca/pasta, ex.: /teste03. Inclua o caminho do site quando houver.'
        $limitDefault = -not $script:WizardDefaults.ContainsKey("Folder:$site") -or [bool]$script:WizardDefaults["Folder:$site"]
        if (Read-YesNo 'Limitar a uma biblioteca ou pasta?' -Default $limitDefault) {
            $scopes[$site] = Read-Validated -PreferenceKey "Folder:$site" -Prompt 'Caminho completo dentro do servidor' -Validate {
                param($v)
                Test-CleanupFolderAccess -SiteUrl $site -Folder $v
            }
        } else {
            if (-not (Read-YesNo 'Confirma que o escopo sera TODO este site?')) { throw 'Escopo nao confirmado. Reinicie o assistente.' }
            $scopes[$site] = ''
        }
        Save-CleanupWizardPreference -Key "Folder:$site" -Value $scopes[$site]
    }
    if ($email.Enabled) {
        $profile = Invoke-SetupGraph -Path 'me?$select=id,mail,userPrincipalName'
        $email.SenderUserId = [string]$profile.id
        $email.From = if ($profile.mail) { [string]$profile.mail } else { [string]$profile.userPrincipalName }
        if (-not $email.SenderUserId -or -not $email.From) { throw 'Nao foi possivel identificar a conta autenticada para o envio Graph.' }
        Write-Host "Remetente Microsoft 365 identificado pelo login: $($email.From)"
        $email.To = @(Read-Validated -PreferenceKey Email.To -Prompt 'Destinatarios separados por virgula' -Default $email.From -Validate {
            param($v)
            @($v.Split(',') | ForEach-Object { ([Net.Mail.MailAddress]::new($_.Trim())).Address })
        })
        Write-Host 'O envio agendado usa certificado e exige Mail.Send de aplicativo com consentimento administrativo no aplicativo de limpeza.'
    }
    $auth = Register-CleanupApplication -Tenant $tenant -CertificateDirectory (Join-Path $Destination 'certificates') -Sites $sites -EnableGraphMail:$email.Enabled
    # Validate the certificate/app pair before asking about retention and scheduling.
    foreach ($site in $sites) {
        while ($true) {
            try {
                $null = Connect-CleanupSite -SiteUrl $site -Tenant $tenant -Authentication $auth -FolderServerRelativeUrl $scopes[$site]
                break
            } catch {
                Write-Warning "Acesso ainda indisponivel: $($_.Exception.Message)"
                if ($_.Exception.Message -match 'AADSTS700027') {
                    Write-Host "O Entra ainda nao reconhece o certificado $($auth.CertificateThumbprint) para o aplicativo $($auth.ClientId). Confira Certificados e segredos e aguarde a propagacao da chave. Consentimento de API nao corrige certificado ausente."
                } elseif ($_.Exception.Message -match '403|Forbidden|Access denied|AccessDenied|Unauthorized|Acesso negado') {
                    Write-Host "Aplicativo: $($auth.ClientId) | Site: $site. O consentimento de Sites.Selected no Entra e a concessao de escrita neste site sao verificacoes distintas. Se a concessao foi confirmada acima, verifique propagacao e restricoes das bibliotecas ou do tenant."
                } else {
                    Write-Host 'A validacao falhou. Confira o erro original acima; a causa pode ser autenticacao, rede ou acesso ao site.'
                }
                if (-not (Read-YesNo 'Tentar validar o acesso novamente?' -Default $true)) { throw }
            }
        }
    }
    if ($email.Enabled -and -not $SkipEmailTest) {
        while ($true) {
            try {
                Test-CleanupEmailConfiguration -Tenant $tenant -Sites $sites -Authentication $auth -Email $email -Destination $Destination
                break
            } catch {
                Write-Warning "O teste de email falhou: $($_.Exception.Message)"
                if ($_.Exception.Data.Contains('Retryable') -and -not $_.Exception.Data['Retryable']) { throw }
                if (-not (Read-YesNo 'Apos corrigir a causa informada acima, testar o email novamente?' -Default $true)) { throw }
            }
        }
    }
    $keep = Read-Validated -PreferenceKey VersionsToKeep -Prompt 'Versoes HISTORICAS a manter (a atual sempre e preservada)' -Default '10' -Validate {
        param($v)
        $n = 0
        if (-not [int]::TryParse($v,[ref]$n) -or $n -lt 1) { throw 'Use um inteiro maior que zero.' }
        $n
    }
    $minimumAge = Read-Validated -PreferenceKey Safety.MinimumVersionAgeDays -Prompt 'Idade minima das versoes, em dias (0 somente para piloto descartavel)' -Default '30' -Validate {
        param($v)
        $n=0
        if (-not [int]::TryParse($v,[ref]$n) -or $n -lt 0 -or $n -gt 36500) { throw 'Use um inteiro de 0 a 36500.' }
        $n
    }
    $maximumDeletes = Read-Validated -PreferenceKey Safety.MaxVersionsPerRun -Prompt 'Limite de exclusoes por execucao' -Default '1000' -Validate {
        param($v)
        $n=0
        if (-not [int]::TryParse($v,[ref]$n) -or $n -lt 1 -or $n -gt 1000000) { throw 'Use um inteiro de 1 a 1000000.' }
        $n
    }
    $auditCopy = Read-Validated -PreferenceKey Audit.CopyDirectory -Prompt 'Pasta para copiar auditoria (Enter aceita; - desabilita)' -Default (Join-Path $Destination 'audit-copy') -Validate {
        param($v)
        if ($v -ne '-') {
            $root = [IO.Path]::GetFullPath($Destination).TrimEnd('\')
            $full = [IO.Path]::GetFullPath($v).TrimEnd('\')
            if ($v.StartsWith('\\') -or -not $full.StartsWith("$root\",[StringComparison]::OrdinalIgnoreCase)) {
                throw 'Use uma subpasta local da instalacao para permitir auditoria automatica sem senha pessoal.'
            }
            foreach ($protected in 'scripts','config','certificates') {
                $protectedPath = Join-Path $root $protected
                if ($full -eq $protectedPath -or $full.StartsWith("$protectedPath\",[StringComparison]::OrdinalIgnoreCase)) { throw 'A auditoria deve ficar separada dos scripts, configuracao e certificados.' }
            }
        }
        Test-CleanupAuditDirectory -Path $v
    }
    $sampling = @{Enabled=$true;SamplesPerLibrary=1;SizeWeight=1;RecencyWeight=4;RecencyHalfLifeDays=30}
    foreach ($key in 'SizeWeight','RecencyWeight','RecencyHalfLifeDays') {
        $savedWeight = $script:WizardDefaults["Sampling.$key"]
        $minimum = if ($key -eq 'RecencyHalfLifeDays') { 1 } else { 0 }
        $maximum = if ($key -eq 'RecencyHalfLifeDays') { 36500 } else { 100 }
        if (($savedWeight -is [int] -or $savedWeight -is [long]) -and $savedWeight -ge $minimum -and $savedWeight -le $maximum) { $sampling[$key] = $savedWeight }
    }
    $sampling.Enabled = Read-YesNo 'Conferir uma amostra dos arquivos inalterados, priorizando maiores e recentes?' -PreferenceKey Sampling.Enabled -Default $true
    if ($sampling.Enabled) {
        $sampling.SamplesPerLibrary = Read-Validated -PreferenceKey Sampling.SamplesPerLibrary -Prompt 'Arquivos a conferir por biblioteca em cada execucao incremental' -Default '1' -Validate {
            param($v)
            $n=0
            if (-not [int]::TryParse($v,[ref]$n) -or $n -lt 1 -or $n -gt 1000) { throw 'Use um inteiro de 1 a 1000.' }
            $n
        }
    }
    $frequency = Read-Validated -PreferenceKey Schedule.Frequency -Prompt 'Periodicidade: D = diaria, S = semanal' -Default 'S' -Validate {
        param($v)
        switch ($v.Trim().ToUpperInvariant()) {
            { $_ -in 'D','DIARIA' } { 'diaria'; break }
            { $_ -in 'S','SEMANAL' } { 'semanal'; break }
            default { throw 'Digite D para diaria ou S para semanal.' }
        }
    }
    $time = Read-Validated -PreferenceKey Schedule.Time -Prompt 'Horario local da tarefa (HH:mm)' -Default '22:00' -Validate {
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
                $report = & $installedCleanup @cleanupArguments
                break
            } catch {
                Write-Host "Nao foi possivel concluir: $($_.Exception.Message)" -ForegroundColor Yellow
                if ($_.Exception.Message -match 'Checkpoint') {
                    Write-Host 'A falha esta no estado local de retomada. Confira o checkpoint indicado no erro; alterar consentimento ou certificado nao resolve esse problema.'
                } else {
                    Write-Host "Confira o erro original acima e a configuracao em: $ConfigPath"
                }
                if (-not (Read-YesNo 'Apos corrigir, deseja tentar novamente?')) { throw }
            }
        }
        Show-CleanupSummary $report
        Write-Step '4 de 5 - Aprovar o piloto'
        if ($report.VersionsEligible -gt 0 -and $report.FilesSkipped -eq 0 -and
            (Read-YesNo 'Aprova excluir as versoes antigas neste escopo para validar o piloto? A exclusao e permanente')) {
            $cleanupArguments.Apply = $true
            $applied = & $installedCleanup @cleanupArguments
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
    $pwsh = Join-Path $PSHOME 'pwsh.exe'
    $cleanupScript = Join-Path $Destination 'scripts\cleanup-versions.ps1'
    $configPath = Join-Path $Destination 'config\config.json'
    Write-Host 'As tarefas usarao LOCAL SERVICE e o certificado do aplicativo, sem senha pessoal e sem exigir sessao aberta.'
    $serviceName = ([Security.Principal.SecurityIdentifier]::new('S-1-5-19')).Translate([Security.Principal.NTAccount]).Value
    $taskPrincipal = New-ScheduledTaskPrincipal -UserId $serviceName -LogonType ServiceAccount -RunLevel Limited
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
                    if (-not $script:TaskBackups.ContainsKey($taskName)) { $script:TaskBackups[$taskName] = Export-ScheduledTask -TaskName $taskName -TaskPath '\' }
                } else {
                    $script:NewTasks.Add($taskName)
                }
                Register-ScheduledTask -TaskName $taskName -TaskPath '\' -Action $action -Trigger $trigger `
                    -Settings $settings -Description "Limpeza de versoes: $site" `
                    -Principal $taskPrincipal -Force | Out-Null
            }
        }
}

function Suspend-CleanupInstallationTasks {
    param([string]$Destination)
    $configPath = Join-Path $Destination 'config\config.json'
    $owned = @(Get-ScheduledTask -TaskPath '\' -ErrorAction Stop | Where-Object {
        $_.TaskName -like "$script:TaskPrefix - *" -and @($_.Actions | Where-Object {
            $_.Arguments -and $_.Arguments.Contains("`"$configPath`"", [StringComparison]::OrdinalIgnoreCase)
        }).Count
    })
    # Validate all tasks before disabling even the first one.
    foreach ($task in $owned) {
        if ($task.State -eq 'Running') { throw "[SPVC-INSTALL-BUSY] Tarefa '$($task.TaskName)' em execucao. Aguarde sua conclusao antes de atualizar." }
        if ($task.Principal.LogonType -eq 'Password') { throw "[SPVC-LEGACY-TASK] Tarefa '$($task.TaskName)' usa senha pessoal. Migre ou remova essa tarefa antes de atualizar; sua identidade nao pode ser restaurada automaticamente sem a senha." }
    }
    foreach ($task in $owned) {
        $script:TaskBackups[$task.TaskName] = Export-ScheduledTask -TaskName $task.TaskName -TaskPath '\'
        $null = Disable-ScheduledTask -TaskName $task.TaskName -TaskPath '\' -ErrorAction Stop
        if ((Get-ScheduledTask -TaskName $task.TaskName -TaskPath '\').State -eq 'Running') {
            throw "[SPVC-INSTALL-BUSY] A tarefa '$($task.TaskName)' iniciou durante a preparacao. Nenhum componente deve ser atualizado enquanto ela executa."
        }
    }
}

function Restore-CleanupInstallation {
    param([hashtable]$Backups, [string[]]$Written, [string]$RollbackRoot)
    $failures = [Collections.Generic.List[string]]::new()
    foreach ($taskName in $script:NewTasks) {
        try { Unregister-ScheduledTask -TaskName $taskName -TaskPath '\' -Confirm:$false -ErrorAction Stop }
        catch { $failures.Add("Tarefa ${taskName}: $($_.Exception.Message)") }
    }
    # Restore files before re-enabling old tasks.
    foreach ($target in $Written) {
        try {
            if ($Backups.ContainsKey($target)) { Copy-Item -LiteralPath $Backups[$target] -Destination $target -Force -ErrorAction Stop }
            elseif (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Force -ErrorAction Stop }
        } catch { $failures.Add("Arquivo ${target}: $($_.Exception.Message)") }
    }
    foreach ($entry in $script:TaskBackups.GetEnumerator()) {
        try {
            if ($failures.Count) { throw 'Restauracao de arquivos incompleta; tarefa mantida desabilitada.' }
            Register-ScheduledTask -TaskName $entry.Key -TaskPath '\' -Xml $entry.Value -Force -ErrorAction Stop | Out-Null
        } catch { $failures.Add("Tarefa $($entry.Key): $($_.Exception.Message)") }
    }
    if ($failures.Count) {
        Write-Warning "[SPVC-ROLLBACK] Restauracao incompleta. Backups preservados em '$RollbackRoot'. $($failures -join '; ')"
        return $false
    }
    return $true
}

function Assert-CleanupInstallPath {
    param([string]$Path)
    if ($Path.StartsWith('\\') -or -not [IO.Path]::IsPathFullyQualified($Path)) { throw '[SPVC-PATH] Use uma pasta local absoluta e dedicada para a instalacao.' }
    $cursor = $Path
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            if (-not $item.PSIsContainer -or $item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "[SPVC-PATH] Caminho nao e uma pasta local sem redirecionamento: $cursor" }
        }
        $cursor = Split-Path $cursor -Parent
    }
    if (Test-Path -LiteralPath $Path) {
        $links = @(Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction Stop | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint })
        if ($links.Count) { throw "[SPVC-PATH] A instalacao contem redirecionamentos: $($links[0].FullName). Use uma pasta local dedicada." }
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
Assert-CleanupInstallPath $InstallPath
# Back up only files owned by the installer. Never delete the user's whole folder.
$rollbackRoot = Join-Path ([IO.Path]::GetTempPath()) ('spvc-install-' + [guid]::NewGuid().ToString('N'))
$managedFiles = @($script:RequiredFiles) + @('config/config.json', 'release-manifest.json')
$backups = @{}
$written = [Collections.Generic.List[string]]::new()
$removeBackups = $false
$installationLock = $null
$stage = 'preparar dependencias'
$installLog = Join-Path ([IO.Path]::GetTempPath()) ('spvc-install-' + [guid]::NewGuid().ToString('N') + '.log')
$installTranscript = $false
$journalPath = Join-Path $InstallPath '.install-recovery.json'
$journalCreated = $false

try {
    try { Start-Transcript -LiteralPath $installLog -ErrorAction Stop | Out-Null; $installTranscript = $true }
    catch { Write-Warning "Nao foi possivel iniciar log '$installLog': $($_.Exception.Message)" }
    $null = New-Item -ItemType Directory -Path $InstallPath -Force
    try { $installationLock = [IO.File]::Open((Join-Path $InstallPath '.install.lock'), 'OpenOrCreate', 'ReadWrite', 'None') }
    catch { throw "[SPVC-INSTALL-BUSY] Nao foi possivel bloquear '$InstallPath' para instalacao. Verifique outra instalacao em curso e permissoes. $($_.Exception.Message)" }
    if (Test-Path -LiteralPath $journalPath) { throw "[SPVC-RECOVERY] Uma instalacao anterior foi interrompida. Revise '$journalPath', que indica os backups para recuperar arquivos e tarefas. Preserve esses backups; remova o marcador somente depois de concluir a recuperacao." }
    Ensure-PnPModule
    New-Item -ItemType Directory -Path $rollbackRoot -Force | Out-Null
    $stage = 'suspender agendamentos existentes'
    Suspend-CleanupInstallationTasks -Destination $InstallPath
    $stage = 'preservar instalacao anterior'
    foreach ($relative in $managedFiles) {
        $target = Join-Path $InstallPath $relative
        if (Test-Path -LiteralPath $target) {
            $backup = Join-Path $rollbackRoot ([guid]::NewGuid().ToString('N'))
            Copy-Item -LiteralPath $target -Destination $backup
            $backups[$target] = $backup
        }
    }
    @{ Files = $backups; Tasks = $script:TaskBackups } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $rollbackRoot 'recovery.json') -Encoding utf8
    @{ BackupRoot = $rollbackRoot; RecoveryFile = (Join-Path $rollbackRoot 'recovery.json'); StartedAt = (Get-Date).ToString('o') } |
        ConvertTo-Json | Set-Content -LiteralPath $journalPath -Encoding utf8
    $journalCreated = $true
    foreach ($relative in $managedFiles) { $written.Add((Join-Path $InstallPath $relative)) }
    $stage = 'copiar e verificar componentes'
    Copy-ProjectFiles -Destination $InstallPath
    . (Join-Path $InstallPath 'scripts/Configuration.ps1')
    . (Join-Path $InstallPath 'scripts/TaskIdentity.ps1')
    $stage = 'preencher e validar configuracao'
    $configuration = New-Configuration -Destination $InstallPath
    $configPath = Join-Path $InstallPath 'config/config.json'
    $configuration | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $configPath -Encoding utf8
    $null = Read-CleanupConfiguration $configPath
    foreach ($folder in 'state','logs') {
        New-Item -ItemType Directory -Path (Join-Path $InstallPath $folder) -Force | Out-Null
    }
    $cert = Get-ChildItem Cert:\CurrentUser\My,Cert:\LocalMachine\My | Where-Object Thumbprint -EQ $configuration.Authentication.CertificateThumbprint | Select-Object -First 1
    if (-not $cert -or -not $cert.HasPrivateKey -or $cert.NotAfter -le (Get-Date) -or $cert.NotBefore -gt (Get-Date)) {
        throw 'Certificado sem chave privada ou fora da validade.'
    }
    $stage = 'preparar e testar LOCAL SERVICE'
    Initialize-CleanupServiceIdentity -Configuration $configuration -Destination $InstallPath
    Test-CleanupServiceExecution -Configuration $configuration -Destination $InstallPath
    $stage = 'validar simulacao e piloto'
    $productionSites = @(Invoke-SetupValidation -ConfigPath $configPath)
    $stage = 'registrar agendamentos'
    Install-ScheduledTasks -Configuration $configuration -Destination $InstallPath -ProductionSites $productionSites
    foreach ($oldName in $script:TaskBackups.Keys) {
        $index = 0
        if ([int]::TryParse(($oldName -split ' - ')[-1], [ref]$index) -and $index -gt $configuration.Sites.Count) {
            Write-Warning "Tarefa antiga '$oldName' mantida desabilitada: o site nao faz parte do novo agendamento."
        }
    }
    $removeBackups = $true
    Write-Host "Instalacao concluida em $InstallPath. Escopos em producao: $($productionSites.Count); restantes em simulacao." -ForegroundColor Green
} catch {
    $originalError = $_
    $removeBackups = Restore-CleanupInstallation -Backups $backups -Written $written.ToArray() -RollbackRoot $rollbackRoot
    Write-Warning "[SPVC-INSTALL] Falha na etapa '$stage'. Destino: $InstallPath. Log: $installLog. Erro original: $($originalError.Exception.Message)"
    Write-Warning 'Instalacao interrompida. Registro Entra, certificado e modulo instalado podem exigir revisao administrativa.'
    throw $originalError
} finally {
    # Only the exact per-file backups and our empty temporary directory are removed.
    if ($removeBackups) {
        if ($journalCreated) { Remove-Item -LiteralPath $journalPath -Force -ErrorAction SilentlyContinue }
        foreach ($backup in $backups.Values) { Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue }
        Remove-Item -LiteralPath (Join-Path $rollbackRoot 'recovery.json') -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $rollbackRoot) { Remove-Item -LiteralPath $rollbackRoot -ErrorAction SilentlyContinue }
    }
    if ($installationLock) { $installationLock.Dispose() }
    if ($installTranscript) { try { Stop-Transcript | Out-Null } catch { Write-Warning "Falha ao encerrar log: $($_.Exception.Message)" } }
}
