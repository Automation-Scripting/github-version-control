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
  local next_minor="$((REL_MINOR + 1))"
  local notes="See item #${issue_no} of project v${REL_MAJOR}.${next_minor} for details."
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

  # release minor
  local next_minor="$((REL_MINOR + 1))"
  local tag_release="v${REL_MAJOR}.${next_minor}.0"
  local proj_released="v${REL_MAJOR}.${next_minor} (liberado)"
  local notes="See project v${REL_MAJOR}.${next_minor} for details."

  # (novo) renomeia o project atual pra bater com a tag
  # (usa a variável do project carregado no ctx; aqui assumo REL_PROJ é o number)
  gh project edit "$REL_PROJ" --owner "$REL_OWNER" --title "$proj_released" >/dev/null
  REL_PROJ_TITLE="$proj_released"


  rel_create_release "$tag_release" "$notes"

  rel_mark_all_done "$REL_PROJ"
  rel_close_project

  # (novo) próximo project = patch+1 do milestone recém lançado
  local next_project="v${REL_MAJOR}.${next_minor}.x"
  rel_maybe_open_next_project "$next_project"
}

rel_major() {
  emulate -L zsh
  set -euo pipefail

  rel_ctx_load_repo
  rel_ctx_load_open_milestone
  rel_ctx_load_last_tag

  # release major
  local next_major="$((REL_MAJOR + 1))"
  local tag_release="v${next_major}.0.0"
  local proj_released="v${next_major}.0 (liberado)"
  local notes="See project v${next_major}.0 for details."

  # (novo) renomeia o project atual pra bater com a tag
  gh project edit "$REL_PROJ" --owner "$REL_OWNER" --title "$proj_released" >/dev/null
  REL_PROJ_TITLE="$proj_released"

  rel_create_release "$tag_release" "$notes"

  rel_mark_all_done "$REL_PROJ"
  rel_close_project

  # (novo) próximo project = patch+1 do major recém lançado
  local next_project="v${next_major}.0.x"
  rel_maybe_open_next_project "$next_project"
}