rel_wipe_project() {
  emulate -L zsh
  set -euo pipefail

  # Current repository
  local repo_full owner repo owner_type
  repo_full="$(gh repo view --json owner,name -q '.owner.login + "/" + .name')"
  owner="${repo_full%%/*}"
  repo="${repo_full##*/}"

  echo
  echo " Target repository:"
  echo "   $repo_full"
  echo

  # Owner type (User | Organization)
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
    echo " No Projects associated with this repository."
    return 0
  fi

  echo " Projects associated with $repo_full:"
  echo
  echo "$projects" | jq -r '
    "• #\(.number)\t\(.title)\t(repos: \((.repositories.nodes | map(.nameWithOwner) | join(","))))"
  '
  echo

  echo "  WARNING: these Projects will be PERMANENTLY DELETED."
  echo -n "Type exactly DELETE to confirm: "
  local confirm
  read -r confirm

  if [[ "$confirm" != "DELETE" ]]; then
    echo " Cancelled. No projects were removed."
    return 1
  fi

  echo
  echo " Deleting Projects..."

  echo "$projects" | jq -r '.number' | while read -r n; do
    echo "  🗑️  Deleting project #$n"
    gh project delete "$n" --owner "$owner"
  done

  echo
  echo " Cleanup completed."
}

rel_wipe_releases() {
  emulate -L zsh
  set -euo pipefail

  local repo_full
  repo_full="$(gh repo view --json owner,name -q '.owner.login + "/" + .name')"

  echo
  echo " Repo: $repo_full"
  echo " Listing releases..."
  echo

  local rels
  rels="$(gh release list --repo "$repo_full" --limit 1000 --json tagName,name,createdAt \
    | jq -c '.[]')"

  if [[ -z "${rels:-}" ]]; then
    echo " No releases found."
    return 0
  fi

  echo " Releases found:"
  echo "$rels" | jq -r '"• \(.tagName)\t\(.name // "-")\t\(.createdAt)"'
  echo

  echo -n "  Type DELETE-RELEASES to delete ALL releases: "
  local confirm
  read -r confirm
  [[ "$confirm" == "DELETE-RELEASES" ]] || { echo "❌ Cancelled."; return 1; }

  echo
  echo " Deleting releases..."
  echo "$rels" | jq -r '.tagName' | while read -r tag; do
    [[ -z "$tag" ]] && continue
    echo "    release $tag"
    gh release delete "$tag" --repo "$repo_full" -y
  done

  echo " Releases deleted."
}

rel_wipe_tags() {
  emulate -L zsh
  set -euo pipefail

  local repo_full
  repo_full="$(gh repo view --json owner,name -q '.owner.login + "/" + .name')"

  echo
  echo " Repo: $repo_full"
  echo "  Listing remote tags..."
  echo

  local tags
  tags="$(gh api "repos/$repo_full/git/matching-refs/tags" --paginate \
    | jq -r '.[].ref | sub("^refs/tags/";"")')"

  if [[ -z "${tags:-}" ]]; then
    echo " No tags found."
    return 0
  fi

  echo " Tags found:"
  echo "$tags" | sed 's/^/• /'
  echo

  echo -n "  Type DELETE-TAGS to delete ALL tags: "
  local confirm
  read -r confirm
  [[ "$confirm" == "DELETE-TAGS" ]] || { echo " Cancelled."; return 1; }

  echo
  echo " Deleting tags..."
  echo "$tags" | while read -r t; do
    [[ -z "$t" ]] && continue
    echo "    tag $t"
    gh api -X DELETE "repos/$repo_full/git/refs/tags/$t" >/dev/null
  done

  echo " Tags deleted."
}

rel_wipe_all() {
  emulate -L zsh
  set -euo pipefail

  local repo_full
  repo_full="$(gh repo view --json owner,name -q '.owner.login + "/" + .name')"

  echo
  echo "  TOTAL WIPE (releases + tags)"
  echo "Repo: $repo_full"
  echo

  echo -n "Type exactly NUKE to continue: "
  local c
  read -r c
  [[ "$c" == "NUKE" ]] || { echo " Cancelled."; return 1; }

  rel_wipe_releases
  rel_wipe_tags
}