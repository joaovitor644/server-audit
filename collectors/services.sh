#!/usr/bin/env bash
#
# collectors/services.sh — estado dos principais serviços do systemd e
# serviços em falha.
#
# Contrato dos coletores:
#   - emite UM objeto JSON na saída padrão
#   - somente leitura: só consulta (`systemctl show` / `list-units`)
#   - sem systemd => {"available": false, "reason": "..."} e saída 0
#
# Quais serviços são monitorados:
#   - os listados em config/services.conf (um por linha, '#' para comentários);
#     linhas com "!" (ex.: !systemd-networkd-wait-online) tiram aquele serviço
#     da lista de falhas;
#   - se o arquivo não existir ou estiver vazio, a lista padrão abaixo.
#   Serviço não instalado não é problema: aparece como "não instalado".
#
# Saída:
#   {
#     "available": true,
#     "monitored": [
#       { "name": "ssh", "load": "loaded", "active": "active",
#         "sub": "running", "enabled": "enabled" }
#     ],
#     "failed": ["example"],         // nomes sem o sufixo .service
#     "ignored_failed": []           // em falha, mas ignorados via !
#   }

set -uo pipefail
export LC_ALL=C

unavailable() {
  printf '{"available": false, "error": "%s"}\n' "$1"
  exit 0
}

not_applicable() {
  printf '{"available": false, "reason": "%s"}\n' "$1"
  exit 0
}

command -v jq >/dev/null 2>&1        || unavailable "jq não encontrado"
command -v systemctl >/dev/null 2>&1 || not_applicable "systemctl não encontrado"
[[ -d /run/systemd/system ]]         || not_applicable "systemd não está em execução"

DEFAULT_SERVICES=(ssh docker nginx cron)

script_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
conf="$script_dir/../config/services.conf"

services=()
ignore=()
if [[ -r $conf ]]; then
  while IFS= read -r line; do
    line="${line%%#*}"
    line="${line//[[:space:]]/}"
    [[ -n $line ]] || continue
    if [[ $line == '!'* ]]; then
      line="${line#!}"
      ignore+=("${line%.service}")
    else
      services+=("$line")
    fi
  done <"$conf"
fi
(( ${#services[@]} > 0 )) || services=("${DEFAULT_SERVICES[@]}")

rows=""
for svc in "${services[@]}"; do
  [[ $svc =~ ^[A-Za-z0-9@:._-]+$ ]] || continue

  unit="$svc"
  [[ $unit == *.* ]] || unit="$unit.service"

  load="" active="" sub="" enabled=""
  while IFS='=' read -r key value; do
    case "$key" in
      LoadState)     load="$value" ;;
      ActiveState)   active="$value" ;;
      SubState)      sub="$value" ;;
      UnitFileState) enabled="$value" ;;
    esac
  done < <(systemctl show "$unit" --property=LoadState,ActiveState,SubState,UnitFileState 2>/dev/null)

  rows+="${unit%.service}"$'\t'"$load"$'\t'"$active"$'\t'"$sub"$'\t'"$enabled"$'\n'
done

failed_all="$(systemctl list-units --type=service --state=failed --no-legend --plain --no-pager 2>/dev/null \
  | awk 'NF { sub(/\.service$/, "", $1); print $1 }')"

# Serviços em falha marcados com "!" no services.conf não geram alarme, mas
# continuam registrados em "ignored_failed" para ficar transparente.
failed="" ignored=""
while IFS= read -r unit_name; do
  [[ -n $unit_name ]] || continue
  if [[ " ${ignore[*]:-} " == *" $unit_name "* ]]; then
    ignored+="$unit_name"$'\n'
  else
    failed+="$unit_name"$'\n'
  fi
done <<<"$failed_all"

jq -n -c --arg rows "$rows" --arg failed "$failed" --arg ignored "$ignored" '
  def lines: split("\n") | map(select(length > 0));
  def nz: if . == "" then null else . end;
  {
    available: true,
    monitored: (
      $rows | lines
      | map(split("\t") | {
          name:    .[0],
          load:    (.[1] | nz),
          active:  (.[2] | nz),
          sub:     (.[3] | nz),
          enabled: (.[4] | nz)
        })
    ),
    failed: ($failed | lines | sort),
    ignored_failed: ($ignored | lines | sort)
  }
' || unavailable "falha ao montar a saída JSON"