#!/bin/sh

# Remote-only harness. The caller owns fixture creation and daemon lifecycle.
# Never run this against the machine's primary sshd configuration or service.
# Use /run: StrictModes rejects authorized keys below world-writable /tmp.
set -eu

e2e_fail() {
    printf 'remote-sandbox: %s\n' "$*" >&2
    exit 1
}

[ "$#" -eq 2 ] || e2e_fail 'usage: remote-sandbox.sh ROOT ACTION'
E2E_ROOT=$1
E2E_ACTION=$2
case "$E2E_ACTION" in
    append|harden|restore|invalid-restore|gen) ;;
    *) e2e_fail 'unsupported action' ;;
esac
case "$E2E_ROOT" in
    /run/ssh-init-e2e.*) ;;
    *) e2e_fail 'sandbox root must be /run/ssh-init-e2e.SUFFIX' ;;
esac
E2E_SUFFIX=${E2E_ROOT#/run/ssh-init-e2e.}
case "$E2E_SUFFIX" in
    ''|*[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789]*)
        e2e_fail 'invalid sandbox suffix' ;;
esac
if [ ! -d "$E2E_ROOT" ] || [ -L "$E2E_ROOT" ]; then
    e2e_fail 'invalid sandbox directory'
fi
E2E_RESOLVED=$(CDPATH=; cd "$E2E_ROOT" && pwd -P)
[ "$E2E_RESOLVED" = "$E2E_ROOT" ] || e2e_fail 'sandbox root is not canonical'
[ "$(id -u)" = 0 ] || e2e_fail 'real root privileges are required'
[ -z "$(find "$E2E_ROOT" -type l -print -quit)" ] || e2e_fail 'sandbox contains a symlink'
[ -f "$E2E_ROOT/init.sh" ] || e2e_fail 'sandbox init.sh is missing'
[ -f "$E2E_ROOT/sshd_config" ] || e2e_fail 'sandbox sshd_config is missing'
[ -d "$E2E_ROOT/home" ] || e2e_fail 'sandbox home is missing'
readonly E2E_ROOT E2E_ACTION

SSH_CONFIG="$E2E_ROOT/sshd_config"
RUN_SSHD_DIR="$E2E_ROOT/run/sshd"
IKE_TEST_HOME="$E2E_ROOT/home"
IKE_TEST_USER=root
IKE_TEST_UID=0
TMPDIR=$E2E_ROOT
IKE_TEST_MODE=1
export SSH_CONFIG RUN_SSHD_DIR IKE_TEST_HOME IKE_TEST_USER IKE_TEST_UID TMPDIR IKE_TEST_MODE
# shellcheck source-path=SCRIPTDIR/..
# shellcheck source=init.sh
. "$E2E_ROOT/init.sh"
# Retain path overrides, but exercise real ownership and permission handling.
IKE_TEST_MODE=0
export IKE_TEST_MODE
require_root
make_tmp_dir || e2e_fail 'cannot initialize private temporary directory'
E2E_TMP_DIR=$TMP_DIR
readonly E2E_TMP_DIR

e2e_cleanup() {
    # Never remove the fixture root or any directory belonging to another run.
    [ "${TMP_DIR:-}" = "$E2E_TMP_DIR" ] || return 1
    case "$E2E_TMP_DIR" in
        "$E2E_ROOT"/ssh-init.*) ;;
        *) return 1 ;;
    esac
    [ -d "$E2E_TMP_DIR" ] && [ ! -L "$E2E_TMP_DIR" ] || return 0
    E2E_CLEANUP_RESOLVED=$(CDPATH=; cd "$E2E_TMP_DIR" && pwd -P) || return 1
    [ "$E2E_CLEANUP_RESOLVED" = "$E2E_TMP_DIR" ] || return 1
    case "${SSHD_CONFIG_TMP_FILE:-}" in
        ''|"$E2E_ROOT"/.*.ssh-init.*) ;;
        *) SSHD_CONFIG_TMP_FILE='' ;;
    esac
    cleanup_tmp
}
trap e2e_cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

e2e_require_inside() {
    case "$1" in
        "$E2E_ROOT"/*) ;;
        *) e2e_fail 'configuration references a path outside the sandbox' ;;
    esac
    case "$1" in
        */../*|*/..|*/./*|*/.|*//*) e2e_fail 'non-canonical configuration path' ;;
    esac
}

