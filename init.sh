#!/bin/sh

# ike-ssh-init: minimal SSH key login initialization and hardening.
# POSIX sh only. No BBR, system upgrade, Docker, site, reverse proxy, WARP or DD.

set -u

ALLOWED_GH_USERS=${ALLOWED_GH_USERS:-"ike666888 ike-sh"}
DEFAULT_USER=${DEFAULT_USER:-deploy}
DEFAULT_PORT=${DEFAULT_PORT:-2222}

BACKUP_ROOT=${BACKUP_ROOT:-/var/backups/ike-ssh-init}
SSH_CONFIG=${SSH_CONFIG:-/etc/ssh/sshd_config}
SSH_CONFIG_D=${SSH_CONFIG_D:-/etc/ssh/sshd_config.d}
SUDOERS_D=${SUDOERS_D:-/etc/sudoers.d}
SSHD_FRAGMENT=${SSHD_FRAGMENT:-"$SSH_CONFIG_D/99-ike-hardening.conf"}
RUN_SSHD_DIR=${RUN_SSHD_DIR:-/run/sshd}

BLOCK_BEGIN="# BEGIN IKE-SSH-INIT MANAGED BLOCK"
BLOCK_END="# END IKE-SSH-INIT MANAGED BLOCK"

TMP_DIR=""
BACKUP_DIR=""
VALID_KEYS_FILE=""

info() {
    printf '%s\n' "$*"
}

warn() {
    printf '%s\n' "警告: $*" >&2
}

die() {
    printf '%s\n' "错误: $*" >&2
    exit 1
}

cleanup_tmp() {
    if [ -n "${TMP_DIR:-}" ] && [ -d "$TMP_DIR" ]; then
        case "$TMP_DIR" in
            /tmp/ike-ssh-init.*)
                rm -rf "$TMP_DIR"
                ;;
        esac
    fi
}

trap cleanup_tmp EXIT HUP INT TERM

make_tmp_dir() {
    old_umask=$(umask)
    umask 077
    if command -v mktemp >/dev/null 2>&1; then
        TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/ike-ssh-init.XXXXXX" 2>/dev/null || true)
    fi
    if [ -z "$TMP_DIR" ]; then
        TMP_DIR="${TMPDIR:-/tmp}/ike-ssh-init.$$"
        mkdir "$TMP_DIR" 2>/dev/null || {
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

init_defaults() {
    TARGET_USER="$DEFAULT_USER"
    SSH_PORT="$DEFAULT_PORT"
    KEY_RAW=""
    KEY_GH=""
    STRICT_MODE=0
    YES_MODE=0
    DRY_RUN=0
    ROLLBACK_LAST=0
    FIREWALL_MODE="auto"
    SUDO_NOPASSWD=0
    USER_CREATED=0
    ARG_COUNT=0
    OS_ID="unknown"
    OS_NAME="unknown"
}

usage() {
    cat <<'EOF'
用法:
  sh init.sh [options]

支持参数:
  --user=deploy
  --port=2222
  --key-raw='ssh-ed25519 AAAA...'
  --key-gh=GitHubUser
  --strict
  --yes
  --dry-run
  --rollback-last
  --no-firewall
  --sudo-nopasswd

不支持参数:
  --bbr --update --key-url --docker --warp --dd --site --ssl
EOF
}

parse_args() {
    ARG_COUNT=$#
    for arg in "$@"; do
        case "$arg" in
            --user=*)
                TARGET_USER=${arg#*=}
                ;;
            --port=*)
                SSH_PORT=${arg#*=}
                ;;
            --key-raw=*)
                KEY_RAW=${arg#*=}
                ;;
            --key-gh=*)
                KEY_GH=${arg#*=}
                ;;
            --strict)
                STRICT_MODE=1
                ;;
            --yes)
                YES_MODE=1
                ;;
            --dry-run)
                DRY_RUN=1
                ;;
            --rollback-last)
                ROLLBACK_LAST=1
                ;;
            --no-firewall)
                FIREWALL_MODE="none"
                ;;
            --sudo-nopasswd)
                SUDO_NOPASSWD=1
                ;;
            --bbr|--update|--key-url=*|--key-url|--docker|--warp|--dd|--site|--ssl)
                printf '%s\n' "错误: 本项目不实现该参数: $arg" >&2
                return 1
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                printf '%s\n' "错误: 未知参数: $arg" >&2
                return 1
                ;;
        esac
    done
    return 0
}

require_root() {
    if [ "${IKE_TEST_MODE:-0}" = "1" ] && [ "${IKE_SKIP_ROOT_CHECK:-0}" = "1" ]; then
        return 0
    fi
    uid=$(id -u 2>/dev/null || printf '%s\n' "")
    if [ "$uid" != "0" ]; then
        die "必须以 root 权限运行"
    fi
}

