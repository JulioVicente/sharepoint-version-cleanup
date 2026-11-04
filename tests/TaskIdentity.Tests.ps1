BeforeAll {
    . (Join-Path $PSScriptRoot '../Install.ps1') -WhatIf
    . (Join-Path $PSScriptRoot '../scripts/Configuration.ps1')
    . (Join-Path $PSScriptRoot '../scripts/TaskIdentity.ps1')
    $realAcl = (Get-Command Set-CleanupServiceAcl).ScriptBlock
    function New-ScheduledTaskPrincipal { param($UserId,$LogonType,$RunLevel) }
    function New-ScheduledTaskAction { param($Execute,$Argument) }
    function New-ScheduledTaskTrigger { param([switch]$Daily,$At,[switch]$Weekly,$DaysOfWeek) }
    function New-ScheduledTaskSettingsSet { param([switch]$StartWhenAvailable,$MultipleInstances,$ExecutionTimeLimit,$RestartCount,$RestartInterval,[switch]$AllowStartIfOnBatteries,[switch]$DontStopIfGoingOnBatteries) }
    function Register-ScheduledTask { param($TaskName,$TaskPath,$Action,$Trigger,$Settings,$Description,$Principal,[switch]$Force,$Xml,$User,$Password) }
    function Get-ScheduledTask { param($TaskName,$TaskPath) }
    function Get-ScheduledTaskInfo { param($TaskName,$TaskPath) }
    function Export-ScheduledTask { param($TaskName) }
    function Start-ScheduledTask { param($TaskName,$TaskPath) }
    function Stop-ScheduledTask { param($TaskName,$TaskPath) }
    function Unregister-ScheduledTask { param($TaskName,$TaskPath,[switch]$Confirm) }
}
Describe 'Agendamento sem senha pessoal' {
    BeforeEach {
        $cfg = @{Sites=@('https://contoso.sharepoint.com');FolderScopes=@{};Schedule=@{Frequency='diaria';Time='22:00'}}
        Mock New-ScheduledTaskPrincipal { @{UserId=$UserId;LogonType=$LogonType;RunLevel=$RunLevel} }
        Mock New-ScheduledTaskAction { @{Execute=$Execute;Arguments=$Argument} }
        Mock New-ScheduledTaskTrigger { @{} }
        Mock New-ScheduledTaskSettingsSet { @{} }
        Mock Get-ScheduledTask { $null }
        Mock Register-ScheduledTask {}
        Mock Get-Credential { throw 'Nao pode pedir senha' }
    }
    It 'registra LOCAL SERVICE com ServiceAccount sem Password nem elevacao' {
        Install-ScheduledTasks -Configuration $cfg -Destination $TestDrive
        Should -Invoke Get-Credential -Times 0
        Should -Invoke New-ScheduledTaskPrincipal -Times 1 -ParameterFilter { $LogonType -eq 'ServiceAccount' -and $RunLevel -eq 'Limited' }
        Should -Invoke Register-ScheduledTask -Times 1 -ParameterFilter { $Principal.LogonType -eq 'ServiceAccount' -and -not $Password -and -not $User -and $Action.Arguments -notmatch '-Apply' }
    }
    It 'mantem Apply apenas para o site aprovado no piloto' {
        Install-ScheduledTasks -Configuration $cfg -Destination $TestDrive -ProductionSites $cfg.Sites
        Should -Invoke Register-ScheduledTask -Times 1 -ParameterFilter { $Action.Arguments -match '-Apply' -and -not $Password }
    }
    It 'restaura acoes antigas usando identidade sem senha' {
        $xml = '<Task xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task"><Principals><Principal id="Author"><UserId>old-user</UserId><LogonType>Password</LogonType><RunLevel>HighestAvailable</RunLevel></Principal></Principals><Actions><Exec><Command>pwsh.exe</Command></Exec></Actions></Task>'
        $result = [xml](ConvertTo-CleanupServiceTaskXml $xml)
        $result.Task.Principals.Principal.UserId | Should -Be 'S-1-5-19'
        $result.Task.Principals.Principal.LogonType | Should -Be 'ServiceAccount'
        $result.Task.Principals.Principal.RunLevel | Should -Be 'LeastPrivilege'
        $result.Task.Actions.Exec.Command | Should -Be 'pwsh.exe'
    }
}
Describe 'Pastas da conta de servico' {
    BeforeEach {
        $root = Join-Path $TestDrive 'installed'
        $null = New-Item -ItemType Directory -Path $root -Force
        $cfg = @{Authentication=@{CertificateThumbprint=('A'*40)};Paths=@{State=(Join-Path $root 'state');Logs=(Join-Path $root 'logs')};Audit=@{CopyDirectory=(Join-Path $root 'audit-copy')}}
        Mock Install-CleanupServiceCertificate {}
        Mock Set-CleanupServiceAcl {}
    }
    It 'concede escrita somente aos dados e leitura aos scripts' {
        $null = New-Item -ItemType Directory -Path (Join-Path $root 'scripts')
        Initialize-CleanupServiceIdentity -Configuration $cfg -Destination $root
        Should -Invoke Set-CleanupServiceAcl -Times 3 -ParameterFilter { $ServiceRights -eq 'Modify' }
        Should -Invoke Set-CleanupServiceAcl -Times 1 -ParameterFilter { $Path -eq (Join-Path $root 'scripts') -and $ServiceRights -ne 'Modify' }
        Should -Invoke Install-CleanupServiceCertificate -Times 1
    }
    It 'recusa pasta externa antes de mudar certificado ou ACL' {
        $cfg.Audit.CopyDirectory = Join-Path $TestDrive 'external'
        { Initialize-CleanupServiceIdentity -Configuration $cfg -Destination $root } | Should -Throw '*subpastas*'
        Should -Invoke Install-CleanupServiceCertificate -Times 0
        Should -Invoke Set-CleanupServiceAcl -Times 0
    }
    It 'recusa escrita sobre os scripts' {
        $cfg.Paths.State = Join-Path $root 'scripts'
        { Initialize-CleanupServiceIdentity -Configuration $cfg -Destination $root } | Should -Throw '*protegidos*'
        Should -Invoke Install-CleanupServiceCertificate -Times 0
    }
    It 'recusa caminho UNC sem alterar ambiente' {
        { Assert-CleanupLocalPath '\\server\share\audit' } | Should -Throw '*pastas locais*'
    }
    It 'ACL permite somente administradores SYSTEM e LOCAL SERVICE' {
        Mock Set-Acl {}
        & $realAcl -Path $root -ServiceRights ReadAndExecute
        Should -Invoke Set-Acl -Times 1 -ParameterFilter {
            $rules = @($AclObject.GetAccessRules($true,$false,[Security.Principal.SecurityIdentifier]))
            $AclObject.AreAccessRulesProtected -and $rules.Count -eq 3 -and
            @($rules | Where-Object { $_.IdentityReference.Value -eq 'S-1-5-19' -and $_.FileSystemRights -band [Security.AccessControl.FileSystemRights]::Write }).Count -eq 0
        }
    }
}

