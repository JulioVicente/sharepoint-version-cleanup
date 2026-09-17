BeforeAll {
    . (Join-Path $PSScriptRoot '../Install.ps1') -WhatIf
    . (Join-Path $PSScriptRoot '../scripts/Configuration.ps1')
    . (Join-Path $PSScriptRoot '../scripts/TaskIdentity.ps1')
    $realAcl = (Get-Command Set-CleanupServiceAcl).ScriptBlock
    function New-ScheduledTaskPrincipal { param($UserId,$LogonType,$RunLevel) }
    function New-ScheduledTaskAction { param($Execute,$Argument) }
    function New-ScheduledTaskTrigger { param([switch]$Daily,$At,[switch]$Weekly,$DaysOfWeek) }
    function New-ScheduledTaskSettingsSet { param([switch]$StartWhenAvailable,$MultipleInstances,$ExecutionTimeLimit,$RestartCount,$RestartInterval) }
    function Register-ScheduledTask { param($TaskName,$TaskPath,$Action,$Trigger,$Settings,$Description,$Principal,[switch]$Force,$Xml,$User,$Password) }
    function Get-ScheduledTask { param($TaskName) }
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
        Mock Get-Content { '{"Success":true,"Identity":"S-1-5-19","Error":""}' }
    }
    It 'aceita somente o resultado da conta LOCAL SERVICE e remove a tarefa temporaria' {
        Test-CleanupServiceExecution -Configuration $cfg -Destination $TestDrive
        Should -Invoke Start-ScheduledTask -Times 1
        Should -Invoke Unregister-ScheduledTask -Times 1
        Should -Invoke Register-ScheduledTask -Times 1 -ParameterFilter { -not $Password }
    }
    It 'recusa resultado obtido sob outra identidade e limpa a tarefa' {
        Mock Get-Content { '{"Success":true,"Identity":"S-1-5-18","Error":"identidade incorreta"}' }
        { Test-CleanupServiceExecution -Configuration $cfg -Destination $TestDrive } | Should -Throw '*LOCAL SERVICE falhou*'
        Should -Invoke Unregister-ScheduledTask -Times 1
    }
    It 'preserva erro de acesso da conta de servico e limpa a tarefa' {
        Mock Get-Content { '{"Success":false,"Identity":"S-1-5-19","Error":"acesso negado"}' }
        { Test-CleanupServiceExecution -Configuration $cfg -Destination $TestDrive } | Should -Throw '*acesso negado*'
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
        [int]$key.Saved.Options | Should -Be -2147483644
        $sd = [Security.AccessControl.RawSecurityDescriptor]::new($key.Saved.GetValue(),0)
        $sd.DiscretionaryAcl.Count | Should -Be 3
        $sd.GetSddlForm([Security.AccessControl.AccessControlSections]::Access) | Should -Be 'D:P(A;;GA;;;SY)(A;;GA;;;BA)(A;;GR;;;LS)'
        Should -Invoke Set-CleanupServiceAcl -Times 0
    }
    It 'recusa releitura que concede escrita a conta de servico' {
        $key.Mismatch = $true
        { Set-CleanupCngKeyAcl -Key $key } | Should -Throw '*nao confirmou*'
    }
    It 'interrompe com diagnostico especifico se o provedor recusar a ACL' {
        $key.Failure = $true
        { Set-CleanupCngKeyAcl -Key $key } | Should -Throw '*provider unavailable*'
    }
}