e2e_check_config_tree() (
    E2E_CHECK_FILE=$1
    E2E_CHECK_DEPTH=${2:-0}
    [ "$E2E_CHECK_DEPTH" -le 16 ] || e2e_fail 'Include recursion limit exceeded'
    e2e_require_inside "$E2E_CHECK_FILE"
    if [ ! -f "$E2E_CHECK_FILE" ] || [ -L "$E2E_CHECK_FILE" ]; then
        e2e_fail 'invalid configuration source'
    fi
    E2E_CHECK_PATTERNS=$(config_file_include_patterns "$E2E_CHECK_FILE" all) ||
        e2e_fail 'cannot parse Include directives'
    while IFS= read -r E2E_CHECK_PATTERN; do
        [ -n "$E2E_CHECK_PATTERN" ] || continue
        e2e_require_inside "$E2E_CHECK_PATTERN"
        E2E_CHECK_MATCHES=$(list_path_matches "$E2E_CHECK_PATTERN") ||
            e2e_fail 'cannot resolve sandbox Include'
        while IFS= read -r E2E_CHECK_CHILD; do
            [ -n "$E2E_CHECK_CHILD" ] || continue
            e2e_check_config_tree "$E2E_CHECK_CHILD" "$((E2E_CHECK_DEPTH + 1))" || exit 1
        done <<EOF
$E2E_CHECK_MATCHES
EOF
    done <<EOF
$E2E_CHECK_PATTERNS
EOF
)

e2e_check_effective_paths() {
    E2E_SSHD_BIN=$(find_sshd_bin) || e2e_fail 'sshd is unavailable'
    "$E2E_SSHD_BIN" -T -f "$SSH_CONFIG" > "$E2E_TMP_DIR/effective" ||
        e2e_fail 'cannot read effective sandbox configuration'
    awk -v root="$E2E_ROOT/" '
        function inside(value) {
            return index(value, root) == 1 && value !~ /\/\.\.?($|\/)/ && value !~ /\/\//
        }
        $1 == "hostkey" || $1 == "pidfile" || $1 == "authorizedkeysfile" {
            seen[$1] = 1
            for (i = 2; i <= NF; i++) if (!inside($i)) bad = 1
        }
        $1 == "listenaddress" {
            listener = 1
            if ($2 !~ /^127[.]0[.]0[.]1:[0-9]+$/) bad = 1
            split($2, address, ":")
            if (address[2] <= 1024 || address[2] > 65535) bad = 1
        }
        $1 == "authorizedkeyscommand" && $2 != "none" { bad = 1 }
        END {
            exit (bad || !listener || !seen["hostkey"] || !seen["pidfile"] || !seen["authorizedkeysfile"])
        }
    ' "$E2E_TMP_DIR/effective" || e2e_fail 'effective paths or listener escape sandbox policy'
}

e2e_verify_listener_pid() {
    [ -f "$E2E_ROOT/launch.pid" ] && [ ! -L "$E2E_ROOT/launch.pid" ] || return 1
    E2E_RELOAD_PID=$(cat "$E2E_ROOT/launch.pid") || return 1
    case "$E2E_RELOAD_PID" in
        ''|*[!0123456789]*) return 1 ;;
    esac
    [ "$E2E_RELOAD_PID" -gt 1 ] || return 1
    kill -0 "$E2E_RELOAD_PID" 2>/dev/null || return 1
    case "$(readlink "/proc/$E2E_RELOAD_PID/exe" 2>/dev/null)" in
        */sshd) ;;
        *) return 1 ;;
    esac
    # sshd may replace its argv with a single process-title string. Split both
    # NUL-delimited argv and that title, and require the exact -f argument.
    tr '\000' ' ' < "/proc/$E2E_RELOAD_PID/cmdline" |
        awk -v config="$SSH_CONFIG" '
            { for (i = 1; i < NF; i++) if ($i == "-f" && $(i + 1) == config) found = 1 }
            END { exit !found }
        '
}

