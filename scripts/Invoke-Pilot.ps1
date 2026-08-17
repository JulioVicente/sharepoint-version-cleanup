#requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ConfigPath,
    [Parameter(Mandatory = $true)][string]$SiteUrl,
    [switch]$Apply,
    [string]$Confirmation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$cleanupScript = Join-Path $PSScriptRoot 'cleanup-versions.ps1'
if (-not (Test-Path -LiteralPath $cleanupScript)) { throw "Script ausente: $cleanupScript" }
if (-not (Test-Path -LiteralPath $ConfigPath)) { throw "Configuracao ausente: $ConfigPath" }

$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
if ($SiteUrl -notin @($config.Sites)) {
    throw 'O site piloto deve estar explicitamente cadastrado em config.json.'
}

if ($Apply -and $Confirmation -cne 'APLICAR NO SITE PILOTO') {
    throw "Para efetivar o piloto, informe -Confirmation 'APLICAR NO SITE PILOTO'."
}

$before = @(Get-ChildItem -LiteralPath $config.Paths.Logs -Filter 'report-*.json' -ErrorAction SilentlyContinue |
    Select-Object -ExpandProperty FullName)
$arguments = @{ ConfigPath = $ConfigPath; SiteUrl = $SiteUrl }
if ($Apply) { $arguments.Apply = $true }
& $cleanupScript @arguments

$reportFile = Get-ChildItem -LiteralPath $config.Paths.Logs -Filter 'report-*.json' |
    Where-Object FullName -NotIn $before |
    Sort-Object LastWriteTimeUtc -Descending |
    Select-Object -First 1
if (-not $reportFile) { throw 'A execucao terminou sem gerar relatorio.' }

$report = Get-Content -LiteralPath $reportFile.FullName -Raw | ConvertFrom-Json
Write-Host "`nResultado do piloto" -ForegroundColor Cyan
Write-Host "Site: $($report.SiteUrl)"
Write-Host "Modo: $(if ($report.Apply) { 'APLICADO' } else { 'SIMULACAO' })"
Write-Host "Arquivos: $($report.FilesProcessed)"
Write-Host "Versoes elegiveis/removidas: $($report.VersionsDeleted)"
Write-Host "Ignorados: $($report.FilesSkipped)"
Write-Host "Relatorio: $($reportFile.FullName)"

if (-not $Apply) {
    Write-Warning "Revise o relatorio e os logs. Para o piloto real, repita com -Apply -Confirmation 'APLICAR NO SITE PILOTO'."
}

