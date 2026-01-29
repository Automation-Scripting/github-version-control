todo() {
  emulate -L zsh
  set -u
  set -o pipefail

  local owner repo repo_full owner_type
  owner="$(gh repo view --json owner -q .owner.login)"
  repo="$(gh repo view --json name -q .name)"
  repo_full="$owner/$repo"
  owner_type="$(gh api "repos/$repo_full" -q '.owner.type')"  # User | Organization

  # ----------------------------
  # Find open dev line project vX.Y.x linked to this repo
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

  local proj title
  proj="$(
    echo "$projects_json" | jq -r --arg REPO "$repo_full" '
      map(
        select(.closed == false)
        | select((.title // "") | test("^v[0-9]+\\.[0-9]+\\.x$"))
        | select((.repositories.nodes // []) | map(.nameWithOwner) | index($REPO))
      )
      | sort_by(.number)
      | .[0].number // empty
    '
  )"

  if [[ -z "${proj:-}" ]]; then
    echo "No open dev line project (vX.Y.x) found for $repo_full."
    return 0
  fi

  title="$(gh project view "$proj" --owner "$owner" --format json | jq -r '.title')"

  echo "Open dev line (Project): $title (#$proj)"
  echo "   Patch: rel p #<issue>   | Minor: rel m   | Major: rel M"
  echo

  local use_color=0
  [[ -t 1 ]] && use_color=1

  # ----------------------------
  # Resolve project node ID + fetch items WITH labels
  # ----------------------------
  local data_json
  if [[ "$owner_type" == "Organization" ]]; then
    data_json="$(
      gh api graphql -f query='
        query($login:String!, $number:Int!) {
          organization(login:$login) {
            projectV2(number:$number) {
              title
              items(first: 100) {
                nodes {
                  id
                  fieldValues(first: 50) {
                    nodes {
                      ... on ProjectV2ItemFieldSingleSelectValue { name field { ... on ProjectV2FieldCommon { name } } }
                      ... on ProjectV2ItemFieldTextValue        { text field { ... on ProjectV2FieldCommon { name } } }
                    }
                  }
                  content {
                    __typename
                    ... on Issue {
                      number
                      title
                      labels(first: 50) { nodes { name } }
                    }
                    ... on PullRequest {
                      number
                      title
                      labels(first: 50) { nodes { name } }
                    }
                  }
                }
              }
            }
          }
        }' -F login="$owner" -F number="$proj" \
      | jq -c '.data.organization.projectV2'
    )"
  else
    data_json="$(
      gh api graphql -f query='
        query($login:String!, $number:Int!) {
          user(login:$login) {
            projectV2(number:$number) {
              title
              items(first: 100) {
                nodes {
                  id
                  fieldValues(first: 50) {
                    nodes {
                      ... on ProjectV2ItemFieldSingleSelectValue { name field { ... on ProjectV2FieldCommon { name } } }
                      ... on ProjectV2ItemFieldTextValue        { text field { ... on ProjectV2FieldCommon { name } } }
                    }
                  }
                  content {
                    __typename
                    ... on Issue {
                      number
                      title
                      labels(first: 50) { nodes { name } }
                    }
                    ... on PullRequest {
                      number
                      title
                      labels(first: 50) { nodes { name } }
                    }
                  }
                }
              }
            }
          }
        }' -F login="$owner" -F number="$proj" \
      | jq -c '.data.user.projectV2'
    )"
  fi

  # ----------------------------
  # Render
  # ----------------------------
  echo "$data_json" |
  jq -r --argjson COLOR "$use_color" '
    # ---------- helpers ----------
    def ititle($i): ($i.content.title // "Untitled");

    def inum($i):
      if ($i.content.number? != null) then ("#" + ($i.content.number|tostring)) else "#?" end;

    def inum_sort($i):
      if ($i.content.number? != null) then ($i.content.number|tonumber) else 999999 end;

    # Status is a Project field value named "Status"
    def istatus($i):
      (
        $i.fieldValues.nodes[]
        | select(.field.name? == "Status")
        | .name
      ) // "No status";

    def s($i): (istatus($i) | ascii_downcase);

    def labels($i): ($i.content.labels.nodes // []);
    def has_label($i; $name):
      any(labels($i)[]; (.name // "" | ascii_downcase) == ($name|ascii_downcase));

    # label-driven "fix" kind
    def is_fix($i):
      has_label($i; "bug") or has_label($i; "fix");

    # TODO vira FIX (só para display) se label indicar
    def status_display($i):
      if s($i) == "todo" and is_fix($i) then "fix" else s($i) end;

    # ordem desejada: done, todo, fix (fix por último)
    def status_rank($i):
      if   status_display($i) == "done" then 0
      elif status_display($i) == "todo" then 1
      elif status_display($i) == "fix"  then 2
      else 9 end;

    # pad à direita (jq 1.6 não tem rpad)
    def pad_right($s; $w):
      ($s + (" " * ((($w - ($s|length)) | if . < 0 then 0 else . end))));

    # status como texto fixo de largura 4 (TODO/FIX/DONE/...)
    def status_pad4($i):
      (status_display($i) | ascii_upcase | .[0:4] | pad_right(.; 4));

    # status com cor, mas sem mexer na largura (a largura é do texto, não do ANSI)
    def status_fmt($i):
      if $COLOR != 1 then
        status_pad4($i)
      elif status_display($i) == "done" then
        "\u001b[35m" + status_pad4($i) + "\u001b[0m"
      elif status_display($i) == "in progress" then
        "\u001b[33m" + status_pad4($i) + "\u001b[0m"
      elif status_display($i) == "fix" then
        "\u001b[31m" + status_pad4($i) + "\u001b[0m"
      elif status_display($i) == "todo" then
        "\u001b[32m" + status_pad4($i) + "\u001b[0m"
      else
        status_pad4($i)
      end;

    # ---------- main ----------
    .items.nodes as $items
    | if ($items|length) == 0 then
        "   (no items)"
      else
        ($items | map(inum(.)|length) | max) as $NW
        | $items
        | sort_by([ status_rank(.), inum_sort(.) ])
        | .[]
        | ("- [" + status_fmt(.) + "] "
          + pad_right(inum(.); $NW)
          + "  "
          + ititle(.))
      end
  '
}