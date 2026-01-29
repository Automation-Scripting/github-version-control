rel_init() {
  emulate -L zsh
  set -u
  set -o pipefail

  local owner repo_full proj_no proj_title
  IFS=$'\t' read -r owner repo_full proj_no proj_title < <(_rel__resolve_devline_project)

  echo "Open dev line found: $proj_title (#$proj_no)"
  _rel_init__create_items "$repo_full" "$owner" "$proj_no" "$proj_title" "feature" "$@"
}

rel_fix() {
  emulate -L zsh
  set -u
  set -o pipefail

  local owner repo_full proj_no proj_title
  IFS=$'\t' read -r owner repo_full proj_no proj_title < <(_rel__resolve_devline_project)

  echo "Open dev line found: $proj_title (#$proj_no)"
  _rel_init__create_items "$repo_full" "$owner" "$proj_no" "$proj_title" "fix" "$@"
}

_rel__resolve_devline_project() {
  emulate -L zsh
  set -u
  set -o pipefail

  # Repo context
  local owner repo repo_full
  owner="$(gh repo view --json owner -q .owner.login)"
  repo="$(gh repo view --json name -q .name)"
  repo_full="$owner/$repo"

  # Detect owner type (User | Organization)
  local owner_type
  owner_type="$(gh api "repos/$repo_full" -q '.owner.type')"  # "User" | "Organization"

  # List Projects v2 for owner + linked repositories
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

  # Keep only projects linked to THIS repo
  local linked
  linked="$(
    echo "$projects_json" | jq -c --arg REPO "$repo_full" '
      map(
        select((.repositories.nodes // []) | map(.nameWithOwner) | index($REPO))
      )
    '
  )"

  # 1) Reuse an open dev line project: vX.Y.x
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
    # Print: owner repo_full proj_no proj_title (tab separated)
    printf "%s\t%s\t%s\t%s\n" "$owner" "$repo_full" "$open_proj" "$open_title"
    return 0
  fi

  # 2) No open dev line → create next dev line from last semver tag
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

  local target_title="v${major}.${minor}.x"
  while echo "$linked" | jq -e --arg T "$target_title" 'any(.[]; (.title // "") == $T)' >/dev/null; do
    minor=$((minor + 1))
    target_title="v${major}.${minor}.x"
  done

  local target_proj
  target_proj="$(
    gh project create --owner "$owner" --title "$target_title" --format json \
      | jq -r '.number'
  )"

  gh project link "$target_proj" --owner "$owner" --repo "$repo_full" >/dev/null

  printf "%s\t%s\t%s\t%s\n" "$owner" "$repo_full" "$target_proj" "$target_title"
}

# Helper used by rel_init and rel_fix: create issues and add them to the project
# kind: "feature" | "fix"
_rel_init__create_items() {
  emulate -L zsh
  set -u
  set -o pipefail

  local repo_full="$1"
  local owner="$2"
  local proj_no="$3"
  local proj_title="$4"
  local kind="${5:-feature}"
  shift 5 || true

  if [[ "$#" -lt 1 ]]; then
    echo "(no items) you can create them later."
    return 0
  fi

  echo "Creating items (kind=$kind):"

  # Compute planned release from dev line title:
  # vX.Y.x -> planned release vX.(Y+1)
  local planned_release="$proj_title"
  if [[ "$proj_title" =~ ^v([0-9]+)\.([0-9]+)\.x$ ]]; then
    local maj="${match[1]}"
    local min="${match[2]}"
    planned_release="v${maj}.$((min + 1))"
  fi

  # Split args by "--" into multiple issue titles (same UX as rel_init)
  local sep="--"
  local parts=() buf="" tok
  for tok in "$@"; do
    if [[ "$tok" == "$sep" ]]; then
      parts+=("$buf")
      buf=""
    else
      buf="${buf:+$buf }$tok"
    fi
  done
  parts+=("$buf")

  # Labels/body depending on kind
  local label_args=()
  local body_suffix=""
  if [[ "$kind" == "fix" ]]; then
    label_args+=( --label bug )
    body_suffix=" (Fix)"
  fi

  local part t issue_url issue_no
  for part in "${parts[@]}"; do
    t="$(echo "$part" | xargs)"
    [[ -z "$t" ]] && continue

    issue_url="$(
      gh issue create \
        --repo "$repo_full" \
        --title "$t" \
        --body "Planned for release ${planned_release}.${body_suffix}" \
        --assignee @me \
        "${label_args[@]}"
    )"

    if [[ -z "${issue_url:-}" || "${issue_url:-}" != https://github.com/*/issues/* ]]; then
      echo "  failed to create issue: $t"
      echo "     output: ${issue_url:-<empty>}"
      continue
    fi

    gh project item-add "$proj_no" --owner "$owner" --url "$issue_url" >/dev/null

    issue_no="${issue_url##*/}"
    if [[ "$kind" == "fix" ]]; then
      echo "  • created: #$issue_no (FIX) $t"
    else
      echo "  • created: #$issue_no $t"
    fi
  done
}