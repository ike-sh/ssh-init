#!/bin/sh
# Independent subprocesses exercise the real lock, journal and dispatch traps.
# Only the fixture's service, sshd and immutable interfaces are simulated.
set -eu
ROOT=$(CDPATH=; cd "$(dirname "$0")/.." && pwd)
self=$ROOT/tests/txn-v058.sh
if [ "${1:-}" = worker ]; then
    D=$2 ACTION=$3
    IKE_TEST_MODE=1 IKE_TEST_HOME=$D/home IKE_TEST_USER=$(id -un) IKE_TEST_UID=$(id -u)
    SSH_CONFIG=$D/sshd_config RUN_SSHD_DIR=$D/run TMPDIR=$D
    export IKE_TEST_MODE IKE_TEST_HOME IKE_TEST_USER IKE_TEST_UID SSH_CONFIG RUN_SSHD_DIR TMPDIR
    . "$ROOT/init.sh"
    make_tmp_dir
    # All callbacks run indirectly in the sourced deployment script.
    # shellcheck disable=SC2317,SC2329
    require_root() { :; }
    # shellcheck disable=SC2317,SC2329
    auth_preflight() { SSH_INIT_ROOT_POLICY=prohibit-password; }
    # shellcheck disable=SC2317,SC2329
    effective_sshd_settings_check() { [ "$ACTION" != effective ]; }
    # shellcheck disable=SC2317,SC2329
    validate_sshd_config() { grep -Fq 'Port 22345' "$SSH_CONFIG" && [ "$ACTION" != syntax ]; }
    # shellcheck disable=SC2317,SC2329
    ssh_service_snapshot() { printf 'fixture\n'; }
    # shellcheck disable=SC2317,SC2329
    is_immutable_file() { [ "$1" = "$SSH_CONFIG" ] && [ -f "$D/immutable" ]; }
    # shellcheck disable=SC2317,SC2329
    chattr() {
        [ "$2" = "$SSH_CONFIG" ] || return 1
        case "$1" in -i) rm "$D/immutable" ;; +i) : > "$D/immutable" ;; *) return 1 ;; esac
    }
    # shellcheck disable=SC2317,SC2329
    ssh_service_restore() { [ "$1" = fixture ] && printf 'restore\n' >> "$D/service" && [ "$ACTION" != double-fail ]; }
    # shellcheck disable=SC2317,SC2329
    restart_ssh_service() {
        if [ "$ACTION" = both ]; then
            [ "$1" = fixture ] && cmp "$SSH_CONFIG" "$D/before" && [ ! -e "$IKE_TEST_HOME/.ssh/authorized_keys" ]; return $?
        fi
        [ "$1" = fixture ] && grep -q '^PasswordAuthentication no$' "$SSH_CONFIG" &&
            grep -q 'fixture-key' "$IKE_TEST_HOME/.ssh/authorized_keys" || return 1
        printf 'apply\n' >> "$D/service"
        case "$ACTION" in
            service|double-fail) return 1 ;;
            TERM|INT|HUP|KILL) kill -s "$ACTION" "$$" ;;
        esac
    }
    if [ "$ACTION" = keys-write ]; then
        # Fail only the authorization rename (never the lock/journal rename).
        # shellcheck disable=SC2317,SC2329
        mv() { for target do :; done; [ "$target" != "$IKE_TEST_HOME/.ssh/authorized_keys" ] && command mv "$@"; }
    fi
    if [ "$ACTION" = attr-error ]; then
        # Simulate a read error rather than incorrectly declaring +i clear.
        # shellcheck disable=SC2317,SC2329
        is_immutable_file() { return 2; }
    fi
    if [ -f "$D/no-flock" ]; then
        # shellcheck disable=SC2317,SC2329
        command_exists() { [ "$1" != flock ] && command -v "$1" >/dev/null 2>&1; }
    fi
    case "$ACTION" in
        clear) clear_authorized_keys ;;
        both) restore_latest_backup both ;;
        recover) with_write_lock true ;;
        help) usage ;;
        inspect-drop) sshd_hardening_dropin_path "$SSH_CONFIG" ;;
        hold)
            # Called by the lock wrapper.
            # shellcheck disable=SC2317,SC2329
            hold() { : > "$D/ready"; while [ ! -f "$D/release" ]; do sleep 0.1; done; }; with_write_lock hold ;;
        *) harden_ssh_config "$D/keys" ;;
    esac
    exit $?
