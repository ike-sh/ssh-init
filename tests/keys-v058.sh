#!/bin/sh
# Independent v0.5.8 checks. Never fetch a real key, touch a real home, or
# invoke service/immutable commands. All files, wrappers and key pairs are local.
set -eu
umask 077
ROOT_DIR=$(CDPATH=; cd "$(dirname "$0")/.." && pwd -P)
IKE_TEST_MODE=1; export IKE_TEST_MODE
# shellcheck source-path=SCRIPTDIR/..
# shellcheck source=init.sh
. "$ROOT_DIR/init.sh"
K_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/ssh-init-keys.XXXXXX")
K_ROOT=$(CDPATH=; cd "$K_ROOT" && pwd -P)
trap 'rm -rf "$K_ROOT"' EXIT
trap 'exit 1' HUP INT TERM
mkdir "$K_ROOT/bin"
for k_cmd in curl wget openssl sshd systemctl service rc-service chattr lsattr; do
    cp "$ROOT_DIR/tests/fixtures/blocked-command.sh" "$K_ROOT/bin/$k_cmd"
    chmod 700 "$K_ROOT/bin/$k_cmd"
done
PATH="$K_ROOT/bin:$PATH"; export PATH
ssh-keygen -q -t ed25519 -N '' -C first -f "$K_ROOT/a"
ssh-keygen -q -t ed25519 -N '' -C second -f "$K_ROOT/b"
A=$(awk '{print $1, $2}' "$K_ROOT/a.pub")
B=$(awk '{print $1, $2}' "$K_ROOT/b.pub")

k_fail() { printf 'not ok - %s\n' "$*" >&2; exit 1; }
k_case() ( k_run_case "$@"; )
k_run_case() {
    k_name=$1
    k_dir=$(mktemp -d "$K_ROOT/case.XXXXXX")
    IKE_TEST_HOME=$k_dir/home; IKE_TEST_UID=$(id -u); IKE_TEST_USER=$(id -un)
    SSH_CONFIG=$k_dir/sshd_config; RUN_SSHD_DIR=$k_dir/run
    TMPDIR=$k_dir; TMP_DIR=''
    export IKE_TEST_HOME IKE_TEST_UID IKE_TEST_USER SSH_CONFIG RUN_SSHD_DIR TMPDIR
    mkdir "$IKE_TEST_HOME"; make_tmp_dir
    k_ssh=$IKE_TEST_HOME/.ssh; k_auth=$k_ssh/authorized_keys
    k_import=$k_dir/import
    printf '%s\n' "$B new" > "$k_import"
    "$k_name"
    [ -z "$(find "$TMP_DIR" -mindepth 1 -print)" ] || k_fail "$k_name left private scratch files"
    [ -z "$(find "$k_dir" -name '.*.ssh-init.*' -print)" ] || k_fail "$k_name left a sibling stage"
    printf 'ok - %s\n' "$k_name"
}

k_existing_restrictions() {
    mkdir "$k_ssh"
    for k_options in 'from="10.0.0.0/8,!10.1.2.3"' 'command="printf \"%s\" hello world"' \
        restrict no-port-forwarding no-agent-forwarding \
        'restrict,from="*.example.test",command="echo \"quoted\" with spaces",no-agent-forwarding'; do
        printf '# header\n\t%s\t%s old comment and tabs\tend' "$k_options" "$A" > "$k_auth"
        chmod 600 "$k_auth"; cp "$k_auth" "$k_dir/expected"
        printf '%s' "$A DIFFERENT COMMENT" > "$k_import"
        append_keys_to_authorized_keys "$k_import" > "$k_dir/out" 2> "$k_dir/err"
        grep -Fq '未验证实际登录' "$k_dir/err"
        cmp "$k_auth" "$k_dir/expected"
        set -- "$k_auth".bak.*; [ ! -e "$1" ] || k_fail 'duplicate made a backup'
    done
    # A key inside command= or inside a comment is NOT an authorization.
    printf 'command="echo %s; echo \"ok\"",restrict %s %s' "$B" "$A" "$B" > "$k_auth"
    cp "$k_auth" "$k_dir/expected"
    printf '\n%s\n' "$B first comment" >> "$k_dir/expected"
    printf '%s\n%s\n%s' "$B first comment" "$A duplicate" "$B duplicate" > "$k_import"
    append_keys_to_authorized_keys "$k_import" >/dev/null
    cmp "$k_auth" "$k_dir/expected"
}

