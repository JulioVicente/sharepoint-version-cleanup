BeforeAll {
    . (Join-Path $PSScriptRoot '../Install.ps1') -WhatIf
    . (Join-Path $PSScriptRoot '../bootstrap.ps1') -WhatIf
    if (-not (Get-Command Get-PSResourceRepository -ErrorAction SilentlyContinue)) {
        function Get-PSResourceRepository { param($Name) }
        function Register-PSResourceRepository { param([switch]$PSGallery) }
        function Install-PSResource { param($Name,$Version,$Scope,$Repository,[switch]$TrustRepository,[switch]$Quiet) }
    }
    function Register-ScheduledTask { param($TaskName,$TaskPath,$Xml,[switch]$Force) }
    function Unregister-ScheduledTask { param($TaskName,$TaskPath,[switch]$Confirm) }
    function Get-ScheduledTask { param($TaskName,$TaskPath) }
    function Export-ScheduledTask { param($TaskName,$TaskPath) }
    function Disable-ScheduledTask { param($TaskName,$TaskPath) }
}
Describe 'Preparacao de dependencias' {
    BeforeEach {
        $script:installedModule = $false
        $shared = Join-Path $env:ProgramFiles 'PowerShell\Modules\PnP.PowerShell\3.0.0'
        Mock Get-Module {
            if ($script:installedModule) { [pscustomobject]@{ModuleBase=$shared;Path=(Join-Path $shared 'PnP.PowerShell.psd1');Version=[version]'3.0.0';PowerShellVersion=[version]'7.4.6'} }
            else { [pscustomobject]@{ModuleBase='C:\Users\Someone\Documents\PowerShell\Modules\PnP.PowerShell';Path='user-module.psd1';Version=[version]'3.0.0';PowerShellVersion=[version]'7.4.6'} }
        }
        Mock Import-Module {}
        Mock Get-PSResourceRepository { $null }
        Mock Register-PSResourceRepository {}
        Mock Install-PSResource { $script:installedModule = $true }
    }
    It 'repara PSGallery ausente e modulo disponivel apenas ao usuario' {
        Ensure-CleanupModule PnP.PowerShell 3.0.0 3.0.0
        Should -Invoke Register-PSResourceRepository -Times 1 -ParameterFilter { $PSGallery }
        Should -Invoke Install-PSResource -Times 1 -ParameterFilter { $Scope -eq 'AllUsers' -and $Version -eq '3.0.0' }
        Should -Invoke Import-Module -Times 1 -ParameterFilter { $Name -eq (Join-Path $shared 'PnP.PowerShell.psd1') }
    }
    It 'reutiliza modulo compartilhado sem rede' {
        $script:installedModule = $true
        Ensure-CleanupModule PnP.PowerShell 3.0.0 3.0.0
        Should -Invoke Install-PSResource -Times 0
        Should -Invoke Get-PSResourceRepository -Times 0
    }
    It 'recusa repositorio com nome oficial e endereco trocado' {
        Mock Get-PSResourceRepository { @{Uri=[uri]'https://example.org/api/v2'} }
        { Ensure-CleanupModule PnP.PowerShell 3.0.0 3.0.0 } | Should -Throw '*SPVC-DEPENDENCY*endereco diferente*'
        Should -Invoke Install-PSResource -Times 0
    }
    It 'explica falha de download preservando a causa' {
        Mock Install-PSResource { throw 'TLS handshake failed' }
        { Ensure-CleanupModule PnP.PowerShell 3.0.0 3.0.0 } | Should -Throw '*SPVC-DEPENDENCY*TLS handshake failed*'
    }
    It 'localiza o PowerShell atual mesmo com PATH sem pwsh' {
        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'pwsh.exe' }
        Find-CleanupPowerShell | Should -Be (Join-Path $PSHOME 'pwsh.exe')
    }
}
Describe 'Fallback MSI do bootstrap' {
    BeforeEach {
        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'winget.exe' }
        Mock Invoke-RestMethod { @{tag_name='v7.6.0';assets=@(@{name='PowerShell-7.6.0-win-x64.msi';browser_download_url='https://github.com/PowerShell/PowerShell/releases/download/v7.6.0/PowerShell-7.6.0-win-x64.msi'},@{name='PowerShell-7.6.0-win-arm64.msi';browser_download_url='https://github.com/msi-arm64'})} }
        Mock Invoke-WebRequest {}
        Mock Get-AuthenticodeSignature { @{Status='Valid';SignerCertificate=@{Subject='CN=Microsoft Corporation, O=Microsoft Corporation, C=US'}} }
        Mock Start-Process { @{ExitCode=0} }
        Mock Find-CleanupPowerShell { 'C:\Program Files\PowerShell\7\pwsh.exe' }
    }
    It 'instala MSI assinado sem WinGet e retorna um unico caminho' {
        $result = @(Install-CleanupPowerShell)
        $result.Count | Should -Be 1
        $result[0] | Should -Be 'C:\Program Files\PowerShell\7\pwsh.exe'
        Should -Invoke Start-Process -Times 1 -ParameterFilter { $WindowStyle -eq 'Hidden' -and $Wait -and $ArgumentList -match '/norestart' }
    }
    It 'nao executa MSI cuja assinatura nao e valida' {
        Mock Get-AuthenticodeSignature { @{Status='HashMismatch';SignerCertificate=$null} }
        { Install-CleanupPowerShell } | Should -Throw '*SPVC-RUNTIME*Assinatura*'
        Should -Invoke Start-Process -Times 0
    }
    It 'preserva codigo de falha e caminho do log MSI' {
        Mock Start-Process { @{ExitCode=1603} }
        { Install-CleanupPowerShell } | Should -Throw '*1603*Log:*'
    }
}
Describe 'Instalacao anterior e rollback' {
    BeforeEach {
        $script:TaskBackups = @{}
        $script:NewTasks = [Collections.Generic.List[string]]::new()
        Mock Register-ScheduledTask {}
        Mock Unregister-ScheduledTask {}
        Mock Disable-ScheduledTask {}
        Mock Export-ScheduledTask { '<Task />' }
    }
    It 'nao altera tarefa em execucao' {
        $arguments = '-ConfigPath "' + (Join-Path $TestDrive 'config\config.json') + '"'
        Mock Get-ScheduledTask { @{TaskName='SharePoint Version Cleanup - 01';State='Running';Actions=@(@{Arguments=$arguments});Principal=@{LogonType='ServiceAccount'}} }
        { Suspend-CleanupInstallationTasks $TestDrive } | Should -Throw '*SPVC-INSTALL-BUSY*'
        Should -Invoke Disable-ScheduledTask -Times 0
    }
    It 'recusa caminho de instalacao que e arquivo ou compartilhamento' {
        $file = Join-Path $TestDrive 'file.txt'
        'original' | Set-Content $file
        { Assert-CleanupInstallPath $file } | Should -Throw '*SPVC-PATH*'
        { Assert-CleanupInstallPath '\\server\share\cleanup' } | Should -Throw '*SPVC-PATH*'
        Get-Content $file | Should -Be 'original'
    }
    It 'nao altera identidade de tarefa antiga baseada em senha' {
        $arguments = '-ConfigPath "' + (Join-Path $TestDrive 'config\config.json') + '"'
        Mock Get-ScheduledTask { @{TaskName='SharePoint Version Cleanup - 01';State='Ready';Actions=@(@{Arguments=$arguments});Principal=@{LogonType='Password'}} }
        { Suspend-CleanupInstallationTasks $TestDrive } | Should -Throw '*SPVC-LEGACY-TASK*'
        Should -Invoke Disable-ScheduledTask -Times 0
    }
    It 'restaura arquivos e o XML original sem trocar principal' {
        $target = Join-Path $TestDrive 'target.txt'; $backup = Join-Path $TestDrive 'backup.txt'
        'old' | Set-Content $backup; 'new' | Set-Content $target
        $script:TaskBackups['old-task'] = '<Task><OriginalPrincipal /></Task>'
        Restore-CleanupInstallation -Backups @{$target=$backup} -Written @($target) -RollbackRoot $TestDrive | Should -BeTrue
        Get-Content $target | Should -Be 'old'
        Should -Invoke Register-ScheduledTask -Times 1 -ParameterFilter { $Xml -eq '<Task><OriginalPrincipal /></Task>' }
    }
    It 'preserva backup e mantem tarefa suspensa se a restauracao falhar' {
        $target = Join-Path $TestDrive 'target.txt'; $backup = Join-Path $TestDrive 'backup.txt'
        'old' | Set-Content $backup
        $script:TaskBackups['old-task'] = '<Task />'
        Mock Copy-Item { throw 'disk unavailable' }
        Restore-CleanupInstallation -Backups @{$target=$backup} -Written @($target) -RollbackRoot $TestDrive -WarningAction SilentlyContinue | Should -BeFalse
        Get-Content $backup | Should -Be 'old'
        Should -Invoke Register-ScheduledTask -Times 0
    }
}
