#!/bin/sh

set -eu

ROOT_DIR=$(CDPATH=; cd "$(dirname "$0")/.." && pwd)
IKE_TEST_MODE=1
export IKE_TEST_MODE
. "$ROOT_DIR/init.sh"

PASS_COUNT=0
FAIL_COUNT=0
VALID_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMockPublicKeyForTestsOnly1234567890 test@example"

pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    printf '%s\n' "ok - $1"
}

fail() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    printf '%s\n' "not ok - $1" >&2
}

assert() {
    name="$1"
    shift
    if "$@"; then
        pass "$name"
    else
        fail "$name"
    fi
}

assert_eq() {
    name="$1"
    expected="$2"
    actual="$3"
    if [ "$expected" = "$actual" ]; then
        pass "$name"
    else
        fail "$name: expected '$expected', got '$actual'"
    fi
}

make_test_dir() {
    mktemp -d "${TMPDIR:-/tmp}/ike-ssh-init-test.XXXXXX"
}

test_parse_args() {
    init_defaults
    parse_args --user=ops --port=2222 --key-raw="$VALID_KEY" --strict --yes --no-firewall --sudo-nopasswd
    assert_eq "parse user" "ops" "$TARGET_USER"
    assert_eq "parse port" "2222" "$SSH_PORT"
    assert_eq "parse strict" "1" "$STRICT_MODE"
    assert_eq "parse yes" "1" "$YES_MODE"
    assert_eq "parse no-firewall" "none" "$FIREWALL_MODE"
    assert_eq "parse sudo-nopasswd" "1" "$SUDO_NOPASSWD"
}

test_key_validation() {
    if normalize_key_line "$VALID_KEY" >/dev/null; then
        pass "valid public key accepted"
    else
        fail "valid public key accepted"
    fi

    if normalize_key_line "ssh-dss AAAABadKey" >/dev/null 2>&1; then
        fail "invalid key type rejected"
    else
        pass "invalid key type rejected"
    fi

    if normalize_key_line "ssh-ed25519 not@base64" >/dev/null 2>&1; then
        fail "invalid key data rejected"
    else
        pass "invalid key data rejected"
    fi
}

test_dry_run_does_not_write() {
    tmp=$(make_test_dir)
    mkdir -p "$tmp/etc/ssh/sshd_config.d" "$tmp/etc/sudoers.d"
    printf '%s\n' "Include $tmp/etc/ssh/sshd_config.d/*.conf" > "$tmp/etc/ssh/sshd_config"

    SSH_CONFIG="$tmp/etc/ssh/sshd_config"
    SSH_CONFIG_D="$tmp/etc/ssh/sshd_config.d"
    SUDOERS_D="$tmp/etc/sudoers.d"
    SSHD_FRAGMENT="$SSH_CONFIG_D/99-ike-hardening.conf"
    BACKUP_ROOT="$tmp/backups"
    IKE_SKIP_ROOT_CHECK=1
    export IKE_SKIP_ROOT_CHECK

    main --dry-run --user=deploy --port=2222 --key-raw="$VALID_KEY" --yes > "$tmp/out"

    if grep -q "\[DRY-RUN\]" "$tmp/out" && [ ! -e "$BACKUP_ROOT" ] && [ ! -e "$SSHD_FRAGMENT" ]; then
        pass "dry-run does not write files"
    else
        fail "dry-run does not write files"
    fi
    safe_rm_rf "$tmp"
}

test_latest_backup_dir() {
    tmp=$(make_test_dir)
    BACKUP_ROOT="$tmp/backups"
    mkdir -p "$BACKUP_ROOT/20260101_000000" "$BACKUP_ROOT/20250101_000000" "$BACKUP_ROOT/20251231_235959" "$BACKUP_ROOT/not-a-backup"
    latest=$(latest_backup_dir)
    assert_eq "rollback-last finds latest backup" "$BACKUP_ROOT/20260101_000000" "$latest"
    safe_rm_rf "$tmp"
}