k_filter_identity() {
    printf '%s\n%s\n%s\n%s\n%s\n%s' "$A keep first" 'garbage' "$A another comment" \
        "restrict $B not an import" 'ssh-ed25519 AAAAAAAAAAAAAAAAAAAAAAAAAAAA' "$B final" > "$k_import"
    [ "$(filter_valid_keys "$k_import" "$k_dir/filtered")" = 2 ]
    printf '%s\n%s\n' "$A keep first" "$B final" > "$k_dir/expected"
    cmp "$k_dir/expected" "$k_dir/filtered"
    if filter_valid_keys "$k_dir/absent" "$k_dir/filtered" >/dev/null; then k_fail 'input failure accepted'; fi
    cmp "$k_dir/expected" "$k_dir/filtered"
}

k_atomic_success() {
    prepare_authorized_keys
    [ "$AUTHORIZED_KEYS_FILE" = "$k_auth" ]; [ ! -e "$k_ssh" ]
    mkdir -m 750 "$k_ssh"; printf '# original' > "$k_auth"; chmod 640 "$k_auth"
    k_before=$(stat -c %i "$k_auth"); k_group=$(stat -c %g "$k_auth")
    k_xattr=0
    if command -v python3 >/dev/null 2>&1 && LC_ALL=C cp --help 2>&1 | grep -q xattr &&
        python3 -c 'import os,sys; os.setxattr(sys.argv[1], "user.ssh_init_test", b"original")' "$k_auth" 2>/dev/null; then
        k_xattr=1
    fi
    # Invoked indirectly to inspect the live target immediately before rename.
    # shellcheck disable=SC2317,SC2329
    mv() {
        [ "$1" = -fT ] && [ "$3" = "$k_auth" ] && [ "${2%/*}" = "$k_ssh" ] || return 1
        [ "$(stat -c '%a:%u:%g' "$2")" = "600:$IKE_TEST_UID:$k_group" ] || return 1
        [ "$(stat -c %i "$3")" = "$k_before" ] && [ "$(cat "$3")" = '# original' ] || return 1
        command mv "$@"
    }
    append_keys_to_authorized_keys "$k_import" >/dev/null
    printf '# original\n%s new\n' "$B" > "$k_dir/expected"; cmp "$k_dir/expected" "$k_auth"
    [ "$(stat -c %i "$k_auth")" != "$k_before" ]; [ "$(stat -c %a "$k_ssh")" = 700 ]
    set -- "$k_auth".bak.*; [ "$#" = 1 ]; [ "$(cat "$1")" = '# original' ]
    [ "$(stat -c %i "$1")" != "$k_before" ]; [ "$(stat -c %a "$1")" = 640 ]
    if [ "$k_xattr" = 1 ]; then
        python3 -c 'import os,sys; assert all(os.getxattr(p, "user.ssh_init_test") == b"original" for p in sys.argv[1:])' "$k_auth" "$1"
    fi
}

