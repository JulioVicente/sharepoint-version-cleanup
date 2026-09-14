# Referência do JSON de configuração

O assistente grava `config/config.json` na pasta de instalação, normalmente `C:\ProgramData\SharePointVersionCleanup`. A tarefa agendada lê esse arquivo a cada execução. O JSON contém dados de acesso e operação; não contém a chave privada do certificado nem a senha da conta do Agendador.

O exemplo [config/config.example.json](config/config.example.json) usa identificadores fictícios. Substitua-os pelos dados do seu aplicativo. O arquivo real é ignorado pelo Git.

## Exemplo para uma biblioteca de teste

```json
{
  "SchemaVersion": 2,
  "Tenant": "empresa.onmicrosoft.com",
  "AdminUrl": "https://empresa-admin.sharepoint.com",
  "Sites": ["https://empresa.sharepoint.com"],
  "FolderScopes": {"https://empresa.sharepoint.com": "/teste03"},
  "VersionsToKeep": 2,
  "Authentication": {
    "ClientId": "11111111-1111-1111-1111-111111111111",
    "CertificateThumbprint": "0123456789ABCDEF0123456789ABCDEF01234567"
  },
  "Email": {"Enabled": false},
  "Schedule": {"Frequency": "diaria", "Time": "22:00"},
  "Paths": {
    "State": "C:\\ProgramData\\SharePointVersionCleanup\\state",
    "Logs": "C:\\ProgramData\\SharePointVersionCleanup\\logs"
  }
}
```

Esse exemplo mantém a versão atual **mais duas versões históricas** de cada arquivo em `/teste03`, incluindo subpastas. Com versões `5.0` atual e `4.0`, `3.0`, `2.0`, `1.0` históricas, preserva `5.0`, `4.0` e `3.0`. As versões `2.0` e `1.0` ficam elegíveis. Sem `-Apply`, nenhuma é excluída.

## Campos gerais

| Campo | Tipo | Obrigatório / padrão | Uso |
|---|---|---|---|
| `SchemaVersion` | inteiro | Opcional; `1` quando omitido; wizard grava `2` | Aceita versões 1 e 2. Versões não suportadas são rejeitadas. |
| `Tenant` | string | Obrigatório | Domínio do tenant, normalmente `empresa.onmicrosoft.com`; usado na autenticação PnP. |
| `AdminUrl` | string | Gerado pelo wizard; não usado pela limpeza | URL do centro administrativo para configuração das concessões. Não é o site que será limpo. |
| `Sites` | array de strings | Obrigatório, ao menos um site | Lista de URLs HTTPS autorizadas. Uma execução trata somente o `-SiteUrl` informado, que deve estar nessa lista. |
| `FolderScopes` | objeto | Opcional no formato legado | Mapeia cada URL de site para uma biblioteca ou pasta dentro dele. Veja as regras abaixo. |
| `VersionsToKeep` | inteiro | Obrigatório; sugestão do wizard e modo direto: `10` | Quantidade de versões **históricas** preservadas, além da atual. Aceita 1 a 2147483647; zero, negativos, decimais e strings são rejeitados. |
| `Authentication` | objeto | Obrigatório | Aplicativo e certificado usados pelo processo de limpeza. |
| `Email` | objeto | Opcional; desabilitado se omitido | Configuração de envio SMTP. |
| `Schedule` | objeto | Opcional; semanal às `22:00` | Periodicidade usada na criação das tarefas. Editar o JSON não altera automaticamente o Agendador. |
| `Paths` | objeto | Obrigatório | Diretórios locais de estado e relatórios. |

Use aspas duplas no JSON, `true`/`false` sem aspas e barras invertidas duplicadas nos caminhos Windows. O leitor normaliza URLs de sites, removendo a barra final e comparando sem diferença de maiúsculas. Não use URLs de telas como `/Forms/AllItems.aspx?...` em `Sites`.

## Escopo por biblioteca ou pasta

```json
"Sites": ["https://empresa.sharepoint.com", "https://empresa.sharepoint.com/sites/equipe"],
"FolderScopes": {
  "https://empresa.sharepoint.com": "/teste03",
  "https://empresa.sharepoint.com/sites/equipe": "/sites/equipe/Documentos Compartilhados/Piloto"
}
```