test_key_gh_whitelist() {
    if is_allowed_gh_user "ike666888" && ! is_allowed_gh_user "not-allowed"; then
        pass "key-gh whitelist"
    else
        fail "key-gh whitelist"
    fi
}

test_port_validation() {
    assert "port 2222 valid" validate_port 2222
    if validate_port 80 || validate_port 1023 || validate_port 65536 || validate_port 8080; then
        fail "invalid ports rejected"
    else
        pass "invalid ports rejected"
    fi
}

test_sudo_nopasswd_logic() {
    line_default=$(sudoers_line deploy 0)
    line_nopass=$(sudoers_line deploy 1)
    case "$line_default" in
        *NOPASSWD*)
            fail "default sudo requires password"
            ;;
        *)
            pass "default sudo requires password"
            ;;
    esac
    case "$line_nopass" in
        *NOPASSWD*)
            pass "sudo-nopasswd emits NOPASSWD"
            ;;
        *)
            fail "sudo-nopasswd emits NOPASSWD"
            ;;
    esac
}

test_user_created_prompt_logic() {
    tmp=$(make_test_dir)
    TARGET_USER=deploy
    SSH_PORT=2222
    BACKUP_DIR="$tmp/backups/20260101_000000"
    USER_CREATED=1
    SUDO_NOPASSWD=0
    post_success_message > "$tmp/out-created"

    USER_CREATED=0
    SUDO_NOPASSWD=0
    post_success_message > "$tmp/out-existing"

    if grep -q "passwd deploy" "$tmp/out-created" && ! grep -q "passwd deploy" "$tmp/out-existing"; then
        pass "USER_CREATED password prompt logic"
    else
        fail "USER_CREATED password prompt logic"
    fi
    safe_rm_rf "$tmp"
}

test_authorized_keys_rejects_bad_home_owner() {
    tmp=$(make_test_dir)
    old_path=$PATH
    mkdir -p "$tmp/bin" "$tmp/home"
    cat > "$tmp/bin/id" <<'MOCK_ID'
#!/bin/sh
if [ "$1" = "-u" ]; then
    printf '%s\n' 99999
    exit 0
fi
exit 1
MOCK_ID
    chmod +x "$tmp/bin/id"
    PATH="$tmp/bin:$PATH"
    PASSWD_FILE="$tmp/passwd"
    export PASSWD_FILE
    printf 'deploy:x:99999:99999::%s:/bin/sh\n' "$tmp/home" > "$PASSWD_FILE"
    printf '%s\n' "$VALID_KEY" > "$tmp/keys"

    if deploy_authorized_keys deploy "$tmp/keys" >/dev/null 2>&1; then
        fail "authorized_keys rejects abnormal home owner"
    else
        pass "authorized_keys rejects abnormal home owner"
    fi

    PATH=$old_path
    unset PASSWD_FILE
    safe_rm_rf "$tmp"
}

test_preflight_rejects_mainthread_port() {
    tmp=$(make_test_dir)
    old_path=$PATH
    mkdir -p "$tmp/bin"
    cat > "$tmp/bin/ss" <<'MOCK_SS'
#!/bin/sh
printf '%s\n' 'State Recv-Q Send-Q Local Address:Port Peer Address:Port Process' 'LISTEN 0 128 0.0.0.0:45678 0.0.0.0:* users:(("MainThread",pid=100,fd=3))'
MOCK_SS
    cat > "$tmp/bin/nc" <<'MOCK_NC'
#!/bin/sh
exit 1
MOCK_NC
    chmod +x "$tmp/bin/ss"
    chmod +x "$tmp/bin/nc"
    PATH="$tmp/bin:$PATH"
    DRY_RUN=0
    STRICT_MODE=0

    if preflight_port_available 45678 > "$tmp/out" 2>"$tmp/err"; then
        fail "preflight rejects MainThread occupied port"
    elif grep -q "MainThread" "$tmp/err"; then
        pass "preflight rejects MainThread occupied port"
    else
        fail "preflight rejects MainThread occupied port"
    fi

    PATH=$old_path
    safe_rm_rf "$tmp"
}

