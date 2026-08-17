# SharePoint Version Cleanup

Automação em PowerShell para analisar e remover versões antigas de arquivos no SharePoint Online. Usa autenticação por aplicativo e certificado, checkpoints, logs e relatórios por e-mail.

> **Estado:** implementação funcional em validação. Faça primeiro um piloto, simule e revise o relatório antes de habilitar exclusões ou tarefas em produção.

## Recursos

- Instalação interativa no Windows e tarefas semanais
- Simulação sem exclusão por padrão no script de limpeza
- Retenção configurável das versões mais recentes
- Checkpoint e lock por site; arquivos em checkout são ignorados
- Logs, relatório JSON e e-mail HTML opcional

## Requisitos

- Windows 10/11 ou Windows Server
- PowerShell 7.4+ (`pwsh`) e privilégios de administrador local
- PnP.PowerShell 3.0+ (o instalador pode instalá-lo)
- Autorização para registrar/aprovar aplicativo no Microsoft Entra ID, ou aplicativo existente com certificado
- Conectividade com Microsoft 365 e, opcionalmente, SMTP

## Início seguro

Baixe, inspecione e execute em uma sessão elevada do PowerShell 7:

```powershell
Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/JulioVicente/sharepoint-version-cleanup/main/Install.ps1' -OutFile "$env:TEMP\Install-SharePointVersionCleanup.ps1"
Get-Content "$env:TEMP\Install-SharePointVersionCleanup.ps1"
& "$env:TEMP\Install-SharePointVersionCleanup.ps1" -WhatIf
& "$env:TEMP\Install-SharePointVersionCleanup.ps1"
```

Consulte o [guia rápido](QUICK_START.md) e os [detalhes da instalação](INSTALL_DETAILS.md).

## Simulação manual

```powershell
$root = "$env:ProgramData\SharePointVersionCleanup"
& "$root\scripts\cleanup-versions.ps1" -ConfigPath "$root\config\config.json" -SiteUrl 'https://contoso.sharepoint.com/sites/Piloto'
```

Depois de conferir os logs, repita com `-Apply` apenas no piloto. As tarefas instaladas começam em simulação; use `scripts/Enable-Production.ps1` somente após validar o piloto aplicado.

## Segurança e limitações

- Não versione `config.json`, certificados, logs ou checkpoints.
- A senha SMTP usa DPAPI e só funciona para o mesmo usuário no mesmo computador; SMTP autenticado pode estar desabilitado.
- O registro solicita `Sites.Selected` e concede `Write` somente aos sites informados. Revise periodicamente essas concessões.
- Checkout é detectado; presença ativa de usuários, retenção e rótulos de conformidade não são avaliados previamente. O SharePoint pode bloquear exclusões.
- Versões excluídas não devem ser tratadas como recuperáveis. Garanta retenção, backup e aprovação operacional.

## Estrutura e documentação

- [QUICK_START.md](QUICK_START.md): instalação e piloto
- [INSTALL_DETAILS.md](INSTALL_DETAILS.md): arquitetura, configuração e operação
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md): diagnóstico
- [config/config.example.json](config/config.example.json): exemplo sem segredos
- `Install.ps1`, `scripts/cleanup-versions.ps1`, `scripts/Send-EmailReport.ps1`
- `templates/email-template.html`
- [LICENSE](LICENSE): licença MIT

**Versão:** 1.0.0 (pré-produção)
**Última atualização:** agosto de 2026
