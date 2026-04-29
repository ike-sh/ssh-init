#!/bin/sh

# ssh-init: configure SSH key login and disable password login.
# POSIX sh only. No BBR, update/upgrade, Docker, site, reverse proxy, WARP, DD or SSL.

set -u

SSH_CONFIG=${SSH_CONFIG:-/etc/ssh/sshd_config}
RUN_SSHD_DIR=${RUN_SSHD_DIR:-/run/sshd}

TMP_DIR=""
GENERATED_PRIVATE_KEY_FILE=""
GENERATED_PUBLIC_KEY_FILE=""
AUTHORIZED_KEYS_FILE=""
CLI_MODE=""
CLI_GITHUB_USER=""
ASK_REPLY=""
LOCAL_SSH_DIR=""

BLUE=$(printf '\033[34m')
GREEN=$(printf '\033[32m')
YELLOW=$(printf '\033[33m')
RED=$(printf '\033[31m')
RESET=$(printf '\033[0m')

info() {
    printf '%s[信息]%s %s\n' "$BLUE" "$RESET" "$*"
}

success() {
    printf '%s[成功]%s %s\n' "$GREEN" "$RESET" "$*"
}

warn() {
    printf '%s[警告]%s %s\n' "$YELLOW" "$RESET" "$*" >&2
}

error() {
    printf '%s[错误]%s %s\n' "$RED" "$RESET" "$*" >&2
}

die() {
    error "$*"
    exit 1
}

print_blank() {
    printf '\n'
}

print_line() {
    printf '%s\n' "============================================================"
}

print_section_title() {
    title="$1"
    print_line
    printf ' %s\n' "$title"
    print_line
}

print_section_end() {
    print_line
}

ask_prompt() {
    prompt="$1"
    printf '%s ' "$prompt"
    if IFS= read -r ASK_REPLY; then
        return 0
    fi
    ASK_REPLY=""
    return 1
}

cleanup_tmp() {
    if [ -n "${TMP_DIR:-}" ] && [ -d "$TMP_DIR" ]; then
        case "$TMP_DIR" in
            */ssh-init.*)
                rm -rf "$TMP_DIR"
                ;;
        esac
    fi
}

trap cleanup_tmp EXIT HUP INT TERM

timestamp() {
    date +%Y%m%d_%H%M%S
}

make_tmp_dir() {
    old_umask=$(umask)
    umask 077
    if command -v mktemp >/dev/null 2>&1; then
        TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/ssh-init.XXXXXX" 2>/dev/null || true)
    fi
    if [ -z "$TMP_DIR" ]; then
        TMP_DIR="${TMPDIR:-/tmp}/ssh-init.$$"
        mkdir "$TMP_DIR" || {
            umask "$old_umask"
            die "无法创建临时目录: $TMP_DIR"
        }
    fi
    chmod 700 "$TMP_DIR" 2>/dev/null || true
    umask "$old_umask"
}

make_tmp_file() {
    prefix="$1"
    if [ -z "${TMP_DIR:-}" ]; then
        make_tmp_dir
    fi
    file="$TMP_DIR/$prefix.$$"
    : > "$file" || die "无法创建临时文件: $file"
    chmod 600 "$file" 2>/dev/null || true
    printf '%s\n' "$file"
}

safe_rm_f() {
    path="$1"
    [ -n "$path" ] || return 1
    [ -e "$path" ] || [ -L "$path" ] || return 0
    rm -f "$path"
}

current_user() {
    if [ -n "${IKE_TEST_USER:-}" ]; then
        printf '%s\n' "$IKE_TEST_USER"
        return 0
    fi
    id -un
}

current_uid() {
    if [ -n "${IKE_TEST_UID:-}" ]; then
        printf '%s\n' "$IKE_TEST_UID"
        return 0
    fi
    id -u
}

home_dir_for_user() {
    user="$1"
    if [ -n "${IKE_TEST_HOME:-}" ]; then
        printf '%s\n' "$IKE_TEST_HOME"
        return 0
    fi
    passwd_home=$(awk -F: -v u="$user" '$1 == u {print $6; exit}' /etc/passwd 2>/dev/null || true)
    if [ -n "$passwd_home" ]; then
        printf '%s\n' "$passwd_home"
        return 0
    fi
    if [ -n "${HOME:-}" ]; then
        printf '%s\n' "$HOME"
        return 0
    fi
    return 1
}

owner_uid() {
    path="$1"
    # shellcheck disable=SC2012
    ls -dn "$path" 2>/dev/null | awk '{print $3}' | sed -n '1p'
}

set_owner() {
    path="$1"
    user="$2"
    if [ "${IKE_TEST_MODE:-0}" = "1" ]; then
        return 0
    fi
    if [ "$(current_uid)" != "0" ]; then
        return 0
    fi
    chown "$user" "$path"
}

mode_marker_path() {
    path="$1"
    if [ -d "$path" ]; then
        printf '%s\n' "$path/.ssh-init-mode"
    else
        printf '%s\n' "$path.ssh-init-mode"
    fi
}

set_mode() {
    mode="$1"
    path="$2"
    chmod "$mode" "$path" || return 1
    if [ "${IKE_TEST_MODE:-0}" = "1" ]; then
        marker=$(mode_marker_path "$path")
        printf '%s\n' "$mode" > "$marker" 2>/dev/null || true
    fi
}

