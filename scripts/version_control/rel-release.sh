# rel-release.zsh
# define: rel_patch, rel_minor, rel_major

rel_patch() {
  emulate -L zsh
  set -euo pipefail

  local ref="${1:-}"
  [[ -z "$ref" ]] && { echo "Use: rel p #<issue> (ex: rel p 3)"; return 1; }

  rel_ctx_load_repo
  rel_ctx_load_open_milestone
  rel_ctx_load_last_tag

  local issue_no="${ref#\#}"
  [[ "$issue_no" =~ ^[0-9]+$ ]] || { echo "Número inválido: $ref"; return 1; }

  local tag="v${REL_MAJOR}.${REL_MINOR}.$((REL_PATCH + 1))"
  local notes="See item #${issue_no} of project ${REL_PROJ_TITLE} for details."
  rel_create_release "$tag" "$notes"

  # marcar o item do project como Done (best-effort)
  local json item_id
  json="$(rel_items_json)"
  item_id="$(echo "$json" | jq -r --argjson N "$issue_no" '
    .items[] | select(.content.number? == $N) | .id
  ' | head -n1)"

  if [[ -n "${item_id:-}" && "$item_id" != "null" ]]; then
    rel_try_set_status "$REL_PROJ" "$item_id" "Done"
  fi

  # comentar no issue do repo (o item é issue)
  rel_issue_comment "$issue_no" "Released in $tag"
}

rel_minor() {
  emulate -L zsh
  set -euo pipefail

  rel_ctx_load_repo
  rel_ctx_load_open_milestone
  rel_ctx_load_last_tag

  local tag="v${REL_MAJOR}.$((REL_MINOR + 1)).0"
  local notes="See project ${REL_PROJ_TITLE} for details."
  rel_create_release "$tag" "$notes"

  rel_mark_all_done "$REL_PROJ"
  rel_close_project
  rel_maybe_open_next_project "$tag"
}

rel_major() {
  emulate -L zsh
  set -euo pipefail

  rel_ctx_load_repo
  rel_ctx_load_open_milestone
  rel_ctx_load_last_tag

  local tag="v$((REL_MAJOR + 1)).0.0"
  local notes="See project ${REL_PROJ_TITLE} for details."
  rel_create_release "$tag" "$notes"

  rel_mark_all_done "$REL_PROJ"
  rel_close_project
  rel_maybe_open_next_project "$tag"
}