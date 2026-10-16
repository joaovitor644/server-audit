#!/usr/bin/env bash
#
# collectors/security.sh — acompanhamento básico da postura de segurança.
#
# Contrato dos coletores:
#   - emite UM objeto JSON na saída padrão
#   - SOMENTE LEITURA: nunca altera configuração, regra ou serviço
#   - jq ausente => {"available": false, "error": "..."} e saída 0
#   - o que exigir privilégio e não estiver liberado vira "unknown" ou
#     "available": false naquela parte, sem derrubar o coletor
#
# O que é coletado e com qual privilégio:
#   firewall  ufw status verbose → precisa de root. Usa `sudo -n` com o comando
#             EXATO liberado em /etc/sudoers.d (veja o README); sem isso, o
#             estado fica "unknown".
#   ssh       lê /etc/ssh/sshd_config e sshd_config.d/*.conf (legíveis por
#             todos). É uma aproximação do `sshd -T`: ignora blocos `Match` e
#             aplica os padrões do OpenSSH quando a opção não aparece.
#   usuários  /etc/passwd e /etc/group (legíveis por todos).
#   auth      journal do sshd nos últimos 7 dias → precisa estar no grupo
#             systemd-journal (ou adm), sem sudo.
#
# As portas em escuta ficam no coletor de rede, para não duplicar dados.
#
# Saída:
#   {
#     "available": true,
#     "firewall": { "tool": "ufw", "status": "active", "default_incoming": "deny",
#                   "rules": ["22/tcp ALLOW IN Anywhere"] },
#     "ssh": { "present": true, "port": [22], "permit_root_login": "prohibit-password",
#              "password_authentication": "no", "pubkey_authentication": "yes",
#              "permit_empty_passwords": "no", "x11_forwarding": "no" },
#     "users": { "with_shell": [ {"name": "root", "uid": 0, "shell": "/bin/bash"} ],
#                "uid0_extra": [], "admins": ["vitor"] },
#     "auth": { "available": true, "window_days": 7, "failed": 12,
#               "unique_sources": 4, "accepted": 3 },
#     "protections": { "fail2ban": "active", "unattended_upgrades": true }
#   }
#   firewall.status: active | inactive | unknown | not-installed
#
# Variáveis AUDIT_SSHD_CONFIG, AUDIT_SSHD_CONFIG_DIR, AUDIT_PASSWD_FILE e
# AUDIT_GROUP_FILE existem só para testes; no uso normal não precisam de valor.

set -uo pipefail
export LC_ALL=C

unavailable() {
  printf '{"available": false, "error": "%s"}\n' "$1"
  exit 0
}

command -v jq >/dev/null 2>&1 || unavailable "jq não encontrado"

SSHD_CONFIG="${AUDIT_SSHD_CONFIG:-/etc/ssh/sshd_config}"
SSHD_CONFIG_DIR="${AUDIT_SSHD_CONFIG_DIR:-/etc/ssh/sshd_config.d}"
PASSWD_FILE="${AUDIT_PASSWD_FILE:-/etc/passwd}"
GROUP_FILE="${AUDIT_GROUP_FILE:-/etc/group}"

# ---------------------------------------------------------------------------
# Firewall (ufw)
# ---------------------------------------------------------------------------

fw_tool="none"
fw_status="not-installed"
fw_default=""
fw_rules=""

