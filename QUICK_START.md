# Guia rápido

## Iniciar pelo GitHub

Em Windows PowerShell 5.1 ou PowerShell 7, **como Administrador**:

```powershell
iwr -useb https://raw.githubusercontent.com/JulioVicente/sharepoint-version-cleanup/v1.3.2/bootstrap.ps1 | iex
```

O comando acima é o instalador de uma linha. Ele baixa somente o lançador; o lançador verifica a versão fixada dos componentes e os hashes antes de iniciar o assistente.

Para baixar, inspecionar e simular o instalador primeiro:

```powershell
$bootstrap = Join-Path $env:TEMP 'spvc-bootstrap.ps1'
Invoke-WebRequest 'https://raw.githubusercontent.com/JulioVicente/sharepoint-version-cleanup/main/bootstrap.ps1' -OutFile $bootstrap
Get-Content $bootstrap
& $bootstrap -WhatIf
& $bootstrap
```

`-WhatIf` descreve a instalação sem baixar componentes, instalar pacotes, solicitar credenciais ou criar tarefas. Em um clone do projeto, execute `& .\bootstrap.ps1` para usar os arquivos locais.

## Responder ao wizard

Tenha a URL do site; o tenant será identificado automaticamente, com pergunta manual somente se a consulta falhar. Para uma biblioteca em `https://empresa.sharepoint.com/teste03/Forms/AllItems.aspx`, informe:

| Pergunta | Resposta |
|---|---|
| URL do site | `https://empresa.sharepoint.com` |
| Limitar a biblioteca/pasta | `S` |
| Caminho completo no servidor | `/teste03` |
| Versões históricas a manter | `2` no piloto, ou o valor aprovado pela operação |

O assistente faz login pelo Microsoft Graph e procura SharePoint Version Cleanup no Entra. Um aplicativo existente gera aviso e é reutilizado, sem digitar Client ID ou thumbprint. Certificados locais válidos associados são reaproveitados; na ausência deles, cria e associa um novo, preservando os anteriores. Só pergunta qual aplicativo usar se encontrar nomes duplicados. O login administrativo e os consentimentos continuam necessários.

O assistente oferece email pelo Graph, usando a conta autenticada como remetente e destinatário padrão, além de agendamento diário/semanal. A auditoria sugere C:\ProgramData\SharePointVersionCleanup\audit-copy; Enter aceita e - desabilita. Depois solicita a simulação, mostra o resumo e pede aprovação para aplicar o piloto. Somente depois do resultado aplicado com exclusões, sem arquivos ignorados, solicita ativar as tarefas em produção. Se não houver histórico excedente, crie versões em um arquivo descartável do piloto; não será possível comprovar exclusões usando apenas arquivos com uma versão.

A credencial do Agendador deve ser da mesma conta que possui o certificado. Informe a senha da conta, não o PIN do Windows Hello. O computador precisa permanecer ligado e conectado nos horários previstos; execuções perdidas iniciam quando possível.

## Executar sem configuração JSON

```powershell
.\scripts\cleanup-versions.ps1 -SiteUrl 'https://empresa.sharepoint.com' `
  -Directory '/teste03' -Tenant 'empresa.onmicrosoft.com' `
  -ClientId '11111111-1111-1111-1111-111111111111' `
  -CertificateThumbprint '0123456789ABCDEF0123456789ABCDEF01234567' `
  -VersionsToKeep 2 -OutputDirectory 'C:\SPCleanup'
```

Substitua os identificadores de exemplo. O modo direto exige escopo e certificado; não envia email nem cria tarefas. Rode em uma pasta local gravável; sem `-OutputDirectory`, logs e estado ficam em `.spvc`. Repita com `-Apply` para efetivar após revisar o relatório. `-PassThru` retorna o objeto de relatório para automação.

## Executar um piloto com JSON

```powershell
$root = "$env:ProgramData\SharePointVersionCleanup"
& "$root\scripts\Invoke-Pilot.ps1" -ConfigPath "$root\config\config.json" `
  -SiteUrl 'https://empresa.sharepoint.com' -FolderServerRelativeUrl '/teste03'
