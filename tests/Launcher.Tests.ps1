BeforeAll {
    . (Join-Path $PSScriptRoot '../bootstrap.ps1') -WhatIf
    function Invoke-TestRuntime {
        $script:runtimeCalls.Add(@($args))
        $global:LASTEXITCODE = $script:runtimeExitCode
    }
}
Describe 'Modos de manutencao do bootstrap' {
    BeforeEach {
        $script:runtimeCalls = [Collections.Generic.List[object]]::new()
        $script:runtimeExitCode = 0
        Mock Get-CleanupLauncherComponent { param($RelativePath) $RelativePath }
    }
    It 'desinstala sem iniciar assistente de configuracao' {
        Invoke-CleanupLauncher -PowerShellPath Invoke-TestRuntime -InstallPath 'C:\App' -RepositoryRawUrl 'https://example.invalid' -Uninstall
        $script:runtimeCalls.Count | Should -Be 1
        $script:runtimeCalls[0] | Should -Contain 'scripts/Uninstall.ps1'
        $script:runtimeCalls[0] | Should -Not -Contain '-Force'
        Should -Invoke Get-CleanupLauncherComponent -Times 0 -ParameterFilter { $RelativePath -eq 'Install.ps1' }
    }
    It 'instalacao limpa executa desinstalador e depois wizard com parametros preservados' {
        Invoke-CleanupLauncher -PowerShellPath Invoke-TestRuntime -InstallPath 'C:\App With Spaces' -RepositoryRawUrl 'https://example.invalid' -CleanInstall -Force -SkipEmailTest
        $script:runtimeCalls.Count | Should -Be 2
        $script:runtimeCalls[0] | Should -Contain 'scripts/Uninstall.ps1'
        $script:runtimeCalls[0] | Should -Contain '-Force'
        $script:runtimeCalls[1] | Should -Contain 'Install.ps1'
        $script:runtimeCalls[1] | Should -Contain 'C:\App With Spaces'
        $script:runtimeCalls[1] | Should -Contain '-SkipEmailTest'
        $script:runtimeCalls[1] | Should -Not -Contain '-Force'
    }
    It 'falha ou cancelamento interrompe instalacao limpa' {
        $script:runtimeExitCode = 1
        { Invoke-CleanupLauncher -PowerShellPath Invoke-TestRuntime -InstallPath 'C:\App' -RepositoryRawUrl 'https://example.invalid' -CleanInstall } | Should -Throw '*Nenhuma nova instalacao*'
        $script:runtimeCalls.Count | Should -Be 1
        Should -Invoke Get-CleanupLauncherComponent -Times 0 -ParameterFilter { $RelativePath -eq 'Install.ps1' }
    }
    It 'mantem instalacao normal sem desinstalar' {
        Invoke-CleanupLauncher -PowerShellPath Invoke-TestRuntime -InstallPath 'C:\App' -RepositoryRawUrl 'https://example.invalid'
        $script:runtimeCalls.Count | Should -Be 1
        $script:runtimeCalls[0] | Should -Contain 'Install.ps1'
    }
    It 'recusa modos conflitantes antes de qualquer alteracao' {
        { & (Join-Path $PSScriptRoot '../bootstrap.ps1') -Uninstall -CleanInstall -WhatIf } | Should -Throw '*somente*'
        { & (Join-Path $PSScriptRoot '../bootstrap.ps1') -Force -WhatIf } | Should -Throw '*Force so*'
    }
}
Describe 'Integridade do desinstalador remoto' {
    It 'recusa desinstalador com hash diferente do manifesto' {
        Mock Invoke-RestMethod { @{Files=@{'scripts/Uninstall.ps1'='incorrect'}} }
        Mock Invoke-WebRequest { param($OutFile) 'fixture' | Set-Content -LiteralPath $OutFile }
        $downloads = [Collections.Generic.List[string]]::new()
        try {
            { Get-CleanupLauncherComponent -RelativePath 'scripts/Uninstall.ps1' -RepositoryRawUrl 'https://example.invalid' -Downloads $downloads } | Should -Throw '*SHA256*'
            $downloads.Count | Should -Be 1
        } finally { foreach ($path in $downloads) { Remove-Item -LiteralPath $path -Force } }
    }
}