is_symlink_path() {
    path="$1"
    [ -L "$path" ] && return 0
    [ -n "${IKE_TEST_SYMLINK_PATH:-}" ] && [ "$IKE_TEST_SYMLINK_PATH" = "$path" ]
}

require_root() {
    if [ "$(current_uid)" != "0" ]; then
        die "修改 /etc/ssh/sshd_config 和重启 SSH 服务必须使用 root 或 sudo 运行。"
    fi
}

validate_github_username() {
    name="$1"
    case "$name" in
        ""|-*|*-|*[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-]*)
            return 1
            ;;
    esac
    return 0
}

is_github_placeholder() {
    name="$1"
    case "$name" in
        GitHubUser|githubuser|username|yourname|你的用户名)
            return 0
            ;;
    esac
    return 1
}

normalize_key_line() {
    line=$(printf '%s\n' "$1" | awk '{$1=$1; print}')
    key_type=$(printf '%s\n' "$line" | awk '{print $1}')
    key_data=$(printf '%s\n' "$line" | awk '{print $2}')

    case "$key_type" in
        ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com)
            ;;
        *)
            return 1
            ;;
    esac

    case "$key_data" in
        ""|*[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=]*)
            return 1
            ;;
    esac

    key_len=$(printf '%s' "$key_data" | wc -c | awk '{print $1}')
    [ "$key_len" -ge 20 ] || return 1
    printf '%s\n' "$line"
}

filter_valid_keys() {
    input_file="$1"
    output_file="$2"
    : > "$output_file" || return 1
    count=0
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ""|\#*)
                continue
                ;;
        esac
        normalized=$(normalize_key_line "$line" 2>/dev/null || true)
        if [ -n "$normalized" ] && ! grep -Fxq "$normalized" "$output_file" 2>/dev/null; then
            printf '%s\n' "$normalized" >> "$output_file" || return 1
            count=$((count + 1))
        fi
    done < "$input_file"
    printf '%s\n' "$count"
}

fetch_github_keys() {
    user="$1"
    output_file="$2"
    validate_github_username "$user" || {
        error "GitHub 用户名格式无效。"
        return 1
    }
    url="https://github.com/$user.keys"
    info "正在拉取 GitHub 公钥..."
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 10 "$url" > "$output_file" || return 1
    elif command -v wget >/dev/null 2>&1; then
        wget -qO- "$url" > "$output_file" || return 1
    else
        error "缺少 curl 或 wget，无法拉取 GitHub 公钥。"
        return 1
    fi
    [ -s "$output_file" ] || return 2
}

backup_authorized_keys() {
    auth_file="$1"
    if [ -f "$auth_file" ]; then
        backup="$auth_file.bak.$(timestamp)"
        cp -p "$auth_file" "$backup" || return 1
        success "已备份 authorized_keys: $backup"
    fi
}

prepare_authorized_keys() {
    user=$(current_user)
    uid=$(current_uid)
    home=$(home_dir_for_user "$user")
    [ -n "$home" ] || die "无法确定当前用户 HOME。"
    [ "$home" != "/" ] || die "当前用户 HOME 异常。"
    ! is_symlink_path "$home" || die "当前用户 HOME 不能是 symlink。"
    [ -d "$home" ] || die "当前用户 HOME 不存在: $home"
    home_owner=$(owner_uid "$home")
    if [ -n "$home_owner" ] && [ "$home_owner" != "$uid" ]; then
        die "当前用户 HOME owner 异常。"
    fi

    ssh_dir="$home/.ssh"
    auth_file="$ssh_dir/authorized_keys"

    ! is_symlink_path "$ssh_dir" || die ".ssh 不能是 symlink。"
    if [ -e "$ssh_dir" ] && [ ! -d "$ssh_dir" ]; then
        die ".ssh 不是目录。"
    fi
    if [ ! -d "$ssh_dir" ]; then
        mkdir "$ssh_dir" || die "无法创建 ~/.ssh。"
    fi
    set_mode 700 "$ssh_dir" || die "无法设置 ~/.ssh 权限。"
    set_owner "$ssh_dir" "$user" || die "无法设置 ~/.ssh owner。"

    ! is_symlink_path "$auth_file" || die "authorized_keys 不能是 symlink。"
    if [ -e "$auth_file" ] && [ ! -f "$auth_file" ]; then
        die "authorized_keys 不是普通文件。"
    fi
    if [ -f "$auth_file" ]; then
        backup_authorized_keys "$auth_file" || die "无法备份 authorized_keys。"
    else
        : > "$auth_file" || die "无法创建 authorized_keys。"
    fi
    set_mode 600 "$auth_file" || die "无法设置 authorized_keys 权限。"
    set_owner "$auth_file" "$user" || die "无法设置 authorized_keys owner。"
    success "authorized_keys 权限已设置为 600"
    AUTHORIZED_KEYS_FILE="$auth_file"
}

append_keys_to_authorized_keys() {
    valid_keys="$1"
    prepare_authorized_keys
    auth_file="$AUTHORIZED_KEYS_FILE"
    added=0
    while IFS= read -r key_line || [ -n "$key_line" ]; do
        [ -n "$key_line" ] || continue
        if ! grep -Fxq "$key_line" "$auth_file" 2>/dev/null; then
            printf '%s\n' "$key_line" >> "$auth_file" || die "写入 authorized_keys 失败。"
            added=$((added + 1))
        fi
    done < "$valid_keys"
    set_mode 600 "$auth_file" || die "无法设置 authorized_keys 权限。"
    success "已导入 $added 条新公钥。"
}

