todo() {
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

  echo "📌 Project aberto: $title (#$proj)"
  echo

  # tenta achar field Status pra mostrar em cada item (se existir)
  local status_field_id
  status_field_id="$(
    gh project field-list "$proj" --owner "$owner" --format json |
      jq -r '.fields[] | select(.name=="Status") | .id' | head -n1 || true
  )"

  # lista itens
    gh project item-list "$proj" --owner "$owner" --format json |
    jq -r --arg STATUS_ID "${status_field_id:-}" '
        def statusOf($item):
        if ($STATUS_ID|length) == 0 then
            ""
        else
            (
            ($item.fieldValues // [])
            | map(select(.field.id? == $STATUS_ID))
            | .[0].name? // .[0].value? // ""
            )
        end;

        .items
        | if (length==0) then
            "   (sem itens)"
        else
            .[]
            | ("- " + (statusOf(.) | if .=="" then "" else "["+.+"] " end)
            + (.title // .content.title // "Untitled"))
        end
    '
}