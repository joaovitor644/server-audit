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
            | "| `\(.mount)` | \(.used_pct // "?")% | \(if .inode_used_pct == null then "—" else "\(.inode_used_pct)%" end) | \(.avail_gb) GB | \($v | icon)\(if .readonly == true then " somente leitura" else "" end) |" )
        end
      ),
      ( ($s.devices // []) as $d
        | if ($d | length) > 0 then
            "", "### Dispositivos", "",
            ( $d[] | "- `\(.name)`: \((.size_bytes / 1073741824 * 10 | round) / 10) GB\(if .model then " — \(.model)" else "" end)" )
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
# Relatório
# ---------------------------------------------------------------------------

render_report() {
  local host="$1" state="$2" changes="$3"
  local name status collected_at worst=0 sev msg detail
  local -a issue_sev=() issue_msg=()

  # --- problemas: coletores com falha + problemas de cada seção ---
  while IFS=$'\t' read -r name detail; do
    [[ -n $name ]] || continue
    issue_sev+=(1)
    issue_msg+=("Coletor \`$name\` falhou: $detail")
  done < <(jq -r '. as $s | (.failed_collectors // [])[] | "\(.)\t\($s[.].error // "sem detalhes")"' "$state")

  for name in "${_SECTION_ORDER[@]}"; do
    status="$(jq -r --arg k "$name" \
      'if has($k) then (if .[$k].available == false then "unavailable" else "ok" end) else "absent" end' \
      "$state")"
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
