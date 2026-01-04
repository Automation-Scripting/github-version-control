rel() {
  set -uo pipefail

  if [ "$#" -lt 1 ]; then
    echo "Uso:"
    echo "  rel p #<issue>        (patch associado ao item/issue; NÃO fecha project)"
    echo "  rel m                 (minor release; fecha project)"
    echo "  rel M                 (major release; fecha project)"
    return 1
  fi

  local mode="$1"
  local ref="${2:-}"

  # ----------------------------
  # Owner / repo
  # ----------------------------
  local owner repo
  owner="$(gh repo view --json owner -q .owner.login)"
  repo="$(gh repo view --json name -q .name)"


  # ----------------------------
  # INIT: rel init Item1 -- Item2 -- ...
  # Regras:
  # - Se existir Project aberto vX.Y.Z => reutiliza e só cria itens
  # - Se existir algum vX.Y.Z fechado (e nenhum aberto) => cria PRÓXIMO PATCH vX.Y.(Z+1)
  # - Se não existir nenhum => cria v0.0.1
  # ----------------------------
  if [ "$mode" = "init" ]; then
    set -euo pipefail

    # pega lista de números de projects (não confiamos em .title aqui)
    local proj_nums
    proj_nums="$(
      gh project list --owner "$owner" --format json |
        jq -r '.projects[].number' 2>/dev/null || true
    )"

    local open_proj="" open_title=""
    local last_title=""

    # varre todos os projects e identifica:
    # - primeiro aberto com título vX.Y.Z
    # - maior título vX.Y.Z (mesmo fechado)
    local n
    while IFS= read -r n; do
      [ -z "$n" ] && continue

      # view é a fonte da verdade no seu GH CLI
      local vjson title closed
      vjson="$(gh project view "$n" --owner "$owner" --format json 2>/dev/null || true)"
      [ -z "$vjson" ] && continue

      title="$(echo "$vjson" | jq -r '.title // empty')"
      closed="$(echo "$vjson" | jq -r '.closed')"

      # só consideramos projects com título semver "vX.Y.Z"
      if echo "$title" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
        # atualiza last_title (maior semver)
        if [ -z "$last_title" ]; then
          last_title="$title"
        else
          # sort -V resolve bem semver simples
          last_title="$(printf "%s\n%s\n" "$last_title" "$title" | sort -V | tail -n1)"
        fi

        # pega o primeiro aberto (prioridade)
        if [ "$closed" = "false" ] && [ -z "$open_proj" ]; then
          open_proj="$n"
          open_title="$title"
        fi
      fi
    done <<< "$proj_nums"

    local target_proj="" target_title="" created_new="no"

    if [ -n "$open_proj" ]; then
      target_proj="$open_proj"
      target_title="$open_title"
      echo "📌 Project aberto encontrado: $target_title (#$target_proj)"
    else
      # não tem aberto: decide o que criar
      if [ -n "$last_title" ]; then
        # existe algum vX.Y.Z (fechado): cria próximo PATCH
        local base major_i minor_i patch_i
        base="${last_title#v}"
        IFS='.' read -r major_i minor_i patch_i <<< "$base"
        target_title="v${major_i}.${minor_i}.$((patch_i+1))"
      else
        # não existe nenhum project vX.Y.Z
        target_title="v0.0.1"
      fi

      echo "🆕 Criando Project (milestone): $target_title"

      target_proj="$(
        gh project create --owner "$owner" --title "$target_title" --format json |
          jq -r '.number'
      )"
      created_new="yes"

      # linka ao repo (pra aparecer na aba Projects do repo)
      gh project link "$target_proj" --owner "$owner" --repo "$owner/$repo" >/dev/null
      echo "🔗 Project associado ao repositório: $owner/$repo"
      echo "✅ Project criado: $target_title (#$target_proj)"
    fi

    # --- parse itens sem aspas, separador: --
    # exemplo: rel init Criar Item 01 -- Criar Item 02 -- Criar Item 03
    if [ "$#" -ge 2 ]; then
      echo "📝 Criando itens (separador: --):"

      local sep="--"
      local parts=()
      local buf=""
      local started=0

      for tok in "$@"; do
        if [ $started -eq 0 ]; then
          started=1
          continue  # pula "init"
        fi

        if [ "$tok" = "$sep" ]; then
          parts+=("$buf")
          buf=""
        else
          if [ -z "$buf" ]; then
            buf="$tok"
          else
            buf="$buf $tok"
          fi
        fi
      done
      parts+=("$buf")

      for part in "${parts[@]}"; do
        local t issue_url
        t="$(echo "$part" | xargs)"
        [ -z "$t" ] && continue

        issue_url="$(
          gh issue create \
            --repo "$owner/$repo" \
            --title "$t" \
            --body "Planned for $target_title" \
            --assignee @me
        )"

        if [[ -z "${issue_url:-}" || "${issue_url:-}" != https://github.com/*/issues/* ]]; then
          echo "  ❌ falhou ao criar issue: $t"
          echo "     saída: ${issue_url:-<vazio>}"
          continue
        fi

        gh project item-add "$target_proj" --owner "$owner" --url "$issue_url" >/dev/null
        echo "  • criado: $t"
      done
    else
      echo "ℹ️ (sem itens) você pode criar depois."
    fi

    return 0
  fi

  # ----------------------------
  # Milestone atual: project aberto vX.Y.Z
  # ----------------------------
  local proj proj_title
  proj="$(
    gh project list --owner "$owner" --format json |
      jq -r '
        .projects
        | map(select(.closed == false))
        | map(select(.title | test("^v[0-9]+\\.[0-9]+\\.[0-9]+$")))
        | sort_by(.number)
        | .[0].number // empty
      '
  )"

  if [ -z "${proj:-}" ]; then
    echo "❌ Nenhum Project (milestone) aberto com título vX.Y.Z encontrado para $owner."
    return 1
  fi

  proj_title="$(gh project view "$proj" --owner "$owner" --format json | jq -r '.title')"


  # ---- DEBUG: fonte da verdade no GitHub (tags) ----
  echo "[debug] repo: $owner/$repo"

  local gh_last
  gh_last="$(
    gh api "repos/$owner/$repo/tags" --paginate -q '.[].name' |
      grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' |
      sort -V |
      tail -n 1
  )"

  echo "[debug] last tag from GitHub tags API: ${gh_last:-<empty>}"

  if [ -z "${gh_last:-}" ]; then
    gh_last="v0.0.0"
  fi

  local base="${gh_last#v}"
  local major minor patch
  IFS='.' read -r major minor patch <<< "$base"

  echo "[debug] parsed semver: major=$major minor=$minor patch=$patch"

  # ----------------------------
  # Última tag (semver)
  # ----------------------------
  local last major minor patch
  # Última versão = maior tag vX.Y.Z no GitHub
  last="$(
    gh api repos/$owner/$repo/tags --paginate -q '.[].name' |
      grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' |
      sort -V |
      tail -n 1
  )"

  [ -z "${last:-}" ] && last="v0.0.0"

  last="${last#v}"
  IFS='.' read -r major minor patch <<< "$last"
  # ----------------------------
  # Helpers
  # ----------------------------
  _items_json() {
    gh project item-list "$proj" --owner "$owner" --format json
  }

  _try_set_status() {
    local project_number="$1"
    local item_id="$2"
    local new_status="$3"

    gh project item-edit "$project_number" --owner "$owner" --id "$item_id" --status "$new_status" >/dev/null 2>&1 || true
  }

  _mark_all_done() {
    local project_number="$1"
    local json
    json="$(gh project item-list "$project_number" --owner "$owner" --format json)"
    echo "$json" | jq -r '.items[].id' | while IFS= read -r item_id; do
      [ -z "$item_id" ] && continue
      _try_set_status "$project_number" "$item_id" "Done"
    done
  }

  _issue_comment() {
    local issue_no="$1"
    local body="$2"
    gh issue comment "$issue_no" --repo "$owner/$repo" --body "$body" >/dev/null
  }

  _create_release() {
    local tag="$1"
    local notes="$2"
    echo "[debug] confirm tag to create: $tag"
    gh release create "$tag" --title "$tag" --notes "$notes"
    echo "✅ Release criada: $tag"
  }

  _close_project() {
    gh project close "$proj" --owner "$owner"
    echo "🔒 Project fechado: ${proj_title} (#$proj)"
  }

  _maybe_open_next_project() {
    local next_title="$1"

    echo -n "Abrir próximo Project (${next_title})? [y/N]: "
    local ans
    IFS= read -r ans || true
    case "${ans:-}" in
      y|Y|yes|YES)
        local next_proj
        next_proj="$(
          gh project create --owner "$owner" --title "$next_title" --format json |
            jq -r '.number'
        )"
        echo "🚀 Novo Project aberto: $next_title (#$next_proj)"

        echo -n "Itens do novo Project (separe por |, ENTER para nenhum): "
        local raw
        IFS= read -r raw || true
        if [ -n "${raw:-}" ]; then
          IFS='|' read -ra parts <<< "$raw"
          for part in "${parts[@]}"; do
            local t
            t="$(echo "$part" | xargs)"
            [ -z "$t" ] && continue

            local issue_url
            issue_url="$(gh issue create --repo "$owner/$repo" --title "$t" --body "Planned for $next_title" --json url -q .url)"
            gh project item-add "$next_proj" --owner "$owner" --url "$issue_url" >/dev/null
            echo "  • criado: $t"
          done
        fi
        ;;
      *)
        echo "↪️ Ok. Nenhum novo Project criado."
        ;;
    esac
  }

  # ----------------------------
  # PATCH: rel p #N  (NÃO fecha project)
  # ----------------------------
  if [ "$mode" = "p" ]; then
    if [ -z "${ref:-}" ]; then
      echo "❌ Use: rel p #<issue>  (ex: rel p #3)"
      return 1
    fi

    local issue_no="${ref#\#}"
    if ! [[ "$issue_no" =~ ^[0-9]+$ ]]; then
      echo "❌ Número de issue inválido: $ref (use #3 ou 3)"
      return 1
    fi

    local tag="v${major}.${minor}.$((patch+1))"
    local notes="See item #${issue_no} of project ${proj_title} for details."
    _create_release "$tag" "$notes"

    # marcar só o item associado (best-effort)
    local json item_id
    json="$(_items_json)"
    item_id="$(echo "$json" | jq -r --argjson N "$issue_no" '
      .items[] | select(.content.number? == $N) | .id
    ' | head -n1)"

    if [ -n "${item_id:-}" ] && [ "$item_id" != "null" ]; then
      _try_set_status "$proj" "$item_id" "Done"
    fi

    _issue_comment "$issue_no" "Released in $tag"
    return 0
  fi

  # ----------------------------
  # MINOR: rel m  (fecha project)
  # ----------------------------
  if [ "$mode" = "m" ]; then
    local tag="v${major}.$((minor+1)).0"
    local notes="See project ${proj_title} for details."
    _create_release "$tag" "$notes"

    _mark_all_done "$proj"
    _close_project
    _maybe_open_next_project "$tag"
    return 0
  fi

  # ----------------------------
  # MAJOR: rel M  (fecha project)
  # ----------------------------
  if [ "$mode" = "M" ]; then
    local tag="v$((major+1)).0.0"
    local notes="See project ${proj_title} for details."
    _create_release "$tag" "$notes"

    _mark_all_done "$proj"
    _close_project
    _maybe_open_next_project "$tag"
    return 0
  fi

  echo "❌ Modo inválido: use p, m ou M"
  return 1
}