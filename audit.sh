#!/usr/bin/env bash
#
# audit.sh — orquestrador do server-audit
#
# Fluxo:
#   1. executa cada coletor em collectors/*.sh (cada um emite um objeto JSON)
#   2. junta as saídas em um único estado novo
#   3. compara com o estado anterior (state/<host>.json)
#   4. gera o relatório Markdown em reports/<host>/
#   5. grava o estado novo (por último, só se o relatório foi gerado)
#
# Códigos de saída:
#   0  relatório gerado, nenhum problema na execução
#   1  erro fatal (relatório não gerado)
#   2  relatório gerado, mas algum coletor ou a comparação falhou
#
# Requisitos: Bash >= 5.0, jq >= 1.6, flock e timeout (util-linux/coreutils).

set -uo pipefail
umask 077   # relatórios e estado contêm IPs, portas e usuários

readonly VERSION="0.1.0"
readonly STATE_SCHEMA=1

if (( BASH_VERSINFO[0] < 5 )); then
  echo "audit.sh: requer Bash 5.0 ou superior (encontrado ${BASH_VERSION})" >&2
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
readonly ROOT_DIR
readonly COLLECTORS_DIR="$ROOT_DIR/collectors"
readonly LIB_DIR="$ROOT_DIR/lib"
readonly STATE_DIR="$ROOT_DIR/state"
readonly REPORTS_DIR="$ROOT_DIR/reports"
readonly LOGS_DIR="$ROOT_DIR/logs"
readonly THRESHOLDS_FILE="$ROOT_DIR/config/thresholds.conf"

# ---------------------------------------------------------------------------
# Log
# ---------------------------------------------------------------------------

HOST=""
LOG_FILE=""

log() {
  local level="$1"; shift
  local line
  printf -v line '%s [%s] [%s] %s' "$(date -Iseconds)" "$level" "${HOST:-?}" "$*"
  printf '%s\n' "$line" >&2
  if [[ -n $LOG_FILE ]]; then
    printf '%s\n' "$line" >>"$LOG_FILE"
  fi
  return 0
}

die() {
  log ERROR "$*"
  exit 1
}

usage() {
  cat <<EOF
Uso: ./audit.sh [opções]

Opções:
  --host NOME       nome usado em state/ e reports/ (padrão: hostname -s)
  --only a,b,c      executa somente os coletores indicados
  --dry-run         imprime o relatório na saída padrão; não grava relatório,
                    estado nem log
  --version         mostra a versão
  -h, --help        mostra esta ajuda

Variáveis de ambiente:
  COLLECTOR_TIMEOUT  tempo limite por coletor, em segundos (padrão: 30)
EOF
}

usage_error() {
  echo "audit.sh: $*" >&2
  usage >&2
  exit 1
}

# ---------------------------------------------------------------------------
# Argumentos
# ---------------------------------------------------------------------------

ONLY=""
DRY_RUN=0

while (( $# > 0 )); do
  case "$1" in
    --host)
      (( $# >= 2 )) || usage_error "--host requer um valor"
      HOST="$2"; shift 2 ;;
    --host=*)
      HOST="${1#*=}"; shift ;;
    --only)
      (( $# >= 2 )) || usage_error "--only requer um valor"
      ONLY="$2"; shift 2 ;;
    --only=*)
      ONLY="${1#*=}"; shift ;;
    --dry-run)
      DRY_RUN=1; shift ;;
    --version)
      echo "server-audit $VERSION"; exit 0 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      usage_error "opção desconhecida: $1" ;;
  esac
done

# ---------------------------------------------------------------------------
# Pré-requisitos
# ---------------------------------------------------------------------------

missing=()
for cmd in jq flock timeout date hostname mktemp; do
  command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
