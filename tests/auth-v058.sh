#!/bin/sh
# `a && b || failed` below intentionally fails the case if either assertion fails.
# shellcheck disable=SC2015
# Independent policy checks. sshd/id are fixtures; no daemon, login, network,
# service manager, or system SSH config is used. Key labels are synthetic.
set -eu
repo=$(CDPATH=; cd "$(dirname "$0")/.." && pwd)
IKE_TEST_MODE=1; export IKE_TEST_MODE
# shellcheck source-path=SCRIPTDIR/..
# shellcheck source=init.sh
. "$repo/init.sh"
fixture=$(mktemp -d "${TMPDIR:-/tmp}/ssh-init-auth.XXXXXX")
fixture=$(CDPATH=; cd "$fixture" && pwd -P)
trap 'rm -rf "$fixture"' EXIT
trap 'exit 1' HUP INT TERM
TMPDIR=$fixture; IKE_TEST_USER=deploy; IKE_TEST_UID=4100; IKE_TEST_HOME="$fixture/home/deploy"
SSH_CONFIG="$fixture/sshd_config"; RUN_SSHD_DIR="$fixture/run/sshd"
SSH_CONNECTION='192.0.2.3 51000 198.51.100.7 2222'; SSH_INIT_ASSUME_YES=1
export fixture TMPDIR IKE_TEST_USER IKE_TEST_UID IKE_TEST_HOME RUN_SSHD_DIR SSH_CONFIG SSH_CONNECTION SSH_INIT_ASSUME_YES
mkdir -p "$fixture/bin" "$IKE_TEST_HOME"
cat > "$fixture/bin/sshd" <<'MOCK'
#!/bin/sh
[ "$#" -ge 3 ] && [ "$1" = -T ] && [ "$2" = -f ] && [ "$3" = "$SSH_CONFIG" ] || exit 2
if [ "$#" = 3 ]; then cat "$fixture/global"; exit; fi
[ "$#" = 5 ] && [ "$4" = -C ] || exit 2
printf '%s\n' "$5" > "$fixture/connection"
if [ -f "$fixture/context-unavailable" ]; then cat "$fixture/context-unavailable" >&2; exit 3; fi
cat "$fixture/context"
MOCK
cat > "$fixture/bin/id" <<'MOCK'
#!/bin/sh
[ "$1" = -Gn ] && [ "$2" = "$IKE_TEST_USER" ] || exit 2
[ ! -f "$fixture/groups-unavailable" ] || exit 3
printf '%s\n' 'deploy operators'
MOCK
chmod +x "$fixture/bin/sshd" "$fixture/bin/id"
PATH="$fixture/bin:$PATH"; export PATH
make_tmp_dir
: > "$SSH_CONFIG"
printf '%s\n' 'ssh-ed25519 synthetic' > "$fixture/keys"
cat > "$fixture/base" <<'EFFECTIVE'
permitrootlogin without-password
pubkeyauthentication yes
passwordauthentication no
kbdinteractiveauthentication no
permitemptypasswords no
authenticationmethods any
authorizedkeysfile .ssh/authorized_keys .ssh/authorized_keys2
authorizedkeyscommand none
pubkeyacceptedalgorithms rsa-sha2-512,ssh-ed25519
usedns no
EFFECTIVE
cp "$fixture/base" "$fixture/global"; cp "$fixture/base" "$fixture/context"
failed() { printf 'not ok - %s\n' "$*" >&2; cat "$fixture/log" "$fixture/problems" >&2; exit 1; }
okay() { printf 'ok - %s\n' "$*"; }
pre() { auth_preflight "$SSH_CONFIG" "$fixture/keys" > "$fixture/log" 2>&1; }
final_check() { effective_sshd_settings_check "$SSH_CONFIG" "$fixture/problems" "${SSH_INIT_ROOT_POLICY:-prohibit-password}" "$fixture/keys" > "$fixture/log" 2>&1; }
replace_ctx() {
    awk -v k="$1" '$1!=k' "$fixture/context" > "$fixture/changed"
    mv "$fixture/changed" "$fixture/context"
    printf '%s %s\n' "$1" "$2" >> "$fixture/context"
}
reset_case() { cp "$fixture/base" "$fixture/context"; cp "$fixture/base" "$fixture/global"; : > "$SSH_CONFIG"; : > "$fixture/problems"; }
pre_denies() { if pre </dev/null || ! grep -Fq "$1" "$fixture/log"; then failed "$2"; fi; okay "$2"; }
final_denies() { if final_check || ! grep -Fiq "$1" "$fixture/problems"; then failed "$2"; fi; okay "$2"; }
reset_case
pre </dev/null && final_check || failed 'basic target policy'
grep -Fxq 'user=deploy,addr=192.0.2.3,laddr=198.51.100.7,lport=2222,host=192.0.2.3' "$fixture/connection" || failed 'connection attributes'
okay 'target user and actual connection attributes; numerically derived hostname only with UseDNS no'
for loc in '.ssh/authorized_keys' '%h/.ssh/authorized_keys' "$fixture/home/%u/.ssh/authorized_keys"; do
    replace_ctx authorizedkeysfile "other $loc"; pre </dev/null || failed "AuthorizedKeysFile $loc"
