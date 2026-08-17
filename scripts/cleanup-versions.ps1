#requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ConfigPath,
    [Parameter(Mandatory = $true)][string]$SiteUrl,
    [switch]$Apply
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$startedAt = Get-Date
$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$siteKey = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($SiteUrl))).Substring(0, 16)
$logPath = Join-Path $config.Paths.Logs "cleanup-$siteKey-$($startedAt.ToString('yyyyMMdd-HHmmss')).log"
$checkpointPath = Join-Path $config.Paths.State "checkpoint-$siteKey.json"
$lockPath = Join-Path $config.Paths.State "cleanup-$siteKey.lock"
New-Item -ItemType Directory -Force -Path $config.Paths.Logs, $config.Paths.State | Out-Null

$lock = $null
$transcriptStarted = $false
$report = [ordered]@{
    Success = $false; SiteUrl = $SiteUrl; StartedAt = $startedAt; FinishedAt = $null
    Apply = [bool]$Apply; FilesProcessed = 0; VersionsDeleted = 0; BytesFreed = 0
    FilesSkipped = 0; Warnings = [Collections.Generic.List[string]]::new(); Error = $null; LogPath = $logPath
}

function Save-Checkpoint([string]$FileUrl) {
    # O cursor so e avancado depois que o arquivo inteiro termina com sucesso.
    @{ SiteUrl = $SiteUrl; LastSuccessfulFileUrl = $FileUrl; UpdatedAt = (Get-Date).ToString('o') } |
        ConvertTo-Json | Set-Content -LiteralPath $checkpointPath -Encoding utf8
}

try {
    $lock = [IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None')
    Start-Transcript -LiteralPath $logPath -Append | Out-Null
    $transcriptStarted = $true
    Import-Module PnP.PowerShell -MinimumVersion 3.0.0

    Write-Host "Conectando a $SiteUrl"
    $connection = Connect-PnPOnline -Url $SiteUrl -ClientId $config.Authentication.ClientId `
        -Tenant $config.Tenant -Thumbprint $config.Authentication.CertificateThumbprint -ReturnConnection

    $resumeAfter = $null
    if (Test-Path -LiteralPath $checkpointPath) {
        $savedCheckpoint = Get-Content -LiteralPath $checkpointPath -Raw | ConvertFrom-Json
        $resumeAfter = if ($savedCheckpoint.PSObject.Properties.Name -contains 'LastSuccessfulFileUrl') {
            $savedCheckpoint.LastSuccessfulFileUrl
        } else { $savedCheckpoint.LastFileUrl }
    }
    $resumeReached = [string]::IsNullOrWhiteSpace($resumeAfter)
    $libraries = Get-PnPList -Connection $connection | Where-Object {
        $_.BaseTemplate -eq 101 -and -not $_.Hidden -and -not $_.IsCatalog
    }

    foreach ($library in $libraries) {
        Write-Host "Biblioteca: $($library.Title)"
        $items = Get-PnPListItem -List $library.Id -PageSize 500 -Fields 'FileRef','FileLeafRef','FSObjType','_ComplianceTag','_ComplianceFlags' -Connection $connection
        foreach ($item in $items) {
            if ([int]$item['FSObjType'] -ne 0) { continue }
            $fileUrl = [string]$item['FileRef']
            if (-not $resumeReached) {
                if ($fileUrl -eq $resumeAfter) { $resumeReached = $true }
                continue
            }

            try {
                $complianceTag = [string]$item['_ComplianceTag']
                $complianceFlags = [string]$item['_ComplianceFlags']
                if (-not [string]::IsNullOrWhiteSpace($complianceTag) -or -not [string]::IsNullOrWhiteSpace($complianceFlags)) {
                    $report.FilesSkipped++
                    $report.Warnings.Add("Arquivo protegido por rotulo/politica de conformidade ignorado: $fileUrl")
                    Save-Checkpoint $fileUrl
                    continue
                }
                $file = Get-PnPFile -Url $fileUrl -AsFileObject -Connection $connection
                Get-PnPProperty -ClientObject $file -Property CheckOutType -Connection $connection | Out-Null
                if ([string]$file.CheckOutType -ne 'None') {
                    $report.FilesSkipped++
                    $report.Warnings.Add("Arquivo em checkout ignorado: $fileUrl")
                    Save-Checkpoint $fileUrl
                    continue
                }

                $versions = @(Get-PnPFileVersion -Url $fileUrl -Connection $connection | Sort-Object Created -Descending)
                $obsolete = @($versions | Select-Object -Skip ([int]$config.VersionsToKeep))
                foreach ($version in $obsolete) {
                    $size = if ($version.PSObject.Properties.Name -contains 'Size') { [long]$version.Size } else { 0L }
                    if ($Apply) {
                        Remove-PnPFileVersion -Url $fileUrl -Identity $version.Id -Force -Connection $connection
                    }
                    $report.VersionsDeleted++
                    $report.BytesFreed += $size
                }
                $report.FilesProcessed++
                Save-Checkpoint $fileUrl
            } catch {
                $report.FilesSkipped++
                $report.Warnings.Add("$fileUrl`: $($_.Exception.Message)")
                # Interromper preserva o ultimo cursor bem-sucedido. Assim este
                # arquivo sera tentado novamente, em vez de ser perdido no checkpoint.
                throw "Falha ao processar $fileUrl; checkpoint preservado para nova tentativa. $($_.Exception.Message)"
            }
        }
    }

    if (-not $resumeReached) {
        throw "O arquivo salvo no checkpoint nao foi encontrado: $resumeAfter. O checkpoint foi preservado para revisao manual."
    }

    $report.Success = $true
    Remove-Item -LiteralPath $checkpointPath -Force -ErrorAction SilentlyContinue
} catch [IO.IOException] {
    $report.Error = 'Ja existe uma limpeza em execucao para este site.'
    throw $report.Error
} catch {
    $report.Error = $_.Exception.Message
    throw
} finally {
    $report.FinishedAt = Get-Date
    if ($transcriptStarted) { Stop-Transcript | Out-Null }
    if ($lock) { $lock.Dispose() }
    Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue

    $reportPath = Join-Path $config.Paths.Logs "report-$siteKey-$($startedAt.ToString('yyyyMMdd-HHmmss')).json"
    $report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $reportPath -Encoding utf8
    if ($config.Email.Enabled) {
        $emailScript = Join-Path (Split-Path -Parent $PSCommandPath) 'Send-EmailReport.ps1'
        & $emailScript -ConfigPath $ConfigPath -ReportPath $reportPath
    }
}

if (-not $Apply) {
    Write-Warning 'Simulacao concluida. Nenhuma versao foi removida. Use -Apply para efetivar.'
}
