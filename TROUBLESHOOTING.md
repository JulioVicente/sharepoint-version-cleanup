# Diagnóstico

## Dependências

Execute `scripts/Validate-Prerequisites.ps1` no PowerShell 5.1 ou 7. O diagnóstico não instala pacotes; testa inclusive a importação do módulo na sessão. Use `-SkipNetworkCheck` para verificar somente o ambiente local e `-PassThru` para obter os resultados como objetos. Cada falha informa a causa e a ação recomendada. O bootstrap prepara PowerShell 7.4.6+ por WinGet ou MSI oficial assinado; o wizard prepara os módulos compartilhados com PSResourceGet.

### Conflito Microsoft.Graph.Core e instalações incompletas

`Could not load type 'Microsoft.Graph.Authentication.AzureIdentityAccessTokenProvider' ... Microsoft.Graph.Core, Version=1.25.1.0` indica conflito de bibliotecas locais. Não é resolvido concedendo consentimento ou recriando certificado. PnP.PowerShell e Microsoft.Graph.Authentication podem exigir versões incompatíveis dessa DLL quando usados no mesmo processo.

O instalador atualizado mantém o Graph no processo do assistente e executa as operações PnP (descoberta do tenant, validação, email, simulação e piloto) em processos separados, sem perfis. Antes do login, cada módulo é importado em um processo de teste; no Graph também é verificada a presença do tipo necessário. A versão e o caminho validados aparecem no log. Uma falha de importação dispara uma reinstalação da mesma versão na PSGallery oficial e uma nova validação. Se o reparo falhar, a instalação para com `SPVC-DEPENDENCY` e a causa original.

Execute novamente o comando de instalação de `main` como Administrador. O bootstrap abre um PowerShell novo, evitando DLLs carregadas por tentativas manuais anteriores. Não é necessário desinstalar todos os módulos Graph/PnP: versões de outros usuários e demais módulos são preservados. Bloqueios de rede, políticas ou permissões podem exigir correção administrativa; o reparo não contorna essas restrições.

### A caixa “Consentir em nome da organização” não reaparece

O Entra pode reutilizar consentimento já registrado e não exibir novamente a caixa. O instalador não força essa tela nem concede consentimento organizacional automaticamente. Para revisar ou conceder depois, um administrador autorizado pode abrir **Entra → Aplicativos empresariais → aplicativo mostrado no login → Permissões → Conceder consentimento do administrador**. Confira o aplicativo e as permissões antes de aprovar. O login padrão do assistente usa o cliente do Microsoft Graph PowerShell; com `-AdminClientId`, usa o cliente informado.

Essa autorização de login é diferente da autorização do serviço. O aplicativo **SharePoint Version Cleanup** precisa de consentimento administrativo para a permissão de aplicativo SharePoint `Sites.Selected` e, se o email via Graph estiver habilitado, Microsoft Graph `Mail.Send`. A concessão `Write` nos sites escolhidos também é necessária. O assistente verifica/configura essas etapas separadamente. Desmarcar a caixa no login não explica um erro de DLL local.

