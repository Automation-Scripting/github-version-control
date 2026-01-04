todo() {
  set -uo pipefail

  local owner
  owner="$(gh repo view --json owner -q .owner.login)"

  # milestone atual: primeiro project ABERTO cujo título parece vX.Y.Z
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
  title="$(gh project view "$proj" --owner "$owner" --format json | jq -r '.title')"

  echo "📌 Milestone (Project) aberto: $title (#$proj)"
  echo "   Patch: rel p #<issue>   | Minor: rel m   | Major: rel M"
  echo

  gh project item-list "$proj" --owner "$owner" --format json |
    jq -r '
      def ititle($i): ($i.title // $i.content.title // "Untitled");
      def inum($i):
        if ($i.content.number? != null) then
          ("#" + ($i.content.number|tostring))
        else
          "#?"
        end;
      def istatus($i): ($i.status // "No status");

      .items
      | if (length==0) then
          "   (sem itens)"
        else
          .[]
          | ("- [" + istatus(.) + "] " + inum(.) + "  " + ititle(.))
        end
    '
}