#!/usr/bin/env bash

pass() { echo "  [PASS] $*"; }
info() { echo "  [INFO] $*"; }
ok()   { echo "  [OK] $*"; }
warn() { echo "  [WARN] $*"; }
err()  { echo "  [ERR] $*"; }

run_module_action() {
    local action="$1"
    shift

    case "$action" in
        install|update)
            install "$@"
            verify "$@"
            ;;
        reinstall)
            uninstall "$@"
            install "$@"
            verify "$@"
            ;;
        uninstall)
            uninstall "$@"
            ;;
        verify)
            verify "$@"
            ;;
        status)
            status "$@"
            ;;
        doctor)
            doctor "$@"
            ;;
        *)
            err "不支持的 ACTION: $action"
            return 1
            ;;
    esac
}

remove_symlink_if_target() {
    local path="$1"
    local expected_target="$2"

    [[ -L "$path" ]] || return 0
    [[ "$(readlink -f "$path")" == "$(readlink -f "$expected_target")" ]] || return 0

    rm -f "$path"
}
