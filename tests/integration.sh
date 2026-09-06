#!/bin/sh

# Real OpenSSH configuration checks, never a live daemon or service restart.
set -eu

ROOT_DIR=$(CDPATH=; cd "$(dirname "$0")/.." && pwd)
case "$(uname -s)" in
    Linux) ;;
    *) printf '%s\n' 'SKIP: OpenSSH integration tests require Linux'; exit 0 ;;
esac
SSHD_BIN=$(command -v sshd || true)
if [ -z "$SSHD_BIN" ] && [ -x /usr/sbin/sshd ]; then
    SSHD_BIN=/usr/sbin/sshd
fi
if [ -z "$SSHD_BIN" ] || ! command -v ssh-keygen >/dev/null 2>&1; then
    printf '%s\n' 'OpenSSH server and ssh-keygen are required for integration tests' >&2
    exit 1
fi

IKE_TEST_MODE=1
export IKE_TEST_MODE
. "$ROOT_DIR/init.sh"
INTEGRATION_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/ssh-init-integration.XXXXXX")
INTEGRATION_ROOT=$(CDPATH=; cd "$INTEGRATION_ROOT" && pwd -P)
TMPDIR=$INTEGRATION_ROOT
SSH_CONFIG="$INTEGRATION_ROOT/sshd_config"
RUN_SSHD_DIR="$INTEGRATION_ROOT/run/sshd"
IKE_TEST_HOME="$INTEGRATION_ROOT/home"
IKE_TEST_USER=$(id -un)
IKE_TEST_UID=$(id -u)
export TMPDIR SSH_CONFIG RUN_SSHD_DIR IKE_TEST_HOME IKE_TEST_USER IKE_TEST_UID
mkdir -p "$IKE_TEST_HOME/.ssh" "$INTEGRATION_ROOT/sshd_config.d"
make_tmp_dir

cleanup_integration() {
    cleanup_tmp
    case "$INTEGRATION_ROOT" in
        /*/ssh-init-integration.*)
            if [ -d "$INTEGRATION_ROOT" ] && [ ! -L "$INTEGRATION_ROOT" ]; then
                integration_resolved=$(CDPATH=; cd "$INTEGRATION_ROOT" && pwd -P)
                [ "$integration_resolved" != "$INTEGRATION_ROOT" ] || rm -rf "$INTEGRATION_ROOT"
            fi
            ;;
    esac
}
trap cleanup_integration EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# Only file/configuration semantics are under test. No service manager is used.
require_root() { return 0; }
restart_ssh_service() {
    printf '%s\n' 'mock restart' >> "$INTEGRATION_ROOT/restarts"
}
find_sshd_bin() { printf '%s\n' "$SSHD_BIN"; }

ssh-keygen -q -t ed25519 -N '' -f "$INTEGRATION_ROOT/host_key"
ssh-keygen -q -t ed25519 -N '' -f "$INTEGRATION_ROOT/user_key"
printf '%s' "$(cat "$INTEGRATION_ROOT/host_key.pub")" > "$IKE_TEST_HOME/.ssh/authorized_keys"
append_keys_to_authorized_keys "$INTEGRATION_ROOT/user_key.pub"
[ "$(ssh-keygen -l -f "$IKE_TEST_HOME/.ssh/authorized_keys" | wc -l | tr -d ' ')" = 2 ]
printf '%s\n' 'ok - real public keys remain separate after an unterminated line'

cat > "$SSH_CONFIG" <<EOF
HostKey $INTEGRATION_ROOT/host_key
PidFile $INTEGRATION_ROOT/sshd.pid
Include $INTEGRATION_ROOT/sshd_config.d/*.conf
UsePAM no
EOF
printf '%s\n' 'PasswordAuthentication yes' 'PermitRootLogin yes' > "$INTEGRATION_ROOT/sshd_config.d/50-cloud-init.conf"
harden_ssh_config
"$SSHD_BIN" -T -f "$SSH_CONFIG" -C "user=$IKE_TEST_USER,host=example.test,addr=192.0.2.10" > "$INTEGRATION_ROOT/effective"
grep -qx 'passwordauthentication no' "$INTEGRATION_ROOT/effective"
grep -qx 'pubkeyauthentication yes' "$INTEGRATION_ROOT/effective"
printf '%s\n' 'ok - real OpenSSH honors hardened drop-in precedence'

cp -p "$SSH_CONFIG" "$INTEGRATION_ROOT/current-main"
cp -p "$INTEGRATION_ROOT/sshd_config.d/00-ssh-init-hardening.conf" "$INTEGRATION_ROOT/current-dropin"
cp -p "$SSH_CONFIG" "$SSH_CONFIG.bak.invalid"
printf '%s\n' 'NotAnOpenSSHOption yes' >> "$SSH_CONFIG.bak.invalid"
if restore_sshd_config_from_backup "$SSH_CONFIG.bak.invalid" > "$INTEGRATION_ROOT/restore-output" 2>&1; then
    printf '%s\n' 'not ok - invalid restored configuration was accepted' >&2
    exit 1
fi
cmp "$SSH_CONFIG" "$INTEGRATION_ROOT/current-main"
cmp "$INTEGRATION_ROOT/sshd_config.d/00-ssh-init-hardening.conf" "$INTEGRATION_ROOT/current-dropin"
"$SSHD_BIN" -t -f "$SSH_CONFIG"
printf '%s\n' 'ok - real sshd validation failure rolls back main and drop-in'

cat > "$SSH_CONFIG" <<EOF
HostKey $INTEGRATION_ROOT/host_key
PidFile $INTEGRATION_ROOT/sshd.pid
PubkeyAuthentication yes
PasswordAuthentication yes
UsePAM no
Match=User $IKE_TEST_USER
    Include = $INTEGRATION_ROOT/match-auth.conf
EOF
printf '%s\n' 'AuthenticationMethods=publickey,password' > "$INTEGRATION_ROOT/match-auth.conf"
"$SSHD_BIN" -T -f "$SSH_CONFIG" -C "user=$IKE_TEST_USER,host=example.test,addr=192.0.2.10" > "$INTEGRATION_ROOT/match-effective"
grep -qx 'authenticationmethods publickey,password' "$INTEGRATION_ROOT/match-effective"
cp -p "$SSH_CONFIG" "$INTEGRATION_ROOT/before-match"
if (harden_ssh_config) > "$INTEGRATION_ROOT/match-output" 2>&1; then
    printf '%s\n' 'not ok - Match Include authentication chain was not blocked' >&2
    exit 1
fi
cmp "$SSH_CONFIG" "$INTEGRATION_ROOT/before-match"
printf '%s\n' 'ok - Match Include authentication chain is blocked before mutation'
printf '%s\n' '4 OpenSSH integration checks passed'