if [[ -x /usr/sbin/ufw ]] || command -v ufw >/dev/null 2>&1; then
  fw_tool="ufw"
  fw_status="unknown"
  ufw_out=""
  if (( EUID == 0 )); then
    ufw_out="$(/usr/sbin/ufw status verbose 2>/dev/null || ufw status verbose 2>/dev/null)"
  elif command -v sudo >/dev/null 2>&1; then
    ufw_out="$(sudo -n /usr/sbin/ufw status verbose 2>/dev/null)"
  fi

  if [[ -n $ufw_out ]]; then
    st="$(awk '/^Status:/ { print tolower($2); exit }' <<<"$ufw_out")"
    [[ $st == active || $st == inactive ]] && fw_status="$st"
    fw_default="$(grep -oE '^Default: [a-z]+ \(incoming\)' <<<"$ufw_out" | awk '{ print $2 }')"
    # regras: linhas depois da linha "--" do cabeçalho, com espaços normalizados
    fw_rules="$(awk '/^--/ { f = 1; next } f && NF { gsub(/[ \t]+/, " "); print }' <<<"$ufw_out")"
  fi
fi

# ---------------------------------------------------------------------------
# SSH (leitura da configuração)
# ---------------------------------------------------------------------------

ssh_present=false
ssh_tsv=""

