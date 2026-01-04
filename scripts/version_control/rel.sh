rel() {
  set -uo pipefail

  local cmd="${1:-}"
  shift || true

  case "$cmd" in
    init) rel_init "$@" ;;
    p)    rel_patch "$@" ;;
    m)    rel_minor "$@" ;;
    M)    rel_major "$@" ;;
    *)
      echo "Uso:"
      echo "  rel init Item 1 -- Item 2 -- Item 3"
      echo "  rel p #<issue>"
      echo "  rel m"
      echo "  rel M"
      return 1
      ;;
  esac
}