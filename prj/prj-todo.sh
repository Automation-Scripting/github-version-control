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

  local use_color=0
  [[ -t 1 ]] && use_color=1

  gh project item-list "$proj" --owner "$owner" --format json |
    jq -r --argjson COLOR "$use_color" '
      def ititle($i): ($i.title // $i.content.title // "Untitled");

      def inum($i):
        if ($i.content.number? != null) then
          ("#" + ($i.content.number|tostring))
        else
          "#?"
        end;

      def inum_sort($i):
        if ($i.content.number? != null) then ($i.content.number|tonumber) else 999999 end;

      def istatus($i): ($i.status // "No status");
      def s($i): (istatus($i) | ascii_downcase);

      # ordem desejada
      def status_rank($i):
        if   s($i) == "done"        then 0
        elif s($i) == "ready"       then 1
        elif s($i) == "in progress" then 2
        elif s($i) == "todo"        then 3
        else 9 end;

      # cores por status (ANSI)
      def status_fmt($i):
        if $COLOR != 1 then
          istatus($i)
        elif s($i) == "done" then
          "\u001b[31m" + istatus($i) + "\u001b[0m"   # vermelho
        elif s($i) == "ready" then
          "\u001b[32m" + istatus($i) + "\u001b[0m"   # verde
        elif s($i) == "in progress" then
          "\u001b[33m" + istatus($i) + "\u001b[0m"   # amarelo
        elif s($i) == "todo" then
          "\u001b[34m" + istatus($i) + "\u001b[0m"   # azul
        else
          istatus($i)
        end;

      .items
      | if (length==0) then
          "   (no items)"
        else
          sort_by([ status_rank(.), inum_sort(.) ])
          | .[]
          | ("- [" + status_fmt(.) + "] " + inum(.) + "  " + ititle(.))
        end
    '
}