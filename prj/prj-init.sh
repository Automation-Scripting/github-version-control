rel_init() {
  emulate -L zsh
  set -euo pipefail

  # ----------------------------
  # Repo context
  # ----------------------------
  local owner repo repo_full
  owner="$(gh repo view --json owner -q .owner.login)"
  repo="$(gh repo view --json name -q .name)"
  repo_full="$owner/$repo"

  # Detect owner type (User | Organization)
  local owner_type
  owner_type="$(gh api "repos/$repo_full" -q '.owner.type')"  # "User" | "Organization"

  # ----------------------------
  # GraphQL: list Projects v2 + linked repositories (scoped to this owner)
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

  # Keep only projects linked to THIS repo (critical!)
  local linked
  linked="$(
    echo "$projects_json" | jq -c --arg REPO "$repo_full" '
      map(
        select((.repositories.nodes // []) | map(.nameWithOwner) | index($REPO))
      )
    '
  )"

  # ----------------------------
  # 1) Reuse an open dev line project: vX.Y.x
  # ----------------------------
  local open_proj open_title
  open_proj="$(
    echo "$linked" | jq -r '
      map(select(.closed == false))
      | map(select((.title // "") | test("^v[0-9]+\\.[0-9]+\\.x$")))
      | sort_by(.number)
      | .[0].number // empty
    '
  )"

  if [[ -n "${open_proj:-}" ]]; then
    open_title="$(
      echo "$linked" | jq -r --argjson N "$open_proj" '
        map(select(.number == $N)) | .[0].title // empty
      '
    )"
    echo "Open dev line found: $open_title (#$open_proj)"
    _rel_init__create_items "$repo_full" "$owner" "$open_proj" "$open_title" "$@"
    return 0
  fi

  # ----------------------------
  # 2) No open dev line → derive the next dev line from the repo's last semver tag
  #    Source of truth: git tags, not project names.
  # ----------------------------
  local last_tag
  last_tag="$(
    gh api "repos/$repo_full/tags" --paginate -q '.[].name' \
      | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' \
      | sort -V \
      | tail -n 1 || true
  )"
  [[ -z "${last_tag:-}" ]] && last_tag="v0.0.0"

  local base major minor patch
  base="${last_tag#v}"
  IFS='.' read -r major minor patch <<< "$base"

  # Candidate dev line title (same MAJOR.MINOR as last tag)
  local target_title="v${major}.${minor}.x"

  # If a project with that exact title already exists (closed or not), bump MINOR until free
  while echo "$linked" | jq -e --arg T "$target_title" 'any(.[]; (.title // "") == $T)' >/dev/null; do
    minor=$((minor + 1))
    target_title="v${major}.${minor}.x"
  done

  echo "Creating dev line project: $target_title"

  local target_proj
  target_proj="$(
    gh project create --owner "$owner" --title "$target_title" --format json \
      | jq -r '.number'
  )"

  gh project link "$target_proj" --owner "$owner" --repo "$repo_full" >/dev/null
  echo "Project linked to repo: $repo_full"
  echo "Project created: $target_title (#$target_proj)"

  _rel_init__create_items "$repo_full" "$owner" "$target_proj" "$target_title" "$@"
}

# Helper used by rel_init: create issues and add them to the project
_rel_init__create_items() {
  emulate -L zsh
  set -euo pipefail

  local repo_full="$1"
  local owner="$2"
  local proj_no="$3"
  local proj_title="$4"
  shift 4 || true

  if [[ "$#" -lt 1 ]]; then
    echo "(no items) you can create them later."
    return 0
  fi

  echo "Creating items:"

  # Compute planned release from dev line title:
  # vX.Y.x -> planned release vX.(Y+1)
  local planned_release="$proj_title"
  if [[ "$proj_title" =~ ^v([0-9]+)\.([0-9]+)\.x$ ]]; then
    local maj="${match[1]}"
    local min="${match[2]}"
    planned_release="v${maj}.$((min + 1))"
  fi

  local sep="--"
  local parts=() buf=""
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
        --body "Planned for release ${planned_release}." \
        --assignee @me
    )"

    if [[ -z "${issue_url:-}" || "${issue_url:-}" != https://github.com/*/issues/* ]]; then
      echo "  failed to create issue: $t"
      echo "     output: ${issue_url:-<empty>}"
      continue
    fi

    gh project item-add "$proj_no" --owner "$owner" --url "$issue_url" >/dev/null

    issue_no="${issue_url##*/}"
    rel_set_item_status "#$issue_no" "Todo"
    
    echo "  • created: $t"
  done
}