fi
BASE=$(mktemp -d "${TMPDIR:-/tmp}/ssh-init-transactions.XXXXXX")
held=''
finish() { if [ -n "$held" ]; then : > "$D/release"; wait "$held" || :; fi; rm -rf "$BASE"; }
trap finish 0
trap 'exit 1' HUP INT TERM
new_case() {
    D=$BASE/$1; mkdir -p "$D/home" "$D/sshd_config.d"
    printf 'Port 22345\nInclude %s/sshd_config.d/*.conf\nPasswordAuthentication yes\n' "$D" > "$D/sshd_config"
    chmod 640 "$D/sshd_config"; cp -p "$D/sshd_config" "$D/before"
    printf '%s\n' 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBHiTtwHOMyc2QbrXv/15/f/TmESu5rAxMdF31qhnU8g fixture-key' > "$D/keys"
    state=$D/sshd_config.ssh-init.d; ak=$D/home/.ssh/authorized_keys
    : > "$D/immutable"
}
run_worker() { sh "$self" worker "$D" "$1" > "$D/log.$1" 2>&1; }
pristine() {
    cmp "$D/before" "$D/sshd_config" && [ "$(stat -c %a "$D/sshd_config")" = 640 ] &&
        [ ! -e "$D/sshd_config.d/00-ssh-init-hardening.conf" ] && [ -f "$D/immutable" ] && [ ! -e "$state/lock" ]
}
count_batches() { find "$state" -type d -name 'batch.*' | wc -l | tr -d ' '; }
for reason in attr-error keys-write syntax effective service TERM HUP INT; do
    new_case "$reason"
    if run_worker "$reason"; then printf 'expected failure: %s\n' "$reason" >&2; exit 1; fi
    if ! pristine || [ -e "$D/home/.ssh" ] || [ -e "$state/pending" ] || [ "$(count_batches)" != 0 ]; then cat "$D/log.$reason" >&2; exit 1; fi
    case "$reason" in attr-error|keys-write|syntax|effective) [ ! -f "$D/service" ] ;; *) [ "$(cat "$D/service")" = "$(printf 'apply\nrestore')" ] ;; esac
    printf 'ok - %s restores originally absent keys, config, drop-in and immutable\n' "$reason"
done
new_case double-fail
mkdir -m 750 "$D/home/.ssh"; printf 'original restriction, no LF' > "$ak"; chmod 640 "$ak"; cp -p "$ak" "$D/auth.before"
if run_worker double-fail; then exit 1; fi
pristine; cmp "$ak" "$D/auth.before"; [ "$(stat -c %a "$ak")" = 640 ]; [ "$(stat -c %a "$D/home/.ssh")" = 750 ]
[ -f "$state/pending/active" ]; grep -q '未完整回滚' "$D/log.double-fail"
printf 'RECOVER\n' > "$D/answer"
if run_worker recover < "$D/answer"; then exit 1; fi
[ ! -d "$state/pending" ]; [ "$(wc -l < "$D/service" | tr -d ' ')" = 3 ]
printf '%s\n' 'ok - rollback service failure retains journal, reports failure and permits retry'
new_case kill
: > "$D/no-flock"
if run_worker KILL; then exit 1; fi
[ -f "$state/pending/active" ]; [ ! -f "$D/immutable" ]; grep -q 'fixture-key' "$ak"
if run_worker recover < /dev/null; then exit 1; fi
[ -f "$state/pending/active" ]; grep -q 'fixture-key' "$ak"
if run_worker recover < "$BASE/double-fail/answer"; then exit 1; fi
pristine; [ ! -e "$ak" ]; [ ! -e "$state/pending" ]; [ "$(cat "$D/service")" = "$(printf 'apply\nrestore')" ]
printf '%s\n' 'ok - SIGKILL leaves a recoverable journal; stale fallback lock is reclaimed'
for lock in flock fallback; do
    new_case "$lock"; [ "$lock" != fallback ] || : > "$D/no-flock"
    sh "$self" worker "$D" hold > "$D/holder" 2>&1 & held=$!
    n=0; while [ ! -e "$D/ready" ]; do n=$((n+1)); [ "$n" -lt 100 ] || exit 1; sleep 0.1; done
    run_worker help
    if run_worker clear; then exit 1; fi
    [ -d "$state/lock" ]; [ ! -e "$ak" ]; : > "$D/release"; wait "$held"; held=''
    [ ! -e "$state/lock" ]; printf 'ok - %s excludes second writer without blocking help\n' "$lock"
done
new_case batch
run_worker success; [ "$(count_batches)" = 1 ]; [ -f "$D/immutable" ]
run_worker success; [ "$(count_batches)" = 1 ]; [ ! -e "$state/pending" ]
run_worker clear; [ "$(count_batches)" = 2 ]; [ ! -s "$ak" ]
# The newest auth-only batch must not be paired with the old main backup.
# Restore validation uses the original Permit/Port policy, not hardened values.
# Use a restore-specific service hook, not the hardening-only assertion above.
if ! run_worker both; then cat "$D/log.both" >&2; exit 1; fi
pristine; [ ! -e "$ak" ]; [ "$(count_batches)" = 3 ]
printf '%s\n' 'ok - unchanged operation creates no backup; combined restore uses one complete batch'
new_case includes
printf 'Include %s/sshd_config.d/50-other.conf\n' "$D" > "$D/sshd_config"
if run_worker inspect-drop; then exit 1; fi
printf 'Include %s/sub.conf\n' "$D" > "$D/sshd_config"
printf 'Include %s/sshd_config.d/*.conf\n' "$D" > "$D/sub.conf"
run_worker inspect-drop
[ "$(cat "$D/log.inspect-drop")" = "$D/sshd_config.d/00-ssh-init-hardening.conf" ]
printf '%s\n' 'ok - nested global Include selects only masks that actually load the managed name'
