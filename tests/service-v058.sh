#!/bin/sh
# Standalone POSIX tests. Every manager is a fixture executable; no host service
# is probed, signalled, started or reloaded. No root or running daemon required.
set -eu
ROOT_DIR=$(CDPATH=; cd "$(dirname "$0")/.." && pwd)
IKE_TEST_MODE=1
export IKE_TEST_MODE
# shellcheck source-path=SCRIPTDIR/..
# shellcheck source=init.sh
. "$ROOT_DIR/init.sh"
SVC_TEST=$(mktemp -d "${TMPDIR:-/tmp}/ssh-init-service.XXXXXX")
trap 'rm -rf "$SVC_TEST"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
RUN_SSHD_DIR=$SVC_TEST/run/sshd
export SVC_TEST RUN_SSHD_DIR
mkdir "$SVC_TEST/bin" "$SVC_TEST/units"
cat > "$SVC_TEST/bin/systemctl" <<'MOCK'
#!/bin/sh
set -eu
case "${0##*/}" in
    systemctl)
        [ "$MOCK_MANAGER" = systemd ] || exit 1
        if [ "$1" = show ]; then
            shift
            case "$*" in
                '-p Version') printf 'Version=255\n'; exit 0 ;;
                '-p Id -p LoadState -p ActiveState -p SubState '*)
                    unit=$9
                    if [ -f "$SVC_TEST/units/$unit" ]; then
                        read -r canonical state < "$SVC_TEST/units/$unit"
                        [ "$state" != query-error ] || exit 1
                        if [ "$state" = orphan ]; then printf 'LoadState=not-found\nActiveState=active\n'; exit 4; fi
                        case "$unit:$state" in
                            *.socket:active) sub=listening ;; *.service:active) sub=running ;;
                            *.service:exited) state=active sub=exited ;; *) sub=dead ;;
                        esac
                        printf 'ActiveState=%s\nSubState=%s\nLoadState=loaded\nId=%s\n' "$state" "$sub" "$canonical"
                    else
                        printf 'LoadState=not-found\n'; exit 4
                    fi ;;
                '-p CanReload -p KillMode -p ExecStop -p ExecStopPost '*)
                    printf 'CanReload=%s\nKillMode=%s\n' "$MOCK_RELOAD" "$MOCK_KILL"
                    if [ "$MOCK_OMIT" = 0 ]; then printf 'ExecStop=%s\nExecStopPost=\n' "$MOCK_STOP"; fi ;;
                '--all -p KillMode -p ExecStop -p ExecStopPost '*)
                    printf 'KillMode=%s\nExecStop=%s\nExecStopPost=\n' "${MOCK_NEW_KILL:-$MOCK_KILL}" "$MOCK_STOP" ;;
                *) exit 125 ;;
            esac
            exit 0
        fi
        action=$1 unit=$2 ;;
    rc-service|service)
        case "${0##*/}:$MOCK_MANAGER" in rc-service:openrc|service:sysv) ;; *) exit 1 ;; esac
        if [ "$1" = -e ]; then [ -f "$SVC_TEST/units/$2.service" ]; exit; fi
        unit=$1.service action=$2
        if [ "$action" = status ]; then
            read -r canonical state < "$SVC_TEST/units/$unit"
            case "$state" in active) exit 0 ;; inactive) exit 3 ;; *) exit 4 ;; esac
        fi ;;
    *) exit 125 ;;
esac
printf '%s %s %s\n' "$MOCK_MANAGER" "$action" "$unit" >> "$SVC_TEST/actions"
case "$action" in
    reload)
        case "$MOCK_OUTCOME" in
            reload-error) exit 1 ;;
            reload-died) printf '%s failed\n' "$unit" > "$SVC_TEST/units/$unit"; exit 1 ;;
            false-success) printf '%s inactive\n' "$unit" > "$SVC_TEST/units/$unit" ;;
        esac ;;
    try-restart) [ "$MOCK_OUTCOME" != restart-error ] ;;
    start) printf '%s active\n' "$unit" > "$SVC_TEST/units/$unit" ;;
    *) exit 125 ;;