Describe 'Teste sob a identidade de servico' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $cfg = @{Paths=@{State=$TestDrive}}
        Mock New-ScheduledTaskPrincipal { @{} }
        Mock New-ScheduledTaskAction { @{} }
        Mock New-ScheduledTaskSettingsSet { @{} }
        Mock Register-ScheduledTask {}
        Mock Start-ScheduledTask {}
        Mock Stop-ScheduledTask {}
        Mock Unregister-ScheduledTask {}
        Mock Test-Path { $true }
        Mock Remove-Item {}
        Mock Get-Content { '{"Scope":"Full","Success":true,"Identity":"S-1-5-19","Error":""}' }
        Mock Set-Content {}
        Mock Add-Content {}
    }
    It 'aceita somente o resultado da conta LOCAL SERVICE e remove a tarefa temporaria' {
        Test-CleanupServiceExecution -Configuration $cfg -Destination $TestDrive
        Should -Invoke Start-ScheduledTask -Times 1
        Should -Invoke Unregister-ScheduledTask -Times 1
        Should -Invoke Register-ScheduledTask -Times 1 -ParameterFilter { -not $Password }
        Should -Invoke New-ScheduledTaskSettingsSet -Times 1 -ParameterFilter { $AllowStartIfOnBatteries -and $DontStopIfGoingOnBatteries -and $ExecutionTimeLimit.TotalSeconds -eq 210 }
    }
    It 'recusa resultado obtido sob outra identidade e limpa a tarefa' {
        Mock Get-Content { '{"Scope":"Full","Success":true,"Identity":"S-1-5-18","Error":"identidade incorreta"}' }
        { Test-CleanupServiceExecution -Configuration $cfg -Destination $TestDrive } | Should -Throw '*LOCAL SERVICE falhou*'
        Should -Invoke Unregister-ScheduledTask -Times 1
    }
    It 'recusa string false e escopo local como sucesso' -ForEach @(
        @{Json='{"Success":"false","Identity":"S-1-5-19","Scope":"Full","Error":""}'},
        @{Json='{"Success":true,"Identity":"S-1-5-19","Scope":"Local","Error":""}'},
        @{Json='{"Success":true,"Identity":"S-1-5-19","Error":""}'},
        @{Json='[]'}
    ) {
        Mock Get-Content { $Json }
        { Test-CleanupServiceExecution -Configuration $cfg -Destination $TestDrive } | Should -Throw '*LOCAL SERVICE falhou*'
    }
    It 'passa o manifesto com espacos entre aspas ao processo LOCAL SERVICE' {
        Mock New-ScheduledTaskAction { [pscustomobject]@{Arguments=$Argument} }
        $modulePath = 'C:\Program Files\PowerShell\Modules\PnP.PowerShell\3.0.0\PnP.PowerShell.psd1'
        Test-CleanupServiceExecution -Configuration $cfg -Destination $TestDrive -ModulePath $modulePath
        Should -Invoke Register-ScheduledTask -Times 1 -ParameterFilter { $Action.Arguments.Contains(' -ModulePath "' + $modulePath + '"') }
    }
    It 'dimensiona o limite total para todos os sites' {
        $cfg.Sites = @('https://a.sharepoint.com','https://b.sharepoint.com')
        Test-CleanupServiceExecution -Configuration $cfg -Destination $TestDrive
        Should -Invoke New-ScheduledTaskSettingsSet -Times 1 -ParameterFilter { $ExecutionTimeLimit.TotalSeconds -eq 2190 }
    }
    It 'informa etapa e site quando um comando fica bloqueado' {
        Mock Test-Path { $LiteralPath -like '*.progress.json' }
        Mock Get-Content { '{"Sequence":5,"Stage":"connect","Detail":"https://contoso.sharepoint.com"}' }
        Mock Get-ScheduledTask { [pscustomobject]@{State='Running'} }
        Mock Get-ScheduledTaskInfo { [pscustomobject]@{LastTaskResult=267009;LastRunTime=[datetime]::Now} }
        Mock Start-Sleep {}
        { Test-CleanupServiceExecution -Configuration $cfg -Destination $TestDrive -TimeoutSeconds 30 -StageTimeoutSeconds 1 } |
            Should -Throw '*Tempo limite*etapa*connect*https://contoso.sharepoint.com*'
        Should -Invoke Add-Content -Times 1
    }
    It 'preserva erro de acesso da conta de servico e limpa a tarefa' {
        Mock Get-Content { '{"Success":false,"Identity":"S-1-5-19","Error":"acesso negado"}' }
        { Test-CleanupServiceExecution -Configuration $cfg -Destination $TestDrive } | Should -Throw '*acesso negado*'
        Should -Invoke Unregister-ScheduledTask -Times 1
    }
    It 'preserva o diagnostico de timeout dentro do indicador real sem sombrear Action' {
        Mock Test-Path { $false }
        Mock Get-ScheduledTask { [pscustomobject]@{State='Running'} }
        Mock Get-ScheduledTaskInfo { [pscustomobject]@{LastTaskResult=267009;LastRunTime=[datetime]::Now} }
        Mock Start-Sleep {}
        { Test-CleanupServiceExecution -Configuration $cfg -Destination $TestDrive -TimeoutSeconds 1 } |
            Should -Throw '*SPVC-SERVICE*Tempo limite*Estado: Running*0x00041301*Executavel:*pwsh.exe*Resultado esperado:*'
        Should -Invoke Stop-ScheduledTask -Times 1
        Should -Invoke Unregister-ScheduledTask -Times 1
    }
    It 'informa imediatamente o codigo de uma tarefa encerrada sem JSON' {
        Mock Test-Path { $false }
        Mock Get-ScheduledTask { [pscustomobject]@{State='Ready'} }
        Mock Get-ScheduledTaskInfo { [pscustomobject]@{LastTaskResult=2147942402;LastRunTime=[datetime]::Now} }
        { Test-CleanupServiceExecution -Configuration $cfg -Destination $TestDrive } |
            Should -Throw '*terminou sem gravar*0x80070002*Executavel:*pwsh.exe*'
        Should -Invoke Unregister-ScheduledTask -Times 1
    }
    It 'nao confunde tarefa ainda nao iniciada com encerramento sem resultado' {
        Mock Test-Path { $false }
        Mock Get-ScheduledTask { [pscustomobject]@{State='Ready'} }
        Mock Get-ScheduledTaskInfo { [pscustomobject]@{LastTaskResult=267011;LastRunTime=[datetime]'1999-11-30'} }
        Mock Start-Sleep {}
        { Test-CleanupServiceExecution -Configuration $cfg -Destination $TestDrive -TimeoutSeconds 1 } |
            Should -Throw '*Tempo limite*0x00041303*'
    }
    It 'reconhece encerramento quando o horario do Agendador difere do processo pai' -ForEach @(@{Code=17},@{Code=0}) {
        Mock Test-Path { $false }
        Mock Get-ScheduledTask { [pscustomobject]@{State='Ready'} }
        Mock Get-ScheduledTaskInfo { [pscustomobject]@{LastTaskResult=$Code;LastRunTime=[datetime]::Now.AddHours(-4)} }
        { Test-CleanupServiceExecution -Configuration $cfg -Destination $TestDrive -TimeoutSeconds 1 } |
            Should -Throw '*terminou sem gravar*'
    }
    It 'nao aprova Ready com codigo zero antes da primeira execucao' {
        Mock Test-Path { $false }
        Mock Get-ScheduledTask { [pscustomobject]@{State='Ready'} }
        Mock Get-ScheduledTaskInfo { [pscustomobject]@{LastTaskResult=0;LastRunTime=[datetime]'1999-11-30'} }
        Mock Start-Sleep {}
        { Test-CleanupServiceExecution -Configuration $cfg -Destination $TestDrive -TimeoutSeconds 1 } |
            Should -Throw '*Tempo limite*'
    }
    It 'nao considera codigo zero suficiente sem resultado da identidade de servico' {
        Mock Test-Path { $false }
        Mock Get-ScheduledTask { [pscustomobject]@{State='Ready'} }
        Mock Get-ScheduledTaskInfo { [pscustomobject]@{LastTaskResult=0;LastRunTime=[datetime]::Now} }
        { Test-CleanupServiceExecution -Configuration $cfg -Destination $TestDrive } |
            Should -Throw '*terminou sem gravar*0x00000000*'
    }
    It 'nao mascara o timeout quando a consulta ao Agendador falha' {
        Mock Test-Path { $false }
        Mock Get-ScheduledTask { throw 'consulta de estado bloqueada' }
        Mock Get-ScheduledTaskInfo { throw 'consulta de resultado bloqueada' }
        Mock Start-Sleep {}
        { Test-CleanupServiceExecution -Configuration $cfg -Destination $TestDrive -TimeoutSeconds 1 } |
            Should -Throw '*SPVC-SERVICE*Tempo limite*indisponivel*consulta de estado bloqueada*consulta de resultado bloqueada*'
        Should -Invoke Unregister-ScheduledTask -Times 1
    }
    It 'aceita resultado publicado durante a ultima consulta ao Agendador' {
        $script:serviceResultPublished = $false
        Mock Test-Path { $script:serviceResultPublished }
        Mock Get-ScheduledTask { [pscustomobject]@{State='Ready'} }
        Mock Get-ScheduledTaskInfo {
            $script:serviceResultPublished = $true
            [pscustomobject]@{LastTaskResult=0;LastRunTime=[datetime]::Now}
        }
        { Test-CleanupServiceExecution -Configuration $cfg -Destination $TestDrive } | Should -Not -Throw
        Should -Invoke Unregister-ScheduledTask -Times 1
    }
}
Describe 'Permissoes da chave CNG pelo provedor' {
    BeforeEach {
        $key = [pscustomobject]@{Saved=$null;Failure=$false;Mismatch=$false}
        $key | Add-Member ScriptMethod SetProperty {
            param($property)
            if ($this.Failure) { throw 'provider unavailable' }
            $this.Saved = $property
        }
        $key | Add-Member ScriptMethod GetProperty {
            param($name,$options)
            if ($name -ne 'Security Descr' -or [int]$options -ne 4) { throw 'flags incorretas' }
            if ($this.Mismatch) {
                $sd = [Security.AccessControl.RawSecurityDescriptor]::new('D:(A;;GA;;;LS)')
                $bytes = [byte[]]::new($sd.BinaryLength)
                $sd.GetBinaryForm($bytes,0)
                return [Security.Cryptography.CngProperty]::new($name,$bytes,$options)
            }
            return $this.Saved
        }
        Mock Set-CleanupServiceAcl { throw 'Nao deve procurar arquivo CNG' }
    }
    It 'persiste a DACL sem depender do caminho ou UniqueName' {
        Set-CleanupCngKeyAcl -Key $key
        $key.Saved.Name | Should -Be 'Security Descr'
        [int]$key.Saved.Options | Should -Be 4
        $sd = [Security.AccessControl.RawSecurityDescriptor]::new($key.Saved.GetValue(),0)
        $sd.DiscretionaryAcl.Count | Should -Be 3
        $sd.GetSddlForm([Security.AccessControl.AccessControlSections]::Access) | Should -Be 'D:P(A;;GA;;;SY)(A;;GA;;;BA)(A;;GR;;;LS)'
        Should -Invoke Set-CleanupServiceAcl -Times 0
    }
    It 'recusa releitura que concede escrita a conta de servico' {
        $key.Mismatch = $true
        { Set-CleanupCngKeyAcl -Key $key } | Should -Throw '*nao confirmou*'
    }
    It 'aceita GENERIC_READ combinado com FILE_GENERIC_READ retornado pelo Windows' {
        $key | Add-Member ScriptMethod GetProperty {
            param($name,$options)
            $sd = [Security.AccessControl.RawSecurityDescriptor]::new('D:P(A;;GA;;;SY)(A;;GA;;;BA)(A;;0x80120089;;;LS)')
            $bytes = [byte[]]::new($sd.BinaryLength)
            $sd.GetBinaryForm($bytes,0)
            return [Security.Cryptography.CngProperty]::new($name,$bytes,$options)
        } -Force
        { Set-CleanupCngKeyAcl -Key $key } | Should -Not -Throw
    }
    It 'interrompe com diagnostico especifico se o provedor recusar a ACL' {
        $key.Failure = $true
        { Set-CleanupCngKeyAcl -Key $key } | Should -Throw '*provider unavailable*'
    }
}

