#!/usr/bin/env bash
#
# collectors/storage.sh — filesystems, uso de disco e inodes, montagens
# somente leitura e dispositivos de armazenamento.
#
# Contrato dos coletores:
#   - emite UM objeto JSON na saída padrão
#   - somente leitura: não altera nada no sistema
#   - ferramenta obrigatória ausente => {"available": false, "error": "..."}
#     e código de saída 0
#
# Saída:
#   {
#     "available": true,
#     "filesystems": [
#       { "mount": "/", "device": "/dev/sda1", "fstype": "ext4",
#         "size_gb": 98.1, "used_gb": 41.2, "avail_gb": 52.9,
#         "used_pct": 44, "inode_used_pct": 5, "readonly": false }
#     ],
#     "devices": [ { "name": "sda", "size_bytes": 107374182400, "model": "..." } ]
#   }

set -uo pipefail
export LC_ALL=C

unavailable() {
  printf '{"available": false, "error": "%s"}\n' "$1"
  exit 0
}

command -v df >/dev/null 2>&1 || unavailable "df não encontrado"
command -v jq >/dev/null 2>&1 || unavailable "jq não encontrado"

# Pseudo-filesystems e camadas que só geram ruído no relatório.
exclude=(-x tmpfs -x devtmpfs -x squashfs -x overlay -x efivarfs -x ramfs)

# Filesystems: device, tipo, total, usado, disponível (KiB), uso %, ponto de montagem.
# O ponto de montagem é "o resto da linha", pois pode conter espaços.
fs_tsv="$(df -P -k -T "${exclude[@]}" 2>/dev/null | awk 'NR > 1 {
  mount = $7
  for (i = 8; i <= NF; i++) mount = mount " " $i
  pct = $6; gsub(/%/, "", pct)
  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", $1, $2, $3, $4, $5, pct, mount
}')"

# Uso de inodes por ponto de montagem ("-" em filesystems sem inodes fixos, como btrfs).
inode_tsv="$(df -P -i "${exclude[@]}" 2>/dev/null | awk 'NR > 1 {
  mount = $6
  for (i = 7; i <= NF; i++) mount = mount " " $i
  pct = $5; gsub(/%/, "", pct)
  printf "%s\t%s\n", mount, pct
}')"

# Pontos de montagem em modo somente leitura (o kernel escapa espaços como \040).
ro_list=""
if [[ -r /proc/self/mounts ]]; then
  ro_list="$(awk '{
    n = split($4, o, ",")
    for (i = 1; i <= n; i++) if (o[i] == "ro") { m = $2; gsub(/\\040/, " ", m); print m; break }
  }' /proc/self/mounts)"
fi

# Discos físicos/virtuais (opcional: sem lsblk a lista fica vazia).
devices_json='[]'
if command -v lsblk >/dev/null 2>&1; then
  devices_json="$(lsblk -J -d -b -o NAME,TYPE,SIZE,MODEL 2>/dev/null | jq -c '
    [ .blockdevices[]?
      | select(.type == "disk" and (.name | startswith("zram") | not))
      | { name,
          size_bytes: (.size | tonumber),
          model: (.model // null | if . then gsub("^\\s+|\\s+$"; "") else . end) } ]
  ' 2>/dev/null)"
  [[ -n $devices_json ]] || devices_json='[]'
fi

jq -n -c \
  --arg fs "$fs_tsv" \
  --arg inodes "$inode_tsv" \
  --arg ro "$ro_list" \
  --argjson devices "$devices_json" '
  def lines: split("\n") | map(select(length > 0));
  def num: try tonumber catch null;
  def gb: if . == null then null else ((. / 1048576 * 10) | round) / 10 end;

  (reduce (($inodes | lines)[] | split("\t")) as $r ({}; .[$r[0]] = ($r[1] | num))) as $im
  | ($ro | lines) as $rol
  | {
      available: true,
      filesystems: (
        $fs | lines
        | map(split("\t") | {
            mount:    .[6],
            device:   .[0],
            fstype:   .[1],
            size_gb:  (.[2] | num | gb),
            used_gb:  (.[3] | num | gb),
            avail_gb: (.[4] | num | gb),
            used_pct: (.[5] | num)
          })
        | map(. + {
            inode_used_pct: $im[.mount],
            readonly: (.mount as $m | ($rol | index($m)) != null)
          })
        | sort_by(.mount)
      ),
      devices: $devices
    }
' || unavailable "falha ao montar a saída JSON"
