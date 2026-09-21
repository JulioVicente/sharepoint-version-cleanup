BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    $productionScript = Join-Path $root 'scripts/Enable-Production.ps1'
    function global:Get-ScheduledTask { param($TaskName,$TaskPath) }
    function global:New-ScheduledTaskAction { param($Execute,$Argument) }
    function global:Set-ScheduledTask { param($TaskName,$TaskPath,$Action) }
}
AfterAll {
    'Get-ScheduledTask','New-ScheduledTaskAction','Set-ScheduledTask' | ForEach-Object { Remove-Item "function:global:$_" }
}
Describe 'Production scope' {
    BeforeEach {
        $installation = Join-Path $TestDrive 'installed'
        New-Item -ItemType Directory -Path (Join-Path $installation 'config'),(Join-Path $installation 'logs') -Force | Out-Null
        $configPath = Join-Path $installation 'config/config.json'
        $cfg = Get-Content (Join-Path $root 'config/config.example.json') -Raw | ConvertFrom-Json -AsHashtable
        $cfg.Sites = @('https://contoso.sharepoint.com')
        $cfg.FolderScopes = @{ 'https://contoso.sharepoint.com' = '/teste03' }
        $cfg.Paths.Logs = Join-Path $installation 'logs'
        $cfg.Paths.State = Join-Path $installation 'state'
        $cfg | ConvertTo-Json -Depth 6 | Set-Content $configPath
        @{SiteUrl='https://contoso.sharepoint.com';Success=$true;Apply=$true;VersionsToKeep=10;PolicyKey='10|30';FilesProcessed=1;FilesSkipped=0;VersionsDeleted=2;FolderServerRelativeUrl='/teste03';FinishedAt=(Get-Date).AddMinutes(-1)} |
            ConvertTo-Json | Set-Content (Join-Path $cfg.Paths.Logs 'report-pilot.json')
        Mock Get-ScheduledTask { [pscustomobject]@{TaskName='SharePoint Version Cleanup - 01'; Actions=@([pscustomobject]@{Execute='C:\Program Files\PowerShell\7\pwsh.exe';Arguments='wrong-scope'})} }
        Mock New-ScheduledTaskAction { [pscustomobject]@{Execute=$Execute;Arguments=$Argument} }
        Mock Set-ScheduledTask {}
    }
    It 'nao promove tarefa de outro escopo' {
        { & $productionScript -ConfigPath $configPath -PilotSiteUrl 'https://contoso.sharepoint.com' -PilotFolderServerRelativeUrl '/teste03' -TaskName 'SharePoint Version Cleanup - 01' -Confirmation 'ATIVAR PRODUCAO' } | Should -Throw '*escopo*'
        Should -Invoke Set-ScheduledTask -Times 0
    }
    It 'recusa piloto cuja idade minima difere da politica atual' {
        $cfg.Safety.MinimumVersionAgeDays = 0
        $cfg | ConvertTo-Json -Depth 6 | Set-Content $configPath
        { & $productionScript -ConfigPath $configPath -PilotSiteUrl 'https://contoso.sharepoint.com' -PilotFolderServerRelativeUrl '/teste03' -TaskName 'SharePoint Version Cleanup - 01' -Confirmation 'ATIVAR PRODUCAO' } | Should -Throw '*Nenhum piloto*'
        Should -Invoke Set-ScheduledTask -Times 0
    }
    It 'promove somente a tarefa explicitamente indicada e validada' {
        $expectedArgs = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$(Join-Path $installation 'scripts\cleanup-versions.ps1')`" -ConfigPath `"$configPath`" -SiteUrl `"https://contoso.sharepoint.com`" -FolderServerRelativeUrl `"/teste03`""
        Mock Get-ScheduledTask { [pscustomobject]@{TaskName='SharePoint Version Cleanup - 01';Actions=@([pscustomobject]@{Execute='C:\Program Files\PowerShell\7\pwsh.exe';Arguments=$expectedArgs})} }
        & $productionScript -ConfigPath $configPath -PilotSiteUrl 'https://contoso.sharepoint.com' -PilotFolderServerRelativeUrl '/teste03' -TaskName 'SharePoint Version Cleanup - 01' -Confirmation 'ATIVAR PRODUCAO'
        Should -Invoke Set-ScheduledTask -Times 1 -ParameterFilter { $TaskName -eq 'SharePoint Version Cleanup - 01' -and $Action.Arguments.EndsWith(' -Apply') }
    }
}
