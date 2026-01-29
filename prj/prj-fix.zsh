rel_fix() {
  emulate -L zsh
  set -u
  set -o pipefail

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
    _rel_fix__create_items "$repo_full" "$owner" "$open_proj" "$open_title" "$@"
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

  _rel_fix__create_items "$repo_full" "$owner" "$target_proj" "$target_title" "$@"
}
_rel_fix__create_items() {
  emulate -L zsh
  set -u
  set -o pipefail

  local repo_full="$1"
  local owner="$2"
  local proj_no="$3"
  local proj_title="$4"
  shift 4 || true

  if [[ "$#" -lt 1 ]]; then
    echo "(no items) you can create them later."
    return 0
  fi

  echo "Creating FIX items:"

  # Compute planned release from dev line title:
  # vX.Y.x -> planned release vX.(Y+1)
  local planned_release="$proj_title"
  if [[ "$proj_title" =~ ^v([0-9]+)\.([0-9]+)\.x$ ]]; then
    local maj="${match[1]}"
    local min="${match[2]}"
    planned_release="v${maj}.$((min + 1))"
  fi

  # ----------------------------
  # Repo owner/name (source of truth)
  # ----------------------------
  local repo_owner repo_name
  repo_owner="${repo_full%%/*}"
  repo_name="${repo_full##*/}"

  # ----------------------------
  # Resolve Project node ID (by number) from the REPOSITORY
  # ----------------------------
  local repo_owner repo_name
  repo_owner="${repo_full%%/*}"
  repo_name="${repo_full##*/}"

  local project_id
  project_id="$(
    gh api graphql -f query='
      query($owner:String!, $name:String!, $number:Int!) {
        repository(owner:$owner, name:$name) {
          projectV2(number:$number) { id }
        }
      }' \
      -F owner="$repo_owner" \
      -F name="$repo_name" \
      -F number="$proj_no" \
      -q '.data.repository.projectV2.id'
  )"

  if [[ -z "${project_id:-}" || "$project_id" == "null" ]]; then
    echo "ERROR: could not resolve project node ID for repo=$repo_full project #$proj_no"
    echo "       (Is project #$proj_no owned by this repo owner, and linked/accessible?)"
    return 1
  fi

  # ----------------------------
  # Resolve Status field ID + "Fix" option ID (from project_id)
  # ----------------------------
  local fields_json
  fields_json="$(
    gh api graphql -f query='
      query($project:ID!) {
        node(id:$project) {
          ... on ProjectV2 {
            fields(first: 100) {
              nodes {
                ... on ProjectV2SingleSelectField {
                  id
                  name
                  options { id name }
                }
              }
            }
          }
        }
      }' -F project="$project_id" -q '.data.node.fields.nodes'
  )"

  local status_field_id fix_option_id
  status_field_id="$(echo "$fields_json" | jq -r '.[] | select(.name=="Status") | .id' | head -n 1)"
  fix_option_id="$(echo "$fields_json" | jq -r '.[] | select(.name=="Status") | .options[]? | select(.name=="Fix") | .id' | head -n 1)"

  if [[ -z "${status_field_id:-}" || "$status_field_id" == "null" ]]; then
    echo 'ERROR: field "Status" not found in this Project.'
    return 1
  fi
  if [[ -z "${fix_option_id:-}" || "$fix_option_id" == "null" ]]; then
    echo 'ERROR: option "Fix" not found in field "Status".'
    echo 'Create it manually in the Project (Status field options) and run again.'
    return 1
  fi

  # ----------------------------
  # Split args by "--" into multiple issue titles (same UX as rel_init)
  # ----------------------------
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

  local part t issue_url issue_node_id item_id issue_no
  for part in "${parts[@]}"; do
    t="$(echo "$part" | xargs)"
    [[ -z "$t" ]] && continue

    issue_url="$(
      gh issue create \
        --repo "$repo_full" \
        --title "$t" \
        --body "Planned for release ${planned_release}. (Fix)" \
        --assignee @me
    )"

    if [[ -z "${issue_url:-}" || "${issue_url:-}" != https://github.com/*/issues/* ]]; then
      echo "  failed to create issue: $t"
      echo "     output: ${issue_url:-<empty>}"
      continue
    fi

    # Resolve Issue node ID from URL
    issue_node_id="$(
      gh api graphql -f query='
        query($url:URI!) {
          resource(url:$url) {
            ... on Issue { id }
          }
        }' -F url="$issue_url" -q '.data.resource.id'
    )"

    if [[ -z "${issue_node_id:-}" || "$issue_node_id" == "null" ]]; then
      echo "  WARN: could not resolve issue node id for $issue_url (skipping project add)"
      continue
    fi

    # Add to Project and capture project item id
    item_id="$(
      gh api graphql -f query='
        mutation($project:ID!, $content:ID!) {
          addProjectV2ItemById(input:{ projectId:$project, contentId:$content }) {
            item { id }
          }
        }' -F project="$project_id" -F content="$issue_node_id" -q '.data.addProjectV2ItemById.item.id'
    )"

    if [[ -z "${item_id:-}" || "$item_id" == "null" ]]; then
      echo "  WARN: could not add to project (skipping status set): $issue_url"
      continue
    fi

    # Set Status = Fix
    gh api graphql -f query='
      mutation($project:ID!, $item:ID!, $field:ID!, $option:String!) {
        updateProjectV2ItemFieldValue(input:{
          projectId:$project,
          itemId:$item,
          fieldId:$field,
          value:{ singleSelectOptionId:$option }
        }) { projectV2Item { id } }
      }' \
      -F project="$project_id" \
      -F item="$item_id" \
      -F field="$status_field_id" \
      -F option="$fix_option_id" >/dev/null

    issue_no="${issue_url##*/}"
    echo "  • created: #$issue_no (Fix) $t"
  done
}