test_preflight_allows_free_port() {
    tmp=$(make_test_dir)
    old_path=$PATH
    mkdir -p "$tmp/bin"
    cat > "$tmp/bin/ss" <<'MOCK_SS'
#!/bin/sh
printf '%s\n' 'State Recv-Q Send-Q Local Address:Port Peer Address:Port Process'
MOCK_SS
    chmod +x "$tmp/bin/ss"
    PATH="$tmp/bin:$PATH"
    DRY_RUN=0
    STRICT_MODE=0

    if preflight_port_available 45678 >/dev/null 2>&1; then
        pass "preflight allows free port"
    else
        fail "preflight allows free port"
    fi

    PATH=$old_path
    safe_rm_rf "$tmp"
}

test_check_ssh_port_listening_rejects_mainthread() {
    tmp=$(make_test_dir)
    old_path=$PATH
    mkdir -p "$tmp/bin"
    cat > "$tmp/bin/ss" <<'MOCK_SS'
#!/bin/sh
printf '%s\n' 'State Recv-Q Send-Q Local Address:Port Peer Address:Port Process' 'LISTEN 0 128 0.0.0.0:45678 0.0.0.0:* users:(("MainThread",pid=100,fd=3))'
MOCK_SS
    chmod +x "$tmp/bin/ss"
    PATH="$tmp/bin:$PATH"

    if check_ssh_port_listening 45678 >/dev/null 2>&1; then
        fail "check_ssh_port_listening rejects MainThread"
    else
        pass "check_ssh_port_listening rejects MainThread"
    fi

    PATH=$old_path
    safe_rm_rf "$tmp"
}

test_check_ssh_port_listening_accepts_sshd() {
    tmp=$(make_test_dir)
    old_path=$PATH
    mkdir -p "$tmp/bin"
    cat > "$tmp/bin/ss" <<'MOCK_SS'
#!/bin/sh
printf '%s\n' 'State Recv-Q Send-Q Local Address:Port Peer Address:Port Process' 'LISTEN 0 128 0.0.0.0:45679 0.0.0.0:* users:(("sshd",pid=101,fd=3))'
MOCK_SS
    chmod +x "$tmp/bin/ss"
    PATH="$tmp/bin:$PATH"

    if check_ssh_port_listening 45679; then
        pass "check_ssh_port_listening accepts sshd"
    else
        fail "check_ssh_port_listening accepts sshd"
    fi

    PATH=$old_path
    safe_rm_rf "$tmp"
}

test_wait_for_ssh_port_eventual_success() {
    tmp=$(make_test_dir)
    old_path=$PATH
    mkdir -p "$tmp/bin"
    cat > "$tmp/bin/ss" <<'MOCK_SS'
#!/bin/sh
count=0
if [ -f "$MOCK_SS_STATE" ]; then
    count=$(cat "$MOCK_SS_STATE")
fi
count=$((count + 1))
printf '%s\n' "$count" > "$MOCK_SS_STATE"
printf '%s\n' 'State Recv-Q Send-Q Local Address:Port Peer Address:Port Process'
if [ "$count" -ge 3 ]; then
    printf '%s\n' 'LISTEN 0 128 0.0.0.0:45680 0.0.0.0:* users:(("sshd",pid=102,fd=3))'
fi
MOCK_SS
    cat > "$tmp/bin/nc" <<'MOCK_NC'
#!/bin/sh
exit 1
MOCK_NC
    chmod +x "$tmp/bin/ss"
    chmod +x "$tmp/bin/nc"
    PATH="$tmp/bin:$PATH"
    MOCK_SS_STATE="$tmp/ss-count"
    WAIT_SSH_PORT_SECONDS=3
    WAIT_SSH_PORT_INTERVAL=0
    export MOCK_SS_STATE WAIT_SSH_PORT_SECONDS WAIT_SSH_PORT_INTERVAL

    if wait_for_ssh_port 45680; then
        pass "wait_for_ssh_port eventual success"
    else
        fail "wait_for_ssh_port eventual success"
    fi

    PATH=$old_path
    unset MOCK_SS_STATE WAIT_SSH_PORT_SECONDS WAIT_SSH_PORT_INTERVAL
    safe_rm_rf "$tmp"
}

