rel_init() {
  emulate -L zsh
  set -euo pipefail

  # ----------------------------
  # Owner / repo
  # ----------------------------
  local owner repo repo_full
  owner="$(gh repo view --json owner -q .owner.login)"
  repo="$(gh repo view --json name -q .name)"
  repo_full="$owner/$repo"

  # ----------------------------
  # Detect owner type (User vs Organization)
  # ----------------------------
  local owner_type
  owner_type="$(gh api "repos/$repo_full" -q '.owner.type')"  # "User" | "Organization"

  # ----------------------------
  # GraphQL: list projectsV2 + linked repositories
  # ----------------------------
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
  # Filter: only dev lines vX.Y.x linked to THIS repo
  # ----------------------------
  local repo_projects
  repo_projects="$(
    echo "$projects_json" | jq -c --arg REPO "$repo_full" '
      map(
        select((.title // "") | test("^v[0-9]+\\.[0-9]+\\.x$"))
        | select((.repositories.nodes // []) | map(.nameWithOwner) | index($REPO))
      )
    '
  )"

  # ----------------------------
  # Pick open dev line first (vX.Y.x)
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

  # ----------------------------
  # Find last dev line title (max vX.Y.x), even if closed
  # ----------------------------
  local last_title
  last_title="$(
    echo "$repo_projects" | jq -r '
      map(.title)
      | sort_by(
          sub("^v";"")
          | sub("\\.x$";"")
          | split(".")
          | map(tonumber)
        )
      | last // empty
    '
  )"

  # ----------------------------
  # Decide target project
  # ----------------------------
  local target_proj="" target_title=""
  if [[ -n "${open_proj:-}" ]]; then
    target_proj="$open_proj"
    target_title="$open_title"
    echo " Open dev line found: $target_title (#$target_proj)"
  else
    if [[ -n "${last_title:-}" ]]; then
      # last_title is like vX.Y.x -> next is vX.(Y+1).x
      local base major_i minor_i
      base="${last_title#v}"
      base="${base%.x}"
      IFS='.' read -r major_i minor_i <<< "$base"
      target_title="v${major_i}.$((minor_i + 1)).x"
    else
      target_title="v0.0.x"
    fi

    echo "Creating dev line project: $target_title"

    target_proj="$(
      gh project create --owner "$owner" --title "$target_title" --format json |
        jq -r '.number'
    )"

    gh project link "$target_proj" --owner "$owner" --repo "$repo_full" >/dev/null
    echo "Project linked to repo: $repo_full"
    echo "Project created: $target_title (#$target_proj)"
  fi

  # ----------------------------
  # Create items (separator: --, no quoting)
  # Usage: rel init Item 01 -- Item 02 -- Item 03
  # rel_init receives tokens AFTER "init"
  # ----------------------------
  if [[ "$#" -ge 1 ]]; then
    echo "Creating items:"

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

      # compute planned release milestone from target_title (vX.Y.x -> vX.(Y+1))
      local planned_release=""
      if [[ "${target_title:-}" =~ '^v([0-9]+)\.([0-9]+)\.x$' ]]; then
        local maj="${match[1]}"
        local min="${match[2]}"
        planned_release="v${maj}.$((min + 1))"
      else
        planned_release="$target_title"
      fi

      issue_url="$(
        gh issue create \
          --repo "$repo_full" \
          --title "$t" \
          --body "Planned for release ${planned_release}" \
          --assignee @me
      )"

      if [[ -z "${issue_url:-}" || "${issue_url:-}" != https://github.com/*/issues/* ]]; then
        echo "  failed to create issue: $t"
        echo "     output: ${issue_url:-<empty>}"
        continue
      fi

      gh project item-add "$target_proj" --owner "$owner" --url "$issue_url" >/dev/null
      echo "  • created: $t"
    done
  else
    echo "(no items) you can create them later."
  fi
}