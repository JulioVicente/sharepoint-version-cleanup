BeforeAll {
    . (Join-Path $PSScriptRoot '../scripts/Resilience.ps1')
}
Describe 'Tentativas limitadas' {
    BeforeEach {
        $settings = @{MaxRetries=2;BaseDelaySeconds=1;MaxDelaySeconds=5}
        $counter = @{Attempts=0}
        Mock Start-Sleep {}
    }
    It 'retoma timeout e retorna somente resultado bem sucedido' {
        $result = Invoke-WithRetry -Settings $settings -Operation {
            $counter.Attempts++
            if ($counter.Attempts -eq 1) { 'parcial'; throw [TimeoutException]::new('timeout') }
            'completo'
        }
        $counter.Attempts | Should -Be 2
        @($result).Count | Should -Be 1
        $result | Should -Be 'completo'
        Should -Invoke Start-Sleep -Times 1
    }
    It 'nao repete erro permanente' {
        { Invoke-WithRetry -Settings $settings -Operation { $counter.Attempts++; throw [UnauthorizedAccessException]::new('negado') } } | Should -Throw '*negado*'
        $counter.Attempts | Should -Be 1
        Should -Invoke Start-Sleep -Times 0
    }
    It 'encerra apos esgotar tentativas' {
        { Invoke-WithRetry -Settings $settings -Operation { $counter.Attempts++; throw [TimeoutException]::new('timeout') } } | Should -Throw
        $counter.Attempts | Should -Be 3
        Should -Invoke Start-Sleep -Times 2
    }
    It 'respeita Retry-After maior que teto calculado' {
        $response = [Net.Http.HttpResponseMessage]::new([Net.HttpStatusCode]::TooManyRequests)
        $response.Headers.RetryAfter = [Net.Http.Headers.RetryConditionHeaderValue]::new([TimeSpan]::FromSeconds(12))
        $error429 = [Microsoft.PowerShell.Commands.HttpResponseException]::new('throttled',$response)
        Invoke-WithRetry -Settings $settings -Operation { $counter.Attempts++; if ($counter.Attempts -eq 1) { throw $error429 } }
        Should -Invoke Start-Sleep -Times 1 -ParameterFilter { $Seconds -ge 12 }
    }
}
