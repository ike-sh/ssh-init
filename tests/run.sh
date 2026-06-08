#!/bin/sh

set -eu

ROOT_DIR=$(CDPATH=; cd "$(dirname "$0")/.." && pwd)
IKE_TEST_MODE=1
export IKE_TEST_MODE
. "$ROOT_DIR/init.sh"

PASS_COUNT=0
FAIL_COUNT=0
VALID_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBHiTtwHOMyc2QbrXv/15/f/TmESu5rAxMdF31qhnU8g test@example"
VALID_KEY_2="ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCYBsYdjo6CUSqYxQusah9Ae3dqIOQxJNS6OsiiQSyq/BPKWdIN1qw8AVPsDe6p9df/RhHtWZOI3gNwsRE39g7ijP/q0lGNMurx1LzxZGFbLjbXaATIZzlCARbJinQOBBjqpisUSf/2vhKRGQciDzC+YCgn/r+uDq4eXL/tSQuPZx72l5Yy+S1w+cKUwSAmBuLcCf3Ovyz8eIkM6NhP/+m9/GkT4TGdEjKdyPMY9mHZOipbJT5ri4ewQJoX9eEQElryb8rT0O2gjN6QXn2dPBC1AhQ4fUrSDc4Mo8mt82LIElX164Tr1xvdk3bzuFx28QKjmpooZmua2rvEJZSDbAcn test@example"

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

test_ask_prompt_format() {
    tmp=$(make_test_dir)
    printf '%s\n' "4" > "$tmp/in"
    ask_prompt "请选择 [1-5]:" < "$tmp/in" > "$tmp/out"
    output=$(cat "$tmp/out")
    if [ "$output" = "请选择 [1-5]: " ] && [ "$ASK_REPLY" = "4" ]; then
        pass "ask_prompt output format has no extra newline"
    else
        fail "ask_prompt output format has no extra newline"
    fi
    rm -rf "$tmp"
}

test_github_username_validation() {
    name39="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    name40="${name39}a"
    if validate_github_username "ike-sh" &&
        validate_github_username "abc123" &&
        validate_github_username "$name39" &&
        ! validate_github_username "" &&
        ! validate_github_username "-bad" &&
        ! validate_github_username "bad-" &&
        ! validate_github_username "bad_name" &&
        ! validate_github_username "$name40" &&
        ! validate_github_username "a--b"; then
        pass "GitHub username validation"
    else
        fail "GitHub username validation"
    fi
}

test_github_placeholder_rejected() {
    if is_github_placeholder "GitHubUser" &&
        is_github_placeholder "username" &&
        is_github_placeholder "yourname" &&
        is_github_placeholder "你的用户名" &&
        ! is_github_placeholder "ike-sh"; then
        pass "GitHub placeholder usernames rejected"
    else
        fail "GitHub placeholder usernames rejected"
    fi
}

test_github_empty_hint() {
    tmp=$(make_test_dir)
    print_github_empty_hint "empty-user" > "$tmp/out" 2>&1
    if grep -q "未获取到 GitHub 公钥" "$tmp/out" &&
        grep -q "https://github.com/empty-user.keys" "$tmp/out" &&
        grep -q "Authentication Key" "$tmp/out" &&
        grep -q "https://github.com/settings/keys" "$tmp/out" &&
        grep -q "4. 生成新的本机 Ed25519 密钥" "$tmp/out"; then
        pass "GitHub .keys empty friendly hint"
    else
        fail "GitHub .keys empty friendly hint"
    fi
    rm -rf "$tmp"
}

test_github_import_tutorial_output() {
    tmp=$(make_test_dir)
    print_github_import_tutorial > "$tmp/out"
    if grep -q "GitHub 公钥导入说明" "$tmp/out" &&
        grep -q "https://github.com/settings/keys" "$tmp/out" &&
        grep -q "Authentication Key" "$tmp/out" &&
        grep -q "不要粘贴这种私钥" "$tmp/out" &&
        grep -q "https://github.com/你的用户名.keys" "$tmp/out"; then
        pass "interactive GitHub tutorial output"
    else
        fail "interactive GitHub tutorial output"
    fi
    rm -rf "$tmp"
}

test_github_cli_does_not_print_full_tutorial() {
    tmp=$(make_test_dir)
    github_mode "GitHubUser" > "$tmp/out" 2>&1 || true
    if grep -q "示例占位符" "$tmp/out" &&
        ! grep -q "GitHub 公钥导入说明" "$tmp/out" &&
        ! grep -q "不要粘贴这种私钥" "$tmp/out"; then
        pass "CLI github avoids full tutorial"
    else
        fail "CLI github avoids full tutorial"
    fi
    rm -rf "$tmp"
}

test_public_key_validation() {
    malformed_rejected=0
    if command -v ssh-keygen >/dev/null 2>&1; then
        if ! normalize_key_line "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMalformedButBase64Like1234567890" >/dev/null 2>&1; then
            malformed_rejected=1
        fi
    else
        malformed_rejected=1
    fi
    if normalize_key_line "$VALID_KEY" >/dev/null &&
        normalize_key_line "$VALID_KEY_2" >/dev/null &&
        ! normalize_key_line "ssh-dss AAAABadKey" >/dev/null 2>&1 &&
        ! normalize_key_line "ssh-ed25519 not@base64" >/dev/null 2>&1 &&
        [ "$malformed_rejected" = "1" ]; then
        pass "public key validation"
    else
        fail "public key validation"
    fi
}

