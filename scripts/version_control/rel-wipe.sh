rel_wipe() {
  emulate -L zsh
  set -euo pipefail

  # Repo atual
  local repo_full owner repo owner_type
  repo_full="$(gh repo view --json owner,name -q '.owner.login + "/" + .name')"
  owner="${repo_full%%/*}"
  repo="${repo_full##*/}"

  echo
  echo "🔎 Repositório alvo:"
  echo "   $repo_full"
  echo

  # Tipo do owner (User | Organization)
  owner_type="$(gh api "repos/$repo_full" -q '.owner.type')"
  echo "Owner type: $owner_type"
  echo

  local raw projects

  if [[ "$owner_type" == "Organization" ]]; then
    raw="$(
      gh api graphql -f query='
        query($login:String!) {
          organization(login:$login) {
            projectsV2(first: 100) {
              nodes {
                number
                title
                repositories(first: 100) {
                  nodes { nameWithOwner }
                }
              }
            }
          }
        }' -F login="$owner"
    )"

    projects="$(
      echo "$raw" | jq -c --arg REPO "$repo_full" '
        .data.organization.projectsV2.nodes[]
        | select(.repositories.nodes[].nameWithOwner? == $REPO)
      '
    )"
  else
    raw="$(
      gh api graphql -f query='
        query($login:String!) {
          user(login:$login) {
            projectsV2(first: 100) {
              nodes {
                number
                title
                repositories(first: 100) {
                  nodes { nameWithOwner }
                }
              }
            }
          }
        }' -F login="$owner"
    )"

    projects="$(
      echo "$raw" | jq -c --arg REPO "$repo_full" '
        .data.user.projectsV2.nodes[]
        | select(.repositories.nodes[].nameWithOwner? == $REPO)
      '
    )"
  fi

  if [[ -z "${projects:-}" ]]; then
    echo "✅ Nenhum Project associado a este repositório."
    return 0
  fi

  echo "📋 Projects associados a $repo_full:"
  echo
  echo "$projects" | jq -r '
    "• #\(.number)\t\(.title)\t(repos: \(.repositories.nodes[].nameWithOwner | join(",")))"
  '
  echo

  echo "⚠️  ATENÇÃO: estes Projects serão APAGADOS DEFINITIVAMENTE."
  echo -n "Digite exatamente DELETE para confirmar: "
  local confirm
  read -r confirm

  if [[ "$confirm" != "DELETE" ]]; then
    echo "❌ Cancelado. Nenhum project foi removido."
    return 1
  fi

  echo
  echo "🔥 Apagando Projects..."

  echo "$projects" | jq -r '.number' | while read -r n; do
    echo "  🗑️  Deletando project #$n"
    gh project delete "$n" --owner "$owner"
  done

  echo
  echo "✅ Limpeza concluída."
}