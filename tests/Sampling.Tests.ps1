BeforeAll {
    . (Join-Path $PSScriptRoot '../scripts/Sampling.ps1')
    . (Join-Path $PSScriptRoot '../scripts/Configuration.ps1')
}
Describe 'Amostragem ponderada' {
    BeforeEach {
        $settings = @{Enabled=$true;SamplesPerLibrary=1;SizeWeight=1;RecencyWeight=4;RecencyHalfLifeDays=30}
        $now = [datetime]'2026-09-14T00:00:00Z'
        $state = @{CycleId='cycle-1';CompletedIds=@()}
    }
    It 'da mais peso a tamanho maior e modificacao mais recente' {
        $small = Get-SamplingWeight @{File_x0020_Size=1MB;Modified=$now.AddDays(-30)} $settings $now
        $large = Get-SamplingWeight @{File_x0020_Size=1GB;Modified=$now.AddDays(-30)} $settings $now
        $recent = Get-SamplingWeight @{File_x0020_Size=1GB;Modified=$now} $settings $now
        $large.Weight | Should -BeGreaterThan $small.Weight
        $recent.Weight | Should -BeGreaterThan $large.Weight
        $small.RecencyScore | Should -Be 0.5
    }
    It 'mantem peso minimo e trata dados ausentes ou invalidos' {
        $w = Get-SamplingWeight @{File_x0020_Size='invalido';Modified='invalido'} $settings $now
        $w.Weight | Should -Be 1
        $w.SizeKnown | Should -BeFalse
        $w = Get-SamplingWeight @{File_x0020_Size='42;#1048576'} $settings $now
        $w.SizeBytes | Should -Be 1MB
    }
    It 'aplica peso ao sorteio sem transformar prioridade em exclusao dos pequenos' {
        Mock Get-Random { 1000000000 }
        $items = @(@{UniqueId='small';FileRef='/docs/small';File_x0020_Size=1MB;Modified=$now},@{UniqueId='large';FileRef='/docs/large';File_x0020_Size=1GB;Modified=$now})
        $sample = @(Select-WeightedSample $items $settings $state $now)
        $sample[0].Id | Should -Be 'large'
        $sample[0].FirstDrawProbability | Should -BeGreaterThan 0.5
        $state.CompletedIds = @('large')
        $sample = @(Select-WeightedSample $items $settings $state $now)
        $sample[0].Id | Should -Be 'small'
        $sample[0].FirstDrawProbability | Should -Be 1
    }
    It 'nao repete dentro do ciclo e reinicia quando candidatos foram conferidos' {
        $settings.SamplesPerLibrary = 5
        $items = @(@{UniqueId='a';FileRef='/docs/a'},@{UniqueId='b';FileRef='/docs/b'})
        $state.CompletedIds = @('a')
        $sample = @(Select-WeightedSample $items $settings $state $now)
        $sample.Count | Should -Be 1
        $sample[0].Id | Should -Be 'b'
        $state.CompletedIds = @('a','b')
        $sample = @(Select-WeightedSample $items $settings $state $now)
        $sample.Count | Should -Be 2
        @($sample.Id | Select-Object -Unique).Count | Should -Be 2
        $state.CycleId | Should -Not -Be 'cycle-1'
    }
    It 'nao sorteia quando desligado ou sem candidatos' {
        @(Select-WeightedSample @() $settings $state $now).Count | Should -Be 0
        $settings.Enabled = $false
        @(Select-WeightedSample @(@{FileRef='/docs/a'}) $settings $state $now).Count | Should -Be 0
    }
    It 'valida os parametros de amostragem do JSON' {
        $cfg = Get-Content (Join-Path $PSScriptRoot '../config/config.example.json') -Raw | ConvertFrom-Json -AsHashtable
        $cfg.Sampling = @{RecencyHalfLifeDays=0}
        { Read-CleanupConfiguration -Values $cfg } | Should -Throw '*RecencyHalfLifeDays*'
        $cfg.Sampling = @{Enabled='sim'}
        { Read-CleanupConfiguration -Values $cfg } | Should -Throw '*Enabled*'
    }
}
