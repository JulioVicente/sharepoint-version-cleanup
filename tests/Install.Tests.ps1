BeforeAll {
    if (-not (Get-Command Install-Module -ErrorAction SilentlyContinue)) {
        function Install-Module { throw 'A instalacao de modulos deve ser mockada nos testes.' }
    }
    $root = Split-Path $PSScriptRoot -Parent
    . (Join-Path $root 'Install.ps1') -WhatIf
    . (Join-Path $root 'scripts/Configuration.ps1')
}
Describe 'Installer' {
    It 'WhatIf nao escreve nem pergunta nem instala' {
        Mock Read-Host { throw 'Nao deve perguntar' }
        Mock Install-Module { throw 'Nao deve instalar' }
        Mock Invoke-WebRequest { throw 'Nao deve baixar' }
        $destination = Join-Path $TestDrive 'not-created'
        & (Join-Path $root 'Install.ps1') -InstallPath $destination -WhatIf
        & (Join-Path $root 'bootstrap.ps1') -InstallPath $destination -WhatIf
        Test-Path $destination | Should -BeFalse
        Should -Invoke Read-Host -Times 0
        Should -Invoke Invoke-WebRequest -Times 0
        Should -Invoke Install-Module -Times 0
    }
    It 'copia todos os componentes locais incluindo operacao e documentacao' {
        $destination = Join-Path $TestDrive 'installed'
        Copy-ProjectFiles -Destination $destination
        foreach ($relative in $script:RequiredFiles) {
            Test-Path (Join-Path $destination $relative) | Should -BeTrue
        }
        Test-Path (Join-Path $destination 'scripts/Enable-Production.ps1') | Should -BeTrue
        Test-Path (Join-Path $destination 'CONFIGURATION.md') | Should -BeTrue
    }
    It 'solicita novamente quando entrada e invalida' {
        $script:answers = [Collections.Generic.Queue[string]]::new()
        $script:answers.Enqueue('abc'); $script:answers.Enqueue('3')
        Mock Read-Host { $script:answers.Dequeue() }
        $n = Read-Validated -Prompt 'Retencao' -Validate { param($v) if ($v -notmatch '^\d+$') { throw 'Inteiro esperado' }; [int]$v }
        $n | Should -Be 3
        Should -Invoke Read-Host -Times 2
    }
    It 'permite deixar opcao de auditoria vazia no wizard' {
        Mock Read-Host { '' }
        $value = Read-Validated -Prompt 'Auditoria opcional' -AllowEmpty -Validate { param($v) $v }
        $value | Should -BeNullOrEmpty
        Should -Invoke Read-Host -Times 1
    }
    It 'resposta N retorna falso e nao aprova a exclusao' {
        Mock Read-Host { 'N' }
        Read-YesNo 'Aplicar?' | Should -BeFalse
    }
    It 'exemplo JSON e validado e email vem desligado' {
        $cfg = Read-CleanupConfiguration -Path (Join-Path $root 'config/config.example.json')
        $cfg.SchemaVersion | Should -Be 2
        $cfg.Email.Enabled | Should -BeFalse
    }
    It 'rejeita horario invalido no JSON' {
        $cfg = Get-Content (Join-Path $root 'config/config.example.json') -Raw | ConvertFrom-Json -AsHashtable
        $cfg.Schedule.Time = '25:00'
        { Read-CleanupConfiguration -Values $cfg } | Should -Throw '*Schedule*'
    }
}