is_valid_username() {
    user="$1"
    if [ "$user" = "root" ]; then
        return 0
    fi
    case "$user" in
        ""|[0123456789-]*|*[!abcdefghijklmnopqrstuvwxyz0123456789_-]*)
            return 1
            ;;
    esac
    return 0
}

validate_port() {
    port="$1"
    case "$port" in
        ""|*[!0123456789]*)
            return 1
            ;;
    esac
    if [ "$port" -lt 1024 ] || [ "$port" -gt 65535 ]; then
        return 1
    fi
    case "$port" in
        80|443|3306|5432|6379|27017|11211|8080|8443)
            return 1
            ;;
    esac
    return 0
}

detect_os() {
    OS_ID="unknown"
    OS_NAME="unknown"
    if [ -r /etc/os-release ]; then
        OS_ID=$(awk -F= '$1=="ID" {gsub(/"/, "", $2); print $2}' /etc/os-release | sed -n '1p')
        OS_NAME=$(awk -F= '$1=="PRETTY_NAME" {gsub(/"/, "", $2); print $2}' /etc/os-release | sed -n '1p')
    fi
    [ -n "$OS_ID" ] || OS_ID="unknown"
    [ -n "$OS_NAME" ] || OS_NAME="$OS_ID"

    case "$OS_ID" in
        debian|ubuntu|alpine|centos|almalinux|rocky)
            return 0
            ;;
        *)
            if [ "$STRICT_MODE" -eq 1 ]; then
                die "strict 模式下拒绝未知或未明确支持的系统: $OS_NAME"
            fi
            warn "未明确识别为 Debian / Ubuntu / Alpine / CentOS / AlmaLinux / Rocky: $OS_NAME"
            return 0
            ;;
    esac
}

is_allowed_gh_user() {
    gh_user="$1"
    case "$gh_user" in
        ""|-*|*-|*[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-]*)
            return 1
            ;;
    esac
    allowed_list=" $ALLOWED_GH_USERS "
    case "$allowed_list" in
        *" $gh_user "*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

validate_key_source_args() {
    if [ -n "$KEY_RAW" ] && [ -n "$KEY_GH" ]; then
        die "只能选择一种公钥来源: --key-raw 或 --key-gh"
    fi
    if [ -n "$KEY_GH" ] && ! is_allowed_gh_user "$KEY_GH"; then
        die "GitHub 用户不在 ALLOWED_GH_USERS 白名单中: $KEY_GH"
    fi
    return 0
}

normalize_key_line() {
    line=$(printf '%s\n' "$1" | awk '{$1=$1; print}')
    key_type=$(printf '%s\n' "$line" | awk '{print $1}')
    key_data=$(printf '%s\n' "$line" | awk '{print $2}')

    case "$key_type" in
        ssh-ed25519|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com|ssh-rsa)
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
    if [ "$key_len" -lt 20 ]; then
        return 1
    fi

    printf '%s\n' "$line"
    return 0
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
        if [ -n "$normalized" ]; then
            if ! grep -Fxq "$normalized" "$output_file" 2>/dev/null; then
                printf '%s\n' "$normalized" >> "$output_file" || return 1
                count=$((count + 1))
            fi
        fi
    done < "$input_file"

    printf '%s\n' "$count"
    return 0
}

fetch_github_keys() {
    gh_user="$1"
    output_file="$2"
    is_allowed_gh_user "$gh_user" || return 1
    url="https://github.com/$gh_user.keys"

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 10 "$url" -o "$output_file"
        return $?
    fi
    if command -v wget >/dev/null 2>&1; then
        wget -qO "$output_file" "$url"
        return $?
    fi
    return 1
}

safe_rm_rf() {
    path="$1"
    [ -n "$path" ] || return 1
    case "$path" in
        "/"|"/etc"|"/etc/"|"/var"|"/var/"|"/usr"|"/usr/")
            return 1
            ;;
    esac
    [ -e "$path" ] || [ -L "$path" ] || return 0
    rm -rf "$path"
}

safe_rm_f() {
    path="$1"
    [ -n "$path" ] || return 1
    [ -e "$path" ] || [ -L "$path" ] || return 0
    rm -f "$path"
}

print_sh_var() {
    name="$1"
    value="$2"
    quoted=$(printf '%s' "$value" | sed "s/'/'\\\\''/g")
    printf "%s='%s'\n" "$name" "$quoted"
}

