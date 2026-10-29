# lib/render.sh — gera o relatório Markdown a partir do estado.
#
# Uso:  render_report HOST ARQUIVO_ESTADO ARQUIVO_MUDANCAS
# Saída: relatório completo na saída padrão.
#
# Limites de severidade vêm do ambiente (config/thresholds.conf, exportados
# pelo audit.sh); sem eles valem os padrões abaixo.
#
# Para adicionar uma seção nova:
#   _render_<coletor> ESTADO   imprime o corpo da seção em Markdown
#   _issues_<coletor> ESTADO   imprime uma linha por problema: "<sev><TAB><mensagem>"
#                              (sev: 1 = Atenção, 2 = Crítico)
# e inclua o coletor em _SECTION_ORDER / _SECTION_TITLE.

_SECTION_ORDER=(system storage network services docker security updates)

declare -A _SECTION_TITLE=(
  [system]="Sistema"
  [storage]="Armazenamento"
  [network]="Rede"
  [services]="Serviços"
  [docker]="Docker"
  [security]="Segurança"
  [updates]="Atualizações"
)

_sev_label() {
  case "$1" in
    2) echo "🔴 Crítico" ;;
    1) echo "🟡 Atenção" ;;
    *) echo "🟢 Normal" ;;
  esac
}

# ---------------------------------------------------------------------------
# Armazenamento
# ---------------------------------------------------------------------------

