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
SSHD_CONFIG_WAS_IMMUTABLE=0
SSHD_CONFIG_TMP_FILE=""
SSH_KEYGEN_WARNED=0
SSHD_EFFECTIVE_KEYS_RE='^(pubkeyauthentication|passwordauthentication|kbdinteractiveauthentication|challengeresponseauthentication|permitemptypasswords|permitrootlogin|authenticationmethods) '
SSHD_SOURCE_GREP_RE='^[[:space:]]*(Include|PasswordAuthentication|KbdInteractiveAuthentication|ChallengeResponseAuthentication|PermitEmptyPasswords|PermitRootLogin|PubkeyAuthentication|AuthenticationMethods|Match)([[:space:]=]|$)'

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

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

is_immutable_file() {
    file="$1"
    [ -e "$file" ] || return 1
    command_exists lsattr || return 1
    attrs=$(lsattr "$file" 2>/dev/null | awk '{print $1; exit}' || true)
    case "$attrs" in
        *i*)
            return 0
            ;;
    esac
    return 1
}

unlock_immutable_if_needed() {
    file="$1"
    SSHD_CONFIG_WAS_IMMUTABLE=0
    [ -e "$file" ] || return 0
    if is_immutable_file "$file"; then
        SSHD_CONFIG_WAS_IMMUTABLE=1
        warn "检测到 sshd_config 被锁定，常见于 NAT VPS 或商家保护 SSH 端口转发场景。"
        warn "脚本只会修改密钥登录相关配置，不会修改 Port。"
        warn "完成后会恢复 immutable 锁定状态。"
        if ! command_exists chattr || ! chattr -i "$file"; then
            die "$file 被 immutable 锁定，且无法 chattr -i 解锁"
        fi
        warn "检测到 $file 被 immutable 锁定，已临时解锁"
    fi
}

relock_immutable_if_needed() {
    file="$1"
    if [ "${SSHD_CONFIG_WAS_IMMUTABLE:-0}" = "1" ]; then
        if command_exists chattr && chattr +i "$file"; then
            success "已恢复 $file immutable 锁定状态"
        else
            warn "恢复 $file immutable 锁定状态失败，请手动执行: chattr +i $file"
        fi
    fi
    SSHD_CONFIG_WAS_IMMUTABLE=0
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
    if [ -n "${SSHD_CONFIG_TMP_FILE:-}" ]; then
        case "$SSHD_CONFIG_TMP_FILE" in
            */.sshd_config.ssh-init.*|*/.*.ssh-init.*)
                rm -f "$SSHD_CONFIG_TMP_FILE"
                ;;
        esac
    fi
}

trap cleanup_tmp EXIT HUP INT TERM

timestamp() {
    date +%Y%m%d_%H%M%S
}

make_tmp_dir() {
    # This must run in the owning shell, before make_tmp_file is captured with $().
    if [ -n "${TMP_DIR:-}" ]; then
        [ -d "$TMP_DIR" ] && [ ! -L "$TMP_DIR" ] && [ -w "$TMP_DIR" ]
        return $?
    fi
    tmp_dir_umask=$(umask)
    umask 077
    if command -v mktemp >/dev/null 2>&1; then
        TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/ssh-init.XXXXXX" 2>/dev/null || true)
    fi
    if [ -z "$TMP_DIR" ]; then
        TMP_DIR="${TMPDIR:-/tmp}/ssh-init.$$"
        mkdir "$TMP_DIR" || {
            error "无法创建临时目录: $TMP_DIR"
            TMP_DIR=""
            umask "$tmp_dir_umask"
            return 1
        }
    fi
    tmp_dir_result=0
    chmod 700 "$TMP_DIR" 2>/dev/null || tmp_dir_result=1
    umask "$tmp_dir_umask"
    return "$tmp_dir_result"
}

make_tmp_file() (
    tmp_prefix="$1"
    case "$tmp_prefix" in
        ""|*[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-]*)
            error "无效的临时文件前缀。"
            return 1
            ;;
    esac
    if [ -z "${TMP_DIR:-}" ] || [ ! -d "$TMP_DIR" ] || [ -L "$TMP_DIR" ]; then
        error "临时目录未初始化或已失效，请先在父 shell 中调用 make_tmp_dir。"
        return 1
    fi
    umask 077
    tmp_path=""
    if command_exists mktemp; then
        tmp_path=$(mktemp "$TMP_DIR/$tmp_prefix.XXXXXX" 2>/dev/null || true)
    fi
    if [ -z "$tmp_path" ]; then
        tmp_index=0
        while [ "$tmp_index" -lt 1000 ]; do
            tmp_candidate="$TMP_DIR/$tmp_prefix.$$.$tmp_index"
            if (set -C; : > "$tmp_candidate") 2>/dev/null; then
                tmp_path="$tmp_candidate"
                break
            fi
            tmp_index=$((tmp_index + 1))
        done
    fi
    [ -n "$tmp_path" ] || return 1
    printf '%s\n' "$tmp_path"
)

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
    name_len=$(printf '%s' "$name" | wc -c | awk '{print $1}')
    [ "$name_len" -le 39 ] || return 1
    case "$name" in
        *--*)
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
    key_extra=$(printf '%s\n' "$line" | awk '{print $3}')

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

    if command_exists ssh-keygen; then
        tmp_key_file=$(make_tmp_file "public-key") || return 1
        if ! printf '%s %s\n' "$key_type" "$key_data" > "$tmp_key_file"; then
            safe_rm_f "$tmp_key_file" || true
            return 1
        fi
        if ! ssh-keygen -l -f "$tmp_key_file" >/dev/null 2>&1; then
            safe_rm_f "$tmp_key_file" || true
            return 1
        fi
        safe_rm_f "$tmp_key_file" || true
    else
        if [ "${SSH_KEYGEN_WARNED:-0}" != "1" ]; then
            warn "未找到 ssh-keygen，公钥格式仅使用基础规则校验。"
            SSH_KEYGEN_WARNED=1
        fi
    fi

    if [ -n "$key_extra" ]; then
        printf '%s\n' "$line"
    else
        printf '%s %s\n' "$key_type" "$key_data"
    fi
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
    if command_exists curl; then
        curl -fsSL --connect-timeout 10 "$url" > "$output_file" || return 1
    elif command_exists wget; then
        if wget --help 2>&1 | grep -qE '(^|[[:space:]])--timeout'; then
            wget -qO- --timeout=10 "$url" > "$output_file" || return 1
        else
            wget -qO- -T 10 "$url" > "$output_file" || return 1
        fi
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
            if [ "$added" -eq 0 ] && [ -s "$auth_file" ]; then
                auth_last_byte=$(tail -c 1 "$auth_file") || die "无法检查 authorized_keys 末尾换行。"
                if [ -n "$auth_last_byte" ]; then
                    printf '\n' >> "$auth_file" || die "无法为 authorized_keys 补充末尾换行。"
                fi
            fi
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
    printf '%s\n' "4. 请确认你已经把公钥添加到 https://github.com/settings/keys"
    printf '%s\n' "5. 并且 Key type 选择 Authentication Key。"
    printf '%s\n' "如果你还没有本地公钥，可以先返回主菜单选择："
    printf '%s\n' "4. 生成新的本机 Ed25519 密钥"
    printf '%s\n' "然后把输出的公钥复制到 GitHub，再回来选择 1 导入。"
}