- A chave é a URL de um site cadastrado em `Sites`; outras chaves são rejeitadas.
- O valor é um caminho relativo ao **servidor**, com `/` inicial. Inclua `/sites/equipe` quando houver.
- Use espaços reais, não `%20`. Não inclua endereço do navegador, query string, fragmento ou `..`.
- Subpastas são incluídas. `/teste03` não inclui `/teste030`.
- Um caminho inexistente causa falha antes de processar versões.
- No formato legado, chave ausente ou valor vazio significa **todo o site**. O wizard pergunta explicitamente antes de aceitar esse escopo.
- Se o JSON definir uma pasta, o parâmetro `-FolderServerRelativeUrl` precisa corresponder a ela; não pode ampliar o escopo.
- Uma configuração admite uma pasta por site. Para escopos independentes no mesmo site, use configurações/tarefas separadas e compartilhe o diretório `Paths.State` para que o lock do site impeça concorrência.

O filtro da aplicação limita o que o script processa. A permissão `Sites.Selected` é concedida ao site, não à pasta; isso não cria uma barreira de autorização por pasta no Microsoft 365.

## Authentication

| Campo | Tipo | Obrigatório | Descrição |
|---|---|---|---|
| `ClientId` | string GUID | Sim | Application (client) ID do aplicativo de limpeza. GUID vazio é rejeitado. Não use Object ID nem o ID do aplicativo administrativo. |
| `CertificateThumbprint` | string hexadecimal de 40 caracteres | Sim | Thumbprint do certificado em `Cert:\CurrentUser\My` da conta executora. O certificado precisa ter chave privada e estar dentro da validade. |

O wizard pode registrar o aplicativo de limpeza, solicitar `Sites.Selected` no SharePoint e conceder `Write` aos sites escolhidos. A concessão usa outro aplicativo com autenticação interativa e permissão **delegada** Microsoft Graph `Sites.FullControl.All`, com consentimento administrativo. O wizard oferece registrar esse aplicativo de configuração ou permite informar um existente. Autorizações administrativas e políticas do tenant continuam sendo necessárias.

`-SkipAppRegistration` reutiliza aplicativo e certificado existentes; pressupõe que consentimentos e concessões já estejam corretos. A simulação verifica se a leitura funciona. Somente o piloto aplicado verifica a exclusão real.

O PFX exportado pelo registro é protegido por senha solicitada no wizard. Essa senha não vai para o JSON. Guarde o backup e a chave privada sob controle de acesso. Para conferir o certificado, execute como a conta da tarefa:

```powershell
Get-ChildItem Cert:\CurrentUser\My | Select-Object Thumbprint, Subject, HasPrivateKey, NotAfter
```

## Email

O mínimo para não enviar mensagens é `"Email": {"Enabled": false}`. Se habilitar SMTP, use:

```json
"Email": {
  "Enabled": true,
  "SmtpServer": "smtp.empresa.com",
  "Port": 587,
  "UseSsl": true,
  "From": "relatorios@empresa.com",
  "To": ["operacao@empresa.com"],
  "UserName": "relatorios@empresa.com",
  "EncryptedPassword": "VALOR_GERADO_PELO_WIZARD"
}
```

| Campo | Tipo | Regra |
|---|---|---|
| `Enabled` | boolean | Deve ser `true` ou `false`. |
| `SmtpServer` | string | Obrigatório quando habilitado. Host do servidor, sem `smtp://`. |
| `Port` | inteiro | 1 a 65535; wizard sugere 587. |
| `UseSsl` | boolean | Wizard usa `true`. O transporte usa STARTTLS do `SmtpClient`, não TLS implícito da porta 465. |
| `From` | string | Endereço válido permitido pelo servidor. |
| `To` | array de strings | Pelo menos um destinatário válido. |
| `UserName` | string | Usuário SMTP; vazio para relay que não exige credenciais. |
| `EncryptedPassword` | string ou null | Necessária se `UserName` for preenchido. Não é senha em texto puro, Base64 nem senha do certificado. |

A proteção usa DPAPI: o valor só pode ser descriptografado pelo **mesmo usuário no mesmo computador**. Regere ao mudar a conta ou máquina. O processo não implementa OAuth SMTP; use um servidor/relay compatível com a política da organização. Para gerar o valor manualmente em PowerShell no computador executor:

