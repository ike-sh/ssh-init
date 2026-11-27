#!/bin/sh

# Real sshd -t/-T only. No listeners, signals, system services or host config.
set -eu
ROOT_DIR=$(CDPATH=; cd "$(dirname "$0")/.." && pwd)
case "$(uname -s)" in Linux) ;; *) echo 'SKIP: OpenSSH integration tests require Linux'; exit 0 ;; esac
SSHD_BIN=$(command -v sshd || true)
if [ -z "$SSHD_BIN" ] && [ -x /usr/sbin/sshd ]; then SSHD_BIN=/usr/sbin/sshd; fi
if [ -z "$SSHD_BIN" ] || ! command -v ssh-keygen >/dev/null 2>&1; then
    echo 'OpenSSH server and ssh-keygen are required for integration tests' >&2; exit 1
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
SSH_CONNECTION='192.0.2.10 31400 192.0.2.20 22222'
export TMPDIR SSH_CONFIG RUN_SSHD_DIR IKE_TEST_HOME IKE_TEST_USER IKE_TEST_UID SSH_CONNECTION
mkdir -p "$IKE_TEST_HOME/.ssh" "$INTEGRATION_ROOT/sshd_config.d" "$INTEGRATION_ROOT/bin"
make_tmp_dir
cleanup_integration() {
    cleanup_tmp
    case "$INTEGRATION_ROOT" in
        /*/ssh-init-integration.*)
            if [ -d "$INTEGRATION_ROOT" ] && [ ! -L "$INTEGRATION_ROOT" ]; then
                integration_resolved=$(CDPATH=; cd "$INTEGRATION_ROOT" && pwd -P)
                [ "$integration_resolved" != "$INTEGRATION_ROOT" ] || rm -rf "$INTEGRATION_ROOT"
            fi ;;
    esac
}
trap cleanup_integration EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

for cmd in service systemctl rc-service chattr lsattr curl wget; do
    cp "$ROOT_DIR/tests/fixtures/blocked-command.sh" "$INTEGRATION_ROOT/bin/$cmd"
    chmod +x "$INTEGRATION_ROOT/bin/$cmd"
done
# Exercise the real parser, but reject any accidental daemon invocation.
cat > "$INTEGRATION_ROOT/bin/sshd" <<'SH'
#!/bin/sh
case "$1" in -t|-T) ;; *) exit 125 ;; esac
[ "$2" = -f ] && [ "$3" = "$SSH_CONFIG" ] || exit 125
printf '%s\n' "$*" >> "$INTEGRATION_ROOT/sshd-calls"
exec "$SSHD_BIN" "$@"
SH
chmod +x "$INTEGRATION_ROOT/bin/sshd"
PATH="$INTEGRATION_ROOT/bin:$PATH"
export PATH SSHD_BIN INTEGRATION_ROOT
require_root() { return 0; }
ssh_service_snapshot() { printf '%s\n' isolated-service; }
restart_ssh_service() { [ "$#" = 1 ] && [ "$1" = isolated-service ] && echo apply >> "$INTEGRATION_ROOT/actions"; }
ssh_service_restore() { [ "$#" = 1 ] && [ "$1" = isolated-service ] && echo restore >> "$INTEGRATION_ROOT/actions"; }
: > "$INTEGRATION_ROOT/actions"

auth_file=$IKE_TEST_HOME/.ssh/authorized_keys
managed=$INTEGRATION_ROOT/sshd_config.d/00-ssh-init-hardening.conf
base_config() {
    printf 'HostKey %s/host_key\nPidFile %s/sshd.pid\nUseDNS no\n' "$INTEGRATION_ROOT" "$INTEGRATION_ROOT"
}
dump_for() {
    sshd -T -f "$SSH_CONFIG" -C "user=$1,host=192.0.2.10,addr=192.0.2.10,laddr=192.0.2.20,lport=22222"
}
backup_list() { find "$INTEGRATION_ROOT" \( -name 'batch.*' -o -name '*.bak.*' -o -name '*.before-restore.*' \) -print | LC_ALL=C sort; }
assert_rejected() {
    cp -p "$SSH_CONFIG" "$INTEGRATION_ROOT/before-main"
    cp -p "$auth_file" "$INTEGRATION_ROOT/before-auth"
    cp -p "$managed" "$INTEGRATION_ROOT/before-drop"
    cp "$INTEGRATION_ROOT/actions" "$INTEGRATION_ROOT/before-actions"
    backup_list > "$INTEGRATION_ROOT/before-backups"
    : > "$INTEGRATION_ROOT/sshd-calls"
    if (harden_ssh_config "$INTEGRATION_ROOT/probe.pub") > "$INTEGRATION_ROOT/rejection" 2>&1; then
        echo "not ok - unexpectedly accepted $1" >&2; exit 1
    fi
    grep -Fq -- "-C user=$IKE_TEST_USER" "$INTEGRATION_ROOT/sshd-calls"
    grep -Fqi "$2" "$INTEGRATION_ROOT/rejection" || { cat "$INTEGRATION_ROOT/rejection" >&2; exit 1; }
    cmp "$SSH_CONFIG" "$INTEGRATION_ROOT/before-main"
    cmp "$auth_file" "$INTEGRATION_ROOT/before-auth"
    cmp "$managed" "$INTEGRATION_ROOT/before-drop"
    cmp "$INTEGRATION_ROOT/actions" "$INTEGRATION_ROOT/before-actions"
    backup_list > "$INTEGRATION_ROOT/after-backups"
    cmp "$INTEGRATION_ROOT/before-backups" "$INTEGRATION_ROOT/after-backups"
}

for key in host_key user_key probe; do ssh-keygen -q -t ed25519 -N '' -f "$INTEGRATION_ROOT/$key"; done
printf '%s' "$(cat "$INTEGRATION_ROOT/host_key.pub")" > "$auth_file"
append_keys_to_authorized_keys "$INTEGRATION_ROOT/user_key.pub"
[ "$(ssh-keygen -l -f "$auth_file" | wc -l | tr -d ' ')" = 2 ]
printf '%s\n' 'ok - real public keys remain separate after an unterminated line'

base_config > "$SSH_CONFIG"
printf 'Include %s/sshd_config.d/*.conf\n' "$INTEGRATION_ROOT" >> "$SSH_CONFIG"
printf '%s\n' 'PasswordAuthentication yes' 'PermitRootLogin yes' > "$INTEGRATION_ROOT/sshd_config.d/50-cloud-init.conf"
harden_ssh_config
dump_for "$IKE_TEST_USER" > "$INTEGRATION_ROOT/effective"
grep -qx 'passwordauthentication no' "$INTEGRATION_ROOT/effective"
grep -qx 'pubkeyauthentication yes' "$INTEGRATION_ROOT/effective"
printf '%s\n' 'ok - real OpenSSH honors hardened drop-in precedence'

cp -p "$SSH_CONFIG" "$INTEGRATION_ROOT/current-main"
cp -p "$managed" "$INTEGRATION_ROOT/current-dropin"
cp -p "$SSH_CONFIG" "$SSH_CONFIG.bak.20260101_000000"
printf '%s\n' 'NotAnOpenSSHOption yes' >> "$SSH_CONFIG.bak.20260101_000000"
: > "$INTEGRATION_ROOT/sshd-calls"
if restore_sshd_config_from_backup "$SSH_CONFIG.bak.20260101_000000" > "$INTEGRATION_ROOT/restore-output" 2>&1; then
    echo 'not ok - invalid restored configuration was accepted' >&2; exit 1
fi
grep -q '^-t ' "$INTEGRATION_ROOT/sshd-calls"
cmp "$SSH_CONFIG" "$INTEGRATION_ROOT/current-main"
cmp "$managed" "$INTEGRATION_ROOT/current-dropin"
sshd -t -f "$SSH_CONFIG"
printf '%s\n' 'ok - real sshd validation failure rolls back main and drop-in'

base_config > "$SSH_CONFIG"
printf 'PubkeyAuthentication yes\nPasswordAuthentication yes\nMatch=User %s\n    Include = %s/match-auth.conf\n' "$IKE_TEST_USER" "$INTEGRATION_ROOT" >> "$SSH_CONFIG"
printf '%s\n' 'AuthenticationMethods=publickey,password' > "$INTEGRATION_ROOT/match-auth.conf"
dump_for "$IKE_TEST_USER" > "$INTEGRATION_ROOT/effective"
grep -qx 'authenticationmethods publickey,password' "$INTEGRATION_ROOT/effective"
assert_rejected 'target MFA' 'AuthenticationMethods publickey,password：脚本会禁用'
printf '%s\n' 'ok - target Match Include authentication chain rejects the import and preserves all files'

for kind in path algorithm; do
    base_config > "$SSH_CONFIG"
    printf 'Match User %s\n' "$IKE_TEST_USER" >> "$SSH_CONFIG"
    case "$kind" in
        path) directive='AuthorizedKeysFile .ssh/other'; effective='authorizedkeysfile .ssh/other'; reason='不读取脚本写入路径' ;;
        algorithm) directive='PubkeyAcceptedAlgorithms rsa-sha2-512'; effective='pubkeyacceptedalgorithms rsa-sha2-512'; reason='不接受任何待导入密钥' ;;
    esac
    printf '    %s\n' "$directive" >> "$SSH_CONFIG"
    dump_for "$IKE_TEST_USER" > "$INTEGRATION_ROOT/effective"
    grep -Fxq "$effective" "$INTEGRATION_ROOT/effective"
    assert_rejected "$kind" "$reason"
    printf 'ok - target-only %s mismatch rejected before changing keys, config, backups or service\n' "$kind"
done

# An incompatible Match for someone else is real and active, but must not
# prevent this user's import. Check both actual -C views, not just global -T.
other=ssh-init-other
[ "$other" != "$IKE_TEST_USER" ] || other=ssh-init-another
{
    base_config
    printf 'Match User %s\n' "$other"
    printf '%s\n' '    AuthenticationMethods publickey,password' '    PasswordAuthentication yes' \
        '    AuthorizedKeysFile .ssh/elsewhere' '    PubkeyAcceptedAlgorithms rsa-sha2-512'
    printf 'Match User %s\n' "$IKE_TEST_USER"
    printf '%s\n' '    AuthorizedKeysFile %h/.ssh/authorized_keys' '    PubkeyAcceptedAlgorithms ssh-ed25519'
} > "$SSH_CONFIG"
harden_ssh_config "$INTEGRATION_ROOT/probe.pub"
grep -Fxq "$(cat "$INTEGRATION_ROOT/probe.pub")" "$auth_file"
dump_for "$IKE_TEST_USER" > "$INTEGRATION_ROOT/target"
dump_for "$other" > "$INTEGRATION_ROOT/non-target"
grep -qx 'passwordauthentication no' "$INTEGRATION_ROOT/target"
grep -qx 'pubkeyacceptedalgorithms ssh-ed25519' "$INTEGRATION_ROOT/target"
grep -Fqx 'authorizedkeysfile %h/.ssh/authorized_keys' "$INTEGRATION_ROOT/target"
grep -qx 'authenticationmethods publickey,password' "$INTEGRATION_ROOT/non-target"
grep -qx 'authorizedkeysfile .ssh/elsewhere' "$INTEGRATION_ROOT/non-target"
[ "$(wc -l < "$INTEGRATION_ROOT/actions" | tr -d ' ')" = 2 ]
printf '%s\n' 'ok - compatible target path and algorithm succeed despite a conflicting non-target Match'
printf '%s\n' '7 OpenSSH integration checks passed'
