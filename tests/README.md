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

`tests/Test-ServiceTaskIntegration.ps1` exige Windows elevado e usa o Agendador real com LOCAL SERVICE. Cria apenas uma pasta descartável em ProgramData e tarefas temporárias de teste; verifica sucesso, encerramento sem resultado e timeout, incluindo a remoção das tarefas e arquivos. O worker simulado não acessa certificados, SharePoint ou email. O CI executa esse teste além dos testes unitários que usam o indicador de progresso real.

`Uninstall.Tests.ps1` cobre preservação de dados, tarefas de outra instalação, locks, redirecionamentos, falhas parciais e `WhatIf`. `Launcher.Tests.ps1` cobre os modos de limpeza, cancelamento e integridade do download. Os testes não desinstalam o produto desta máquina.

O CI também executa `./tests/Test-UninstallIntegration.ps1` em Windows elevado. Esse teste cria somente uma instalação fictícia temporária, usa um Agendador simulado e valida movimentação de arquivos e ACLs reais do backup. Não acessa o tenant nem tarefas existentes. A pasta temporária do próprio teste é validada e removida no `finally`.

`Test-ServiceContextIntegration.ps1 -ModulePath '<Program Files>/PowerShell/Modules/PnP.PowerShell/<versão>/PnP.PowerShell.psd1'` executa o worker de produção sob LOCAL SERVICE, em Windows elevado, com o módulo real. Valida assinatura SHA256, escrita em pastas e importação usando certificados descartáveis CNG, CAPI AES e CAPI Base (o legado usa SHA1 somente para emitir o certificado descartável). Remove certificados, chaves, tarefa e pasta do teste no finally. Não conecta ao tenant. O resultado tem Scope=Local, que o instalador recusa como aprovação completa.

`ServiceContext.Tests.ps1` injeta somente a identidade no arquivo de teste e simula PnP para cobrir o fluxo completo, múltiplos sites, pasta, falhas de configuração/conexão e preservação do erro original. `TaskIdentity.Tests.ps1` cobre formato de resultado, escopo, timeout por etapa e orçamento por quantidade de sites. O teste nativo do Agendador inclui uma tarefa bloqueada na etapa connect.

Na v1.4.12, Environment.Tests.ps1 cobre atualizacao de PnP 3.0.0, selecao da base 3.4.1 quando uma versao instalada exige PowerShell indisponivel, revalidacao depois do download e isolamento/restauracao de PSModulePath. O CI nativo usa PnP.PowerShell 3.4.1.

`ConfigurationReload.Tests.ps1` cobre JSON invalido, arquivo em gravacao, lock, rollback parcial, sites reordenados, tarefas desativadas e recuperacao interrompida. `Test-ConfigurationReloadIntegration.ps1` usa tarefas Windows e certificado descartaveis, sem acesso a SharePoint: comprova monitor SYSTEM, restart LOCAL SERVICE, atualizacao do horario e preservacao da execucao quando o JSON fica invalido. Recusa rodar se os nomes reservados ja existirem.