esac
MOCK
cp "$SVC_TEST/bin/systemctl" "$SVC_TEST/bin/service"
cp "$SVC_TEST/bin/systemctl" "$SVC_TEST/bin/rc-service"
chmod +x "$SVC_TEST/bin/"*
# A missing or non-executable mock must never fall through to the host PATH.
for tool in cat chmod mkdir rm; do ln -s "$(command -v "$tool")" "$SVC_TEST/bin/$tool"; done
PATH=$SVC_TEST/bin
export PATH
ssh_service_systemd_booted() { [ "$MOCK_MANAGER" = systemd ] || [ "$MOCK_MANAGER" = bus-down ]; }
ssh_service_openrc_booted() { [ "$MOCK_MANAGER" = openrc ]; }
ssh_service_sysv_exists() { [ -f "$SVC_TEST/units/$1.service" ]; }
fixture() {
    MOCK_MANAGER=$1 MOCK_RELOAD=yes MOCK_KILL=control-group MOCK_STOP='' MOCK_OUTCOME=ok MOCK_OMIT=0
    export MOCK_MANAGER MOCK_RELOAD MOCK_KILL MOCK_STOP MOCK_OUTCOME MOCK_OMIT
    rm -f "$SVC_TEST/units/"*
    : > "$SVC_TEST/actions"
}
unit() { printf '%s %s\n' "${3:-$1}" "$2" > "$SVC_TEST/units/$1"; }
expect_actions() {
    actual=$(cat "$SVC_TEST/actions")
    [ "$actual" = "$1" ] || { printf 'actions: expected <%s>, got <%s>\n' "$1" "$actual" >&2; exit 1; }
}
reject() { if "$@"; then printf 'unexpected success: %s\n' "$*" >&2; exit 1; fi; }
ok() { printf 'ok - %s\n' "$1"; }

fixture systemd
unit ssh.service active
unit sshd.service active ssh.service
saved=$(ssh_service_snapshot)
expect_actions ''
restart_ssh_service "$saved"
expect_actions 'systemd reload ssh.service'
ok 'read-only discovery and alias deduplication; one reload, no restart'

fixture systemd
unit ssh.service inactive; unit sshd.service active
unit ssh.socket active
restart_ssh_service
expect_actions 'systemd reload sshd.service'
ok 'target only the active independent daemon, preserve its socket'

fixture systemd
unit ssh.service inactive; unit ssh.socket active
saved=$(ssh_service_snapshot)
restart_ssh_service "$saved"
ssh_service_restore "$saved"
expect_actions ''
unit ssh.socket inactive
ssh_service_restore "$saved"
expect_actions 'systemd start ssh.socket'
ok 'socket-only operation and socket recovery never start the dormant daemon'

fixture systemd
unit sshd.socket active
restart_ssh_service
expect_actions ''
ok 'inetd-style socket with no resident service stays listening'

fixture systemd
unit sshd.service inactive
saved=$(ssh_service_snapshot)
restart_ssh_service "$saved"; ssh_service_restore "$saved"
expect_actions ''
ok 'previously stopped conventional daemon stays stopped'

fixture systemd
unit sshd.service active
MOCK_RELOAD=no MOCK_KILL=process MOCK_OMIT=1
restart_ssh_service
expect_actions 'systemd try-restart sshd.service'
ok 'explicitly unsupported reload: only session-preserving fallback'

fixture systemd
unit ssh.service active
MOCK_OUTCOME=reload-error MOCK_KILL=process
restart_ssh_service
expect_actions 'systemd reload ssh.service
systemd try-restart ssh.service'
ok 'failed reload falls back on the same verified active unit'