done
(( ${#missing[@]} == 0 )) || die "dependências ausentes: ${missing[*]}"

if [[ -z $HOST ]]; then
  HOST="$(hostname -s)"
fi
[[ $HOST =~ ^[A-Za-z0-9._-]+$ && $HOST != "." && $HOST != ".." ]] \
  || die "nome de servidor inválido: '$HOST' (use letras, números, '.', '_' ou '-')"

COLLECTOR_TIMEOUT="${COLLECTOR_TIMEOUT:-30}"
[[ $COLLECTOR_TIMEOUT =~ ^[0-9]+$ && $COLLECTOR_TIMEOUT -gt 0 ]] \
  || die "COLLECTOR_TIMEOUT deve ser um inteiro positivo"

if (( EUID == 0 )); then
  log WARN "executando como root; o projeto foi pensado para rodar como usuário comum"
fi

TMP_DIR="$(mktemp -d)" || die "não foi possível criar diretório temporário"
readonly TMP_DIR
trap 'rm -rf "$TMP_DIR"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# ---------------------------------------------------------------------------
# Limites de severidade (config/thresholds.conf sobrescreve os padrões)
# ---------------------------------------------------------------------------

set -a
DISK_WARN_PCT=80
DISK_CRIT_PCT=90
INODE_WARN_PCT=80
INODE_CRIT_PCT=90
MEM_WARN_PCT=85
UPDATES_WARN_COUNT=1
if [[ -r $THRESHOLDS_FILE ]]; then
  # shellcheck source=/dev/null
  source "$THRESHOLDS_FILE"
fi
AUDIT_HOST="$HOST"
set +a

# ---------------------------------------------------------------------------
# Bibliotecas
# ---------------------------------------------------------------------------

for lib in compare render; do
  lib_file="$LIB_DIR/$lib.sh"
  [[ -r $lib_file ]] || die "biblioteca ausente: $lib_file"
  # shellcheck source=/dev/null
  source "$lib_file"
done
declare -F compare_states >/dev/null || die "lib/compare.sh não define compare_states"
declare -F render_report  >/dev/null || die "lib/render.sh não define render_report"

# ---------------------------------------------------------------------------
# Diretórios, log em arquivo e trava de execução
# ---------------------------------------------------------------------------

STATE_FILE="$STATE_DIR/$HOST.json"
REPORT_DIR="$REPORTS_DIR/$HOST"

if (( ! DRY_RUN )); then
  mkdir -p "$STATE_DIR" "$REPORT_DIR" "$LOGS_DIR" \
    || die "não foi possível criar state/, reports/ ou logs/"
  LOG_FILE="$LOGS_DIR/audit.log"

  # Evita duas execuções simultâneas para o mesmo servidor (timer + manual).
  exec 9>"$STATE_DIR/.$HOST.lock"
  flock -n 9 || die "já existe uma execução em andamento para '$HOST'"
fi

# ---------------------------------------------------------------------------
# Seleção dos coletores (descobertos em collectors/*.sh)
# ---------------------------------------------------------------------------

shopt -s nullglob
available=()
for f in "$COLLECTORS_DIR"/*.sh; do
  available+=("$(basename "$f" .sh)")
done
shopt -u nullglob
(( ${#available[@]} > 0 )) || die "nenhum coletor encontrado em $COLLECTORS_DIR"

COLLECTORS=("${available[@]}")
if [[ -n $ONLY ]]; then
  IFS=',' read -r -a COLLECTORS <<<"$ONLY"
  for c in "${COLLECTORS[@]}"; do
    [[ " ${available[*]} " == *" $c "* ]] || die "coletor desconhecido: '$c'"
  done
fi

# ---------------------------------------------------------------------------
# Execução de um coletor
#   - saída esperada: um objeto JSON na saída padrão
#   - qualquer falha vira {"available": false, "error": "..."} e não
#     interrompe os demais coletores
# ---------------------------------------------------------------------------

run_collector() {
  local name="$1"
  local script="$COLLECTORS_DIR/$name.sh"
  local out="$TMP_DIR/$name.json"
  local err="$TMP_DIR/$name.err"
  local reason="" rc=0 line

  if [[ ! -x $script ]]; then
    reason="script não é executável"
  else
    timeout --kill-after=5 "$COLLECTOR_TIMEOUT" "$script" >"$out" 2>"$err" </dev/null
    rc=$?
    case $rc in
      0)   ;;
      124) reason="tempo limite excedido (${COLLECTOR_TIMEOUT}s)" ;;
      *)   reason="terminou com código $rc" ;;
    esac
  fi

  if [[ -z $reason ]] && ! jq -e 'type == "object"' "$out" >/dev/null 2>&1; then
    reason="a saída não é um objeto JSON válido"
  fi

  if [[ -n $reason ]]; then
    log ERROR "coletor '$name' falhou: $reason"
    if [[ -s $err ]]; then
      while IFS= read -r line; do
        log ERROR "  [$name] $line"
      done < <(head -n 3 "$err")
    fi
    jq -n --arg error "$reason" '{available: false, error: $error}' >"$out"
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Coleta e montagem do estado novo
# ---------------------------------------------------------------------------

NEW_STATE="$TMP_DIR/state.new.json"
problems=0
failed=()

jq -n \
  --argjson schema "$STATE_SCHEMA" \
  --arg host "$HOST" \
  --arg ts "$(date -Iseconds)" \
  '{schema: $schema, hostname: $host, collected_at: $ts}' >"$NEW_STATE" \
  || die "falha ao iniciar o estado"

log INFO "iniciando auditoria (${#COLLECTORS[@]} coletores)"

for name in "${COLLECTORS[@]}"; do
  if ! run_collector "$name"; then
    failed+=("$name")
    problems=1
  fi
  jq --arg k "$name" --slurpfile v "$TMP_DIR/$name.json" '.[$k] = $v[0]' \
    "$NEW_STATE" >"$NEW_STATE.tmp" \
    && mv "$NEW_STATE.tmp" "$NEW_STATE" \
    || die "falha ao incorporar a saída do coletor '$name' ao estado"
done

failed_json="$(jq -nc '$ARGS.positional' --args "${failed[@]}")"
jq --argjson f "$failed_json" '.failed_collectors = $f' "$NEW_STATE" >"$NEW_STATE.tmp" \
  && mv "$NEW_STATE.tmp" "$NEW_STATE" \
  || die "falha ao registrar coletores com erro"

# ---------------------------------------------------------------------------
# Comparação com o estado anterior
#   compare_states ANTERIOR NOVO  → Markdown das mudanças na saída padrão
#   (seções em que algum dos lados tem "available": false devem ser ignoradas
#   pela comparação, para não gerar mudanças falsas)
# ---------------------------------------------------------------------------

CHANGES_FILE="$TMP_DIR/changes.md"
has_baseline=0

if [[ -f $STATE_FILE ]]; then
  if jq -e 'type == "object"' "$STATE_FILE" >/dev/null 2>&1; then
    has_baseline=1
  else
    log WARN "estado anterior inválido ($STATE_FILE); tratando como primeira execução"
  fi
fi

if (( has_baseline )); then
  if compare_states "$STATE_FILE" "$NEW_STATE" >"$CHANGES_FILE" 2>"$TMP_DIR/compare.err"; then
    if ! grep -q '[^[:space:]]' "$CHANGES_FILE"; then
      echo "Nenhuma mudança relevante desde o relatório anterior." >"$CHANGES_FILE"
    fi
  else
    log ERROR "falha ao comparar com o estado anterior"
    head -n 3 "$TMP_DIR/compare.err" | while IFS= read -r line; do log ERROR "  [compare] $line"; done
    echo "Não foi possível comparar com o relatório anterior (erro na comparação)." >"$CHANGES_FILE"
    problems=1
  fi
else
  echo "Sem base de comparação (primeira execução para este servidor)." >"$CHANGES_FILE"
fi

# ---------------------------------------------------------------------------
# Relatório
#   render_report HOST ARQUIVO_ESTADO_NOVO ARQUIVO_MUDANCAS → Markdown
# ---------------------------------------------------------------------------

REPORT_TMP="$TMP_DIR/report.md"
render_report "$HOST" "$NEW_STATE" "$CHANGES_FILE" >"$REPORT_TMP" \
  || die "falha ao gerar o relatório; estado anterior preservado"
[[ -s $REPORT_TMP ]] || die "o relatório gerado está vazio; estado anterior preservado"

if (( DRY_RUN )); then
  cat "$REPORT_TMP"
  log INFO "dry-run concluído (nada foi gravado)"
  exit $(( problems > 0 ? 2 : 0 ))
fi

day="$(date +%F)"
report_path="$REPORT_DIR/$day.md"
if [[ -e $report_path ]]; then
  report_path="$REPORT_DIR/${day}_$(date +%H%M).md"
  if [[ -e $report_path ]]; then
    report_path="$REPORT_DIR/${day}_$(date +%H%M%S).md"
  fi
fi

# cp + mv no mesmo diretório: a gravação final é atômica
cp "$REPORT_TMP" "$report_path.tmp" && mv "$report_path.tmp" "$report_path" \
  || die "não foi possível gravar o relatório em $report_path"

# O estado só é atualizado depois de o relatório existir.
cp "$NEW_STATE" "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE" \
  || die "relatório gravado, mas falhou ao gravar o estado em $STATE_FILE"

if (( ${#failed[@]} > 0 )); then
  log WARN "concluído com falhas nos coletores: ${failed[*]}"
fi
log INFO "relatório gerado: ${report_path#"$ROOT_DIR"/}"

exit $(( problems > 0 ? 2 : 0 ))