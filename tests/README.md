# Testes

Execute em PowerShell 7.4.6+ com Pester 5.7.1 ou superior:

```powershell
Install-PSResource Pester -Version 5.7.1 -Scope CurrentUser
.\tests\Run-Tests.ps1
# Alternativa com módulo isolado:
.\tests\Run-Tests.ps1 -PesterPath '<caminho>\Pester.psd1'
```

A suíte usa mocks para SharePoint, Microsoft Graph, certificados e Agendador. Não exclui versões reais nem comprova permissões no tenant. A validação integrada exige piloto com aplicativo/certificado e escopo dedicado. O runner desativa TestRegistry, pois os testes não precisam alterar o registro.

Após editar arquivos distribuídos, normalize para LF conforme `.gitattributes` e execute `tools/Update-ReleaseManifest.ps1` antes dos testes de cópia do instalador.

O teste nativo separado cria certificados e chaves descartáveis CAPI e CNG, exporta/importa PFX somente em memória e remove as chaves no `finally`:

```powershell
# Windows sem elevação: metadados do provedor e assinatura, sem alterar ACL.
.\tests\Test-KeyAclIntegration.ps1
# Windows elevado: aplica/reaplica e relê ACL em chaves de máquina; reabre e assina.
.\tests\Test-KeyAclIntegration.ps1 -MachineKey
```

O CI Windows executa também a variante elevada; a falta de elevação reprova esse teste. Ele não acessa o tenant nem substitui a tarefa de diagnóstico real sob LOCAL SERVICE executada pelo instalador.

`Uninstall.Tests.ps1` cobre preservação de dados, tarefas de outra instalação, locks, redirecionamentos, falhas parciais e `WhatIf`. `Launcher.Tests.ps1` cobre os modos de limpeza, cancelamento e integridade do download. Os testes não desinstalam o produto desta máquina.

O CI também executa `./tests/Test-UninstallIntegration.ps1` em Windows elevado. Esse teste cria somente uma instalação fictícia temporária, usa um Agendador simulado e valida movimentação de arquivos e ACLs reais do backup. Não acessa o tenant nem tarefas existentes. A pasta temporária do próprio teste é validada e removida no `finally`.
