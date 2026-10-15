#!/usr/bin/env bash
#
# collectors/system.sh — sistema operacional e recursos básicos da máquina.
#
# Contrato dos coletores:
#   - emite UM objeto JSON na saída padrão
#   - somente leitura: não altera nada no sistema
#   - dependência obrigatória ausente => {"available": false, "error": "..."}
#     e código de saída 0
#
# Lê diretamente de /proc e /etc/os-release (o mesmo que `free`, `uptime` e
# `nproc` usam), sem executar nada além de utilitários básicos.
#
# Saída:
#   {
#     "available": true,
#     "hostname": "kait",
#     "os": { "id": "debian", "version": "12", "pretty": "Debian GNU/Linux 12 (bookworm)" },
#     "kernel": "6.1.0-25-amd64",
#     "arch": "x86_64",
#     "uptime_seconds": 123456,
#     "boot_epoch": 1760000000,
#     "cpu": { "model": "Intel(R) ...", "cores": 4, "load": [0.1, 0.2, 0.3] },
#     "memory": { "total_mb": 3900, "used_mb": 1840, "available_mb": 2060, "used_pct": 47 },
#     "swap":   { "total_mb": 2048, "used_mb": 0, "used_pct": 0 }
#   }
#
# "used" considera MemAvailable (o que o kernel realmente pode ceder),
# portanto cache de disco não conta como memória em uso.

set -uo pipefail
export LC_ALL=C

unavailable() {
  printf '{"available": false, "error": "%s"}\n' "$1"
  exit 0
}

command -v jq >/dev/null 2>&1 || unavailable "jq não encontrado"
[[ -r /proc/meminfo && -r /proc/uptime ]] || unavailable "/proc indisponível"

# --- sistema operacional ---
os_file=""
for f in /etc/os-release /usr/lib/os-release; do
  [[ -r $f ]] && { os_file="$f"; break; }
done

os_val() {
  [[ -n $os_file ]] || return 0
  awk -F= -v k="$1" '
    $1 == k { v = substr($0, length(k) + 2); gsub(/^"|"$/, "", v); print v; exit }
  ' "$os_file"
}

host="$(hostname -s 2>/dev/null || uname -n 2>/dev/null || true)"
kernel="$(uname -r 2>/dev/null || true)"
arch="$(uname -m 2>/dev/null || true)"

# --- uptime e horário do boot ---
uptime_s="$(awk '{ print int($1) }' /proc/uptime 2>/dev/null)"
btime=""
[[ -r /proc/stat ]] && btime="$(awk '$1 == "btime" { print $2; exit }' /proc/stat)"

# --- CPU e carga ---
cpu_model=""
[[ -r /proc/cpuinfo ]] && cpu_model="$(awk -F': *' '/^model name/ { print $2; exit }' /proc/cpuinfo)"
cores="$(nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo 2>/dev/null || true)"
read -r l1 l5 l15 _ < /proc/loadavg 2>/dev/null || { l1=""; l5=""; l15=""; }

# --- memória e swap (kB) ---
read -r mem_total mem_avail swap_total swap_free < <(awk '
  /^MemTotal:/     { t = $2 }
  /^MemAvailable:/ { a = $2 }
  /^SwapTotal:/    { st = $2 }
  /^SwapFree:/     { sf = $2 }
  END { print t, a, st, sf }
' /proc/meminfo)

jq -n -c \
  --arg host "$host" --arg osid "$(os_val ID)" --arg osver "$(os_val VERSION_ID)" \
  --arg ospretty "$(os_val PRETTY_NAME)" --arg kernel "$kernel" --arg arch "$arch" \
  --arg up "${uptime_s:-}" --arg btime "$btime" \
  --arg cpumodel "$cpu_model" --arg cores "${cores:-}" \
  --arg l1 "${l1:-}" --arg l5 "${l5:-}" --arg l15 "${l15:-}" \
  --arg mt "${mem_total:-}" --arg ma "${mem_avail:-}" \
  --arg st "${swap_total:-}" --arg sf "${swap_free:-}" '
  def n:  try tonumber catch null;
  def nz: if . == "" then null else . end;
  def mb: if . == null then null else (. / 1024 | round) end;
  def pct($used; $total):
    if $used == null or $total == null or $total == 0 then null
    else ($used / $total * 100 | round) end;

  ($mt | n) as $mtot | ($ma | n) as $mav
  | ($st | n) as $stot | ($sf | n) as $sfree
  | {
      available: true,
      hostname: ($host | nz),
      os: { id: ($osid | nz), version: ($osver | nz), pretty: ($ospretty | nz) },
      kernel: ($kernel | nz),
      arch: ($arch | nz),
      uptime_seconds: ($up | n),
      boot_epoch: ($btime | n),
      cpu: {
        model: ($cpumodel | nz),
        cores: ($cores | n),
        load: [ $l1, $l5, $l15 | n ]
      },
      memory: {
        total_mb: ($mtot | mb),
        used_mb: (if $mtot == null or $mav == null then null else ($mtot - $mav) | mb end),
        available_mb: ($mav | mb),
        used_pct: (if $mtot == null or $mav == null then null else pct($mtot - $mav; $mtot) end)
      },
      swap: (
        if $stot == null then { total_mb: null, used_mb: null, used_pct: null }
        elif $stot == 0 then { total_mb: 0, used_mb: 0, used_pct: 0 }
        else {
          total_mb: ($stot | mb),
          used_mb: (if $sfree == null then null else ($stot - $sfree) | mb end),
          used_pct: (if $sfree == null then null else pct($stot - $sfree; $stot) end)
        } end
      )
    }
' || unavailable "falha ao montar a saída JSON"