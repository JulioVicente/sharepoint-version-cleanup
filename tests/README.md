# Testes automatizados

Os testes usam Pester e mocks para não acessar SharePoint nem enviar e-mail.

```powershell
Invoke-Pester -Path ./tests
```

Recomenda-se Pester 5. O ambiente também pode executar a suíte com Pester 3.4.

O caminho de envio habilitado não é exercitado porque `Send-EmailReport.ps1` instancia
`System.Net.Mail.SmtpClient` diretamente. Para testar assunto, destinatários, corpo e
anexos sem rede, extraia o envio para uma função ou adaptador injetável e faça mock
dessa fronteira.
