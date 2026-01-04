rel_init() {
  emulate -L zsh
  set -euo pipefail

  # Seu dispatcher provavelmente chama: rel init ...
  # Aqui assumimos que rel_init recebe todos os args APÓS "init".
  # Ex: rel init Item 01 -- Item 02
  # => rel_init "Item" "01" "--" "Item" "02"

  # ----------------------------
  # Owner / repo
  # ----------------------------
  local owner repo repo_full
  owner="$(gh repo view --json owner -q .owner.login)"
  repo="$(gh repo view --json name -q .name)"
  repo_full="$owner/$repo"

  # ----------------------------
  # GraphQL: lista projectsV2 do USER e filtra por repo linkado
  # (se você for org, a gente cai pro bloco org)
  # ----------------------------
  local owner_type
  owner_type="$(gh api "repos/$repo_full" -q '.owner.type')"  # "User" ou "Organization"

  local projects_json

  if [[ "$owner_type" == "Organization" ]]; then
    projects_json="$(
      gh api graphql -f query='
        query($login:String!) {
          organization(login:$login) {
            projectsV2(first: 100) {
              nodes {
                number
                title
                closed
                repositories(first: 100) { nodes { nameWithOwner } }
              }
            }
          }
        }' -F login="$owner" \
      | jq -c '.data.organization.projectsV2.nodes'
    )"
  else
    projects_json="$(
      gh api graphql -f query='
        query($login:String!) {
          user(login:$login) {
            projectsV2(first: 100) {
              nodes {
                number
                title
                closed
                repositories(first: 100) { nodes { nameWithOwner } }
              }
            }
          }
        }' -F login="$owner" \
      | jq -c '.data.user.projectsV2.nodes'
    )"
  fi

  # ----------------------------
  # Filtra: só milestones vX.Y.Z linkados ao repo atual
  # ----------------------------
  local repo_projects
  repo_projects="$(
    echo "$projects_json" | jq -c --arg REPO "$repo_full" '
      map(
        select(
          (.title // "") | test("^v[0-9]+\\.[0-9]+\\.[0-9]+$")
        )
        | select(
          (.repositories.nodes // []) | map(.nameWithOwner) | index($REPO)
        )
      )
    '
  )"

  # ----------------------------
  # Decide target_proj/target_title
  # ----------------------------
  local open_proj open_title
  open_proj="$(
    echo "$repo_projects" | jq -r '
      map(select(.closed == false))
      | sort_by(.number)
      | .[0].number // empty
    '
  )"
  open_title="$(
    echo "$repo_projects" | jq -r --argjson N "${open_proj:-0}" '
      map(select(.number == $N))
      | .[0].title // empty
    ' 2>/dev/null || true
  )"

  local last_title
  last_title="$(
    echo "$repo_projects" | jq -r '
      map(.title)
      | sort_by(sub("^v";"") | split(".") | map(tonumber))
      | last // empty
    '
  )"

  local target_proj="" target_title=""
  if [[ -n "${open_proj:-}" ]]; then
    target_proj="$open_proj"
    target_title="$open_title"
    echo "Project aberto encontrado: $target_title (#$target_proj)"
  else
    if [[ -n "${last_title:-}" ]]; then
      # cria próximo PATCH
      local base major_i minor_i patch_i
      base="${last_title#v}"
      IFS='.' read -r major_i minor_i patch_i <<< "$base"
      target_title="v${major_i}.${minor_i}.$((patch_i + 1))"
    else
      target_title="v0.0.1"
    fi

    echo "Criando Project (milestone): $target_title"

    target_proj="$(
      gh project create --owner "$owner" --title "$target_title" --format json |
        jq -r '.number'
    )"

    # linka ao repo (pra aparecer na aba Projects do repo)
    gh project link "$target_proj" --owner "$owner" --repo "$repo_full" >/dev/null
    echo "Project associado ao repositório: $repo_full"
    echo "Project criado: $target_title (#$target_proj)"
  fi

  # ----------------------------
  # Criar itens (separador: --, sem aspas)
  # Uso: rel init Item 01 -- Item 02 -- Item 03
  # Aqui rel_init recebe os tokens dos itens diretamente (não recebe "init")
  # ----------------------------
  if [[ "$#" -ge 1 ]]; then
    echo "Criando itens (separador: --):"

    local sep="--"
    local parts=()
    local buf=""

    local tok
    for tok in "$@"; do
      if [[ "$tok" == "$sep" ]]; then
        parts+=("$buf")
        buf=""
      else
        buf="${buf:+$buf }$tok"
      fi
    done
    parts+=("$buf")

    local part t issue_url
    for part in "${parts[@]}"; do
      t="$(echo "$part" | xargs)"
      [[ -z "$t" ]] && continue

      issue_url="$(
        gh issue create \
          --repo "$repo_full" \
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
}