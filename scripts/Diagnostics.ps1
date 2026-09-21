#requires -Version 7.4.6
function Get-CleanupFailureHint {
    param([Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$Failure)
    $detail = $Failure.ToString()
    if ($detail -match 'AADSTS700027|certificate|certificado|private key|chave privada') {
        return '[SPVC-CERTIFICATE] Confira validade, chave privada, associacao do certificado ao aplicativo e acesso da identidade executora a chave em LocalMachine\My.'
    }
    if ($detail -match '403|Forbidden|AccessDenied|Authorization_RequestDenied') {
        return '[SPVC-PERMISSION] Confira permissoes do aplicativo, consentimento e concessao Sites.Selected para o site; politicas de retencao tambem podem impedir exclusoes.'
    }
    if ($detail -match '401|AADSTS|Unauthorized') {
        return '[SPVC-AUTH] Confira Tenant, ClientId, certificado e relogio da maquina; examine o codigo AADSTS original.'
    }
    if ($detail -match 'PnP.PowerShell|Import-Module|assembly|assemblies') {
        return '[SPVC-MODULE] Execute bootstrap.ps1 para preparar o modulo compartilhado e tente em um novo processo PowerShell sem perfil.'
    }
    if ($detail -match '429|503|504|timed out|timeout|tempo limite|TLS|SSL|proxy|host.*known|name.*resolution|conexao|connection') {
        return '[SPVC-NETWORK] Confira DNS, proxy, TLS e acesso HTTPS sob a identidade executora. As tentativas automaticas sao limitadas; tente novamente apos normalizar o servico.'
    }
    if ($detail -match 'disk|disco|space|espaco|denied|negado|UnauthorizedAccess|read.only|somente leitura') {
        return '[SPVC-STORAGE] Confira espaco livre e permissoes de leitura/escrita nos caminhos informados, incluindo a identidade LOCAL SERVICE quando agendado.'
    }
    return '[SPVC-EXECUTION] Consulte o erro original e os caminhos de diagnostico informados. Corrija a causa antes de repetir; nao amplie o escopo para contornar a falha.'
}

function Read-CleanupState {
    param([string]$Path, [scriptblock]$Validate)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    # Read failures (ACL, disk, lock) must not be confused with invalid JSON.
    $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
    try {
        $state = ConvertFrom-Json -InputObject $raw -AsHashtable -ErrorAction Stop
        if ($state -isnot [Collections.IDictionary] -or -not (& $Validate $state)) { throw 'Estrutura de estado invalida.' }
        return $state
    } catch {
        $backup = "$Path.invalid-$([guid]::NewGuid().ToString('N')).bak"
        [IO.File]::Move($Path, $backup)
        Write-Warning "[SPVC-STATE] Estado invalido preservado em $backup. Os dados serao reavaliados a partir do SharePoint. Motivo: $($_.Exception.Message)"
        return $null
    }
}
