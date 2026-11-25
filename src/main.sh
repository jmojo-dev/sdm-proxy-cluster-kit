# shellcheck shell=bash
# ============================================================================
# sdm-proxy-cluster-kit :: src/main.sh  (entry point; last file in the build)
# Picks a mode from KIT_MODE or the 1/2/3 menu and dispatches to
#   mode_install  (src/modes/install.sh)
#   mode_debug    (src/modes/debug.sh)
#   mode_check    (src/modes/check.sh)
# Each mode function owns its own kit_log_init/kit_banner and returns an exit code.
# ============================================================================
# @env KIT_MODE  install | debug | check - skip the menu (required when there is no terminal)
# @env KIT_NONINTERACTIVE  1 = never prompt even if a terminal exists; every input must come from env vars
# @env NO_COLOR  any value disables colour output
kit_main() {
  local choice=""
  case "${1:-}" in
    -h|--help) kit_usage; return 0;;
    --version) echo "$KIT_NAME $KIT_VERSION"; return 0;;
    install|debug|check) KIT_MODE=$1;;
    "") ;;
    *) kit_usage; return $KIT_EXIT_USAGE;;
  esac
  if [ -z "${KIT_MODE:-}" ]; then
    kit_noninteractive && kit_die $KIT_EXIT_USAGE "No mode selected." "There is no terminal to show the menu on." "export KIT_MODE=install   # or debug / check"
    kit_banner "Choose what to do"
    kit_pick choice "What do you want to do on $(kit_hostname)?" \
      "New install   - install or repair a proxy cluster worker (user '$SDM_USER')" \
      "Debug install - verbose logging, follow the logs, auto-revert when done" \
      "Check install - read-only health check, incl. Delinea credential test"
    case $choice in New*) KIT_MODE=install;; Debug*) KIT_MODE=debug;; Check*) KIT_MODE=check;; esac
  fi
  case $KIT_MODE in
    install) mode_install;;
    debug)   mode_debug;;
    check)   mode_check;;
    *) kit_die $KIT_EXIT_USAGE "Unknown KIT_MODE '$KIT_MODE'." "" "export KIT_MODE=install   # or debug / check";;
  esac
}
kit_usage() {
  cat <<EOF
$KIT_NAME $KIT_VERSION - install, debug and check StrongDM proxy cluster workers.
usage: bash $KIT_NAME.sh [install|debug|check]     (no argument = interactive menu)
Non-interactive (cloud-init etc.): set KIT_MODE and the variables listed in README.md.
EOF
}
kit_main "$@"