```powershell
Read-Host 'Senha SMTP' -AsSecureString | ConvertFrom-SecureString
```

O wizard testa o envio, exceto com `-SkipEmailTest`. A execução registra falhas de notificação em `NotificationError` no relatório local, sem mascarar o resultado da limpeza. O teste de SMTP é um envio real; a prévia HTML é local:

```powershell
.\scripts\Send-EmailReport.ps1 -ConfigPath .\config\config.json -Test -PreviewPath .\preview.html
```

## Schedule e execução em segundo plano

| Campo | Tipo | Valores / padrão |
|---|---|---|
| `Frequency` | string | `diaria` ou `semanal`; padrão semanal. |
| `Time` | string | Horário local `HH:mm`, 00:00 a 23:59; padrão `22:00`. |

A execução usa o **Agendador de Tarefas do Windows**, com `pwsh.exe -NonInteractive`. Não instala um Windows Service residente. O Agendador guarda a credencial da conta atual para funcionar sem sessão aberta; o JSON não guarda essa senha. A conta deve possuir direito de logon como tarefa em lote e acesso ao certificado, rede e pastas locais.

No modo semanal, os sites são distribuídos de segunda a sexta, conforme a ordem em `Sites`; o sexto volta à segunda. As tarefas têm prefixo `SharePoint Version Cleanup - NN`, iniciam quando possível se perderem o horário, não iniciam outra instância da mesma tarefa e possuem limite de 12 horas.

**O JSON não liga produção.** `-Apply` nos argumentos da tarefa controla a exclusão. O wizard acrescenta esse argumento somente após simulação, aprovação da aplicação piloto, resultado aplicado com exclusões e sem arquivos ignorados, e aprovação do agendamento em produção. Caso contrário agenda simulação.

Editar `Schedule` não modifica gatilhos já registrados. Use novamente o wizard ou ajuste os gatilhos no Agendador. Mudanças de sites/pastas também exigem revisar os argumentos das tarefas. Desabilite tarefas antigas que deixarem de fazer parte da configuração; o instalador não remove silenciosamente tarefas excedentes.

## Paths, retomada e incremental

| Campo | Tipo | Regra |
|---|---|---|
| `Paths.State` | string | Caminho absoluto gravável. Checkpoints, inventário incremental e lock por site. |
| `Paths.Logs` | string | Caminho absoluto gravável. Transcrição e relatório JSON de cada execução. |

Não há expansão automática de `%ProgramData%` ou `$env:ProgramData` dentro do JSON: grave o caminho resolvido. Os diretórios são criados se necessário.

O modo aplicado enumera os itens atuais e compara `UniqueId`, `Modified` e `_UIVersionString` com o inventário da última limpeza. Arquivos sem alteração dispensam a consulta de histórico; os novos/alterados são processados. Se metadados estiverem ausentes, o arquivo é processado normalmente. A simulação sempre consulta o histórico. Isso é processamento incremental por arquivo; não usa a API delta nem evita enumerar a biblioteca.

O checkpoint registra arquivos concluídos após sucesso, separado por site, modo e pasta. Em interrupção, a próxima execução retoma os pendentes; arquivos excluídos do SharePoint não impedem a retomada. Na conclusão, remove o checkpoint. A assinatura de retenção invalida o inventário quando `VersionsToKeep` muda; checkpoint interrompido com retenção diferente exige arquivamento manual antes de reiniciar. Um arquivo alterado depois de concluído durante uma execução interrompida será reconsiderado no ciclo completo seguinte.

O arquivo `.lock` pode permanecer no disco. A exclusividade vem do handle aberto, não de sua existência. Não o apague durante uma execução. Use o mesmo diretório de estado para operações concorrentes no mesmo site. Caminhos diferentes não compartilham esse lock.

Arquivos com checkout, rótulo de conformidade ou flags de proteção são ignorados e aparecem no relatório. O script não resolve retenção, hold ou presença ativa de editores; o SharePoint pode recusar operações. Não contorne essas recusas.

## Alterar e validar a configuração

1. Pause a tarefa e aguarde a execução atual terminar.
2. Faça uma cópia do JSON e edite os campos desejados.
3. Valide localmente:

```powershell
. .\scripts\Configuration.ps1
$config = Read-CleanupConfiguration -Path .\config\config.json
'Configuracao valida'
```