k_atomic_failure() {
    mkdir -m 750 "$k_ssh"; printf '%s' '# old' > "$k_auth"; chmod 640 "$k_auth"
    cp -p "$k_auth" "$k_dir/reference"; k_meta=$(stat -c '%i:%a:%u:%g' "$k_auth")
    for k_kind in copy mode rename; do
        if (
            # shellcheck disable=SC2317,SC2329
            cat() { if [ "$k_kind" = copy ] && [ "${1:-}" = "${ak_delta:-}" ]; then printf partial; return 1; fi; command cat "$@"; }
            # shellcheck disable=SC2317,SC2329
            chmod() { if [ "$k_kind" = mode ] && [ "$1" = 600 ]; then return 1; fi; command chmod "$@"; }
            # shellcheck disable=SC2317,SC2329
            mv() { if [ "$k_kind" = rename ]; then return 1; fi; command mv "$@"; }
            append_keys_to_authorized_keys "$k_import"
        ) >/dev/null 2>&1; then k_fail "$k_kind failure ignored"; fi
        cmp "$k_auth" "$k_dir/reference"
        [ "$(stat -c '%i:%a:%u:%g' "$k_auth")" = "$k_meta" ]; [ "$(stat -c %a "$k_ssh")" = 750 ]
        set -- "$k_auth".bak.*; [ ! -e "$1" ]
    done
    rm "$k_auth"; rmdir "$k_ssh"
    if (mv() { return 1; }; append_keys_to_authorized_keys "$k_import") >/dev/null 2>&1; then k_fail 'created missing target on failure'; fi
    [ ! -e "$k_ssh" ]
}

k_path_safety() {
    mkdir "$k_dir/outside"; printf sentinel > "$k_dir/outside/untouched"
    ln -s "$k_dir/outside" "$k_ssh"
    if append_keys_to_authorized_keys "$k_import" >/dev/null 2>&1; then k_fail 'linked .ssh accepted'; fi
    rm "$k_ssh"; mkdir -m 750 "$k_ssh"
    for k_target in "$k_dir/outside/untouched" "$k_dir/outside/absent"; do
        ln -s "$k_target" "$k_auth"
        if append_keys_to_authorized_keys "$k_import" >/dev/null 2>&1; then k_fail 'linked auth accepted'; fi
        rm "$k_auth"
    done
    ln "$k_dir/outside/untouched" "$k_auth"
    if append_keys_to_authorized_keys "$k_import" >/dev/null 2>&1; then k_fail 'hardlinked auth accepted'; fi
    rm "$k_auth"; mkfifo "$k_auth"
    if prepare_authorized_keys >/dev/null 2>&1; then k_fail 'FIFO accepted'; fi
    rm "$k_auth"; ln -s "$k_dir" "$k_dir/alias"
    if (IKE_TEST_HOME=$k_dir/alias/home; prepare_authorized_keys) >/dev/null 2>&1; then k_fail 'linked ancestor accepted'; fi
    ln -s "$k_dir/outside/untouched" "$k_ssh/.ssh-init-mode"
    if append_keys_to_authorized_keys "$k_import" >/dev/null 2>&1; then k_fail 'linked test marker accepted'; fi
    [ "$(cat "$k_dir/outside/untouched")" = sentinel ]; [ ! -e "$k_dir/outside/absent" ]
    [ ! -e "$k_auth" ]; [ "$(stat -c %a "$k_ssh")" = 750 ]
}

k_transaction_interface() {
    mkdir "$k_ssh"; printf '%s' "$A restricted" > "$k_auth"
    TX_DIR=$k_dir/pending; mkdir "$TX_DIR"
    tx_snapshot auth "$k_auth"; TX_ACTIVE=1
    append_keys_to_authorized_keys "$k_import" >/dev/null
    [ "$(stat -c %a "$k_auth")" = 600 ]; [ -z "$SSHD_CONFIG_TMP_FILE" ]
    set -- "$k_auth".bak.*; [ ! -e "$1" ] || k_fail 'transaction created independent backup'
    printf '%s' "$A restricted" > "$k_dir/expected"; cmp "$k_dir/expected" "$TX_DIR/auth.data"
    if append_keys_to_authorized_keys "$k_import" >/dev/null 2>&1; then k_fail 'ignored stale transaction snapshot'; fi
    TX_ACTIVE=0
}

k_downloads() {
    mkdir "$k_dir/bin"; PATH="$k_dir/bin:$PATH"; export PATH
    K_LOG=$k_dir/args; export K_LOG A K_KIND K_REPLY
    k_out=$k_dir/output; printf sentinel > "$k_out"
    cat > "$k_dir/bin/wget" <<'MOCK'
#!/bin/sh
if [ "$1" = '--help' ]; then
    case "$K_KIND" in
        gnu) printf 'GNU Wget 1.21.4\n' ;;
        busy) printf 'BusyBox v1.36.1\n--no-check-certificate\n' ;;
        *) printf 'BusyBox v1.31.0\n' ;;
    esac
    exit 0