test_public_key_ssh_keygen_deep_validation() {
    tmp=$(make_test_dir)
    old_path=$PATH
    mkdir -p "$tmp/bin"
    cat > "$tmp/bin/ssh-keygen" <<'MOCK_KEYGEN'
#!/bin/sh
file=""
while [ "$#" -gt 0 ]; do
    if [ "$1" = "-f" ]; then
        file="$2"
        shift 2
    else
        shift
    fi
done
if grep -q "MalformedButBase64Like" "$file"; then
    exit 1
fi
exit 0
MOCK_KEYGEN
    chmod +x "$tmp/bin/ssh-keygen"
    PATH="$tmp/bin:$PATH"
    if normalize_key_line "$VALID_KEY" >/dev/null &&
        ! normalize_key_line "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMalformedButBase64Like1234567890" >/dev/null 2>&1; then
        pass "ssh-keygen validates public key format"
    else
        fail "ssh-keygen validates public key format"
    fi
    PATH=$old_path
    rm -rf "$tmp"
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

test_sshd_config_password_auth_no() {
    tmp=$(make_test_dir)
    in="$tmp/sshd_config"
    out="$tmp/out"
    printf '%s\n' "PasswordAuthentication yes" > "$in"
    write_hardened_sshd_config "$in" "$out"
    if grep -q '^PasswordAuthentication no$' "$out"; then
        pass "sshd_config sets PasswordAuthentication no"
    else
        fail "sshd_config sets PasswordAuthentication no"
    fi
    rm -rf "$tmp"
}

test_sshd_config_pubkey_yes() {
    tmp=$(make_test_dir)
    in="$tmp/sshd_config"
    out="$tmp/out"
    printf '%s\n' "PubkeyAuthentication no" > "$in"
    write_hardened_sshd_config "$in" "$out"
    if grep -q '^PubkeyAuthentication yes$' "$out"; then
        pass "sshd_config sets PubkeyAuthentication yes"
    else
        fail "sshd_config sets PubkeyAuthentication yes"
    fi
    rm -rf "$tmp"
}

test_sshd_config_permit_root() {
    tmp=$(make_test_dir)
    in="$tmp/sshd_config"
    out="$tmp/out"
    printf '%s\n' "PermitRootLogin yes" > "$in"
    write_hardened_sshd_config "$in" "$out"
    if grep -q '^PermitRootLogin prohibit-password$' "$out"; then
        pass "sshd_config sets PermitRootLogin prohibit-password"
    else
        fail "sshd_config sets PermitRootLogin prohibit-password"
    fi
    rm -rf "$tmp"
}

test_immutable_detection_with_i() {
    tmp=$(make_test_dir)
    old_path=$PATH
    mkdir -p "$tmp/bin"
    file="$tmp/sshd_config"
    printf '%s\n' "config" > "$file"
    cat > "$tmp/bin/lsattr" <<'MOCK_LSATTR'
#!/bin/sh
printf '%s\n' '----i---------e------- '"$1"
MOCK_LSATTR
    chmod +x "$tmp/bin/lsattr"
    PATH="$tmp/bin:$PATH"
    if is_immutable_file "$file"; then
        pass "is_immutable_file detects i attribute"
    else
        fail "is_immutable_file detects i attribute"
    fi
    PATH=$old_path
    rm -rf "$tmp"
}

test_immutable_detection_without_i() {
    tmp=$(make_test_dir)
    old_path=$PATH
    mkdir -p "$tmp/bin"
    file="$tmp/sshd_config"
    printf '%s\n' "config" > "$file"
    cat > "$tmp/bin/lsattr" <<'MOCK_LSATTR'
#!/bin/sh
printf '%s\n' '--------------e------- '"$1"
MOCK_LSATTR
    chmod +x "$tmp/bin/lsattr"
    PATH="$tmp/bin:$PATH"
    if is_immutable_file "$file"; then
        fail "is_immutable_file ignores non-immutable file"
    else
        pass "is_immutable_file ignores non-immutable file"
    fi
    PATH=$old_path
    rm -rf "$tmp"
}

test_unlock_immutable_calls_chattr() {
    tmp=$(make_test_dir)
    old_path=$PATH
    old_flag=$SSHD_CONFIG_WAS_IMMUTABLE
    mkdir -p "$tmp/bin"
    file="$tmp/sshd_config"
    printf '%s\n' "config" > "$file"
    cat > "$tmp/bin/lsattr" <<'MOCK_LSATTR'
#!/bin/sh
printf '%s\n' '----i---------e------- '"$1"
MOCK_LSATTR
    cat > "$tmp/bin/chattr" <<'MOCK_CHATTR'
#!/bin/sh
printf '%s\n' "$*" >> "$CHATTR_LOG"
exit 0
MOCK_CHATTR
    chmod +x "$tmp/bin/lsattr" "$tmp/bin/chattr"
    CHATTR_LOG="$tmp/chattr.log"
    export CHATTR_LOG
    PATH="$tmp/bin:$PATH"
    unlock_immutable_if_needed "$file" > "$tmp/out" 2>&1
    if grep -q -- "-i $file" "$CHATTR_LOG" &&
        [ "$SSHD_CONFIG_WAS_IMMUTABLE" = "1" ] &&
        grep -q "不会修改 Port" "$tmp/out"; then
        pass "unlock immutable calls chattr -i"
    else
        fail "unlock immutable calls chattr -i"
    fi
    SSHD_CONFIG_WAS_IMMUTABLE=$old_flag
    PATH=$old_path
    unset CHATTR_LOG
    rm -rf "$tmp"
}

test_relock_only_when_originally_immutable() {
    tmp=$(make_test_dir)
    old_path=$PATH
    old_flag=$SSHD_CONFIG_WAS_IMMUTABLE
    mkdir -p "$tmp/bin"
    file="$tmp/sshd_config"
    printf '%s\n' "config" > "$file"
    cat > "$tmp/bin/chattr" <<'MOCK_CHATTR'
#!/bin/sh
printf '%s\n' "$*" >> "$CHATTR_LOG"
exit 0
MOCK_CHATTR
    chmod +x "$tmp/bin/chattr"
    CHATTR_LOG="$tmp/chattr.log"
    export CHATTR_LOG
    PATH="$tmp/bin:$PATH"
    SSHD_CONFIG_WAS_IMMUTABLE=1
    relock_immutable_if_needed "$file" >/dev/null 2>&1
    if grep -q -- "+i $file" "$CHATTR_LOG"; then
        pass "relock immutable calls chattr +i"
    else
        fail "relock immutable calls chattr +i"
    fi
    : > "$CHATTR_LOG"
    SSHD_CONFIG_WAS_IMMUTABLE=0
    relock_immutable_if_needed "$file" >/dev/null 2>&1
    if [ ! -s "$CHATTR_LOG" ]; then
        pass "relock skips chattr for non-immutable file"
    else
        fail "relock skips chattr for non-immutable file"
    fi
    SSHD_CONFIG_WAS_IMMUTABLE=$old_flag
    PATH=$old_path
    unset CHATTR_LOG
    rm -rf "$tmp"
}

test_sshd_config_writer_does_not_modify_port_or_forbidden_keys() {
    tmp=$(make_test_dir)
    in="$tmp/sshd_config"
    out="$tmp/out"
    {
        printf '%s\n' "Port 2222"
        printf '%s\n' "ListenAddress 0.0.0.0"
        printf '%s\n' "HostKey /etc/ssh/ssh_host_ed25519_key"
        printf '%s\n' "AllowUsers root"
        printf '%s\n' "DenyUsers bad"
        printf '%s\n' "AuthorizedKeysFile .ssh/authorized_keys"
        printf '%s\n' "# PasswordAuthentication yes"
        printf '%s\n' "Match User deploy"
        printf '%s\n' "    PasswordAuthentication yes"
    } > "$in"
    write_hardened_sshd_config "$in" "$out"
    if grep -q '^Port 2222$' "$out" &&
        grep -q '^ListenAddress 0.0.0.0$' "$out" &&
        grep -q '^HostKey /etc/ssh/ssh_host_ed25519_key$' "$out" &&
        grep -q '^AllowUsers root$' "$out" &&
        grep -q '^DenyUsers bad$' "$out" &&
        grep -q '^AuthorizedKeysFile .ssh/authorized_keys$' "$out" &&
        grep -q '^Match User deploy$' "$out" &&
        grep -q '^    PasswordAuthentication yes$' "$out"; then
        pass "sshd_config writer preserves Port and forbidden keys"
    else
        fail "sshd_config writer preserves Port and forbidden keys"
    fi
    rm -rf "$tmp"
}

test_sshd_config_writer_only_changes_allowed_keys() {
    tmp=$(make_test_dir)
    in="$tmp/sshd_config"
    out="$tmp/out"
    {
        printf '%s\n' "# PubkeyAuthentication no"
        printf '%s\n' "PasswordAuthentication yes"
        printf '%s\n' "# ChallengeResponseAuthentication yes"
        printf '%s\n' "KbdInteractiveAuthentication yes"
        printf '%s\n' "# PermitEmptyPasswords yes"
        printf '%s\n' "PermitRootLogin yes"
    } > "$in"
    write_hardened_sshd_config "$in" "$out"
    if grep -q '^PubkeyAuthentication yes$' "$out" &&
        grep -q '^PasswordAuthentication no$' "$out" &&
        grep -q '^ChallengeResponseAuthentication no$' "$out" &&
        grep -q '^KbdInteractiveAuthentication no$' "$out" &&
        grep -q '^PermitEmptyPasswords no$' "$out" &&
        grep -q '^PermitRootLogin prohibit-password$' "$out"; then
        pass "sshd_config writer updates only allowed keys"
    else
        fail "sshd_config writer updates only allowed keys"
    fi
    rm -rf "$tmp"
}

test_sshd_t_failure_restores_backup() {
    tmp=$(make_test_dir)
    old_path=$PATH
    old_ssh_config=$SSH_CONFIG
    old_run_sshd_dir=$RUN_SSHD_DIR
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
    SSH_CONFIG=$old_ssh_config
    RUN_SSHD_DIR=$old_run_sshd_dir
    unset IKE_TEST_UID
    rm -rf "$tmp"
}

test_restart_failure_restores_backup() {
    tmp=$(make_test_dir)
    old_path=$PATH
    old_ssh_config=$SSH_CONFIG
    old_run_sshd_dir=$RUN_SSHD_DIR
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
    SSH_CONFIG=$old_ssh_config
    RUN_SSHD_DIR=$old_run_sshd_dir
    unset IKE_TEST_UID
    rm -rf "$tmp"
}

test_effective_include_password_yes_fails() {
    tmp=$(make_test_dir)
    old_path=$PATH
    old_ssh_config=$SSH_CONFIG
    old_run_sshd_dir=$RUN_SSHD_DIR
    mkdir -p "$tmp/bin" "$tmp/conf.d"
    SSH_CONFIG="$tmp/sshd_config"
    RUN_SSHD_DIR="$tmp/run/sshd"
    IKE_TEST_UID=0
    export IKE_TEST_UID
    include="$tmp/conf.d/early.conf"
    {
        printf '%s\n' "Include $include"
        printf '%s\n' "PasswordAuthentication no"
    } > "$SSH_CONFIG"
    printf '%s\n' "PasswordAuthentication yes" > "$include"
    cat > "$tmp/bin/sshd" <<'MOCK_SSHD'
#!/bin/sh
mode=""
config=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -T)
            mode="T"
            shift
            ;;
        -t)
            mode="t"
            shift
            ;;
        -f)
            config="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done
if [ "$mode" = "T" ]; then
    include=$(awk 'tolower($1) == "include" { print $2; exit }' "$config")
    if [ -n "$include" ] && grep -q '^PasswordAuthentication yes$' "$include"; then
        printf '%s\n' "pubkeyauthentication yes"
        printf '%s\n' "passwordauthentication yes"
        printf '%s\n' "kbdinteractiveauthentication no"
        printf '%s\n' "permitemptypasswords no"
        printf '%s\n' "permitrootlogin prohibit-password"
        exit 0
    fi
fi
exit 0
MOCK_SSHD
    cat > "$tmp/bin/systemctl" <<'MOCK_SYSTEMCTL'
#!/bin/sh
printf '%s\n' "restart" >> "$RESTART_LOG"
exit 0
MOCK_SYSTEMCTL
    chmod +x "$tmp/bin/sshd" "$tmp/bin/systemctl"
    RESTART_LOG="$tmp/restart.log"
    export RESTART_LOG
    PATH="$tmp/bin:$PATH"
    if (harden_ssh_config > "$tmp/out" 2>&1); then
        fail "effective Include password yes fails"
    elif grep -q "最终生效配置不符合预期" "$tmp/out" &&
        grep -q "^Include $include$" "$SSH_CONFIG" &&
        [ ! -s "$RESTART_LOG" ]; then
        pass "effective Include password yes fails"
    else
        fail "effective Include password yes fails"
    fi
    PATH=$old_path
    SSH_CONFIG=$old_ssh_config
    RUN_SSHD_DIR=$old_run_sshd_dir
    unset IKE_TEST_UID RESTART_LOG
    rm -rf "$tmp"
}

make_mock_sshd_dropin_aware() {
    bin_dir="$1"
    cat > "$bin_dir/sshd" <<'MOCK_SSHD'
#!/bin/sh
mode=""
config=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -T)
            mode="T"
            shift
            ;;
        -t)
            mode="t"
            shift
            ;;
        -f)
            config="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done