print_github_empty_hint() {
    github_user="$1"
    error "未获取到 GitHub 公钥，请确认："
    printf '%s\n' "1. GitHub 用户名是否正确"
    printf '%s\n' "2. 该用户是否已在 GitHub Settings -> SSH and GPG keys 添加 Authentication Key"
    printf '%s\n' "3. 浏览器访问 https://github.com/$github_user.keys 是否能看到 ssh-ed25519 / ssh-rsa 开头的公钥"
    printf '%s\n' "如果你还没有本地公钥，可以先返回主菜单选择："
    printf '%s\n' "4. 生成新的本机 Ed25519 密钥"
    printf '%s\n' "然后把输出的公钥复制到 GitHub，再回来选择 1 导入。"
}

print_execution_summary() {
    github_user="$1"
    user=$(current_user)
    home=$(home_dir_for_user "$user")
    printf '%s\n' "当前用户: $user"
    printf '%s\n' "HOME: $home"
    if [ -n "$github_user" ]; then
        printf '%s\n' "GitHub 用户名: $github_user"
    fi
    printf '%s\n' "将写入: $home/.ssh/authorized_keys"
    printf '%s\n' "将修改: $SSH_CONFIG"
    printf '%s\n' "将禁用密码登录: 是"
    printf '%s\n' "将保留 root 密钥登录: PermitRootLogin prohibit-password"
}

prepare_local_ssh_dir() {
    user=$(current_user)
    uid=$(current_uid)
    home=$(home_dir_for_user "$user")
    [ -n "$home" ] || die "无法确定当前用户 HOME。"
    [ "$home" != "/" ] || die "当前用户 HOME 异常。"
    ! is_symlink_path "$home" || die "当前用户 HOME 不能是 symlink。"
    [ -d "$home" ] || die "当前用户 HOME 不存在: $home"
    home_owner=$(owner_uid "$home")
    if [ -n "$home_owner" ] && [ "$home_owner" != "$uid" ]; then
        die "当前用户 HOME owner 异常。"
    fi

    LOCAL_SSH_DIR="$home/.ssh"
    ! is_symlink_path "$LOCAL_SSH_DIR" || die ".ssh 不能是 symlink。"
    if [ -e "$LOCAL_SSH_DIR" ] && [ ! -d "$LOCAL_SSH_DIR" ]; then
        die ".ssh 不是目录。"
    fi
    if [ ! -d "$LOCAL_SSH_DIR" ]; then
        mkdir "$LOCAL_SSH_DIR" || die "无法创建 ~/.ssh。"
    fi
    set_mode 700 "$LOCAL_SSH_DIR" || die "无法设置 ~/.ssh 权限。"
    set_owner "$LOCAL_SSH_DIR" "$user" || die "无法设置 ~/.ssh owner。"
}

print_public_key_block() {
    public_file="$1"
    title="$2"
    [ -f "$public_file" ] || die "公钥文件不存在: $public_file"
    print_blank
    print_section_title "$title"
    cat "$public_file"
    print_section_end
}

print_private_key_block() {
    private_file="$1"
    [ -f "$private_file" ] || die "私钥文件不存在: $private_file"
    print_blank
    print_section_title "请复制保存以下私钥"
    cat "$private_file"
    print_section_title "私钥结束"
}

maybe_show_private_key_file() {
    private_file="$1"
    ask_prompt "是否显示私钥内容？输入 SHOW 继续:" || return 0
    if [ "$ASK_REPLY" = "SHOW" ]; then
        print_private_key_block "$private_file"
    fi
    return 0
}

show_local_keys() {
    user=$(current_user)
    home=$(home_dir_for_user "$user")
    ssh_dir="$home/.ssh"
    found=0
    private_found=0

    print_blank
    print_section_title "查看本机已有 SSH 密钥"
    printf '%s\n' "[说明]"
    printf '%s\n' "本机指当前运行脚本的服务器。"
    printf '%s\n\n' "私钥不要上传 GitHub，不要发给别人；FinalShell 导入的是私钥文件。"

    printf '%s\n' "[密钥文件]"
    for name in id_ed25519 id_ed25519.pub id_rsa id_rsa.pub; do
        file="$ssh_dir/$name"
        if [ -f "$file" ]; then
            found=1
            printf '%s\n' "存在: $file"
        else
            printf '%s\n' "不存在: $file"
        fi
    done

    for pub in "$ssh_dir/id_ed25519.pub" "$ssh_dir/id_rsa.pub"; do
        if [ -f "$pub" ]; then
            print_blank
            print_section_title "本机公钥信息"
            printf '%s\n' "公钥文件: $pub"
            cat "$pub"
            print_section_end
        fi
    done

    for private in "$ssh_dir/id_ed25519" "$ssh_dir/id_rsa"; do
        if [ -f "$private" ]; then
            private_found=1
            print_blank
            printf '%s\n' "私钥文件: $private"
            printf '%s\n' "注意：私钥不要上传 GitHub，不要发给别人。"
            printf '%s\n' "FinalShell 导入的是私钥文件。"
        fi
    done

    if [ "$found" -eq 0 ]; then
        warn "未发现常见 SSH 密钥，可选择菜单 4 生成新的 Ed25519 密钥。"
    fi

    if [ "$private_found" -eq 1 ]; then
        ask_prompt "是否显示私钥内容？输入 SHOW 继续:" || return 0
        if [ "$ASK_REPLY" = "SHOW" ]; then
            for private in "$ssh_dir/id_ed25519" "$ssh_dir/id_rsa"; do
                [ -f "$private" ] || continue
                print_private_key_block "$private"
            done
        fi
    fi
}

