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
    # the persisted native CNG key. Legacy CAPI keys are handled separately.
    $descriptor = [Security.AccessControl.RawSecurityDescriptor]::new('D:P(A;;GA;;;SY)(A;;GA;;;BA)(A;;GR;;;LS)')
    $bytes = [byte[]]::new($descriptor.BinaryLength)
    $descriptor.GetBinaryForm($bytes,0)
    # Security Descr is a built-in property: request only DACL_SECURITY_INFORMATION.
    $options = [Security.Cryptography.CngPropertyOptions]4
    try {
        $Key.SetProperty([Security.Cryptography.CngProperty]::new('Security Descr',$bytes,$options))
        $actual = $Key.GetProperty('Security Descr',[Security.Cryptography.CngPropertyOptions]4).GetValue()
        $readback = [Security.AccessControl.RawSecurityDescriptor]::new($actual,0)
        $serviceRules = @($readback.DiscretionaryAcl | Where-Object { $_.SecurityIdentifier.Value -eq 'S-1-5-19' })
        # Providers may map GENERIC_READ to FILE_GENERIC_READ or return both bits.
        if ($serviceRules.Count -ne 1 -or $serviceRules[0].AceQualifier -ne 'AccessAllowed' -or
            $serviceRules[0].AccessMask -notin @(-2147483648,1179785,(-2147483648 -bor 1179785))) {
            $observed = $readback.GetSddlForm([Security.AccessControl.AccessControlSections]::Access)
            throw "A releitura da chave nao confirmou acesso de leitura para LOCAL SERVICE. DACL recebida: $observed"
        }
    } catch {
        $cause = $_.Exception.GetBaseException()
        $provider = if ($Key.PSObject.Properties['Provider']) { [string]$Key.Provider } else { 'nao informado' }
        $code = '0x{0:X8}' -f $cause.HResult
        throw [InvalidOperationException]::new("[SPVC-KEY-ACL] Nao foi possivel preparar a chave privada para LOCAL SERVICE. Provedor CNG: '$provider'; codigo: $code. Verifique suporte a ACL e permissao administrativa local. Erro original: $($cause.Message)", $_.Exception)
    }
}