_STORAGE_JQ_DEFS='
def sev($f):
  if $f.readonly == true
     or ($f.used_pct // 0) >= $dc
     or ($f.inode_used_pct // 0) >= $ic then 2
  elif ($f.used_pct // 0) >= $dw
     or ($f.inode_used_pct // 0) >= $iw then 1
  else 0 end;
def icon: if . == 2 then "🔴" elif . == 1 then "🟡" else "🟢" end;
def fmtgb: if . == null then "?"
           elif . >= 1024 then "\((. / 1024 * 10 | round) / 10) TB"
           else "\(.) GB" end;
'

# _storage_jq ARQUIVO_ESTADO FILTRO   (saída crua, como jq -r)
_storage_jq() {
  local state="$1" filter="$2"
  jq -r \
    --argjson dw "${DISK_WARN_PCT:-80}" --argjson dc "${DISK_CRIT_PCT:-90}" \
    --argjson iw "${INODE_WARN_PCT:-80}" --argjson ic "${INODE_CRIT_PCT:-90}" \
    "$_STORAGE_JQ_DEFS $filter" "$state"
}

_render_storage() {
  _storage_jq "$1" '
    .storage as $s
    | ($s.filesystems // []) as $fs
    | (
        if ($fs | length) == 0 then
          "Nenhum filesystem encontrado."
        else
          "| Filesystem | Uso | Inodes | Disponível | Situação |",
          "|---|---:|---:|---:|---|",
          ( $fs | sort_by(.mount)[]
            | sev(.) as $v
            | "| `\(.mount)` | \(.used_pct // "?")% | \(if .inode_used_pct == null then "—" else "\(.inode_used_pct)%" end) | \(.avail_gb | fmtgb) | \($v | icon)\(if .readonly == true then " somente leitura" else "" end) |" )
        end
      ),
      ( ($s.devices // []) as $d
        | if ($d | length) > 0 then
            "", "### Dispositivos", "",
            ( $d[] | "- `\(.name)`: \((.size_bytes / 1073741824 * 10 | round) / 10 | fmtgb)\(if .model then " — \(.model)" else "" end)" )
          else empty end )
  '
}

_issues_storage() {
  _storage_jq "$1" '
    (.storage.filesystems // [])[] as $f
    | (
        ( if $f.readonly == true
          then [2, "`\($f.mount)` montado como somente leitura"] else empty end ),
        ( if ($f.used_pct // 0) >= $dc
          then [2, "`\($f.mount)` com \($f.used_pct)% de uso (limite crítico: \($dc)%)"]
          elif ($f.used_pct // 0) >= $dw
          then [1, "`\($f.mount)` com \($f.used_pct)% de uso (limite de atenção: \($dw)%)"]
          else empty end ),
        ( if ($f.inode_used_pct // 0) >= $ic
          then [2, "`\($f.mount)` com \($f.inode_used_pct)% de inodes em uso (limite crítico: \($ic)%)"]
          elif ($f.inode_used_pct // 0) >= $iw
          then [1, "`\($f.mount)` com \($f.inode_used_pct)% de inodes em uso (limite de atenção: \($iw)%)"]
          else empty end )
      )
    | "\(.[0])\t\(.[1])"
  '
}

# ---------------------------------------------------------------------------
# Sistema
# ---------------------------------------------------------------------------

_render_system() {
  jq -r --argjson mw "${MEM_WARN_PCT:-85}" '
    def dur:
      floor as $s
      | ($s / 86400 | floor) as $d
      | (($s % 86400) / 3600 | floor) as $h
      | (($s % 3600) / 60 | floor) as $m
      | if $d > 0 then "\($d)d \($h)h"
        elif $h > 0 then "\($h)h \($m)min"
        else "\($m)min" end;

    .system as $s
    | "| Item | Valor |",
      "|---|---|",
      "| Hostname | `\($s.hostname // "?")` |",
      "| Sistema | \($s.os.pretty // "?") |",
      "| Kernel | \($s.kernel // "?") |",
      "| Arquitetura | \($s.arch // "?") |",
      "| Uptime | \(if $s.uptime_seconds == null then "?" else ($s.uptime_seconds | dur) end) |",
      "| CPU | \($s.cpu.model // "?") (\($s.cpu.cores // "?") \(if $s.cpu.cores == 1 then "núcleo" else "núcleos" end)) |",
      "| Carga (1/5/15 min) | \(($s.cpu.load // []) | map(. // "?" | tostring) | join(" / ")) |",
      "| Memória | \(
          if $s.memory.used_pct == null then "?"
          else "\($s.memory.used_mb) MB de \($s.memory.total_mb) MB (\($s.memory.used_pct)%) \(if $s.memory.used_pct >= $mw then "🟡" else "🟢" end)"
          end) |",
      "| Swap | \(
          if $s.swap.total_mb == null then "?"
          elif $s.swap.total_mb == 0 then "sem swap"
          else "\($s.swap.used_mb) MB de \($s.swap.total_mb) MB (\($s.swap.used_pct)%)"
          end) |"
  ' "$1"
}

_issues_system() {
  jq -r --argjson mw "${MEM_WARN_PCT:-85}" '
    .system.memory.used_pct as $p
    | if $p != null and $p >= $mw
      then "1\tMemória em uso elevado: \($p)% (limite de atenção: \($mw)%)"
      else empty end
  ' "$1"
}

# ---------------------------------------------------------------------------
# Serviços
#   🔴 failed, ou parado embora habilitado; 🟡 em transição;
#   sem alarme: inativo e desabilitado, mascarado ou não instalado.
# ---------------------------------------------------------------------------

_SERVICES_JQ_DEFS='
def trans: (.active // "") | IN("activating", "deactivating", "reloading");
def should_run: (.enabled // "") | startswith("enabled");
def svc_sev:
  if .load == null or .load == "not-found" or .load == "masked" then 0
  elif .active == "failed" then 2
  elif .active == "active" then 0
  elif trans then 1
  elif should_run then 2
  else 0 end;
def svc_label:
  if .load == null then "desconhecido"
  elif .load == "not-found" then "não instalado"
  elif .load == "masked" then "mascarado"
  elif .active == "active" then "🟢 ativo"
  elif .active == "failed" then "🔴 failed"
  elif trans then "🟡 \(.active)"
  elif should_run then "🔴 parado (habilitado)"
  else "inativo (desabilitado)" end;
'

_render_services() {
  jq -r "$_SERVICES_JQ_DEFS"'
    .services as $s
    | ($s.monitored // []) as $m
    | (
        if ($m | length) == 0 then "Nenhum serviço monitorado."
        else
          "| Serviço | Estado |",
          "|---|---|",
          ( $m[] | "| \(.name) | \(svc_label) |" )
        end
      ),
      "", "### Serviços em falha", "",
      ( if (($s.failed // []) | length) == 0 then "Nenhum serviço em falha."
        else ($s.failed[] | "- `\(.).service`") end ),
      ( if (($s.ignored_failed // []) | length) > 0
        then "", "Ignorados pela configuração: \(($s.ignored_failed | map("`\(.).service`") | join(", ")))"
        else empty end )
  ' "$1"
}

_issues_services() {
  jq -r "$_SERVICES_JQ_DEFS"'
    .services as $s
    | ($s.monitored // []) as $m
    | (
        ( $m[] | select(svc_sev > 0)
          | "\(svc_sev)\tServiço `\(.name)` \(
              if .active == "failed" then "em estado failed"
              elif trans then "em transição (\(.active))"
              else "parado (habilitado)" end)" ),
        ( ($s.failed // [])[] as $u
          | select(($m | map(.name) | index($u)) == null)
          | "1\tServiço `\($u).service` em falha" )
      )
  ' "$1"
}

# ---------------------------------------------------------------------------
# Rede
#   🔴 sem rota padrão, ou interface da rota padrão em down.
# ---------------------------------------------------------------------------

_render_network() {
  jq -r '
    def stext: if .scope == "all" then "todas as interfaces"
               elif .scope == "local" then "somente local" else .addr end;

    .network as $n
    | ($n.default_routes // []) as $dr
    | ($dr | map(.dev)) as $prim
    | "### Interfaces", "",
      "| Interface | Estado | Endereços |", "|---|---|---|",
      ( ($n.interfaces // [])[] as $i
        | "| `\($i.name)` | \(
            if $i.state == "up" then "🟢 up"
            elif $i.state == "down" and (($prim | index($i.name)) != null) then "🔴 down"
            else $i.state end) | \(
            if ($i.addresses | length) == 0 then "—"
            else ($i.addresses | map("`\(.)`") | join(", ")) end) |" ),
      "",
      "**Gateway padrão:** \(
        if ($dr | length) == 0 then "nenhum"
        else ($dr | map("`\(.gateway // "—")` via `\(.dev)`") | join(", ")) end)",
      "",
      "**DNS:** \(
        if ($n.dns.servers | length) == 0 then "não identificado"
        else (($n.dns.servers | map("`\(.)`") | join(", "))
              + (if $n.dns.source then " (\($n.dns.source))" else "" end)) end)",
      "", "### Portas em escuta", "",
      ( if $n.listening == null then "Não foi possível listar as portas (ss indisponível)."
        elif ($n.listening | length) == 0 then "Nenhuma porta em escuta."
        else
          "| Protocolo | Porta | Escopo |", "|---|---:|---|",
          ( $n.listening
            | group_by([.proto, .port, .scope])
            | map({ proto: .[0].proto, port: .[0].port, scope: .[0].scope,
                    addr: (map(.addr) | unique | join(", ")) })
            | sort_by(.port, .proto)[]
            | "| \(.proto) | \(.port) | \(stext) |" )
        end )
  ' "$1"
}

_issues_network() {
  jq -r '
    .network as $n
    | ($n.default_routes // []) as $dr
    | ( if ($dr | length) == 0
        then "2\tNenhuma rota padrão configurada (rede principal indisponível)" else empty end ),
      ( ($n.interfaces // [])[] as $i
        | select((($dr | map(.dev) | index($i.name)) != null) and $i.state == "down")
        | "2\tInterface principal `\($i.name)` está down" )
  ' "$1"
}

# ---------------------------------------------------------------------------
# Docker
#   🔴 container essencial (DOCKER_ESSENTIAL) parado ou inexistente;
#   🟡 reiniciando, unhealthy, encerrado com erro, pausado ou dead.
# ---------------------------------------------------------------------------

_DOCKER_JQ_DEFS='
def isess($ess): .name as $n | ($ess | index($n)) != null;
def csev($ess):
  if isess($ess) and .state != "running" then 2
  elif .state == "restarting" or .restarting == true then 1
  elif .health == "unhealthy" then 1
  elif .state == "dead" or .state == "paused" then 1
  elif .state == "exited" and ((.exit_code // 0) != 0) and ((.exited_ago_days // 0) <= $ew) then 1
  else 0 end;
def clabel($ess):
  csev($ess) as $v
  | (if .state == "running" then "Up\(if .health != null then " (\(.health))" else "" end)"
     elif .state == "restarting" or .restarting == true then "reiniciando"
     elif .state == "exited" then "Exited (\(.exit_code))\(if (.exited_ago_days // 0) > 0 then " há \(.exited_ago_days)d" else "" end)"
     else .state end) as $t
  | (if $v == 2 then "🔴" elif $v == 1 then "🟡" elif .state == "running" then "🟢" else "" end) as $i
  | [$i, $t] | map(select(. != "")) | join(" ");
'

_docker_essential_json() {
  local -a ess=()
  read -r -a ess <<<"${DOCKER_ESSENTIAL:-}"
  jq -nc '$ARGS.positional' --args "${ess[@]}"
}

_render_docker() {
  jq -r --argjson ess "$(_docker_essential_json)" --argjson ew "${DOCKER_EXIT_WARN_DAYS:-7}" "$_DOCKER_JQ_DEFS"'
    .docker as $d
    | ($d.containers // []) as $c
    | ( if ($c | length) == 0 then "Nenhum container."
        else
          "| Container | Estado | Imagem |", "|---|---|---|",
          ( $c | sort_by(.name)[] | "| \(.name) | \(clabel($ess)) | \(.image) |" )
        end ),
      "",
      "Imagens: \($d.images.count) (\($d.images.dangling) sem tag) · Volumes: \($d.volumes.count) (\($d.volumes.dangling) órfãos) · Redes: \($d.networks.count)"
  ' "$1"
}

_issues_docker() {
  jq -r --argjson ess "$(_docker_essential_json)" --argjson ew "${DOCKER_EXIT_WARN_DAYS:-7}" "$_DOCKER_JQ_DEFS"'
    .docker as $d
    | ($d.containers // []) as $c
    | ( ( $c[] | select(csev($ess) > 0)
          | "\(csev($ess))\tContainer \(if isess($ess) then "essencial " else "" end)`\(.name)` \(
              if isess($ess) and .state != "running" then "não está em execução (estado: \(.state))"
              elif .state == "restarting" or .restarting == true then "reiniciando (\(.restart_count // 0) reinícios)"
              elif .health == "unhealthy" then "com healthcheck falhando (unhealthy)"
              elif .state == "exited" then "encerrou com erro (código \(.exit_code))\(if .exited_ago_days != null then " há \(.exited_ago_days) dia(s)" else "" end)"
              else "em estado \(.state)" end)" ),
        ( $ess[] as $e
          | select(($c | map(.name) | index($e)) == null)
          | "2\tContainer essencial `\($e)` não encontrado" ) )
  ' "$1"
}

# ---------------------------------------------------------------------------
# Segurança
#   🔴 SSH com senhas vazias, conta extra com UID 0;
#   🟡 firewall inativo ou desconhecido, SSH com login root/senha habilitado.
# ---------------------------------------------------------------------------

_render_security() {
  jq -r --argjson pw "${SSH_PASSWORD_AUTH_WARN:-1}" '
    def names($a): if ($a | length) == 0 then "nenhum"
                   else ($a | map("`\(.)`") | join(", ")) end;
    def flag($v; $bad; $icon): if $v == $bad then " \($icon)" else "" end;

    .security as $s
    | "### Firewall", "",
      ( if $s.firewall.tool == "none"
        then "- ufw não instalado (só o ufw é consultado; se houver outro firewall, como nftables ou iptables, confira por fora)"
        else
          "- Firewall (ufw): \(
            if $s.firewall.status == "active" then "🟢 ativo"
            elif $s.firewall.status == "inactive" then "🟡 inativo"
            else "🟡 desconhecido (sem permissão; configure o sudoers)" end)",
          ( if $s.firewall.default_incoming != null
            then "- Política padrão de entrada: \($s.firewall.default_incoming)" else empty end ),
          ( if ($s.firewall.rules | length) > 0
            then "- Regras:", ($s.firewall.rules[] | "  - `\(.)`") else empty end )
        end ),
      "", "### SSH", "",
      ( if $s.ssh.present != true then "Configuração do sshd não encontrada."
        else
          "| Opção | Valor |", "|---|---|",
          "| Porta | \($s.ssh.port | map(tostring) | join(", ")) |",
          "| PermitRootLogin | \($s.ssh.permit_root_login)\(flag($s.ssh.permit_root_login; "yes"; "🟡")) |",
          "| PasswordAuthentication | \($s.ssh.password_authentication)\(if $pw == 1 then flag($s.ssh.password_authentication; "yes"; "🟡") else "" end) |",
          "| PubkeyAuthentication | \($s.ssh.pubkey_authentication) |",
          "| PermitEmptyPasswords | \($s.ssh.permit_empty_passwords)\(flag($s.ssh.permit_empty_passwords; "yes"; "🔴")) |",
          "| X11Forwarding | \($s.ssh.x11_forwarding) |"
        end ),
      "", "### Usuários", "",
      "- Com shell de login: \(names($s.users.with_shell | map(.name)))",
      "- Administradores (sudo/admin/wheel): \(names($s.users.admins))",
      ( if ($s.users.uid0_extra | length) > 0
        then "- 🔴 Contas com UID 0 além de root: \(names($s.users.uid0_extra))" else empty end ),
      "", "### Tentativas de autenticação SSH", "",
      ( if $s.auth.available != true
        then "Indisponível: \($s.auth.reason // "sem detalhes")."
        else "- Últimos \($s.auth.window_days) dias: \($s.auth.failed) falhas (\($s.auth.unique_sources) origens distintas) e \($s.auth.accepted) logins aceitos"
        end ),
      "", "### Proteções complementares", "",
      "- fail2ban: \(
        if $s.protections.fail2ban == "active" then "🟢 ativo"
        elif $s.protections.fail2ban == "inactive" then "inativo"
        elif $s.protections.fail2ban == "not-installed" then "não instalado"
        else "desconhecido" end)",
      "- unattended-upgrades: \(
        if $s.protections.unattended_upgrades == null then "desconhecido"
        elif $s.protections.unattended_upgrades then "instalado" else "não instalado" end)"
  ' "$1"
}

_issues_security() {
  jq -r --argjson pw "${SSH_PASSWORD_AUTH_WARN:-1}" '
    .security as $s
    | ( if $s.firewall.status == "inactive" then "1\tFirewall (ufw) inativo" else empty end ),
      ( if $s.firewall.tool == "ufw" and $s.firewall.status == "unknown"
        then "1\tEstado do firewall (ufw) desconhecido: sem permissão para consultar (veja a seção Permissões do README)"
        else empty end ),
      ( if $s.ssh.present == true then
          ( if $s.ssh.permit_empty_passwords == "yes"
            then "2\tSSH permite senhas vazias (PermitEmptyPasswords yes)" else empty end ),
          ( if $s.ssh.permit_root_login == "yes"
            then "1\tSSH permite login direto como root com senha (PermitRootLogin yes)" else empty end ),
          ( if $pw == 1 and $s.ssh.password_authentication == "yes"
            then "1\tSSH aceita autenticação por senha (PasswordAuthentication yes)" else empty end )
        else empty end ),
      ( ($s.users.uid0_extra // [])[] | "2\tConta `\(.)` com UID 0 além de root" )
  ' "$1"
}

# ---------------------------------------------------------------------------
# Atualizações
#   🟡 pacotes pendentes, reinicialização pendente, índice do apt velho.
# ---------------------------------------------------------------------------

_render_updates() {
  jq -r --argjson cw "${UPDATES_CACHE_WARN_DAYS:-14}" --argjson uw "${UPDATES_WARN_COUNT:-1}" '
    .updates as $u
    | ( if $u.pending == 0 then "Nenhum pacote pendente."
        elif $u.pending == 1 then "1 pacote pode ser atualizado."
        else "\($u.pending) pacotes podem ser atualizados." end ),
      ( if $u.security > 0 then "", "Atualizações de segurança: \($u.security)." else empty end ),
      "", "### Situação", "",
      ( if $u.pending > 0 and $u.pending >= $uw then "🟡 Atualizações pendentes" else "🟢 Em dia" end ),
      "",
      "- Reinicialização necessária: \(if $u.reboot_required then "sim 🟡" else "não" end)",
      "- Índice de pacotes (apt) atualizado: \(
        if $u.cache_age_days == null then "data desconhecida"
        elif $u.cache_age_days == 0 then "hoje"
        else "há \($u.cache_age_days) dia(s)\(if $u.cache_age_days > $cw then " 🟡" else "" end)" end)",
      ( ($u.security_packages + ($u.packages - $u.security_packages)) as $all
        | if ($all | length) > 0 then
            "", "### Pacotes", "",
            ( ($all[:20] | map("`\(.)`") | join(", "))
              + (if ($all | length) > 20 then " (e mais \(($all | length) - 20))" else "" end) )
          else empty end )
  ' "$1"
}

_issues_updates() {
  jq -r --argjson cw "${UPDATES_CACHE_WARN_DAYS:-14}" --argjson uw "${UPDATES_WARN_COUNT:-1}" '
    .updates as $u
    | ( if $u.pending > 0 and $u.pending >= $uw
        then "1\t\($u.pending) \(if $u.pending == 1 then "pacote com atualização pendente" else "pacotes com atualização pendente" end)\(if $u.security > 0 then " (\($u.security) de segurança)" else "" end)"
        else empty end ),
      ( if $u.reboot_required then "1\tReinicialização do servidor pendente" else empty end ),
      ( if $u.cache_age_days != null and $u.cache_age_days > $cw
        then "1\tÍndice de pacotes (apt) desatualizado há \($u.cache_age_days) dias; a contagem de pendências pode estar incorreta"
        else empty end )
  ' "$1"
}

# ---------------------------------------------------------------------------
# Relatório
# ---------------------------------------------------------------------------

render_report() {
  local host="$1" state="$2" changes="$3"
  local name status collected_at worst=0 sev msg detail
  local -a issue_sev=() issue_msg=() failed_names=()

  # --- problemas: coletores com falha + problemas de cada seção ---
  while IFS=$'\t' read -r name detail; do
    [[ -n $name ]] || continue
    failed_names+=("$name")
    issue_sev+=(1)
    issue_msg+=("Coletor \`$name\` falhou: $detail")
  done < <(jq -r '. as $s | (.failed_collectors // [])[] | "\(.)\t\($s[.].error // "sem detalhes")"' "$state")

  for name in "${_SECTION_ORDER[@]}"; do
    status="$(jq -r --arg k "$name" \
      'if has($k) then (if .[$k].available == false then "unavailable" else "ok" end) else "absent" end' \
      "$state")"
    if [[ $status == unavailable ]]; then
      # "reason" = ausência esperada (sem alarme); "error" = problema real
      detail="$(jq -r --arg k "$name" \
        'if .[$k].reason == null and .[$k].error != null then .[$k].error else "" end' "$state")"
      if [[ -n $detail && " ${failed_names[*]:-} " != *" $name "* ]]; then
        issue_sev+=(1)
        issue_msg+=("Seção \`$name\` indisponível: $detail")
      fi
      continue
    fi
    [[ $status == ok ]] || continue
    declare -F "_issues_$name" >/dev/null || continue
    while IFS=$'\t' read -r sev msg; do
      [[ -n $sev ]] || continue
      issue_sev+=("$sev")
      issue_msg+=("$msg")
    done < <("_issues_$name" "$state")
  done

  for sev in "${issue_sev[@]}"; do
    (( sev > worst )) && worst=$sev
  done

  collected_at="$(jq -r '.collected_at // "desconhecido"' "$state")"

  # --- cabeçalho e resumo ---
  printf '# Relatório de auditoria — %s\n\n' "$host"
  printf -- '- **Coletado em:** %s\n' "$collected_at"
  printf -- '- **Situação geral:** %s\n\n' "$(_sev_label "$worst")"

  printf '## Resumo\n\n'
  if (( ${#issue_sev[@]} == 0 )); then
    printf 'Nenhum item exige atenção.\n\n'
  else
    local i s
    for s in 2 1; do
      for i in "${!issue_sev[@]}"; do
        [[ ${issue_sev[$i]} == "$s" ]] || continue
        printf -- '- %s %s\n' "$([[ $s == 2 ]] && echo 🔴 || echo 🟡)" "${issue_msg[$i]}"
      done
    done
    printf '\n'
  fi

  # --- seções ---
  for name in "${_SECTION_ORDER[@]}"; do
    status="$(jq -r --arg k "$name" \
      'if has($k) then (if .[$k].available == false then "unavailable" else "ok" end) else "absent" end' \
      "$state")"

    case "$status" in
      absent)
        continue ;;
      unavailable)
        detail="$(jq -r --arg k "$name" '.[$k].reason // .[$k].error // "sem detalhes"' "$state")"
        printf '## %s\n\nIndisponível: %s.\n\n' "${_SECTION_TITLE[$name]}" "$detail" ;;
      ok)
        printf '## %s\n\n' "${_SECTION_TITLE[$name]}"
        if declare -F "_render_$name" >/dev/null; then
          "_render_$name" "$state"
        else
          printf 'Coletor executado, mas a renderização desta seção ainda não foi implementada.\n'
        fi
        printf '\n' ;;
    esac
  done

  # --- mudanças ---
  printf '## Mudanças desde o relatório anterior\n\n'
  if [[ -r $changes ]]; then
    cat "$changes"
  fi
  return 0
}