write_restore_script() {
    restore_path="$BACKUP_DIR/restore.sh"
    {
        printf '%s\n' '#!/bin/sh'
        printf '%s\n' 'set -u'
        printf '%s\n' "BACKUP_DIR=\$(CDPATH=; cd \"\$(dirname \"\$0\")\" && pwd)"
        print_sh_var SSH_CONFIG_DEST "$SSH_CONFIG"
        print_sh_var SSH_CONFIG_D_DEST "$SSH_CONFIG_D"
        print_sh_var SUDOERS_D_DEST "$SUDOERS_D"
        print_sh_var RUN_SSHD_DIR_DEST "$RUN_SSHD_DIR"
        cat <<'RESTORE_BODY'

safe_rm_rf() {
    path="$1"
    [ -n "$path" ] || return 1
    case "$path" in
        "/"|"/etc"|"/etc/"|"/var"|"/var/"|"/usr"|"/usr/")
            return 1
            ;;
    esac
    [ -e "$path" ] || [ -L "$path" ] || return 0
    rm -rf "$path"
}

restore_file() {
    src="$1"
    dest="$2"
    marker="$3"
    [ -n "$src" ] || return 1
    [ -n "$dest" ] || return 1
    [ -n "$marker" ] || return 1
    if [ -f "$src" ]; then
        cp -p "$src" "$dest" || return 1
    elif [ -f "$marker" ]; then
        safe_rm_rf "$dest" || return 1
    fi
    return 0
}

restore_dir() {
    src="$1"
    dest="$2"
    marker="$3"
    [ -n "$src" ] || return 1
    [ -n "$dest" ] || return 1
    [ -n "$marker" ] || return 1
    tmp="${dest}.ike-restore.$$"
    [ -n "$tmp" ] || return 1
    if [ -d "$src" ]; then
        safe_rm_rf "$tmp" || return 1
        cp -pR "$src" "$tmp" || return 1
        safe_rm_rf "$dest" || return 1
        mv "$tmp" "$dest" || return 1
    elif [ -f "$marker" ]; then
        safe_rm_rf "$dest" || return 1
    fi
    return 0
}

find_sshd() {
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

ensure_run_sshd_dir() {
    [ -n "$RUN_SSHD_DIR_DEST" ] || return 1
    if [ -L "$RUN_SSHD_DIR_DEST" ]; then
        return 1
    fi
    if [ ! -d "$RUN_SSHD_DIR_DEST" ]; then
        mkdir -p "$RUN_SSHD_DIR_DEST" || return 1
    fi
    chmod 755 "$RUN_SSHD_DIR_DEST" || return 1
    return 0
}

reload_sshd() {
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
    if command -v systemctl >/dev/null 2>&1; then
        systemctl reload ssh >/dev/null 2>&1 && return 0
        systemctl reload sshd >/dev/null 2>&1 && return 0
    fi
    if command -v service >/dev/null 2>&1; then
        service ssh reload >/dev/null 2>&1 && return 0
        service sshd reload >/dev/null 2>&1 && return 0
    fi
    if command -v rc-service >/dev/null 2>&1; then
        rc-service ssh reload >/dev/null 2>&1 && return 0
        rc-service sshd reload >/dev/null 2>&1 && return 0
    fi
    return 1
}

restore_file "$BACKUP_DIR/sshd_config" "$SSH_CONFIG_DEST" "$BACKUP_DIR/sshd_config.missing" || exit 1
restore_dir "$BACKUP_DIR/sshd_config.d" "$SSH_CONFIG_D_DEST" "$BACKUP_DIR/sshd_config.d.missing" || exit 1
restore_dir "$BACKUP_DIR/sudoers.d" "$SUDOERS_D_DEST" "$BACKUP_DIR/sudoers.d.missing" || exit 1

sshd_bin=$(find_sshd 2>/dev/null || true)
if [ -n "$sshd_bin" ]; then
    ensure_run_sshd_dir || exit 1
    "$sshd_bin" -t || exit 1
fi

reload_sshd || exit 1
printf '%s\n' "restore complete: $BACKUP_DIR"
RESTORE_BODY
    } > "$restore_path" || return 1
    chmod 700 "$restore_path" || return 1
    return 0
}

backup_file_or_marker() {
    src="$1"
    dest="$2"
    marker="$3"
    [ -n "$src" ] || return 1
    [ -n "$dest" ] || return 1
    [ -n "$marker" ] || return 1
    if [ -f "$src" ]; then
        cp -p "$src" "$dest" || return 1
    else
        : > "$marker" || return 1
    fi
    return 0
}

backup_dir_or_marker() {
    src="$1"
    dest="$2"
    marker="$3"
    [ -n "$src" ] || return 1
    [ -n "$dest" ] || return 1
    [ -n "$marker" ] || return 1
    if [ -d "$src" ]; then
        cp -pR "$src" "$dest" || return 1
    else
        : > "$marker" || return 1
    fi
    return 0
}