# This override is mandatory: init.sh otherwise restarts the real SSH service.
restart_ssh_service() {
    e2e_check_config_tree "$SSH_CONFIG" || return 1
    e2e_check_effective_paths || return 1
    validate_sshd_config || return 1
    e2e_verify_listener_pid || return 1
    [ -f "$E2E_ROOT/sshd.log" ] && [ ! -L "$E2E_ROOT/sshd.log" ] || return 1
    E2E_RELOAD_BEFORE=$(grep -c 'Server listening on ' "$E2E_ROOT/sshd.log" || true)
    kill -HUP "$E2E_RELOAD_PID" || return 1
    E2E_RELOAD_ATTEMPT=0
    while [ "$E2E_RELOAD_ATTEMPT" -lt 5 ]; do
        sleep 1
        kill -0 "$E2E_RELOAD_PID" 2>/dev/null || return 1
        E2E_RELOAD_AFTER=$(grep -c 'Server listening on ' "$E2E_ROOT/sshd.log" || true)
        if [ "$E2E_RELOAD_AFTER" -gt "$E2E_RELOAD_BEFORE" ]; then
            return 0
        fi
        E2E_RELOAD_ATTEMPT=$((E2E_RELOAD_ATTEMPT + 1))
    done
    return 1
}

e2e_check_config_tree "$SSH_CONFIG"
e2e_check_effective_paths

case "$E2E_ACTION" in
    append)
        [ -f "$E2E_ROOT/key-b.pub" ] || e2e_fail 'key-b.pub is missing'
        E2E_VALID_KEYS="$E2E_TMP_DIR/key-b.valid"
        E2E_KEY_COUNT=$(filter_valid_keys "$E2E_ROOT/key-b.pub" "$E2E_VALID_KEYS") ||
            e2e_fail 'cannot validate key-b.pub'
        [ "$E2E_KEY_COUNT" -eq 1 ] || e2e_fail 'expected exactly one public key'
        append_keys_to_authorized_keys "$E2E_VALID_KEYS"
        ;;
    harden)
        harden_ssh_config
        ;;
    restore)
        E2E_CONFIG_BACKUP=$(latest_sshd_backup) || e2e_fail 'configuration backup is missing'
        E2E_AUTH_BACKUP=$(latest_authorized_keys_backup) || e2e_fail 'authorized_keys backup is missing'
        e2e_require_inside "$E2E_AUTH_BACKUP"
        e2e_check_config_tree "$E2E_CONFIG_BACKUP"
        restore_sshd_and_authorized_keys_from_backups "$E2E_CONFIG_BACKUP" "$E2E_AUTH_BACKUP"
        ;;
    invalid-restore)
        E2E_DROPIN="$E2E_ROOT/sshd_config.d/00-ssh-init-hardening.conf"
        cp -p "$SSH_CONFIG" "$E2E_TMP_DIR/main-before"
        cp -p "$SSH_CONFIG" "$E2E_TMP_DIR/invalid-config"
        printf '\nInvalidSshInitSandboxOption yes\n' >> "$E2E_TMP_DIR/invalid-config"
        E2E_DROPIN_EXISTED=0
        if [ -f "$E2E_DROPIN" ]; then
            E2E_DROPIN_EXISTED=1
            cp -p "$E2E_DROPIN" "$E2E_TMP_DIR/dropin-before"
        fi
        if restore_sshd_config_from_backup "$E2E_TMP_DIR/invalid-config" > "$E2E_TMP_DIR/restore-output" 2>&1; then
            e2e_fail 'invalid configuration was accepted'
        fi
        cmp "$SSH_CONFIG" "$E2E_TMP_DIR/main-before" || e2e_fail 'failed restore changed main configuration'
        if [ "$E2E_DROPIN_EXISTED" -eq 1 ]; then
            cmp "$E2E_DROPIN" "$E2E_TMP_DIR/dropin-before" || e2e_fail 'failed restore changed drop-in'
        else
            [ ! -e "$E2E_DROPIN" ] || e2e_fail 'failed restore created a drop-in'
        fi
        validate_sshd_config || e2e_fail 'rolled-back configuration is invalid'
        printf '%s\n' 'ok - invalid restore preserved main configuration and drop-in'
        ;;
    gen)
        # No tee or output redirection: the caller parses private-key stdout
        # in memory and supplies interactive yes/SAVED responses over stdin.
        gen_mode
        ;;
esac