fixture systemd
unit ssh.service active
MOCK_OUTCOME=reload-error MOCK_KILL=mixed
reject restart_ssh_service
expect_actions 'systemd reload ssh.service'
: > "$SVC_TEST/actions"
MOCK_RELOAD=no MOCK_KILL=process MOCK_STOP='/bin/custom-stop' MOCK_OMIT=1
reject restart_ssh_service
expect_actions ''
MOCK_RELOAD=yes MOCK_STOP='' MOCK_NEW_KILL=control-group
export MOCK_NEW_KILL
reject restart_ssh_service
expect_actions 'systemd reload ssh.service'
unset MOCK_NEW_KILL
ok 'mixed or changed kill mode and custom stop hooks veto restart'

fixture systemd
unit ssh.service active
saved=$(ssh_service_snapshot)
printf '%s\n' "$saved" > "$SVC_TEST/journal"
MOCK_KILL=process MOCK_OUTCOME=reload-died
reject restart_ssh_service "$saved"
expect_actions 'systemd reload ssh.service'
unset saved
# Durable data alone is enough: drop the live snapshot and restore in a subshell.
( IFS= read -r recovered < "$SVC_TEST/journal"; ssh_service_restore "$recovered" )
expect_actions 'systemd reload ssh.service
systemd start ssh.service'
ok 'interrupted failed reload: recover exactly the originally active daemon'

fixture systemd
unit ssh.service active; unit ssh.socket active
saved=$(ssh_service_snapshot)
unit ssh.service failed; unit ssh.socket inactive
ssh_service_restore "$saved"
expect_actions 'systemd start ssh.socket
systemd start ssh.service'
ok 'recovery reestablishes the original socket before restoring the daemon'

fixture systemd
unit ssh.service active; MOCK_OUTCOME=false-success
reject restart_ssh_service
expect_actions 'systemd reload ssh.service'
ok 'successful manager exit cannot hide inactive postcondition'

fixture systemd
unit ssh.service inactive; unit ssh.socket active
saved=$(ssh_service_snapshot)
unit ssh.service active
reject restart_ssh_service "$saved"; reject ssh_service_restore "$saved"
expect_actions ''
ok 'external activation/race never stops sessions to force a rollback'

fixture systemd
reject ssh_service_snapshot
unit ssh.service active; unit sshd.service active
reject ssh_service_snapshot
unit sshd.service activating
reject ssh_service_snapshot
unit sshd.service query-error
reject ssh_service_snapshot
unit sshd.service exited
reject ssh_service_snapshot
unit sshd.service orphan
reject ssh_service_snapshot
expect_actions ''
ok 'unknown, ambiguous, transient, exited and unqueryable topology fails closed'

fixture systemd
unit ssh.service active
reject ssh_service_restore 'v1:systemd:active:absent:absent:absent:'
# shellcheck disable=SC2016 # This must be a literal string from an untrusted journal.
reject ssh_service_restore 'v1:systemd:active:absent:absent:$(id)'
reject ssh_service_restore 'v1:sysv:active:absent:absent:absent'
reject ssh_service_restore 'v1:systemd:active:absent:absent:absent
systemctl stop ssh.service'
expect_actions ''
ok 'invalid data or a changed manager cannot dispatch actions'

for manager in openrc sysv; do
    fixture "$manager"
    unit sshd.service active; unit ssh.service inactive
    saved=$(ssh_service_snapshot)
    restart_ssh_service "$saved"
    unit sshd.service inactive
    ssh_service_restore "$saved"
    expect_actions "$manager reload sshd.service
$manager start sshd.service"
    : > "$SVC_TEST/actions"
    MOCK_OUTCOME=reload-error
    reject restart_ssh_service "$saved"
    expect_actions "$manager reload sshd.service"
    unit sshd.service query-error
    reject ssh_service_snapshot
    ok "$manager: query actual state, reload active daemon, recover loss, refuse blind restart"
done

fixture bus-down
unit ssh.service active
reject ssh_service_snapshot
expect_actions ''
ok 'a broken running systemd manager never falls through to another backend'