create_backup() {
    ts=$(date +%Y%m%d_%H%M%S)
    [ -n "$BACKUP_ROOT" ] || return 1
    mkdir -p "$BACKUP_ROOT" || return 1
    BACKUP_DIR="$BACKUP_ROOT/$ts"
    if [ -e "$BACKUP_DIR" ]; then
        sleep 1
        ts=$(date +%Y%m%d_%H%M%S)
        BACKUP_DIR="$BACKUP_ROOT/$ts"
    fi
    mkdir "$BACKUP_DIR" || return 1

    backup_file_or_marker "$SSH_CONFIG" "$BACKUP_DIR/sshd_config" "$BACKUP_DIR/sshd_config.missing" || return 1
    backup_dir_or_marker "$SSH_CONFIG_D" "$BACKUP_DIR/sshd_config.d" "$BACKUP_DIR/sshd_config.d.missing" || return 1
    backup_dir_or_marker "$SUDOERS_D" "$BACKUP_DIR/sudoers.d" "$BACKUP_DIR/sudoers.d.missing" || return 1
    write_restore_script || return 1
    info "已创建备份: $BACKUP_DIR"
    return 0
}

latest_backup_dir() {
    [ -d "$BACKUP_ROOT" ] || return 1
    latest=""
    latest_base=""
    for dir in "$BACKUP_ROOT"/*; do
        [ -d "$dir" ] || continue
        base=${dir##*/}
        case "$base" in
            [0123456789][0123456789][0123456789][0123456789][0123456789][0123456789][0123456789][0123456789]_[0123456789][0123456789][0123456789][0123456789][0123456789][0123456789])
                if [ -z "$latest_base" ] || awk -v a="$base" -v b="$latest_base" 'BEGIN { exit (a > b) ? 0 : 1 }'; then
                    latest="$dir"
                    latest_base="$base"
                fi
                ;;
        esac
    done
    [ -n "$latest" ] || return 1
    printf '%s\n' "$latest"
    return 0
}

run_restore() {
    restore_dir_path="$1"
    if [ -z "$restore_dir_path" ] || [ ! -x "$restore_dir_path/restore.sh" ]; then
        return 1
    fi
    sh "$restore_dir_path/restore.sh"
}

rollback_or_die() {
    reason="$1"
    warn "$reason"
    if [ -n "$BACKUP_DIR" ] && run_restore "$BACKUP_DIR"; then
        die "已自动回滚。请保持当前 SSH 窗口，重新检查配置后再执行。"
    fi
    printf '%s\n' "致命: 自动回滚失败，请立即进入云厂商 VNC/Console 手动恢复。" >&2
    if [ -n "$BACKUP_DIR" ]; then
        printf '%s\n' "可尝试执行: sh $BACKUP_DIR/restore.sh" >&2
    fi
    exit 1
}

rollback_last() {
    latest=$(latest_backup_dir 2>/dev/null || true)
    if [ -z "$latest" ]; then
        die "没有找到可用备份: $BACKUP_ROOT"
    fi
    info "将执行最新备份回滚: $latest"
    if ! run_restore "$latest"; then
        printf '%s\n' "回滚失败，请进入 VNC/Console 手动恢复。" >&2
        exit 1
    fi
}

login_shell() {
    if [ -x /bin/bash ]; then
        printf '%s\n' /bin/bash
        return 0
    fi
    printf '%s\n' /bin/sh
}

passwd_field() {
    user="$1"
    field="$2"
    passwd_file=${PASSWD_FILE:-/etc/passwd}
    awk -F: -v u="$user" -v f="$field" '$1 == u {print $f}' "$passwd_file" | sed -n '1p'
}

ensure_user() {
    user="$1"
    shell_path=$(login_shell)
    if id "$user" >/dev/null 2>&1; then
        USER_CREATED=0
        current_shell=$(passwd_field "$user" 7)
        case "$current_shell" in
            ""|*/nologin|*/false)
                if command -v usermod >/dev/null 2>&1; then
                    usermod -s "$shell_path" "$user" || return 1
                elif command -v chsh >/dev/null 2>&1; then
                    chsh -s "$shell_path" "$user" || return 1
                else
                    return 1
                fi
                ;;
        esac
        return 0
    fi

    if command -v useradd >/dev/null 2>&1; then
        useradd -m -s "$shell_path" "$user" || return 1
        USER_CREATED=1
        return 0
    fi
    if command -v adduser >/dev/null 2>&1; then
        adduser -D -s "$shell_path" "$user" || return 1
        USER_CREATED=1
        return 0
    fi
    return 1
}

owner_uid() {
    path="$1"
    # shellcheck disable=SC2012
    ls -dn "$path" 2>/dev/null | awk '{print $3}' | sed -n '1p'
}

