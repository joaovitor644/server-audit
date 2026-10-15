#!/usr/bin/env bash
#
# collectors/network.sh — interfaces, endereços, rotas, gateway, DNS e portas
# TCP/UDP em escuta.
#
# Contrato dos coletores:
#   - emite UM objeto JSON na saída padrão
#   - somente leitura: só consulta (`ip`, `ss`, `resolvectl`, resolv.conf)
#   - dependência obrigatória ausente => {"available": false, "error": "..."}
#     e saída 0
#
# Detalhes:
#   - `lo` e interfaces `veth*` (criadas e destruídas pelo Docker a cada
#     container) ficam de fora, para não gerar "mudanças" sem sentido;
#   - só endereços de escopo global entram (IPv6 link-local fe80:: é ignorado);
#   - sem root, `ss` não mostra o processo dono da porta; só a porta.
#
# Saída:
#   {
#     "available": true,
#     "interfaces": [ { "name": "eth0", "state": "up", "addresses": ["192.168.1.10/24"] } ],
#     "default_routes": [ { "family": "inet", "gateway": "192.168.1.1", "dev": "eth0", "metric": 100 } ],
#     "routes": [ { "dst": "192.168.1.0/24", "gateway": null, "dev": "eth0" } ],
#     "dns": { "servers": ["192.168.1.1"], "source": "resolvectl" },
#     "listening": [ { "proto": "tcp", "addr": "0.0.0.0", "port": 22, "scope": "all" } ]
#   }
#
# scope: "all" (todas as interfaces), "local" (somente loopback) ou "specific".

set -uo pipefail
export LC_ALL=C

unavailable() {
  printf '{"available": false, "error": "%s"}\n' "$1"
  exit 0
}

command -v jq >/dev/null 2>&1 || unavailable "jq não encontrado"
command -v ip >/dev/null 2>&1 || unavailable "ip (iproute2) não encontrado"
ip -j addr show >/dev/null 2>&1 || unavailable "iproute2 sem suporte a JSON (ip -j)"

ipj() { ip -j "$@" 2>/dev/null; }

interfaces="$(ipj addr show | jq -sc '
  (.[0] // [])
  | map(select(.ifname != "lo" and (.ifname | startswith("veth") | not))
        | { name: .ifname,
            state: ((.operstate // "unknown") | ascii_downcase),
            addresses: [ .addr_info[]? | select(.scope == "global") | "\(.local)/\(.prefixlen)" ] })
')" || unavailable "falha ao ler interfaces"
[[ -n $interfaces ]] || interfaces='[]'

default_v4="$(ipj -4 route show default | jq -sc '(.[0] // []) | map({ family: "inet",  gateway, dev, metric })')"
default_v6="$(ipj -6 route show default | jq -sc '(.[0] // []) | map({ family: "inet6", gateway, dev, metric })')"
routes="$(ipj -4 route show | jq -sc '(.[0] // []) | map({ dst, gateway, dev })')"
[[ -n $default_v4 ]] || default_v4='[]'
[[ -n $default_v6 ]] || default_v6='[]'
[[ -n $routes ]]     || routes='[]'

# DNS: resolvectl (systemd-resolved) mostra os servidores reais; o resolv.conf
# do systemd-resolved só aponta para o stub local (127.0.0.53).
dns_servers=""
dns_source=""
if command -v resolvectl >/dev/null 2>&1; then
  dns_servers="$(resolvectl dns 2>/dev/null | sed 's/^[^:]*://' | tr ' ' '\n' \
    | grep -E '^[0-9a-fA-F:.]+$' | sort -u)"
  [[ -n $dns_servers ]] && dns_source="resolvectl"
fi
if [[ -z $dns_servers && -r /etc/resolv.conf ]]; then
  dns_servers="$(awk '$1 == "nameserver" { print $2 }' /etc/resolv.conf | sort -u)"
  dns_source="resolv.conf"
fi

# Portas em escuta: proto <TAB> endereço <TAB> porta
have_listen=false
listen_tsv=""
if command -v ss >/dev/null 2>&1; then
  have_listen=true
  listen_tsv="$(ss -tuln 2>/dev/null | awk '
    NR > 1 && NF >= 5 {
      n = split($5, p, ":")
      port = p[n]
      addr = substr($5, 1, length($5) - length(port) - 1)
      printf "%s\t%s\t%s\n", $1, addr, port
    }
  ' | sort -u)"
fi

jq -n -c \
  --argjson interfaces "$interfaces" \
  --argjson d4 "$default_v4" --argjson d6 "$default_v6" \
  --argjson routes "$routes" \
  --arg dns "$dns_servers" --arg dnssrc "$dns_source" \
  --arg listen "$listen_tsv" --argjson have_listen "$have_listen" '
  def lines: split("\n") | map(select(length > 0));
  {
    available: true,
    interfaces: $interfaces,
    default_routes: ($d4 + $d6),
    routes: $routes,
    dns: {
      servers: ($dns | lines | sort),
      source: (if $dnssrc == "" then null else $dnssrc end)
    },
    listening: (
      if $have_listen | not then null
      else
        $listen | lines
        | map(split("\t") as $f
              | { proto: $f[0],
                  addr: $f[1],
                  port: ($f[2] | try tonumber catch null),
                  scope: (
                    if ($f[1] | IN("0.0.0.0", "[::]", "*", "::")) then "all"
                    elif (($f[1] | startswith("127.")) or $f[1] == "[::1]") then "local"
                    else "specific" end
                  ) })
        | map(select(.port != null))
        | sort_by(.port, .proto)
      end
    )
  }
' || unavailable "falha ao montar a saída JSON"