print_github_import_tutorial() {
    print_blank
    print_section_title "GitHub 公钥导入说明"
    cat <<'EOF'

本功能会从 GitHub 拉取你的公开 SSH 公钥，并写入当前用户的：
~/.ssh/authorized_keys

操作前，请确保你已经在 GitHub 账户中添加了 SSH 公钥：

1. 打开 GitHub SSH Keys 设置页面：
   https://github.com/settings/keys

2. 点击 New SSH key 或 Add SSH key

3. Key type 选择：
   Authentication Key

4. Title 可随便填写，例如：
   VPS
   Home Laptop
   ssh-init

5. Key 输入框中粘贴“公钥”，不是私钥。
   公钥通常长这样：
   ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA... user@device

6. 不要粘贴这种私钥：
   -----BEGIN OPENSSH PRIVATE KEY-----
   ...
   -----END OPENSSH PRIVATE KEY-----

7. 添加完成后，GitHub 会公开你的公钥地址：
   https://github.com/你的用户名.keys

如果你还没有公钥，可以先返回主菜单，选择：
4. 生成新的本机 Ed25519 密钥

然后复制输出的公钥到 GitHub，再回来选择 1 导入。

EOF
    print_section_end
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
    print_blank || return 1
    print_section_title "$title" || return 1
    cat "$public_file" || return 1
    print_section_end
}

print_private_key_block() {
    private_file="$1"
    [ -f "$private_file" ] || die "私钥文件不存在: $private_file"
    print_blank || return 1
    print_section_title "请复制保存以下私钥" || return 1
    cat "$private_file" || return 1
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
    raw_file=$(make_tmp_file "github-keys") || return 1
    valid_file=$(make_tmp_file "valid-keys") || return 1
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
    count=$(filter_valid_keys "$raw_file" "$valid_file") || return 1
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
    chmod 644 "$GENERATED_PUBLIC_KEY_FILE" 2>/dev/null || true
}

print_generated_public_key() {
    [ -f "$GENERATED_PUBLIC_KEY_FILE" ] || die "临时公钥不存在，无法打印。"
    print_public_key_block "$GENERATED_PUBLIC_KEY_FILE" "请复制以下公钥到 GitHub" || return 1
    info "公钥可以放 GitHub。" || return 1
    info "私钥必须保存到本地。" || return 1
    info "确认私钥已保存后，才会写入 authorized_keys 并禁用密码登录。"
}

print_generated_private_key() {
    [ -f "$GENERATED_PRIVATE_KEY_FILE" ] || die "临时私钥不存在，无法打印。"
    print_blank || return 1
    print_private_key_block "$GENERATED_PRIVATE_KEY_FILE" || return 1
    print_blank || return 1
    info "请把私钥复制保存到本地电脑。" || return 1
    info "Windows 可保存为 C:\\Users\\你的用户名\\.ssh\\id_ed25519_SERVER" || return 1
    info "Linux/macOS 可保存为 ~/.ssh/id_ed25519_SERVER" || return 1
    info "FinalShell 导入的是私钥，不是公钥。"
}

remove_generated_key_pair() {
    safe_rm_f "$GENERATED_PRIVATE_KEY_FILE" || return 1
    safe_rm_f "$GENERATED_PUBLIC_KEY_FILE" || return 1
}