deploy_authorized_keys() {
    user="$1"
    keys_file="$2"
    home_dir=$(passwd_field "$user" 6)
    uid=$(id -u "$user" 2>/dev/null || true)
    [ -n "$home_dir" ] || return 1
    [ -n "$uid" ] || return 1
    [ "$home_dir" != "/" ] || return 1

    if [ -L "$home_dir" ] || [ ! -d "$home_dir" ]; then
        return 1
    fi
    if [ "$(owner_uid "$home_dir")" != "$uid" ]; then
        return 1
    fi

    ssh_dir="$home_dir/.ssh"
    auth_file="$ssh_dir/authorized_keys"

    if [ -L "$ssh_dir" ]; then
        return 1
    fi
    if [ -e "$ssh_dir" ] && [ ! -d "$ssh_dir" ]; then
        return 1
    fi
    if [ ! -d "$ssh_dir" ]; then
        mkdir "$ssh_dir" || return 1
    fi

    if [ -L "$auth_file" ]; then
        return 1
    fi
    if [ -e "$auth_file" ] && [ ! -f "$auth_file" ]; then
        return 1
    fi
    if [ ! -f "$auth_file" ]; then
        : > "$auth_file" || return 1
    fi

    chmod 700 "$ssh_dir" || return 1
    chmod 600 "$auth_file" || return 1
    chown "$user" "$ssh_dir" || return 1
    chown "$user" "$auth_file" || return 1

    if [ "$(owner_uid "$ssh_dir")" != "$uid" ] || [ "$(owner_uid "$auth_file")" != "$uid" ]; then
        return 1
    fi

    added=0
    while IFS= read -r key_line || [ -n "$key_line" ]; do
        [ -n "$key_line" ] || continue
        if ! grep -Fxq "$key_line" "$auth_file" 2>/dev/null; then
            printf '%s\n' "$key_line" >> "$auth_file" || return 1
            added=$((added + 1))
        fi
    done < "$keys_file"

    chmod 600 "$auth_file" || return 1
    chown "$user" "$auth_file" || return 1
    info "authorized_keys 已处理，新增 $added 条公钥"
    return 0
}

sudoers_line() {
    user="$1"
    nopass="$2"
    if [ "$nopass" -eq 1 ]; then
        printf '%s ALL=(ALL) NOPASSWD: ALL\n' "$user"
    else
        printf '%s ALL=(ALL) ALL\n' "$user"
    fi
}

configure_sudoers() {
    user="$1"
    nopass="$2"
    [ "$user" = "root" ] && return 0
    if [ ! -d "$SUDOERS_D" ]; then
        return 1
    fi
    if ! command -v visudo >/dev/null 2>&1; then
        return 1
    fi

    sudo_file="$SUDOERS_D/90-ike-$user"
    sudo_tmp=$(make_tmp_file "sudoers")
    [ -n "$sudo_file" ] || return 1
    [ -n "$sudo_tmp" ] || return 1
    sudoers_line "$user" "$nopass" > "$sudo_tmp" || return 1
    chmod 440 "$sudo_tmp" || return 1
    mv "$sudo_tmp" "$sudo_file" || return 1
    chmod 440 "$sudo_file" || return 1

    if ! visudo -cf "$sudo_file" >/dev/null 2>&1; then
        safe_rm_f "$sudo_file" || true
        return 1
    fi
    return 0
}

build_hardening_block() {
    port="$1"
    printf '%s\n' "Port $port"
    printf '%s\n' "PubkeyAuthentication yes"
    printf '%s\n' "PasswordAuthentication no"
    printf '%s\n' "KbdInteractiveAuthentication no"
    printf '%s\n' "ChallengeResponseAuthentication no"
    printf '%s\n' "PermitEmptyPasswords no"
    printf '%s\n' "X11Forwarding no"
    printf '%s\n' "PermitRootLogin prohibit-password"
    printf '%s\n' "ClientAliveInterval 300"
    printf '%s\n' "ClientAliveCountMax 2"
}

supports_sshd_config_d() {
    conf_file="$1"
    conf_dir="$2"
    [ -d "$conf_dir" ] || return 1
    [ -f "$conf_file" ] || return 1
    awk -v dir="$conf_dir" '
        /^[[:space:]]*#/ { next }
        {
            first = $1
            lower = tolower(first)
            if (lower == "include") {
                for (i = 2; i <= NF; i++) {
                    if ($i == dir "/*.conf" || $i ~ /sshd_config\.d\/\*\.conf$/) {
                        found = 1
                    }
                }
            }
        }
        END { exit found ? 0 : 1 }
    ' "$conf_file"
}

write_managed_block_to_main() {
    block_file="$1"
    [ -n "$block_file" ] || return 1
    tmp_file=$(make_tmp_file "sshd_config")
    [ -n "$tmp_file" ] || return 1
    [ -n "$SSH_CONFIG" ] || return 1
    awk -v begin="$BLOCK_BEGIN" -v end="$BLOCK_END" -v block="$block_file" '
        function print_block() {
            print begin
            while ((getline line < block) > 0) {
                print line
            }
            close(block)
            print end
        }
        BEGIN {
            print_block()
            print ""
        }
        $0 == begin { skip = 1; next }
        $0 == end { skip = 0; next }
        skip == 1 { next }
        { print }
    ' "$SSH_CONFIG" > "$tmp_file" || return 1
    mv "$tmp_file" "$SSH_CONFIG" || return 1
    return 0
}