done
IKE_TEST_HOME="$fixture/home/4100"; mkdir "$IKE_TEST_HOME"
replace_ctx authorizedkeysfile "$fixture/home/%U/.ssh/authorized_keys"; pre </dev/null || failed '%U in path'
IKE_TEST_HOME="$fixture/home/deploy"; okay 'relative paths, multiple files and %h/%u/%U compare with the actual destination'
for loc in /etc/ssh/other none; do
    replace_ctx authorizedkeysfile "$loc"; pre_denies AuthorizedKeysFile "unread key destination: $loc"
done
replace_ctx authorizedkeyscommand "$fixture/do-not-execute"
pre </dev/null && grep -q AuthorizedKeysCommand "$fixture/log" || failed 'external key source'
okay 'external key commands are not executed or assumed to authorize a key'
reset_case; replace_ctx authorizedkeysfile '%x/keys'; pre </dev/null && grep -q AuthorizedKeysFile "$fixture/log" || failed 'unknown token'; okay 'unresolved token warns instead of guessing'
for method in publickey,password publickey,keyboard-interactive:pam password hostbased; do
    replace_ctx authenticationmethods "$method"; pre_denies AuthenticationMethods "unusable key-only authentication: $method"
done
for method in 'publickey,password publickey' 'publickey,publickey' 'any'; do
    replace_ctx authenticationmethods "$method"; pre </dev/null || failed "AuthenticationMethods $method"
done
okay 'alternative key-only branch is usable; independent MFA factor cannot be proved'
reset_case; replace_ctx pubkeyacceptedalgorithms rsa-sha2-256
pre_denies PubkeyAcceptedAlgorithms 'all imported signatures are excluded'
printf '%s\n' 'ssh-rsa synthetic' >> "$fixture/keys"; pre </dev/null || failed rsa-sha2; okay 'one acceptable imported RSA key suffices for rsa-sha2-256'
for rule in 'denyusers deploy' 'denyusers de?lo*' 'allowusers someoneelse' 'denygroups operators' 'denygroups oper*' 'allowgroups other'; do
    reset_case; replace_ctx "${rule%% *}" "${rule#* }"; pre_denies "${rule%% *}" "effective access rule: $rule"
done
reset_case; replace_ctx allowusers 'deploy@*.example'; pre </dev/null && grep -q allowusers "$fixture/log" || failed 'conditional user rule'
replace_ctx allowgroups other; : > "$fixture/groups-unavailable"; pre </dev/null && grep -q allowgroups "$fixture/log" || failed 'group lookup'; rm "$fixture/groups-unavailable"; okay 'host patterns and unavailable group membership warn only'
for pair in 'pubkeyauthentication no' 'passwordauthentication yes' 'kbdinteractiveauthentication yes' 'permitemptypasswords yes'; do
    reset_case; replace_ctx "${pair%% *}" "${pair#* }"
    if pre </dev/null || ! grep -Fiq "${pair%% *}" "$fixture/log"; then failed "preflight: $pair"; fi
    final_denies "${pair%% *}" "preflight and final -C detect target override: $pair"