```

Depois de revisar os resultados:

```powershell
& "$root\scripts\Invoke-Pilot.ps1" -ConfigPath "$root\config\config.json" `
  -SiteUrl 'https://empresa.sharepoint.com' -FolderServerRelativeUrl '/teste03' `
  -Apply -Confirmation 'APLICAR NO SITE PILOTO'
```

Um piloto de pasta só autoriza promover tarefas daquele mesmo escopo:

```powershell
& "$root\scripts\Enable-Production.ps1" -ConfigPath "$root\config\config.json" `
  -PilotSiteUrl 'https://empresa.sharepoint.com' -PilotFolderServerRelativeUrl '/teste03' `
  -TaskName 'SharePoint Version Cleanup - 01' -Confirmation 'ATIVAR PRODUCAO' -WhatIf
```

Remova `-WhatIf` para promover após verificar. O script exige relatório aplicado recente, com exclusões e sem ignorados, e valida os argumentos da tarefa. Não promove automaticamente os demais sites.

## Ler os resultados

No resumo e no `report-*.json`:

- `VersionsEligible`: versões que atendem ao critério de retenção.
- `VersionsDeleted`: exclusões efetivas; zero na simulação.
- `BytesEligible` e `BytesFreed`: tamanhos elegíveis e removidos reportados pelo provedor.
- `FilesUnchanged`: arquivos reaproveitados pelo inventário incremental no modo aplicado.
- `FilesSkipped`, `Warnings`, `Error`: proteção, checkout ou falhas.

Consulte [CONFIGURATION.md](CONFIGURATION.md) antes de alterar escopo, retenção ou estado. Em falhas, veja [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

## Versões recentes e auditoria

Para versões recém-criadas no piloto, selecione idade mínima `0` no wizard ou configure `Safety.MinimumVersionAgeDays` no JSON. O padrão é 30 dias. Na CLI sem JSON, use `-MinimumVersionAgeDays 0`. `Safety.MaxVersionsPerRun` limita cada execução, inclusive as retomadas agendadas.

Consulte o dia com `scripts/Get-DailyAudit.ps1 -ConfigPath <arquivo> -Date AAAA-MM-DD -OutputCsv <destino.csv>`. A [referência JSON](CONFIGURATION.md) explica simulação, sucesso, falhas e pendências.

## Amostragem dos arquivos inalterados

O wizard oferece conferência por sorteio, priorizando arquivos maiores e recentes. O padrão é um arquivo por biblioteca; na CLI sem JSON, `-SamplesPerLibrary 3` amplia para três e `-SamplesPerLibrary 0` desativa. A amostra é somente leitura; a rotina normal de limpeza continua obedecendo `-Apply` e à retenção configurada. Veja os pesos e os eventos de auditoria em [Sampling](CONFIGURATION.md#amostragem-ponderada-do-incremental).

## URL de biblioteca/pasta informada como site

A partir da v1.3.1, depois do login e antes de alterar o aplicativo/certificado, o assistente verifica se a URL representa um site. Se o Graph retornar 404, consulta os caminhos pais até encontrar um site válido e mantém o caminho original como escopo obrigatório de biblioteca/pasta. Por exemplo, `https://empresa.sharepoint.com/teste03` pode ser convertido em site `https://empresa.sharepoint.com` com pasta `/teste03`. Um site real chamado `/teste03` é preservado como site.

O assistente não remove a restrição de pasta nem assume o site raiz em erros 403 ou de rede. Se a validação não puder ser concluída, permite corrigir a URL no mesmo host sem recriar o aplicativo. Não são aceitos escopos diferentes do mesmo site na mesma instalação. Depois de descobrir o site pai, o assistente consulta a biblioteca/pasta no Graph e rejeita caminhos inexistentes ou arquivos. Revise os resultados da simulação antes de aprovar exclusões.

Os campos são validados assim que os dados necessários ficam disponíveis. Site e biblioteca/pasta são consultados depois do login e antes de alterar o aplicativo; a pasta de auditoria é criada quando necessário e testada com um arquivo temporário removido em seguida. O email é testado assim que aplicativo, certificado e destinatários estão definidos (exceto com -SkipEmailTest), antes das perguntas de retenção e agendamento. Sintaxe, limites, destinatários e horário são validados no próprio campo. A aceitação do email pelo Graph não comprova entrega nem existência de caixas externas.