backup_local_key_file() {
    file="$1"
    stamp="$2"
    if [ -f "$file" ]; then
        backup="$file.bak.$stamp"
        cp -p "$file" "$backup" || return 1
        success "已备份已有密钥: $backup"
    fi
}

generate_local_key_only() {
    print_blank
    print_section_title "生成新的本机 Ed25519 密钥"
    if ! command -v ssh-keygen >/dev/null 2>&1; then
        die "缺少 ssh-keygen，无法生成 SSH 密钥。"
    fi

    prepare_local_ssh_dir
    user=$(current_user)
    private="$LOCAL_SSH_DIR/id_ed25519"
    public="$private.pub"

    ! is_symlink_path "$private" || die "私钥文件不能是 symlink: $private"
    ! is_symlink_path "$public" || die "公钥文件不能是 symlink: $public"

    if [ -e "$private" ] || [ -e "$public" ]; then
        warn "已存在本机 Ed25519 密钥。"
        printf '%s\n' "私钥文件: $private"
        printf '%s\n' "公钥文件: $public"
        ask_prompt "确认覆盖？输入 YES 继续:" || return 1
        if [ "$ASK_REPLY" != "YES" ]; then
            warn "已取消生成，不覆盖已有密钥。"
            return 1
        fi
        stamp=$(timestamp)
        backup_local_key_file "$private" "$stamp" || die "备份已有私钥失败。"
        backup_local_key_file "$public" "$stamp" || die "备份已有公钥失败。"
        safe_rm_f "$private" || die "删除旧私钥失败。"
        safe_rm_f "$public" || die "删除旧公钥失败。"
    fi

    host=$(hostname 2>/dev/null || printf '%s' "server")
    info "正在生成本机 Ed25519 密钥..."
    ssh-keygen -t ed25519 -C "ssh-init-generated@$host" -f "$private" -N "" >/dev/null 2>&1 || die "生成 SSH 密钥失败。"
    set_mode 600 "$private" || die "无法设置私钥权限。"
    set_mode 644 "$public" || die "无法设置公钥权限。"
    set_owner "$private" "$user" || die "无法设置私钥 owner。"
    set_owner "$public" "$user" || die "无法设置公钥 owner。"
    success "本机 Ed25519 密钥已生成。"

    print_public_key_block "$public" "请复制以下公钥到 GitHub"
    info "私钥文件: $private"
    info "FinalShell 导入这个私钥文件。"
    info "GitHub 只能粘贴公钥，不能粘贴私钥。"
    info "GitHub 添加路径: Settings -> SSH and GPG keys -> New SSH key -> Authentication Key"
    info "如果你要复制私钥到本地，请执行菜单 3 并输入 SHOW 查看私钥。"
    maybe_show_private_key_file "$private"
}

confirm_yes() {
    prompt="$1"
    ask_prompt "$prompt" || return 1
    [ "$ASK_REPLY" = "yes" ]
}

github_mode() {
    github_user="$1"
    print_blank
    print_section_title "从 GitHub 导入公钥"
    if [ -z "$github_user" ]; then
        error "GitHub 用户名不能为空。"
        return 1
    fi
    if is_github_placeholder "$github_user"; then
        error "你输入的是示例占位符，请输入真实 GitHub 用户名。"
        return 1
    fi
    validate_github_username "$github_user" || {
        error "GitHub 用户名格式无效。"
        return 1
    }
    raw_file=$(make_tmp_file "github-keys")
    valid_file=$(make_tmp_file "valid-keys")
    fetch_rc=0
    fetch_github_keys "$github_user" "$raw_file" || fetch_rc=$?
    if [ "$fetch_rc" -eq 2 ]; then
        print_github_empty_hint "$github_user"
        return 1
    fi
    if [ "$fetch_rc" -ne 0 ]; then
        error "拉取 GitHub 公钥失败。"
        return 1
    fi
    count=$(filter_valid_keys "$raw_file" "$valid_file")
    if [ "$count" -le 0 ]; then
        print_github_empty_hint "$github_user"
        return 1
    fi
    success "已获取 $count 条有效公钥"
    print_execution_summary "$github_user"
    if [ "${SSH_INIT_ASSUME_YES:-0}" != "1" ]; then
        confirm_yes "确认执行？输入 yes 继续:" || return 1
    fi
    append_keys_to_authorized_keys "$valid_file"
    harden_ssh_config
    final_reminder
}