done
reset_case; printf 'Match User other\n Include "%s/with spaces.conf"\n' "$fixture" > "$SSH_CONFIG"
printf '%s\n' 'AuthenticationMethods publickey,password' 'AuthorizedKeysFile none' > "$fixture/with spaces.conf"
pre </dev/null && grep -Fq "$fixture/with spaces.conf:1" "$fixture/log" && grep -Fq "$fixture/with spaces.conf:2" "$fixture/log" || failed 'Match Include warning'
okay 'Match Include reports locations without blocking a different user'
printf 'Match Address 192.0.2.*\n Include "%s/with spaces.conf"\n' "$fixture" > "$SSH_CONFIG"; SSH_CONNECTION='invalid'
replace_ctx authorizedkeysfile none; pre </dev/null && grep -q Match "$fixture/log" || failed 'unknown source context'
grep -Fxq 'user=deploy' "$fixture/connection" || failed 'invalid SSH_CONNECTION ignored'; okay 'unknown source Match stays uncertain'
replace_ctx pubkeyacceptedalgorithms ssh-dss; pre_denies PubkeyAcceptedAlgorithms 'unrelated source Match cannot hide an algorithm rejection'
replace_ctx pubkeyacceptedalgorithms rsa-sha2-512; replace_ctx permitrootlogin no; cp "$fixture/context" "$fixture/global"
IKE_TEST_USER=root; IKE_TEST_UID=0; pre_denies PermitRootLogin 'unrelated source Match cannot turn strict root into success'; IKE_TEST_USER=deploy; IKE_TEST_UID=4100
reset_case; printf '%s\n' 'Match Address 192.0.2.*' '  AllowUsers other' > "$SSH_CONFIG"
printf '%s\n' 'Address not specified in connection test specification' > "$fixture/context-unavailable"
pre </dev/null && grep -Fq -- '-T -C' "$fixture/log" || failed 'missing context attribute'; okay 'missing required Match attribute is flagged as unverified'
printf '%s\n' 'AuthenticationMethods cannot be satisfied' > "$fixture/context-unavailable"
pre_denies '校验执行失败' 'independent -C error fails even with incomplete connection information'
reset_case; printf '%s\n' 'Address not specified in connection test specification' > "$fixture/context-unavailable"
pre_denies '校验执行失败' 'without a matching source criterion an unexplained -C error is fatal'; rm "$fixture/context-unavailable"
reset_case
for strict in no forced-commands-only; do
    replace_ctx permitrootlogin "$strict"; cp "$fixture/context" "$fixture/global"
    pre </dev/null && [ "$SSH_INIT_ROOT_POLICY" = "$strict" ] || failed "strict root default $strict"
    printf 'PermitRootLogin %s\nMatch User backup\n    PermitRootLogin no\n' "$strict" > "$SSH_CONFIG"
    write_hardened_sshd_config "$SSH_CONFIG" "$fixture/written" && write_sshd_hardening_dropin_content "$fixture/dropin" || failed 'root writers'
    grep -qx "PermitRootLogin $strict" "$fixture/written" && grep -qx "PermitRootLogin $strict" "$fixture/dropin" && grep -qx '    PermitRootLogin no' "$fixture/written" && final_check || failed 'strict root rendering'
    okay "strict PermitRootLogin $strict survives main/drop-in/final validation; Match unchanged"
done
IKE_TEST_USER=root; IKE_TEST_UID=0; pre_denies PermitRootLogin 'root target cannot open a normal session under forced-commands-only'
pre <<'ANSWER' || failed 'explicit consent'
ROOT
ANSWER
[ "$SSH_INIT_ROOT_POLICY" = prohibit-password ] || failed 'explicit root choice'; okay 'only separate ROOT consent allows relaxing the global strict root setting'
reset_case; replace_ctx permitrootlogin no; pre_denies PermitRootLogin 'target Match still forbids root even when global root policy permits keys'
IKE_TEST_USER=deploy; IKE_TEST_UID=4100; reset_case; awk '$1!="pubkeyauthentication"' "$fixture/base" > "$fixture/global"; final_denies pubkeyauthentication 'missing critical global output cannot pass verification'
printf '%s\n' 'auth-v058: passed'