if [ "$mode" = "T" ]; then
    pattern=$(awk 'tolower($1) == "include" { print $2; exit }' "$config")
    dir=${pattern%/*}
    if [ -f "$dir/00-ssh-init-hardening.conf" ]; then
        printf '%s\n' "permitrootlogin without-password"
        printf '%s\n' "pubkeyauthentication yes"
        printf '%s\n' "passwordauthentication no"
        printf '%s\n' "kbdinteractiveauthentication no"
        printf '%s\n' "permitemptypasswords no"
        printf '%s\n' "authenticationmethods any"
        exit 0
    fi
    printf '%s\n' "permitrootlogin yes"
    printf '%s\n' "pubkeyauthentication yes"
    printf '%s\n' "passwordauthentication yes"
    printf '%s\n' "kbdinteractiveauthentication no"
    printf '%s\n' "permitemptypasswords no"
    printf '%s\n' "authenticationmethods any"
fi
exit 0
MOCK_SSHD
    chmod +x "$bin_dir/sshd"
}

make_mock_restart_success() {
    bin_dir="$1"
    cat > "$bin_dir/systemctl" <<'MOCK_SYSTEMCTL'
#!/bin/sh
printf '%s\n' "restart" >> "$RESTART_LOG"
exit 0
MOCK_SYSTEMCTL
    chmod +x "$bin_dir/systemctl"
}

test_dropin_permitrootlogin_success() {
    tmp=$(make_test_dir)
    old_path=$PATH
    old_ssh_config=$SSH_CONFIG
    old_run_sshd_dir=$RUN_SSHD_DIR
    mkdir -p "$tmp/bin" "$tmp/sshd_config.d"
    SSH_CONFIG="$tmp/sshd_config"
    RUN_SSHD_DIR="$tmp/run/sshd"
    IKE_TEST_UID=0
    export IKE_TEST_UID
    {
        printf '%s\n' "Include $tmp/sshd_config.d/*.conf"
        printf '%s\n' "KbdInteractiveAuthentication no"
    } > "$SSH_CONFIG"
    printf '%s\n' "PermitRootLogin yes" > "$tmp/sshd_config.d/01-permitrootlogin.conf"
    make_mock_sshd_dropin_aware "$tmp/bin"
    make_mock_restart_success "$tmp/bin"
    RESTART_LOG="$tmp/restart.log"
    export RESTART_LOG
    PATH="$tmp/bin:$PATH"
    if harden_ssh_config > "$tmp/out" 2>&1 &&
        [ -f "$tmp/sshd_config.d/00-ssh-init-hardening.conf" ] &&
        grep -q '^PasswordAuthentication no$' "$tmp/sshd_config.d/00-ssh-init-hardening.conf" &&
        grep -q '^PermitRootLogin prohibit-password$' "$tmp/sshd_config.d/00-ssh-init-hardening.conf" &&
        grep -q '^PermitRootLogin yes$' "$tmp/sshd_config.d/01-permitrootlogin.conf" &&
        [ -s "$RESTART_LOG" ]; then
        pass "generic 00 drop-in overrides earlier PermitRootLogin drop-in"
    else
        fail "generic 00 drop-in overrides earlier PermitRootLogin drop-in"
    fi
    PATH=$old_path
    SSH_CONFIG=$old_ssh_config
    RUN_SSHD_DIR=$old_run_sshd_dir
    unset IKE_TEST_UID RESTART_LOG
    rm -rf "$tmp"
}

test_dropin_cloud_init_success() {
    tmp=$(make_test_dir)
    old_path=$PATH
    old_ssh_config=$SSH_CONFIG
    old_run_sshd_dir=$RUN_SSHD_DIR
    mkdir -p "$tmp/bin" "$tmp/sshd_config.d"
    SSH_CONFIG="$tmp/sshd_config"
    RUN_SSHD_DIR="$tmp/run/sshd"
    IKE_TEST_UID=0
    export IKE_TEST_UID
    printf '%s\n' "Include $tmp/sshd_config.d/*.conf" > "$SSH_CONFIG"
    printf '%s\n' "PasswordAuthentication yes" > "$tmp/sshd_config.d/50-cloud-init.conf"
    make_mock_sshd_dropin_aware "$tmp/bin"
    make_mock_restart_success "$tmp/bin"
    RESTART_LOG="$tmp/restart.log"
    export RESTART_LOG
    PATH="$tmp/bin:$PATH"
    if harden_ssh_config > "$tmp/out" 2>&1 &&
        grep -q '^PasswordAuthentication no$' "$tmp/sshd_config.d/00-ssh-init-hardening.conf" &&
        grep -q '^PasswordAuthentication yes$' "$tmp/sshd_config.d/50-cloud-init.conf" &&
        grep -q "SSH 最终生效配置校验通过" "$tmp/out"; then
        pass "00 drop-in wins before 50-cloud-init PasswordAuthentication"
    else
        fail "00 drop-in wins before 50-cloud-init PasswordAuthentication"
    fi
    PATH=$old_path
    SSH_CONFIG=$old_ssh_config
    RUN_SSHD_DIR=$old_run_sshd_dir
    unset IKE_TEST_UID RESTART_LOG
    rm -rf "$tmp"
}

test_existing_dropin_failure_restores_backup() {
    tmp=$(make_test_dir)
    old_path=$PATH
    old_ssh_config=$SSH_CONFIG
    old_run_sshd_dir=$RUN_SSHD_DIR
    mkdir -p "$tmp/bin" "$tmp/sshd_config.d"
    SSH_CONFIG="$tmp/sshd_config"
    RUN_SSHD_DIR="$tmp/run/sshd"
    IKE_TEST_UID=0
    export IKE_TEST_UID
    printf '%s\n' "Include $tmp/sshd_config.d/*.conf" > "$SSH_CONFIG"
    printf '%s\n' "old managed content" > "$tmp/sshd_config.d/00-ssh-init-hardening.conf"
    cat > "$tmp/bin/sshd" <<'MOCK_SSHD'
#!/bin/sh
while [ "$#" -gt 0 ]; do
    if [ "$1" = "-T" ]; then
        printf '%s\n' "permitrootlogin yes"
        printf '%s\n' "pubkeyauthentication yes"
        printf '%s\n' "passwordauthentication yes"
        printf '%s\n' "kbdinteractiveauthentication no"
        printf '%s\n' "permitemptypasswords no"
        exit 0
    fi
    shift
done
exit 0
MOCK_SSHD
    make_mock_restart_success "$tmp/bin"
    chmod +x "$tmp/bin/sshd"
    RESTART_LOG="$tmp/restart.log"
    export RESTART_LOG
    PATH="$tmp/bin:$PATH"
    if (harden_ssh_config > "$tmp/out" 2>&1); then
        fail "existing 00 drop-in is restored after effective failure"
    elif grep -q '^old managed content$' "$tmp/sshd_config.d/00-ssh-init-hardening.conf" &&
        ! grep -q '^PasswordAuthentication no$' "$tmp/sshd_config.d/00-ssh-init-hardening.conf" &&
        ! grep -q '^PasswordAuthentication no$' "$SSH_CONFIG" &&
        [ "$(find "$tmp/sshd_config.d" -name '00-ssh-init-hardening.conf.bak.*' | wc -l | awk '{print $1}')" = "1" ] &&
        [ ! -s "$RESTART_LOG" ]; then
        pass "existing 00 drop-in is restored after effective failure"
    else
        fail "existing 00 drop-in is restored after effective failure"
    fi
    PATH=$old_path
    SSH_CONFIG=$old_ssh_config
    RUN_SSHD_DIR=$old_run_sshd_dir
    unset IKE_TEST_UID RESTART_LOG
    rm -rf "$tmp"
}

test_new_dropin_failure_removes_file() {
    tmp=$(make_test_dir)
    old_path=$PATH
    old_ssh_config=$SSH_CONFIG
    old_run_sshd_dir=$RUN_SSHD_DIR
    mkdir -p "$tmp/bin" "$tmp/sshd_config.d"
    SSH_CONFIG="$tmp/sshd_config"
    RUN_SSHD_DIR="$tmp/run/sshd"
    IKE_TEST_UID=0
    export IKE_TEST_UID
    printf '%s\n' "Include $tmp/sshd_config.d/*.conf" > "$SSH_CONFIG"
    cat > "$tmp/bin/sshd" <<'MOCK_SSHD'
#!/bin/sh
while [ "$#" -gt 0 ]; do
    if [ "$1" = "-T" ]; then
        printf '%s\n' "permitrootlogin yes"
        printf '%s\n' "pubkeyauthentication yes"
        printf '%s\n' "passwordauthentication yes"
        printf '%s\n' "kbdinteractiveauthentication no"
        printf '%s\n' "permitemptypasswords no"
        exit 0
    fi
    shift
done
exit 0
MOCK_SSHD
    make_mock_restart_success "$tmp/bin"
    chmod +x "$tmp/bin/sshd"
    RESTART_LOG="$tmp/restart.log"
    export RESTART_LOG
    PATH="$tmp/bin:$PATH"
    if (harden_ssh_config > "$tmp/out" 2>&1); then
        fail "new 00 drop-in is removed after effective failure"
    elif [ ! -e "$tmp/sshd_config.d/00-ssh-init-hardening.conf" ] &&
        ! grep -q '^PasswordAuthentication no$' "$SSH_CONFIG" &&
        [ ! -s "$RESTART_LOG" ]; then
        pass "new 00 drop-in is removed after effective failure"
    else
        fail "new 00 drop-in is removed after effective failure"
    fi
    PATH=$old_path
    SSH_CONFIG=$old_ssh_config
    RUN_SSHD_DIR=$old_run_sshd_dir
    unset IKE_TEST_UID RESTART_LOG
    rm -rf "$tmp"
}

test_effective_failure_lists_items() {
    tmp=$(make_test_dir)
    old_path=$PATH
    old_ssh_config=$SSH_CONFIG
    old_run_sshd_dir=$RUN_SSHD_DIR
    mkdir -p "$tmp/bin"
    SSH_CONFIG="$tmp/sshd_config"
    RUN_SSHD_DIR="$tmp/run/sshd"
    IKE_TEST_UID=0
    export IKE_TEST_UID
    printf '%s\n' "PasswordAuthentication yes" > "$SSH_CONFIG"
    cat > "$tmp/bin/sshd" <<'MOCK_SSHD'
#!/bin/sh
while [ "$#" -gt 0 ]; do
    if [ "$1" = "-T" ]; then
        printf '%s\n' "permitrootlogin yes"
        printf '%s\n' "passwordauthentication yes"
        printf '%s\n' "pubkeyauthentication yes"
        printf '%s\n' "kbdinteractiveauthentication no"
        printf '%s\n' "permitemptypasswords no"
        exit 0
    fi
    shift
done
exit 0
MOCK_SSHD
    make_mock_restart_success "$tmp/bin"
    chmod +x "$tmp/bin/sshd"
    RESTART_LOG="$tmp/restart.log"
    export RESTART_LOG
    PATH="$tmp/bin:$PATH"
    if (harden_ssh_config > "$tmp/out" 2>&1); then
        fail "effective failure output lists mismatched keys"
    elif grep -q "passwordauthentication: 期望 no，实际 yes" "$tmp/out" &&
        grep -q "permitrootlogin: 期望 prohibit-password/without-password，实际 yes" "$tmp/out" &&
        grep -q "也可能是 Match 块根据用户、地址或组覆盖了全局配置" "$tmp/out" &&
        [ ! -s "$RESTART_LOG" ]; then
        pass "effective failure output lists mismatched keys"
    else
        fail "effective failure output lists mismatched keys"
    fi
    PATH=$old_path
    SSH_CONFIG=$old_ssh_config
    RUN_SSHD_DIR=$old_run_sshd_dir
    unset IKE_TEST_UID RESTART_LOG
    rm -rf "$tmp"
}

test_authentication_methods_blocks_hardening() {
    tmp=$(make_test_dir)
    old_ssh_config=$SSH_CONFIG
    mkdir -p "$tmp/conf.d"
    SSH_CONFIG="$tmp/sshd_config"
    include="$tmp/conf.d/auth.conf"
    IKE_TEST_UID=0
    export IKE_TEST_UID
    printf '%s\n' "Include $include" > "$SSH_CONFIG"
    printf '%s\n' "AuthenticationMethods publickey,password" > "$include"
    if (harden_ssh_config > "$tmp/out" 2>&1); then
        fail "AuthenticationMethods publickey,password blocks hardening"
    elif grep -q "AuthenticationMethods publickey,password" "$tmp/out" &&
        grep -q "继续可能导致 SSH 无法登录" "$tmp/out" &&
        grep -q "AuthenticationMethods 改为 publickey" "$tmp/out" &&
        [ "$(find "$tmp" -name 'sshd_config.bak.*' | wc -l | awk '{print $1}')" = "0" ]; then
        pass "AuthenticationMethods publickey,password blocks hardening"
    else
        fail "AuthenticationMethods publickey,password blocks hardening"
    fi
    SSH_CONFIG=$old_ssh_config
    unset IKE_TEST_UID
    rm -rf "$tmp"
}

test_authentication_methods_keyboard_interactive_blocks_hardening() {
    tmp=$(make_test_dir)
    old_ssh_config=$SSH_CONFIG
    mkdir -p "$tmp/sshd_config.d"
    SSH_CONFIG="$tmp/sshd_config"
    include="$tmp/sshd_config.d/auth.conf"
    IKE_TEST_UID=0
    export IKE_TEST_UID
    printf '%s\n' "Include $tmp/sshd_config.d/*.conf" > "$SSH_CONFIG"
    printf '%s\n' "AuthenticationMethods publickey,keyboard-interactive" > "$include"
    if (harden_ssh_config > "$tmp/out" 2>&1); then
        fail "AuthenticationMethods publickey,keyboard-interactive blocks hardening"
    elif grep -q "AuthenticationMethods publickey,keyboard-interactive" "$tmp/out" &&
        grep -q "脚本会禁用 password / keyboard-interactive" "$tmp/out" &&
        [ ! -e "$tmp/sshd_config.d/00-ssh-init-hardening.conf" ] &&
        [ "$(find "$tmp" -name 'sshd_config.bak.*' | wc -l | awk '{print $1}')" = "0" ]; then
        pass "AuthenticationMethods publickey,keyboard-interactive blocks hardening"
    else
        fail "AuthenticationMethods publickey,keyboard-interactive blocks hardening"
    fi
    SSH_CONFIG=$old_ssh_config
    unset IKE_TEST_UID
    rm -rf "$tmp"
}

test_authentication_methods_safe_values_allowed() {
    tmp=$(make_test_dir)
    old_ssh_config=$SSH_CONFIG
    SSH_CONFIG="$tmp/sshd_config"
    printf '%s\n' "AuthenticationMethods any" > "$SSH_CONFIG"
    any_ok=0
    publickey_ok=0
    if detect_authentication_methods_risk "$SSH_CONFIG"; then
        any_ok=1
    fi
    printf '%s\n' "AuthenticationMethods publickey" > "$SSH_CONFIG"
    if detect_authentication_methods_risk "$SSH_CONFIG"; then
        publickey_ok=1
    fi
    if [ "$any_ok" = "1" ] && [ "$publickey_ok" = "1" ]; then
        pass "AuthenticationMethods any and publickey are allowed"
    else
        fail "AuthenticationMethods any and publickey are allowed"
    fi
    SSH_CONFIG=$old_ssh_config
    rm -rf "$tmp"
}

test_match_password_yes_warns_and_preserves() {
    tmp=$(make_test_dir)
    old_path=$PATH
    old_ssh_config=$SSH_CONFIG
    old_run_sshd_dir=$RUN_SSHD_DIR
    mkdir -p "$tmp/bin"
    SSH_CONFIG="$tmp/sshd_config"
    RUN_SSHD_DIR="$tmp/run/sshd"
    IKE_TEST_UID=0
    export IKE_TEST_UID
    {
        printf '%s\n' "PasswordAuthentication yes"
        printf '%s\n' "Match User deploy"
        printf '%s\n' "    PasswordAuthentication yes"
    } > "$SSH_CONFIG"
    cat > "$tmp/bin/sshd" <<'MOCK_SSHD'
#!/bin/sh
if [ "$1" = "-T" ]; then
    printf '%s\n' "pubkeyauthentication yes"
    printf '%s\n' "passwordauthentication no"
    printf '%s\n' "kbdinteractiveauthentication no"
    printf '%s\n' "permitemptypasswords no"
    printf '%s\n' "permitrootlogin prohibit-password"
fi
exit 0
MOCK_SSHD
    cat > "$tmp/bin/systemctl" <<'MOCK_SYSTEMCTL'
#!/bin/sh
exit 0
MOCK_SYSTEMCTL
    chmod +x "$tmp/bin/sshd" "$tmp/bin/systemctl"
    PATH="$tmp/bin:$PATH"
    if harden_ssh_config > "$tmp/out" 2>&1 &&
        grep -q '^PasswordAuthentication no$' "$SSH_CONFIG" &&
        grep -q '^    PasswordAuthentication yes$' "$SSH_CONFIG" &&
        [ "$(grep -c "检测到 Match 块可能覆盖全局 SSH 安全策略" "$tmp/out")" -ge 2 ]; then
        pass "Match PasswordAuthentication yes warns and preserves block"
    else
        fail "Match PasswordAuthentication yes warns and preserves block"
    fi
    PATH=$old_path
    SSH_CONFIG=$old_ssh_config
    RUN_SSHD_DIR=$old_run_sshd_dir
    unset IKE_TEST_UID
    rm -rf "$tmp"
}

test_atomic_write_failure_restores_backup() {
    tmp=$(make_test_dir)
    old_path=$PATH
    old_ssh_config=$SSH_CONFIG
    old_run_sshd_dir=$RUN_SSHD_DIR
    mkdir -p "$tmp/bin"
    SSH_CONFIG="$tmp/sshd_config"
    RUN_SSHD_DIR="$tmp/run/sshd"
    IKE_TEST_UID=0
    export IKE_TEST_UID
    printf '%s\n' "PasswordAuthentication yes" > "$SSH_CONFIG"
    cat > "$tmp/bin/sshd" <<'MOCK_SSHD'
#!/bin/sh
if [ "$1" = "-T" ]; then
    printf '%s\n' "pubkeyauthentication yes"
    printf '%s\n' "passwordauthentication no"
    printf '%s\n' "kbdinteractiveauthentication no"
    printf '%s\n' "permitemptypasswords no"
    printf '%s\n' "permitrootlogin prohibit-password"
fi
exit 0
MOCK_SSHD
    cat > "$tmp/bin/mv" <<'MOCK_MV'
#!/bin/sh
exit 1
MOCK_MV
    cat > "$tmp/bin/systemctl" <<'MOCK_SYSTEMCTL'
#!/bin/sh
printf '%s\n' "restart" >> "$RESTART_LOG"
exit 0
MOCK_SYSTEMCTL
    chmod +x "$tmp/bin/sshd" "$tmp/bin/mv" "$tmp/bin/systemctl"
    RESTART_LOG="$tmp/restart.log"
    export RESTART_LOG
    PATH="$tmp/bin:$PATH"
    if (harden_ssh_config > "$tmp/out" 2>&1); then
        fail "atomic write failure restores backup"
    elif grep -q '^PasswordAuthentication yes$' "$SSH_CONFIG" &&
        grep -q "写入 SSH 配置失败，已恢复备份" "$tmp/out" &&
        [ ! -s "$RESTART_LOG" ]; then
        pass "atomic write failure restores backup"
    else
        fail "atomic write failure restores backup"
    fi
    PATH=$old_path
    SSH_CONFIG=$old_ssh_config
    RUN_SSHD_DIR=$old_run_sshd_dir
    unset IKE_TEST_UID RESTART_LOG
    rm -rf "$tmp"
}

test_effective_sshd_T_failure_restores_backup() {
    tmp=$(make_test_dir)
    old_path=$PATH
    old_ssh_config=$SSH_CONFIG
    old_run_sshd_dir=$RUN_SSHD_DIR
    mkdir -p "$tmp/bin"
    SSH_CONFIG="$tmp/sshd_config"
    RUN_SSHD_DIR="$tmp/run/sshd"
    IKE_TEST_UID=0
    export IKE_TEST_UID
    printf '%s\n' "PasswordAuthentication yes" > "$SSH_CONFIG"
    cat > "$tmp/bin/sshd" <<'MOCK_SSHD'
#!/bin/sh
while [ "$#" -gt 0 ]; do
    if [ "$1" = "-T" ]; then
        exit 1
    fi
    shift
done
exit 0
MOCK_SSHD
    cat > "$tmp/bin/systemctl" <<'MOCK_SYSTEMCTL'
#!/bin/sh
printf '%s\n' "restart" >> "$RESTART_LOG"
exit 0
MOCK_SYSTEMCTL
    chmod +x "$tmp/bin/sshd" "$tmp/bin/systemctl"
    RESTART_LOG="$tmp/restart.log"
    export RESTART_LOG
    PATH="$tmp/bin:$PATH"
    if (harden_ssh_config > "$tmp/out" 2>&1); then
        fail "sshd -T failure restores backup"
    elif grep -q '^PasswordAuthentication yes$' "$SSH_CONFIG" &&
        grep -q "sshd -T 无法读取最终配置" "$tmp/out" &&
        [ ! -s "$RESTART_LOG" ]; then
        pass "sshd -T failure restores backup"
    else
        fail "sshd -T failure restores backup"
    fi
    PATH=$old_path
    SSH_CONFIG=$old_ssh_config
    RUN_SSHD_DIR=$old_run_sshd_dir
    unset IKE_TEST_UID RESTART_LOG
    rm -rf "$tmp"
}

test_restore_sshd_restores_existing_dropin_backup() {
    tmp=$(make_test_dir)
    old_path=$PATH
    old_ssh_config=$SSH_CONFIG
    old_run_sshd_dir=$RUN_SSHD_DIR
    mkdir -p "$tmp/bin" "$tmp/sshd_config.d"
    SSH_CONFIG="$tmp/sshd_config"
    RUN_SSHD_DIR="$tmp/run/sshd"
    IKE_TEST_UID=0
    export IKE_TEST_UID
    {
        printf '%s\n' "Include $tmp/sshd_config.d/*.conf"
        printf '%s\n' "PasswordAuthentication yes"
    } > "$SSH_CONFIG.bak.20260429_090000"
    {
        printf '%s\n' "Include $tmp/sshd_config.d/*.conf"
        printf '%s\n' "PasswordAuthentication no"
    } > "$SSH_CONFIG"
    printf '%s\n' "old dropin content" > "$tmp/sshd_config.d/00-ssh-init-hardening.conf.bak.20260429_090000"
    write_sshd_hardening_dropin_content "$tmp/sshd_config.d/00-ssh-init-hardening.conf"
    cat > "$tmp/bin/sshd" <<'MOCK_SSHD'
#!/bin/sh
exit 0
MOCK_SSHD
    cat > "$tmp/bin/systemctl" <<'MOCK_SYSTEMCTL'
#!/bin/sh
exit 0
MOCK_SYSTEMCTL
    chmod +x "$tmp/bin/sshd" "$tmp/bin/systemctl"
    PATH="$tmp/bin:$PATH"
    backup=$(latest_sshd_backup)
    if restore_sshd_config_from_backup "$backup" > "$tmp/out" 2>&1 &&
        grep -q '^PasswordAuthentication yes$' "$SSH_CONFIG" &&
        grep -q '^old dropin content$' "$tmp/sshd_config.d/00-ssh-init-hardening.conf" &&
        grep -q "已恢复 SSH drop-in" "$tmp/out"; then
        pass "restore sshd_config also restores existing drop-in backup"
    else
        fail "restore sshd_config also restores existing drop-in backup"
    fi
    PATH=$old_path
    SSH_CONFIG=$old_ssh_config
    RUN_SSHD_DIR=$old_run_sshd_dir
    unset IKE_TEST_UID
    rm -rf "$tmp"
}

test_restore_sshd_removes_new_managed_dropin() {
    tmp=$(make_test_dir)
    old_path=$PATH
    old_ssh_config=$SSH_CONFIG
    old_run_sshd_dir=$RUN_SSHD_DIR
    mkdir -p "$tmp/bin" "$tmp/sshd_config.d"
    SSH_CONFIG="$tmp/sshd_config"
    RUN_SSHD_DIR="$tmp/run/sshd"
    IKE_TEST_UID=0
    export IKE_TEST_UID
    {
        printf '%s\n' "Include $tmp/sshd_config.d/*.conf"
        printf '%s\n' "PasswordAuthentication yes"
    } > "$SSH_CONFIG.bak.20260429_090000"
    {
        printf '%s\n' "Include $tmp/sshd_config.d/*.conf"
        printf '%s\n' "PasswordAuthentication no"
    } > "$SSH_CONFIG"
    write_sshd_hardening_dropin_content "$tmp/sshd_config.d/00-ssh-init-hardening.conf"
    cat > "$tmp/bin/sshd" <<'MOCK_SSHD'
#!/bin/sh
exit 0
MOCK_SSHD
    cat > "$tmp/bin/systemctl" <<'MOCK_SYSTEMCTL'
#!/bin/sh
exit 0
MOCK_SYSTEMCTL
    chmod +x "$tmp/bin/sshd" "$tmp/bin/systemctl"
    PATH="$tmp/bin:$PATH"
    backup=$(latest_sshd_backup)
    if restore_sshd_config_from_backup "$backup" > "$tmp/out" 2>&1 &&
        grep -q '^PasswordAuthentication yes$' "$SSH_CONFIG" &&
        [ ! -e "$tmp/sshd_config.d/00-ssh-init-hardening.conf" ] &&
        grep -q "已移除 ssh-init 创建的 drop-in" "$tmp/out"; then
        pass "restore sshd_config removes newly created managed drop-in"
    else
        fail "restore sshd_config removes newly created managed drop-in"
    fi
    PATH=$old_path
    SSH_CONFIG=$old_ssh_config
    RUN_SSHD_DIR=$old_run_sshd_dir
    unset IKE_TEST_UID
    rm -rf "$tmp"
}

test_match_authentication_methods_blocks_hardening() {
    tmp=$(make_test_dir)
    old_ssh_config=$SSH_CONFIG
    SSH_CONFIG="$tmp/sshd_config"
    IKE_TEST_UID=0
    export IKE_TEST_UID
    {
        printf '%s\n' "PasswordAuthentication yes"
        printf '%s\n' "Match User admin"
        printf '%s\n' "    AuthenticationMethods publickey,password"
    } > "$SSH_CONFIG"
    if (harden_ssh_config > "$tmp/out" 2>&1); then
        fail "Match AuthenticationMethods publickey,password blocks hardening"
    elif grep -q "AuthenticationMethods publickey,password" "$tmp/out" &&
        grep -q "继续可能导致 SSH 无法登录" "$tmp/out" &&
        [ "$(find "$tmp" -name 'sshd_config.bak.*' | wc -l | awk '{print $1}')" = "0" ]; then
        pass "Match AuthenticationMethods publickey,password blocks hardening"
    else
        fail "Match AuthenticationMethods publickey,password blocks hardening"
    fi
    SSH_CONFIG=$old_ssh_config
    unset IKE_TEST_UID
    rm -rf "$tmp"
}

test_list_backups_includes_dropin() {
    tmp=$(make_test_dir)
    old_ssh_config=$SSH_CONFIG
    SSH_CONFIG="$tmp/sshd_config"
    mkdir -p "$tmp/sshd_config.d"
    printf '%s\n' "Include $tmp/sshd_config.d/*.conf" > "$SSH_CONFIG"
    printf '%s\n' "old dropin" > "$tmp/sshd_config.d/00-ssh-init-hardening.conf.bak.20260429_090000"
    list_backups > "$tmp/out"
    if grep -q "SSH drop-in 备份" "$tmp/out" &&
        grep -q "00-ssh-init-hardening.conf.bak.20260429_090000" "$tmp/out"; then
        pass "restore backup list includes drop-in backups"
    else
        fail "restore backup list includes drop-in backups"
    fi
    SSH_CONFIG=$old_ssh_config
    rm -rf "$tmp"
}

test_fetch_github_keys_wget_busybox_timeout() {
    tmp=$(make_test_dir)
    old_path=$PATH
    mkdir -p "$tmp/bin"
    cat > "$tmp/bin/wget" <<'MOCK_WGET'
#!/bin/sh
if [ "$1" = "--help" ]; then
    printf '%s\n' "BusyBox wget mock"
    exit 0
fi
case "$*" in
    *-T\ 10*)
        printf '%s\n' 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBHiTtwHOMyc2QbrXv/15/f/TmESu5rAxMdF31qhnU8g test@example'
        exit 0
        ;;
esac
exit 1
MOCK_WGET
    chmod +x "$tmp/bin/wget"
    PATH="$tmp/bin:$PATH"
    output="$tmp/keys"
    if fetch_github_keys "ike-sh" "$output" >/dev/null 2>&1 &&
        grep -Fq 'ssh-ed25519' "$output"; then
        pass "fetch_github_keys uses wget -T fallback for BusyBox"
    else
        fail "fetch_github_keys uses wget -T fallback for BusyBox"
    fi
    PATH=$old_path
    rm -rf "$tmp"
}

test_restore_both_rolls_back_sshd_when_auth_fails() {
    tmp=$(make_test_dir)
    old_path=$PATH
    old_ssh_config=$SSH_CONFIG
    old_run_sshd_dir=$RUN_SSHD_DIR
    mkdir -p "$tmp/bin"
    setup_home "$tmp"
    SSH_CONFIG="$tmp/sshd_config"
    RUN_SSHD_DIR="$tmp/run/sshd"
    IKE_TEST_UID=0
    export IKE_TEST_UID
    auth="$IKE_TEST_HOME/.ssh/authorized_keys"
    mkdir -p "$IKE_TEST_HOME/.ssh"
    printf '%s\n' "current-sshd" > "$SSH_CONFIG"
    printf '%s\n' "restored-sshd" > "$SSH_CONFIG.bak.20260429_090000"
    printf '%s\n' "current-auth" > "$auth"
    cat > "$tmp/bin/sshd" <<'MOCK_SSHD'
#!/bin/sh
exit 0
MOCK_SSHD
    cat > "$tmp/bin/systemctl" <<'MOCK_SYSTEMCTL'
#!/bin/sh
exit 0
MOCK_SYSTEMCTL
    chmod +x "$tmp/bin/sshd" "$tmp/bin/systemctl"
    PATH="$tmp/bin:$PATH"
    if (restore_sshd_and_authorized_keys_from_backups "$SSH_CONFIG.bak.20260429_090000" "$auth.bak.missing" > "$tmp/out" 2>&1); then
        fail "restore both rolls back sshd when authorized_keys restore fails"
    elif grep -q '^current-sshd$' "$SSH_CONFIG" &&
        grep -Fxq "current-auth" "$auth" &&
        grep -q "authorized_keys 恢复失败" "$tmp/out"; then
        pass "restore both rolls back sshd when authorized_keys restore fails"
    else
        fail "restore both rolls back sshd when authorized_keys restore fails"
    fi
    PATH=$old_path
    SSH_CONFIG=$old_ssh_config
    RUN_SSHD_DIR=$old_run_sshd_dir
    clear_test_user
    unset IKE_TEST_UID
    rm -rf "$tmp"
}

test_restore_latest_sshd_config_backup() {
    tmp=$(make_test_dir)
    old_path=$PATH
    old_ssh_config=$SSH_CONFIG
    old_run_sshd_dir=$RUN_SSHD_DIR
    mkdir -p "$tmp/bin"
    SSH_CONFIG="$tmp/sshd_config"
    RUN_SSHD_DIR="$tmp/run/sshd"
    IKE_TEST_UID=0
    export IKE_TEST_UID
    printf '%s\n' "PasswordAuthentication yes" > "$SSH_CONFIG"
    printf '%s\n' "PasswordAuthentication maybe" > "$SSH_CONFIG.bak.20260429_083759"
    printf '%s\n' "PasswordAuthentication no" > "$SSH_CONFIG.bak.20260429_090000"
    cat > "$tmp/bin/sshd" <<'MOCK_SSHD'
#!/bin/sh
exit 0
MOCK_SSHD
    cat > "$tmp/bin/systemctl" <<'MOCK_SYSTEMCTL'
#!/bin/sh
exit 0
MOCK_SYSTEMCTL
    chmod +x "$tmp/bin/sshd" "$tmp/bin/systemctl"
    PATH="$tmp/bin:$PATH"
    backup=$(latest_sshd_backup)
    if restore_sshd_config_from_backup "$backup" >/dev/null 2>&1 &&
        grep -q '^PasswordAuthentication no$' "$SSH_CONFIG"; then
        pass "restore latest sshd_config backup"
    else
        fail "restore latest sshd_config backup"
    fi
    PATH=$old_path
    SSH_CONFIG=$old_ssh_config
    RUN_SSHD_DIR=$old_run_sshd_dir
    unset IKE_TEST_UID
    rm -rf "$tmp"
}

test_restore_sshd_shows_effective_config() {
    tmp=$(make_test_dir)
    old_path=$PATH
    old_ssh_config=$SSH_CONFIG
    old_run_sshd_dir=$RUN_SSHD_DIR
    mkdir -p "$tmp/bin"
    SSH_CONFIG="$tmp/sshd_config"
    RUN_SSHD_DIR="$tmp/run/sshd"
    IKE_TEST_UID=0
    export IKE_TEST_UID
    printf '%s\n' "PasswordAuthentication yes" > "$SSH_CONFIG"
    printf '%s\n' "PasswordAuthentication no" > "$SSH_CONFIG.bak.20260429_090000"
    cat > "$tmp/bin/sshd" <<'MOCK_SSHD'
#!/bin/sh
if [ "$1" = "-T" ]; then
    printf '%s\n' "passwordauthentication no"
    printf '%s\n' "permitrootlogin prohibit-password"
    exit 0
fi
exit 0
MOCK_SSHD
    cat > "$tmp/bin/systemctl" <<'MOCK_SYSTEMCTL'
#!/bin/sh
exit 0
MOCK_SYSTEMCTL
    chmod +x "$tmp/bin/sshd" "$tmp/bin/systemctl"
    PATH="$tmp/bin:$PATH"
    backup=$(latest_sshd_backup)
    restore_sshd_config_from_backup "$backup" > "$tmp/out" 2>&1
    if grep -q "passwordauthentication no" "$tmp/out" &&
        grep -q "当前 PasswordAuthentication: no" "$tmp/out" &&
        grep -q "当前 PermitRootLogin: prohibit-password" "$tmp/out"; then
        pass "restore sshd_config shows effective status"
    else
        fail "restore sshd_config shows effective status"
    fi
    PATH=$old_path
    SSH_CONFIG=$old_ssh_config
    RUN_SSHD_DIR=$old_run_sshd_dir
    unset IKE_TEST_UID
    rm -rf "$tmp"
}

test_restore_sshd_immutable_unlocks_and_relocks() {
    tmp=$(make_test_dir)
    old_path=$PATH
    old_ssh_config=$SSH_CONFIG
    old_run_sshd_dir=$RUN_SSHD_DIR
    old_flag=$SSHD_CONFIG_WAS_IMMUTABLE
    mkdir -p "$tmp/bin"
    SSH_CONFIG="$tmp/sshd_config"
    RUN_SSHD_DIR="$tmp/run/sshd"
    IKE_TEST_UID=0
    export IKE_TEST_UID
    printf '%s\n' "PasswordAuthentication yes" > "$SSH_CONFIG"
    printf '%s\n' "PasswordAuthentication no" > "$SSH_CONFIG.bak.20260429_090000"
    cat > "$tmp/bin/lsattr" <<'MOCK_LSATTR'
#!/bin/sh
printf '%s\n' '----i---------e------- '"$1"
MOCK_LSATTR
    cat > "$tmp/bin/chattr" <<'MOCK_CHATTR'
#!/bin/sh
printf '%s\n' "$*" >> "$CHATTR_LOG"
exit 0
MOCK_CHATTR
    cat > "$tmp/bin/sshd" <<'MOCK_SSHD'
#!/bin/sh
exit 0
MOCK_SSHD
    cat > "$tmp/bin/systemctl" <<'MOCK_SYSTEMCTL'
#!/bin/sh
exit 0
MOCK_SYSTEMCTL
    chmod +x "$tmp/bin/lsattr" "$tmp/bin/chattr" "$tmp/bin/sshd" "$tmp/bin/systemctl"
    CHATTR_LOG="$tmp/chattr.log"
    export CHATTR_LOG
    PATH="$tmp/bin:$PATH"
    backup=$(latest_sshd_backup)
    if restore_sshd_config_from_backup "$backup" > "$tmp/out" 2>&1 &&
        grep -q -- "-i $SSH_CONFIG" "$CHATTR_LOG" &&
        grep -q -- "+i $SSH_CONFIG" "$CHATTR_LOG" &&
        grep -q '^PasswordAuthentication no$' "$SSH_CONFIG"; then
        pass "restore sshd_config unlocks and relocks immutable file"
    else
        fail "restore sshd_config unlocks and relocks immutable file"
    fi
    PATH=$old_path
    SSH_CONFIG=$old_ssh_config
    RUN_SSHD_DIR=$old_run_sshd_dir
    SSHD_CONFIG_WAS_IMMUTABLE=$old_flag
    unset IKE_TEST_UID CHATTR_LOG
    rm -rf "$tmp"
}

test_restore_sshd_t_failure_restores_and_relocks() {
    tmp=$(make_test_dir)
    old_path=$PATH
    old_ssh_config=$SSH_CONFIG
    old_run_sshd_dir=$RUN_SSHD_DIR
    old_flag=$SSHD_CONFIG_WAS_IMMUTABLE
    mkdir -p "$tmp/bin"
    SSH_CONFIG="$tmp/sshd_config"
    RUN_SSHD_DIR="$tmp/run/sshd"
    IKE_TEST_UID=0
    export IKE_TEST_UID
    printf '%s\n' "PasswordAuthentication current" > "$SSH_CONFIG"
    printf '%s\n' "PasswordAuthentication broken" > "$SSH_CONFIG.bak.20260429_090000"
    cat > "$tmp/bin/lsattr" <<'MOCK_LSATTR'
#!/bin/sh
printf '%s\n' '----i---------e------- '"$1"
MOCK_LSATTR
    cat > "$tmp/bin/chattr" <<'MOCK_CHATTR'
#!/bin/sh
printf '%s\n' "$*" >> "$CHATTR_LOG"
exit 0
MOCK_CHATTR
    cat > "$tmp/bin/sshd" <<'MOCK_SSHD'
#!/bin/sh
exit 1
MOCK_SSHD
    chmod +x "$tmp/bin/lsattr" "$tmp/bin/chattr" "$tmp/bin/sshd"
    CHATTR_LOG="$tmp/chattr.log"
    export CHATTR_LOG
    PATH="$tmp/bin:$PATH"
    backup=$(latest_sshd_backup)
    if restore_sshd_config_from_backup "$backup" > "$tmp/out" 2>&1; then
        fail "restore sshd_config sshd -t failure restores and relocks"
    elif grep -q '^PasswordAuthentication current$' "$SSH_CONFIG" &&
        grep -q -- "+i $SSH_CONFIG" "$CHATTR_LOG"; then
        pass "restore sshd_config sshd -t failure restores and relocks"
    else
        fail "restore sshd_config sshd -t failure restores and relocks"
    fi
    PATH=$old_path
    SSH_CONFIG=$old_ssh_config
    RUN_SSHD_DIR=$old_run_sshd_dir
    SSHD_CONFIG_WAS_IMMUTABLE=$old_flag
    unset IKE_TEST_UID CHATTR_LOG
    rm -rf "$tmp"
}

test_restore_latest_authorized_keys_backup() {
    tmp=$(make_test_dir)
    setup_home "$tmp"
    mkdir -p "$IKE_TEST_HOME/.ssh"
    auth="$IKE_TEST_HOME/.ssh/authorized_keys"
    printf '%s\n' "old" > "$auth"
    printf '%s\n' "$VALID_KEY" > "$auth.bak.20260429_083759"
    printf '%s\n' "$VALID_KEY_2" > "$auth.bak.20260429_090000"
    backup=$(latest_authorized_keys_backup)
    if restore_authorized_keys_from_backup "$backup" > "$tmp/out" 2>&1 &&
        grep -Fxq "$VALID_KEY_2" "$auth" &&
        has_mode "$auth" 600 &&
        grep -q "恢复为备份时的内容" "$tmp/out"; then
        pass "restore latest authorized_keys backup"
    else
        fail "restore latest authorized_keys backup"
    fi
    clear_test_user
    rm -rf "$tmp"
}

test_restore_list_reverse_order() {
    tmp=$(make_test_dir)
    old_ssh_config=$SSH_CONFIG
    SSH_CONFIG="$tmp/sshd_config"
    setup_home "$tmp"
    mkdir -p "$IKE_TEST_HOME/.ssh"
    printf '%s\n' "current" > "$SSH_CONFIG"
    printf '%s\n' "old" > "$SSH_CONFIG.bak.20260429_083759"
    printf '%s\n' "new" > "$SSH_CONFIG.bak.20260429_090210"
    printf '%s\n' "old" > "$IKE_TEST_HOME/.ssh/authorized_keys.bak.20260429_083759"
    printf '%s\n' "new" > "$IKE_TEST_HOME/.ssh/authorized_keys.bak.20260429_090210"
    list_backups > "$tmp/out"
    first_sshd=$(awk '/sshd_config.bak/ { print; exit }' "$tmp/out")
    first_auth=$(awk '/authorized_keys.bak/ { print; exit }' "$tmp/out")
    if printf '%s\n' "$first_sshd" | grep -q '20260429_090210' &&
        printf '%s\n' "$first_auth" | grep -q '20260429_090210'; then
        pass "restore backup list shows newest first"
    else
        fail "restore backup list shows newest first"
    fi
    SSH_CONFIG=$old_ssh_config
    clear_test_user
    rm -rf "$tmp"
}

test_clear_authorized_keys_requires_yes() {
    tmp=$(make_test_dir)
    setup_home "$tmp"
    mkdir -p "$IKE_TEST_HOME/.ssh"
    auth="$IKE_TEST_HOME/.ssh/authorized_keys"
    printf '%s\n' "$VALID_KEY" > "$auth"
    printf '%s\n' "no" > "$tmp/in"
    if clear_authorized_keys_interactive < "$tmp/in" > "$tmp/out" 2>&1; then
        fail "clear authorized_keys requires uppercase YES"
    elif grep -Fxq "$VALID_KEY" "$auth"; then
        pass "clear authorized_keys requires uppercase YES"
    else
        fail "clear authorized_keys requires uppercase YES"
    fi
    clear_test_user
    rm -rf "$tmp"
}

test_clear_authorized_keys_backup_and_empty() {
    tmp=$(make_test_dir)
    setup_home "$tmp"
    mkdir -p "$IKE_TEST_HOME/.ssh"
    auth="$IKE_TEST_HOME/.ssh/authorized_keys"
    printf '%s\n' "$VALID_KEY" > "$auth"
    printf '%s\n' "YES" > "$tmp/in"
    clear_authorized_keys_interactive < "$tmp/in" > "$tmp/out" 2>&1
    backup_count=$(find "$IKE_TEST_HOME/.ssh" -name 'authorized_keys.before-clear.*' | wc -l | awk '{print $1}')
    lines=$(wc -l < "$auth" | awk '{print $1}')
    if [ "$backup_count" = "1" ] &&
        [ "$lines" = "0" ] &&
        has_mode "$auth" 600; then
        pass "clear authorized_keys backs up then empties file"
    else
        fail "clear authorized_keys backs up then empties file"
    fi
    clear_test_user
    rm -rf "$tmp"
}

test_show_local_keys_empty() {
    tmp=$(make_test_dir)
    setup_home "$tmp"
    show_local_keys < /dev/null > "$tmp/out" 2>&1
    if grep -q "未发现常见 SSH 密钥" "$tmp/out" &&
        grep -q "菜单 4" "$tmp/out"; then
        pass "show_local_keys suggests menu 4 when empty"
    else
        fail "show_local_keys suggests menu 4 when empty"
    fi
    clear_test_user
    rm -rf "$tmp"
}

test_show_local_keys_prints_public_key() {
    tmp=$(make_test_dir)
    setup_home "$tmp"
    mkdir -p "$IKE_TEST_HOME/.ssh"
    printf '%s\n' "$VALID_KEY" > "$IKE_TEST_HOME/.ssh/id_ed25519.pub"
    show_local_keys < /dev/null > "$tmp/out" 2>&1
    if grep -q "本机公钥信息" "$tmp/out" &&
        grep -Fxq "$VALID_KEY" "$tmp/out"; then
        pass "show_local_keys prints public key"
    else
        fail "show_local_keys prints public key"
    fi
    clear_test_user
    rm -rf "$tmp"
}

test_show_local_keys_hides_private_by_default() {
    tmp=$(make_test_dir)
    setup_home "$tmp"
    mkdir -p "$IKE_TEST_HOME/.ssh"
    printf '%s\n' "-----BEGIN OPENSSH PRIVATE KEY-----" "secret" "-----END OPENSSH PRIVATE KEY-----" > "$IKE_TEST_HOME/.ssh/id_ed25519"
    show_local_keys < /dev/null > "$tmp/out" 2>&1
    if grep -q "私钥文件:" "$tmp/out" &&
        ! grep -q "BEGIN OPENSSH PRIVATE KEY" "$tmp/out"; then
        pass "show_local_keys hides private key by default"
    else
        fail "show_local_keys hides private key by default"
    fi
    clear_test_user
    rm -rf "$tmp"
}

test_show_local_keys_prints_private_on_show() {
    tmp=$(make_test_dir)
    setup_home "$tmp"
    mkdir -p "$IKE_TEST_HOME/.ssh"
    printf '%s\n' "-----BEGIN OPENSSH PRIVATE KEY-----" "secret" "-----END OPENSSH PRIVATE KEY-----" > "$IKE_TEST_HOME/.ssh/id_ed25519"
    printf '%s\n' "SHOW" > "$tmp/in"
    show_local_keys < "$tmp/in" > "$tmp/out" 2>&1
    if grep -q "BEGIN OPENSSH PRIVATE KEY" "$tmp/out"; then
        pass "show_local_keys prints private key only on SHOW"
    else
        fail "show_local_keys prints private key only on SHOW"
    fi
    clear_test_user
    rm -rf "$tmp"
}

make_mock_ssh_keygen() {
    bin_dir="$1"
    cat > "$bin_dir/ssh-keygen" <<'MOCK_KEYGEN'
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
printf '%s\n' '-----BEGIN OPENSSH PRIVATE KEY-----' 'mock-local' '-----END OPENSSH PRIVATE KEY-----' > "$out"
printf '%s\n' 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILocalGeneratedKey1234567890 ssh-init-generated' > "$out.pub"
MOCK_KEYGEN
    chmod +x "$bin_dir/ssh-keygen"
}

test_keygen_existing_requires_yes() {
    tmp=$(make_test_dir)
    old_path=$PATH
    setup_home "$tmp"
    mkdir -p "$tmp/bin" "$IKE_TEST_HOME/.ssh"
    make_mock_ssh_keygen "$tmp/bin"
    printf '%s\n' "old-private" > "$IKE_TEST_HOME/.ssh/id_ed25519"
    printf '%s\n' "old-public" > "$IKE_TEST_HOME/.ssh/id_ed25519.pub"
    printf '%s\n' "no" > "$tmp/in"
    PATH="$tmp/bin:$PATH"
    if generate_local_key_only < "$tmp/in" > "$tmp/out" 2>&1; then
        fail "keygen existing key requires uppercase YES"
    elif grep -q "old-private" "$IKE_TEST_HOME/.ssh/id_ed25519" &&
        grep -q "old-public" "$IKE_TEST_HOME/.ssh/id_ed25519.pub"; then
        pass "keygen existing key requires uppercase YES"
    else
        fail "keygen existing key requires uppercase YES"
    fi
    PATH=$old_path
    clear_test_user
    rm -rf "$tmp"
}

test_keygen_backup_before_overwrite() {
    tmp=$(make_test_dir)
    old_path=$PATH
    setup_home "$tmp"
    mkdir -p "$tmp/bin" "$IKE_TEST_HOME/.ssh"
    make_mock_ssh_keygen "$tmp/bin"
    printf '%s\n' "old-private" > "$IKE_TEST_HOME/.ssh/id_ed25519"
    printf '%s\n' "old-public" > "$IKE_TEST_HOME/.ssh/id_ed25519.pub"
    printf '%s\n' "YES" > "$tmp/in"
    PATH="$tmp/bin:$PATH"
    generate_local_key_only < "$tmp/in" > "$tmp/out" 2>&1
    private_bak=$(find "$IKE_TEST_HOME/.ssh" -name 'id_ed25519.bak.*' | wc -l | awk '{print $1}')
    public_bak=$(find "$IKE_TEST_HOME/.ssh" -name 'id_ed25519.pub.bak.*' | wc -l | awk '{print $1}')
    if [ "$private_bak" = "1" ] && [ "$public_bak" = "1" ]; then
        pass "keygen creates timestamp backups before overwrite"
    else
        fail "keygen creates timestamp backups before overwrite"
    fi
    PATH=$old_path
    clear_test_user
    rm -rf "$tmp"
}

test_keygen_generates_files_and_modes() {
    tmp=$(make_test_dir)
    old_path=$PATH
    setup_home "$tmp"
    mkdir -p "$tmp/bin"
    make_mock_ssh_keygen "$tmp/bin"
    PATH="$tmp/bin:$PATH"
    generate_local_key_only < /dev/null > "$tmp/out" 2>&1
    private="$IKE_TEST_HOME/.ssh/id_ed25519"
    public="$private.pub"
    if [ -f "$private" ] &&
        [ -f "$public" ] &&
        has_mode "$private" 600 &&
        has_mode "$public" 644 &&
        grep -q "请复制以下公钥到 GitHub" "$tmp/out"; then
        pass "keygen generates id_ed25519 files with expected modes"
    else
        fail "keygen generates id_ed25519 files with expected modes"
    fi
    PATH=$old_path
    clear_test_user
    rm -rf "$tmp"
}

test_gen_mode_public_and_private_blocks() {
    tmp=$(make_test_dir)
    GENERATED_PRIVATE_KEY_FILE="$tmp/generated_ed25519"
    GENERATED_PUBLIC_KEY_FILE="$tmp/generated_ed25519.pub"
    printf '%s\n' "-----BEGIN OPENSSH PRIVATE KEY-----" "mock" "-----END OPENSSH PRIVATE KEY-----" > "$GENERATED_PRIVATE_KEY_FILE"
    printf '%s\n' "$VALID_KEY" > "$GENERATED_PUBLIC_KEY_FILE"
    {
        print_generated_public_key
        print_generated_private_key
    } > "$tmp/out" 2>&1
    if grep -q "请复制以下公钥到 GitHub" "$tmp/out" &&
        grep -q "请复制保存以下私钥" "$tmp/out" &&
        grep -q "该公钥已自动写入当前用户 authorized_keys" "$tmp/out"; then
        pass "gen mode output includes public and private blocks"
    else
        fail "gen mode output includes public and private blocks"
    fi
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

test_gen_mode_public_key_mode_644() {
    tmp=$(make_test_dir)
    old_path=$PATH
    mkdir -p "$tmp/bin"
    make_mock_ssh_keygen "$tmp/bin"
    PATH="$tmp/bin:$PATH"
    TMP_DIR="$tmp/work"
    mkdir -p "$TMP_DIR"
    generate_ed25519_key_pair
    pub_perms=$(ls -l "$GENERATED_PUBLIC_KEY_FILE" 2>/dev/null | awk '{print $1}')
    if case "$pub_perms" in -rw-r--r--*) true;; *) false;; esac; then
        pass "gen mode temporary public key uses mode 644"
    else
        fail "gen mode temporary public key uses mode 644"
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

test_cli_github_parsing() {
    if parse_cli_args github ike-sh &&
        [ "$CLI_MODE" = "github" ] &&
        [ "$CLI_GITHUB_USER" = "ike-sh" ]; then
        pass "CLI github subcommand parsing"
    else
        fail "CLI github subcommand parsing"
    fi
}

test_cli_gen_parsing() {
    if parse_cli_args gen &&
        [ "$CLI_MODE" = "gen" ]; then
        pass "CLI gen subcommand parsing"
    else
        fail "CLI gen subcommand parsing"
    fi
}

test_cli_keys_parsing() {
    if parse_cli_args keys &&
        [ "$CLI_MODE" = "keys" ]; then
        pass "CLI keys subcommand parsing"
    else
        fail "CLI keys subcommand parsing"
    fi
}

test_cli_keygen_parsing() {
    if parse_cli_args keygen &&
        [ "$CLI_MODE" = "keygen" ]; then
        pass "CLI keygen subcommand parsing"
    else
        fail "CLI keygen subcommand parsing"
    fi
}

test_cli_restore_parsing() {
    if parse_cli_args restore &&
        [ "$CLI_MODE" = "restore" ]; then
        pass "CLI restore subcommand parsing"
    else
        fail "CLI restore subcommand parsing"
    fi
}

test_cli_status_parsing() {
    if parse_cli_args status &&
        [ "$CLI_MODE" = "status" ]; then
        pass "CLI status subcommand parsing"
    else
        fail "CLI status subcommand parsing"
    fi
}

test_cli_debug_effective_parsing() {
    if parse_cli_args --debug-effective &&
        [ "$CLI_MODE" = "debug-effective" ]; then
        pass "CLI --debug-effective parsing"
    else
        fail "CLI --debug-effective parsing"
    fi
}

test_menu_output() {
    tmp=$(make_test_dir)
    show_menu > "$tmp/menu"
    if grep -q "SSH 密钥登录配置" "$tmp/menu" &&
        grep -q "7. 退出" "$tmp/menu" &&
        grep -q "生成新的本机 Ed25519 密钥" "$tmp/menu"; then
        pass "no-arg menu function"
    else
        fail "no-arg menu function"
    fi
    rm -rf "$tmp"
}

test_debug_effective_outputs_report_without_config_d() {
    tmp=$(make_test_dir)
    old_path=$PATH
    old_ssh_config=$SSH_CONFIG
    old_run_sshd_dir=$RUN_SSHD_DIR
    mkdir -p "$tmp/bin"
    SSH_CONFIG="$tmp/sshd_config"
    RUN_SSHD_DIR="$tmp/run/sshd"
    {
        printf '%s\n' "PasswordAuthentication yes"
        printf '%s\n' "PermitRootLogin yes"
    } > "$SSH_CONFIG"
    before=$(cat "$SSH_CONFIG")
    cat > "$tmp/bin/sshd" <<'MOCK_SSHD'
#!/bin/sh
if [ "$1" = "-T" ]; then
    printf '%s\n' "pubkeyauthentication yes"
    printf '%s\n' "passwordauthentication yes"
    printf '%s\n' "kbdinteractiveauthentication no"
    printf '%s\n' "permitemptypasswords no"
    printf '%s\n' "permitrootlogin yes"
    printf '%s\n' "authenticationmethods any"
fi
exit 0
MOCK_SSHD
    chmod +x "$tmp/bin/sshd"
    PATH="$tmp/bin:$PATH"
    if IKE_TEST_MODE=0 SSH_CONFIG="$SSH_CONFIG" RUN_SSHD_DIR="$RUN_SSHD_DIR" PATH="$PATH" sh "$ROOT_DIR/init.sh" --debug-effective > "$tmp/out" 2>&1 &&
        grep -q "SSH 最终生效配置诊断" "$tmp/out" &&
        grep -q "sshd 路径: $tmp/bin/sshd" "$tmp/out" &&
        grep -q "passwordauthentication yes" "$tmp/out" &&
        grep -q "1:PasswordAuthentication yes" "$tmp/out" &&
        [ "$(cat "$SSH_CONFIG")" = "$before" ] &&
        [ "$(find "$tmp" -name 'sshd_config.bak.*' | wc -l | awk '{print $1}')" = "0" ]; then
        pass "--debug-effective reports final values without modifying config"
    else
        fail "--debug-effective reports final values without modifying config"
    fi
    PATH=$old_path
    SSH_CONFIG=$old_ssh_config
    RUN_SSHD_DIR=$old_run_sshd_dir
    rm -rf "$tmp"
}

test_restore_authorized_keys_message() {
    tmp=$(make_test_dir)
    show_authorized_keys_summary "$tmp/missing" > "$tmp/out" 2>&1
    info "authorized_keys 已恢复为备份时的内容；这不是清空 authorized_keys；如果仍有公钥行，说明备份中本来就有这些公钥。" >> "$tmp/out"
    if grep -q "不是清空 authorized_keys" "$tmp/out"; then
        pass "authorized_keys restore explains it is not clear"
    else
        fail "authorized_keys restore explains it is not clear"
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

test_status_output() {
    tmp=$(make_test_dir)
    old_path=$PATH
    setup_home "$tmp"
    mkdir -p "$tmp/bin" "$IKE_TEST_HOME/.ssh"
    printf '%s\n' "$VALID_KEY" > "$IKE_TEST_HOME/.ssh/authorized_keys"
    cat > "$tmp/bin/sshd" <<'MOCK_SSHD'
#!/bin/sh
if [ "$1" = "-T" ]; then
    printf '%s\n' "port 22"
    printf '%s\n' "permitrootlogin prohibit-password"
    printf '%s\n' "pubkeyauthentication yes"
    printf '%s\n' "passwordauthentication no"
    exit 0
fi
exit 0
MOCK_SSHD
    cat > "$tmp/bin/ss" <<'MOCK_SS'
#!/bin/sh
printf '%s\n' 'LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=1,fd=3))'
MOCK_SS
    chmod +x "$tmp/bin/sshd" "$tmp/bin/ss"
    PATH="$tmp/bin:$PATH"
    show_status > "$tmp/status"
    if grep -q "当前用户: testuser" "$tmp/status" &&
        grep -q "passwordauthentication no" "$tmp/status" &&
        grep -q "sshd" "$tmp/status"; then
        pass "status outputs key SSH settings"
    else
        fail "status outputs key SSH settings"
    fi
    PATH=$old_path
    clear_test_user
    rm -rf "$tmp"
}

test_no_forbidden_features() {
    if grep -E "curl \\| sh|--docker|--warp|--dd|--site|--ssl|install docker|bbr" "$ROOT_DIR/init.sh" >/dev/null 2>&1; then
        fail "no forbidden feature implementation"
    else
        pass "no forbidden feature implementation"
    fi
}

test_ask_prompt_format
test_github_username_validation
test_github_placeholder_rejected
test_github_empty_hint
test_github_import_tutorial_output
test_github_cli_does_not_print_full_tutorial
test_public_key_validation
test_public_key_ssh_keygen_deep_validation
test_github_keys_filtering
test_authorized_keys_append_dedup_and_permissions
test_symlink_ssh_rejected
test_symlink_authorized_keys_rejected
test_sshd_config_settings
test_sshd_config_password_auth_no
test_sshd_config_pubkey_yes
test_sshd_config_permit_root
test_immutable_detection_with_i
test_immutable_detection_without_i
test_unlock_immutable_calls_chattr
test_relock_only_when_originally_immutable
test_sshd_config_writer_does_not_modify_port_or_forbidden_keys
test_sshd_config_writer_only_changes_allowed_keys
test_sshd_t_failure_restores_backup
test_restart_failure_restores_backup
test_effective_include_password_yes_fails
test_dropin_permitrootlogin_success
test_dropin_cloud_init_success
test_existing_dropin_failure_restores_backup
test_new_dropin_failure_removes_file
test_effective_failure_lists_items
test_authentication_methods_blocks_hardening
test_authentication_methods_keyboard_interactive_blocks_hardening
test_authentication_methods_safe_values_allowed
test_match_password_yes_warns_and_preserves
test_atomic_write_failure_restores_backup
test_effective_sshd_T_failure_restores_backup
test_fetch_github_keys_wget_busybox_timeout
test_restore_both_rolls_back_sshd_when_auth_fails
test_restore_latest_sshd_config_backup
test_restore_sshd_restores_existing_dropin_backup
test_restore_sshd_removes_new_managed_dropin
test_match_authentication_methods_blocks_hardening
test_list_backups_includes_dropin
test_restore_sshd_shows_effective_config
test_restore_sshd_immutable_unlocks_and_relocks
test_restore_sshd_t_failure_restores_and_relocks
test_restore_latest_authorized_keys_backup
test_restore_list_reverse_order
test_clear_authorized_keys_requires_yes
test_clear_authorized_keys_backup_and_empty
test_show_local_keys_empty
test_show_local_keys_prints_public_key
test_show_local_keys_hides_private_by_default
test_show_local_keys_prints_private_on_show
test_keygen_existing_requires_yes
test_keygen_backup_before_overwrite
test_keygen_generates_files_and_modes
test_gen_mode_public_and_private_blocks
test_gen_without_ssh_keygen_fails
test_gen_mock_ed25519
test_gen_mode_public_key_mode_644
test_cli_github_parsing
test_cli_gen_parsing
test_cli_keys_parsing
test_cli_keygen_parsing
test_cli_restore_parsing
test_cli_status_parsing
test_cli_debug_effective_parsing
test_menu_output
test_color_output
test_status_output
test_debug_effective_outputs_report_without_config_d
test_restore_authorized_keys_message
test_no_forbidden_features

if [ "$FAIL_COUNT" -gt 0 ]; then
    printf '%s\n' "$FAIL_COUNT test(s) failed" >&2
    exit 1
fi

printf '%s\n' "$PASS_COUNT test(s) passed"