generate_ed25519_key_pair() {
    if ! command -v ssh-keygen >/dev/null 2>&1; then
        die "缺少 ssh-keygen，无法生成 SSH 密钥。"
    fi
    if [ -z "${TMP_DIR:-}" ]; then
        make_tmp_dir
    fi
    GENERATED_PRIVATE_KEY_FILE="$TMP_DIR/generated_ed25519"
    GENERATED_PUBLIC_KEY_FILE="$GENERATED_PRIVATE_KEY_FILE.pub"
    safe_rm_f "$GENERATED_PRIVATE_KEY_FILE" || return 1
    safe_rm_f "$GENERATED_PUBLIC_KEY_FILE" || return 1
    info "正在生成 Ed25519 密钥对..."
    ssh-keygen -q -t ed25519 -N "" -f "$GENERATED_PRIVATE_KEY_FILE" -C "ssh-init-generated" >/dev/null 2>&1 || die "生成 SSH 密钥失败。"
    chmod 600 "$GENERATED_PRIVATE_KEY_FILE" 2>/dev/null || true
    chmod 600 "$GENERATED_PUBLIC_KEY_FILE" 2>/dev/null || true
}

print_generated_public_key() {
    [ -f "$GENERATED_PUBLIC_KEY_FILE" ] || die "临时公钥不存在，无法打印。"
    print_public_key_block "$GENERATED_PUBLIC_KEY_FILE" "请复制以下公钥到 GitHub"
    info "公钥可以放 GitHub。"
    info "私钥必须保存到本地。"
    info "该公钥已自动写入当前用户 authorized_keys。"
    info "密码登录已禁用。"
}

print_generated_private_key() {
    [ -f "$GENERATED_PRIVATE_KEY_FILE" ] || die "临时私钥不存在，无法打印。"
    print_blank
    print_private_key_block "$GENERATED_PRIVATE_KEY_FILE"
    print_blank
    info "请把私钥复制保存到本地电脑。"
    info "Windows 可保存为 C:\\Users\\你的用户名\\.ssh\\id_ed25519_SERVER"
    info "Linux/macOS 可保存为 ~/.ssh/id_ed25519_SERVER"
    info "FinalShell 导入的是私钥，不是公钥。"
    safe_rm_f "$GENERATED_PRIVATE_KEY_FILE" || true
    safe_rm_f "$GENERATED_PUBLIC_KEY_FILE" || true
}

gen_mode() {
    print_blank
    print_section_title "在服务器生成 Ed25519 密钥"
    warn "此模式会在服务器临时生成私钥，并打印到终端。"
    warn "请只在可信服务器和可信终端使用。"
    warn "复制保存私钥后，服务器临时私钥会被删除。"
    if [ "${SSH_INIT_ASSUME_YES:-0}" != "1" ]; then
        confirm_yes "确认生成？输入 yes 继续:" || return 1
    fi
    valid_file=$(make_tmp_file "valid-keys")
    generate_ed25519_key_pair
    count=$(filter_valid_keys "$GENERATED_PUBLIC_KEY_FILE" "$valid_file")
    [ "$count" -gt 0 ] || die "生成的公钥格式无效。"
    append_keys_to_authorized_keys "$valid_file"
    harden_ssh_config
    print_generated_public_key
    print_generated_private_key
    final_reminder
}

ensure_run_sshd_dir() {
    [ -n "$RUN_SSHD_DIR" ] || return 1
    if [ -L "$RUN_SSHD_DIR" ]; then
        return 1
    fi
    if [ ! -d "$RUN_SSHD_DIR" ]; then
        mkdir -p "$RUN_SSHD_DIR" || return 1
    fi
    chmod 755 "$RUN_SSHD_DIR" || return 1
}

find_sshd_bin() {
    if command -v sshd >/dev/null 2>&1; then
        command -v sshd
        return 0
    fi
    if [ -x /usr/sbin/sshd ]; then
        printf '%s\n' /usr/sbin/sshd
        return 0
    fi
    return 1
}

validate_sshd_config() {
    ensure_run_sshd_dir || return 1
    sshd_bin=$(find_sshd_bin 2>/dev/null || true)
    [ -n "$sshd_bin" ] || return 1
    "$sshd_bin" -t
}

restart_ssh_service() {
    ensure_run_sshd_dir || return 1
    if command -v systemctl >/dev/null 2>&1; then
        systemctl restart ssh >/dev/null 2>&1 && return 0
        systemctl restart sshd >/dev/null 2>&1 && return 0
    fi
    if command -v service >/dev/null 2>&1; then
        service ssh restart >/dev/null 2>&1 && return 0
        service sshd restart >/dev/null 2>&1 && return 0
    fi
    if command -v rc-service >/dev/null 2>&1; then
        rc-service ssh restart >/dev/null 2>&1 && return 0
        rc-service sshd restart >/dev/null 2>&1 && return 0
    fi
    return 1
}

write_hardened_sshd_config() {
    input="$1"
    output="$2"
    {
        printf '%s\n' "PubkeyAuthentication yes"
        printf '%s\n' "PasswordAuthentication no"
        printf '%s\n' "ChallengeResponseAuthentication no"
        printf '%s\n' "KbdInteractiveAuthentication no"
        printf '%s\n' "PermitEmptyPasswords no"
        printf '%s\n' "PermitRootLogin prohibit-password"
        printf '\n'
        awk '
            /^[[:space:]]*#/ { print; next }
            {
                key = tolower($1)
                if (key == "pubkeyauthentication" ||
                    key == "passwordauthentication" ||
                    key == "challengeresponseauthentication" ||
                    key == "kbdinteractiveauthentication" ||
                    key == "permitemptypasswords" ||
                    key == "permitrootlogin") {
                    next
                }
                print
            }
        ' "$input"
    } > "$output"
}

restore_sshd_backup() {
    backup="$1"
    [ -n "$backup" ] || return 1
    [ -f "$backup" ] || return 1
    cp -p "$backup" "$SSH_CONFIG"
}

