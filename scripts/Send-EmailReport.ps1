#requires -Version 7.4
[CmdletBinding(DefaultParameterSetName = 'Report')]
param(
    [Parameter(Mandatory = $true)][string]$ConfigPath,
    [Parameter(Mandatory = $true, ParameterSetName = 'Report')][string]$ReportPath,
    [Parameter(Mandatory = $true, ParameterSetName = 'Test')][switch]$Test
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
if (-not $config.Email.Enabled) { return }

if ($Test) {
    $report = [pscustomobject]@{
        Success = $true; SiteUrl = 'Teste de configuracao'; Apply = $false
        FilesProcessed = 0; VersionsDeleted = 0; BytesFreed = 0
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
    MODE = $(if ($report.Apply) { 'Aplicacao' } else { 'Simulacao' })
    FILES = [string]$report.FilesProcessed; DELETED = [string]$report.VersionsDeleted
    FREED = ('{0:N2} GB' -f ([double]$report.BytesFreed / 1GB))
    SKIPPED = [string]$report.FilesSkipped; WARNINGS = $warningText
    ERROR = [Net.WebUtility]::HtmlEncode([string]$report.Error)
    FINISHED = ([datetime]$report.FinishedAt).ToString('dd/MM/yyyy HH:mm:ss')
}
foreach ($key in $values.Keys) { $template = $template.Replace("{{$key}}", $values[$key]) }

$message = [Net.Mail.MailMessage]::new()
$client = [Net.Mail.SmtpClient]::new([string]$config.Email.SmtpServer, [int]$config.Email.Port)
try {
    $message.From = [Net.Mail.MailAddress]::new([string]$config.Email.From)
    foreach ($recipient in $config.Email.To) { [void]$message.To.Add([string]$recipient) }
    $message.Subject = "[$status] SharePoint Version Cleanup - $($report.SiteUrl)"
    $message.Body = $template
    $message.IsBodyHtml = $true
    if (-not $Test -and $report.LogPath -and (Test-Path -LiteralPath $report.LogPath)) {
        [void]$message.Attachments.Add([Net.Mail.Attachment]::new([string]$report.LogPath))
    }
    $client.EnableSsl = [bool]$config.Email.UseSsl
    if ($config.Email.UserName) {
        $secure = ConvertTo-SecureString ([string]$config.Email.EncryptedPassword)
        $credential = [pscredential]::new([string]$config.Email.UserName, $secure)
        $client.Credentials = $credential.GetNetworkCredential()
    }
    $client.Send($message)
} finally {
    $message.Dispose()
    $client.Dispose()
}

