# Diagnóstico

## Dependências

Execute `scripts/Validate-Prerequisites.ps1` no PowerShell 7. O diagnóstico é somente de leitura; não instala pacotes nem altera o sistema. Use `-SkipNetworkCheck` para verificar somente o ambiente local. O bootstrap instala PowerShell via WinGet quando necessário; o wizard instala/atualiza PnP.PowerShell. Falhas de download/importação são exibidas e interrompem a instalação.

## JSON inválido

Consulte [CONFIGURATION.md](CONFIGURATION.md). Verifique tipos, GUID, thumbprint, URLs, escopo e caminhos absolutos. Rode o validador local antes da limpeza. URLs de telas (`Forms/AllItems.aspx`) não representam a URL do site nem o caminho da biblioteca.

## Conexão e acesso negado

Confirme tenant, certificado com chave privada na conta executora, consentimento `Sites.Selected` do aplicativo e concessão `Write` no site. Para configurar a concessão, use um aplicativo interativo administrativo com Microsoft Graph `Sites.FullControl.All` delegado. O aplicativo de limpeza não deve ser usado como aplicativo administrativo interativo.

Políticas de retenção, hold, rótulos ou permissões podem impedir exclusões. Não contorne essas regras. O log diferencia falha de conexão, processamento e envio de email.

## Tarefa não inicia

Confira a senha da conta (não o PIN do Windows Hello), direito de logon como tarefa em lote, certificado em `Cert:\CurrentUser\My`, acesso à rede e caminhos graváveis. O computador precisa estar ligado. Confira gatilho, fuso local e histórico do Agendador. Alterar `Schedule` no JSON não atualiza o gatilho de uma tarefa existente.

## Não remove versões

Sem `-Apply`, a execução é simulação. `VersionsToKeep` preserva N versões históricas além da atual. Arquivos com apenas uma versão não têm histórico removível. Em execução incremental, arquivos sem alterações entram em `FilesUnchanged`. Confira `VersionsEligible`, `FilesSkipped` e `Warnings` no relatório.

## Lock e checkpoint

A existência do arquivo `.lock` é normal; somente um handle aberto bloqueia outra execução. Não apague lock durante execução. Checkpoints são separados por site, modo e pasta. Checkpoint interrompido com retenção diferente falha explicitamente: pare as tarefas, arquive esse checkpoint e simule novamente. Arquivos de checkpoint antigos `checkpoint-<site>.json` não são reutilizados pelo novo formato.

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
