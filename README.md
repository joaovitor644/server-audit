# Server Audit

Ferramenta em Bash para coleta periódica de informações sobre o estado de servidores Linux e geração automática de relatórios em **Markdown**.

O objetivo é fornecer uma visão consolidada do estado atual de cada servidor e permitir identificar **mudanças e possíveis problemas ao longo do tempo**, sem precisar comparar relatórios manualmente.

Servidores atendidos inicialmente: `kait` e `kara`.

🚧 **Status:** código das Fases 1 (MVP), 2 (histórico) e 3 (automação) escrito e testado em ambiente de teste. Falta validar em um servidor real, começando pelo `kait`.

---

## Sumário

- [Objetivos](#objetivos)
- [Como funciona](#como-funciona)
- [Instalação e uso](#instalação-e-uso)
- [Agendamento semanal (systemd)](#agendamento-semanal-systemd)
- [Estrutura do projeto](#estrutura-do-projeto)
- [Coletores](#coletores)
- [Estado e comparação histórica](#estado-e-comparação-histórica)
- [Relatórios](#relatórios)
- [Classificação de severidade](#classificação-de-severidade)
- [Permissões](#permissões)
- [Requisitos](#requisitos)
- [Como adicionar um coletor](#como-adicionar-um-coletor)
- [Princípios do projeto](#princípios-do-projeto)
- [Limitações conhecidas](#limitações-conhecidas)
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

Cada coletor emite **dados estruturados (JSON)**. O `audit.sh` junta a saída de todos em um único estado, compara com o estado da execução anterior e só então gera o Markdown. O estado novo é gravado por último, e só se o relatório foi gerado.

```text
┌───────────────────┐
│     audit.sh      │
└─────────┬─────────┘
          │ executa cada coletor (com tempo limite)
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
- se a ferramenta necessária não existir, **não falha**: emite `{"available": false, ...}` e sai com código `0`:
  - `"reason"` indica ausência esperada (`"não instalado"`, `"systemd não está em execução"`): a seção mostra o motivo, sem alarme;
  - `"error"` indica problema real (`"sem permissão para acessar o Docker"`): a seção aparece com 🟡 no resumo;
- se o coletor travar, sair com erro ou imprimir JSON inválido, o `audit.sh` registra o erro, marca o coletor em `failed_collectors` e segue com os demais.

---

## Instalação e uso

```bash
git clone <url-do-repositorio> server-audit
cd server-audit
chmod +x audit.sh collectors/*.sh

./audit.sh --dry-run       # imprime o relatório; não grava nada
./audit.sh                 # audita a máquina atual
```

Opções:

| Opção | O que faz |
|---|---|
| `--host NOME` | nome usado em `state/` e `reports/` (padrão: `hostname -s`) |
| `--only a,b` | executa só os coletores indicados (ex.: `--only storage,updates`) |
| `--dry-run` | imprime o relatório na saída padrão; não grava relatório, estado nem log |
| `--version` | mostra a versão |

Variável de ambiente: `COLLECTOR_TIMEOUT` (segundos por coletor, padrão `30`).

**Códigos de saída:**

| Código | Significado |
|---|---|
| `0` | relatório gerado, sem problemas na execução |
| `1` | erro fatal (relatório não gerado) |
| `2` | relatório gerado, mas algum coletor ou a comparação falhou |

**Comportamento:**

- **Mais de uma execução no mesmo dia:** a primeira gera `AAAA-MM-DD.md`; as seguintes ganham sufixo de hora (`AAAA-MM-DD_HHMM.md`). Nenhum relatório é sobrescrito.
- **Primeira execução:** sem estado anterior, o relatório indica "sem base de comparação" e apenas grava o estado inicial.
- **Execuções simultâneas** para o mesmo servidor são bloqueadas (`flock`).
- Arquivos gerados usam permissão `600` (`umask 077`).

> ⚠️ `reports/`, `state/` e `logs/` contêm IPs, portas, usuários, containers e regras de firewall. Estão no `.gitignore` e **não devem ser versionados**, principalmente se o repositório for público.

---

## Agendamento semanal (systemd)

Os arquivos estão em `systemd/`. O timer roda toda segunda-feira às 06:00, com atraso aleatório de até 15 minutos, e `Persistent=true` (se o servidor estava desligado, executa ao ligar).

```bash
# 1. usuário dedicado, sem login
sudo useradd --system --home-dir /opt/server-audit --shell /usr/sbin/nologin audit

# 2. instalar o projeto
sudo mkdir -p /opt/server-audit
sudo cp -r audit.sh collectors lib config systemd README.md /opt/server-audit/
sudo chown -R root:root /opt/server-audit
sudo chmod -R go+rX /opt/server-audit
sudo install -d -o audit -g audit -m 700 \
  /opt/server-audit/state /opt/server-audit/reports /opt/server-audit/logs

# 3. permissão para o firewall (veja "Permissões")
echo 'audit ALL=(root) NOPASSWD: /usr/sbin/ufw status verbose' \
  | sudo tee /etc/sudoers.d/server-audit
sudo chmod 440 /etc/sudoers.d/server-audit
sudo visudo -c -f /etc/sudoers.d/server-audit

# 4. teste manual, como o usuário de auditoria
sudo -u audit /opt/server-audit/audit.sh --dry-run

# 5. ativar o timer
sudo cp systemd/server-audit.service systemd/server-audit.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now server-audit.timer
```

Acompanhamento:

```bash
systemctl list-timers server-audit.timer     # próxima execução
sudo systemctl start server-audit.service    # executar agora
journalctl -u server-audit.service           # logs (também em logs/audit.log)
```

Se algum coletor falhar (código de saída `2`), o `systemd` marca a unidade como falha, e isso aparece em `systemctl --failed`.

Pontos de atenção na unidade:

- `NoNewPrivileges=false` é intencional: o coletor de segurança usa `sudo -n` para consultar o `ufw`. Com `true`, o `sudo` deixaria de funcionar.
- `SupplementaryGroups=systemd-journal` dá leitura do journal sem `sudo`.
- A linha do grupo `docker` está comentada de propósito (veja [Permissões](#permissões)).
- `ProtectSystem=full` e `ProtectHome=true` protegem `/usr`, `/etc` e `/home`; `state/`, `reports/` e `logs/` continuam graváveis.

---

## Estrutura do projeto

```text
server-audit/
├── audit.sh                # orquestrador
├── .gitignore              # ignora reports/, state/ e logs/
│
├── config/
│   ├── thresholds.conf     # limites de 🟡/🔴 e containers essenciais
│   └── services.conf       # serviços systemd monitorados
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
├── lib/
│   ├── compare.sh          # estado anterior × novo → Markdown das mudanças
│   └── render.sh           # estado → relatório Markdown, com severidade
│
├── systemd/
│   ├── server-audit.service
│   └── server-audit.timer
│
├── reports/                # histórico (não versionado)
│   └── kait/2026-10-13.md
├── state/                  # último estado de cada servidor (não versionado)
│   └── kait.json
└── logs/
    └── audit.log           # (não versionado)
```

Os coletores são **descobertos automaticamente** em `collectors/*.sh`: adicionar um arquivo novo não exige alterar o `audit.sh`.

---

## Coletores

| Coletor | O que coleta | Observações |
|---|---|---|
| `system.sh` | hostname, SO e versão, kernel, arquitetura, uptime, horário do boot, CPU (modelo, núcleos, carga), memória e swap | lê direto de `/proc`; memória "em uso" desconta o cache (`MemAvailable`) |
| `storage.sh` | filesystems, uso de disco e inodes, espaço disponível, montagem somente leitura, discos | ignora os filesystems `tmpfs`, `squashfs` e `overlay` e os discos `zram` |
| `network.sh` | interfaces e estado, endereços, rotas, gateway padrão, DNS, portas TCP/UDP em escuta | ignora `lo`, `veth*` e as bridges `br-<hash>` do Docker; usa `resolvectl` quando existe |
| `services.sh` | estado dos serviços de `config/services.conf` e lista de serviços em `failed` | padrão: `ssh`, `docker`, `nginx`, `cron`; linhas `!nome` no `services.conf` ignoram uma falha conhecida |
| `docker.sh` | containers (estado, imagem, reinícios, healthcheck), imagens, volumes, redes | Docker ausente: seção diz "não instalado" |
| `security.sh` | firewall (`ufw`), configuração do SSH, usuários com shell, administradores, tentativas de login SSH (7 dias), fail2ban, unattended-upgrades | veja [Permissões](#permissões) |
| `updates.sh` | pacotes com atualização pendente, quantos são de segurança, reinicialização pendente, idade do índice do apt | simula `apt-get dist-upgrade`; não instala nada |

O coletor de segurança **não faz alterações no sistema**: apenas coleta e reporta. O de atualizações **não instala nada** e não executa `apt-get update`.

Exemplo de seção gerada (armazenamento):

```markdown
## Armazenamento

| Filesystem | Uso | Inodes | Disponível | Situação |
|---|---:|---:|---:|---|
| `/` | 42% | 2% | 55 GB | 🟢 |
| `/mnt/storage` | 71% | 1% | 135 GB | 🟢 |
```

Exemplo (Docker):

```markdown
## Docker

| Container | Estado | Imagem |
|---|---|---|
| nginx | 🟢 Up (healthy) | nginx:1.27 |
| worker | 🟡 reiniciando | meu/worker |

Imagens: 5 (1 sem tag) · Volumes: 2 (0 órfãos) · Redes: 3
```

---

## Estado e comparação histórica

O estado é o JSON consolidado da última execução em `state/<host>.json`, com **uma chave por coletor**. Ele guarda listas e valores (não só contagens), o que permite detectar "novo container", "serviço que passou a falhar" ou "porta nova em escuta":

```json
{
  "schema": 1,
  "hostname": "kait",
  "collected_at": "2026-10-13T09:00:00-03:00",
  "failed_collectors": [],
  "system":   { "available": true, "kernel": "6.1.0-25-amd64", "memory": { "used_pct": 47 } },
  "storage":  { "available": true, "filesystems": [ { "mount": "/", "used_pct": 42 } ] },
  "network":  { "available": true, "listening": [ { "proto": "tcp", "port": 22, "scope": "all" } ] },
  "services": { "available": true, "monitored": [ { "name": "ssh", "active": "active" } ], "failed": [] },
  "docker":   { "available": false, "reason": "não instalado" },
  "security": { "available": true, "firewall": { "status": "active" } },
  "updates":  { "available": true, "pending": 12, "packages": ["libc6", "openssl"] }
}
```

O campo `schema` permite evoluir o formato sem quebrar a comparação com estados antigos.

**Regra da comparação:** uma seção só é comparada se o coletor estava disponível (`"available": true`) nas **duas** execuções. Assim, uma falha temporária ou uma ferramenta opcional ausente não gera "mudanças" falsas (como "todos os containers sumiram").

Exemplo de seção gerada:

```markdown
## Mudanças desde o relatório anterior

### Rede

- `tcp/5432`: somente local → todas as interfaces
- Nova porta em escuta: `tcp/8080` (todas as interfaces)

### Docker

- Containers: 7 → 8
- Novo container: `grafana`

### Serviços

- `example.service` passou para o estado `failed`.

### Atualizações

- Pacotes pendentes: 12 → 4
```

O que cada seção compara:

| Seção | Mudanças detectadas |
|---|---|
| Sistema | reinicialização (pelo horário do boot), kernel, SO, núcleos de CPU, memória total |
| Armazenamento | uso por filesystem, filesystem novo ou removido, passagem para somente leitura |
| Rede | interfaces, endereços, gateway, DNS, portas novas ou fechadas, mudança de escopo de uma porta |
| Serviços | mudança de estado, serviços que passaram a falhar ou se recuperaram |
| Docker | containers novos ou removidos, estado, imagem, contagens de imagens, volumes e redes |
| Segurança | estado e regras do firewall, opções do SSH, usuários com shell, administradores, UID 0, proteções |
| Atualizações | pacotes pendentes, pacotes de segurança, reinicialização pendente |

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
Cabeçalho (servidor, data, situação geral)
Resumo (problemas ordenados: 🔴 antes de 🟡)
  ├── Sistema
  ├── Armazenamento
  ├── Rede
  ├── Serviços
  ├── Docker
  ├── Segurança
  ├── Atualizações
  └── Mudanças desde o relatório anterior
```

Seções de coletores que não rodaram não aparecem. Seções indisponíveis mostram o motivo.

---

## Classificação de severidade

| Nível | Significado |
|---|---|
| 🟢 Normal | Dentro do esperado |
| 🟡 Atenção | Merece acompanhamento |
| 🔴 Crítico | Pode exigir intervenção imediata |

Regras atuais:

| Seção | 🟡 Atenção | 🔴 Crítico |
|---|---|---|
| Armazenamento | disco ou inodes acima do limite de atenção | disco ou inodes acima do limite crítico; filesystem somente leitura |
| Sistema | memória acima de `MEM_WARN_PCT` | — |
| Rede | — | sem rota padrão; interface da rota padrão em `down` |
| Serviços | serviço em transição; serviço fora da lista em `failed` | serviço monitorado em `failed`, ou parado embora habilitado |
| Docker | reiniciando, `unhealthy`, pausado, `dead`, ou encerrado com erro **há até `DOCKER_EXIT_WARN_DAYS` dias** | container de `DOCKER_ESSENTIAL` parado ou inexistente |
| Segurança | firewall inativo ou desconhecido; SSH com `PermitRootLogin yes` ou `PasswordAuthentication yes` (este desligável com `SSH_PASSWORD_AUTH_WARN=0`) | SSH com `PermitEmptyPasswords yes`; conta extra com UID 0 |
| Atualizações | pacotes pendentes; reinicialização pendente; índice do apt velho | — |
| Qualquer | coletor com falha; seção indisponível por `error` | — |

Serviço **não instalado**, **mascarado** ou **inativo e desabilitado** não gera alarme. Container parado há mais de `DOCKER_EXIT_WARN_DAYS` dias também não: o relatório só mostra "Exited (137) há 40d", sem 🟡. Falhas conhecidas de serviço podem ser silenciadas com `!nome` no `services.conf`.

Os limites ficam em `config/thresholds.conf`, fora do código:

```bash
DISK_WARN_PCT=80
DISK_CRIT_PCT=90
INODE_WARN_PCT=80
INODE_CRIT_PCT=90
MEM_WARN_PCT=85
UPDATES_WARN_COUNT=1
UPDATES_CACHE_WARN_DAYS=14
DOCKER_ESSENTIAL=""        # ex.: "nginx stirling-pdf"
DOCKER_EXIT_WARN_DAYS=7    # container parado com erro só alarma se parou há até N dias
SSH_PASSWORD_AUTH_WARN=1   # 0 = não marcar 🟡 por PasswordAuthentication yes
```

Esse arquivo é lido como script Bash (só atribuições). Os valores acima são os padrões; ajuste depois dos primeiros relatórios.

---

## Permissões

O projeto segue o princípio do **menor privilégio**: o processo roda como usuário comum (`audit`), e só alguns itens recebem acesso extra.

| Informação | Como é obtida |
|---|---|
| Sistema, armazenamento, rede, serviços, atualizações, usuários e SSH | usuário normal (arquivos e comandos de leitura pública) |
| Tentativas de login SSH (journal) | usuário no grupo `systemd-journal`, sem `sudo` |
| Estado do firewall (`ufw status verbose`) | `sudo` restrito a esse comando |
| Docker | usuário com acesso ao socket (grupo `docker`) |

Regra em `/etc/sudoers.d/server-audit` (editar sempre com `visudo -f`):

```text
audit ALL=(root) NOPASSWD: /usr/sbin/ufw status verbose
```

Liste **comandos completos e exatos**, sem curingas, e nunca conceda `sudo` geral ao usuário de auditoria.

> ⚠️ **Docker:** estar no grupo `docker` equivale a ter root na máquina, o que contraria o menor privilégio. Se não aceitar esse risco, deixe o usuário de fora: a seção Docker aparece como indisponível (🟡 no resumo, com o motivo).

Quando algo exige privilégio e não está liberado, o coletor registra a limitação no relatório em vez de falhar.

---

## Requisitos

Direcionado a sistemas **Debian/Ubuntu**.

**Obrigatórios:**

- Bash 5.0 ou superior;
- `jq` 1.6 ou superior;
- `flock` e `timeout` (util-linux e coreutils);
- coreutils e utilitários padrão (`df`, `awk`, `sed`, `grep`);
- `systemd` (`systemctl`, `journalctl`);
- `iproute2` com suporte a JSON (`ip -j`) e `ss`.

**Opcionais** (a ausência não impede o relatório):

- Docker;
- UFW;
- `resolvectl` (systemd-resolved);
- `apt-get` (sem ele, a seção de atualizações fica indisponível);
- `lsblk` (lista de discos);
- smartmontools (reservado para a Fase 4).

---

## Como adicionar um coletor

1. Crie `collectors/<nome>.sh` seguindo o [contrato](#contrato-de-um-coletor), com `chmod +x`. O `audit.sh` já o executa.
2. Em `lib/render.sh`, defina:
   - `_render_<nome> ARQUIVO_ESTADO`: imprime o corpo da seção em Markdown;
   - `_issues_<nome> ARQUIVO_ESTADO`: imprime uma linha por problema, no formato `<sev><TAB><mensagem>` (`1` = Atenção, `2` = Crítico);
   - e inclua o nome em `_SECTION_ORDER` e `_SECTION_TITLE`.
3. Em `lib/compare.sh`, defina `_compare_<nome> ANTERIOR NOVO` (uma linha `- ...` por mudança) e inclua o nome em `_COMPARE_SECTIONS` e `_COMPARE_TITLE`.

Sem os passos 2 e 3, o coletor roda e entra no estado, mas a seção aparece só com um aviso de "renderização não implementada".

---

## Princípios do projeto

1. **Somente leitura.** A auditoria apenas consulta informações; nunca modifica configurações do servidor.
2. **Modularidade.** Cada categoria tem seu coletor. Adicionar um novo não exige alterar os demais nem o `audit.sh`.
3. **Tolerância a falhas.** Um problema em um coletor não impede o relatório completo: o item aparece como "não instalado" ou "indisponível", em vez de abortar tudo.
4. **Histórico.** Relatórios anteriores são preservados para acompanhar a evolução do servidor.

---

## Limitações conhecidas

- **SSH:** a configuração é lida dos arquivos (`sshd_config` e `sshd_config.d/*.conf`), pois `sshd -T` exige root. É uma aproximação: blocos `Match` são ignorados e valem os padrões do OpenSSH quando a opção não aparece.
- **Firewall:** só o `ufw` é suportado. Quem usa `nftables` ou `iptables` direto aparece como "ufw não instalado".
- **Portas em escuta:** sem root, `ss` não informa qual processo é dono da porta.
- **Serviços privilegiados** (item previsto para a segurança) não foram implementados, pois exigem root.
- **Atualizações:** só `apt`. O índice não é atualizado pela ferramenta; se estiver velho, a contagem fica subestimada (o relatório avisa).
- **Container parado:** o Docker não diferencia "parou com `docker stop`" de "caiu" (ambos podem sair com 137). Por isso o alarme depende de **quando** o container parou; para o que não pode cair, use `DOCKER_ESSENTIAL`.
- **Mounts somente leitura legítimos** (por exemplo, uma ISO montada) são marcados como 🔴. Se isso gerar alarme falso, será preciso uma lista de exceções.

---

## Roadmap

### Fase 1 — MVP

- [x] Criar estrutura do projeto e `.gitignore`
- [x] Criar `audit.sh` (detecção do host, execução dos coletores, log)
- [x] Criar os 7 coletores: sistema, armazenamento, rede, serviços, Docker, segurança, atualizações
- [x] Gerar relatório Markdown (`lib/render.sh`)
- [x] Aplicar limites de `config/thresholds.conf` (🟢/🟡/🔴)
- [ ] Validar no `kait` e ajustar alarmes falsos

### Fase 2 — Histórico

- [x] Gravar estado em `state/<host>.json`
- [x] Criar `lib/compare.sh` e a seção de mudanças
- [x] Detectar mudanças de serviços, containers, armazenamento, rede, segurança e atualizações
- [ ] Validar a comparação com duas execuções reais em dias diferentes

### Fase 3 — Automação

- [x] Criar `server-audit.service` e `server-audit.timer` (execução semanal)
- [x] Registrar logs no `journald` (a saída de erro do `audit.sh` vai para o journal)
- [x] Tratar falhas de execução (código de saída `2` marca a unidade como falha)
- [ ] Ativar o timer no `kait` depois da validação

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