if [[ -r $SSHD_CONFIG ]]; then
  ssh_present=true
  files=()
  shopt -s nullglob
  for f in "$SSHD_CONFIG_DIR"/*.conf; do files+=("$f"); done   # ordem lexical
  shopt -u nullglob
  files+=("$SSHD_CONFIG")

  # No sshd vale a PRIMEIRA ocorrência de cada opção (o .d é lido antes);
  # `Port` é cumulativo. Linhas depois de `Match` valem só condicionalmente.
  ssh_tsv="$(awk '
    FNR == 1 { inmatch = 0 }
    { line = $0; sub(/^[ \t]+/, "", line) }
    line == "" || line ~ /^#/ { next }
    tolower($1) == "match" { inmatch = 1; next }
    inmatch { next }
    {
      k = tolower($1)
      v = line; sub(/^[^ \t=]+[ \t=]+/, "", v); sub(/[ \t]+$/, "", v)
      if (k == "port") { ports = (ports == "" ? v : ports "," v) }
      else if (!(k in seen)) { seen[k] = 1; val[k] = v }
    }
    END {
      n = split("permitrootlogin passwordauthentication pubkeyauthentication permitemptypasswords x11forwarding", keys, " ")
      for (i = 1; i <= n; i++) if (keys[i] in val) print keys[i] "\t" val[keys[i]]
      if (ports != "") print "port\t" ports
    }
  ' "${files[@]}" 2>/dev/null)"
fi

# ---------------------------------------------------------------------------
# Usuários
# ---------------------------------------------------------------------------

users_tsv=""
uid0_extra=""
admins=""
if [[ -r $PASSWD_FILE ]]; then
  users_tsv="$(awk -F: '
    $7 != "" {
      n = split($7, s, "/"); b = s[n]
      if (b != "nologin" && b != "false" && b != "sync" && b != "shutdown" && b != "halt")
        printf "%s\t%s\t%s\n", $1, $3, $7
    }
  ' "$PASSWD_FILE" | sort)"
  uid0_extra="$(awk -F: '$3 == 0 && $1 != "root" { print $1 }' "$PASSWD_FILE" | sort)"
fi
if [[ -r $GROUP_FILE ]]; then
  admins="$(awk -F: '
    $1 == "sudo" || $1 == "admin" || $1 == "wheel" {
      n = split($4, m, ",")
      for (i = 1; i <= n; i++) if (m[i] != "") print m[i]
    }
  ' "$GROUP_FILE" | sort -u)"
fi

# ---------------------------------------------------------------------------
# Tentativas de autenticação SSH (últimos 7 dias)
# ---------------------------------------------------------------------------

auth_json='{"available": false, "reason": "journalctl não encontrado"}'
if command -v journalctl >/dev/null 2>&1; then
  if (( EUID == 0 )) || id -nG 2>/dev/null | tr ' ' '\n' | grep -qxE 'systemd-journal|adm'; then
    log="$(journalctl -q --no-pager -o cat --since '7 days ago' -u ssh.service -u sshd.service 2>/dev/null)"
    failed="$(grep -cE 'Failed (password|publickey)' <<<"$log")"
    sources="$(grep -E 'Failed (password|publickey)' <<<"$log" | grep -oE 'from [0-9a-fA-F:.]+' | sort -u | grep -c .)"
    accepted="$(grep -cE 'Accepted (password|publickey|keyboard-interactive)' <<<"$log")"
    auth_json="$(jq -nc --arg f "${failed:-0}" --arg s "${sources:-0}" --arg a "${accepted:-0}" \
      '{available: true, window_days: 7, failed: ($f | tonumber), unique_sources: ($s | tonumber), accepted: ($a | tonumber)}')"
  else
    auth_json='{"available": false, "reason": "sem acesso ao journal (usuário fora do grupo systemd-journal)"}'
  fi
fi

# ---------------------------------------------------------------------------
# Proteções complementares
# ---------------------------------------------------------------------------

fail2ban="unknown"
if command -v systemctl >/dev/null 2>&1; then
  f2b_load="" f2b_active=""
  while IFS='=' read -r key value; do
    case "$key" in
      LoadState)   f2b_load="$value" ;;
      ActiveState) f2b_active="$value" ;;
    esac
  done < <(systemctl show fail2ban.service --property=LoadState,ActiveState 2>/dev/null)
  if [[ -n $f2b_load ]]; then
    if [[ $f2b_load == not-found ]]; then fail2ban="not-installed"
    elif [[ $f2b_active == active ]]; then fail2ban="active"
    else fail2ban="inactive"; fi
  fi
fi

unattended="null"
if command -v dpkg-query >/dev/null 2>&1; then
  if dpkg-query -W -f='${Status}' unattended-upgrades 2>/dev/null | grep -q 'install ok installed'; then
    unattended="true"
  else
    unattended="false"
  fi
fi

# ---------------------------------------------------------------------------
# Saída
# ---------------------------------------------------------------------------

jq -n -c \
  --arg fw_tool "$fw_tool" --arg fw_status "$fw_status" \
  --arg fw_default "$fw_default" --arg fw_rules "$fw_rules" \
  --argjson ssh_present "$ssh_present" --arg ssh "$ssh_tsv" \
  --arg users "$users_tsv" --arg uid0 "$uid0_extra" --arg admins "$admins" \
  --argjson auth "$auth_json" \
  --arg fail2ban "$fail2ban" --argjson unattended "$unattended" '
  def lines: split("\n") | map(select(length > 0));
  def nz: if . == "" then null else . end;
  (reduce ($ssh | lines | map(split("\t")))[] as $r ({}; .[$r[0]] = $r[1])) as $s
  | {
      available: true,
      firewall: {
        tool: $fw_tool,
        status: $fw_status,
        default_incoming: ($fw_default | nz),
        rules: ($fw_rules | lines)
      },
      ssh: (
        if $ssh_present | not then { present: false }
        else {
          present: true,
          port: (($s.port // "22") | split(",") | map(try tonumber catch .)),
          permit_root_login: (($s.permitrootlogin // "prohibit-password") | ascii_downcase
                              | if . == "without-password" then "prohibit-password" else . end),
          password_authentication: (($s.passwordauthentication // "yes") | ascii_downcase),
          pubkey_authentication: (($s.pubkeyauthentication // "yes") | ascii_downcase),
          permit_empty_passwords: (($s.permitemptypasswords // "no") | ascii_downcase),
          x11_forwarding: (($s.x11forwarding // "no") | ascii_downcase)
        } end
      ),
      users: {
        with_shell: ($users | lines | map(split("\t") | { name: .[0], uid: (.[1] | try tonumber catch null), shell: .[2] })),
        uid0_extra: ($uid0 | lines),
        admins: ($admins | lines)
      },
      auth: $auth,
      protections: { fail2ban: $fail2ban, unattended_upgrades: $unattended }
    }
' || unavailable "falha ao montar a saída JSON"