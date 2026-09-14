#requires -Version 7.4
function Get-SamplingWeight {
    param($Item, [System.Collections.IDictionary]$Settings, [datetime]$Now = [datetime]::UtcNow)
    $bytes = 0L
    $rawSize = $Item['File_x0020_Size']
    if ($null -ne $rawSize -and $rawSize.PSObject.Properties['LookupValue']) { $rawSize = $rawSize.LookupValue }
    $sizeKnown = [long]::TryParse(([string]$rawSize -replace '^.*;#',''), [ref]$bytes) -and $bytes -ge 0
    if (-not $sizeKnown) { $bytes = 0L }
    $ageDays = $null
    $recency = 0.0
    if ($Item['Modified']) {
        try {
            $ageDays = [math]::Max(0, ($Now.ToUniversalTime() - ([datetime]$Item['Modified']).ToUniversalTime()).TotalDays)
            $recency = [math]::Pow(0.5, $ageDays / $Settings.RecencyHalfLifeDays)
        } catch { $ageDays = $null }
    }
    $sizeScore = [math]::Log(1 + $bytes / 1MB, 2)
    [pscustomobject]@{
        Weight = 1.0 + $Settings.SizeWeight * $sizeScore + $Settings.RecencyWeight * $recency
        SizeBytes = $bytes; SizeKnown = $sizeKnown; AgeDays = $ageDays
        SizeScore = $sizeScore; RecencyScore = $recency
    }
}

function Select-WeightedSample {
    param([AllowEmptyCollection()][object[]]$Items, [System.Collections.IDictionary]$Settings,
        [System.Collections.IDictionary]$State, [datetime]$Now = [datetime]::UtcNow)
    if (-not $Settings.Enabled -or -not $Items.Count) { return }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($id in $State.CompletedIds) { $null = $seen.Add([string]$id) }
    $candidates = @(foreach ($item in $Items) {
        $id = if ($item['UniqueId']) { [string]$item['UniqueId'] } else { [string]$item['FileRef'] }
        [pscustomobject]@{ Id = $id; Item = $item; Factors = (Get-SamplingWeight $item $Settings $Now) }
    })
    $remaining = @($candidates | Where-Object { -not $seen.Contains($_.Id) })
    if (-not $remaining.Count) {
        $State.CompletedIds = @()
        $State.CycleId = [guid]::NewGuid().ToString('N')
        $remaining = $candidates
    }
    # Exponential race: independent keys give weighted sampling without replacement.
    # Every weight is >= 1; no file is excluded merely because it is small or old.
    $ranked = foreach ($candidate in $remaining) {
        $uniform = (Get-Random -Minimum 1 -Maximum 2147483647) / 2147483647.0
        [pscustomobject]@{ Candidate = $candidate; Key = -[math]::Log($uniform) / $candidate.Factors.Weight }
    }
    $totalWeight = ($remaining | Measure-Object -Property { $_.Factors.Weight } -Sum).Sum
    $ranked | Sort-Object Key | Select-Object -First $Settings.SamplesPerLibrary | ForEach-Object {
        [pscustomobject]@{
            Id = $_.Candidate.Id; Item = $_.Candidate.Item; Factors = $_.Candidate.Factors
            CycleId = $State.CycleId; CandidateCount = $remaining.Count
            FirstDrawProbability = $_.Candidate.Factors.Weight / $totalWeight
        }
    }
}