function Get-CleanupCertificateKeyProvider {
    param([Security.Cryptography.X509Certificates.X509Certificate2]$Certificate)
    if (-not ('Spvc.CertificateKeyProvider' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
namespace Spvc {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct CertificateKeyProvider {
        [MarshalAs(UnmanagedType.LPWStr)] public string ContainerName;
        [MarshalAs(UnmanagedType.LPWStr)] public string ProviderName;
        public uint ProviderType;
        public uint Flags;
        public uint ParameterCount;
        public IntPtr Parameters;
        public uint KeySpec;
        [DllImport("crypt32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CertGetCertificateContextProperty(IntPtr context, uint property, IntPtr data, ref uint size);
        public static CertificateKeyProvider Read(IntPtr context) {
            const uint CERT_KEY_PROV_INFO_PROP_ID = 2;
            uint size = 0;
            if (!CertGetCertificateContextProperty(context, CERT_KEY_PROV_INFO_PROP_ID, IntPtr.Zero, ref size))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            if (size < Marshal.SizeOf<CertificateKeyProvider>()) throw new InvalidOperationException("Informacao do provedor incompleta.");
            IntPtr buffer = Marshal.AllocHGlobal(checked((int)size));
            try {
                if (!CertGetCertificateContextProperty(context, CERT_KEY_PROV_INFO_PROP_ID, buffer, ref size))
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                return Marshal.PtrToStructure<CertificateKeyProvider>(buffer);
            } finally { Marshal.FreeHGlobal(buffer); }
        }
    }
}
'@
    }
    try { return [Spvc.CertificateKeyProvider]::Read($Certificate.Handle) }
    finally { [GC]::KeepAlive($Certificate) }
}

function Get-CleanupCapiKeyInfo {
    param($Provider)
    $parameters = [Security.Cryptography.CspParameters]::new([int]$Provider.ProviderType, $Provider.ProviderName, $Provider.ContainerName)
    $parameters.KeyNumber = [int]$Provider.KeySpec
    if ($Provider.Flags -band 0x20) { $parameters.Flags = [Security.Cryptography.CspProviderFlags]::UseMachineKeyStore }
    return [Security.Cryptography.CspKeyContainerInfo]::new($parameters)
}

function Set-CleanupCertificatePrivateKeyAcl {
    param([Security.Cryptography.X509Certificates.X509Certificate2]$Certificate)
    try {
        # GetRSAPrivateKey can return RSACng for a legacy CAPI key. Inspect the
        # certificate's native provider metadata before choosing how to set its ACL.
        $provider = Get-CleanupCertificateKeyProvider -Certificate $Certificate
        if ($provider.ProviderType -ne 0) {
            $info = Get-CleanupCapiKeyInfo -Provider $provider
            if (-not $info.MachineKeyStore -or $info.HardwareDevice) { throw 'A chave CAPI deve estar no armazenamento de maquina e usar um provedor de software.' }
            $uniqueName = $info.UniqueKeyContainerName
            if (-not $uniqueName -or [IO.Path]::GetFileName($uniqueName) -ne $uniqueName -or $uniqueName -in '.', '..') { throw 'Identificador do arquivo da chave CAPI invalido.' }
            $keyPath = Join-Path $env:ProgramData "Microsoft\Crypto\RSA\MachineKeys\$uniqueName"
            if (-not (Test-Path -LiteralPath $keyPath -PathType Leaf)) { throw "Arquivo da chave CAPI nao localizado: $keyPath" }
            Set-CleanupServiceAcl -Path $keyPath -ServiceRights Read
            $acl = Get-Acl -LiteralPath $keyPath -ErrorAction Stop
            $rules = @($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]) | Where-Object { $_.IdentityReference.Value -eq 'S-1-5-19' })
            if ($rules.Count -ne 1 -or $rules[0].AccessControlType -ne 'Allow' -or
                [int]$rules[0].FileSystemRights -notin @(131209,1179785)) { throw 'A releitura da chave CAPI nao confirmou leitura exclusiva para LOCAL SERVICE.' }
            Write-Host "Permissao da chave CAPI validada: $($provider.ProviderName)."
            return
        }
        $rsa = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($Certificate)
        try {
            if ($rsa -isnot [Security.Cryptography.RSACng] -or -not $rsa.Key.IsMachineKey) { throw 'A chave CNG deve ser RSA e estar no armazenamento de maquina.' }
            Set-CleanupCngKeyAcl -Key $rsa.Key
            Write-Host "Permissao da chave CNG validada: $($provider.ProviderName)."
        } finally { if ($rsa) { $rsa.Dispose() } }
    } catch {
        $cause = $_.Exception.GetBaseException()
        $code = '0x{0:X8}' -f $cause.HResult
        $thumbprint = 'indisponivel'
        try { if ($Certificate) { $thumbprint = $Certificate.Thumbprint } } catch { }
        throw [InvalidOperationException]::new("[SPVC-KEY-ACL] Falha local ao preparar a chave do certificado '$thumbprint' para LOCAL SERVICE ($code). Execute o bootstrap atualizado como Administrador. Confira o provedor e as permissoes locais; refazer consentimento no Entra nao corrige essa etapa. Erro original: $($_.Exception.Message)", $_.Exception)
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
    Set-CleanupCertificatePrivateKeyAcl -Certificate $certificate
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

function Get-CleanupServiceTaskStatus {
    param([string]$TaskName)
    $status = [ordered]@{ State='indisponivel'; Code='indisponivel'; LastRunUtc=$null; QueryError='' }
    try {
        $scheduledTask = Get-ScheduledTask -TaskName $TaskName -TaskPath '\' -ErrorAction Stop
        $status.State = [string]$scheduledTask.State
    } catch { $status.QueryError = $_.Exception.Message }
    try {
        $taskInfo = Get-ScheduledTaskInfo -TaskName $TaskName -TaskPath '\' -ErrorAction Stop
        $status.Code = '0x{0:X8}' -f ([long]$taskInfo.LastTaskResult -band 4294967295L)
        $status.LastRunUtc = ([datetime]$taskInfo.LastRunTime).ToUniversalTime()
    } catch { $status.QueryError = ($status.QueryError + ' ' + $_.Exception.Message).Trim() }
    return [pscustomobject]$status
}

function Test-CleanupServiceExecution {
    param([System.Collections.IDictionary]$Configuration,[string]$Destination,
        [ValidateRange(1,86400)][int]$TimeoutSeconds = 180,
        [ValidateRange(1,3600)][int]$StageTimeoutSeconds = 180,
        [string]$ModulePath)
    if (-not $PSBoundParameters.ContainsKey('TimeoutSeconds') -and $Configuration.Contains('Sites')) {
        # Independent local stages plus connect/list/folder for every site.
        $TimeoutSeconds = [Math]::Min(86400, $StageTimeoutSeconds * (6 + 3 * @($Configuration.Sites).Count))
    }
    $name = 'SPVC-ServiceTest-' + [guid]::NewGuid().ToString('N')
    $resultPath = Join-Path $Configuration.Paths.State "$name.json"
    $progressPath = "$resultPath.progress.json"
    $serviceName = ([Security.Principal.SecurityIdentifier]::new('S-1-5-19')).Translate([Security.Principal.NTAccount]).Value
    $principal = New-ScheduledTaskPrincipal -UserId $serviceName -LogonType ServiceAccount -RunLevel Limited
    $scriptPath = Join-Path $Destination 'scripts\Test-ServiceContext.ps1'
    $configPath = Join-Path $Destination 'config\config.json'
    # Invoke-CleanupActivity has an Action parameter. PowerShell's dynamic scope
    # makes $action inside its callback refer to that scriptblock, not this task.
    $taskExecutable = Join-Path $PSHOME 'pwsh.exe'
    $serviceTaskAction = New-ScheduledTaskAction -Execute $taskExecutable -Argument "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$scriptPath`" -ConfigPath `"$configPath`" -ResultPath `"$resultPath`""
    if ($ModulePath) {
        if ($ModulePath -match '["\r\n]') { throw 'Caminho de modulo invalido.' }
        $serviceTaskAction.Arguments += " -ModulePath `"$ModulePath`""
    }
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Seconds ($TimeoutSeconds + 30)) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    $registered = $false
    try {
        $null = Register-ScheduledTask -TaskName $name -TaskPath '\' -Action $serviceTaskAction -Principal $principal -Settings $settings
        $registered = $true
        Start-ScheduledTask -TaskName $name -TaskPath '\'
        Invoke-CleanupActivity -Message 'Testando execucao sem senha como LOCAL SERVICE...' -Action {
            $totalTimer = [Diagnostics.Stopwatch]::StartNew()
            $stageTimer = [Diagnostics.Stopwatch]::StartNew()
            $lastSequence = 0
            $lastStage = 'startup (sem progresso recebido)'
            $lastDetail = ''
            while (-not (Test-Path -LiteralPath $resultPath)) {
                if (Test-Path -LiteralPath $progressPath) {
                    try {
                        $progress = Get-Content -LiteralPath $progressPath -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop
                        if ($progress.Sequence -is [long] -or $progress.Sequence -is [int]) {
                            if ($progress.Sequence -gt $lastSequence -and $progress.Stage -is [string]) {
                                $lastSequence = $progress.Sequence
                                $lastStage = $progress.Stage
                                $lastDetail = [string]$progress.Detail
                                $stageTimer.Restart()
                                Write-Host "[SPVC-SERVICE] Etapa: $lastStage. $lastDetail"
                            }
                        }
                    } catch { Write-Verbose "Progresso temporariamente indisponivel: $($_.Exception.Message)" }
                }
                $taskStatus = Get-CleanupServiceTaskStatus -TaskName $name
                # This GUID task was created without Force and has no previous run.
                # Do not compare LastRunTime with the parent's clock: scheduler
                # timestamps may be rounded or represented differently on Windows.
                # 1999 is the scheduler's never-run sentinel; a real return code
                # also proves a run even when its timestamp is unavailable.
                $hasRun = ($taskStatus.LastRunUtc -and $taskStatus.LastRunUtc.Year -ge 2000) -or
                    $taskStatus.Code -notin @('indisponivel','0x00000000','0x00041301','0x00041303')
                $finished = $hasRun -and $taskStatus.State -notin @('Running','Queued','indisponivel') -and
                    $taskStatus.Code -notin @('indisponivel','0x00041301','0x00041303')
                if ($finished -or $totalTimer.Elapsed.TotalSeconds -ge $TimeoutSeconds -or $stageTimer.Elapsed.TotalSeconds -ge $StageTimeoutSeconds) {
                    # The worker may have published its result between the checks.
                    if (Test-Path -LiteralPath $resultPath) { break }
                    $reason = if ($finished) { 'A tarefa terminou sem gravar o resultado' }
                        elseif ($stageTimer.Elapsed.TotalSeconds -ge $StageTimeoutSeconds) { "Tempo limite de $StageTimeoutSeconds segundos na etapa '$lastStage' ($lastDetail)" }
                        else { "Tempo limite total de $TimeoutSeconds segundos no teste LOCAL SERVICE" }
                    $hint = switch ($lastStage) {
                        module { 'Confira o manifesto informado, leitura de Program Files e bloqueios de DLL por antivirus/AppLocker.' }
                        certificate { 'Confira validade e acesso a chave privada RSA em LocalMachine\\My sob LOCAL SERVICE.' }
                        storage { 'Confira espaco livre e permissoes de escrita nas pastas de dados.' }
                        configuration { 'Confira acesso e sintaxe do JSON e integridade dos scripts instalados.' }
                        { $_ -in 'connect','libraries','folder' } { 'Confira DNS, HTTPS/TLS, proxy sob LOCAL SERVICE e permissoes do aplicativo no site. O login do administrador nao comprova acesso da conta de servico.' }
                        default { 'Confira inicializacao do PowerShell, politicas corporativas e acesso ao script/estado.' }
                    }
                    $reason += ". Ultima etapa: $lastStage ($lastDetail). $hint"
                    throw "[SPVC-SERVICE] $reason. Tarefa: $name. Estado: $($taskStatus.State). Ultimo resultado do Agendador: $($taskStatus.Code). Executavel: $taskExecutable. Script: $scriptPath. Configuracao: $configPath. Resultado esperado: $resultPath. Diagnostico do Agendador: $($taskStatus.QueryError). Confira politica de execucao corporativa, acesso aos arquivos, modulo compartilhado, proxy da conta de servico e log Microsoft-Windows-TaskScheduler/Operational."
                }
                Start-Sleep -Seconds 2
            }
        }
        $result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json -AsHashtable
        if ($result -isnot [System.Collections.IDictionary]) { throw 'Teste LOCAL SERVICE falhou: resultado JSON invalido.' }
        if ($result['Success'] -isnot [bool] -or -not $result['Success'] -or $result['Identity'] -ne 'S-1-5-19' -or $result['Scope'] -ne 'Full') {
            throw "Teste LOCAL SERVICE falhou: $($result['Error']) Resultado deve confirmar sucesso booleano, identidade S-1-5-19 e escopo Full."
        }
        Write-Host 'LOCAL SERVICE validado: certificado, modulo, pastas e leitura SharePoint. Nenhuma versao removida neste teste.'
    } catch {
        $failure = $_
        # Keep evidence outside the installation rollback and the task's cleanup.
        try {
            $diagnosticPath = Join-Path ([IO.Path]::GetTempPath()) "$name-diagnostic.log"
            $failure.Exception.Message | Set-Content -LiteralPath $diagnosticPath -Encoding utf8
            foreach ($artifact in @($progressPath,$resultPath,"$resultPath.log")) {
                if (Test-Path -LiteralPath $artifact) {
                    Get-Content -LiteralPath $artifact -Tail 200 -ErrorAction Stop | Add-Content -LiteralPath $diagnosticPath -Encoding utf8
                }
            }
            Write-Warning "Diagnostico LOCAL SERVICE preservado em: $diagnosticPath"
        } catch { Write-Warning "Nao foi possivel preservar diagnostico adicional: $($_.Exception.Message)" }
        throw $failure
    } finally {
        if ($registered) {
            Stop-ScheduledTask -TaskName $name -TaskPath '\' -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName $name -TaskPath '\' -Confirm:$false -ErrorAction SilentlyContinue
        }
        foreach ($path in @($resultPath,"$resultPath.tmp",$progressPath,"$progressPath.tmp","$resultPath.log")) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue } }
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