write_ssh_hardening_config() {
    block_file=$(make_tmp_file "hardening")
    build_hardening_block "$SSH_PORT" > "$block_file" || return 1

    if supports_sshd_config_d "$SSH_CONFIG" "$SSH_CONFIG_D"; then
        mkdir -p "$SSH_CONFIG_D" || return 1
        {
            printf '%s\n' "# Managed by ike-ssh-init. Backup: $BACKUP_DIR"
            cat "$block_file"
        } > "$SSHD_FRAGMENT" || return 1
        chmod 644 "$SSHD_FRAGMENT" 2>/dev/null || true
        info "已写入 SSH 配置片段: $SSHD_FRAGMENT"
        return 0
    fi

    [ -f "$SSH_CONFIG" ] || return 1
    write_managed_block_to_main "$block_file" || return 1
    info "已写入 sshd_config 托管配置块: $SSH_CONFIG"
    return 0
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

ensure_run_sshd_dir() {
    [ -n "$RUN_SSHD_DIR" ] || return 1
    if [ -L "$RUN_SSHD_DIR" ]; then
        return 1
    fi
    if [ ! -d "$RUN_SSHD_DIR" ]; then
        mkdir -p "$RUN_SSHD_DIR" || return 1
    fi
    chmod 755 "$RUN_SSHD_DIR" || return 1
    return 0
}

validate_sshd_config() {
    ensure_run_sshd_dir || return 1
    sshd_bin=$(find_sshd_bin 2>/dev/null || true)
    [ -n "$sshd_bin" ] || return 1
    "$sshd_bin" -t
}

reload_sshd_service() {
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
    if command -v systemctl >/dev/null 2>&1; then
        systemctl reload ssh >/dev/null 2>&1 && return 0
        systemctl reload sshd >/dev/null 2>&1 && return 0
    fi
    if command -v service >/dev/null 2>&1; then
        service ssh reload >/dev/null 2>&1 && return 0
        service sshd reload >/dev/null 2>&1 && return 0
    fi
    if command -v rc-service >/dev/null 2>&1; then
        rc-service ssh reload >/dev/null 2>&1 && return 0
        rc-service sshd reload >/dev/null 2>&1 && return 0
    fi
    return 1
}

find_port_listener_lines() {
    port="$1"
    [ -n "$port" ] || return 1
    pattern=":$port"

    if command -v ss >/dev/null 2>&1; then
        ss -ltnp 2>/dev/null | awk -v p="$pattern" '
            $1 == "LISTEN" {
                local_addr = $4
                if (local_addr == p || local_addr ~ p "$") {
                    print
                    found = 1
                }
            }
            END { exit found ? 0 : 1 }
        '
        return $?
    fi

    if command -v netstat >/dev/null 2>&1; then
        netstat -ltnp 2>/dev/null | awk -v p="$pattern" '
            $0 ~ /LISTEN/ {
                local_addr = $4
                if (local_addr == p || local_addr ~ p "$") {
                    print
                    found = 1
                }
            }
            END { exit found ? 0 : 1 }
        '
        return $?
    fi

    return 2
}

read_ssh_banner() {
    port="$1"
    [ -n "$port" ] || return 1
    if command -v nc >/dev/null 2>&1; then
        banner=$(printf '\n' | nc -w 2 127.0.0.1 "$port" 2>/dev/null | sed -n '1p')
        case "$banner" in
            SSH-2.0*)
                return 0
                ;;
        esac
    fi
    return 1
}

check_ssh_port_listening() {
    port="$1"
    rc=0
    lines=$(find_port_listener_lines "$port" 2>/dev/null) || rc=$?
    if [ "$rc" -eq 0 ]; then
        if printf '%s\n' "$lines" | grep -qi "sshd"; then
            return 0
        fi
        read_ssh_banner "$port" && return 0
        return 1
    fi
    if read_ssh_banner "$port"; then
        return 0
    fi
    if [ "$rc" -eq 2 ]; then
        return 2
    fi
    return 1
}

preflight_port_available() {
    port="$1"
    rc=0
    lines=$(find_port_listener_lines "$port" 2>/dev/null) || rc=$?
    if [ "$rc" -eq 0 ]; then
        if [ "$DRY_RUN" -eq 1 ]; then
            warn "[DRY-RUN] 目标端口 $port 已被监听，正式执行会退出。占用信息:"
            printf '%s\n' "$lines" >&2
            return 0
        fi
        warn "目标端口 $port 已被监听，请更换端口。占用信息:"
        printf '%s\n' "$lines" >&2
        return 1
    fi
    if [ "$rc" -eq 2 ]; then
        if [ "$DRY_RUN" -eq 1 ]; then
            warn "[DRY-RUN] 未找到 ss/netstat，无法预检查端口 $port 是否被占用。"
            return 0
        fi
        if [ "$STRICT_MODE" -eq 1 ]; then
            warn "strict 模式下未找到 ss/netstat，无法预检查端口 $port。"
            return 1
        fi
        warn "未找到 ss/netstat，无法预检查端口 $port 是否被占用。"
    fi
    return 0
}