Describe 'Provedor nativo da chave privada do certificado' {
    BeforeEach {
        $certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new()
        $provider = @{ProviderType=24;ProviderName='Microsoft Enhanced RSA and AES Cryptographic Provider';ContainerName='test';KeySpec=2;Flags=32}
        Mock Get-CleanupCertificateKeyProvider { $provider }
        Mock Get-CleanupCapiKeyInfo { @{MachineKeyStore=$true;HardwareDevice=$false;UniqueKeyContainerName='test-key'} }
        Mock Test-Path { $true }
        Mock Set-CleanupServiceAcl {}
        Mock Set-CleanupCngKeyAcl { throw 'Nao pode enviar chave CAPI ao provedor CNG.' }
        Mock Get-Acl {
            $acl = [Security.AccessControl.FileSecurity]::new()
            $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-5-19'), 'Read', 'Allow'))
            $acl
        }
    }
    AfterEach { $certificate.Dispose() }
    It 'usa o arquivo CAPI identificado pelo provedor nativo' {
        Set-CleanupCertificatePrivateKeyAcl -Certificate $certificate
        Should -Invoke Set-CleanupServiceAcl -Times 1 -ParameterFilter { $Path -eq (Join-Path $env:ProgramData 'Microsoft\Crypto\RSA\MachineKeys\test-key') -and $ServiceRights -eq 'Read' }
        Should -Invoke Set-CleanupCngKeyAcl -Times 0
        Should -Invoke Get-Acl -Times 1
    }
    It 'recusa chave de usuario antes de alterar ACL de maquina' {
        Mock Get-CleanupCapiKeyInfo { @{MachineKeyStore=$false;HardwareDevice=$false;UniqueKeyContainerName='test-key'} }
        { Set-CleanupCertificatePrivateKeyAcl -Certificate $certificate } | Should -Throw '*SPVC-KEY-ACL*armazenamento de maquina*'
        Should -Invoke Set-CleanupServiceAcl -Times 0
    }
    It 'recusa caminho inesperado retornado como nome da chave' {
        Mock Get-CleanupCapiKeyInfo { @{MachineKeyStore=$true;HardwareDevice=$false;UniqueKeyContainerName='..\other'} }
        { Set-CleanupCertificatePrivateKeyAcl -Certificate $certificate } | Should -Throw '*Identificador*invalido*'
        Should -Invoke Set-CleanupServiceAcl -Times 0
    }
    It 'nao tenta outro arquivo quando o arquivo CAPI nao existe' {
        Mock Test-Path { $false }
        { Set-CleanupCertificatePrivateKeyAcl -Certificate $certificate } | Should -Throw '*Arquivo da chave CAPI nao localizado*'
        Should -Invoke Set-CleanupServiceAcl -Times 0
    }
    It 'recusa ACL CAPI que conceda escrita a LOCAL SERVICE' {
        Mock Get-Acl {
            $acl = [Security.AccessControl.FileSecurity]::new()
            $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-5-19'), 'FullControl', 'Allow'))
            $acl
        }
        { Set-CleanupCertificatePrivateKeyAcl -Certificate $certificate } | Should -Throw '*releitura*'
    }
}
