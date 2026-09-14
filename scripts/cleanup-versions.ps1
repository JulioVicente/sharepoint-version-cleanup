#requires -Version 7.4
[CmdletBinding(DefaultParameterSetName = 'Config')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'Config')][string]$ConfigPath,
    [Parameter(Mandatory = $true)][string]$SiteUrl,
    [switch]$Apply,
    [Parameter(Mandatory = $true, ParameterSetName = 'Direct')]
    [Parameter(ParameterSetName = 'Config')][Alias('Directory')][string]$FolderServerRelativeUrl,
    [Parameter(Mandatory = $true, ParameterSetName = 'Direct')][string]$Tenant,
    [Parameter(Mandatory = $true, ParameterSetName = 'Direct')][string]$ClientId,
    [Parameter(Mandatory = $true, ParameterSetName = 'Direct')][string]$CertificateThumbprint,
    [Parameter(ParameterSetName = 'Direct')][ValidateRange(1,2147483647)][int]$VersionsToKeep = 10,
    [Parameter(ParameterSetName = 'Direct')][ValidateRange(1,1000000)][int]$MaxVersionsPerRun = 1000,
    [Parameter(ParameterSetName = 'Direct')][ValidateRange(0,36500)][int]$MinimumVersionAgeDays = 30,
    [Parameter(ParameterSetName = 'Direct')][ValidateRange(0,1000)][int]$SamplesPerLibrary = 1,
    [Parameter(ParameterSetName = 'Direct')][string]$OutputDirectory = (Join-Path (Get-Location) '.spvc'),
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$startedAt = Get-Date
. (Join-Path $PSScriptRoot 'Configuration.ps1')
. (Join-Path $PSScriptRoot 'Resilience.ps1')
. (Join-Path $PSScriptRoot 'Sampling.ps1')
$config = if ($PSCmdlet.ParameterSetName -eq 'Direct') {
    $outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
    Read-CleanupConfiguration -Values @{
        Tenant = $Tenant; Sites = @($SiteUrl); VersionsToKeep = $VersionsToKeep
        Authentication = @{ ClientId = $ClientId; CertificateThumbprint = $CertificateThumbprint }
        Paths = @{ Logs = (Join-Path $outputRoot 'logs'); State = (Join-Path $outputRoot 'state') }
        Email = @{ Enabled = $false }
        Safety = @{ MaxVersionsPerRun = $MaxVersionsPerRun; MinimumVersionAgeDays = $MinimumVersionAgeDays }
        Sampling = @{ Enabled = ($SamplesPerLibrary -gt 0); SamplesPerLibrary = [math]::Max(1,$SamplesPerLibrary) }
    }
} else { Read-CleanupConfiguration $ConfigPath }
$SiteUrl = ConvertTo-SiteUrl $SiteUrl
if ($SiteUrl -notin $config.Sites) { throw 'SiteUrl deve estar cadastrado em Sites na configuracao.' }
$scopeFolder = ''
if (-not $FolderServerRelativeUrl -and $config.FolderScopes[$SiteUrl]) { $FolderServerRelativeUrl = $config.FolderScopes[$SiteUrl] }
if ($FolderServerRelativeUrl) {
    $scopeFolder = ConvertTo-CleanupFolder $FolderServerRelativeUrl $SiteUrl
}
if ($config.FolderScopes[$SiteUrl] -and $scopeFolder -ne $config.FolderScopes[$SiteUrl]) {
    throw 'O escopo solicitado difere da pasta autorizada na configuracao.'
}
$runId = $startedAt.ToString('yyyyMMdd-HHmmss-fffffff') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8)
$siteKey = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($SiteUrl))).Substring(0, 16)
$logPath = Join-Path $config.Paths.Logs "cleanup-$siteKey-$runId.log"
$mode = if ($Apply) { 'apply' } else { 'simulation' }
$scopeKey = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($scopeFolder.ToLowerInvariant()))).Substring(0, 8)
$checkpointPath = Join-Path $config.Paths.State "checkpoint-$siteKey-$mode-$scopeKey.json"
$inventoryPath = Join-Path $config.Paths.State "inventory-$siteKey-$scopeKey.json"
$policyKey = "$($config.VersionsToKeep)|$($config.Safety.MinimumVersionAgeDays)"
$ageCutoff = $startedAt.ToUniversalTime().AddDays(-$config.Safety.MinimumVersionAgeDays)
$lockPath = Join-Path $config.Paths.State "cleanup-$siteKey.lock"
New-Item -ItemType Directory -Force -Path $config.Paths.Logs, $config.Paths.State | Out-Null

