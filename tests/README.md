# Testes

Execute em PowerShell 7.4+ com Pester 5.7.1 ou superior:

```powershell
Install-PSResource Pester -Version 5.7.1 -Scope CurrentUser
.\tests\Run-Tests.ps1
# Alternativa com módulo isolado:
.\tests\Run-Tests.ps1 -PesterPath '<caminho>\Pester.psd1'
```

A suíte usa mocks para SharePoint, Microsoft Graph, certificados e Agendador. Não exclui versões reais nem comprova permissões no tenant. A validação integrada exige piloto com aplicativo/certificado e escopo dedicado. O runner desativa TestRegistry, pois os testes não precisam alterar o registro.

Após editar arquivos distribuídos, normalize para LF conforme `.gitattributes` e execute `tools/Update-ReleaseManifest.ps1` antes dos testes de cópia do instalador.