fi
printf '%s\n' "$*" > "$K_LOG"
case "$K_REPLY" in
    insecure) printf 'wget: note: TLS certificate validation not implemented\n' >&2 ;;
    redirect) printf '  HTTP/1.1 302 Found\n' >&2 ;;
    badcert) printf partial; exit 1 ;;
    empty) exit 0 ;;
esac
printf '  HTTP/1.1 200 OK\n' >&2; printf '%s\n' "$A"
MOCK
    cat > "$k_dir/bin/curl" <<'MOCK'
#!/bin/sh
printf '%s\n' "$*" > "$K_LOG"
case "$K_REPLY" in
    badcert) printf partial; exit 60 ;; empty) exit 0 ;;
    large) dd if=/dev/zero bs=65536 count=17 2>/dev/null; exit $? ;;
esac
printf '%s\n' "$A"
MOCK
    cat > "$k_dir/bin/openssl" <<'MOCK'
#!/bin/sh
[ "$1" = version ]
MOCK
    chmod 700 "$k_dir/bin/"*
    # Force concrete downloader branches; network is always an executable mock.
    command_exists() {
        case "$1:$K_KIND" in curl:curl) ;; curl:*) return 1 ;; esac
        command -v "$1" >/dev/null 2>&1
    }
    for K_KIND in curl gnu busy; do
        K_REPLY=ok; fetch_github_keys valid-user "$k_out" >/dev/null
        grep -Fxq "$A" "$k_out"
        k_args=$(cat "$K_LOG"); case "$K_KIND:$k_args" in
            'curl:'*'--connect-timeout 10 --max-time 30'*'https://github.com/valid-user.keys'|'gnu:'*'--timeout=10'*'https://github.com/valid-user.keys'|'busy:-S -Y off -qO- -T 10 https://github.com/valid-user.keys') ;;
            *) k_fail "unexpected downloader args: $k_args" ;;
        esac
        printf sentinel > "$k_out"; K_REPLY=badcert
        if fetch_github_keys valid-user "$k_out" >/dev/null 2>&1; then k_fail "$K_KIND partial download"; fi
        [ "$(cat "$k_out")" = sentinel ]
    done
    K_KIND=curl; K_REPLY=empty; k_rc=0; fetch_github_keys valid-user "$k_out" >/dev/null 2>&1 || k_rc=$?
    [ "$k_rc" = 2 ]; [ "$(cat "$k_out")" = sentinel ]
    K_REPLY=large; if fetch_github_keys valid-user "$k_out" >/dev/null 2>&1; then k_fail 'accepted oversized response'; fi
    for K_REPLY in insecure redirect; do
        K_KIND=busy; if fetch_github_keys valid-user "$k_out" >/dev/null 2>&1; then k_fail "$K_REPLY TLS accepted"; fi
    done
    K_KIND=unknown; K_REPLY=ok; if fetch_github_keys valid-user "$k_out" >/dev/null 2>&1; then k_fail 'unknown BusyBox TLS accepted'; fi
    rm "$k_out"; printf sentinel > "$k_dir/elsewhere"; ln -s "$k_dir/elsewhere" "$k_out"
    if fetch_github_keys valid-user "$k_out" >/dev/null 2>&1; then k_fail 'linked output accepted'; fi
    [ "$(cat "$k_dir/elsewhere")" = sentinel ]
}

k_deadline_fallback() {
    command_exists() { [ "$1" != timeout ] && command -v "$1" >/dev/null 2>&1; }
    k_rc=0; key_deadline 1 sleep 60 || k_rc=$?; [ "$k_rc" = 124 ]
    k_rc=0; key_deadline 3 sh -c 'exit 7' || k_rc=$?; [ "$k_rc" = 7 ]
}

k_case k_existing_restrictions
k_case k_filter_identity
k_case k_atomic_success
k_case k_atomic_failure
k_case k_path_safety
k_case k_transaction_interface
k_case k_downloads
k_case k_deadline_fallback