test_restart_prefers_restart() {
    tmp=$(make_test_dir)
    old_path=$PATH
    mkdir -p "$tmp/bin"
    cat > "$tmp/bin/systemctl" <<'MOCK_SYSTEMCTL'
#!/bin/sh
printf '%s\n' "systemctl $*" >> "$MOCK_SERVICE_LOG"
if [ "$1" = "restart" ] && [ "$2" = "ssh" ]; then
    exit 0
fi
exit 1
MOCK_SYSTEMCTL
    chmod +x "$tmp/bin/systemctl"
    PATH="$tmp/bin:$PATH"
    MOCK_SERVICE_LOG="$tmp/service.log"
    RUN_SSHD_DIR="$tmp/run/sshd"
    export MOCK_SERVICE_LOG

    if reload_sshd_service && [ "$(sed -n '1p' "$MOCK_SERVICE_LOG")" = "systemctl restart ssh" ]; then
        pass "restart function prefers restart"
    else
        fail "restart function prefers restart"
    fi

    PATH=$old_path
    unset MOCK_SERVICE_LOG
    safe_rm_rf "$tmp"
}

test_ensure_run_sshd_dir() {
    tmp=$(make_test_dir)
    RUN_SSHD_DIR="$tmp/run/sshd"

    if ensure_run_sshd_dir &&
        [ -d "$RUN_SSHD_DIR" ] &&
        find "$RUN_SSHD_DIR" -prune -perm 755 | grep -q .; then
        pass "ensure_run_sshd_dir creates directory"
    else
        fail "ensure_run_sshd_dir creates directory"
    fi

    safe_rm_rf "$tmp"
}

test_sshd_config_d_write() {
    tmp=$(make_test_dir)
    mkdir -p "$tmp/etc/ssh/sshd_config.d"
    printf '%s\n' "Include $tmp/etc/ssh/sshd_config.d/*.conf" > "$tmp/etc/ssh/sshd_config"

    SSH_CONFIG="$tmp/etc/ssh/sshd_config"
    SSH_CONFIG_D="$tmp/etc/ssh/sshd_config.d"
    SSHD_FRAGMENT="$SSH_CONFIG_D/99-ike-hardening.conf"
    BACKUP_DIR="$tmp/backups/20260101_000000"
    SSH_PORT=2222

    write_ssh_hardening_config >/dev/null

    if [ -f "$SSHD_FRAGMENT" ] &&
        grep -q "Port 2222" "$SSHD_FRAGMENT" &&
        grep -q "PasswordAuthentication no" "$SSHD_FRAGMENT" &&
        ! grep -q "IKE-SSH-INIT MANAGED BLOCK" "$SSH_CONFIG" &&
        find "$SSHD_FRAGMENT" -prune -perm 644 | grep -q .; then
        pass "sshd_config.d fragment write"
    else
        fail "sshd_config.d fragment write"
    fi
    safe_rm_rf "$tmp"
}

test_parse_args
test_key_validation
test_dry_run_does_not_write
test_latest_backup_dir
test_key_gh_whitelist
test_port_validation
test_sudo_nopasswd_logic
test_user_created_prompt_logic
test_authorized_keys_rejects_bad_home_owner
test_preflight_rejects_mainthread_port
test_preflight_allows_free_port
test_check_ssh_port_listening_rejects_mainthread
test_check_ssh_port_listening_accepts_sshd
test_wait_for_ssh_port_eventual_success
test_restart_prefers_restart
test_ensure_run_sshd_dir
test_sshd_config_d_write

if [ "$FAIL_COUNT" -gt 0 ]; then
    printf '%s\n' "$FAIL_COUNT test(s) failed" >&2
    exit 1
fi

printf '%s\n' "$PASS_COUNT test(s) passed"
