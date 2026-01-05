rel_patch() {
  emulate -L zsh
  set -euo pipefail

  local ref="${1:-}"
  [[ -z "$ref" ]] && { echo "Usage: rel p #<issue> (e.g. rel p 3)"; return 1; }

  rel_ctx_load_repo
  rel_ctx_load_open_milestone
  rel_ctx_load_last_tag

  local issue_no="${ref#\#}"
  [[ "$issue_no" =~ ^[0-9]+$ ]] || { echo "Invalid issue number: $ref"; return 1; }

  local tag="v${REL_MAJOR}.${REL_MINOR}.$((REL_PATCH + 1))"
  local next_minor="$((REL_MINOR + 1))"
  local notes="See item #${issue_no} of project v${REL_MAJOR}.${next_minor} for details."
  rel_create_release "$tag" "$notes"

  # Locate the corresponding project item (by issue number)
  # and mark it as Done after the patch release.
  local json item_id
  json="$(rel_items_json)"
  item_id="$(echo "$json" | jq -r --argjson N "$issue_no" '
    .items[] | select(.content.number? == $N) | .id
  ' | head -n1)"

  if [[ -z "${item_id:-}" || "$item_id" == "null" ]]; then
    echo "[warn] Project item not found for issue #$issue_no (nothing to mark Done)."
  else
    if rel_try_set_status "$REL_PROJ" "$item_id" "Done"; then
      echo "[info] project item #$issue_no marked as Done."
    else
      echo "[warn] Could not mark item #$issue_no as Done (best-effort)."
    fi
  fi

  rel_issue_comment "$issue_no" "Released in $tag"
}

rel_minor() {
  emulate -L zsh
  set -euo pipefail

  rel_ctx_load_repo
  rel_ctx_load_open_milestone
  rel_ctx_load_last_tag

  # Minor release
  local next_minor="$((REL_MINOR + 1))"
  local tag_release="v${REL_MAJOR}.${next_minor}.0"
  local proj_released="v${REL_MAJOR}.${next_minor} (released)"
  local notes="See project v${REL_MAJOR}.${next_minor} for details."

  # (new) Rename the current project to match the released version
  # (uses the project number loaded in the context)
  gh project edit "$REL_PROJ" --owner "$REL_OWNER" --title "$proj_released" >/dev/null
  REL_PROJ_TITLE="$proj_released"

  rel_create_release "$tag_release" "$notes"

  rel_mark_all_done "$REL_PROJ"
  rel_close_project

  # (new) Next project = patch line for the newly released minor
  local next_project="v${REL_MAJOR}.${next_minor}.x"
  rel_maybe_open_next_project "$next_project"
}

rel_major() {
  emulate -L zsh
  set -euo pipefail

  rel_ctx_load_repo
  rel_ctx_load_open_milestone
  rel_ctx_load_last_tag

  # Major release
  local next_major="$((REL_MAJOR + 1))"
  local tag_release="v${next_major}.0.0"
  local proj_released="v${next_major}.0 (released)"
  local notes="See project v${next_major}.0 for details."

  # (new) Rename the current project to match the released version
  gh project edit "$REL_PROJ" --owner "$REL_OWNER" --title "$proj_released" >/dev/null
  REL_PROJ_TITLE="$proj_released"

  rel_create_release "$tag_release" "$notes"

  rel_mark_all_done "$REL_PROJ"
  rel_close_project

  # (new) Next project = patch line for the newly released major
  local next_project="v${next_major}.0.x"
  rel_maybe_open_next_project "$next_project"
}