rel() {
  emulate -L zsh
  set -u
  set -o pipefail

  local cmd="${1:-}"
  shift || true

  case "${cmd:-}" in
    todo)     rel_todo     "$@" ;;
    progress) rel_progress "$@" ;;
    done)     rel_done     "$@" ;;
    init)     rel_init     "$@" ;;
    fix)      rel_fix      "$@" ;;
    p)        rel_patch    "$@" ;;
    m)        rel_minor    "$@" ;;
    M)        rel_major    "$@" ;;
    *)
      echo "Usage:"
      echo "  rel init Item A -- Item B -- Item C"
      echo "  rel fix Item A -- Item B -- Item C"
      echo "  rel p <issue>        (patch release)"
      echo "  rel m                (minor release)"
      echo "  rel M                (major release)"
      echo "  rel todo <issue>     (set Status=Todo)"
      echo "  rel progress <issue> (set Status=In Progress)"
      echo "  rel done <issue>     (set Status=Done)"
      return 1
      ;;
  esac
}

    # wipe)
    #   case "$sub" in
    #     releases)
    #       rel_wipe_releases
    #       ;;
    #     tags)
    #       rel_wipe_tags
    #       ;;
    #     all)
    #       rel_wipe_all
    #       ;;
    #     project)
    #       rel_wipe_project
    #       ;;
    #     *)
    #       echo "Use:"
    #       echo "  rel wipe project"
    #       echo "  rel wipe releases"
    #       echo "  rel wipe tags"
    #       echo "  rel wipe all"
    #       return 1
    #       ;;
    #   esac
    #   return 0
    #   ;;