gen_mode() {
    print_blank
    print_section_title "在服务器生成 Ed25519 密钥"
    warn "此模式会在服务器临时生成私钥，并打印到终端。"
    warn "请只在可信服务器和可信终端使用。"
    warn "必须复制保存私钥并输入 SAVED 确认，才会配置密钥登录和禁用密码登录。"
    warn "确认保存或取消后，服务器临时私钥都会被删除。"
    if [ "${SSH_INIT_ASSUME_YES:-0}" != "1" ]; then
        confirm_yes "确认生成？输入 yes 继续:" || return 1
    fi
    generate_ed25519_key_pair || return 1
    valid_file=$(make_tmp_file "valid-keys") || die "无法创建生成公钥的校验文件。"
    count=$(filter_valid_keys "$GENERATED_PUBLIC_KEY_FILE" "$valid_file") || die "校验生成的公钥失败。"
    [ "$count" -gt 0 ] || die "生成的公钥格式无效。"
    if ! print_generated_public_key || ! print_generated_private_key; then
        remove_generated_key_pair || die "删除临时密钥失败。"
        error "无法完整显示密钥，已取消；未写入 authorized_keys，也未修改 SSH 登录配置。"
        return 1
    fi
    if ! ask_prompt "确认私钥已保存到本地？输入 SAVED 才会写入 authorized_keys 并禁用密码登录（其他输入或 EOF 取消）:" ||
        [ "$ASK_REPLY" != "SAVED" ]; then
        remove_generated_key_pair || die "删除临时密钥失败。"
        warn "未确认私钥已保存，已取消；未写入 authorized_keys，也未修改 SSH 登录配置。"
        return 1
    fi
    remove_generated_key_pair || die "删除临时密钥失败。"
    append_keys_to_authorized_keys "$valid_file"
    harden_ssh_config
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

validate_sshd_config_file() {
    config_file="$1"
    ensure_run_sshd_dir || return 1
    sshd_bin=$(find_sshd_bin 2>/dev/null || true)
    [ -n "$sshd_bin" ] || return 1
    "$sshd_bin" -t -f "$config_file"
}

validate_sshd_config() {
    validate_sshd_config_file "$SSH_CONFIG"
}

effective_sshd_settings_check() {
    config_file="$1"
    failures_file="${2:-}"
    if [ -n "$failures_file" ]; then
        : > "$failures_file" || return 1
    fi
    if ! ensure_run_sshd_dir; then
        if [ -n "$failures_file" ]; then
            printf '%s\n' "__SSHD_T_FAILED__" > "$failures_file" || true
        fi
        return 1
    fi
    sshd_bin=$(find_sshd_bin 2>/dev/null || true)
    if [ -z "$sshd_bin" ]; then
        if [ -n "$failures_file" ]; then
            printf '%s\n' "__SSHD_T_FAILED__" > "$failures_file" || true
        fi
        return 1
    fi
    effective_file=$(make_tmp_file "sshd-effective") || return 1
    if ! "$sshd_bin" -T -f "$config_file" > "$effective_file" 2>/dev/null; then
        if [ -n "$failures_file" ]; then
            printf '%s\n' "__SSHD_T_FAILED__" > "$failures_file" || true
        fi
        return 1
    fi
    detected_failures=$(make_tmp_file "sshd-effective-failures") || return 1
    awk '
        {
            key = tolower($1)
            value = tolower($2)
            seen[key] = 1
            values[key] = value
        }
        END {
            if (seen["pubkeyauthentication"] && values["pubkeyauthentication"] != "yes")
                print "  - pubkeyauthentication: 期望 yes，实际 " values["pubkeyauthentication"]
            if (seen["passwordauthentication"] && values["passwordauthentication"] != "no")
                print "  - passwordauthentication: 期望 no，实际 " values["passwordauthentication"]
            if (seen["kbdinteractiveauthentication"] && values["kbdinteractiveauthentication"] != "no")
                print "  - kbdinteractiveauthentication: 期望 no，实际 " values["kbdinteractiveauthentication"]
            if (seen["permitemptypasswords"] && values["permitemptypasswords"] != "no")
                print "  - permitemptypasswords: 期望 no，实际 " values["permitemptypasswords"]
            if (seen["challengeresponseauthentication"] && values["challengeresponseauthentication"] != "no")
                print "  - challengeresponseauthentication: 期望 no，实际 " values["challengeresponseauthentication"]
            if (seen["permitrootlogin"] &&
                values["permitrootlogin"] != "prohibit-password" &&
                values["permitrootlogin"] != "without-password")
                print "  - permitrootlogin: 期望 prohibit-password/without-password，实际 " values["permitrootlogin"]
        }
    ' "$effective_file" > "$detected_failures"
    if [ -s "$detected_failures" ]; then
        if [ -n "$failures_file" ]; then
            cat "$detected_failures" > "$failures_file" || true
        fi
        return 1
    fi
    return 0
}

print_effective_sshd_settings_failure() {
    failures_file="$1"
    if [ -f "$failures_file" ] && grep -qx "__SSHD_T_FAILED__" "$failures_file"; then
        error "sshd -T 无法读取最终配置"
        return 0
    fi
    error "配置语法通过，但最终生效配置不符合预期："
    if [ -f "$failures_file" ] && [ -s "$failures_file" ]; then
        cat "$failures_file" >&2
    else
        printf '%s\n' "  - 未能解析最终生效配置，请手动运行 sshd -T 排查。" >&2
    fi
    print_blank >&2
    printf '%s\n' "可能原因：" >&2
    printf '%s\n' "  - /etc/ssh/sshd_config.d/*.conf 中有更早加载的配置" >&2
    printf '%s\n' "  - 也可能是 Match 块根据用户、地址或组覆盖了全局配置。" >&2
    printf '%s\n' "  - 当前 OpenSSH 默认值仍允许密码登录" >&2
}

ssh_init_dirname() {
    path="$1"
    dir=${path%/*}
    if [ "$dir" = "$path" ]; then
        printf '%s\n' "."
    elif [ -n "$dir" ]; then
        printf '%s\n' "$dir"
    else
        printf '%s\n' "/"
    fi
}

has_path_glob() {
    case "$1" in
        *\**|*\?*|*\[*)
            return 0
            ;;
    esac
    return 1
}

list_path_matches() (
    # Disable field splitting, not pathname expansion. This also handles globs
    # in parent directories and symlinked configuration files without eval.
    pattern="$1"
    IFS=''
    set +f
    # shellcheck disable=SC2086
    set -- $pattern
    for matched_path do
        [ -e "$matched_path" ] || [ -L "$matched_path" ] || continue
        [ -f "$matched_path" ] && [ -r "$matched_path" ] || return 1
        printf '%s\n' "$matched_path" || return 1
    done
)

list_resolved_include_patterns() {
    pattern="$1"
    case "$pattern" in
        /*)
            printf '%s\n' "$pattern"
            ;;
        \~*)
            # Do not silently skip a syntax whose expansion we cannot verify.
            return 1
            ;;
        *)
            # OpenSSH resolves all relative Include paths against /etc/ssh,
            # not against the directory of the including file.
            printf '%s\n' "/etc/ssh/$pattern"
            ;;
    esac
}

list_include_matches() (
    pattern="$1"
    [ -n "$pattern" ] || return 1
    resolved=$(list_resolved_include_patterns "$pattern" "${2:-/etc/ssh}") || return 1
    list_path_matches "$resolved"
)

config_file_scan_records() (
    scan_file="$1"
    [ -f "$scan_file" ] && [ -r "$scan_file" ] || return 1
    awk -v in_match="${2:-0}" '
        # Parse quoted arguments without executing shell syntax. Records use
        # tabs as separators, so embedded control characters are rejected.
        function tokenize(line, parts, i, c, quote, token, started, n) {
            for (i in parts) delete parts[i]
            quote = ""
            token = ""
            started = 0
            n = 0
            for (i = 1; i <= length(line); i++) {
                c = substr(line, i, 1)
                if (c == "\\") {
                    if (++i > length(line)) return -1
                    token = token substr(line, i, 1)
                    started = 1
                } else if (quote != "") {
                    if (c == quote) quote = ""
                    else token = token c
                } else if (c == "\"" || c == sprintf("%c", 39)) {
                    quote = c
                    started = 1
                } else if (c == "#" && !started) {
                    break
                } else if (c ~ /[[:space:]]/) {
                    if (started) parts[++n] = token
                    token = ""
                    started = 0
                } else {
                    token = token c
                    started = 1
                }
            }
            if (quote != "") return -1
            if (started) parts[++n] = token
            return n
        }
        {
            line = $0
            sub(/\r$/, "", line)
            sub(/^[[:space:]]*/, "", line)
            # OpenSSH separates the keyword from its arguments with whitespace
            # or one optional equals sign. Equals signs inside args are data.
            keyword_end = match(line, /[[:space:]=]/)
            if (keyword_end > 0) {
                keyword = substr(line, 1, keyword_end - 1)
                arguments = substr(line, keyword_end)
                sub(/^[[:space:]]*=[[:space:]]*/, " ", arguments)
                line = keyword " " arguments
            }
            n = tokenize(line, parts)
            if (n < 0) exit 2
            if (n == 0) next
            key = tolower(parts[1])
            if (key == "match") {
                if (n < 2) exit 2
                in_match = 1
                next
            }
            if (key == "include") {
                if (n < 2) exit 2
                for (i = 2; i <= n; i++) {
                    if (parts[i] == "" || parts[i] ~ /[\t\r\n]/) exit 2
                    print "include\t" in_match "\t" NR "\t" parts[i]
                }
                next
            }
            value = ""
            for (i = 2; i <= n; i++)
                value = value (i == 2 ? "" : " ") parts[i]
            if (key == "authenticationmethods") {
                if (n < 2) exit 2
                lower = tolower(value)
                if (lower ~ /(^|[,[:space:]])password([,[:space:]]|$)/ ||
                    lower ~ /(^|[,[:space:]])keyboard-interactive([,:[:space:]]|$)/)
                    print "authentication\t" in_match "\t" NR "\tAuthenticationMethods " value
            }
            value = tolower(parts[2])
            if (in_match &&
                ((key == "passwordauthentication" && value == "yes") ||
                 (key == "kbdinteractiveauthentication" && value == "yes") ||
                 (key == "challengeresponseauthentication" && value == "yes") ||
                 (key == "pubkeyauthentication" && value == "no") ||
                 (key == "permitrootlogin" && value == "yes")))
                print "match\t" in_match "\t" NR "\t" parts[1] " " parts[2]
        }
    ' "$scan_file"
)

