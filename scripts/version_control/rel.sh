rel() {
  emulate -L zsh
  set -uo pipefail

  local cmd="${1:-}"
  local sub="${2:-}"
  shift || true

  case "$cmd" in
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
    ready)     shift; rel_ready "$@" ;;
    progress)  shift; rel_progress "$@" ;;
    done)      shift; rel_done "$@" ;;
    init) rel_init "$@" ;;
    p)    rel_patch "$@" ;;
    m)    rel_minor "$@" ;;
    M)    rel_major "$@" ;;
    *)
      echo "Use:"
      echo "  rel init Item 1 -- Item 2 -- Item 3"
      echo "  rel p <#issue>"
      echo "  rel m"
      echo "  rel M"
      return 1
      ;;
  esac
}