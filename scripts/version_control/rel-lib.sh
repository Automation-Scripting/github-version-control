rel_ctx_load_repo() {
  emulate -L zsh
  set -euo pipefail

  typeset -g REL_OWNER REL_REPO REL_REPO_FULL
  REL_OWNER="$(gh repo view --json owner -q .owner.login)"
  REL_REPO="$(gh repo view --json name -q .name)"
  REL_REPO_FULL="${REL_OWNER}/${REL_REPO}"
}

rel_ctx_load_open_milestone() {
  emulate -L zsh
  set -euo pipefail

  typeset -g REL_PROJ REL_PROJ_TITLE

  REL_PROJ="$(
    gh project list --owner "$REL_OWNER" --format json |
      jq -r '
        .projects
        | map(select(.closed == false))
        | map(select(.title | test("^v[0-9]+\\.[0-9]+\\.x$")))
        | sort_by(.number)
        | .[0].number // empty
      '
  )"

  if [[ -z "${REL_PROJ:-}" ]]; then
    echo "No open Project (development line) with title vX.Y.x found for $REL_OWNER."
    return 1
  fi

  REL_PROJ_TITLE="$(
    gh project view "$REL_PROJ" --owner "$REL_OWNER" --format json |
      jq -r '.title'
  )"
}

rel_ctx_load_last_tag() {
  emulate -L zsh
  set -euo pipefail

  typeset -g REL_LAST_TAG REL_MAJOR REL_MINOR REL_PATCH

  REL_LAST_TAG="$(
    gh api "repos/$REL_REPO_FULL/tags" --paginate -q '.[].name' |
      grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' |
      sort -V |
      tail -n 1 || true
  )"

  [[ -z "${REL_LAST_TAG:-}" ]] && REL_LAST_TAG="v0.0.0"

  local base="${REL_LAST_TAG#v}"
  IFS='.' read -r REL_MAJOR REL_MINOR REL_PATCH <<< "$base"
}

# ---------- Project helpers ----------

rel_items_json() {
  emulate -L zsh
  set -euo pipefail
  gh project item-list "$REL_PROJ" --owner "$REL_OWNER" --format json
}

rel_try_set_status() {
  emulate -L zsh
  set -euo pipefail

  local project_number="$1"
  local item_id="$2"
  local new_status="$3"   # Avoid using the name "status"

  local project_id fields_json status_field_id option_id

  project_id="$(
    gh project view "$project_number" --owner "$REL_OWNER" --format json |
      jq -r '.id'
  )"

  fields_json="$(
    gh project field-list "$project_number" --owner "$REL_OWNER" --format json
  )"

  status_field_id="$(
    echo "$fields_json" |
      jq -r '.fields[] | select(.name=="Status") | .id' |
      head -n1
  )"

  [[ -z "${status_field_id:-}" || "$status_field_id" == "null" ]] && return 0

  option_id="$(
    echo "$fields_json" |
      jq -r --arg S "$new_status" '
        .fields[] | select(.id=="'"$status_field_id"'")
        | .options[] | select(.name==$S) | .id
      ' |
      head -n1
  )"

  [[ -z "${option_id:-}" || "$option_id" == "null" ]] && return 0

  gh project item-edit \
    --project-id "$project_id" \
    --id "$item_id" \
    --field-id "$status_field_id" \
    --single-select-option-id "$option_id" \
    >/dev/null 2>&1 || true
}

rel_mark_all_done() {
  emulate -L zsh
  set -euo pipefail

  local project_number="$1"
  local json

  json="$(gh project item-list "$project_number" --owner "$REL_OWNER" --format json)"

  echo "$json" | jq -r '.items[].id' | while IFS= read -r item_id; do
    [[ -z "$item_id" ]] && continue
    rel_try_set_status "$project_number" "$item_id" "Done"
  done
}

rel_issue_comment() {
  emulate -L zsh
  set -euo pipefail

  local issue_no="$1"
  local body="$2"

  gh issue comment "$issue_no" --repo "$REL_REPO_FULL" --body "$body" >/dev/null
}

rel_create_release() {
  emulate -L zsh
  set -euo pipefail

  local tag="$1"
  local notes="$2"

  echo "[info] $REL_REPO_FULL"
  echo "[info] Tag to create: $REL_LAST_TAG -> $tag"

  gh release create "$tag" --title "$tag" --notes "$notes" > /dev/null
  echo "[info] Release created: $tag"
}

rel_close_project() {
  emulate -L zsh
  set -euo pipefail

  gh project close "$REL_PROJ" --owner "$REL_OWNER"
  echo "Project closed: ${REL_PROJ_TITLE} (#$REL_PROJ)"
}

rel_maybe_open_next_project() {
  emulate -L zsh
  set -euo pipefail

  local next_title="$1"

  echo -n "Open next Project (${next_title})? [y/N]: "
  local ans
  IFS= read -r ans || true

  case "${ans:-}" in
    y|Y|yes|YES)
      local next_proj
      next_proj="$(
        gh project create --owner "$REL_OWNER" --title "$next_title" --format json |
          jq -r '.number'
      )"
      echo "New Project opened: $next_title (#$next_proj)"
      ;;
    *)
      echo "Ok. No new Project created."
      ;;
  esac
}

rel_create_tag() {
  emulate -L zsh
  set -euo pipefail

  local tag="$1"

  echo "[info] $REL_REPO_FULL"
  echo "[info] Tag to create: $REL_LAST_TAG -> $tag"

  # If tag already exists, stop (avoid rewriting history)
  if gh api "repos/$REL_REPO_FULL/git/ref/tags/$tag" >/dev/null 2>&1; then
    echo "[warn] Tag already exists: $tag"
    return 1
  fi

  # Tag target = default branch HEAD (source of truth on GitHub)
  local default_branch sha
  default_branch="$(gh api "repos/$REL_REPO_FULL" -q '.default_branch')"
  sha="$(gh api "repos/$REL_REPO_FULL/git/ref/heads/$default_branch" -q '.object.sha')"

  gh api -X POST "repos/$REL_REPO_FULL/git/refs" \
    -f "ref=refs/tags/$tag" \
    -f "sha=$sha" \
    >/dev/null

  echo "[info] Tag created: $tag (at $default_branch)"
}

rel_issue_last_patch_tag() {
  emulate -L zsh
  set -euo pipefail

  local issue_no="$1"

  # Grab the last comment that matches: "Tagged in vX.Y.Z"
  gh issue view "$issue_no" --repo "$REL_REPO_FULL" --json comments \
    | jq -r '
      [.comments[].body
        | select(test("^Tagged in v[0-9]+\\.[0-9]+\\.[0-9]+"))
      ] | last // empty
    ' \
    | sed -E 's/^Tagged in (v[0-9]+\.[0-9]+\.[0-9]+).*/\1/'
}

rel_build_release_notes_from_project() {
  emulate -L zsh
  set -euo pipefail

  local release_line="$1"  # e.g. "v0.1"
  local json
  json="$(rel_items_json)"

  # Build a Markdown list of items with their latest patch tag (if any)
  echo "See project ${release_line} for details."
  echo
  echo "## Shipped items"
  echo

  echo "$json" | jq -r '
    .items[]
    | select(.content.number? != null)
    | "\(.content.number)\t\(.content.title // .title // "Untitled")"
  ' | while IFS=$'\t' read -r issue_no title; do
    local tag
    tag="$(rel_issue_last_patch_tag "$issue_no" || true)"
    if [[ -n "${tag:-}" ]]; then
      echo "- #${issue_no} ${title} — **${tag}**"
    else
      echo "- #${issue_no} ${title}"
    fi
  done
}