4. Rode uma nova simulação. Mudanças de escopo ou retenção exigem nova revisão antes de aplicar.
5. Atualize os argumentos/gatilhos da tarefa quando necessário e reative somente o escopo aprovado.

| Alteração | Efeito |
|---|---|
| Retenção, autenticação, SMTP, Logs | Lidos na próxima execução; retenção requer nova avaliação. |
| Pasta do site | Lida na próxima execução, mas argumento de pasta divergente faz a tarefa falhar. Atualize ambos. |
| State | Usa outro estado e lock; implica novo levantamento. Não altere durante execução. |
| Horário/frequência ou lista de sites | Requer atualizar/criar tarefas; editar JSON sozinho não altera o Agendador. |
| Simulação para produção | Requer `-Apply` e fluxo de aprovação; não existe campo `Apply` no JSON. |

Não use o JSON para armazenar tokens, senhas em texto puro, chaves privadas ou credenciais do Windows.

## Relatório de execução

`Success`, `Error`, `SiteUrl`, `FolderServerRelativeUrl`, `Apply` e `VersionsToKeep` identificam o resultado e escopo. `FilesProcessed`, `FilesUnchanged` e `FilesSkipped` diferenciam processamento, cache incremental e proteção/falha. `VersionsEligible`/`BytesEligible` indicam o potencial; `VersionsDeleted`/`BytesFreed` contam apenas exclusões efetivas. Os bytes refletem tamanhos reportados pelo provedor e não garantem atualização imediata da quota do SharePoint. `Warnings`, `NotificationError`, `StartedAt`, `FinishedAt`, `LogPath` e `ReportPath` completam o diagnóstico. Os contadores são da invocação atual, não o acumulado de todas as retomadas.

## Referências de comportamento do provedor

