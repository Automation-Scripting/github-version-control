rel_init() {
  emulate -L zsh
  set -euo pipefail
  
  local mode="$1"
  local ref="${2:-}"

  # ----------------------------
  # Owner / repo
  # ----------------------------
  local owner repo
  owner="$(gh repo view --json owner -q .owner.login)"
  repo="$(gh repo view --json name -q .name)"


  # ----------------------------
  # INIT: rel init Item1 -- Item2 -- ...
  # Regras:
  # - Se existir Project aberto vX.Y.Z => reutiliza e só cria itens
  # - Se existir algum vX.Y.Z fechado (e nenhum aberto) => cria PRÓXIMO PATCH vX.Y.(Z+1)
  # - Se não existir nenhum => cria v0.0.1
  # ----------------------------
  if [ "$mode" = "init" ]; then
  set -euo pipefail

  local repo_full repo_projects_prefix
  repo_full="$owner/$repo"
  repo_projects_prefix="https://github.com/${repo_full}/projects/"

  # lista só os números (não confiamos em title no list)
  local proj_nums
  proj_nums="$(
    gh project list --owner "$owner" --format json |
      jq -r '.projects[].number' 2>/dev/null || true
  )"

  local open_proj="" open_title=""
  local last_title=""

  local n
  while IFS= read -r n; do
    [ -z "$n" ] && continue

    local vjson title closed url
    vjson="$(gh project view "$n" --owner "$owner" --format json 2>/dev/null || true)"
    [ -z "$vjson" ] && continue

    title="$(echo "$vjson" | jq -r '.title // empty')"
    closed="$(echo "$vjson" | jq -r '.closed')"
    url="$(echo "$vjson" | jq -r '.url // empty')"

    # FILTRO CRÍTICO: só projects do REPO (não do usuário)
    # repo projects: https://github.com/<owner>/<repo>/projects/<n>
    case "$url" in
      ${repo_projects_prefix}*) ;;
      *) continue ;;
    esac

    # só consideramos milestone no formato vX.Y.Z
    if echo "$title" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
      # atualiza last_title (maior semver)
      if [ -z "$last_title" ]; then
        last_title="$title"
      else
        last_title="$(printf "%s\n%s\n" "$last_title" "$title" | sort -V | tail -n1)"
      fi

      # pega o primeiro aberto
      if [ "$closed" = "false" ] && [ -z "$open_proj" ]; then
        open_proj="$n"
        open_title="$title"
      fi
    fi
  done <<< "$proj_nums"

  local target_proj="" target_title="" created_new="no"

  if [ -n "$open_proj" ]; then
    target_proj="$open_proj"
    target_title="$open_title"
    echo "📌 Project aberto encontrado: $target_title (#$target_proj)"
  else
    if [ -n "$last_title" ]; then
      # existe milestone fechado: cria próximo PATCH
      local base major_i minor_i patch_i
      base="${last_title#v}"
      IFS='.' read -r major_i minor_i patch_i <<< "$base"
      target_title="v${major_i}.${minor_i}.$((patch_i+1))"
    else
      target_title="v0.0.1"
    fi

    echo "Criando Project (milestone): $target_title"

    target_proj="$(
      gh project create --owner "$owner" --title "$target_title" --format json |
        jq -r '.number'
    )"
    created_new="yes"

    gh project link "$target_proj" --owner "$owner" --repo "$owner/$repo" >/dev/null
    echo "Project associado ao repositório: $owner/$repo"
    echo "Project criado: $target_title (#$target_proj)"
  fi

  # criar itens (separador: --, sem aspas)
  if [ "$#" -ge 2 ]; then
    echo "Criando itens (separador: --):"

    local sep="--"
    local parts=()
    local buf=""
    local started=0

    for tok in "$@"; do
      if [ $started -eq 0 ]; then
        started=1
        continue  # pula "init"
      fi

      if [ "$tok" = "$sep" ]; then
        parts+=("$buf")
        buf=""
      else
        if [ -z "$buf" ]; then
          buf="$tok"
        else
          buf="$buf $tok"
        fi
      fi
    done
    parts+=("$buf")

    for part in "${parts[@]}"; do
      local t issue_url
      t="$(echo "$part" | xargs)"
      [ -z "$t" ] && continue

      issue_url="$(
        gh issue create \
          --repo "$owner/$repo" \
          --title "$t" \
          --body "Planned for $target_title" \
          --assignee @me
      )"

      if [[ -z "${issue_url:-}" || "${issue_url:-}" != https://github.com/*/issues/* ]]; then
        echo "  falhou ao criar issue: $t"
        echo "     saída: ${issue_url:-<vazio>}"
        continue
      fi

      gh project item-add "$target_proj" --owner "$owner" --url "$issue_url" >/dev/null
      echo "  • criado: $t"
    done
  else
    echo "(sem itens) você pode criar depois."
  fi

    return 0
  fi
}