$lock = $null
$transcriptStarted = $false
$report = [ordered]@{
    Success = $false; SiteUrl = $SiteUrl; StartedAt = $startedAt; FinishedAt = $null
    Apply = [bool]$Apply; VersionsToKeep = $config.VersionsToKeep; FilesProcessed = 0; VersionsDeleted = 0; BytesFreed = 0
    VersionsEligible = 0; BytesEligible = 0; NotificationError = $null
    FolderServerRelativeUrl = $scopeFolder
    FilesUnchanged = 0; ReportPath = (Join-Path $config.Paths.Logs "report-$siteKey-$runId.json")
    FilesSkipped = 0; Warnings = [Collections.Generic.List[string]]::new(); Error = $null; LogPath = $logPath
    AuditPaths = [Collections.Generic.List[string]]::new()
    FilesFailed = 0; LibrariesFailed = 0; Errors = [Collections.Generic.List[string]]::new()
    SamplesInspected = 0; SampleDiscrepancies = 0; SamplesFailed = 0
    LimitReached = $false; AuditBackupError = $null; PolicyKey = $policyKey; MaxVersionsPerRun = $config.Safety.MaxVersionsPerRun
}

function Write-AuditEvent {
    param([string]$Event, [string]$Outcome, [string]$FileUrl = '', [string]$VersionId = '',
        [string]$Reason = '', [string]$ErrorMessage = '', [hashtable]$Details = @{})
    $now = [DateTimeOffset]::Now
    $path = Join-Path $config.Paths.Logs "audit-$($now.ToString('yyyyMMdd'))-$siteKey-$runId.jsonl"
    $record = [ordered]@{
        Timestamp = $now.ToString('o'); RunId = $runId; SiteUrl = $SiteUrl
        FolderServerRelativeUrl = $scopeFolder; Mode = $mode; Event = $Event; Outcome = $Outcome
        FileUrl = $FileUrl; VersionId = $VersionId; Reason = $Reason; Error = $ErrorMessage
        VersionsToKeep = $config.VersionsToKeep; Details = $Details
    }
    $line = $record | ConvertTo-Json -Depth 8 -Compress
    [IO.File]::AppendAllText($path, $line + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
    if (-not $report.AuditPaths.Contains($path)) { $report.AuditPaths.Add($path) }
}

function Invoke-PnPRequest {
    param([scriptblock]$Operation)
    Invoke-WithRetry -Operation $Operation -Settings $config.Retry -OnRetry {
        param($retry)
        Write-AuditEvent -Event 'RequestRetry' -Outcome 'Retrying' -ErrorMessage $retry.Error -Details $retry
        Write-Warning "Falha temporaria; nova tentativa $($retry.Attempt) em $($retry.DelaySeconds) segundos."
    }
}
function Save-Checkpoint([string]$FileUrl) {
    # Atomic replacement prevents truncated state after interruption.
    if ($FileUrl) { $completed.Add($FileUrl) | Out-Null }
    @{ SiteUrl = $SiteUrl; Apply = [bool]$Apply; VersionsToKeep = $config.VersionsToKeep
        PolicyKey = $policyKey
        CompletedFiles = @($completed); UpdatedAt = (Get-Date).ToString('o') } |
        ConvertTo-Json -Depth 4 | Set-Content -LiteralPath "$checkpointPath.tmp" -Encoding utf8
    [IO.File]::Move("$checkpointPath.tmp", $checkpointPath, $true)
}

function Save-Inventory {
    @{ VersionsToKeep = $config.VersionsToKeep; PolicyKey = $policyKey; Files = $inventory } | ConvertTo-Json -Depth 5 |
        Set-Content -LiteralPath "$inventoryPath.tmp" -Encoding utf8
    [IO.File]::Move("$inventoryPath.tmp", $inventoryPath, $true)
}

try {
    try { $lock = [IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None') }
    catch [IO.IOException] { throw "Nao foi possivel adquirir o lock; outra limpeza pode estar em execucao para este site. $($_.Exception.Message)" }
    Write-AuditEvent -Event 'RunStarted' -Outcome 'Started' -Reason 'Preservar arquivo atual e N versoes historicas; excluir somente excedentes com Apply.' -Details @{
        Computer = [Environment]::MachineName; User = [Environment]::UserName
        ScriptSha256 = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash
    }
    Start-Transcript -LiteralPath $logPath -Append | Out-Null
    $transcriptStarted = $true
    Import-Module PnP.PowerShell -MinimumVersion 3.0.0

    Write-Host "Conectando a $SiteUrl"
    $connection = Invoke-PnPRequest { Connect-PnPOnline -Url $SiteUrl -ClientId $config.Authentication.ClientId `
        -Tenant $config.Tenant -Thumbprint $config.Authentication.CertificateThumbprint -ReturnConnection }
    if ($scopeFolder) {
        $null = Invoke-PnPRequest { Get-PnPFolder -Url $scopeFolder -Connection $connection -ErrorAction Stop }
    }

    $completed = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $inventory = @{}
    if ($Apply -and (Test-Path -LiteralPath $inventoryPath)) {
        $savedInventory = Get-Content -LiteralPath $inventoryPath -Raw | ConvertFrom-Json -AsHashtable
        if ($savedInventory.PolicyKey -eq $policyKey -and $savedInventory.Files -is [Collections.IDictionary]) {
            $inventory = $savedInventory.Files
        }
    }
    if (Test-Path -LiteralPath $checkpointPath) {
        $savedCheckpoint = Get-Content -LiteralPath $checkpointPath -Raw | ConvertFrom-Json -AsHashtable
        if ($savedCheckpoint.SiteUrl -ne $SiteUrl -or $savedCheckpoint.Apply -ne [bool]$Apply -or
            $savedCheckpoint.VersionsToKeep -ne $config.VersionsToKeep -or -not $savedCheckpoint.ContainsKey('CompletedFiles')) {
            throw 'Checkpoint incompativel com o site, modo ou retencao atual. Arquive-o antes de reiniciar.'
        }
        if ($savedCheckpoint.ContainsKey('PolicyKey') -and $savedCheckpoint.PolicyKey -ne $policyKey) { throw 'Checkpoint incompativel com a politica de idade/retencao.' }
        foreach ($url in $savedCheckpoint.CompletedFiles) { $completed.Add([string]$url) | Out-Null }
    }
    $scannedDirectories = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $libraries = Invoke-PnPRequest { Get-PnPList -Includes RootFolder,IsCatalog -Connection $connection } | Where-Object {
        $_.BaseTemplate -eq 101 -and -not $_.Hidden -and -not $_.IsCatalog
    }

    :libraryLoop foreach ($library in $libraries) {
        try {
        $libraryRoot = if ($library.PSObject.Properties.Name -contains 'RootFolder') { [string]$library.RootFolder.ServerRelativeUrl } else { '' }
        if ($scopeFolder -and $libraryRoot -and $scopeFolder -ne $libraryRoot -and
            -not $scopeFolder.StartsWith("$libraryRoot/", [StringComparison]::OrdinalIgnoreCase)) {
            Write-AuditEvent -Event 'LibrarySkipped' -Outcome 'Skipped' -FileUrl $libraryRoot -Reason 'Biblioteca fora do escopo configurado.'
            continue
        }
        Write-Host "Biblioteca: $($library.Title)"
        Write-AuditEvent -Event 'LibraryScanned' -Outcome 'Started' -FileUrl $libraryRoot -Details @{ Library = $library.Title; LibraryId = [string]$library.Id }
        $sampleCandidates = [Collections.Generic.List[object]]::new()
        $items = Invoke-PnPRequest { Get-PnPListItem -List $library.Id -PageSize 500 -Fields 'FileRef','FileLeafRef','FSObjType','Modified','UniqueId','_UIVersionString','_ComplianceTag','_ComplianceFlags','File_x0020_Size' -Connection $connection }
        foreach ($item in $items) {
            $fileUrl = [string]$item['FileRef']
            if ($scopeFolder -and -not $fileUrl.StartsWith("$scopeFolder/", [StringComparison]::OrdinalIgnoreCase)) { continue }
            $directory = if ([int]$item['FSObjType'] -ne 0) { $fileUrl } else { $fileUrl.Substring(0, $fileUrl.LastIndexOf('/')) }
            if ($scannedDirectories.Add($directory)) { Write-AuditEvent -Event 'DirectoryScanned' -Outcome 'Success' -FileUrl $directory }
            if ([int]$item['FSObjType'] -ne 0) { continue }
            if ($completed.Contains($fileUrl)) {
                Write-AuditEvent -Event 'FileSkipped' -Outcome 'Skipped' -FileUrl $fileUrl -Reason 'Concluido anteriormente neste checkpoint.'
                continue
            }

            try {
                $complianceTag = [string]$item['_ComplianceTag']
                $complianceFlags = [string]$item['_ComplianceFlags']
                if (-not [string]::IsNullOrWhiteSpace($complianceTag) -or
                    (-not [string]::IsNullOrWhiteSpace($complianceFlags) -and $complianceFlags -ne '0')) {
                    $report.FilesSkipped++
                    $report.Warnings.Add("Arquivo protegido por rotulo/politica de conformidade ignorado: $fileUrl")
                    Write-AuditEvent -Event 'FileSkipped' -Outcome 'Skipped' -FileUrl $fileUrl -Reason 'Rotulo ou flags de conformidade.'
                    Save-Checkpoint $fileUrl
                    continue
                }
                $file = Invoke-PnPRequest { Get-PnPFile -Url $fileUrl -AsFileObject -Connection $connection }
                Invoke-PnPRequest { Get-PnPProperty -ClientObject $file -Property CheckOutType -Connection $connection } | Out-Null
                if ([string]$file.CheckOutType -ne 'None') {
                    $report.FilesSkipped++
                    $report.Warnings.Add("Arquivo em checkout ignorado: $fileUrl")
                    Write-AuditEvent -Event 'FileSkipped' -Outcome 'Skipped' -FileUrl $fileUrl -Reason 'Arquivo em checkout.'
                    Save-Checkpoint $fileUrl
                    continue
                }

                # A persistent signature avoids rereading version history for unchanged files.
                # Missing metadata means process normally, never assume unchanged.
                $signature = ''
                if ($item['Modified'] -and $item['UniqueId'] -and $item['_UIVersionString']) {
                    $signature = "$($item['UniqueId'])|$(([datetime]$item['Modified']).ToUniversalTime().ToString('o'))|$($item['_UIVersionString'])"
                }
                if ($Apply -and $signature -and $inventory[$fileUrl] -and $inventory[$fileUrl].Signature -eq $signature -and
                    (-not $inventory[$fileUrl].RecheckAt -or [datetime]$inventory[$fileUrl].RecheckAt -gt $startedAt.ToUniversalTime())) {
                    $report.FilesUnchanged++
                    if ($config.Sampling.Enabled) { $sampleCandidates.Add($item) }
                    Write-AuditEvent -Event 'FileUnchanged' -Outcome 'Skipped' -FileUrl $fileUrl -Reason 'UniqueId, Modified e versao atual iguais ao inventario aplicado.'
                    Save-Checkpoint $fileUrl
                    continue
                }

                # Keep N historical versions in addition to the current version.
                $versions = @(Invoke-PnPRequest { Get-PnPFileVersion -Url $fileUrl -Connection $connection } |
                    Where-Object { -not ($_.PSObject.Properties.Name -contains 'IsCurrentVersion' -and $_.IsCurrentVersion) } |
                    Sort-Object Created, Id -Descending)
                $excess = @($versions | Select-Object -Skip ([int]$config.VersionsToKeep))
                $obsolete = @($excess | Where-Object { ([datetime]$_.Created).ToUniversalTime() -le $ageCutoff })
                $tooRecent = @($excess | Where-Object { ([datetime]$_.Created).ToUniversalTime() -gt $ageCutoff })
                Write-AuditEvent -Event 'RetentionDecision' -Outcome 'Success' -FileUrl $fileUrl `
                    -Reason 'Preservar atual e N historicas; excluir excedentes somente depois da idade minima.' `
                    -Details @{ HistoricalCount = $versions.Count; EligibleCount = $obsolete.Count
                        KeptVersionIds = @($versions | Select-Object -First ([int]$config.VersionsToKeep) | ForEach-Object { [string]$_.Id })
                        EligibleVersionIds = @($obsolete | ForEach-Object { [string]$_.Id }); CurrentVersionPreserved = $true; MinimumVersionAgeDays = $config.Safety.MinimumVersionAgeDays; DeferredVersionIds = @($tooRecent | ForEach-Object { [string]$_.Id }) }
                foreach ($version in $obsolete) {
                    $size = if ($version.PSObject.Properties.Name -contains 'Size') { [long]$version.Size } else { 0L }
                    $report.VersionsEligible++
                    $report.BytesEligible += $size
                    if ($Apply) {
                        if ($report.VersionsDeleted -ge $config.Safety.MaxVersionsPerRun) {
                            $report.LimitReached = $true
                            Write-AuditEvent -Event 'RunLimitReached' -Outcome 'Deferred' -FileUrl $fileUrl -Reason 'Teto de exclusoes por execucao; retomar os pendentes em nova execucao.'
                            break libraryLoop
                        }
                        Write-AuditEvent -Event 'VersionDeleteRequested' -Outcome 'Started' -FileUrl $fileUrl -VersionId $version.Id -Reason 'Versao excede a retencao historica.' -Details @{ Bytes = $size }
                        try { Invoke-PnPRequest { Remove-PnPFileVersion -Url $fileUrl -Identity $version.Id -Force -Connection $connection } | Out-Null }
                        catch {
                            Write-AuditEvent -Event 'VersionDeleteFailed' -Outcome 'Failed' -FileUrl $fileUrl -VersionId $version.Id -ErrorMessage $_.Exception.Message
                            throw
                        }
                        $report.VersionsDeleted++
                        $report.BytesFreed += $size
                        Write-AuditEvent -Event 'VersionDeleted' -Outcome 'Success' -FileUrl $fileUrl -VersionId $version.Id -Details @{ Bytes = $size }
                    } else {
                        Write-AuditEvent -Event 'VersionWouldDelete' -Outcome 'Simulated' -FileUrl $fileUrl -VersionId $version.Id -Reason 'Excede a retencao; Apply ausente.' -Details @{ Bytes = $size }
                    }
                }
                $report.FilesProcessed++
                Write-AuditEvent -Event 'FileCompleted' -Outcome 'Success' -FileUrl $fileUrl -Details @{ EligibleCount = $obsolete.Count; ContentModified = $false }
                if ($Apply -and $signature) {
                    $recheckAt = if ($tooRecent.Count) {
                        (($tooRecent | Sort-Object Created | Select-Object -First 1).Created.ToUniversalTime().AddDays($config.Safety.MinimumVersionAgeDays)).ToString('o')
                    } else { $null }
                    $inventory[$fileUrl] = @{ Signature = $signature; RecheckAt = $recheckAt }
                    Save-Inventory
                }
                Save-Checkpoint $fileUrl
            } catch {
                $report.FilesSkipped++
                $report.FilesFailed++
                $report.Warnings.Add("$fileUrl`: $($_.Exception.Message)")
                $report.Errors.Add("$fileUrl`: $($_.Exception.Message)")
                try { Write-AuditEvent -Event 'FileFailed' -Outcome 'Failed' -FileUrl $fileUrl -ErrorMessage $_.Exception.Message } catch { Write-Warning 'Falha ao gravar auditoria do erro.' }
                # Only successful files enter the checkpoint; later files can continue.
                continue
            }
        }
        if ($sampleCandidates.Count) {
            $libraryKey = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes([string]$library.Id))).Substring(0,16)
            $samplePath = Join-Path $config.Paths.State "sampling-$siteKey-$scopeKey-$libraryKey.json"
            $sampleState = @{ CycleId = [guid]::NewGuid().ToString('N'); CompletedIds = @() }
            if (Test-Path -LiteralPath $samplePath) {
                $sampleState = Get-Content -LiteralPath $samplePath -Raw | ConvertFrom-Json -AsHashtable
                if (-not $sampleState.CycleId -or -not $sampleState.ContainsKey('CompletedIds')) { throw 'Estado da amostragem invalido.' }
            }
            $samples = @(Select-WeightedSample -Items $sampleCandidates.ToArray() -Settings $config.Sampling -State $sampleState -Now $startedAt)
            foreach ($sample in $samples) {
                $sampleUrl = [string]$sample.Item['FileRef']
                try {
                    Write-AuditEvent -Event 'SampleSelected' -Outcome 'Started' -FileUrl $sampleUrl `
                        -Reason 'Sorteio ponderado entre arquivos inalterados; tamanho e modificacao recente aumentam o peso.' `
                        -Details @{ CycleId=$sample.CycleId; Weight=$sample.Factors.Weight; SizeBytes=$sample.Factors.SizeBytes
                            SizeKnown=$sample.Factors.SizeKnown; AgeDays=$sample.Factors.AgeDays; CandidateCount=$sample.CandidateCount
                            FirstDrawProbability=$sample.FirstDrawProbability; ReadOnly=$true; SizeWeight=$config.Sampling.SizeWeight; RecencyWeight=$config.Sampling.RecencyWeight; RecencyHalfLifeDays=$config.Sampling.RecencyHalfLifeDays }
                    $sampleVersions = @(Invoke-PnPRequest { Get-PnPFileVersion -Url $sampleUrl -Connection $connection } |
                        Where-Object { -not ($_.PSObject.Properties.Name -contains 'IsCurrentVersion' -and $_.IsCurrentVersion) } |
                        Sort-Object Created,Id -Descending)
                    $sampleEligible = @($sampleVersions | Select-Object -Skip $config.VersionsToKeep |
                        Where-Object { ([datetime]$_.Created).ToUniversalTime() -le $ageCutoff })
                    if ($sampleEligible.Count) {
                        $report.SampleDiscrepancies++
                        $report.Warnings.Add("Amostragem encontrou versoes elegiveis em arquivo inalterado: $sampleUrl. Reavaliacao na proxima execucao.")
                        $inventory.Remove($sampleUrl)
                        Save-Inventory
                        $null = $completed.Remove($sampleUrl)
                        Save-Checkpoint ''
                    }
                    Write-AuditEvent -Event 'SampleInspected' -Outcome $(if ($sampleEligible.Count) { 'Discrepancy' } else { 'Success' }) -FileUrl $sampleUrl `
                        -Reason $(if ($sampleEligible.Count) { 'Inventario invalidado para reavaliacao na proxima execucao.' } else { 'Nenhuma versao elegivel segundo a politica atual.' }) `
                        -Details @{ CycleId=$sample.CycleId; HistoricalCount=$sampleVersions.Count; EligibleCount=$sampleEligible.Count; ReadOnly=$true }
                    $sampleState.CompletedIds = @($sampleState.CompletedIds) + @($sample.Id)
                    $sampleState | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$samplePath.tmp" -Encoding utf8
                    [IO.File]::Move("$samplePath.tmp",$samplePath,$true)
                    $report.SamplesInspected++
                } catch {
                    $report.SamplesFailed++
                    $report.Errors.Add("Amostragem $sampleUrl`: $($_.Exception.Message)")
                    Write-AuditEvent -Event 'SampleFailed' -Outcome 'Failed' -FileUrl $sampleUrl -ErrorMessage $_.Exception.Message
                    $inventory.Remove($sampleUrl)
                    Save-Inventory
                    $null = $completed.Remove($sampleUrl)
                    Save-Checkpoint ''
                }
            }
        }
        } catch {
            $report.LibrariesFailed++
            $report.Errors.Add("Biblioteca $($library.Title): $($_.Exception.Message)")
            try { Write-AuditEvent -Event 'LibraryFailed' -Outcome 'Failed' -ErrorMessage $_.Exception.Message -Details @{ Library = $library.Title } }
            catch { Write-Warning 'Falha ao gravar auditoria da biblioteca.' }
            continue
        }
    }

    if ($report.LimitReached) { throw 'Limite de exclusoes atingido; progresso preservado para nova execucao.' }
    if ($report.Errors.Count) {
        throw "Execucao parcial; itens com falha serao tentados novamente. $($report.Errors -join '; ')"
    }
    $report.Success = $true
    Remove-Item -LiteralPath $checkpointPath -Force -ErrorAction SilentlyContinue
} catch {
    $report.Error = $_.Exception.Message
    throw
} finally {
    $report.FinishedAt = Get-Date
    if ($transcriptStarted) { try { Stop-Transcript | Out-Null } catch { Write-Warning $_.Exception.Message } }
    # Keep the lock file: unlinking it after release races with the next process.

    $reportPath = Join-Path $config.Paths.Logs "report-$siteKey-$runId.json"
    try {
    Write-AuditEvent -Event 'RunCompleted' -Outcome $(if ($report.Success) { 'Success' } else { 'Failed' }) -ErrorMessage $report.Error `
        -Details @{ FilesProcessed = $report.FilesProcessed; FilesUnchanged = $report.FilesUnchanged; FilesSkipped = $report.FilesSkipped
            VersionsEligible = $report.VersionsEligible; VersionsDeleted = $report.VersionsDeleted }
    if ($config.Audit.CopyDirectory) {
        try {
            New-Item -ItemType Directory -Path $config.Audit.CopyDirectory -Force | Out-Null
            foreach ($auditPath in $report.AuditPaths) { Copy-Item -LiteralPath $auditPath -Destination $config.Audit.CopyDirectory -Force }
        } catch {
            $report.AuditBackupError = $_.Exception.Message
            Write-AuditEvent -Event 'AuditCopyFailed' -Outcome 'Failed' -ErrorMessage $_.Exception.Message
            Write-Warning "Copia externa da auditoria falhou: $($_.Exception.Message)"
        }
    }
    $report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $reportPath -Encoding utf8
    if ($config.Email.Enabled) {
        $emailScript = Join-Path (Split-Path -Parent $PSCommandPath) 'Send-EmailReport.ps1'
        try { & $emailScript -ConfigPath $ConfigPath -ReportPath $reportPath }
        catch {
            $report.NotificationError = $_.Exception.Message
            $report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $reportPath -Encoding utf8
            Write-Warning "Falha no email; consulte o relatorio local: $($_.Exception.Message)"
        }
    }
    } finally { if ($lock) { $lock.Dispose() } }
}

if (-not $Apply) {
    Write-Warning 'Simulacao concluida. Nenhuma versao foi removida. Use -Apply para efetivar.'
}
if ($PassThru) { [pscustomobject]$report }
else {
    Write-Host "Arquivos: $($report.FilesProcessed); sem alteracao: $($report.FilesUnchanged); ignorados: $($report.FilesSkipped)"
    Write-Host "Versoes elegiveis: $($report.VersionsEligible); excluidas: $($report.VersionsDeleted)"
    Write-Host "Relatorio: $($report.ReportPath)"
}
