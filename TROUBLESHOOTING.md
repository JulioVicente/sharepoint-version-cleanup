# Solução de problemas

## PowerShell ou módulo

Confirme `$PSVersionTable.PSVersion` (7.4+) e `Get-Module -ListAvailable PnP.PowerShell`. Use `pwsh` elevado quando necessário.

## Conexão ou acesso negado

Valide tenant, URL, Client ID, thumbprint, expiração do certificado, consentimento e acesso ao site. Não contorne retenção, legal hold ou rótulos; trate-os com a governança do Microsoft 365.

## Falha ao baixar arquivos do GitHub

Se o instalador não conseguir baixar `Install.ps1`, `cleanup-versions.ps1` ou o template HTML, valide a conectividade com o host bruto do GitHub e teste o download manualmente:

```powershell
Test-NetConnection raw.githubusercontent.com -Port 443
Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/JulioVicente/sharepoint-version-cleanup/main/scripts/cleanup-versions.ps1' -OutFile "$env:TEMP\cleanup-versions.ps1"
```

Quando a rede bloquear `raw.githubusercontent.com`, prefira executar a instalação a partir de um clone local do repositório para reaproveitar os arquivos já baixados:

```powershell
git clone https://github.com/JulioVicente/sharepoint-version-cleanup.git
pwsh -NoProfile -File .\sharepoint-version-cleanup\Install.ps1
```

## Certificado não encontrado na tarefa

Execute como a identidade da tarefa:

```powershell
Get-ChildItem Cert:\CurrentUser\My | Select-Object Thumbprint, Subject, NotAfter
```

Um certificado de outro usuário ou apenas em `LocalMachine` não é encontrado no fluxo de `CurrentUser`.

## Tarefa não inicia

Confira histórico, usuário/senha, `pwsh.exe`, argumentos, configuração e direito de logon como tarefa em lote. Verifique também a conectividade no horário agendado.

## Limpeza já em execução

O lock bloqueia concorrência por site. Confirme se existe um `pwsh` ativo antes de tratar um `.lock` como órfão; a finalização normal remove o arquivo.

## Checkpoint ou itens ignorados

O estado fica em `state\checkpoint-*.json`. Não o altere durante a execução. Arquivos em checkout e falhas individuais aparecem como ignorados no relatório.

## E-mail não enviado

Confira servidor, porta, TLS, remetente e destinatários. A senha criptografada só funciona sob o usuário/computador originais. Se SMTP autenticado estiver bloqueado, defina `Email.Enabled` como `false` até adotar método aprovado.

## Evidências

- `logs\cleanup-*.log`: transcrição
- `logs\report-*.json`: resumo
- `state\checkpoint-*.json`: retomada
- Histórico do Agendador e Visualizador de Eventos: execução da tarefa

Ao compartilhar um erro, remova segredos, dados pessoais e caminhos sensíveis.
