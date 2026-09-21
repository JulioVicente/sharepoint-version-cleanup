# SharePoint Version Cleanup

Assistente PowerShell para limpar versões antigas de arquivos no SharePoint Online. Preserva o arquivo, a versão atual e a quantidade configurada de versões históricas. Inclui simulação, relatórios, retomada e tarefas incrementais no Windows.

## Instalação em um comando

Abra **PowerShell como Administrador** e execute:

```powershell
iwr -useb https://raw.githubusercontent.com/JulioVicente/sharepoint-version-cleanup/main/bootstrap.ps1 | iex
```

Esse comando busca o lançador no GitHub e inicia o wizard. Para inspecionar antes, siga o [guia rápido](QUICK_START.md). O bootstrap verifica PowerShell 7.4.6+ e instala via WinGet quando necessário, com alternativa pelo MSI oficial de assinatura Microsoft validada. O wizard prepara PnP.PowerShell 3.x para todos os usuários, pergunta os dados, valida o acesso e simula. Os últimos valores preenchidos aparecem como sugestões: Enter aceita, e outro valor substitui a sugestão.

O lançador de `main` instala a versão estável **v1.4.2**, com componentes fixados nessa tag e verificação SHA256, sem parâmetros adicionais. A [release v1.4.2](https://github.com/JulioVicente/sharepoint-version-cleanup/releases/tag/v1.4.2) inclui as correções de permissões CAPI/CNG, diagnósticos de instalação e sugestões dos últimos valores do wizard. Para selecionar outra revisão, use `-ReleaseVersion` ou `-RepositoryRawUrl` na execução por arquivo. Para testar um checkout local, regenere o manifesto com `& .\tools\Update-ReleaseManifest.ps1` e execute `& .\bootstrap.ps1`.

## Fluxo do assistente

1. Verifica Windows, administrador, PowerShell e PnP.PowerShell.
2. Solicita sites, identifica o tenant pela URL e autentica no Microsoft 365. Localiza aplicativo/certificado automaticamente; configura escopo, retenção, email Graph, auditoria e horário.
3. Executa uma simulação e mostra arquivos, versões elegíveis e espaço estimado.
4. Solicita aprovação para aplicar o piloto; mostra o resultado real.
5. Solicita aprovação para agendar o escopo em produção. Escopos não aprovados ficam em simulação.

O acesso administrativo, consentimentos e políticas do tenant precisam permitir o registro e as operações. O assistente valida os dados e a execução, mas não contorna permissões ou retenção.

## Execução simples, sem JSON

Depois de instalar as dependências, em PowerShell 7:

```powershell
.\scripts\cleanup-versions.ps1 `
  -SiteUrl 'https://empresa.sharepoint.com' `
  -Directory '/teste03' `
  -Tenant 'empresa.onmicrosoft.com' `
  -ClientId '11111111-1111-1111-1111-111111111111' `
  -CertificateThumbprint '0123456789ABCDEF0123456789ABCDEF01234567' `
  -VersionsToKeep 2 `
  -OutputDirectory 'C:\SPCleanup'
```

Os identificadores são exemplos. `-Directory` é um alias para `-FolderServerRelativeUrl`: indica a biblioteca/pasta **no SharePoint**. `-OutputDirectory` indica onde guardar logs e estado **localmente**. Sem ele, usa `.spvc` no diretório de trabalho. Adicione `-Apply` somente para efetivar a exclusão. A simulação é o padrão.

## Execução com JSON

```powershell
$root = "$env:ProgramData\SharePointVersionCleanup"
& "$root\scripts\cleanup-versions.ps1" `
  -ConfigPath "$root\config\config.json" `
  -SiteUrl 'https://empresa.sharepoint.com'
```

A pasta configurada em `FolderScopes` é usada automaticamente. A tarefa agendada chama o mesmo script. O modo aplicado usa inventário persistente para evitar consultar histórico de arquivos sem alteração; não é um serviço residente nem elimina a enumeração de itens.

## Documentação

- [Guia rápido](QUICK_START.md): comando único, wizard, piloto e CLI.
- [Referência completa do JSON](CONFIGURATION.md): campos, tipos, exemplos, escopo e operação.
- [Detalhes da instalação](INSTALL_DETAILS.md): dependências, credenciais, atualização e rollback.
- [Diagnóstico](TROUBLESHOOTING.md): falhas e recuperação.
- [Testes](tests/README.md): suíte local sem operações no tenant.
- [Exemplo JSON](config/config.example.json) e [licença MIT](LICENSE).

Versões antigas são excluídas permanentemente. Arquivos com checkout ou sinais de conformidade são ignorados; outras políticas podem bloquear a operação. Relatórios indicam o que foi simulado, excluído, ignorado e o que falhou.

## Limites e auditoria diária

O padrão protege versões com menos de 30 dias e limita a 1000 exclusões por execução. Ajuste `Safety` no JSON ou `-MinimumVersionAgeDays` e `-MaxVersionsPerRun` na CLI direta. Para um piloto com versões criadas agora, escolha explicitamente idade mínima `0`.

```powershell
.\scripts\Get-DailyAudit.ps1 -ConfigPath 'C:\ProgramData\SharePointVersionCleanup\config\config.json' `
  -Date '2026-09-13' -OutputCsv 'C:\Relatorios\auditoria.csv'
```

A auditoria identifica diretório, arquivo, versão, regra aplicada e resultado de cada alteração. Falhas por arquivo/biblioteca permitem continuar os demais e retomar pendências. Consulte a [referência completa](CONFIGURATION.md) para interpretar os eventos e configurar cópia externa.

## Conferência por sorteio

O incremental inclui amostragem ponderada de arquivos inalterados: maiores e modificados recentemente têm mais chance, sem eliminar os pequenos ou antigos. O padrão confere um arquivo por biblioteca e guarda o ciclo para evitar repetições. Essa consulta é somente leitura; divergências ficam registradas para reavaliação na próxima execução. Configure `Sampling` no [JSON](CONFIGURATION.md#amostragem-ponderada-do-incremental), ou use `-SamplesPerLibrary` na CLI direta.