harden_ssh_config() {
    require_root
    [ -f "$SSH_CONFIG" ] || die "找不到 SSH 配置文件: $SSH_CONFIG"
    backup="$SSH_CONFIG.bak.$(timestamp)"
    tmp_file=$(make_tmp_file "sshd_config")
    info "正在修改 sshd_config..."
    cp -p "$SSH_CONFIG" "$backup" || die "备份 sshd_config 失败。"
    success "已备份 sshd_config: $backup"
    write_hardened_sshd_config "$SSH_CONFIG" "$tmp_file" || die "生成 SSH 配置失败。"
    mv "$tmp_file" "$SSH_CONFIG" || die "写入 SSH 配置失败。"

    if ! validate_sshd_config; then
        restore_sshd_backup "$backup" || true
        die "sshd -t 校验失败，已恢复备份。"
    fi
    success "SSH 配置校验通过"

    if ! restart_ssh_service; then
        warn "SSH 服务重启失败，正在恢复备份..."
        restore_sshd_backup "$backup" || true
        restart_ssh_service >/dev/null 2>&1 || true
        die "SSH 服务重启失败，已尝试恢复备份。请通过 VNC/Console 检查。"
    fi
    success "SSH 服务已重启"
    info "PermitRootLogin prohibit-password 表示禁止 root 密码登录，但允许 root 密钥登录。"
}

current_auth_file() {
    user=$(current_user)
    home=$(home_dir_for_user "$user")
    printf '%s\n' "$home/.ssh/authorized_keys"
}

