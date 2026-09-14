# Instalação e operação

## Componentes e requisitos

`bootstrap.ps1` é o ponto de entrada para o comando remoto e funciona no Windows PowerShell 5.1. Descobre PowerShell 7.4+ ou instala a versão estável pelo WinGet, verificando o código de saída. Sem WinGet, apresenta o endereço oficial para instalação manual. Em seguida inicia `Install.ps1` em PowerShell 7. O instalador requer administrador e instala/atualiza PnP.PowerShell 3.0+ para todos os usuários, verificando a importação.

Os scripts de operação exigem PowerShell 7.4+ e PnP.PowerShell. A limpeza usa aplicativo/certificado, portanto não pede login nas execuções agendadas. Pester é dependência apenas de desenvolvimento.

## Parâmetros do instalador e bootstrap

| Parâmetro | Uso |
|---|---|
| `InstallPath` | Pasta dedicada, padrão `%ProgramData%\SharePointVersionCleanup`. Não use a raiz do disco nem a pasta do código-fonte. |
| `RepositoryRawUrl` | URL raw de uma revisão/pasta do repositório. Em produção, pode ser fixada num commit revisado para obter componentes da mesma revisão. |
| `SkipAppRegistration` | Reutiliza Client ID e certificado; as concessões existentes devem ser válidas. |
| `AdminClientId` | Aplicativo interativo administrativo usado para conceder acesso por site. Não é o aplicativo de limpeza. |
| `SkipEmailTest` | Pula o envio SMTP de teste; não valida entrega de emails. |
| `WhatIf` | Sem efeitos colaterais: não instala, baixa, escreve, registra ou agenda. |

O instalador copia scripts, template, exemplo JSON e documentação operacional. `Install.ps1` é o assistente principal; `bootstrap.ps1` é o lançador. Não existem mais dois arquivos diferenciados somente por maiúsculas/minúsculas.

## Fluxo e aprovações

O wizard valida dados, registra/reutiliza aplicativo, grava configuração, valida certificado e executa simulação real do escopo. Solicita aprovação antes do piloto aplicado e novamente para agendar exclusões. O cadastro das tarefas usa a identidade atual, senha fornecida ao Agendador e nível elevado. Escopos sem aprovação continuam em simulação.

A operação agendada é uma tarefa do Windows, não um serviço residente. Há uma tarefa por site, diária ou semanal, com limite de 12 horas e bloqueio de múltiplas instâncias. O lock adicional é por site e diretório de estado. Consulte a [referência do JSON](CONFIGURATION.md) para detalhes de incremental e retomada.

## Atualização e falhas

Pause tarefas existentes e aguarde as execuções terminarem antes de atualizar. Execute o bootstrap do novo código. O wizard recolhe a configuração novamente; guarde uma cópia da anterior para consulta. A instalação faz backup dos arquivos gerenciados e das tarefas que substituir. Em falha, tenta restaurar esses arquivos e tarefas, preservando outros arquivos do diretório. Não apaga recursivamente toda a instalação.

Registro Entra, certificado exportado, módulo instalado e exclusões de versões já aplicadas não são revertidos pelo rollback local. Se houver falha posterior ao piloto, consulte os relatórios antes de repetir. Tarefas antigas além da quantidade configurada não são removidas automaticamente: revise e desabilite as excedentes.

As permissões Microsoft 365 dependem do administrador: o assistente não pode conceder privilégios que a conta autenticada não possui. A leitura bem-sucedida não comprova permissão para excluir; o piloto aplicado é a validação dessa etapa.

## Desinstalação

No Agendador, desabilite e remova apenas as tarefas desta instalação. Preserve relatórios exigidos pela operação e remova os arquivos locais quando não forem necessários. Aplicativos Entra, concessões e certificados exigem remoção administrativa separada, depois de confirmar que não têm outros consumidores. Nunca use o procedimento de desinstalação para apagar arquivos ou versões no SharePoint.

## Versão e integridade

O bootstrap instala componentes da tag `v1.1.0` por padrão. Para fixar também o lançador, troque `main` por `v1.1.0` na URL do comando. O parâmetro `-ReleaseVersion` seleciona outra tag no bootstrap; `-RepositoryRawUrl` permite usar um commit/origem com manifesto compatível.

A instalação remota verifica SHA256 de `Install.ps1` antes de executá-lo e dos componentes copiados, usando `release-manifest.json` da mesma revisão. O manifesto fica na instalação. Hashes detectam divergências; não substituem assinatura digital nem protegem contra comprometimento da origem comum ao script e manifesto.

Após mudanças no checkout, normalize os arquivos para LF conforme `.gitattributes` e execute `tools/Update-ReleaseManifest.ps1` antes dos testes e da publicação.

O Agendador faz até três reinícios separados por 15 minutos após erro, inclusive para retomar trabalho que atingiu o limite de exclusões por execução. Esse limite não é diário.
