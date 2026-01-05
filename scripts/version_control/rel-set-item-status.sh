rel_set_item_status() {
  emulate -L zsh
  set -euo pipefail

  local ref="$1"
  local new_status="$2"

  [[ -z "$ref" || -z "$new_status" ]] && {
    echo "Usage: rel_set_item_status #<issue> <Status>"
    echo "Example: rel_set_item_status #6 \"In Progress\""
    return 1
  }

  rel_ctx_load_repo
  rel_ctx_load_open_milestone

  local issue_no="${ref#\#}"
  [[ "$issue_no" =~ ^[0-9]+$ ]] || {
    echo "Invalid issue number: $ref"
    return 1
  }

  # find project item id
  local json item_id
  json="$(rel_items_json)"
  item_id="$(
    echo "$json" | jq -r --argjson N "$issue_no" '
      .items[]
      | select(.content.number? == $N)
      | .id
    ' | head -n1
  )"

  if [[ -z "${item_id:-}" || "$item_id" == "null" ]]; then
    echo " Issue #$issue_no not found in project ${REL_PROJ_TITLE}"
    return 1
  fi

  rel_try_set_status "$REL_PROJ" "$item_id" "$new_status"

  echo " Issue #$issue_no marked as \"$new_status\" in project ${REL_PROJ_TITLE}"
}

rel_progress() {
  rel_set_item_status "$1" "In Progress"
}

rel_ready() {
  rel_set_item_status "$1" "Ready"
}

rel_done() {
  rel_set_item_status "$1" "Done"
}