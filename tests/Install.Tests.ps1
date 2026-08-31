Describe 'Install.ps1 - Copy-ProjectFiles' {
    BeforeEach {
        Remove-Item -Path function:Copy-ProjectFiles -ErrorAction SilentlyContinue
        function Write-Step { param([string]$Message) }

        $installerScript = (Resolve-Path -LiteralPath (Join-Path (Get-Location) 'Install.ps1')).Path
        $tokens = $null
        $parseErrors = $null
        $installerAst = [System.Management.Automation.Language.Parser]::ParseFile($installerScript, [ref]$tokens, [ref]$parseErrors)
        if ($parseErrors) {
            throw ($parseErrors | ForEach-Object Message | Out-String)
        }
        $copyProjectFilesDefinition = $installerAst.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Copy-ProjectFiles'
        }, $true).Extent.Text
        if (-not $copyProjectFilesDefinition) {
            throw 'Nao foi possivel localizar a funcao Copy-ProjectFiles em Install.ps1.'
        }

        Invoke-Expression $copyProjectFilesDefinition
        $script:RequiredFiles = @('scripts/component.ps1')
        $script:RepositoryRawUrl = 'https://raw.githubusercontent.com/JulioVicente/sharepoint-version-cleanup/main'
        $RepositoryRawUrl = $script:RepositoryRawUrl
    }

    It 'aceita download somente com HTTP 200' {
        $destination = Join-Path $TestDrive 'install-root'

        Mock Invoke-WebRequest {
            param($Uri, $OutFile, [switch]$PassThru)
            Set-Content -LiteralPath $OutFile -Value 'ok'
            [pscustomobject]@{ StatusCode = 200 }
        }
        Mock Start-Sleep {}

        Copy-ProjectFiles -Destination $destination

        Test-Path (Join-Path $destination 'scripts\component.ps1') | Should -Be $true
        Should -Invoke -CommandName Invoke-WebRequest -Exactly -Times 1 -Scope It
        Should -Invoke -CommandName Start-Sleep -Exactly -Times 0 -Scope It
    }

    It 'repete com backoff exponencial e falha quando o status HTTP nao e 200' {
        $destination = Join-Path $TestDrive 'install-root'

        Mock Invoke-WebRequest {
            param($Uri, $OutFile, [switch]$PassThru)
            Set-Content -LiteralPath $OutFile -Value 'parcial'
            [pscustomobject]@{ StatusCode = 503 }
        }
        Mock Start-Sleep {}

        $errorMessage = $null
        try {
            Copy-ProjectFiles -Destination $destination
            throw 'Era esperado um erro ao validar um status HTTP diferente de 200.'
        } catch {
            $errorMessage = $_.Exception.Message
        }

        $errorMessage | Should -Match 'Componente obrigatorio indisponivel: https://raw\.githubusercontent\.com/JulioVicente/sharepoint-version-cleanup/main/scripts/component\.ps1'
        $errorMessage | Should -Match 'Retries executados: 2'
        $errorMessage | Should -Match 'Test-NetConnection raw\.githubusercontent\.com -Port 443'
        $errorMessage | Should -Match 'clone local do repositorio'

        Should -Invoke -CommandName Invoke-WebRequest -Exactly -Times 3 -Scope It
        Should -Invoke -CommandName Start-Sleep -Exactly -Times 2 -Scope It
        Should -Invoke -CommandName Start-Sleep -Exactly -Times 1 -Scope It -ParameterFilter { $Seconds -eq 2 }
        Should -Invoke -CommandName Start-Sleep -Exactly -Times 1 -Scope It -ParameterFilter { $Seconds -eq 4 }
        Test-Path (Join-Path $destination 'scripts\component.ps1') | Should -Be $false
    }
}
