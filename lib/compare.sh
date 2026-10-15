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

_COMPARE_SECTIONS=(storage)

declare -A _COMPARE_TITLE=(
  [storage]="Armazenamento"
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
