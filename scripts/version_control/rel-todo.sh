todo() {
  emulate -L zsh
  set -euo pipefail

  local owner repo repo_full owner_type
  owner="$(gh repo view --json owner -q .owner.login)"
  repo="$(gh repo view --json name -q .name)"
  repo_full="$owner/$repo"

  owner_type="$(gh api "repos/$repo_full" -q '.owner.type')"  # User | Organization

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

  # only open dev lines vX.Y.x linked to this repo
  local proj title
  proj="$(
    echo "$projects_json" | jq -r --arg REPO "$repo_full" '
      map(
        select(.closed == false)
        | select((.title // "") | test("^v[0-9]+\\.[0-9]+\\.x$"))
        | select((.repositories.nodes // []) | map(.nameWithOwner) | index($REPO))
      )
      | sort_by(.number)
      | .[0].number // empty
    '
  )"

  if [[ -z "${proj:-}" ]]; then
    echo "No open dev line project (vX.Y.x) found for $repo_full."
    return 0
  fi

  title="$(gh project view "$proj" --owner "$owner" --format json | jq -r '.title')"

  echo "Open dev line (Project): $title (#$proj)"
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
          "   (no items)"
        else
          .[]
          | ("- [" + istatus(.) + "] " + inum(.) + "  " + ititle(.))
        end
    '
}