- [Get-PnPFileVersion](https://pnp.github.io/powershell/cmdlets/Get-PnPFileVersion.html): retorna histórico sem a versão atual.
- [Grant-PnPEntraIDAppSitePermission](https://pnp.github.io/powershell/cmdlets/Grant-PnPEntraIDAppSitePermission.html): concessões por site e permissão delegada necessária.
- [Register-PnPEntraIDApp](https://pnp.github.io/powershell/cmdlets/Register-PnPEntraIDApp.html): registro e certificado.

## Segurança, tentativas e cópia da auditoria

As seções abaixo são opcionais; estes padrões se aplicam quando omitidas:

```json
{
  "Safety": { "MaxVersionsPerRun": 1000, "MinimumVersionAgeDays": 30 },
  "Retry": { "MaxRetries": 3, "BaseDelaySeconds": 2, "MaxDelaySeconds": 60 },
  "Audit": { "CopyDirectory": "" }
}
```

| Campo | Tipo e valores | Comportamento |
|---|---|---|
| `Safety.MaxVersionsPerRun` | Inteiro 1–1000000; padrão 1000 | Máximo de exclusões confirmadas por execução de site. Havendo mais candidatas, registra `RunLimitReached`, mantém pendências e retorna erro para retomada. Não é limite diário. |
| `Safety.MinimumVersionAgeDays` | Inteiro 0–36500; padrão 30 | Idade mínima das versões excedentes. `0` permite testar versões recém-criadas. Preserva sempre a versão atual e as N históricas mais recentes. |
| `Retry.MaxRetries` | Inteiro 0–10; padrão 3 | Tentativas adicionais por chamada; zero desativa as tentativas do programa. O SDK pode ter tentativas próprias. |
| `Retry.BaseDelaySeconds` | Inteiro 1–300; padrão 2 | Espera inicial, crescendo exponencialmente, com pequena variação aleatória. |
| `Retry.MaxDelaySeconds` | Inteiro 1–3600; padrão 60; maior ou igual à espera inicial | Teto da espera calculada. Um `Retry-After` maior enviado pelo servidor prevalece. |
| `Audit.CopyDirectory` | Texto; padrão vazio | Diretório absoluto local ou UNC acessível à conta da tarefa. Recebe cópia dos JSONL desta execução ao final. Vazio desativa; não aceita URL HTTP. |

As tentativas cobrem timeouts, erros de rede reconhecidos e HTTP 408, 429, 500, 502, 503 e 504. Erros permanentes são registrados sem repetição imediata. O tratamento respeita a orientação da [Microsoft sobre Retry-After](https://learn.microsoft.com/en-us/sharepoint/dev/general-development/how-to-avoid-getting-throttled-or-blocked-in-sharepoint-online).

A idade é calculada em UTC. O inventário guarda a próxima data de reavaliação: versões protegidas pela idade voltam a ser consideradas quando envelhecem, mesmo sem alteração do arquivo. Mudanças na quantidade ou idade invalidam o inventário. Arquive checkpoints pendentes com política diferente antes de reiniciar.

Na CLI sem JSON, use `-MaxVersionsPerRun` e `-MinimumVersionAgeDays`. Tentativas e cópia externa são configuráveis pelo JSON. A aplicação reavalia o histórico disponível; não exige plano fixo de versões vinculado à simulação.

## Auditoria e resultado da execução

Em `Paths.Logs`, há transcript `.log`, resumo `report-*.json` e eventos `audit-AAAAMMDD-<site>-<execução>.jsonl`. A data é local à máquina; cada evento inclui horário e fuso. Uma execução que atravessa a meia-noite pode gerar dois arquivos diários.

Cada linha contém `Timestamp`, `RunId`, `SiteUrl`, `FolderServerRelativeUrl`, `Mode`, `Event`, `Outcome`, `FileUrl`, `VersionId`, `Reason`, `Error`, `VersionsToKeep` e `Details`. Não registra conteúdo dos documentos, senhas ou chaves.

| Evento | Significado |
|---|---|
| `RunStarted` / `RunCompleted` | Início e resultado final. O início inclui identidade da execução e SHA256 do script. |
| `LibraryScanned` / `DirectoryScanned` | Bibliotecas e diretórios encontrados na varredura. |
| `RetentionDecision` | IDs preservados, elegíveis e adiados pela idade; regra aplicada e preservação da versão atual. |
| `VersionWouldDelete` | Exclusão simulada. |
| `VersionDeleteRequested` / `VersionDeleted` | Tentativa de exclusão / sucesso retornado pelo provedor. |
| `VersionDeleteFailed` | Erro da exclusão. Se houve timeout, a próxima leitura confirma o estado remoto. |
| `FileCompleted` / `FileFailed` / `FileSkipped` | Resultado por arquivo e motivo. O conteúdo do arquivo não é modificado. |
| `LibraryFailed` / `RequestRetry` / `RunLimitReached` | Falha por biblioteca, nova tentativa ou limite atingido. |
| `AuditCopyFailed` | Falha na cópia externa; conserva auditoria local. |

```powershell
.\scripts\Get-DailyAudit.ps1 -ConfigPath 'C:\ProgramData\SharePointVersionCleanup\config\config.json' `
  -Date '2026-09-13' -OutputCsv 'C:\Relatorios\auditoria.csv'
# Alternativa sem JSON; data padrão: hoje
.\scripts\Get-DailyAudit.ps1 -LogsPath 'C:\SPCleanup\logs'
```

Crie previamente a pasta de destino do CSV. O comando consolida sucessos, falhas, diretórios e arquivos que tiveram versões excluídas. Simulação não é contada como exclusão.

O relatório contém `Success`, `Error`, `Errors`, `FilesProcessed`, `FilesUnchanged`, `FilesSkipped`, `FilesFailed`, `LibrariesFailed`, `VersionsEligible`, `VersionsDeleted`, `BytesEligible`, `BytesFreed`, `LimitReached`, `AuditPaths`, `AuditBackupError` e `NotificationError`. Os bytes são estimativas, sem garantia de liberação imediata da quota. Sucesso da limpeza não significa entrega de email ou sucesso da cópia externa; consulte os campos correspondentes.

Falhas por arquivo ou biblioteca permitem continuar os demais. Qualquer falha operacional resulta em saída diferente de zero e conserva checkpoint; a retomada reavalia o histórico atual dos arquivos incompletos. Autenticação inválida, estado corrompido ou impossibilidade de gravar auditoria podem impedir continuidade. Uma interrupção abrupta pode deixar início sem evento de conclusão. Nenhum programa é imune a falhas.

A cópia externa ocorre ao final, não é transmissão contínua nem armazenamento imutável. Não há reenvio automático de cópias antigas nem expiração automática de logs. Preserve os JSONL locais até confirmar a cópia.
