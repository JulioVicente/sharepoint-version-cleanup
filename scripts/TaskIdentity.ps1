#requires -Version 7.4.6
# LOCAL SERVICE authenticates to Microsoft 365 with the application certificate.
function Assert-CleanupLocalPath {
    param([string]$Path)
    if (-not [IO.Path]::IsPathFullyQualified($Path) -or $Path.StartsWith('\\')) {
        throw 'O agendamento sem senha exige pastas locais; caminhos de rede dependem de outra identidade.'
    }
    $cursor = [IO.Path]::GetFullPath($Path)
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Pasta com redirecionamento nao suportada: $cursor" }
        }
        $cursor = Split-Path $cursor -Parent
    }
}

function Set-CleanupServiceAcl {
    param([string]$Path, [Security.AccessControl.FileSystemRights]$ServiceRights = 'ReadAndExecute')
    Assert-CleanupLocalPath $Path
    $item = Get-Item -LiteralPath $Path -Force
    $acl = if ($item.PSIsContainer) { [Security.AccessControl.DirectorySecurity]::new() } else { [Security.AccessControl.FileSecurity]::new() }
    $acl.SetAccessRuleProtection($true, $false)
    $admin = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    $acl.SetOwner($admin)
    $inherit = if ($item.PSIsContainer) { [Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit' } else { [Security.AccessControl.InheritanceFlags]::None }
    foreach ($entry in @(@('S-1-5-18','FullControl'),@('S-1-5-32-544','FullControl'),@('S-1-5-19',[string]$ServiceRights))) {
        $rule = [Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($entry[0]),[Security.AccessControl.FileSystemRights]$entry[1],$inherit,[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Allow)
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
}

function Set-CleanupCngKeyAcl {
    param($Key)
    # UniqueName does not identify a filesystem directory. Let the KSP locate
    # the persisted key, including legacy keys exposed through CNG.
    $descriptor = [Security.AccessControl.RawSecurityDescriptor]::new('D:P(A;;GA;;;SY)(A;;GA;;;BA)(A;;GR;;;LS)')
    $bytes = [byte[]]::new($descriptor.BinaryLength)
    $descriptor.GetBinaryForm($bytes,0)
    # DACL_SECURITY_INFORMATION | NCRYPT_PERSIST_FLAG; leave owner/SACL intact.
    $options = [Security.Cryptography.CngPropertyOptions](-2147483644)
    try {
        $Key.SetProperty([Security.Cryptography.CngProperty]::new('Security Descr',$bytes,$options))
        $actual = $Key.GetProperty('Security Descr',[Security.Cryptography.CngPropertyOptions]4).GetValue()
        $readback = [Security.AccessControl.RawSecurityDescriptor]::new($actual,0)
        $serviceRules = @($readback.DiscretionaryAcl | Where-Object { $_.SecurityIdentifier.Value -eq 'S-1-5-19' })
        # Providers may map GENERIC_READ to FILE_GENERIC_READ.
        if ($serviceRules.Count -ne 1 -or $serviceRules[0].AceQualifier -ne 'AccessAllowed' -or
            $serviceRules[0].AccessMask -notin @(-2147483648,1179785)) {
            throw 'A releitura da chave nao confirmou acesso de leitura para LOCAL SERVICE.'
        }
    } catch {
        throw "Nao foi possivel preparar a chave privada para LOCAL SERVICE pelo provedor criptografico: $($_.Exception.Message)"
    }
}

function Install-CleanupServiceCertificate {
    param([ValidatePattern('^[a-fA-F0-9]{40}$')][string]$Thumbprint)
    $certificate = Get-Item -LiteralPath "Cert:\LocalMachine\My\$Thumbprint" -ErrorAction SilentlyContinue
    if (-not $certificate -or -not $certificate.HasPrivateKey) {
        $source = Get-Item -LiteralPath "Cert:\CurrentUser\My\$Thumbprint" -ErrorAction Stop
        $password = ConvertTo-SecureString ([Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(32))) -AsPlainText -Force
        $bytes = $null
        $store = [Security.Cryptography.X509Certificates.X509Store]::new('My','LocalMachine')
        try {
            # Transfer only in memory; no unprotected PFX or password file is written.
            $bytes = $source.Export([Security.Cryptography.X509Certificates.X509ContentType]::Pfx,$password)
            $certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new($bytes,$password,[Security.Cryptography.X509Certificates.X509KeyStorageFlags]'MachineKeySet,PersistKeySet')
            $store.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
            $store.Add($certificate)
        } finally {
            $store.Close()
            if ($bytes) { [Array]::Clear($bytes,0,$bytes.Length) }
            $password.Dispose()
        }
    }
    if (-not $certificate.HasPrivateKey -or $certificate.NotAfter.ToUniversalTime() -le [datetime]::UtcNow -or $certificate.NotBefore.ToUniversalTime() -gt [datetime]::UtcNow) {
        throw 'Certificado de maquina sem chave privada ou fora da validade.'
    }
    $rsa = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($certificate)
    try {
        if ($rsa -is [Security.Cryptography.RSACng] -and $rsa.Key.IsMachineKey) {
            Set-CleanupCngKeyAcl -Key $rsa.Key
        } elseif ($rsa -is [Security.Cryptography.RSACryptoServiceProvider] -and $rsa.CspKeyContainerInfo.MachineKeyStore) {
            $keyPath = Join-Path $env:ProgramData ('Microsoft\Crypto\RSA\MachineKeys\' + $rsa.CspKeyContainerInfo.UniqueKeyContainerName)
            if (-not (Test-Path -LiteralPath $keyPath -PathType Leaf)) { throw "Arquivo da chave CAPI nao localizado: $keyPath" }
            Set-CleanupServiceAcl -Path $keyPath -ServiceRights Read
        } else { throw 'Provedor da chave privada nao suportado para agendamento sem senha.' }
    } finally { if ($rsa) { $rsa.Dispose() } }
    return $certificate
}

function Initialize-CleanupServiceIdentity {
    param([System.Collections.IDictionary]$Configuration, [string]$Destination)
    $root = [IO.Path]::GetFullPath($Destination).TrimEnd('\')
    Assert-CleanupLocalPath $root
    # Refuse links before changing any ACL; do not traverse junctions outside this installation.
    $entries = @(Get-ChildItem -LiteralPath $root -Recurse -Force | Where-Object { $_.FullName -ne (Join-Path $root '.install.lock') })
    if (@($entries | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) { throw 'A instalacao contem links/redirecionamentos; use uma pasta local dedicada.' }
    $writable = @($Configuration.Paths.State,$Configuration.Paths.Logs)
    if ($Configuration.Audit.CopyDirectory) { $writable += $Configuration.Audit.CopyDirectory }
    foreach ($path in $writable) {
        Assert-CleanupLocalPath $path
        $full = [IO.Path]::GetFullPath($path).TrimEnd('\')
        if (-not $full.StartsWith("$root\",[StringComparison]::OrdinalIgnoreCase)) {
            throw 'Para agendar sem senha, mantenha estado, logs e copia de auditoria em subpastas da instalacao.'
        }
        foreach ($protected in @($root,(Join-Path $root 'scripts'),(Join-Path $root 'config'),(Join-Path $root 'certificates'))) {
            if ($full -eq $protected -or $full.StartsWith("$protected\",[StringComparison]::OrdinalIgnoreCase) -and $protected -ne $root) { throw "Pasta de escrita conflita com arquivos protegidos: $full" }
        }
    }
    $null = Install-CleanupServiceCertificate -Thumbprint $Configuration.Authentication.CertificateThumbprint
    Set-CleanupServiceAcl -Path $root
    foreach ($entry in $entries) { Set-CleanupServiceAcl -Path $entry.FullName }
    foreach ($path in $writable) {
        $null = New-Item -ItemType Directory -Path $path -Force
        Set-CleanupServiceAcl -Path $path -ServiceRights Modify
        foreach ($entry in Get-ChildItem -LiteralPath $path -Recurse -Force) { Set-CleanupServiceAcl -Path $entry.FullName -ServiceRights Modify }
    }
}

function Test-CleanupServiceExecution {
    param([System.Collections.IDictionary]$Configuration,[string]$Destination)
    $name = 'SPVC-ServiceTest-' + [guid]::NewGuid().ToString('N')
    $resultPath = Join-Path $Configuration.Paths.State "$name.json"
    $serviceName = ([Security.Principal.SecurityIdentifier]::new('S-1-5-19')).Translate([Security.Principal.NTAccount]).Value
    $principal = New-ScheduledTaskPrincipal -UserId $serviceName -LogonType ServiceAccount -RunLevel Limited
    $scriptPath = Join-Path $Destination 'scripts\Test-ServiceContext.ps1'
    $configPath = Join-Path $Destination 'config\config.json'
    $action = New-ScheduledTaskAction -Execute (Join-Path $PSHOME 'pwsh.exe') -Argument "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$scriptPath`" -ConfigPath `"$configPath`" -ResultPath `"$resultPath`""
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 3)
    $registered = $false
    try {
        $null = Register-ScheduledTask -TaskName $name -TaskPath '\' -Action $action -Principal $principal -Settings $settings
        $registered = $true
        Start-ScheduledTask -TaskName $name -TaskPath '\'
        Invoke-CleanupActivity -Message 'Testando execucao sem senha como LOCAL SERVICE...' -Action {
            $deadline = [datetime]::UtcNow.AddMinutes(3)
            while (-not (Test-Path -LiteralPath $resultPath)) {
                if ([datetime]::UtcNow -ge $deadline) {
                    $info = Get-ScheduledTaskInfo -TaskName $name -TaskPath '\' -ErrorAction SilentlyContinue
                    $code = if ($info) { '0x{0:X8}' -f [long]$info.LastTaskResult } else { 'indisponivel' }
                    throw "[SPVC-SERVICE] Tempo limite no teste LOCAL SERVICE. Ultimo resultado do Agendador: $code. Executavel: $($action.Execute). Confira politica de execucao corporativa, acesso ao script '$scriptPath', modulo compartilhado, proxy da conta de servico e log Microsoft-Windows-TaskScheduler/Operational."
                }
                Start-Sleep -Seconds 2
            }
        }
        $result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
        if (-not $result.Success -or $result.Identity -ne 'S-1-5-19') { throw "Teste LOCAL SERVICE falhou: $($result.Error)" }
        Write-Host 'LOCAL SERVICE validado: certificado, modulo, pastas e leitura SharePoint. Nenhuma versao removida neste teste.'
    } finally {
        if ($registered) {
            Stop-ScheduledTask -TaskName $name -TaskPath '\' -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName $name -TaskPath '\' -Confirm:$false -ErrorAction SilentlyContinue
        }
        foreach ($path in @($resultPath,"$resultPath.tmp")) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue } }
    }
}

function ConvertTo-CleanupServiceTaskXml {
    param([string]$Xml)
    $document = [xml]$Xml
    $principal = $document.SelectSingleNode("//*[local-name()='Principals']/*[local-name()='Principal']")
    if (-not $principal) { throw 'Principal ausente no backup da tarefa.' }
    foreach ($name in @('UserId','GroupId','LogonType','RunLevel')) {
        $node = $principal.SelectSingleNode("*[local-name()='$name']")
        if ($node) { $null = $principal.RemoveChild($node) }
    }
    foreach ($entry in @(@('UserId','S-1-5-19'),@('LogonType','ServiceAccount'),@('RunLevel','LeastPrivilege'))) {
        $node = $document.CreateElement($entry[0],$principal.NamespaceURI)
        $node.InnerText = $entry[1]
        $null = $principal.AppendChild($node)
    }
    $document.OuterXml
}
