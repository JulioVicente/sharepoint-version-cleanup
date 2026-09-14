#requires -Version 7.4
[CmdletBinding(DefaultParameterSetName = 'Path')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Config')][string]$ConfigPath,
    [Parameter(Mandatory, ParameterSetName = 'Path')][string]$LogsPath,
    [datetime]$Date = (Get-Date).Date,
    [string]$OutputCsv
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($PSCmdlet.ParameterSetName -eq 'Config') {
    . (Join-Path $PSScriptRoot 'Configuration.ps1')
    $LogsPath = (Read-CleanupConfiguration -Path $ConfigPath).Paths.Logs
}
$files = @(Get-ChildItem -LiteralPath $LogsPath -Filter "audit-$($Date.ToString('yyyyMMdd'))-*.jsonl" -File -ErrorAction Stop)
$events = @(foreach ($file in $files) {
    $lineNumber = 0
    foreach ($line in (Get-Content -LiteralPath $file.FullName)) {
        $lineNumber++
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $line | ConvertFrom-Json -ErrorAction Stop }
        catch { throw "Auditoria invalida em $($file.FullName), linha $lineNumber. $($_.Exception.Message)" }
    }
})
if ($OutputCsv) {
    $events | Sort-Object Timestamp | Select-Object Timestamp,RunId,SiteUrl,FolderServerRelativeUrl,Mode,Event,Outcome,FileUrl,VersionId,VersionsToKeep,Reason,Error,
        @{n='Details';e={$_.Details | ConvertTo-Json -Depth 8 -Compress}} | Export-Csv -LiteralPath $OutputCsv -NoTypeInformation -Encoding utf8
}
[pscustomobject]@{
    Date = $Date.ToString('yyyy-MM-dd'); AuditFiles = $files.Count; Events = $events.Count
    RunsSucceeded = @($events | Where-Object { $_.Event -eq 'RunCompleted' -and $_.Outcome -eq 'Success' }).Count
    RunsFailed = @($events | Where-Object { $_.Event -eq 'RunCompleted' -and $_.Outcome -eq 'Failed' }).Count
    DirectoriesScanned = @($events | Where-Object Event -eq 'DirectoryScanned' | Select-Object SiteUrl,FileUrl -Unique).Count
    VersionsSimulated = @($events | Where-Object Event -eq 'VersionWouldDelete').Count
    VersionsDeleted = @($events | Where-Object Event -eq 'VersionDeleted').Count
    VersionFailures = @($events | Where-Object Event -eq 'VersionDeleteFailed').Count
    FileFailures = @($events | Where-Object Event -eq 'FileFailed').Count
    LibraryFailures = @($events | Where-Object Event -eq 'LibraryFailed').Count
    FilesWithVersionsDeleted = @($events | Where-Object Event -eq 'VersionDeleted' | Select-Object SiteUrl,FileUrl -Unique).Count
    SamplesInspected = @($events | Where-Object Event -eq 'SampleInspected').Count
    SampleDiscrepancies = @($events | Where-Object { $_.Event -eq 'SampleInspected' -and $_.Outcome -eq 'Discrepancy' }).Count
    SamplesFailed = @($events | Where-Object Event -eq 'SampleFailed').Count
    OutputCsv = $OutputCsv
}
