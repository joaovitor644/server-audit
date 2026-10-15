# Server Audit

Ferramenta em Bash para coleta periódica de informações sobre o estado de servidores Linux e geração automática de relatórios em **Markdown**.

O objetivo é fornecer uma visão consolidada do estado atual de cada servidor e permitir identificar **mudanças e possíveis problemas ao longo do tempo**, sem precisar comparar relatórios manualmente.

Servidores atendidos inicialmente: `kait` e `kara`.

🚧 **Status:** em desenvolvimento (definição da arquitetura e implementação do MVP). A primeira versão será validada no `kait` antes de ser usada nos demais servidores.

---

## Sumário

- [Objetivos](#objetivos)
- [Como funciona](#como-funciona)
- [Instalação e uso](#instalação-e-uso)
- [Estrutura do projeto](#estrutura-do-projeto)
- [Coletores](#coletores)
- [Estado e comparação histórica](#estado-e-comparação-histórica)
- [Relatórios](#relatórios)
- [Classificação de severidade](#classificação-de-severidade)
- [Permissões](#permissões)
- [Requisitos](#requisitos)
- [Princípios do projeto](#princípios-do-projeto)
- [Roadmap](#roadmap)

---

## Objetivos

- coletar informações do servidor de forma automatizada;
- gerar relatórios em Markdown e manter o histórico;
- comparar o estado atual com o da execução anterior;
- destacar mudanças relevantes e problemas que precisam de atenção;
- permitir execução manual ou agendada;
- manter os coletores independentes e fáceis de expandir.

---

## Como funciona

Cada coletor emite **dados estruturados (JSON)**. O `audit.sh` junta a saída de todos em um único estado, compara com o estado da execução anterior e só então gera o Markdown. O estado novo é gravado ao final.

```text
┌───────────────────┐
│     audit.sh      │
└─────────┬─────────┘
          │ executa cada coletor
          ▼
┌───────────────────┐
│    collectors/    │  system · storage · network · services
│   (saída JSON)    │  docker · security · updates
└─────────┬─────────┘
          │ junta tudo
          ▼
┌───────────────────┐        ┌────────────────────────┐
│   estado novo     │◄──────►│ state/<host>.json      │
│                   │ compara│ (estado anterior)      │
└─────────┬─────────┘        └────────────────────────┘
          │ severidade + mudanças
          ▼
┌───────────────────┐
│ reports/<host>/   │
│ AAAA-MM-DD.md     │
└─────────┬─────────┘
          │ por último
          ▼
  grava o estado novo em state/<host>.json
```

**Por que JSON e não Markdown direto nos coletores?** Comparar valores lendo Markdown de relatórios antigos é frágil. Com dados estruturados, a comparação é uma operação simples (`jq`) e a formatação do relatório fica separada da coleta.

### Contrato de um coletor

- é um script Bash executável em `collectors/<nome>.sh`;
- imprime **um objeto JSON** na saída padrão;
- nunca altera o sistema;
- se a ferramenta necessária não existir, **não falha**: emite `{"available": false}`;
- termina com código `0`, exceto em erro inesperado (o `audit.sh` registra e segue com os demais).

Exemplo de saída do coletor de armazenamento:

```json
{
  "available": true,
  "filesystems": [
    { "mount": "/", "used_pct": 42, "avail_gb": 55 },
    { "mount": "/mnt/storage", "used_pct": 71, "avail_gb": 135 }
  ]
}
```

---

## Instalação e uso

```bash
git clone <url-do-repositorio> server-audit
cd server-audit
chmod +x audit.sh collectors/*.sh

./audit.sh                 # audita a máquina atual
./audit.sh --host kait     # força o nome usado em state/ e reports/
```

- **Nome do servidor:** por padrão vem de `hostname -s`; `--host` sobrescreve.
- **Saídas:** relatório em `reports/<host>/`, estado em `state/<host>.json`, log em `logs/audit.log`.
- **Mais de uma execução no mesmo dia:** o primeiro relatório do dia é `AAAA-MM-DD.md`; as seguintes ganham sufixo de hora (`AAAA-MM-DD_HHMM.md`). Nenhum relatório é sobrescrito.
- **Primeira execução:** sem estado anterior, o relatório indica "sem base de comparação" e apenas grava o estado inicial.

> ⚠️ `reports/`, `state/` e `logs/` contêm IPs, portas, usuários e containers dos servidores. Estão no `.gitignore` e **não devem ser versionados** (principalmente se o repositório for público).

---

## Estrutura do projeto

```text
server-audit/
├── audit.sh                # orquestrador
├── .gitignore              # ignora reports/, state/ e logs/
│
├── config/
│   └── thresholds.conf     # limites de 🟡 Atenção e 🔴 Crítico
│
├── collectors/             # um script por categoria (saída JSON)
│   ├── system.sh
│   ├── storage.sh
│   ├── network.sh
│   ├── services.sh
│   ├── docker.sh
│   ├── security.sh
│   └── updates.sh
│
├── lib/                    # funções compartilhadas
│   ├── common.sh           # log, checagem de dependências, helpers
│   ├── compare.sh          # diferença entre estado anterior e atual
│   └── render.sh           # JSON → relatório Markdown
│
├── reports/                # histórico (não versionado)
│   ├── kait/
│   │   ├── 2026-10-13.md
│   │   └── ...
│   └── kara/
│
├── state/                  # último estado de cada servidor (não versionado)
│   ├── kait.json
│   └── kara.json
│
└── logs/
    └── audit.log           # (não versionado)
```

---

## Coletores

Cada coletor cuida de uma categoria. A tabela separa o que entra no **MVP** do que fica para depois.

| Coletor | MVP | Futuro |
|---|---|---|
| `system.sh` | hostname, distribuição e versão, kernel, uptime, CPU, RAM, swap, arquitetura | — |
| `storage.sh` | filesystems, uso de disco e inodes, espaço disponível, pontos de montagem (incluindo detecção de montagem somente leitura) | dados SMART |
| `network.sh` | interfaces e estado, endereços IP, rotas, gateway, DNS, portas TCP/UDP em escuta | WireGuard |
| `services.sh` | estado dos principais serviços `systemd` e lista de serviços em `failed` | serviços específicos por servidor |
| `docker.sh` | containers e estado, imagens, containers reiniciando ou com problema | volumes, redes |
| `security.sh` | firewall, configuração relevante do SSH, usuários com shell, tentativas recentes de autenticação | serviços privilegiados, mais indicadores |
| `updates.sh` | quantidade e lista de pacotes atualizáveis | certificados, backups |

O coletor de segurança **não faz alterações no sistema**: apenas coleta e reporta. Da mesma forma, o de atualizações **não instala nada**.

Exemplo de seção gerada (armazenamento):

```markdown
## Armazenamento

| Filesystem | Uso | Disponível | Situação |
|---|---:|---:|---|
| `/` | 42% | 55 GB | 🟢 |
| `/mnt/storage` | 71% | 135 GB | 🟢 |
```

Exemplo (Docker):

```markdown
## Docker

| Container | Estado | Imagem | Situação |
|---|---|---|---|
| stirling-pdf | Up | stirlingtools/stirling-pdf | 🟢 |
| nginx | Up | nginx | 🟢 |
```

Quando uma dependência opcional não está presente, a seção aparece assim:

```markdown
## Docker

Não instalado.
```

---

## Estado e comparação histórica

O estado é o JSON consolidado da última execução em `state/<host>.json`. Para a comparação detectar o que o relatório promete (novo container, serviço que falhou, queda de pacotes pendentes), o estado guarda **listas e valores**, não apenas contagens:

```json
{
  "schema": 1,
  "hostname": "kait",
  "collected_at": "2026-10-13T09:00:00-03:00",
  "storage": {
    "filesystems": [
      { "mount": "/", "used_pct": 42 },
      { "mount": "/mnt/storage", "used_pct": 71 }
    ]
  },
  "memory": { "used_mb": 1840 },
  "docker": {
    "containers": ["stirling-pdf", "nginx", "grafana"]
  },
  "services": {
    "failed": []
  },
  "updates": {
    "pending": 12
  }
}
```

O campo `schema` permite evoluir o formato sem quebrar a comparação com estados antigos.

Exemplo de seção gerada no relatório:

```markdown
## Mudanças desde o relatório anterior

### Armazenamento

- `/`: 42% → 47%
- `/mnt/storage`: 68% → 71%

### Docker

- Containers: 7 → 8
- Novo container: `grafana`

### Serviços

- `example.service` passou para o estado `failed`.

### Atualizações

- Pacotes pendentes: 12 → 4
```

---

## Relatórios

Um relatório por execução, em `reports/<host>/AAAA-MM-DD.md`, preservando o histórico:

```text
2026-10-13.md
2026-10-20.md
2026-10-27.md
...
```

Estrutura:

```text
Resumo (severidade geral + itens que precisam de atenção)
  ├── Sistema
  ├── Armazenamento
  ├── Rede
  ├── Serviços
  ├── Docker
  ├── Segurança
  ├── Atualizações
  └── Mudanças desde o relatório anterior
```

---

## Classificação de severidade

| Nível | Significado | Exemplos |
|---|---|---|
| 🟢 Normal | Dentro do esperado | — |
| 🟡 Atenção | Merece acompanhamento | disco acima do limite, atualizações pendentes, memória elevada, container reiniciando, certificado perto de vencer |
| 🔴 Crítico | Pode exigir intervenção imediata | filesystem quase cheio ou somente leitura, serviço crítico parado, container essencial indisponível, interface principal fora do ar |

Os limites ficam em `config/thresholds.conf`, fora do código. Valores iniciais sugeridos (ajustáveis após os primeiros relatórios):

```bash
# config/thresholds.conf
DISK_WARN_PCT=80
DISK_CRIT_PCT=90
INODE_WARN_PCT=80
INODE_CRIT_PCT=90
MEM_WARN_PCT=85
UPDATES_WARN_COUNT=1
```

No MVP, a classificação já é aplicada com esses limites simples; a Fase 2 a refina com a comparação histórica (por exemplo, crescimento rápido de uso de disco).

---

## Permissões

O projeto segue o princípio do **menor privilégio**: o processo roda como usuário comum, e só alguns comandos específicos recebem privilégio extra.

| Informação | Como é obtida |
|---|---|
| Informações públicas do sistema (`df`, `free`, `ss`, `systemctl`, `lsblk`…) | usuário normal |
| Logs do journal (`journalctl`, tentativas de autenticação) | usuário no grupo `systemd-journal`, sem `sudo` |
| Estado do firewall (`ufw status`) | `sudo` restrito a esse comando |
| SMART (`smartctl`) | `sudo` restrito a esse comando |

Exemplo de regra em `/etc/sudoers.d/server-audit` (editar sempre com `visudo -f`):

```text
audit ALL=(root) NOPASSWD: /usr/sbin/ufw status verbose
```

Liste **comandos completos e exatos**, sem curingas, e nunca conceda `sudo` geral ao usuário de auditoria. Se um comando exigir privilégio e ele não estiver disponível, o coletor registra a limitação no relatório em vez de falhar.

---

## Requisitos

Direcionado inicialmente a sistemas **Debian/Ubuntu**.

**Obrigatórios:**

- Bash 5.0 ou superior;
- `jq`;
- `systemd` (`systemctl`, `journalctl`);
- coreutils e utilitários padrão (`df`, `free`, `lsblk`);
- `iproute2` (`ip`, `ss`).

**Opcionais** (a ausência não impede o relatório):

- Docker;
- UFW;
- WireGuard;
- smartmontools.

---

## Princípios do projeto

1. **Somente leitura.** A auditoria apenas consulta informações; nunca modifica configurações do servidor.
2. **Modularidade.** Cada categoria tem seu coletor. Adicionar um novo (por exemplo, `proxmox.sh`) não exige alterar os demais.
3. **Tolerância a falhas.** Um problema em um coletor não impede o relatório completo: o item aparece como "não instalado" ou "indisponível", em vez de abortar tudo.
4. **Histórico.** Relatórios anteriores são preservados para acompanhar a evolução do servidor.

---

## Roadmap

### Fase 1 — MVP

- [ ] Criar estrutura do projeto e `.gitignore`
- [ ] Criar `audit.sh` (detecção do host, execução dos coletores, log)
- [ ] Criar `lib/common.sh`
- [ ] Criar os coletores: sistema, armazenamento, rede, serviços, Docker, segurança, atualizações
- [ ] Criar `lib/render.sh` e gerar o primeiro relatório Markdown
- [ ] Aplicar limites de `config/thresholds.conf` (🟢/🟡/🔴)

### Fase 2 — Histórico

- [ ] Gravar estado em `state/<host>.json`
- [ ] Criar `lib/compare.sh` e a seção de mudanças
- [ ] Detectar novos serviços, novos containers e alterações de armazenamento
- [ ] Refinar severidade com base no histórico

### Fase 3 — Automação

- [ ] Criar `server-audit.service` e `server-audit.timer` (execução semanal)
- [ ] Registrar logs no `journald`
- [ ] Tratar falhas de execução

```text
┌─────────────────────┐
│ systemd timer       │
│ (semanal)           │
└──────────┬──────────┘
           ▼
┌─────────────────────┐
│ server-audit.service│
└──────────┬──────────┘
           ▼
┌─────────────────────┐
│ audit.sh            │
└──────────┬──────────┘
           ▼
       relatório
```

### Fase 4 — Expansão

- [ ] Monitoramento de certificados
- [ ] Monitoramento de WireGuard
- [ ] Monitoramento de backups
- [ ] Monitoramento de SMART
- [ ] Monitoramento de serviços específicos
- [ ] Indicadores adicionais de segurança

### Fase 5 — Centralização

Reunir os relatórios de vários servidores em um só lugar, com possível integração futura ao **Kait Control**.

```text
       ┌──────────────────────────┐
       │  Relatórios centralizados │
       └────────────┬─────────────┘
          ┌─────────┴─────────┐
       ┌──▼───┐            ┌──▼───┐
       │ kait │            │ kara │
       └──────┘            └──────┘
```