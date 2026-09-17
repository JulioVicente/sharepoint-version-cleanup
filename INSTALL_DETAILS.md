# Instalação e operação

## Componentes e requisitos

`bootstrap.ps1` é o ponto de entrada para o comando remoto e funciona no Windows PowerShell 5.1. Descobre PowerShell 7.4+ ou instala a versão estável pelo WinGet, verificando o código de saída. Sem WinGet, apresenta o endereço oficial para instalação manual. Em seguida inicia `Install.ps1` em PowerShell 7. O instalador requer administrador e instala/atualiza PnP.PowerShell 3.0+ e Microsoft.Graph.Authentication 2.0+ para todos os usuários, verificando a importação.

O formato recomendado de uma linha é `iwr -useb https://raw.githubusercontent.com/JulioVicente/sharepoint-version-cleanup/v1.4.0/bootstrap.ps1 | iex`. Ele é equivalente ao download e execução explícitos do `bootstrap.ps1`; use o fluxo de inspeção do guia rápido quando quiser revisar o conteúdo antes de executar.

Os scripts de operação exigem PowerShell 7.4+ e PnP.PowerShell. A limpeza usa aplicativo/certificado, portanto não pede login nas execuções agendadas. Pester é dependência apenas de desenvolvimento.

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

Pause tarefas existentes e aguarde as execuções terminarem antes de atualizar. Execute o bootstrap do novo código. O wizard recolhe a configuração novamente; guarde uma cópia da anterior para consulta. A instalação faz backup dos arquivos gerenciados e das tarefas que substituir. Em falha, tenta restaurar esses arquivos e tarefas, preservando outros arquivos do diretório. Não apaga recursivamente toda a instalação.

Registro Entra, certificado exportado, módulo instalado e exclusões de versões já aplicadas não são revertidos pelo rollback local. Se houver falha posterior ao piloto, consulte os relatórios antes de repetir. Tarefas antigas além da quantidade configurada não são removidas automaticamente: revise e desabilite as excedentes.

As permissões Microsoft 365 dependem do administrador: o assistente não pode conceder privilégios que a conta autenticada não possui. A leitura bem-sucedida não comprova permissão para excluir; o piloto aplicado é a validação dessa etapa.

## Desinstalação

No Agendador, desabilite e remova apenas as tarefas desta instalação. Preserve relatórios exigidos pela operação e remova os arquivos locais quando não forem necessários. Aplicativos Entra, concessões e certificados exigem remoção administrativa separada, depois de confirmar que não têm outros consumidores. Nunca use o procedimento de desinstalação para apagar arquivos ou versões no SharePoint.

## Versão e integridade

O bootstrap instala componentes da tag `v1.4.0` por padrão. Para fixar também o lançador, troque `main` por `v1.4.0` na URL do comando. O parâmetro `-ReleaseVersion` seleciona outra tag no bootstrap; `-RepositoryRawUrl` permite usar um commit/origem com manifesto compatível.

A instalação remota verifica SHA256 de `Install.ps1` antes de executá-lo e dos componentes copiados, usando `release-manifest.json` da mesma revisão. O manifesto fica na instalação. Hashes detectam divergências; não substituem assinatura digital nem protegem contra comprometimento da origem comum ao script e manifesto.

Após mudanças no checkout, normalize os arquivos para LF conforme `.gitattributes` e execute `tools/Update-ReleaseManifest.ps1` antes dos testes e da publicação.

O Agendador faz até três reinícios separados por 15 minutos após erro, inclusive para retomar trabalho que atingiu o limite de exclusões por execução. Esse limite não é diário.

## Descoberta automática e consentimento

O login usa Microsoft Graph PowerShell com contexto restrito ao processo. Solicita permissões delegadas Application.ReadWrite.All (localizar e configurar aplicativo/certificado), Sites.FullControl.All (conceder acesso aos sites escolhidos) e User.Read (identificar o remetente). A conta precisa das funções administrativas adequadas. O aplicativo de limpeza usa Sites.Selected no SharePoint e, com email habilitado, Mail.Send de aplicativo no Graph; as permissões delegadas administrativas não são usadas pelo agendamento.

Client ID e thumbprint são descobertos automaticamente. Se houver aplicativos homônimos, o operador seleciona um item numerado. Sem certificado utilizável no Windows, o assistente cria um certificado de um ano, exporta backup PFX protegido por senha e CER em certificates e associa a chave pública, preservando as chaves anteriores. Só nessa criação pede a senha do PFX. Aplicativos existentes recebem permissões adicionais necessárias; o consentimento administrativo permanece uma etapa do tenant.

A identificação automática não dispensa políticas e consentimentos da organização. A conta usada no login será o remetente do email e precisa ter caixa no Exchange Online. Para tarefas sem usuário conectado, Mail.Send exige consentimento administrativo de aplicativo. Restrinja o acesso à caixa necessária no Exchange Online.

### Agendamento sem senha pessoal (v1.4.0)

O certificado existente e copiado para LocalMachine usando somente memoria, sem gravar senha ou PFX temporario em disco. O original do usuario e mantido. A chave de maquina permite acesso a administradores e SYSTEM, com leitura para LOCAL SERVICE. Os componentes da instalacao ficam protegidos contra escrita pela conta de servico; somente subpastas de estado, logs e auditoria permitem gravacao. O modulo PnP precisa estar instalado para todos os usuarios.

A pasta de instalacao deve ser local e dedicada, sem junctions/links. Auditoria, estado e logs devem permanecer em subpastas dela. A tarefa temporaria de teste nao envia email nem exclui versoes e e removida ao terminar, inclusive em erro. Uma falha impede a criacao dos agendamentos definitivos.

Ao atualizar tarefas antigas, a identidade passa a LOCAL SERVICE. Se houver rollback do cadastro, as acoes e gatilhos anteriores sao restaurados com essa identidade sem senha; nao e possivel recuperar a senha da tarefa antiga. Certificado de maquina e ACLs preparados nao sao desfeitos pelo rollback de arquivos. O backup PFX de um certificado novo ainda solicita uma senha de protecao, distinta da senha pessoal do Windows.
