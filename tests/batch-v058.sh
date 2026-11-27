#!/bin/sh
# Real restore entrypoints and transactions; no host config or service commands.
set -eu
REPO=$(CDPATH='' cd -P "$(dirname "$0")/.." && pwd -P)
TOP=$(CDPATH='' cd -P "${TMPDIR:-/tmp}" && pwd -P)
[ "$TOP" != / ] || exit 1
T=$(mktemp -d "$TOP/ssh-init-batches.XXXXXX")
fixture_ok() {
    case "$T" in "$TOP"/ssh-init-batches.??????) ;; *) return 1 ;; esac
    [ -d "$T" ] && [ ! -L "$T" ] && [ "$(CDPATH='' cd -P "$T" && pwd -P)" = "$T" ]
}
fixture_ok || exit 1
IKE_TEST_MODE=1 IKE_TEST_HOME=$T/home IKE_TEST_USER=$(id -un) IKE_TEST_UID=$(id -u)
SSH_CONFIG="$T/with space/sshd_config" RUN_SSHD_DIR=$T/run/sshd TMPDIR=$T
export IKE_TEST_MODE IKE_TEST_HOME IKE_TEST_USER IKE_TEST_UID SSH_CONFIG RUN_SSHD_DIR TMPDIR
mkdir -p "$T/bin" "$IKE_TEST_HOME" "${SSH_CONFIG%/*}/sshd_config.d" "$T/other/sshd_config.d"
for cmd in systemctl service rc-service sshd curl wget lsattr chattr; do
    cp "$REPO/tests/fixtures/blocked-command.sh" "$T/bin/$cmd"; chmod 700 "$T/bin/$cmd"
