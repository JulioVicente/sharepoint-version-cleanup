# Instalação e operação

## Componentes e requisitos

`bootstrap.ps1` funciona no Windows PowerShell 5.1. Descobre PowerShell 7.4.6+ também fora do PATH ou instala a versão estável pelo WinGet. Se necessário, usa o MSI oficial do GitHub, valida a assinatura Microsoft e executa sem reiniciar o computador. Falhas informam causa e caminho do log MSI. Em seguida inicia `Install.ps1` em processo sem perfil. O instalador requer administrador e usa PSResourceGet, incluído no PowerShell, para preparar módulos compartilhados; não depende de NuGet ou PowerShellGet previamente configurados. PSGallery ausente é registrada; uma origem diferente usando esse nome é recusada.

PnP.PowerShell 3.x e Microsoft.Graph.Authentication 2.x compatíveis já presentes em AllUsers são reutilizados. Quando ausentes, são instaladas as versões 3.0.0 e 2.25.0, respectivamente. A importação usa o manifesto compartilhado. O requisito PowerShell 7.4.6 segue a [publicação oficial do PnP 3](https://pnp.github.io/blog/pnp-powershell/pnp-powershell-v3-0-0/).

O formato recomendado de uma linha é `iwr -useb https://raw.githubusercontent.com/JulioVicente/sharepoint-version-cleanup/main/bootstrap.ps1 | iex`. Ele instala a revisão atual sem parâmetros extras. É equivalente ao download e execução explícitos do `bootstrap.ps1`; use o fluxo de inspeção do guia rápido quando quiser revisar o conteúdo antes de executar.

Os scripts de operação exigem PowerShell 7.4.6+ e PnP.PowerShell 3.x. O diagnóstico de pré-requisitos também pode ser executado em Windows PowerShell 5.1. A limpeza usa aplicativo/certificado, portanto não pede login nas execuções agendadas. Pester é dependência apenas de desenvolvimento.

## Parâmetros do instalador e bootstrap

| Parâmetro | Uso |
|---|---|
| `InstallPath` | Pasta dedicada, padrão `%ProgramData%\SharePointVersionCleanup`. Não use a raiz do disco nem a pasta do código-fonte. |
| `RepositoryRawUrl` | URL raw de uma revisão/pasta do repositório. Em produção, pode ser fixada num commit revisado para obter componentes da mesma revisão. |
| `SkipAppRegistration` | Exige um aplicativo existente, encontrado automaticamente pelo nome; não cria outro aplicativo. Ainda pode associar um certificado e atualizar permissões. |
| `AdminClientId` | Opcional: Client ID próprio para o login do Graph. O padrão usa Microsoft Graph PowerShell e não pede esse ID. |
| `SkipEmailTest` | Pula o envio Graph de teste; não valida entrega de emails. |
| `WhatIf` | Sem efeitos colaterais: não instala, baixa, escreve, registra ou agenda. |

O instalador copia scripts, template, exemplo JSON e documentação operacional. `Install.ps1` é o assistente principal; `bootstrap.ps1` é o lançador. Não existem mais dois arquivos diferenciados somente por maiúsculas/minúsculas.

## Fluxo e aprovações

O wizard valida dados, registra/reutiliza aplicativo, grava configuracao, valida certificado e executa simulacao real do escopo. Solicita aprovacao antes do piloto aplicado e novamente para agendar exclusoes. As tarefas usam LOCAL SERVICE, sem senha pessoal e sem elevacao. Antes do piloto, uma tarefa temporaria verifica certificado, modulo PnP, pastas e leitura SharePoint sob essa identidade. Escopos sem aprovacao continuam em simulacao.

A operação agendada é uma tarefa do Windows, não um serviço residente. Há uma tarefa por site, diária ou semanal, com limite de 12 horas e bloqueio de múltiplas instâncias. O lock adicional é por site e diretório de estado. Consulte a [referência do JSON](CONFIGURATION.md) para detalhes de incremental e retomada.

## Atualização e falhas

Aguarde execuções terminarem antes de atualizar. O instalador recusa tarefas em execução, suspende as tarefas existentes da instalação e bloqueia outra instalação simultânea no mesmo destino. Preserva os arquivos gerenciados e o XML original das tarefas. Em falha, restaura os arquivos antes das tarefas; se a restauração falhar, mantém backups e informa os caminhos. O log de instalação fica em `%TEMP%/spvc-install-*.log`. Uma interrupção abrupta depois do backup deixa `.install-recovery.json`, que aponta para as evidências e impede sobrescrever a recuperação pendente.

O wizard carrega sugestões de `config/config.json` e da tentativa mais recente em `config/wizard-defaults.json`. Guarda cada resposta validada, mesmo se a instalação for revertida. Sites, pastas, retenção, email, auditoria, amostragem e horário podem ser aceitos com Enter ou substituídos. Senhas, tokens e aprovações de exclusão não entram nesse histórico. Para remover as sugestões, arquive o histórico; os valores de `config.json` continuam disponíveis enquanto esse arquivo existir. Valores aceitos passam novamente pela validação.

Registro Entra, certificado exportado, módulo instalado e exclusões de versões já aplicadas não são revertidos pelo rollback local. Se houver falha posterior ao piloto, consulte os relatórios antes de repetir. Tarefas antigas excedentes permanecem desabilitadas para não executar escopos removidos.

As permissões Microsoft 365 dependem do administrador: o assistente não pode conceder privilégios que a conta autenticada não possui. A leitura bem-sucedida não comprova permissão para excluir; o piloto aplicado é a validação dessa etapa.

## Desinstalação

No Agendador, desabilite e remova apenas as tarefas desta instalação. Preserve relatórios exigidos pela operação e remova os arquivos locais quando não forem necessários. Aplicativos Entra, concessões e certificados exigem remoção administrativa separada, depois de confirmar que não têm outros consumidores. Nunca use o procedimento de desinstalação para apagar arquivos ou versões no SharePoint.

## Versão e integridade

O bootstrap instala componentes de `main` por padrão. O parâmetro `-ReleaseVersion`, na execução por arquivo, seleciona outra tag ou commit; `-RepositoryRawUrl` permite usar outra origem com manifesto compatível. Para uma instalação fixada, baixe o bootstrap da revisão desejada e informe a mesma revisão em `-ReleaseVersion`.

A instalação remota verifica SHA256 de `Install.ps1` antes de executá-lo e dos componentes copiados, usando `release-manifest.json` da mesma revisão. O manifesto fica na instalação. Hashes detectam divergências; não substituem assinatura digital nem protegem contra comprometimento da origem comum ao script e manifesto.

Após mudanças no checkout, normalize os arquivos para LF conforme `.gitattributes` e execute `tools/Update-ReleaseManifest.ps1` antes dos testes e da publicação.

O Agendador faz até três reinícios separados por 15 minutos após erro, inclusive para retomar trabalho que atingiu o limite de exclusões por execução. Esse limite não é diário.

## Descoberta automática e consentimento

O login usa Microsoft Graph PowerShell com contexto restrito ao processo. Solicita permissões delegadas Application.ReadWrite.All (localizar e configurar aplicativo/certificado), Sites.FullControl.All (conceder acesso aos sites escolhidos) e User.Read (identificar o remetente). A conta precisa das funções administrativas adequadas. O aplicativo de limpeza usa Sites.Selected no SharePoint e, com email habilitado, Mail.Send de aplicativo no Graph; as permissões delegadas administrativas não são usadas pelo agendamento.

Client ID e thumbprint são descobertos automaticamente. Se houver aplicativos homônimos, o operador seleciona um item numerado. Sem certificado utilizável no Windows, o assistente cria um certificado de um ano, exporta backup PFX protegido por senha e CER em certificates e associa a chave pública, preservando as chaves anteriores. Só nessa criação pede a senha do PFX. Aplicativos existentes recebem permissões adicionais necessárias; o consentimento administrativo permanece uma etapa do tenant.

A identificação automática não dispensa políticas e consentimentos da organização. A conta usada no login será o remetente do email e precisa ter caixa no Exchange Online. Para tarefas sem usuário conectado, Mail.Send exige consentimento administrativo de aplicativo. Restrinja o acesso à caixa necessária no Exchange Online.

### Agendamento sem senha pessoal (v1.4.1)

O certificado existente e copiado para LocalMachine usando somente memoria, sem gravar senha ou PFX temporario em disco. O original do usuario e mantido. A chave de maquina permite acesso a administradores e SYSTEM, com leitura para LOCAL SERVICE. Os componentes da instalacao ficam protegidos contra escrita pela conta de servico; somente subpastas de estado, logs e auditoria permitem gravacao. O modulo PnP precisa estar instalado para todos os usuarios.

A pasta de instalacao deve ser local e dedicada, sem junctions/links. Auditoria, estado e logs devem permanecer em subpastas dela. A tarefa temporaria de teste nao envia email nem exclui versoes e e removida ao terminar, inclusive em erro. Uma falha impede a criacao dos agendamentos definitivos.

Tarefas antigas que dependem de senha pessoal são recusadas antes da atualização, pois sua identidade não pode ser restaurada automaticamente sem a senha. Migre ou remova essas tarefas antes de instalar. O rollback preserva o XML e a identidade originais das tarefas compatíveis. Certificado de máquina e ACLs preparados não são desfeitos pelo rollback de arquivos. O backup PFX de um certificado novo ainda solicita uma senha de proteção, distinta da senha pessoal do Windows.

Na v1.4.1, as permissoes de chaves CNG sao aplicadas diretamente pelo provedor do Windows (Security Descr), sem presumir uma pasta a partir de UniqueName. A permissao de leitura de LOCAL SERVICE e relida antes do teste real da tarefa. Falhas nessa etapa sao locais e nao exigem recriar o aplicativo ou repetir consentimento no Entra.

O instalador consulta `CERT_KEY_PROV_INFO_PROP_ID` para distinguir CAPI de CNG: uma chave CAPI importada pode aparecer como `RSACng` no .NET. Para CAPI de software, usa o nome unico fornecido pelo CSP para localizar o arquivo em `RSA/MachineKeys`; para CNG, usa a propriedade nativa `Security Descr` com `DACL_SECURITY_INFORMATION`. A permissao aplicada e relida nos dois casos. A classificacao segue [CRYPT_KEY_PROV_INFO](https://learn.microsoft.com/en-us/windows/win32/api/wincrypt/ns-wincrypt-crypt_key_prov_info).
