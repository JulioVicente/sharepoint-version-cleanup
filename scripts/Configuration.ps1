#requires -Version 7.4
# Shared validation; dot-sourcing this file has no external effects.
function ConvertTo-SiteUrl {
    param([Parameter(Mandatory)][string]$Value)
    $uri = $null
    if (-not [uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -ne 'https' -or $uri.UserInfo -or $uri.Query -or $uri.Fragment -or
        $Value -match '["\s]' -or $uri.Host -notmatch '\.sharepoint\.(com|us|de|cn)$') {
        throw "URL SharePoint HTTPS invalida: $Value"
    }
    return $uri.AbsoluteUri.TrimEnd('/').ToLowerInvariant()
}

function Read-CleanupConfiguration {
    [CmdletBinding(DefaultParameterSetName = 'File')]
    param(
        [Parameter(Mandatory, Position = 0, ParameterSetName = 'File')][string]$Path,
        [Parameter(Mandatory, ParameterSetName = 'Values')][hashtable]$Values
    )
    $value = if ($PSCmdlet.ParameterSetName -eq 'Values') { $Values } else { Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable }
    if ($value -isnot [Collections.IDictionary]) { throw 'A raiz do JSON deve ser um objeto.' }
    if (-not $value.ContainsKey('SchemaVersion')) { $value.SchemaVersion = 1 }
    if ($value.SchemaVersion -notin 1,2) { throw 'SchemaVersion suportado: 1 ou 2.' }
    if (-not $value.ContainsKey('Safety')) { $value.Safety = @{} }
    if (-not $value.ContainsKey('Retry')) { $value.Retry = @{} }
    if (-not $value.ContainsKey('Audit')) { $value.Audit = @{} }
    $defaults = @{
        Safety = @{ MaxVersionsPerRun = 1000; MinimumVersionAgeDays = 30 }
        Retry = @{ MaxRetries = 3; BaseDelaySeconds = 2; MaxDelaySeconds = 60 }
        Audit = @{ CopyDirectory = '' }
    }
    foreach ($section in $defaults.Keys) {
        if ($value[$section] -isnot [Collections.IDictionary]) { throw "$section deve ser um objeto." }
        foreach ($key in $defaults[$section].Keys) {
            if (-not $value[$section].ContainsKey($key)) { $value[$section][$key] = $defaults[$section][$key] }
        }
    }
    foreach ($rule in @(
        @('Safety','MaxVersionsPerRun',1,1000000), @('Safety','MinimumVersionAgeDays',0,36500),
        @('Retry','MaxRetries',0,10), @('Retry','BaseDelaySeconds',1,300), @('Retry','MaxDelaySeconds',1,3600)
    )) {
        $number = $value[$rule[0]][$rule[1]]
        if (($number -isnot [int] -and $number -isnot [long]) -or $number -lt $rule[2] -or $number -gt $rule[3]) {
            throw "$($rule[0]).$($rule[1]) deve ser inteiro entre $($rule[2]) e $($rule[3])."
        }
    }
    if ($value.Retry.MaxDelaySeconds -lt $value.Retry.BaseDelaySeconds) { throw 'MaxDelaySeconds deve ser maior ou igual a BaseDelaySeconds.' }
    if ($value.Audit.CopyDirectory -and -not [IO.Path]::IsPathFullyQualified($value.Audit.CopyDirectory)) { throw 'Audit.CopyDirectory deve ser absoluto ou UNC.' }
    if (-not $value.ContainsKey('Schedule')) { $value.Schedule = @{ Frequency = 'semanal'; Time = '22:00' } }
    if ($value.Schedule.Frequency -notin 'diaria','semanal' -or $value.Schedule.Time -notmatch '^([01]\d|2[0-3]):[0-5]\d$') {
        throw 'Schedule exige Frequency diaria/semanal e Time HH:mm.'
    }
    foreach ($key in 'Tenant','Sites','VersionsToKeep','Authentication','Paths') {
        if (-not $value.ContainsKey($key)) { throw "Configuracao obrigatoria ausente: $key" }
    }
    if ([string]::IsNullOrWhiteSpace($value.Tenant)) { throw 'Tenant obrigatorio.' }
    if ($value.VersionsToKeep -isnot [long] -and $value.VersionsToKeep -isnot [int]) {
        throw 'VersionsToKeep deve ser um inteiro maior que zero.'
    }
    if ($value.VersionsToKeep -lt 1 -or $value.VersionsToKeep -gt [int]::MaxValue) {
        throw 'VersionsToKeep deve ser um inteiro maior que zero.'
    }
    if ($value.Sites -is [string] -or @($value.Sites).Count -eq 0) { throw 'Sites deve ser uma lista nao vazia.' }
    $value.Sites = @($value.Sites | ForEach-Object { ConvertTo-SiteUrl $_ } | Select-Object -Unique)
    if (-not $value.ContainsKey('FolderScopes')) { $value.FolderScopes = @{} }
    if ($value.FolderScopes -isnot [Collections.IDictionary]) { throw 'FolderScopes deve ser um objeto indexado pela URL de cada site.' }
    $normalizedScopes = @{}
    foreach ($key in $value.FolderScopes.Keys) {
        $siteKey = ConvertTo-SiteUrl $key
        if ($siteKey -notin $value.Sites) { throw "FolderScopes contem site nao cadastrado: $key" }
        $normalizedScopes[$siteKey] = [string]$value.FolderScopes[$key]
    }
    $value.FolderScopes = $normalizedScopes
    foreach ($site in $value.Sites) {
        if ($value.FolderScopes[$site]) { $value.FolderScopes[$site] = ConvertTo-CleanupFolder $value.FolderScopes[$site] $site }
    }
    $clientId = [guid]::Empty
    if (-not [guid]::TryParse($value.Authentication.ClientId, [ref]$clientId) -or $clientId -eq [guid]::Empty) {
        throw 'Authentication.ClientId deve ser um GUID valido e nao vazio.'
    }
    if ($value.Authentication.CertificateThumbprint -notmatch '^[a-fA-F0-9]{40}$') { throw 'Thumbprint invalido.' }
    foreach ($key in 'Logs','State') {
        if ([string]::IsNullOrWhiteSpace($value.Paths[$key]) -or -not [IO.Path]::IsPathFullyQualified($value.Paths[$key])) {
            throw "Paths.$key deve ser um caminho absoluto."
        }
    }
    if (-not $value.ContainsKey('Email')) { $value.Email = @{ Enabled = $false } }
    if ($value.Email.Enabled -isnot [bool]) { throw 'Email.Enabled deve ser booleano.' }
    if ($value.Email.Enabled) {
        if ([string]::IsNullOrWhiteSpace($value.Email.SmtpServer) -or $value.Email.Port -lt 1 -or $value.Email.Port -gt 65535) { throw 'Servidor/porta SMTP invalidos.' }
        if ($value.Email.UseSsl -isnot [bool]) { throw 'Email.UseSsl deve ser booleano.' }
        $null = [Net.Mail.MailAddress]::new([string]$value.Email.From)
        if (@($value.Email.To).Count -eq 0) { throw 'Destinatario SMTP obrigatorio.' }
        foreach ($recipient in $value.Email.To) { $null = [Net.Mail.MailAddress]::new([string]$recipient) }
        if ($value.Email.UserName -and -not $value.Email.EncryptedPassword) { throw 'Senha SMTP criptografada obrigatoria quando UserName e informado.' }
    }
    return $value
}

function ConvertTo-CleanupFolder {
    param([string]$Value, [string]$SiteUrl)
    $folder = $Value.TrimEnd('/')
    $sitePath = [uri]::UnescapeDataString(([uri]$SiteUrl).AbsolutePath).TrimEnd('/')
    if (-not $folder.StartsWith('/') -or $folder -match '[?#"\\%]' -or
        $folder -match '(^|/)\.{1,2}(/|$)' -or
        ($sitePath -and -not $folder.StartsWith("$sitePath/", [StringComparison]::OrdinalIgnoreCase))) {
        throw 'Use um caminho decodificado dentro do site, ex.: /teste03, sem URL de visualizacao nem barras finais.'
    }
    return $folder
}
