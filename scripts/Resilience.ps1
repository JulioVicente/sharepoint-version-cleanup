#requires -Version 7.4.6
function Invoke-WithRetry {
    [CmdletBinding()]
    param([Parameter(Mandatory)][scriptblock]$Operation, [Parameter(Mandatory)][System.Collections.IDictionary]$Settings, [scriptblock]$OnRetry)
    for ($attempt = 0; ; $attempt++) {
        try {
            $result = @(& $Operation)
            return $result
        } catch {
            $exception = $_.Exception
            $status = 0
            $retryAfter = 0.0
            $transient = $false
            for ($current = $exception; $null -ne $current; $current = $current.InnerException) {
                if ($current.PSObject.Properties.Name -contains 'StatusCode' -and $current.StatusCode) { $status = [int]$current.StatusCode }
                if ($current -is [TimeoutException] -or $current -is [Net.Sockets.SocketException]) { $transient = $true }
                if ($current -is [Net.Http.HttpRequestException] -and -not $current.StatusCode) { $transient = $true }
                if ($current -is [Threading.Tasks.TaskCanceledException]) { $transient = $true }
                if ($current -is [Net.WebException] -and $current.Status -in 'Timeout','ConnectFailure','ConnectionClosed','ReceiveFailure','SendFailure') { $transient = $true }
                if ($current.PSObject.Properties.Name -contains 'Response' -and $current.Response) {
                    $response = $current.Response
                    if ($response.PSObject.Properties.Name -contains 'StatusCode') { $status = [int]$response.StatusCode }
                    try {
                        $raw = if ($response.Headers -is [Net.Http.Headers.HttpResponseHeaders]) {
                            if ($response.Headers.RetryAfter.Delta) { [string]$response.Headers.RetryAfter.Delta.TotalSeconds }
                            elseif ($response.Headers.RetryAfter.Date) { $response.Headers.RetryAfter.Date.ToString() }
                        } else { [string]$response.Headers['Retry-After'] }
                        $seconds = 0.0
                        if ([double]::TryParse($raw, [ref]$seconds)) { $retryAfter = [math]::Max(0,$seconds) }
                        elseif ($raw) { $retryAfter = [math]::Max(0,([DateTimeOffset]::Parse($raw)-[DateTimeOffset]::UtcNow).TotalSeconds) }
                    } catch { $retryAfter = 0 }
                }
            }
            if ($status -in 408,429,500,502,503,504) { $transient = $true }
            if (-not $transient -or $attempt -ge $Settings.MaxRetries) { throw }
            $delay = [math]::Min($Settings.MaxDelaySeconds, $Settings.BaseDelaySeconds * [math]::Pow(2,$attempt) + (Get-Random -Minimum 0 -Maximum 1000)/1000.0)
            $delay = [math]::Max($delay,$retryAfter)
            if ($OnRetry) { & $OnRetry @{ Attempt = $attempt+1; DelaySeconds = $delay; StatusCode = $status; Error = $exception.Message } | Out-Null }
            Start-Sleep -Seconds $delay
        }
    }
}