latest_matching_file() {
    pattern="$1"
    latest=""
    latest_base=""
    # shellcheck disable=SC2086
    for file in $pattern; do
        [ -f "$file" ] || continue
        base=${file##*/}
        if [ -z "$latest_base" ] || awk -v a="$base" -v b="$latest_base" 'BEGIN { exit (a > b) ? 0 : 1 }'; then
            latest="$file"
            latest_base="$base"
        fi
    done
    [ -n "$latest" ] || return 1
    printf '%s\n' "$latest"
}

latest_sshd_backup() {
    latest_matching_file "$SSH_CONFIG.bak.*"
}

latest_authorized_keys_backup() {
    auth_file=$(current_auth_file)
    latest_matching_file "$auth_file.bak.*"
}

list_matching_files_reverse() {
    pattern="$1"
    # shellcheck disable=SC2086
    for file in $pattern; do
        [ -f "$file" ] || continue
        printf '%s\n' "$file"
    done | sort -r
}

list_backups() {
    printf '%s\n' "[说明]"
    printf '%s\n' "恢复最新备份表示恢复到脚本上次修改前的状态。"
    printf '%s\n' "authorized_keys 恢复不是清空，而是恢复备份文件内容。"
    printf '%s\n\n' "authorized_keys 恢复后仍可能存在已有公钥，这是正常现象。"

    printf '%s\n' "[可用 sshd_config 备份]"
    files=$(list_matching_files_reverse "$SSH_CONFIG.bak.*")
    if [ -n "$files" ]; then
        printf '%s\n' "$files" | awk '{print NR ") " $0}'
    else
        printf '%s\n' "(无)"
    fi
    print_blank

    auth_file=$(current_auth_file)
    printf '%s\n' "[可用 authorized_keys 备份]"
    files=$(list_matching_files_reverse "$auth_file.bak.*")
    if [ -n "$files" ]; then
        printf '%s\n' "$files" | awk '{print NR ") " $0}'
    else
        printf '%s\n' "(无)"
    fi
    print_blank
}

show_effective_ssh_config() {
    if command -v sshd >/dev/null 2>&1; then
        sshd -T 2>/dev/null | grep -Ei '^(port|permitrootlogin|pubkeyauthentication|passwordauthentication|kbdinteractiveauthentication|challengeresponseauthentication|permitemptypasswords)' || true
    elif [ -x /usr/sbin/sshd ]; then
        /usr/sbin/sshd -T 2>/dev/null | grep -Ei '^(port|permitrootlogin|pubkeyauthentication|passwordauthentication|kbdinteractiveauthentication|challengeresponseauthentication|permitemptypasswords)' || true
    fi
}

get_effective_sshd_value() {
    key="$1"
    show_effective_ssh_config | awk -v k="$key" 'tolower($1) == tolower(k) { print $2; exit }'
}

show_authorized_keys_summary() {
    auth_file="$1"
    info "authorized_keys 路径: $auth_file"
    if [ -f "$auth_file" ]; then
        # shellcheck disable=SC2012
        perms=$(ls -l "$auth_file" | awk '{print $1}')
        lines=$(wc -l < "$auth_file" | awk '{print $1}')
        info "authorized_keys 权限: $perms"
        info "authorized_keys 行数: $lines"
    else
        info "authorized_keys 不存在"
    fi
}

restore_sshd_config_from_backup() {
    backup="$1"
    [ -f "$backup" ] || {
        error "没有找到 sshd_config 备份。"
        return 1
    }
    require_root
    before="$SSH_CONFIG.before-restore.$(timestamp)"
    cp -p "$SSH_CONFIG" "$before" || return 1
    if ! cp -p "$backup" "$SSH_CONFIG"; then
        cp -p "$before" "$SSH_CONFIG" || true
        return 1
    fi
    if ! validate_sshd_config; then
        cp -p "$before" "$SSH_CONFIG" || true
        error "恢复后的 sshd_config 未通过 sshd -t，已还原当前配置。"
        return 1
    fi
    if ! restart_ssh_service; then
        cp -p "$before" "$SSH_CONFIG" || true
        restart_ssh_service >/dev/null 2>&1 || true
        error "SSH 服务重启失败，已还原当前配置。"
        return 1
    fi
    success "sshd_config 已恢复。"
    success "SSH 服务已重启。"
    show_effective_ssh_config
    password_auth=$(get_effective_sshd_value "passwordauthentication")
    permit_root=$(get_effective_sshd_value "permitrootlogin")
    [ -n "$password_auth" ] && info "当前 PasswordAuthentication: $password_auth"
    [ -n "$permit_root" ] && info "当前 PermitRootLogin: $permit_root"
    return 0
}

restore_authorized_keys_from_backup() {
    backup="$1"
    [ -f "$backup" ] || {
        error "没有找到 authorized_keys 备份。"
        return 1
    }
    auth_file=$(current_auth_file)
    user=$(current_user)
    ssh_dir=$(dirname "$auth_file")
    ! is_symlink_path "$ssh_dir" || {
        error ".ssh 不能是 symlink。"
        return 1
    }
    ! is_symlink_path "$auth_file" || {
        error "authorized_keys 不能是 symlink。"
        return 1
    }
    mkdir -p "$ssh_dir" || return 1
    if [ -e "$auth_file" ] && [ ! -f "$auth_file" ]; then
        error "authorized_keys 不是普通文件。"
        return 1
    fi
    set_mode 700 "$ssh_dir" || return 1
    set_owner "$ssh_dir" "$user" || return 1
    cp -p "$backup" "$auth_file" || return 1
    set_mode 600 "$auth_file" || return 1
    set_owner "$auth_file" "$user" || return 1
    success "authorized_keys 已恢复。"
    show_authorized_keys_summary "$auth_file"
    info "authorized_keys 已恢复为备份时的内容；这不是清空 authorized_keys；如果仍有公钥行，说明备份中本来就有这些公钥。"
}

clear_authorized_keys() {
    auth_file=$(current_auth_file)
    user=$(current_user)
    ssh_dir=$(dirname "$auth_file")
    ! is_symlink_path "$ssh_dir" || {
        error ".ssh 不能是 symlink。"
        return 1
    }
    ! is_symlink_path "$auth_file" || {
        error "authorized_keys 不能是 symlink。"
        return 1
    }
    mkdir -p "$ssh_dir" || return 1
    if [ -e "$auth_file" ] && [ ! -f "$auth_file" ]; then
        error "authorized_keys 不是普通文件。"
        return 1
    fi
    set_mode 700 "$ssh_dir" || return 1
    set_owner "$ssh_dir" "$user" || return 1
    backup="$auth_file.before-clear.$(timestamp)"
    if [ -f "$auth_file" ]; then
        cp -p "$auth_file" "$backup" || return 1
        success "已备份当前 authorized_keys: $backup"
    else
        : > "$backup" || return 1
        set_mode 600 "$backup" || return 1
        set_owner "$backup" "$user" || return 1
        success "已创建 authorized_keys 空备份: $backup"
        : > "$auth_file" || return 1
    fi
    : > "$auth_file" || return 1
    set_mode 600 "$auth_file" || return 1
    set_owner "$auth_file" "$user" || return 1
    success "authorized_keys 已清空。"
    show_authorized_keys_summary "$auth_file"
}

clear_authorized_keys_interactive() {
    warn "这会删除当前用户所有 SSH 公钥，可能导致无法用密钥登录。"
    ask_prompt "确认清空？输入 YES 继续:" || return 1
    if [ "$ASK_REPLY" != "YES" ]; then
        warn "已取消清空 authorized_keys。"
        return 1
    fi
    clear_authorized_keys
}

restore_menu() {
    print_blank
    print_section_title "恢复 SSH 配置备份"
    list_backups
    printf '%s\n' "[操作]"
    cat <<'EOF'
1) 恢复最新 sshd_config 备份
2) 恢复最新 authorized_keys 备份
3) 同时恢复最新 sshd_config 和 authorized_keys
4) 查看当前 SSH 登录配置
5) 清空当前用户 authorized_keys（危险）
6) 返回主菜单
EOF
    ask_prompt "请选择 [1-6]:" || return 1
    choice=$ASK_REPLY
    case "$choice" in
        1)
            backup=$(latest_sshd_backup 2>/dev/null || true)
            restore_sshd_config_from_backup "$backup" && info "请新开终端测试 SSH 登录是否恢复正常。"
            ;;
        2)
            backup=$(latest_authorized_keys_backup 2>/dev/null || true)
            restore_authorized_keys_from_backup "$backup" && info "请新开终端测试 SSH 登录是否恢复正常。"
            ;;
        3)
            ssh_backup=$(latest_sshd_backup 2>/dev/null || true)
            auth_backup=$(latest_authorized_keys_backup 2>/dev/null || true)
            restore_sshd_config_from_backup "$ssh_backup" && restore_authorized_keys_from_backup "$auth_backup" && info "请新开终端测试 SSH 登录是否恢复正常。"
            ;;
        4)
            show_status
            ;;
        5)
            clear_authorized_keys_interactive && info "请新开终端测试 SSH 登录是否符合预期。"
            ;;
        6)
            return 0
            ;;
        *)
            error "无效选择。"
            return 1
            ;;
    esac
}

