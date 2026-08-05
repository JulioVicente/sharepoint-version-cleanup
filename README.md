# SharePoint Version Cleanup 🧹

Solução automática e simples para limpeza de versionamento no SharePoint 365. Execute uma vez, configure com defaults, e pronto - tudo agendado!

## ✨ Características

✅ **Instalação One-Liner** - Uma linha de comando PowerShell  
✅ **Configuração Interativa** - Perguntas com defaults inteligentes  
✅ **Validação Automática** - Verifica e atualiza componentes necessários  
✅ **Email de Teste** - Valida configurações antes de começar  
✅ **Agendamento Local** - Windows Task Scheduler nativo  
✅ **Sem Dependências de Nuvem** - Apenas SharePoint 365  
✅ **Checkpoint Automático** - Retoma de onde parou se falhar  
✅ **Emails Automáticos** - Sucesso (verde) e Erro (vermelho)  
✅ **Logs Detalhados** - Rastreamento completo de execução  

## 🚀 Quick Start

### Um comando, tudo pronto:

```powershell
iwr -useb https://raw.githubusercontent.com/JulioVicente/sharepoint-version-cleanup/main/Install.ps1 | iex
```

Isso vai:
1. Validar e atualizar componentes PowerShell
2. Fazer perguntas com defaults (apenas aperte Enter)
3. Criar App no Azure AD
4. Agendar no Windows Task Scheduler
5. Enviar email de teste validando tudo
6. Você recebe email com próximos passos

## 📋 Requisitos

- Windows 10+ ou Windows Server 2016+
- PowerShell 5.0+
- Admin local da máquina
- Credenciais admin do Microsoft 365
- Conexão com internet

## 🔧 Como Funciona

```
┌─ Windows Task Scheduler (agendamento local)
│
├─ Segunda 10:00 → cleanup-versions.ps1 /sites/Sales
├─ Terça 10:00 → cleanup-versions.ps1 /sites/Marketing
├─ Quarta 10:00 → cleanup-versions.ps1 /sites/HR
├─ Quinta 10:00 → cleanup-versions.ps1 /sites/Finance
├─ Sexta 10:00 → cleanup-versions.ps1 /sites/Operations
│
└─ Cada execução:
   ✓ Conecta ao SharePoint 365
   ✓ Limpa versões antigas
   ✓ Detecta arquivos em uso
   ✓ Salva progresso (checkpoint)
   ✓ Envia email com resumo
```

## 📁 Estrutura do Projeto

```
sharepoint-version-cleanup/
├── README.md                   # Este arquivo
├── QUICK_START.md             # Guia rápido
├── INSTALL_DETAILS.md         # Detalhes de instalação
├── TROUBLESHOOTING.md         # Problemas comuns
├── Install.ps1                # Instalação interativa (main)
├── config/
│   ├── config.json            # Configuração (gerado)
│   └── config.example.json    # Exemplo
├── scripts/
│   ├── cleanup-versions.ps1   # Script principal
│   └── Send-EmailReport.ps1   # Funções de email
├── state/
│   └── checkpoint.json        # Progresso (gerado)
├── logs/                      # Logs (gerado)
├── templates/
│   └── email-template.html    # Templates de email
├── .gitignore
└── LICENSE
```

## 📧 Emails Automáticos

### Email de Sucesso ✅
- Total de versões deletadas
- Espaço liberado (GB)
- Arquivos processados
- Avisos (em uso, sem permissão)
- Próxima execução agendada

### Email de Erro ❌
- Erro destacado em vermelho
- O que foi feito antes do erro
- Avisos importantes
- Ação recomendada
- Log anexado

## 🔐 Segurança

- Credenciais criptografadas
- App Registration com permissões mínimas
- Lock file contra execução simultânea
- Validação de permissões antes de deletar
- Detecção de usuários ativos
- Logs completos para auditoria

## 📚 Documentação

- **[QUICK_START.md](QUICK_START.md)** - Comece em 5 minutos
- **[INSTALL_DETAILS.md](INSTALL_DETAILS.md)** - Detalhes técnicos
- **[TROUBLESHOOTING.md](TROUBLESHOOTING.md)** - Resolvendo problemas

## 🎯 Próximos Passos

1. Execute o installer:
   ```powershell
   iwr -useb https://raw.githubusercontent.com/JulioVicente/sharepoint-version-cleanup/main/Install.ps1 | iex
   ```

2. Responda as perguntas (use defaults apertando Enter)

3. Receba email de teste validando tudo

4. Pronto! Task Scheduler já está agendado

## 📞 Suporte

Consultando [TROUBLESHOOTING.md](TROUBLESHOOTING.md) para:
- Problemas comuns
- Como visualizar logs
- Restaurar configurações

## 📄 License

MIT License - veja [LICENSE](LICENSE) para detalhes

---

**Versão:** 1.0.0  
**Última atualização:** Agosto 2024  
**Status:** ✅ Pronto para produção
