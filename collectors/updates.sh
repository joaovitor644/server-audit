#!/usr/bin/env bash
#
# collectors/updates.sh — pacotes com atualização disponível (Debian/Ubuntu).
#
# Contrato dos coletores:
#   - emite UM objeto JSON na saída padrão
#   - somente leitura: usa `apt-get -s` (simulação); NÃO instala nada e NÃO
#     executa `apt-get update` (usa o índice local de pacotes)
#   - sem apt => {"available": false, "reason": "..."} e saída 0
#
# Como contar: simula `apt-get dist-upgrade` e considera só as linhas "Inst"
# de pacotes JÁ instalados (as que têm a versão antiga entre colchetes). É a
# mesma contagem que o aviso de login do Ubuntu mostra. Pacotes novos que
# seriam instalados como dependência não entram.
#
# Saída:
#   {
#     "available": true,
#     "pending": 12,
#     "security": 3,
#     "packages": ["libc6", "openssl", ...],
#     "security_packages": ["openssl", ...],
#     "reboot_required": false,
#     "cache_age_days": 2        // idade do índice do apt (null se desconhecida)
#   }
#
# Se o índice do apt estiver velho, a contagem pode estar subestimada: por
# isso a idade dele também é reportada (o relatório alerta quando passa de
# UPDATES_CACHE_WARN_DAYS).

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

command -v jq >/dev/null 2>&1      || unavailable "jq não encontrado"
command -v apt-get >/dev/null 2>&1 || not_applicable "apt-get não encontrado (somente Debian/Ubuntu)"

if ! sim="$(apt-get -s -o Debug::NoLocking=1 dist-upgrade 2>/dev/null)"; then
  unavailable "falha ao simular apt-get dist-upgrade"
fi

# nome <TAB> 1 se a origem for de segurança, 0 caso contrário
pkgs_tsv="$(awk '
  $1 == "Inst" && $3 ~ /^\[/ {
    sec = (tolower($0) ~ /security/) ? 1 : 0
    printf "%s\t%d\n", $2, sec
  }
' <<<"$sim" | sort -u)"

reboot=false
if [[ -e /run/reboot-required || -e /var/run/reboot-required ]]; then
  reboot=true
fi

# Idade do índice do apt: carimbo do último `apt update` bem-sucedido; se não
# existir, o arquivo mais recente em /var/lib/apt/lists.
mtime=""
stamp=/var/lib/apt/periodic/update-success-stamp
if [[ -e $stamp ]]; then
  mtime="$(stat -c %Y "$stamp" 2>/dev/null)"
else
  mtime="$(stat -c %Y /var/lib/apt/lists/* 2>/dev/null | sort -n | tail -n 1)"
fi
age_days=""
if [[ $mtime =~ ^[0-9]+$ ]]; then
  age_days=$(( ( $(date +%s) - mtime ) / 86400 ))
  (( age_days < 0 )) && age_days=0
fi

jq -n -c --arg pkgs "$pkgs_tsv" --argjson reboot "$reboot" --arg age "$age_days" '
  def lines: split("\n") | map(select(length > 0));
  ($pkgs | lines | map(split("\t") | { name: .[0], security: (.[1] == "1") })) as $p
  | {
      available: true,
      pending: ($p | length),
      security: ($p | map(select(.security)) | length),
      packages: ($p | map(.name) | sort),
      security_packages: ($p | map(select(.security) | .name) | sort),
      reboot_required: $reboot,
      cache_age_days: ($age | try tonumber catch null)
    }
' || unavailable "falha ao montar a saída JSON"