#!/bin/sh

set -eu

ROOT_DIR=$(CDPATH=; cd "$(dirname "$0")/.." && pwd)
IKE_TEST_MODE=1
export IKE_TEST_MODE
. "$ROOT_DIR/init.sh"

PASS_COUNT=0
FAIL_COUNT=0
VALID_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMockPublicKeyForTestsOnly1234567890 test@example"
VALID_KEY_2="ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCMockPublicKeyForTestsOnly1234567890 test@example"

pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    printf '%s\n' "ok - $1"
}

fail() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    printf '%s\n' "not ok - $1" >&2
}

make_test_dir() {
    mktemp -d "${TMPDIR:-/tmp}/ssh-init-test.XXXXXX"
}

setup_home() {
    tmp="$1"
    mkdir -p "$tmp/home"
    IKE_TEST_USER="testuser"
    IKE_TEST_HOME="$tmp/home"
    IKE_TEST_UID=$(owner_uid "$IKE_TEST_HOME")
    export IKE_TEST_USER IKE_TEST_HOME IKE_TEST_UID
}

clear_test_user() {
    unset IKE_TEST_USER IKE_TEST_HOME IKE_TEST_UID
}

write_keys_file() {
    file="$1"
    shift
    : > "$file"
    for key in "$@"; do
        printf '%s\n' "$key" >> "$file"
    done
}

has_mode() {
    path="$1"
    mode="$2"
    marker=$(mode_marker_path "$path")
    if [ -f "$marker" ] && [ "$(sed -n '1p' "$marker")" = "$mode" ]; then
        return 0
    fi
    actual=$(stat -c %a "$path" 2>/dev/null || true)
    [ "$actual" = "$mode" ] && return 0
    find "$path" -prune -perm "$mode" | grep -q .
}

test_github_username_validation() {
    if validate_github_username "ike-sh" &&
        validate_github_username "abc123" &&
        ! validate_github_username "" &&
        ! validate_github_username "-bad" &&
        ! validate_github_username "bad-" &&
        ! validate_github_username "bad_name"; then
        pass "GitHub username validation"
    else
        fail "GitHub username validation"
    fi
}

test_public_key_validation() {
    if normalize_key_line "$VALID_KEY" >/dev/null &&
        normalize_key_line "$VALID_KEY_2" >/dev/null &&
        ! normalize_key_line "ssh-dss AAAABadKey" >/dev/null 2>&1 &&
        ! normalize_key_line "ssh-ed25519 not@base64" >/dev/null 2>&1; then
        pass "public key validation"
    else
        fail "public key validation"
    fi
}

test_github_keys_filtering() {
    tmp=$(make_test_dir)
    raw="$tmp/raw"
    valid="$tmp/valid"
    {
        printf '%s\n' "$VALID_KEY"
        printf '%s\n' "bad-key"
        printf '%s\n' "$VALID_KEY"
        printf '%s\n' "$VALID_KEY_2"
    } > "$raw"
    count=$(filter_valid_keys "$raw" "$valid")
    if [ "$count" = "2" ] && grep -Fxq "$VALID_KEY" "$valid" && grep -Fxq "$VALID_KEY_2" "$valid"; then
        pass "GitHub .keys content filtering"
    else
        fail "GitHub .keys content filtering"
    fi
    rm -rf "$tmp"
}

test_authorized_keys_append_dedup_and_permissions() {
    tmp=$(make_test_dir)
    setup_home "$tmp"
    keys="$tmp/keys"
    write_keys_file "$keys" "$VALID_KEY"
    append_keys_to_authorized_keys "$keys" >/dev/null
    append_keys_to_authorized_keys "$keys" >/dev/null
    auth="$IKE_TEST_HOME/.ssh/authorized_keys"
    count=$(grep -Fc "$VALID_KEY" "$auth")
    if [ "$count" = "1" ] &&
        has_mode "$auth" 600 &&
        has_mode "$IKE_TEST_HOME/.ssh" 700; then
        pass "authorized_keys dedup and permissions"
    else
        fail "authorized_keys dedup and permissions"
    fi
    clear_test_user
    rm -rf "$tmp"
}

