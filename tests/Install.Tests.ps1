Describe 'Install.ps1' {
    BeforeAll {
        $installScript = (Resolve-Path (Join-Path $PSScriptRoot '../Install.ps1')).Path
        . $installScript -SkipAutoRun
    }

    BeforeEach {
        $RepositoryRawUrl = 'https://raw.githubusercontent.com/JulioVicente/sharepoint-version-cleanup/main'
        $script:RequiredFiles = @(
            'scripts/cleanup-versions.ps1',
            'scripts/Send-EmailReport.ps1',
            'scripts/Enable-Production.ps1',
            'scripts/Invoke-Pilot.ps1',
            'templates/email-template.html',
            'config/config.example.json'
        )
    }

    It 'constroi cabecalhos sem cache para cargas remotas' {
        $headers = New-NoCacheHeaders

        $headers['Cache-Control'] | Should -Be 'no-cache, no-store, must-revalidate'
        $headers['Pragma'] | Should -Be 'no-cache'
        $headers['Expires'] | Should -Be '0'
    }

    It 'separa base e branch ao receber uma URL remota customizada' {
        $RepositoryRawUrl = 'https://mirror.example/repos/sharepoint-version-cleanup/release'

        $location = Get-RepositoryRawLocation

        $location.BaseUrl | Should -Be 'https://mirror.example/repos/sharepoint-version-cleanup'
        $location.ConfiguredBranch | Should -Be 'release'
    }

    It 'resolve a primeira branch candidata disponivel para componente obrigatorio' {
        Mock Invoke-WebRequest {
            if ($Uri -match '/main/') {
                throw [System.Exception]::new('404')
            }

            [pscustomobject]@{ StatusCode = 200 }
        }

        $result = Resolve-RequiredFileRemoteUrl -RelativePath 'scripts/cleanup-versions.ps1'

        $result.Branch | Should -Be 'master'
        $result.Uri | Should -Match '/master/scripts/cleanup-versions\.ps1$'
        Assert-MockCalled Invoke-WebRequest -Scope It -ParameterFilter { $Uri -match '/main/' }
        Assert-MockCalled Invoke-WebRequest 1 -Scope It -ParameterFilter { $Uri -match '/master/' -and $Method -eq 'Head' }
    }

    It 'falha com mensagem clara quando nenhuma branch candidata contem o componente' {
        Mock Invoke-WebRequest { throw [System.Exception]::new('404') }

        { Resolve-RequiredFileRemoteUrl -RelativePath 'scripts/inexistente.ps1' } |
            Should -Throw 'Componente obrigatorio remoto indisponivel: scripts/inexistente.ps1. Branches testadas: main, master.'
    }

    It 'baixa arquivo obrigatorio sem cache e valida o payload salvo' {
        $destination = Join-Path $TestDrive 'install'
        Mock Resolve-RequiredFileRemoteUrl {
            [pscustomobject]@{
                RelativePath      = $RelativePath
                Branch            = 'main'
                Uri               = 'https://raw.githubusercontent.com/JulioVicente/sharepoint-version-cleanup/main/scripts/custom.ps1'
                AttemptedBranches = @('main')
            }
        }
        Mock Invoke-WebRequest {
            Set-Content -LiteralPath $OutFile -Value 'payload' -Encoding utf8
        } -ParameterFilter { $null -ne $OutFile }

        $savedPath = Save-RequiredFileFromRepository -RelativePath 'scripts/custom.ps1' -Destination $destination

        Test-Path -LiteralPath $savedPath | Should -Be $true
        (Get-Item -LiteralPath $savedPath).Length | Should -BeGreaterThan 0
        Assert-MockCalled Invoke-WebRequest 1 -Scope It -ParameterFilter {
            $Headers['Cache-Control'] -eq 'no-cache, no-store, must-revalidate' -and
            $Headers['Pragma'] -eq 'no-cache' -and
            $Headers['Expires'] -eq '0'
        }
    }

    It 'percorre todos os componentes obrigatorios configurados' {
        $script:RequiredFiles = @(
            'scripts/a.ps1',
            'templates/b.html',
            'config/c.json'
        )
        Mock Save-RequiredFileFromRepository {}

        Copy-ProjectFiles -Destination (Join-Path $TestDrive 'install')

        Assert-MockCalled Save-RequiredFileFromRepository 3 -Scope It
    }
}