config_file_include_patterns() (
    records=$(config_file_scan_records "$1" "${3:-0}") || return 1
    printf '%s\n' "$records" | awk -F '\t' -v scope="${2:-global}" '
        $1 == "include" && (scope == "all" || $2 == "0") { print $4 }
    '
)

config_file_authentication_methods_risk() (
    records=$(config_file_scan_records "$1") || return 1
    printf '%s\n' "$records" | awk -F '\t' -v file="$1" '
        $1 == "authentication" { print file ":" $3 ": " $4; exit }
    '
)

config_file_match_override_risk() (
    records=$(config_file_scan_records "$1" "${2:-0}") || return 1
    printf '%s\n' "$records" | awk -F '\t' -v file="$1" '
        $1 == "match" { print file ":" $3 ": " $4; exit }
    '
)

scan_sshd_config_risk_file() (
    # Each recursive frame owns its variables and its unique record files.
    # A child inherits Match context, but cannot change its parent/siblings.
    scan_file="$1"
    scan_depth="$2"
    scan_kind="$3"
    scan_in_match="${4:-0}"
    if [ "$scan_depth" -gt 16 ]; then
        printf '%s\n' "$scan_file: Include 嵌套过深或存在循环，无法完整扫描。"
        return 2
    fi
    scan_records=$(make_tmp_file "sshd-scan-records") || {
        printf '%s\n' "$scan_file: 无法创建扫描临时文件。"
        return 2
    }
    if ! config_file_scan_records "$scan_file" "$scan_in_match" > "$scan_records"; then
        printf '%s\n' "$scan_file: 无法读取或解析 SSH 配置，已停止扫描。"
        return 2
    fi
    scan_tab=$(printf '\t')
    while IFS="$scan_tab" read -r record_kind record_match record_line record_value; do
        if [ "$record_kind" = "$scan_kind" ]; then
            printf '%s\n' "$scan_file:$record_line: $record_value"
            return 1
        fi
        [ "$record_kind" = "include" ] || continue
        scan_matches=$(make_tmp_file "sshd-include-matches") || {
            printf '%s\n' "$scan_file:$record_line: 无法创建 Include 扫描临时文件。"
            return 2
        }
        if ! list_include_matches "$record_value" > "$scan_matches"; then
            printf '%s\n' "$scan_file:$record_line: 无法可靠展开 Include $record_value"
            return 2
        fi
        while IFS= read -r scan_included || [ -n "$scan_included" ]; do
            if scan_sshd_config_risk_file "$scan_included" "$((scan_depth + 1))" "$scan_kind" "$record_match"; then
                :
            else
                return $?
            fi
        done < "$scan_matches"
    done < "$scan_records"
    return 0
)

scan_authentication_methods_risk_file() {
    scan_sshd_config_risk_file "$1" "$2" authentication "${3:-0}"
}

detect_authentication_methods_risk() {
    AUTHENTICATION_METHODS_RISK=""
    AUTHENTICATION_METHODS_SCAN_FAILED=0
    if ! make_tmp_dir; then
        AUTHENTICATION_METHODS_RISK="$1: 扫描临时目录不可用。"
        AUTHENTICATION_METHODS_SCAN_FAILED=1
        return 1
    fi
    if AUTHENTICATION_METHODS_RISK=$(scan_authentication_methods_risk_file "$1" 0); then
        return 0
    else
        [ "$?" -eq 1 ] || AUTHENTICATION_METHODS_SCAN_FAILED=1
        return 1
    fi
}

scan_match_override_risk_file() {
    scan_sshd_config_risk_file "$1" "$2" match "${3:-0}"
}

detect_match_override_risk() {
    MATCH_OVERRIDE_RISK=""
    MATCH_OVERRIDE_RISK_FOUND=0
    MATCH_OVERRIDE_SCAN_FAILED=0
    if ! make_tmp_dir; then
        MATCH_OVERRIDE_RISK="$1: 扫描临时目录不可用。"
        MATCH_OVERRIDE_SCAN_FAILED=1
        return 0
    fi
    if MATCH_OVERRIDE_RISK=$(scan_match_override_risk_file "$1" 0); then
        return 1
    else
        [ "$?" -eq 1 ] || MATCH_OVERRIDE_SCAN_FAILED=1
        MATCH_OVERRIDE_RISK_FOUND=1
        return 0
    fi
}