test_symlink_ssh_rejected() {
    tmp=$(make_test_dir)
    setup_home "$tmp"
    keys="$tmp/keys"
    write_keys_file "$keys" "$VALID_KEY"
    IKE_TEST_SYMLINK_PATH="$IKE_TEST_HOME/.ssh"
    export IKE_TEST_SYMLINK_PATH
    if (append_keys_to_authorized_keys "$keys" >/dev/null 2>&1); then
        fail "symlink .ssh rejected"
    else
        pass "symlink .ssh rejected"
    fi
    unset IKE_TEST_SYMLINK_PATH
    clear_test_user
    rm -rf "$tmp"
}

test_symlink_authorized_keys_rejected() {
    tmp=$(make_test_dir)
    setup_home "$tmp"
    mkdir -p "$IKE_TEST_HOME/.ssh"
    IKE_TEST_SYMLINK_PATH="$IKE_TEST_HOME/.ssh/authorized_keys"
    export IKE_TEST_SYMLINK_PATH
    keys="$tmp/keys"
    write_keys_file "$keys" "$VALID_KEY"
    if (append_keys_to_authorized_keys "$keys" >/dev/null 2>&1); then
        fail "symlink authorized_keys rejected"
    else
        pass "symlink authorized_keys rejected"
    fi
    unset IKE_TEST_SYMLINK_PATH
    clear_test_user
    rm -rf "$tmp"
}

test_sshd_config_settings() {
    tmp=$(make_test_dir)
    in="$tmp/sshd_config"
    out="$tmp/out"
    {
        printf '%s\n' "PasswordAuthentication yes"
        printf '%s\n' "PubkeyAuthentication no"
        printf '%s\n' "Port 22"
    } > "$in"
    write_hardened_sshd_config "$in" "$out"
    if grep -q '^PubkeyAuthentication yes$' "$out" &&
        grep -q '^PasswordAuthentication no$' "$out" &&
        grep -q '^ChallengeResponseAuthentication no$' "$out" &&
        grep -q '^KbdInteractiveAuthentication no$' "$out" &&
        grep -q '^PermitEmptyPasswords no$' "$out" &&
        grep -q '^PermitRootLogin prohibit-password$' "$out"; then
        pass "sshd_config hardening settings"
    else
        fail "sshd_config hardening settings"
    fi
    rm -rf "$tmp"
}

test_sshd_t_failure_restores_backup() {
    tmp=$(make_test_dir)
    old_path=$PATH
    mkdir -p "$tmp/bin"
    SSH_CONFIG="$tmp/sshd_config"
    RUN_SSHD_DIR="$tmp/run/sshd"
    IKE_TEST_UID=0
    export IKE_TEST_UID
    printf '%s\n' "PasswordAuthentication yes" > "$SSH_CONFIG"
    cat > "$tmp/bin/sshd" <<'MOCK_SSHD'
#!/bin/sh
exit 1
MOCK_SSHD
    chmod +x "$tmp/bin/sshd"
    PATH="$tmp/bin:$PATH"
    if (harden_ssh_config >/dev/null 2>&1); then
        fail "sshd -t failure restores backup"
    elif grep -q '^PasswordAuthentication yes$' "$SSH_CONFIG"; then
        pass "sshd -t failure restores backup"
    else
        fail "sshd -t failure restores backup"
    fi
    PATH=$old_path
    unset IKE_TEST_UID
    rm -rf "$tmp"
}

test_restart_failure_restores_backup() {
    tmp=$(make_test_dir)
    old_path=$PATH
    mkdir -p "$tmp/bin"
    SSH_CONFIG="$tmp/sshd_config"
    RUN_SSHD_DIR="$tmp/run/sshd"
    IKE_TEST_UID=0
    export IKE_TEST_UID
    printf '%s\n' "PasswordAuthentication yes" > "$SSH_CONFIG"
    cat > "$tmp/bin/sshd" <<'MOCK_SSHD'
#!/bin/sh
exit 0
MOCK_SSHD
    cat > "$tmp/bin/systemctl" <<'MOCK_SYSTEMCTL'
#!/bin/sh
exit 1
MOCK_SYSTEMCTL
    cat > "$tmp/bin/service" <<'MOCK_SERVICE'
#!/bin/sh
exit 1
MOCK_SERVICE
    cat > "$tmp/bin/rc-service" <<'MOCK_RC'
#!/bin/sh
exit 1
MOCK_RC
    chmod +x "$tmp/bin/sshd" "$tmp/bin/systemctl" "$tmp/bin/service" "$tmp/bin/rc-service"
    PATH="$tmp/bin:$PATH"
    if (harden_ssh_config >/dev/null 2>&1); then
        fail "restart failure restores backup"
    elif grep -q '^PasswordAuthentication yes$' "$SSH_CONFIG"; then
        pass "restart failure restores backup"
    else
        fail "restart failure restores backup"
    fi
    PATH=$old_path
    unset IKE_TEST_UID
    rm -rf "$tmp"
}

