todo2() {
  set -uo pipefail

  local owner
  owner="$(gh repo view --json owner -q .owner.login)"

  # pega o primeiro project ABERTO cujo título parece "v1.2.3"
  local proj
  proj="$(
    gh project list --owner "$owner" --format json |
      jq -r '
        .projects
        | map(select(.closed == false))
        | map(select(.title | test("^v[0-9]+\\.[0-9]+\\.[0-9]+$")))
        | sort_by(.number)
        | .[0].number // empty
      '
  )"

  if [ -z "${proj:-}" ]; then
    echo "Nenhum Project aberto com título tipo vX.Y.Z encontrado para $owner."
    return 0
  fi

  local title
  title="$(
    gh project view "$proj" --owner "$owner" --format json |
      jq -r '.title'
  )"


  # lista itens
    gh project item-list "$proj" --owner "$owner" --format json 
}