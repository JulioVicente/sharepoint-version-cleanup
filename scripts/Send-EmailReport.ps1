#requires -Version 7.4
[CmdletBinding(DefaultParameterSetName = 'Report')]
param(
    [Parameter(Mandatory = $true)][string]$ConfigPath,
    [Parameter(Mandatory = $true, ParameterSetName = 'Report')][string]$ReportPath,
    [Parameter(Mandatory = $true, ParameterSetName = 'Test')][switch]$Test,
    [string]$PreviewPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
if (-not $config.Email.Enabled) { return }

if ($Test) {
    $report = [pscustomobject]@{
        Success = $true; SiteUrl = 'Teste de configuracao'; Apply = $false
        FilesProcessed = 0; VersionsDeleted = 0; BytesFreed = 0
        VersionsEligible = 0; BytesEligible = 0; FolderServerRelativeUrl = ''; FilesUnchanged = 0
        FilesSkipped = 0; Warnings = @(); Error = $null; LogPath = $null
        StartedAt = Get-Date; FinishedAt = Get-Date
    }
} else {
    $report = Get-Content -LiteralPath $ReportPath -Raw | ConvertFrom-Json
}

$templatePath = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'templates\email-template.html'
$template = Get-Content -LiteralPath $templatePath -Raw
$status = if ($report.Success) { 'SUCESSO' } else { 'ERRO' }
$color = if ($report.Success) { '#16803c' } else { '#c62828' }
$warningText = if (@($report.Warnings).Count) {
    [Net.WebUtility]::HtmlEncode((@($report.Warnings) -join "`n"))
} else { 'Nenhum' }
$values = @{
    STATUS = $status; COLOR = $color
    SITE = [Net.WebUtility]::HtmlEncode([string]$report.SiteUrl)
    FOLDER = [Net.WebUtility]::HtmlEncode([string]$report.FolderServerRelativeUrl)
    UNCHANGED = [string]$report.FilesUnchanged
    ELIGIBLE = [string]$report.VersionsEligible
    ESTIMATED = ('{0:N2} GB' -f ([double]$report.BytesEligible / 1GB))
    MODE = $(if ($report.Apply) { 'Aplicacao' } else { 'Simulacao' })
    FILES = [string]$report.FilesProcessed; DELETED = [string]$report.VersionsDeleted
    FREED = ('{0:N2} GB' -f ([double]$report.BytesFreed / 1GB))
    SKIPPED = [string]$report.FilesSkipped; WARNINGS = $warningText
    ERROR = [Net.WebUtility]::HtmlEncode([string]$report.Error)
    FINISHED = ([datetime]$report.FinishedAt).ToString('dd/MM/yyyy HH:mm:ss')
}
foreach ($key in $values.Keys) { $template = $template.Replace("{{$key}}", $values[$key]) }

if ($PreviewPath) {
    $template | Set-Content -LiteralPath $PreviewPath -Encoding utf8
    return
}

if (-not $config.Email.PSObject.Properties['Provider'] -or $config.Email.Provider -ne 'Graph') {
    throw 'Reconfigure o email pelo assistente para usar Microsoft Graph. SMTP nao e mais utilizado.'
}
$senderId = [guid]::Empty
if (-not $config.Email.PSObject.Properties['SenderUserId'] -or
    -not [guid]::TryParse([string]$config.Email.SenderUserId, [ref]$senderId) -or $senderId -eq [guid]::Empty) {
    throw 'Email.SenderUserId deve identificar a conta Microsoft 365 autenticada no assistente.'
}
if (@($config.Email.To).Count -eq 0) { throw 'Informe pelo menos um destinatario.' }
$recipients = @($config.Email.To | ForEach-Object {
    @{ emailAddress = @{ address = ([Net.Mail.MailAddress]::new([string]$_)).Address } }
})
$message = @{
    subject = "[$status] SharePoint Version Cleanup - $($report.SiteUrl)"
    body = @{ contentType = 'HTML'; content = $template }
    toRecipients = $recipients
}
if (-not $Test -and $report.LogPath -and (Test-Path -LiteralPath $report.LogPath)) {
    $log = Get-Item -LiteralPath $report.LogPath
    if ($log.Length -le 2MB) {
        $message.attachments = @(@{
            '@odata.type' = '#microsoft.graph.fileAttachment'
            name = $log.Name
            contentType = 'text/plain'
            contentBytes = [Convert]::ToBase64String([IO.File]::ReadAllBytes($log.FullName))
        })
    } else {
        Write-Warning "Log maior que 2 MB: envio do resumo sem anexo. Arquivo preservado em $($log.FullName)."
        $message.body.content += '<p>O log excedeu o limite de anexo de 2 MB e permanece no computador executor.</p>'
    }
}
Import-Module PnP.PowerShell -MinimumVersion 3.0.0 -ErrorAction Stop
$connection = Connect-PnPOnline -Url $config.Sites[0] -Tenant $config.Tenant `
    -ClientId $config.Authentication.ClientId -Thumbprint $config.Authentication.CertificateThumbprint `
    -ReturnConnection -ErrorAction Stop
$payload = @{ message = $message; saveToSentItems = $true } | ConvertTo-Json -Depth 10
try {
    $null = Invoke-PnPGraphMethod -Url "users/$senderId/sendMail" -Method Post -Content $payload `
        -ContentType 'application/json' -Connection $connection -ErrorAction Stop
    Write-Host "Microsoft Graph aceitou o envio de $($config.Email.From). A entrega depende do Exchange Online."
} catch {
    throw "Falha no envio Microsoft Graph. Verifique Mail.Send (aplicativo), consentimento administrativo e acesso a caixa $($config.Email.From). $($_.Exception.Message)"
}