test_gen_without_ssh_keygen_fails() {
    tmp=$(make_test_dir)
    old_path=$PATH
    PATH="$tmp"
    if (generate_ed25519_key_pair >/dev/null 2>&1); then
        fail "gen mode without ssh-keygen fails"
    else
        pass "gen mode without ssh-keygen fails"
    fi
    PATH=$old_path
    rm -rf "$tmp"
}

test_gen_mock_ed25519() {
    tmp=$(make_test_dir)
    old_path=$PATH
    mkdir -p "$tmp/bin"
    cat > "$tmp/bin/ssh-keygen" <<'MOCK_KEYGEN'
#!/bin/sh
out=""
while [ "$#" -gt 0 ]; do
    if [ "$1" = "-f" ]; then
        out="$2"
        shift 2
    else
        shift
    fi
done
printf '%s\n' '-----BEGIN OPENSSH PRIVATE KEY-----' 'mock' '-----END OPENSSH PRIVATE KEY-----' > "$out"
printf '%s\n' 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMockGeneratedKey1234567890 ssh-init-generated' > "$out.pub"
MOCK_KEYGEN
    chmod +x "$tmp/bin/ssh-keygen"
    PATH="$tmp/bin:$PATH"
    TMP_DIR="$tmp/work"
    mkdir -p "$TMP_DIR"
    generate_ed25519_key_pair
    if grep -q '^ssh-ed25519 ' "$GENERATED_PUBLIC_KEY_FILE"; then
        pass "gen mode mock generates ed25519"
    else
        fail "gen mode mock generates ed25519"
    fi
    PATH=$old_path
    rm -rf "$tmp"
}

test_cli_parsing() {
    if parse_cli_args github ike-sh &&
        [ "$CLI_MODE" = "github" ] &&
        [ "$CLI_GITHUB_USER" = "ike-sh" ] &&
        parse_cli_args gen &&
        [ "$CLI_MODE" = "gen" ]; then
        pass "CLI argument parsing"
    else
        fail "CLI argument parsing"
    fi
}

test_menu_output() {
    tmp=$(make_test_dir)
    show_menu > "$tmp/menu"
    if grep -q "SSH 密钥登录配置" "$tmp/menu" &&
        grep -q "请选择 \[1-3\]" "$tmp/menu"; then
        pass "no-arg menu function"
    else
        fail "no-arg menu function"
    fi
    rm -rf "$tmp"
}

test_color_output() {
    tmp=$(make_test_dir)
    info "hello" > "$tmp/out"
    if grep -q "\[信息\]" "$tmp/out"; then
        pass "color output function"
    else
        fail "color output function"
    fi
    rm -rf "$tmp"
}

test_no_forbidden_features() {
    if grep -E "curl \\| sh|--docker|--warp|--dd|--site|--ssl|install docker|bbr" "$ROOT_DIR/init.sh" >/dev/null 2>&1; then
        fail "no forbidden feature implementation"
    else
        pass "no forbidden feature implementation"
    fi
}

test_github_username_validation
test_public_key_validation
test_github_keys_filtering
test_authorized_keys_append_dedup_and_permissions
test_symlink_ssh_rejected
test_symlink_authorized_keys_rejected
test_sshd_config_settings
test_sshd_t_failure_restores_backup
test_restart_failure_restores_backup
test_gen_without_ssh_keygen_fails
test_gen_mock_ed25519
test_cli_parsing
test_menu_output
test_color_output
test_no_forbidden_features

if [ "$FAIL_COUNT" -gt 0 ]; then
    printf '%s\n' "$FAIL_COUNT test(s) failed" >&2
    exit 1
fi

printf '%s\n' "$PASS_COUNT test(s) passed"
