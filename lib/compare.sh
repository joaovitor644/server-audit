# lib/compare.sh — compara o estado anterior com o novo.
#
# Uso:  compare_states ARQUIVO_ANTERIOR ARQUIVO_NOVO
# Saída: Markdown com as mudanças na saída padrão (vazio = nenhuma mudança).
# Retorno: 0 em caso de sucesso, diferente de 0 se a comparação falhar.
#
# Regra: uma seção só é comparada se o coletor estava disponível
# ("available": true) nas DUAS execuções. Isso evita falsas mudanças quando um
# coletor falha ou uma ferramenta opcional deixa de existir.
#
# Para adicionar uma seção nova: crie _compare_<coletor> (imprime as linhas
# "- ...", uma por mudança) e inclua o nome em _COMPARE_SECTIONS.

_COMPARE_SECTIONS=(system storage network services docker security updates)

declare -A _COMPARE_TITLE=(
  [system]="Sistema"
  [storage]="Armazenamento"
  [network]="Rede"
  [services]="Serviços"
  [docker]="Docker"
  [security]="Segurança"
  [updates]="Atualizações"
)

_compare_storage() {
  local old="$1" new="$2"
  jq -r -n --slurpfile a "$old" --slurpfile b "$new" '
    ($a[0].storage // {}) as $o
    | ($b[0].storage // {}) as $n
    | if ($o.available != true) or ($n.available != true) then empty
      else
        (($o.filesystems // []) | map({(.mount): .}) | add // {}) as $om
        | (($n.filesystems // []) | map({(.mount): .}) | add // {}) as $nm
        | (
            ( ($nm | keys[]) as $m
              | if $om[$m] == null then
                  "- Novo filesystem: `\($m)` (\($nm[$m].used_pct)% de uso)"
                else
                  ( if $om[$m].used_pct != $nm[$m].used_pct
                    then "- `\($m)`: \($om[$m].used_pct)% → \($nm[$m].used_pct)%"
                    else empty end ),
                  ( if ($om[$m].readonly != true) and ($nm[$m].readonly == true)
                    then "- `\($m)` passou a ser montado como **somente leitura**"
                    else empty end )
                end ),
            ( ($om | keys[]) as $m
              | select($nm[$m] == null)
              | "- Filesystem removido: `\($m)`" )
          )
      end
  ' || return 1
}

_compare_system() {
  local old="$1" new="$2"
  jq -r -n --slurpfile a "$old" --slurpfile b "$new" '
    ($a[0].system // {}) as $o
    | ($b[0].system // {}) as $n
    | if ($o.available != true) or ($n.available != true) then empty
      else
        ( if ($o.boot_epoch != null and $n.boot_epoch != null
              and (($n.boot_epoch - $o.boot_epoch) | fabs) > 120)
          then "- Reinicialização detectada (último boot: \($n.boot_epoch | strftime("%Y-%m-%d %H:%M UTC")))"
          else empty end ),
        ( if $o.kernel != $n.kernel
          then "- Kernel: `\($o.kernel)` → `\($n.kernel)`" else empty end ),
        ( if $o.os.pretty != $n.os.pretty
          then "- Sistema: \($o.os.pretty) → \($n.os.pretty)" else empty end ),
        ( if $o.cpu.cores != $n.cpu.cores
          then "- Núcleos de CPU: \($o.cpu.cores) → \($n.cpu.cores)" else empty end ),
        ( if $o.memory.total_mb != $n.memory.total_mb
          then "- Memória total: \($o.memory.total_mb) MB → \($n.memory.total_mb) MB" else empty end )
      end
  ' || return 1
}

_compare_services() {
  local old="$1" new="$2"
  jq -r -n --slurpfile a "$old" --slurpfile b "$new" '
    ($a[0].services // {}) as $o
    | ($b[0].services // {}) as $n
    | if ($o.available != true) or ($n.available != true) then empty
      else
        (($o.monitored // []) | map({(.name): .}) | add // {}) as $om
        | (($n.monitored // []) | map({(.name): .}) | add // {}) as $nm
        | ($nm | keys) as $mon
        | (
            ( ($nm | keys[]) as $s
              | select($om[$s] != null and $om[$s].active != $nm[$s].active)
              | "- `\($s)`: \($om[$s].active) → \($nm[$s].active)" ),
            ( ($n.failed // [])[] as $u
              | select(($mon | index($u)) == null and ((($o.failed // []) | index($u)) == null))
              | "- `\($u).service` passou para o estado `failed`" ),
            ( ($o.failed // [])[] as $u
              | select(($mon | index($u)) == null and ((($n.failed // []) | index($u)) == null))
              | "- `\($u).service` não está mais em falha" )
          )
      end
  ' || return 1
}

_compare_network() {
  local old="$1" new="$2"
  jq -r -n --slurpfile a "$old" --slurpfile b "$new" '
    def stext: if . == "all" then "todas as interfaces"
               elif . == "local" then "somente local" else "interface específica" end;
    def pmap:
      (. // [])
      | group_by("\(.proto)/\(.port)")
      | map({ key: "\(.[0].proto)/\(.[0].port)",
              value: (if any(.[]; .scope == "all") then "all"
                      elif any(.[]; .scope == "specific") then "specific"
                      else "local" end) })
      | from_entries;
    def gws: (. // []) | map("\(.gateway // "—") (\(.dev))") | join(", ");

    ($a[0].network // {}) as $o
    | ($b[0].network // {}) as $n
    | if ($o.available != true) or ($n.available != true) then empty
      else
        (($o.interfaces // []) | map({(.name): .}) | add // {}) as $oi
        | (($n.interfaces // []) | map({(.name): .}) | add // {}) as $ni
        | (if $o.listening == null or $n.listening == null then null else ($o.listening | pmap) end) as $op
        | (if $o.listening == null or $n.listening == null then null else ($n.listening | pmap) end) as $np
        | (
            ( ($ni | keys[]) as $i
              | if $oi[$i] == null then "- Nova interface: `\($i)`"
                else
                  ( if $oi[$i].state != $ni[$i].state
                    then "- `\($i)`: \($oi[$i].state) → \($ni[$i].state)" else empty end ),
                  ( (($ni[$i].addresses // []) - ($oi[$i].addresses // []))[]
                    | "- `\($i)`: endereço `\(.)` adicionado" ),
                  ( (($oi[$i].addresses // []) - ($ni[$i].addresses // []))[]
                    | "- `\($i)`: endereço `\(.)` removido" )
                end ),
            ( ($oi | keys[]) as $i | select($ni[$i] == null) | "- Interface removida: `\($i)`" ),
            ( if ($o.default_routes | gws) != ($n.default_routes | gws)
              then "- Gateway padrão: \(($o.default_routes | gws) | if . == "" then "nenhum" else . end) → \(($n.default_routes | gws) | if . == "" then "nenhum" else . end)"
              else empty end ),
            ( if ((($o.dns.servers // []) | sort) != (($n.dns.servers // []) | sort))
              then "- DNS: \((($o.dns.servers // []) | join(", ")) | if . == "" then "nenhum" else . end) → \((($n.dns.servers // []) | join(", ")) | if . == "" then "nenhum" else . end)"
              else empty end ),
            ( if $op == null then empty
              else
                ( ($np | keys[]) as $k
                  | if $op[$k] == null then "- Nova porta em escuta: `\($k)` (\($np[$k] | stext))"
                    elif $op[$k] != $np[$k]
                    then "- `\($k)`: \($op[$k] | stext) → \($np[$k] | stext)"
                    else empty end ),
                ( ($op | keys[]) as $k | select($np[$k] == null)
                  | "- Porta deixou de escutar: `\($k)`" )
              end )
          )
      end
  ' || return 1
}

_compare_docker() {
  local old="$1" new="$2"
  jq -r -n --slurpfile a "$old" --slurpfile b "$new" '
    ($a[0].docker // {}) as $o
    | ($b[0].docker // {}) as $n
    | if ($o.available != true) or ($n.available != true) then empty
      else
        (($o.containers // []) | map({(.name): .}) | add // {}) as $om
        | (($n.containers // []) | map({(.name): .}) | add // {}) as $nm
        | (
            ( if ($om | length) != ($nm | length)
              then "- Containers: \($om | length) → \($nm | length)" else empty end ),
            ( ($nm | keys[]) as $c | select($om[$c] == null) | "- Novo container: `\($c)`" ),
            ( ($om | keys[]) as $c | select($nm[$c] == null) | "- Container removido: `\($c)`" ),
            ( ($nm | keys[]) as $c
              | select($om[$c] != null and $om[$c].state != $nm[$c].state)
              | "- `\($c)`: \($om[$c].state) → \($nm[$c].state)" ),
            ( ($nm | keys[]) as $c
              | select($om[$c] != null and $om[$c].image != $nm[$c].image)
              | "- Imagem de `\($c)`: `\($om[$c].image)` → `\($nm[$c].image)`" ),
            ( if $o.images.count != $n.images.count
              then "- Imagens: \($o.images.count) → \($n.images.count)" else empty end ),
            ( if $o.volumes.count != $n.volumes.count
              then "- Volumes: \($o.volumes.count) → \($n.volumes.count)" else empty end ),
            ( if $o.networks.count != $n.networks.count
              then "- Redes: \($o.networks.count) → \($n.networks.count)" else empty end )
          )
      end
  ' || return 1
}

_compare_security() {
  local old="$1" new="$2"
  jq -r -n --slurpfile a "$old" --slurpfile b "$new" '
    def v: if type == "array" then join(",") else tostring end;
    def names: {
      port: "Port", permit_root_login: "PermitRootLogin",
      password_authentication: "PasswordAuthentication",
      pubkey_authentication: "PubkeyAuthentication",
      permit_empty_passwords: "PermitEmptyPasswords", x11_forwarding: "X11Forwarding"
    };

    ($a[0].security // {}) as $o
    | ($b[0].security // {}) as $n
    | if ($o.available != true) or ($n.available != true) then empty
      else
        (
          # firewall: só compara quando o estado era conhecido nas duas execuções
          ( if $o.firewall.status != "unknown" and $n.firewall.status != "unknown" then
              ( if $o.firewall.status != $n.firewall.status
                then "- Firewall (\($n.firewall.tool)): \($o.firewall.status) → \($n.firewall.status)"
                else empty end ),
              ( (($n.firewall.rules // []) - ($o.firewall.rules // []))[]
                | "- Regra de firewall adicionada: `\(.)`" ),
              ( (($o.firewall.rules // []) - ($n.firewall.rules // []))[]
                | "- Regra de firewall removida: `\(.)`" )
            else empty end ),
          # ssh
          ( if $o.ssh.present == true and $n.ssh.present == true then
              ( names | keys[]) as $k
              | select(($o.ssh[$k] | v) != ($n.ssh[$k] | v))
              | "- SSH `\(names[$k])`: \($o.ssh[$k] | v) → \($n.ssh[$k] | v)"
            else empty end ),
          # usuários
          ( ((($n.users.with_shell // []) | map(.name)) - (($o.users.with_shell // []) | map(.name)))[]
            | "- Novo usuário com shell de login: `\(.)`" ),
          ( ((($o.users.with_shell // []) | map(.name)) - (($n.users.with_shell // []) | map(.name)))[]
            | "- Usuário com shell de login removido: `\(.)`" ),
          ( ((($n.users.admins // [])) - (($o.users.admins // [])))[]
            | "- Novo administrador (sudo/admin/wheel): `\(.)`" ),
          ( ((($o.users.admins // [])) - (($n.users.admins // [])))[]
            | "- Administrador removido: `\(.)`" ),
          ( ((($n.users.uid0_extra // [])) - (($o.users.uid0_extra // [])))[]
            | "- Nova conta com UID 0: `\(.)`" ),
          # proteções
          ( if $o.protections.fail2ban != $n.protections.fail2ban
            then "- fail2ban: \($o.protections.fail2ban) → \($n.protections.fail2ban)" else empty end ),
          ( if $o.protections.unattended_upgrades != $n.protections.unattended_upgrades
            then "- unattended-upgrades: \($o.protections.unattended_upgrades) → \($n.protections.unattended_upgrades)" else empty end )
        )
      end
  ' || return 1
}

_compare_updates() {
  local old="$1" new="$2"
  jq -r -n --slurpfile a "$old" --slurpfile b "$new" '
    ($a[0].updates // {}) as $o
    | ($b[0].updates // {}) as $n
    | if ($o.available != true) or ($n.available != true) then empty
      else
        ( if $o.pending != $n.pending
          then "- Pacotes pendentes: \($o.pending) → \($n.pending)" else empty end ),
        ( if $o.security != $n.security
          then "- Pacotes de segurança pendentes: \($o.security) → \($n.security)" else empty end ),
        ( if ($o.reboot_required != true) and ($n.reboot_required == true)
          then "- Reinicialização passou a ser necessária" else empty end )
      end
  ' || return 1
}

compare_states() {
  local old="$1" new="$2" name body

  for name in "${_COMPARE_SECTIONS[@]}"; do
    body="$("_compare_$name" "$old" "$new")" || return 1
    if [[ -n $body ]]; then
      printf '### %s\n\n%s\n\n' "${_COMPARE_TITLE[$name]}" "$body"
    fi
  done
  return 0
}