wait_for_ssh_port() {
    port="$1"
    limit=${WAIT_SSH_PORT_SECONDS:-10}
    interval=${WAIT_SSH_PORT_INTERVAL:-1}
    i=0
    last_rc=1
    while [ "$i" -lt "$limit" ]; do
        last_rc=0
        check_ssh_port_listening "$port" || last_rc=$?
        if [ "$last_rc" -eq 0 ]; then
            return 0
        fi
        i=$((i + 1))
        sleep "$interval"
    done
    if [ "$last_rc" -eq 2 ]; then
        return 2
    fi
    return 1
}

check_ssh_port_after_reload() {
    rc=0
    wait_for_ssh_port "$SSH_PORT" || rc=$?
    case "$rc" in
        0)
            return 0
            ;;
        2)
            if [ "$STRICT_MODE" -eq 1 ]; then
                return 1
            fi
            warn "未找到 ss/netstat/nc，无法自动确认 SSH 新端口监听状态；请手动检查 $SSH_PORT/tcp。"
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

configure_firewall() {
    if [ "$FIREWALL_MODE" = "none" ]; then
        info "已按 --no-firewall 跳过本机防火墙修改。请确认云厂商安全组已放行 $SSH_PORT/tcp。"
        return 0
    fi

    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi "Status: active"; then
        ufw allow "$SSH_PORT/tcp" || return 1
        info "ufw 已放行 $SSH_PORT/tcp"
        return 0
    fi

    if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        firewall-cmd --add-port="$SSH_PORT/tcp" >/dev/null 2>&1 || return 1
        firewall-cmd --add-port="$SSH_PORT/tcp" --permanent >/dev/null 2>&1 || return 1
        firewall-cmd --reload >/dev/null 2>&1 || return 1
        info "firewalld 已放行 $SSH_PORT/tcp"
        return 0
    fi

    info "未检测到已启用的 ufw/firewalld。本脚本无法自动修改云厂商安全组，请手动放行 $SSH_PORT/tcp。"
    return 0
}

collect_public_keys() {
    raw_file=$(make_tmp_file "keys.raw")
    valid_file=$(make_tmp_file "keys.valid")

    if [ -n "$KEY_RAW" ]; then
        printf '%s\n' "$KEY_RAW" > "$raw_file" || return 1
    elif [ -n "$KEY_GH" ]; then
        fetch_github_keys "$KEY_GH" "$raw_file" || return 1
    else
        : > "$raw_file" || return 1
    fi

    key_count=$(filter_valid_keys "$raw_file" "$valid_file" || printf '%s\n' "0")
    if [ "$key_count" -lt 1 ]; then
        return 1
    fi
    VALID_KEYS_FILE="$valid_file"
    info "有效公钥数量: $key_count"
    return 0
}

print_plan() {
    prefix=""
    if [ "$DRY_RUN" -eq 1 ]; then
        prefix="[DRY-RUN] "
    fi
    info "${prefix}计划操作:"
    info "${prefix}系统检测: $OS_NAME"
    info "${prefix}登录用户: $TARGET_USER"
    info "${prefix}SSH 端口: $SSH_PORT"
    if [ -n "$KEY_RAW" ]; then
        info "${prefix}公钥来源: --key-raw"
    elif [ -n "$KEY_GH" ]; then
        info "${prefix}公钥来源: GitHub $KEY_GH"
    else
        info "${prefix}公钥来源: 未提供"
    fi
    if [ "$SUDO_NOPASSWD" -eq 1 ]; then
        info "${prefix}sudo: NOPASSWD"
    else
        info "${prefix}sudo: 需要密码"
    fi
    if [ "$FIREWALL_MODE" = "none" ]; then
        info "${prefix}本机防火墙: 不修改"
    else
        info "${prefix}本机防火墙: auto 检测 ufw/firewalld"
    fi
    info "${prefix}将备份: $SSH_CONFIG, $SSH_CONFIG_D, $SUDOERS_D"
    info "${prefix}不会执行系统 update/upgrade，不会安装 Docker，不会配置 BBR/WARP/DD/站点/SSL。"
}

prompt_default() {
    prompt="$1"
    default="$2"
    printf '%s' "$prompt"
    IFS= read -r answer
    if [ -z "$answer" ]; then
        answer="$default"
    fi
    printf '%s\n' "$answer"
}

