#!/usr/bin/env bash
#
# collectors/docker.sh — containers, imagens, volumes e redes do Docker.
#
# Contrato dos coletores:
#   - emite UM objeto JSON na saída padrão
#   - somente leitura: só consulta (`docker info/ps/inspect/ls`)
#   - Docker não instalado => {"available": false, "reason": "não instalado"}
#   - Docker instalado mas inacessível (daemon parado, sem permissão) =>
#     {"available": false, "error": "..."}; o relatório sinaliza com 🟡
#
# Permissão: o usuário precisa conseguir rodar `docker ps`. Atenção: estar no
# grupo `docker` equivale a ter root na máquina. Avalie se compensa para o
# usuário de auditoria (veja a seção Permissões do README).
#
# Saída:
#   {
#     "available": true,
#     "version": "27.3.1",
#     "containers": [
#       { "name": "nginx", "image": "nginx:1.27", "state": "running",
#         "restart_count": 0, "restarting": false, "restart_policy": "unless-stopped",
#         "exit_code": 0, "health": null, "exited_ago_days": null }
#     ],
#     "images":   { "count": 5, "dangling": 1 },
#     "volumes":  { "count": 3, "dangling": 0 },
#     "networks": { "count": 4 }
#   }
#
# state segue o Docker: running, exited, restarting, paused, created, dead.
# health é healthy/unhealthy/starting, ou null se o container não tem healthcheck.
# exited_ago_days: há quantos dias um container parado terminou (null se está rodando).

set -uo pipefail
export LC_ALL=C

unavailable() {
  printf '{"available": false, "error": "%s"}\n' "$1"
  exit 0
}

command -v jq >/dev/null 2>&1 || unavailable "jq não encontrado"

if ! command -v docker >/dev/null 2>&1; then
  printf '{"available": false, "reason": "não instalado"}\n'
  exit 0
fi

if ! version="$(docker info --format '{{.ServerVersion}}' 2>&1)"; then
  if [[ ${version,,} == *"permission denied"* ]]; then
    unavailable "sem permissão para acessar o Docker (usuário fora do grupo docker?)"
  fi
  unavailable "daemon do Docker inacessível"
fi

ids=()
mapfile -t ids < <(docker ps -aq 2>/dev/null)

# Campos separados por '|' (nomes de container e de imagem não contêm '|').
rows=""
if (( ${#ids[@]} > 0 )); then
  rows="$(docker inspect --format \
    '{{.Name}}|{{.Config.Image}}|{{.State.Status}}|{{.RestartCount}}|{{.State.Restarting}}|{{.HostConfig.RestartPolicy.Name}}|{{.State.ExitCode}}|{{if .State.Health}}{{.State.Health.Status}}{{end}}|{{.State.FinishedAt}}' \
    "${ids[@]}" 2>/dev/null)"
fi

count() { "$@" 2>/dev/null | sort -u | grep -c .; }

images="$(count docker image ls -q)"
dangling_images="$(count docker image ls -q -f dangling=true)"
volumes="$(count docker volume ls -q)"
dangling_volumes="$(count docker volume ls -q -f dangling=true)"
networks="$(count docker network ls -q)"

jq -n -c \
  --argjson now "$(date +%s)" \
  --arg version "$version" --arg rows "$rows" \
  --arg images "${images:-0}" --arg dimages "${dangling_images:-0}" \
  --arg volumes "${volumes:-0}" --arg dvolumes "${dangling_volumes:-0}" \
  --arg networks "${networks:-0}" '
  def lines: split("\n") | map(select(length > 0));
  def nz: if . == "" then null else . end;
  def num: try tonumber catch null;
  {
    available: true,
    version: ($version | nz),
    containers: (
      $rows | lines
      | map(split("|")
            | ((.[8] // "") | sub("\\.[0-9]+Z$"; "Z") | try fromdateiso8601 catch null) as $f
            | {
          name:           (.[0] | ltrimstr("/")),
          image:          .[1],
          state:          .[2],
          restart_count:  (.[3] | num),
          restarting:     (.[4] == "true"),
          restart_policy: (.[5] | nz),
          exit_code:      (.[6] | num),
          health:         (.[7] | nz),
          exited_ago_days: (if $f != null and $f > 0 and .[2] != "running"
                            then ((($now - $f) / 86400 | floor) | if . < 0 then 0 else . end)
                            else null end)
        })
      | sort_by(.name)
    ),
    images:   { count: ($images | num),  dangling: ($dimages | num) },
    volumes:  { count: ($volumes | num), dangling: ($dvolumes | num) },
    networks: { count: ($networks | num) }
  }
' || unavailable "falha ao montar a saída JSON"