make_sshd_config_tmp_file() {
    target="$1"
    dir=$(ssh_init_dirname "$target")
    base=${target##*/}
    [ -d "$dir" ] || return 1
    old_umask=$(umask)
    umask 077
    tmp_file=""
    if command_exists mktemp; then
        tmp_file=$(mktemp "$dir/.$base.ssh-init.XXXXXX" 2>/dev/null || true)
    fi
    if [ -z "$tmp_file" ]; then
        i=0
        while [ "$i" -lt 10 ]; do
            candidate="$dir/.$base.ssh-init.$$.$i"
            if (set -C; : > "$candidate") 2>/dev/null; then
                tmp_file="$candidate"
                break
            fi
            i=$((i + 1))
        done
    fi
    umask "$old_umask"
    [ -n "$tmp_file" ] || return 1
    SSHD_CONFIG_TMP_FILE="$tmp_file"
    printf '%s\n' "$tmp_file"
}

sshd_dropin_dir_from_config() {
    file="$1"
    [ -f "$file" ] || return 1
    current_dir=$(ssh_init_dirname "$file")
    patterns_file=$(make_tmp_file "sshd-dropin-patterns") || return 1
    config_file_include_patterns "$file" > "$patterns_file" || return 1
    while IFS= read -r pattern || [ -n "$pattern" ]; do
        resolved_file=$(make_tmp_file "sshd-dropin-resolved") || return 1
        list_resolved_include_patterns "$pattern" "$current_dir" > "$resolved_file" || return 1
        while IFS= read -r resolved || [ -n "$resolved" ]; do
            dir=$(ssh_init_dirname "$resolved")
            base=${resolved##*/}
            case "$dir" in
                */sshd_config.d)
                    ;;
                *)
                    continue
                    ;;
            esac
            case "$base" in
                *.conf)
                    ;;
                *)
                    continue
                    ;;
            esac
            [ -d "$dir" ] || continue
            printf '%s\n' "$dir"
            return 0
        done < "$resolved_file"
    done < "$patterns_file"
    return 1
}

sshd_hardening_dropin_path() {
    dropin_dir=$(sshd_dropin_dir_from_config "$1" 2>/dev/null || true)
    [ -n "$dropin_dir" ] || return 1
    printf '%s\n' "$dropin_dir/00-ssh-init-hardening.conf"
}

write_sshd_hardening_dropin_content() {
    output="$1"
    cat > "$output" <<'EOF'
# Managed by ssh-init. Do not edit manually unless you know what you are doing.
PubkeyAuthentication yes
PasswordAuthentication no
ChallengeResponseAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
PermitRootLogin prohibit-password
EOF
}

