# Detalhes da instalação

## Parâmetros

Use `Get-Help .\Install.ps1 -Detailed`.

- `-InstallPath`: destino; padrão `%ProgramData%\SharePointVersionCleanup`.
- `-SkipAppRegistration`: solicita Client ID e thumbprint existentes.
- `-SkipEmailTest`: não envia a validação SMTP.
- `-WhatIf`: mostra operações compatíveis com `ShouldProcess`; revise todas as interações exibidas.

O instalador exige Windows, administrador e PowerShell 7.4+. Ele valida o PnP.PowerShell, copia arquivos, coleta a configuração, registra ou referencia o aplicativo e cria tarefas semanais.

## Configuração

O arquivo gerado é `config\config.json`; veja [config/config.example.json](config/config.example.json). `Tenant`, `Sites`, `VersionsToKeep`, `Authentication` e `Paths` são consumidos pela limpeza. `Email` é opcional. A senha SMTP criada pelo instalador usa DPAPI: não pode ser copiada entre usuários ou computadores.

## Autenticação e permissões

O registro solicita `Sites.Selected` e o instalador concede `Write` apenas aos sites configurados. Use aplicativo dedicado, revise as concessões, controle o acesso à chave privada e monitore a validade do certificado.

## Fluxo da limpeza

O script obtém lock por site, conecta por certificado, enumera bibliotecas e arquivos, ignora checkout, preserva `VersionsToKeep`, e só exclui com `-Apply`. Ele grava checkpoint, log e JSON e envia e-mail quando habilitado. Retenção, legal hold, rótulos e permissões podem bloquear operações.

## Tarefas agendadas

O instalador distribui sites entre segunda e sexta às 10:00 e cria as tarefas sem `-Apply`. Faça o piloto manual e use `scripts/Enable-Production.ps1` para promovê-las após um piloto aplicado recente. Confira identidade, certificado, `pwsh.exe`, argumentos, caminhos graváveis, janela operacional e alertas.

## Desinstalação

Desabilite e remova somente tarefas com prefixo `SharePoint Version Cleanup`, preserve evidências necessárias e depois remova o diretório instalado. Aplicativo Entra, consentimentos e certificado são removidos separadamente, após confirmar que não têm outros consumidores.
