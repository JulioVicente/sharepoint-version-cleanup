# Guia rápido

Use um site SharePoint de teste com arquivos descartáveis e várias versões. Abra o PowerShell 7.4+ como administrador e confirme `$PSVersionTable.PSVersion`.

## Instalar

Na raiz do projeto:

```powershell
pwsh -NoProfile -File .\Install.ps1 -WhatIf
pwsh -NoProfile -File .\Install.ps1
```

Para informar Client ID e certificado existentes, use `-SkipAppRegistration`. O destino padrão é `%ProgramData%\SharePointVersionCleanup`.

O instalador solicitará tenant, URL administrativa, sites, número de versões a manter e SMTP opcional.

## Conferir antes do piloto

1. Revise as permissões e o consentimento do aplicativo.
2. Valide URLs e `VersionsToKeep` em `config\config.json`.
3. Confirme no Agendador que as tarefas `SharePoint Version Cleanup` estão em simulação, sem `-Apply`.
4. Não compartilhe configuração, certificados, logs ou checkpoints.

## Simular e aplicar

```powershell
$root = "$env:ProgramData\SharePointVersionCleanup"
& "$root\scripts\cleanup-versions.ps1" -ConfigPath "$root\config\config.json" -SiteUrl 'https://contoso.sharepoint.com/sites/Piloto'
```

Confira `report-*.json` e o log em `$root\logs`. Na simulação, `VersionsDeleted` indica o que seria removido. Após revisar:

```powershell
& "$root\scripts\cleanup-versions.ps1" -ConfigPath "$root\config\config.json" -SiteUrl 'https://contoso.sharepoint.com/sites/Piloto' -Apply
```

Valide o resultado no SharePoint e só então habilite tarefas gradualmente. Em caso de falha, consulte [TROUBLESHOOTING.md](TROUBLESHOOTING.md).