show_status() {
    user=$(current_user)
    home=$(home_dir_for_user "$user")
    auth_file="$home/.ssh/authorized_keys"
    print_blank
    print_section_title "当前 SSH 登录配置"
    printf '%s\n' "[用户信息]"
    printf '%s\n' "当前用户: $user"
    printf '%s\n' "HOME: $home"
    print_blank

    printf '%s\n' "[密钥文件]"
    if [ -d "$home/.ssh" ]; then
        # shellcheck disable=SC2012
        printf '%s\n' ".ssh 权限: $(ls -ld "$home/.ssh" | awk '{print $1}')"
    else
        printf '%s\n' ".ssh 不存在"
    fi
    if [ -f "$auth_file" ]; then
        # shellcheck disable=SC2012
        printf '%s\n' "authorized_keys: 存在"
        # shellcheck disable=SC2012
        printf '%s\n' "authorized_keys 权限: $(ls -l "$auth_file" | awk '{print $1}')"
        printf '%s\n' "authorized_keys 行数: $(wc -l < "$auth_file" | awk '{print $1}')"
    else
        printf '%s\n' "authorized_keys 不存在"
    fi
    print_blank

    printf '%s\n' "[SSH 生效配置]"
    show_effective_ssh_config
    print_blank

    printf '%s\n' "[监听端口]"
    if command -v ss >/dev/null 2>&1; then
        ss -ltnp 2>/dev/null | grep sshd || true
    elif command -v netstat >/dev/null 2>&1; then
        netstat -ltnp 2>/dev/null | grep sshd || true
    fi
    print_section_end
}

show_menu() {
    print_blank
    print_section_title "SSH 密钥登录配置工具"
    cat <<'MENU'
  1. 从 GitHub 导入公钥并禁用密码登录
  2. 在服务器生成 Ed25519 密钥并配置登录
  3. 查看本机已有 SSH 密钥
  4. 生成新的本机 Ed25519 密钥
  5. 恢复 SSH 配置备份
  6. 查看当前 SSH 登录配置
  7. 退出
MENU
    print_section_end
}

interactive_main() {
    while :; do
        show_menu
        ask_prompt "请选择 [1-7]:" || return 0
        choice=$ASK_REPLY
        case "$choice" in
            1)
                require_root
                ask_prompt "请输入 GitHub 用户名:" || return 0
                github_user=$ASK_REPLY
                if github_mode "$github_user"; then
                    return 0
                fi
                ;;
            2)
                require_root
                if gen_mode; then
                    return 0
                fi
                ;;
            3)
                show_local_keys
                ;;
            4)
                generate_local_key_only
                ;;
            5)
                require_root
                restore_menu || true
                ;;
            6)
                show_status
                ;;
            7)
                info "已退出。"
                return 0
                ;;
            *)
                error "无效选择。"
                ;;
        esac
    done
}

final_reminder() {
    print_blank
    print_section_title "配置完成"
    cat <<'EOF'
请不要立即关闭当前终端。
请新开一个终端测试密钥登录是否成功。
确认可以用私钥登录后，再关闭当前窗口。
如果无法登录，请通过云厂商 VNC/Console 恢复 SSH 配置。
EOF
    print_section_end
}

usage() {
    cat <<'EOF'
用法:
  sh init.sh
  sh init.sh github GitHubUser
  sh init.sh gen
  sh init.sh keys
  sh init.sh keygen
  sh init.sh restore
  sh init.sh status
EOF
}

parse_cli_args() {
    CLI_MODE=""
    CLI_GITHUB_USER=""
    if [ "$#" -eq 0 ]; then
        CLI_MODE="menu"
        return 0
    fi
    case "$1" in
        github)
            [ "$#" -eq 2 ] || return 1
            validate_github_username "$2" || return 1
            CLI_MODE="github"
            CLI_GITHUB_USER="$2"
            ;;
        gen)
            [ "$#" -eq 1 ] || return 1
            CLI_MODE="gen"
            ;;
        keys)
            [ "$#" -eq 1 ] || return 1
            CLI_MODE="keys"
            ;;
        keygen)
            [ "$#" -eq 1 ] || return 1
            CLI_MODE="keygen"
            ;;
        restore)
            [ "$#" -eq 1 ] || return 1
            CLI_MODE="restore"
            ;;
        status)
            [ "$#" -eq 1 ] || return 1
            CLI_MODE="status"
            ;;
        -h|--help)
            CLI_MODE="help"
            ;;
        *)
            return 1
            ;;
    esac
    return 0
}

main() {
    parse_cli_args "$@" || {
        usage
        exit 1
    }
    if [ "$CLI_MODE" = "menu" ]; then
        interactive_main
        return 0
    fi
    case "$CLI_MODE" in
        github)
            require_root
            github_mode "$CLI_GITHUB_USER"
            ;;
        gen)
            require_root
            gen_mode
            ;;
        keys)
            show_local_keys
            ;;
        keygen)
            generate_local_key_only
            ;;
        restore)
            require_root
            restore_menu
            ;;
        status)
            show_status
            ;;
        help)
            usage
            ;;
    esac
}

if [ "${IKE_TEST_MODE:-0}" != "1" ]; then
    main "$@"
fi
