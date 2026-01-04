# rel-lib.zsh
# helpers compartilhados por rel_patch/rel_minor/rel_major

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
        | map(select(.title | test("^v[0-9]+\\.[0-9]+\\.[0-9]+$")))
        | sort_by(.number)
        | .[0].number // empty
      '
  )"

  if [[ -z "${REL_PROJ:-}" ]]; then
    echo "Nenhum Project (milestone) aberto com título vX.Y.Z encontrado para $REL_OWNER."
    return 1
  fi

  REL_PROJ_TITLE="$(gh project view "$REL_PROJ" --owner "$REL_OWNER" --format json | jq -r '.title')"
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

# ---------- project helpers ----------
rel_items_json() {
  emulate -L zsh
  set -euo pipefail
  gh project item-list "$REL_PROJ" --owner "$REL_OWNER" --format json
}

rel_try_set_status() {
  emulate -L zsh
  set -euo pipefail
  local project_number="$1" item_id="$2" new_status="$3"

  # best-effort
  gh project item-edit "$project_number" --owner "$REL_OWNER" --id "$item_id" --status "$new_status" >/dev/null 2>&1 || true
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
  local issue_no="$1" body="$2"
  gh issue comment "$issue_no" --repo "$REL_REPO_FULL" --body "$body" >/dev/null
}

rel_create_release() {
  emulate -L zsh
  set -euo pipefail
  local tag="$1" notes="$2"

  echo "[debug] repo: $REL_REPO_FULL"
  echo "[debug] last tag: $REL_LAST_TAG"
  echo "[debug] confirm tag to create: $tag"

  gh release create "$tag" --title "$tag" --notes "$notes"
  echo "Release criada: $tag"
}

rel_close_project() {
  emulate -L zsh
  set -euo pipefail
  gh project close "$REL_PROJ" --owner "$REL_OWNER"
  echo "🔒 Project fechado: ${REL_PROJ_TITLE} (#$REL_PROJ)"
}

rel_maybe_open_next_project() {
  emulate -L zsh
  set -euo pipefail
  local next_title="$1"

  echo -n "Abrir próximo Project (${next_title})? [y/N]: "
  local ans
  IFS= read -r ans || true

  case "${ans:-}" in
    y|Y|yes|YES)
      local next_proj
      next_proj="$(
        gh project create --owner "$REL_OWNER" --title "$next_title" --format json |
          jq -r '.number'
      )"
      echo "Novo Project aberto: $next_title (#$next_proj)"
      ;;
    *)
      echo "Ok. Nenhum novo Project criado."
      ;;
  esac
}