done
PATH=$T/bin:$PATH; export PATH
# shellcheck source=/dev/null
. "$REPO/init.sh"
finish() { if fixture_ok; then rm -rf "$T"; fi; }
trap finish EXIT
trap 'exit 1' HUP INT TERM
# These hooks are invoked indirectly by init.sh. Durability is tested separately.
# shellcheck disable=SC2317,SC2329
require_root() { fixture_ok; }
# shellcheck disable=SC2317,SC2329
ssh_service_snapshot() { printf 'fixture\n'; }
# shellcheck disable=SC2317,SC2329
restart_ssh_service() { [ "$1" = fixture ] && printf 'apply\n' >> "$T/service"; }
# shellcheck disable=SC2317,SC2329
ssh_service_restore() { [ "$1" = fixture ] && printf 'rollback\n' >> "$T/service"; }
# shellcheck disable=SC2317,SC2329
validate_sshd_config() { [ -s "$SSH_CONFIG" ] && ! grep -qx Broken "$SSH_CONFIG"; }
# shellcheck disable=SC2317,SC2329
show_effective_ssh_config() { :; }
# shellcheck disable=SC2317,SC2329
sync() { :; }
make_tmp_dir
ak=$(current_auth_file); c=$SSH_CONFIG; d=${ak%/*}; state=$c.ssh-init.d
[ "$ak" = "$T/home/.ssh/authorized_keys" ]; mkdir -m 750 "$d"
printf 'current-auth\n' > "$ak"; chmod 640 "$ak"; printf 'current-main\n' > "$c"
: > "$T/service"; printf '3\n' > "$T/input"
reject() {
    if "$@" > "$T/rejected" 2>&1; then printf 'unexpected success: %s\n' "$*" >&2; exit 1; fi
    [ ! -d "$state/lock" ]; [ ! -d "$state/pending" ]
}
# Legacy menu 3: independent newest files are never a pair. Once an older
# shared timestamp exists it is the only eligible pair, with an explicit warning.
printf 'main-newest\n' > "$c.bak.20261102_020202"; printf 'auth-newest\n' > "$ak.bak.20261103_030303"
reject restore_menu < "$T/input"
grep -qx current-main "$c"; grep -qx current-auth "$ak"; [ ! -s "$T/service" ]
old_c=$c.bak.20261101_010101; old_a=$ak.bak.20261101_010101
printf 'main-one\n' > "$old_c"; printf 'auth-one\n' > "$old_a"
restore_menu < "$T/input" > "$T/selected" 2>&1
grep -q '无法确定' "$T/selected"; grep -qx main-one "$c"; grep -qx auth-one "$ak"
b1=$(find_restore_batch both); [ "$b1" = "$state/batch.000000000001" ]
grep -qx current-main "$b1/main.data"; grep -qx current-auth "$b1/auth.data"
printf '%s\n' 'ok - menu refuses unrelated latest files; legacy pair uses the same timestamp with warning'

clear_authorized_keys > "$T/clear" 2>&1; b2=$(find_restore_batch auth); [ "$b2" = "$state/batch.000000000002" ]
[ ! -s "$ak" ]; grep -qx auth-one "$b2/auth.data"
reject restore_sshd_and_authorized_keys_from_backups "$b1/main.data" "$b2/auth.data"
reject restore_sshd_and_authorized_keys_from_backups "$old_c" "$b2/auth.data"
ln -s "$state" "$T/alias"
reject restore_sshd_and_authorized_keys_from_backups "$T/alias/batch.000000000001/main.data" "$T/alias/batch.000000000002/auth.data"
[ ! -s "$ak" ]; grep -qx main-one "$c"; [ "$(wc -l < "$T/service")" -eq 1 ]
restore_latest_backup both > "$T/selected" 2>&1
grep -qx current-main "$c"; grep -qx current-auth "$ak"; [ "$(stat -c %a "$d")" = 750 ]; [ "$(stat -c %a "$ak")" = 640 ]
printf '%s\n' 'ok - newer auth-only batch does not mix with combined restore; original file and directory modes restored'

b3=$(find_restore_batch both); cp "$b3/main.path" "$T/saved.path"; printf '%s\n' "$T/victim" > "$b3/main.path"
reject restore_latest_backup both; [ ! -e "$T/victim" ]; grep -qx current-main "$c"; grep -qx current-auth "$ak"
[ "$(wc -l < "$T/service")" -eq 2 ]; cp "$T/saved.path" "$b3/main.path"
mv "$b3/main.data" "$T/linked-data"; ln -s "$T/linked-data" "$b3/main.data"
reject restore_latest_backup both; [ "$(wc -l < "$T/service")" -eq 2 ]; rm "$b3/main.data"; mv "$T/linked-data" "$b3/main.data"
mkdir "$state/batch.000000000004"; cp "$b3/main.meta" "$state/batch.000000000004/main.meta"
pick=$(find_restore_batch main 2> "$T/warning"); [ "$pick" = "$b3" ]; grep -q 'batch.000000000004' "$T/warning"
rm "$state/batch.000000000004/main.meta"; rmdir "$state/batch.000000000004"
printf '%s\n' 'ok - corrupt paths and symlinked data fail closed; incomplete latest batch is skipped with warning'

rm "$ak" "$ak".bak.*; rmdir "$d"; clear_authorized_keys > "$T/clear" 2>&1
missing=$(find_restore_batch auth); grep -qx absent "$missing/auth.meta"; grep -qx absent "$missing/sshdir.meta"
restore_authorized_keys_from_backup "$missing" > "$T/selected" 2>&1; [ ! -e "$d" ]
created=$(find_restore_batch auth); restore_authorized_keys_from_backup "$created" > "$T/selected" 2>&1
[ -f "$ak" ]; [ ! -s "$ak" ]; [ "$(stat -c %a "$ak")" = 600 ]; [ "$(stat -c %a "$d")" = 700 ]
printf '%s\n' 'ok - clear and replay round-trip an originally absent authorized_keys and .ssh parent'

x=${c%/*}/sshd_config.d/00-ssh-init-hardening.conf; y=$T/other/sshd_config.d/00-ssh-init-hardening.conf
stamp=20261104_040404; cross=$c.bak.$stamp
printf 'Include "%s/with space/sshd_config.d/*.conf"\n' "$T" > "$c"; printf 'Include %s/other/sshd_config.d/*.conf\n' "$T" > "$cross"
printf 'orig-x\n' > "$x"; printf 'orig-y\n' > "$y"; printf 'old-x\n' > "$x.bak.$stamp"; printf 'old-y\n' > "$y.bak.$stamp"
printf 'wrong\n' > "$y.bak.20261105_050505"; cp "$c" "$T/main.before"
restore_sshd_config_from_backup "$cross" > "$T/selected" 2>&1; grep -qx old-x "$x"; grep -qx old-y "$y"; cmp "$c" "$cross"
undo=$(find_restore_batch main); restore_sshd_config_from_backup "$undo" > "$T/selected" 2>&1
grep -qx orig-x "$x"; grep -qx orig-y "$y"; cmp "$T/main.before" "$c"
corrupt=$(find_restore_batch main); printf '%s\n' "$T/victim" > "$corrupt/drop.path"; reject restore_sshd_config_from_backup "$corrupt"
[ ! -e "$T/victim" ]; grep -qx orig-x "$x"; grep -qx orig-y "$y"; cmp "$T/main.before" "$c"
printf '%s\n' 'ok - both historical Include directories restored without choosing a newer unrelated drop-in'

# Explicit historical APIs intentionally honor caller-chosen independent files.
printf 'explicit-auth\n' > "$ak.before-clear.20261106_060606"
restore_sshd_and_authorized_keys_from_backups "$old_c" "$ak.before-clear.20261106_060606" > "$T/selected" 2>&1
grep -q '无法确定' "$T/selected"; grep -qx main-one "$c"; grep -qx explicit-auth "$ak"
rm "$ak"; printf 'sentinel\n' > "$T/victim"; ln -s "$T/victim" "$ak"
reject clear_authorized_keys; [ -L "$ak" ]; grep -qx sentinel "$T/victim"
printf '%s\n' 'ok - explicit historical files remain usable; clear refuses a symlinked destination'