write_sshd_hardening_dropin() {
    dropin_file="$1"
    tmp_file=$(make_sshd_config_tmp_file "$dropin_file" 2>/dev/null || true)
    if [ -z "$tmp_file" ]; then
        return 1
    fi
    if ! write_sshd_hardening_dropin_content "$tmp_file"; then
        safe_rm_f "$tmp_file" || true
        SSHD_CONFIG_TMP_FILE=""
        return 1
    fi
    if ! set_owner "$tmp_file" "root:root"; then
        safe_rm_f "$tmp_file" || true
        SSHD_CONFIG_TMP_FILE=""
        return 1
    fi
    if ! chmod 644 "$tmp_file"; then
        safe_rm_f "$tmp_file" || true
        SSHD_CONFIG_TMP_FILE=""
        return 1
    fi
    if ! mv -f "$tmp_file" "$dropin_file"; then
        safe_rm_f "$tmp_file" || true
        SSHD_CONFIG_TMP_FILE=""
        return 1
    fi
    SSHD_CONFIG_TMP_FILE=""
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
    awk '
        function setting_for(key) {
            key = tolower(key)
            if (key == "pubkeyauthentication") return "PubkeyAuthentication yes"
            if (key == "passwordauthentication") return "PasswordAuthentication no"
            if (key == "challengeresponseauthentication") return "ChallengeResponseAuthentication no"
            if (key == "kbdinteractiveauthentication") return "KbdInteractiveAuthentication no"
            if (key == "permitemptypasswords") return "PermitEmptyPasswords no"
            if (key == "permitrootlogin") return "PermitRootLogin prohibit-password"
            return ""
        }

        function first_key(line, tmp, parts) {
            tmp = line
            sub(/^[[:space:]]*/, "", tmp)
            if (substr(tmp, 1, 1) == "#") {
                sub(/^#[[:space:]]*/, "", tmp)
            }
            split(tmp, parts, /[[:space:]=]+/)
            return tolower(parts[1])
        }

        function is_active_match(line, tmp, parts) {
            tmp = line
            sub(/^[[:space:]]*/, "", tmp)
            if (substr(tmp, 1, 1) == "#") return 0
            split(tmp, parts, /[[:space:]=]+/)
            return tolower(parts[1]) == "match"
        }

        function mark_seen(key) {
            key = tolower(key)
            if (key == "pubkeyauthentication") seen_pubkey = 1
            else if (key == "passwordauthentication") seen_password = 1
            else if (key == "challengeresponseauthentication") seen_challenge = 1
            else if (key == "kbdinteractiveauthentication") seen_kbd = 1
            else if (key == "permitemptypasswords") seen_empty = 1
            else if (key == "permitrootlogin") seen_root = 1
        }

        function emit_missing() {
            if (inserted_missing) return
            inserted_missing = 1
            if (!seen_pubkey) print "PubkeyAuthentication yes"
            if (!seen_password) print "PasswordAuthentication no"
            if (!seen_challenge) print "ChallengeResponseAuthentication no"
            if (!seen_kbd) print "KbdInteractiveAuthentication no"
            if (!seen_empty) print "PermitEmptyPasswords no"
            if (!seen_root) print "PermitRootLogin prohibit-password"
        }

        {
            if (!in_match && is_active_match($0)) {
                emit_missing()
                in_match = 1
                print
                next
            }

            key = first_key($0)
            replacement = ""
            if (!in_match) {
                replacement = setting_for(key)
            }
            if (replacement != "") {
                print replacement
                mark_seen(key)
                next
            }
            print
        }

        END {
            emit_missing()
        }
    ' "$input" > "$output"
}

restore_sshd_backup() {
    backup="$1"
    [ -n "$backup" ] || return 1
    [ -f "$backup" ] || return 1
    cp -p "$backup" "$SSH_CONFIG"
}

restore_sshd_dropin_backup() {
    dropin_file="$1"
    dropin_backup="$2"
    dropin_existed="$3"
    [ -n "$dropin_file" ] || return 0
    if [ "$dropin_existed" = "1" ]; then
        [ -f "$dropin_backup" ] || return 1
        cp -p "$dropin_backup" "$dropin_file"
    else
        safe_rm_f "$dropin_file"
    fi
}

rollback_sshd_hardening() {
    backup="$1"
    dropin_file="$2"
    dropin_backup="$3"
    dropin_existed="$4"
    rollback_failed=0
    if ! restore_sshd_backup "$backup"; then
        error "恢复 sshd_config 备份失败: $backup"
        rollback_failed=1
    fi
    if ! restore_sshd_dropin_backup "$dropin_file" "$dropin_backup" "$dropin_existed"; then
        error "恢复 SSH drop-in 加固文件失败: $dropin_file"
        rollback_failed=1
    fi
    relock_immutable_if_needed "$SSH_CONFIG"
    [ "$rollback_failed" = "0" ]
}

warn_match_override_risk() {
    warn "检测到 Match 块可能覆盖全局 SSH 安全策略，请确认特定用户/地址仍允许密码登录是否符合预期。"
    if [ -n "${MATCH_OVERRIDE_RISK:-}" ]; then
        warn "风险位置: $MATCH_OVERRIDE_RISK"
    fi
}

harden_ssh_config() {
    require_root
    [ -f "$SSH_CONFIG" ] || die "找不到 SSH 配置文件: $SSH_CONFIG"
    if ! detect_authentication_methods_risk "$SSH_CONFIG"; then
        if [ "${AUTHENTICATION_METHODS_SCAN_FAILED:-0}" = "1" ]; then
            error "无法完整检查 SSH 认证配置，未进行加固。"
            die "$AUTHENTICATION_METHODS_RISK"
        fi
        auth_methods=$(printf '%s\n' "$AUTHENTICATION_METHODS_RISK" | sed 's/^.*: AuthenticationMethods //')
        error "当前 SSH 配置要求多因素认证 AuthenticationMethods $auth_methods 或 keyboard-interactive。"
        error "脚本会禁用 password / keyboard-interactive，继续可能导致 SSH 无法登录。"
        error "请先将 AuthenticationMethods 改为 publickey，或删除该项后重试。"
        exit 1
    fi
    match_override_warned=0
    if detect_match_override_risk "$SSH_CONFIG"; then
        if [ "${MATCH_OVERRIDE_SCAN_FAILED:-0}" = "1" ]; then
            error "无法完整检查 Match 条件配置，未进行加固。"
            die "$MATCH_OVERRIDE_RISK"
        fi
        match_override_warned=1
        warn_match_override_risk
    fi
    stamp=$(timestamp)
    backup="$SSH_CONFIG.bak.$stamp"
    dropin_file=$(sshd_hardening_dropin_path "$SSH_CONFIG" 2>/dev/null || true)
    dropin_backup=""
    dropin_existed=0
    tmp_file=""
    info "正在修改 sshd_config..."
    cp -p "$SSH_CONFIG" "$backup" || die "备份 sshd_config 失败。"
    success "已备份 sshd_config: $backup"
    unlock_immutable_if_needed "$SSH_CONFIG"
    if [ -n "$dropin_file" ]; then
        info "检测到 sshd_config.d Include，将优先写入: $dropin_file"
        if [ -f "$dropin_file" ]; then
            dropin_existed=1
            dropin_backup="$dropin_file.bak.$stamp"
            if ! cp -p "$dropin_file" "$dropin_backup"; then
                restore_sshd_backup "$backup" || true
                relock_immutable_if_needed "$SSH_CONFIG"
                die "备份 SSH drop-in 加固文件失败，已恢复备份。"
            fi
            success "已备份 SSH drop-in 加固文件: $dropin_backup"
        else
            info "将新建 SSH drop-in 加固文件: $dropin_file"
        fi
    fi
    tmp_file=$(make_sshd_config_tmp_file "$SSH_CONFIG" 2>/dev/null || true)
    if [ -z "$tmp_file" ]; then
        rollback_sshd_hardening "$backup" "$dropin_file" "$dropin_backup" "$dropin_existed" || true
        die "创建 SSH 配置临时文件失败，已恢复备份。"
    fi
    if ! cp -p "$SSH_CONFIG" "$tmp_file"; then
        safe_rm_f "$tmp_file" || true
        SSHD_CONFIG_TMP_FILE=""
        rollback_sshd_hardening "$backup" "$dropin_file" "$dropin_backup" "$dropin_existed" || true
        die "准备 SSH 配置临时文件失败，已恢复备份。"
    fi
    if ! write_hardened_sshd_config "$SSH_CONFIG" "$tmp_file"; then
        safe_rm_f "$tmp_file" || true
        SSHD_CONFIG_TMP_FILE=""
        rollback_sshd_hardening "$backup" "$dropin_file" "$dropin_backup" "$dropin_existed" || true
        die "生成 SSH 配置失败，已恢复备份。"
    fi
    if ! validate_sshd_config_file "$tmp_file"; then
        safe_rm_f "$tmp_file" || true
        SSHD_CONFIG_TMP_FILE=""
        rollback_sshd_hardening "$backup" "$dropin_file" "$dropin_backup" "$dropin_existed" || true
        die "sshd -t 校验失败，已恢复备份。"
    fi
    if ! mv -f "$tmp_file" "$SSH_CONFIG"; then
        safe_rm_f "$tmp_file" || true
        SSHD_CONFIG_TMP_FILE=""
        rollback_sshd_hardening "$backup" "$dropin_file" "$dropin_backup" "$dropin_existed" || true
        die "写入 SSH 配置失败，已恢复备份。"
    fi
    SSHD_CONFIG_TMP_FILE=""

    if [ -n "$dropin_file" ]; then
        if ! write_sshd_hardening_dropin "$dropin_file"; then
            rollback_sshd_hardening "$backup" "$dropin_file" "$dropin_backup" "$dropin_existed" || true
            die "写入 SSH drop-in 加固文件失败，已恢复备份。"
        fi
        success "SSH drop-in 加固文件已写入: $dropin_file"
    fi

    if ! validate_sshd_config; then
        rollback_sshd_hardening "$backup" "$dropin_file" "$dropin_backup" "$dropin_existed" || true
        die "sshd -t 校验失败，已恢复备份。"
    fi
    success "SSH 配置校验通过"
    if ! effective_failures=$(make_tmp_file "sshd-effective-check"); then
        rollback_sshd_hardening "$backup" "$dropin_file" "$dropin_backup" "$dropin_existed" || true
        die "无法创建生效配置检查文件，已尝试恢复 SSH 配置。"
    fi
    if ! effective_sshd_settings_check "$SSH_CONFIG" "$effective_failures"; then
        print_effective_sshd_settings_failure "$effective_failures"
        rollback_sshd_hardening "$backup" "$dropin_file" "$dropin_backup" "$dropin_existed" || true
        die "已恢复 SSH 配置，未重启 SSH 服务。"
    fi
    success "SSH 最终生效配置校验通过"

    if ! restart_ssh_service; then
        warn "SSH 服务重启失败，正在恢复备份..."
        rollback_sshd_hardening "$backup" "$dropin_file" "$dropin_backup" "$dropin_existed" || true
        restart_ssh_service >/dev/null 2>&1 || true
        die "SSH 服务重启失败，已尝试恢复备份。请通过 VNC/Console 检查。"
    fi
    relock_immutable_if_needed "$SSH_CONFIG"
    success "SSH 服务已重启"
    if [ "$match_override_warned" = "1" ]; then
        warn_match_override_risk
    fi
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

latest_dropin_backup() {
    dropin_file=$(sshd_hardening_dropin_path "$SSH_CONFIG" 2>/dev/null || true)
    [ -n "$dropin_file" ] || return 1
    latest_matching_file "$dropin_file.bak.*"
}

is_managed_ssh_init_dropin() {
    file="$1"
    [ -f "$file" ] || return 1
    grep -Fq 'Managed by ssh-init' "$file" 2>/dev/null
}

restore_sshd_dropin_from_backup_or_remove() (
    # Resolve both arguments before changing sshd_config. Never choose a new
    # backup while rolling back a partially completed restore.
    restore_dropin_file="$1"
    restore_dropin_backup="$2"
    [ -n "$restore_dropin_file" ] || return 0

    if [ -n "$restore_dropin_backup" ]; then
        cp -p "$restore_dropin_backup" "$restore_dropin_file" || return 1
        success "已恢复 SSH drop-in: $restore_dropin_file"
        return 0
    fi

    if is_managed_ssh_init_dropin "$restore_dropin_file"; then
        safe_rm_f "$restore_dropin_file" || return 1
        success "已移除 ssh-init 创建的 drop-in: $restore_dropin_file"
    fi
    return 0
)

snapshot_restore_file() (
    [ -n "$1" ] || { printf '%s\n' 0; return 0; }
    if [ -L "$1" ] || { [ -e "$1" ] && [ ! -f "$1" ]; }; then
        error "恢复目标不是普通文件或是 symlink: $1"
        return 1
    fi
    if [ -f "$1" ]; then
        # Do not overwrite an earlier recovery snapshot from the same second.
        (set -C; : > "$2") || return 1
        cp -p "$1" "$2" || return 1
        printf '%s\n' 1
    else
        printf '%s\n' 0
    fi
)

restore_file_snapshot() (
    [ -n "$1" ] || return 0
    if [ "$3" = "1" ]; then
        cp -p "$2" "$1"
    else
        safe_rm_f "$1"
    fi
)

rollback_sshd_restore_transaction() {
    # These names belong only to restore_sshd_transaction's subshell.
    restore_tx_rollback_failed=0
    restore_file_snapshot "$SSH_CONFIG" "$restore_tx_main_before" "$restore_tx_main_existed" || restore_tx_rollback_failed=1
    restore_file_snapshot "$restore_tx_dropin" "$restore_tx_dropin_before" "$restore_tx_dropin_existed" || restore_tx_rollback_failed=1
    restore_file_snapshot "$restore_tx_other_dropin" "$restore_tx_other_before" "$restore_tx_other_existed" || restore_tx_rollback_failed=1
    if [ "$restore_tx_with_auth" = "1" ]; then
        restore_file_snapshot "$restore_tx_auth" "$restore_tx_auth_before" "$restore_tx_auth_existed" || restore_tx_rollback_failed=1
    fi
    if [ "$restore_tx_service_touched" = "1" ]; then
        if ! validate_sshd_config || ! restart_ssh_service; then
            warn "操作前的 SSH 配置未能重新加载，请通过 VNC/Console 检查。"
            restore_tx_rollback_failed=1
        fi
    fi
    relock_immutable_if_needed "$SSH_CONFIG"
    [ "$restore_tx_rollback_failed" = "0" ]
}

cleanup_sshd_restore_transaction() {
    if [ "$restore_tx_active" = "1" ]; then
        if rollback_sshd_restore_transaction; then
            warn "已还原操作前的 sshd_config、SSH drop-in 和相关 authorized_keys 状态。"
        else
            warn "恢复操作的回滚未完全成功；请保留 before-restore 备份并通过 VNC/Console 检查。"
        fi
    fi
    if [ -n "$restore_tx_staged" ]; then
        safe_rm_f "$restore_tx_staged" || true
    fi
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

    dropin_file=$(sshd_hardening_dropin_path "$SSH_CONFIG" 2>/dev/null || true)
    if [ -n "$dropin_file" ]; then
        printf '%s\n' "[可用 SSH drop-in 备份]"
        files=$(list_matching_files_reverse "$dropin_file.bak.*")
        if [ -n "$files" ]; then
            printf '%s\n' "$files" | awk '{print NR ") " $0}'
        else
            printf '%s\n' "(无)"
        fi
        print_blank
    fi
}

show_effective_ssh_config() {
    sshd_bin=$(find_sshd_bin 2>/dev/null || true)
    [ -n "$sshd_bin" ] || return 0
    "$sshd_bin" -T -f "$SSH_CONFIG" 2>/dev/null | grep -Ei "^(port|permitrootlogin|pubkeyauthentication|passwordauthentication|kbdinteractiveauthentication|challengeresponseauthentication|permitemptypasswords|authenticationmethods) " || true
}

get_effective_sshd_value() {
    key="$1"
    show_effective_ssh_config | awk -v k="$key" 'tolower($1) == tolower(k) { print $2; exit }'
}

debug_effective_config() {
    sshd_bin=$(find_sshd_bin 2>/dev/null || true)
    print_blank
    print_section_title "SSH 最终生效配置诊断"
    if [ -n "$sshd_bin" ]; then
        printf '%s\n' "sshd 路径: $sshd_bin"
    else
        printf '%s\n' "sshd 路径: 未找到"
    fi
    printf '%s\n' "配置文件: $SSH_CONFIG"
    print_blank

    printf '%s\n' "[最终生效关键项]"
    if [ -n "$sshd_bin" ]; then
        effective_file=$(make_tmp_file "sshd-debug-effective") || return 1
        if "$sshd_bin" -T -f "$SSH_CONFIG" > "$effective_file" 2>/dev/null; then
            if ! grep -Ei "$SSHD_EFFECTIVE_KEYS_RE" "$effective_file"; then
                printf '%s\n' "(未输出相关关键项)"
            fi
        else
            printf '%s\n' "sshd -T 无法读取最终配置"
        fi
    else
        printf '%s\n' "sshd -T 无法读取最终配置"
    fi
    print_blank

    printf '%s\n' "[相关来源行]"
    config_dir=$(ssh_init_dirname "$SSH_CONFIG")
    source_dir="$config_dir/sshd_config.d"
    if [ -d "$source_dir" ]; then
        grep -RInE "$SSHD_SOURCE_GREP_RE" "$SSH_CONFIG" "$source_dir" 2>/dev/null || printf '%s\n' "(未找到相关来源行)"
    else
        grep -RInE "$SSHD_SOURCE_GREP_RE" "$SSH_CONFIG" 2>/dev/null || printf '%s\n' "(未找到相关来源行)"
    fi
    print_section_end
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

restore_sshd_transaction() (
    # POSIX sh functions otherwise share variables with their callers. Keep
    # transaction paths and the immutable flag isolated from helper functions.
    restore_tx_backup="$1"
    restore_tx_with_auth="$2"
    restore_tx_auth_backup="${3:-}"
    restore_tx_active=0
    restore_tx_service_touched=0
    restore_tx_staged=""
    [ -f "$restore_tx_backup" ] || {
        error "没有找到 sshd_config 备份。"
        return 1
    }
    require_root
    trap cleanup_sshd_restore_transaction EXIT
    trap 'exit 1' HUP INT TERM

    # Stage before mutation and resolve paths from both configuration versions.
    # OpenSSH itself resolves relative Includes against /etc/ssh.
    restore_tx_staged=$(make_sshd_config_tmp_file "$SSH_CONFIG") || return 1
    [ -n "$restore_tx_staged" ] || return 1
    cp -p "$restore_tx_backup" "$restore_tx_staged" || return 1
    restore_tx_other_dropin=$(sshd_hardening_dropin_path "$SSH_CONFIG" 2>/dev/null || true)
    restore_tx_dropin=$(sshd_hardening_dropin_path "$restore_tx_staged" 2>/dev/null || true)
    if [ "$restore_tx_other_dropin" = "$restore_tx_dropin" ]; then
        restore_tx_other_dropin=""
    fi
    restore_tx_dropin_backup=""
    if [ -n "$restore_tx_dropin" ]; then
        restore_tx_dropin_backup=$(latest_matching_file "$restore_tx_dropin.bak.*" 2>/dev/null || true)
    fi

    restore_tx_stamp="$(timestamp).$$"
    restore_tx_sequence=0
    while [ -e "$SSH_CONFIG.before-restore.$restore_tx_stamp" ] ||
        [ -L "$SSH_CONFIG.before-restore.$restore_tx_stamp" ]; do
        restore_tx_sequence=$((restore_tx_sequence + 1))
        restore_tx_stamp="$(timestamp).$$.$restore_tx_sequence"
    done
    restore_tx_main_before="$SSH_CONFIG.before-restore.$restore_tx_stamp"
    restore_tx_dropin_before="$restore_tx_dropin.before-restore.$restore_tx_stamp"
    restore_tx_other_before="$restore_tx_other_dropin.before-restore.$restore_tx_stamp"
    restore_tx_main_existed=$(snapshot_restore_file "$SSH_CONFIG" "$restore_tx_main_before") || return 1
    restore_tx_dropin_existed=$(snapshot_restore_file "$restore_tx_dropin" "$restore_tx_dropin_before") || return 1
    restore_tx_other_existed=$(snapshot_restore_file "$restore_tx_other_dropin" "$restore_tx_other_before") || return 1
    restore_tx_auth=""
    restore_tx_auth_before=""
    restore_tx_auth_existed=0
    if [ "$restore_tx_with_auth" = "1" ]; then
        restore_tx_auth=$(current_auth_file)
        restore_tx_auth_before="$restore_tx_auth.before-restore.$restore_tx_stamp"
        restore_tx_auth_existed=$(snapshot_restore_file "$restore_tx_auth" "$restore_tx_auth_before") || return 1
    fi

    unlock_immutable_if_needed "$SSH_CONFIG"
    restore_tx_active=1
    if ! cp -p "$restore_tx_staged" "$SSH_CONFIG"; then
        error "恢复 sshd_config 失败，正在还原操作前状态。"
        return 1
    fi
    if ! restore_sshd_dropin_from_backup_or_remove "$restore_tx_dropin" "$restore_tx_dropin_backup"; then
        error "恢复 SSH drop-in 失败，正在还原操作前状态。"
        return 1
    fi
    if ! validate_sshd_config; then
        error "恢复后的 sshd_config 未通过 sshd -t，正在还原操作前状态。"
        return 1
    fi
    if [ "$restore_tx_with_auth" = "1" ] &&
        ! (restore_authorized_keys_from_backup "$restore_tx_auth_backup"); then
        error "authorized_keys 恢复失败，正在还原操作前状态。"
        return 1
    fi
    restore_tx_service_touched=1
    if ! restart_ssh_service; then
        error "SSH 服务重启失败，正在还原操作前状态。"
        return 1
    fi
    restore_tx_active=0
    relock_immutable_if_needed "$SSH_CONFIG"
    success "sshd_config 已恢复。"
    success "SSH 服务已重启。"
    show_effective_ssh_config
    password_auth=$(get_effective_sshd_value "passwordauthentication")
    permit_root=$(get_effective_sshd_value "permitrootlogin")
    [ -n "$password_auth" ] && info "当前 PasswordAuthentication: $password_auth"
    [ -n "$permit_root" ] && info "当前 PermitRootLogin: $permit_root"
    return 0
)

restore_sshd_config_from_backup() {
    restore_sshd_transaction "$1" 0
}

restore_sshd_and_authorized_keys_from_backups() {
    restore_sshd_transaction "$1" 1 "$2" || return 1
    info "请新开终端测试 SSH 登录是否恢复正常。"
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
            restore_sshd_and_authorized_keys_from_backups "$ssh_backup" "$auth_backup"
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
                print_github_import_tutorial
                ask_prompt "请输入 GitHub 用户名（username，不含 @）:" || return 0
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
  sh init.sh --debug-effective
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
        --debug-effective)
            [ "$#" -eq 1 ] || return 1
            CLI_MODE="debug-effective"
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
    # Temporary-file helpers run in command substitutions. Keep ownership of
    # their directory in this shell so the exit trap can always remove it.
    if [ "$CLI_MODE" != "help" ]; then
        make_tmp_dir || die "无法初始化安全临时目录。"
    fi
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
        debug-effective)
            debug_effective_config
            ;;
        help)
            usage
            ;;
    esac
}

if [ "${IKE_TEST_MODE:-0}" != "1" ]; then
    main "$@"
fi