interactive_prompts() {
    info "进入中文交互模式。"
    TARGET_USER=$(prompt_default "登录用户 [deploy]: " "deploy")
    SSH_PORT=$(prompt_default "SSH 端口 [2222]: " "2222")

    info "公钥来源:"
    info "  1) GitHub"
    info "  2) 手动粘贴"
    key_choice=$(prompt_default "请选择 [1]: " "1")
    case "$key_choice" in
        1)
            info "允许的 GitHub 用户白名单: $ALLOWED_GH_USERS"
            KEY_GH=$(prompt_default "GitHub 用户名: " "")
            ;;
        2)
            KEY_RAW=$(prompt_default "请粘贴 SSH 公钥: " "")
            ;;
        *)
            die "无效的公钥来源选择"
            ;;
    esac

    sudo_choice=$(prompt_default "是否配置 NOPASSWD sudo? [y/N]: " "n")
    case "$sudo_choice" in
        y|Y|yes|YES)
            SUDO_NOPASSWD=1
            ;;
        *)
            SUDO_NOPASSWD=0
            ;;
    esac

    fw_choice=$(prompt_default "是否修改本机防火墙? [Y/n]: " "y")
    case "$fw_choice" in
        n|N|no|NO)
            FIREWALL_MODE="none"
            ;;
        *)
            FIREWALL_MODE="auto"
            ;;
    esac
}

confirm_or_exit() {
    if [ "$YES_MODE" -eq 1 ]; then
        return 0
    fi
    print_plan
    info "注意: 脚本无法自动修改云厂商安全组，请先确认目标端口已放行。"
    printf '%s' "确认执行? 输入 yes 继续: "
    IFS= read -r answer
    if [ "$answer" != "yes" ]; then
        die "已取消"
    fi
}

should_warn_new_user_sudo_password() {
    [ "$USER_CREATED" -eq 1 ] && [ "$SUDO_NOPASSWD" -eq 0 ]
}

post_success_message() {
    info ""
    info "================ 完成 ================"
    info "新 SSH 登录命令:"
    info "ssh -i ~/.ssh/id_ed25519 -p $SSH_PORT $TARGET_USER@SERVER_IP"
    info ""
    info "请不要关闭当前 SSH 窗口。"
    info "请新开终端测试登录。"
    info "请确认 sudo 可用。"
    if should_warn_new_user_sudo_password; then
        info "重要: 当前新建用户 sudo 需要密码，请先在当前 root 窗口执行 passwd $TARGET_USER。"
    fi
    info "请确认云厂商安全组已放行 $SSH_PORT/tcp。"
    info "脚本无法自动修改云厂商安全组。"
    if [ -n "$BACKUP_DIR" ]; then
        info "如果无法登录，可通过以下命令恢复:"
        info "sh $BACKUP_DIR/restore.sh"
        info "回滚需要 root 权限；普通用户不能执行 /root/init.sh --rollback-last。"
        info "如普通用户仍有 sudo 权限，也可执行: sudo sh $BACKUP_DIR/restore.sh"
    fi
}

main() {
    init_defaults
    parse_args "$@" || exit 1
    require_root
    make_tmp_dir

    if [ "$ROLLBACK_LAST" -eq 1 ]; then
        rollback_last
        return 0
    fi

    if [ "$ARG_COUNT" -eq 0 ]; then
        interactive_prompts
    fi

    detect_os
    is_valid_username "$TARGET_USER" || die "用户名无效: $TARGET_USER"
    validate_port "$SSH_PORT" || die "端口必须为 1024-65535，且不能使用常见服务端口"
    validate_key_source_args

    if [ "$DRY_RUN" -eq 1 ]; then
        print_plan
        preflight_port_available "$SSH_PORT" || true
        info "[DRY-RUN] 不创建用户，不写 authorized_keys，不写 SSH 配置，不写 sudoers，不修改防火墙，不重启 SSH。"
        return 0
    fi

    confirm_or_exit
    print_plan

    preflight_port_available "$SSH_PORT" || die "目标端口已被占用，已停止，未创建备份或修改系统"
    create_backup || die "备份失败，已停止，未继续修改系统"

    collect_public_keys || {
        if [ "$STRICT_MODE" -eq 1 ]; then
            die "strict 模式下没有有效公钥，拒绝继续禁用密码登录"
        fi
        die "没有有效公钥，拒绝继续禁用密码登录"
    }

    ensure_user "$TARGET_USER" || rollback_or_die "用户创建或 shell 配置失败，开始回滚"
    deploy_authorized_keys "$TARGET_USER" "$VALID_KEYS_FILE" || rollback_or_die "authorized_keys 安全检查或写入失败，开始回滚"
    configure_sudoers "$TARGET_USER" "$SUDO_NOPASSWD" || rollback_or_die "sudoers 写入或 visudo 校验失败，开始回滚"
    write_ssh_hardening_config || rollback_or_die "SSH 配置写入失败，开始回滚"
    validate_sshd_config || rollback_or_die "sshd -t 校验失败，开始回滚"
    configure_firewall || rollback_or_die "本机防火墙配置失败，开始回滚"
    reload_sshd_service || rollback_or_die "SSH reload/restart 失败，开始回滚"
    check_ssh_port_after_reload || rollback_or_die "SSH 新端口未处于监听状态，开始回滚"

    post_success_message
    return 0
}

init_defaults

if [ "${IKE_TEST_MODE:-0}" != "1" ]; then
    main "$@"
fi