Consulte [como conceder consentimento administrativo no Microsoft Entra](https://learn.microsoft.com/en-us/entra/identity/enterprise-apps/grant-admin-consent).

## JSON inválido

Consulte [CONFIGURATION.md](CONFIGURATION.md). Verifique tipos, GUID, thumbprint, URLs, escopo e caminhos absolutos. Rode o validador local antes da limpeza. URLs de telas (`Forms/AllItems.aspx`) não representam a URL do site nem o caminho da biblioteca.

## Conexão e acesso negado

Confirme tenant, certificado com chave privada na conta executora, consentimento `Sites.Selected` do aplicativo e concessão `Write` no site. Para configurar a concessão, use um aplicativo interativo administrativo com Microsoft Graph `Sites.FullControl.All` delegado. O aplicativo de limpeza não deve ser usado como aplicativo administrativo interativo.

Políticas de retenção, hold, rótulos ou permissões podem impedir exclusões. Não contorne essas regras. O log diferencia falha de conexão, processamento e envio de email.

## Tarefa não inicia

Confira a identidade LOCAL SERVICE, certificado com chave privada em `Cert:\LocalMachine\My`, acesso a rede e permissoes das pastas locais. O instalador nao solicita senha pessoal e testa essa identidade antes de agendar. O computador precisa estar ligado. Confira gatilho, fuso local e historico do Agendador. Alterar `Schedule` no JSON nao atualiza o gatilho de uma tarefa existente.

## Falha ao preparar a chave privada para LOCAL SERVICE

`SetProperty: Parâmetro incorreto` na etapa `preparar e testar LOCAL SERVICE` pode ocorrer quando uma chave legada CAPI importada de PFX aparece como `RSACng` no .NET. O instalador atualizado consulta o provedor nativo do certificado: aplica a ACL no arquivo identificado pelo CSP para CAPI e usa `Security Descr` do provedor para CNG. Ambos os caminhos releem a permissão de LOCAL SERVICE.

Execute novamente o bootstrap de `main` como Administrador, usando a mesma pasta de instalação e os valores sugeridos pelo assistente. O certificado válido existente pode ser reutilizado. Refazer consentimento no Entra não corrige essa falha local. Se persistir, o diagnóstico `SPVC-KEY-ACL` informa o certificado, código hexadecimal e causa original; confira permissões administrativas, disponibilidade da chave e compatibilidade do provedor. Chaves de hardware CAPI não são tratadas como arquivos de chave de software.

## Não remove versões

Sem `-Apply`, a execução é simulação. `VersionsToKeep` preserva N versões históricas além da atual. Arquivos com apenas uma versão não têm histórico removível. Em execução incremental, arquivos sem alterações entram em `FilesUnchanged`. Confira `VersionsEligible`, `FilesSkipped` e `Warnings` no relatório.

## Lock e checkpoint

A existência do arquivo `.lock` é normal; somente um handle aberto bloqueia outra execução. Não apague lock durante execução. Checkpoints são separados por site, modo e pasta. Mudanças de retenção arquivam automaticamente o checkpoint. Estados locais com JSON inválido são preservados em `.invalid-*.bak` e reconstruídos pela leitura atual do SharePoint. Erro de acesso ao estado não é tratado como corrupção: corrija a permissão ou o armazenamento. Arquivos antigos `checkpoint-<site>.json` não são reutilizados pelo novo formato.

## Códigos de diagnóstico e recuperação

| Código | Ação |
|---|---|
| `SPVC-RUNTIME` / `SPVC-DEPENDENCY` | Confira proxy, TLS, rede, espaço e permissões; a mensagem inclui a causa do download/importação. |
| `SPVC-POLICY` / `SPVC-PREREQUISITE` | Corrija o requisito indicado; políticas corporativas exigem atuação administrativa. |
| `SPVC-CERTIFICATE` / `SPVC-AUTH` | Confira validade, chave privada, aplicação, tenant e acesso da identidade executora. |
| `SPVC-PERMISSION` | Confira consentimento, Sites.Selected e restrições do SharePoint. |
| `SPVC-STORAGE` / `SPVC-REPORT` | Confira espaço, ACLs e caminhos; uma falha de relatório não substitui a causa original da limpeza. |
| `SPVC-SERVICE` | Consulte o código hexadecimal do Agendador, executável e caminhos informados. |
| `SPVC-KEY-ACL` | Execute o bootstrap atualizado como Administrador; confira o provedor, armazenamento da chave e erro local informado. |
| `SPVC-INSTALL-BUSY` | Aguarde a instalação ou tarefa em andamento; confira permissões se não houver execução. |
| `SPVC-ROLLBACK` / `SPVC-RECOVERY` | Preserve a pasta de backup. `recovery.json` mapeia arquivos e XML das tarefas. Recupere os arquivos antes de reativar tarefas; remova `.install-recovery.json` apenas após concluir. |

O instalador registra a etapa da falha e o log `%TEMP%/spvc-install-*.log`. Falhas fatais da limpeza informam caminhos do log/relatório; eles podem não existir se o próprio disco impedir a gravação. Os relatórios incluem `Diagnostic`, além do erro original. Confirmações de piloto e produção continuam obrigatórias a cada instalação.

O inventário `inventory-*.json` acelera o modo aplicado. Para forçar um levantamento completo, pare as tarefas, arquive o inventário e checkpoint correspondentes e rode novamente. Não altere estado com uma limpeza ativa. A próxima execução completa examina itens novos/alterados.

## Email

O envio usa Microsoft Graph com certificado. Em erro 403, confira Mail.Send (Application), consentimento administrativo e restrições de acesso à caixa no Exchange Online. A conta autenticada no assistente precisa ter caixa de correio; seu ID é salvo em Email.SenderUserId. Reexecute o assistente para migrar configurações SMTP antigas. Use -PreviewPath para conferir HTML sem envio. Falhas durante limpeza aparecem em NotificationError sem substituir o resultado da operação; o relatório continua local. A aceitação pelo Graph não garante entrega; confira destinatário e rastreamento do Exchange.

## Evidências

- `logs/cleanup-*.log`: transcrição.
- `logs/report-*.json`: escopo, contadores e erros.
- `state/checkpoint-*.json`: progresso de execução interrompida.
- `state/inventory-*.json`: assinaturas da última limpeza aplicada.
- Histórico do Agendador: início, saída e credencial da tarefa.

Não compartilhe PFX, senhas ou chaves privadas. Remova dados sensíveis dos logs antes de compartilhá-los.

## Idade, limites, novas tentativas e cópia externa

Nenhuma versão elegível: confira quantidade preservada e idade mínima (30 dias por padrão). Para um piloto controlado com versões novas, configure idade `0`.

`LimitReached` verdadeiro: execute novamente para retomar com novo limite por execução. O Agendador pode reiniciar até três vezes a cada 15 minutos.

Erro parcial: consulte `Errors`, `FilesFailed`, `LibrariesFailed` e eventos `VersionDeleteFailed`/`RequestRetry`. Erros permanentes exigem correção; throttling respeita `Retry-After`. Uma resposta perdida pode ocorrer depois de a exclusão remota ter sido feita: a retomada consulta novamente o histórico.

`AuditBackupError`: confira acesso da conta da tarefa a `Audit.CopyDirectory` e copie manualmente JSONL antigos pendentes. A cópia externa não reenvia arquivos de execuções anteriores.

Divergência SHA256: confira origem e versão. Em desenvolvimento, regenere o manifesto após alterações. Não desative a verificação para instalar componentes divergentes.

Aplicativo já existente: o assistente atual procura e reutiliza automaticamente o registro e um certificado associado. Não é necessário digitar Client ID ou thumbprint. Erros de permissão na consulta continuam sendo erros; não são tratados como aplicativo inexistente. O comando fixado em v1.2.1 continua usando o assistente antigo. Use a versão v1.3.0 ou posterior para essas correções.

## URL de biblioteca/pasta informada como site

A partir da v1.3.1, depois do login e antes de alterar o aplicativo/certificado, o assistente verifica se a URL representa um site. Se o Graph retornar 404, consulta os caminhos pais até encontrar um site válido e mantém o caminho original como escopo obrigatório de biblioteca/pasta. Por exemplo, `https://empresa.sharepoint.com/teste03` pode ser convertido em site `https://empresa.sharepoint.com` com pasta `/teste03`. Um site real chamado `/teste03` é preservado como site.

O assistente não remove a restrição de pasta nem assume o site raiz em erros 403 ou de rede. Se a validação não puder ser concluída, permite corrigir a URL no mesmo host sem recriar o aplicativo. Não são aceitos escopos diferentes do mesmo site na mesma instalação. Depois de descobrir o site pai, o assistente consulta a biblioteca/pasta no Graph e rejeita caminhos inexistentes ou arquivos. Revise os resultados da simulação antes de aprovar exclusões.

Os campos são validados assim que os dados necessários ficam disponíveis. Site e biblioteca/pasta são consultados depois do login e antes de alterar o aplicativo; a pasta de auditoria é criada quando necessário e testada com um arquivo temporário removido em seguida. O email é testado assim que aplicativo, certificado e destinatários estão definidos (exceto com -SkipEmailTest), antes das perguntas de retenção e agendamento. Sintaxe, limites, destinatários e horário são validados no próprio campo. A aceitação do email pelo Graph não comprova entrega nem existência de caixas externas.

## Certificado, consentimento e corpo do email

Na v1.3.2, o assistente consulta keyCredentials para confirmar o certificado antes de usá-lo. Isso não garante propagação imediata ao serviço de tokens. AADSTS700027 indica certificado não reconhecido: confira Certificados e segredos, aplicativo/tenant e propagação da chave. Repetir consentimento de API não registra um certificado.

HTTP 400 / BadRequest com parâmetro Message ausente indica um pedido de email inválido, não falta de Mail.Send. O envio serializa uma vez e transmite bytes JSON UTF-8 diretamente ao endpoint sendMail com token Graph obtido por certificado. Erros 400 encerram a tentativa com o diagnóstico original, sem pedir novo consentimento. HTTP 403 continua orientando verificar Mail.Send, consentimento e restrições da caixa no Exchange Online.

## Certificados recentes e fusos horários (v1.3.3)

A validade retornada pelo Graph pode chegar como DateTime UTC, DateTimeOffset ou texto ISO. A seleção agora normaliza os instantes para UTC antes da comparação com a validade local; isso corrige o descarte de certificados recentes causado pela comparação direta de UTC com horário local. O certificado precisa continuar válido e ter chave privada.

A confirmação remota compara o hash da chave pública real (campo key), não apenas customKeyIdentifier. Se a autenticação retornar AADSTS700027, tenta até seis vezes, com dez segundos de intervalo, sempre usando a mesma chave. Outras falhas não são tratadas como propagação. Se o aplicativo inteiro tiver sido apagado no Entra, a próxima execução criará outro Client ID e precisará de novo consentimento. Essa recriação também exigirá associar um certificado ao novo registro.

## v1.3.4: acesso negado ao consultar bibliotecas

O consentimento de Sites.Selected no Entra nao comprova a concessao ao site. O assistente agora relê as permissoes do site e confirma o Client ID atual e o papel de escrita, inclusive depois de recriar o aplicativo. Valida tambem Get-PnPList antes da simulacao; uma conexao ou Get-PnPWeb bem-sucedido nao basta.

Com pasta definida, consulta diretamente sua biblioteca. Sem pasta, consulta as bibliotecas do site. A consulta evita solicitar todas as propriedades de RootFolder e preserva o erro original com o site e o escopo. Nao amplia permissoes automaticamente para FullControl. Se a negacao persistir com a concessao confirmada, examine propagacao, restricoes das bibliotecas e politicas do tenant. Envio aceito pelo Graph comprova somente o envio ao servico de email, nao acesso ao SharePoint.

Periodicidade no assistente: D para diaria, S para semanal (padrao S). No JSON, Schedule.Frequency continua diaria/semanal; nomes de campos e valores Graph/true/false nao devem ser traduzidos.

## v1.3.7: checkpoint de uma politica anterior

Ao alterar a quantidade de versões mantidas ou a idade mínima, o checkpoint antigo é preservado como `.json.policy-<execucao>.bak` na pasta state. A nova execução reavalia os arquivos com a política atual. Isso também vale para a simulação, que continua sem excluir versões. Checkpoints de outro site ou modo são recusados; JSON ou estrutura inválida são preservados para diagnóstico e reconstruídos. Uma falha de checkpoint é estado local, não falta de consentimento no Entra.
