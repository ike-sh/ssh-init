#!/bin/sh

# ssh-init v0.5.8: configure SSH key login and disable password login.
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
SSHD_EFFECTIVE_KEYS_RE='^(pubkeyauthentication|passwordauthentication|kbdinteractiveauthentication|challengeresponseauthentication|permitemptypasswords|permitrootlogin|authenticationmethods|authorizedkeysfile|authorizedkeyscommand|pubkeyacceptedalgorithms|pubkeyacceptedkeytypes|allowusers|denyusers|allowgroups|denygroups) '
SSHD_SOURCE_GREP_RE='^[[:space:]]*(Include|PasswordAuthentication|KbdInteractiveAuthentication|ChallengeResponseAuthentication|PermitEmptyPasswords|PermitRootLogin|PubkeyAuthentication|AuthenticationMethods|AuthorizedKeysFile|AuthorizedKeysCommand|PubkeyAcceptedAlgorithms|PubkeyAcceptedKeyTypes|AllowUsers|DenyUsers|AllowGroups|DenyGroups|Match)([[:space:]=]|$)'

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

# 0 = immutable, 1 = clear or unavailable on this filesystem, 2 = probe error.
# Never treat a transient read error as permission to remove a real +i flag.
is_immutable_file() (
    [ -e "$1" ] || return 1
    command_exists lsattr || return 1
    if attrs=$(LC_ALL=C lsattr -d "$1" 2>&1); then
        attrs=${attrs%%[[:space:]]*}
        case "$attrs" in *i*) return 0 ;; *-*) return 1 ;; esac
    else
        case "$attrs" in *'Operation not supported'*|*'Inappropriate ioctl for device'*|*'Function not implemented'*) return 1 ;; esac
    fi
    error "无法读取 immutable 状态: $1 ($attrs)"; return 2
)

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
            error "恢复 $file immutable 锁定状态失败，请手动执行: chattr +i $file"
            return 1
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

# The owning shell alone changes TX_ACTIVE and owns fd 9. Never run a transaction
# in a command substitution. The private journal stores data, not shell code.
TX_ACTIVE=0
TX_ROLLING=0
TX_LOCAL_STATE=''
TX_LOCKED=0
TX_STATE=''
TX_DIR=''
TX_OWNER=''
TX_FLOCK=0

# Linux stat is provided by both coreutils and BusyBox. Reject symlink ancestors
# rather than snapshot one object and later replace another through a link.
tx_safe_path() (
    case "$1" in /*) ;; *) return 1 ;; esac
    case "$1/" in *'/../'*|*'/./'*|*'//'*|*'
'*) return 1 ;; esac
    p=$1
    while [ -n "$p" ]; do
        ! is_symlink_path "$p" || { error "拒绝操作符号链接: $p"; return 1; }
        p=${p%/*}
    done
)

# Each acquisition reserves a distinct directory on the state filesystem. The
# public gate is ONE symlink; it is never visible without its owner identity.
tx_lock_owner_dir() (
    umask 077
    if command_exists mktemp; then mktemp -d "$1/.owner.$$.XXXXXX"; return $?; fi
    n=0
    while [ "$n" -lt 100 ]; do
        candidate=$1/.owner.$$.$n
        if mkdir "$candidate" 2>/dev/null; then printf '%s\n' "$candidate"; return $?; fi
        n=$((n + 1))
    done
    return 1
)

tx_lock_pid_dead() {
    [ -d /proc/self ] && ! kill -0 "$1" 2>/dev/null && [ ! -d "/proc/$1" ]
}

tx_lock_reap() (
    gate=$1/lock
    old=$(readlink "$gate") || return 1
    name=${old##*/}
    [ "$old" = "$1/$name" ] && [ -d "$old" ] && [ ! -L "$old" ] || return 1
    case "$name" in .owner.*.*) ;; *) return 1 ;; esac
    fields=${name#.owner.}; pid=${fields%%.*}; nonce=${fields#*.}
    case "$pid" in ''|0|*[!0-9]*) return 1 ;; esac
    case "$nonce" in ''|*[!a-zA-Z0-9]*) return 1 ;; esac
    tx_lock_pid_dead "$pid" || return 1
    # Serialize reapers of THIS generation only. A reaper killed between claim
    # and unlink leaves an identifiable claim; never guess that it is safe to
    # remove an unknown gate. The next operator can inspect lock and reaper.
    ln -sT "$2" "$old/reaper" 2>/dev/null || return 1
    reap_rc=1
    if [ "$(readlink "$gate")" = "$old" ] && tx_lock_pid_dead "$pid" && rm "$gate"; then
        reap_rc=0; warn '已清理退出进程留下的写锁。'
    fi
    rm "$old/reaper" || return 1
    if [ "$reap_rc" = 0 ]; then rmdir "$old" 2>/dev/null || :; fi
    return "$reap_rc"
)

tx_lock() {
    if [ -n "$TX_OWNER" ] || [ "$TX_LOCKED" != 0 ]; then error '上次写锁尚未释放。'; return 1; fi
    command_exists readlink || { error '写锁需要 readlink；未获取锁。'; return 1; }
    TX_STATE=${TX_LOCAL_STATE:-$SSH_CONFIG.ssh-init.d}
    tx_safe_path "$TX_STATE" || return 1
    (umask 077; mkdir "$TX_STATE") 2>/dev/null || [ -d "$TX_STATE" ] || return 1
    [ "$(stat -c '%u:%a' "$TX_STATE")" = "$(id -u):700" ] || {
        error "事务目录必须归当前用户所有且权限为 700: $TX_STATE"; return 1;
    }
    if command_exists flock; then
        tx_safe_path "$TX_STATE/lockfile" || return 1
        exec 9>>"$TX_STATE/lockfile"
        if ! flock -n 9; then exec 9>&-; error '另一个 ssh-init 写操作正在运行。'; return 1; fi
        TX_FLOCK=1
    fi
    TX_OWNER=$(tx_lock_owner_dir "$TX_STATE") || { tx_unlock; return 1; }
    # -T means a contender cannot accidentally create a link inside the live
    # owner's directory. Both backends use this same atomic acquisition.
    if ! ln -sT "$TX_OWNER" "$TX_STATE/lock" 2>/dev/null; then
        if ! tx_lock_reap "$TX_STATE" "$TX_OWNER" || ! ln -sT "$TX_OWNER" "$TX_STATE/lock" 2>/dev/null; then
            error "写锁占用或无法确认归属: $TX_STATE/lock；如有残留，请从 Console 核对 owner/reaper，不要删除活动锁。"
            tx_unlock; return 1
        fi
    fi
    TX_LOCKED=1
    TX_DIR=$TX_STATE/pending
}

tx_unlock() {
    tx_unlock_rc=0
    if [ -n "$TX_OWNER" ]; then
        # Also handles TERM after successful ln but before TX_LOCKED=1. Never
        # unlink a successor's gate, even after an interrupted release.
        if [ -L "$TX_STATE/lock" ]; then
            if tx_unlock_owner=$(readlink "$TX_STATE/lock"); then
                if [ "$tx_unlock_owner" = "$TX_OWNER" ]; then rm "$TX_STATE/lock" || tx_unlock_rc=1; fi
            else
                # It may have been released by the holder while we were a contender.
                if [ "$TX_LOCKED" = 1 ] || [ -L "$TX_STATE/lock" ]; then tx_unlock_rc=1; fi
            fi
        elif [ "$TX_LOCKED" = 1 ]; then
            # lstat may have failed: keep the private directory intact.
            tx_unlock_rc=1
        fi
        if [ "$tx_unlock_rc" = 0 ]; then
            rmdir "$TX_OWNER" 2>/dev/null || warn "私有锁目录清理失败（已不持有写锁）: $TX_OWNER"
            TX_OWNER=''; TX_LOCKED=0
        fi
    fi
    if [ "$TX_FLOCK" = 1 ]; then exec 9>&-; TX_FLOCK=0; fi
    [ "$tx_unlock_rc" = 0 ] || { error "未能确认释放自己的写锁: $TX_STATE/lock"; return 1; }
}

tx_metadata() (
    if [ ! -e "$1" ]; then printf 'absent\n'; return $?; fi
    m=$(stat -c '%a %u %g' "$1") || return 1
    i=0; if is_immutable_file "$1"; then i=1; else [ "$?" = 1 ] || return 1; fi
    printf '%s %s\n' "$m" "$i"
)

# cp -p is the portable floor. GNU cp can also preserve extended attributes
# (including ACLs); request xattr explicitly so failure isn't ignored as with
# --preserve=all. Do not copy a labeled file with an unlabeled-only backend.
tx_copy_file() (
    if LC_ALL=C cp --help 2>&1 | grep -q 'xattr'; then
        attrs=mode,ownership,timestamps,xattr
        if [ -e /sys/fs/selinux/enforce ]; then attrs=$attrs,context; fi
        cp --preserve="$attrs" "$1" "$2"
    elif [ -e /sys/fs/selinux/enforce ]; then
        error '当前 cp 无法保留 SELinux 文件上下文，停止替换。'; return 1
    else
        cp -p "$1" "$2"
    fi
)

tx_snapshot() (
    [ -n "$2" ] || return 0
    tx_safe_path "$2" || return 1
    if [ -e "$2" ]; then
        case "$1" in sshdir) [ -d "$2" ] ;; *) [ -f "$2" ] ;; esac || return 1
    fi
    printf '%s\n' "$2" > "$TX_DIR/$1.path" && tx_metadata "$2" > "$TX_DIR/$1.meta" || return 1
    if [ "$1" != sshdir ] && [ -f "$2" ]; then tx_copy_file "$2" "$TX_DIR/$1.data" || return 1; fi
)

tx_set_immutable() (
    [ -e "$1" ] || return 0
    if is_immutable_file "$1"; then have=1; else [ "$?" = 1 ] || return 1; have=0; fi
    [ "$have" != "$2" ] || return 0
    case "$2" in 0) chattr -i "$1" ;; 1) chattr +i "$1" ;; *) return 1 ;; esac || return 1
    if is_immutable_file "$1"; then [ "$2" = 1 ]; else [ "$?" = 1 ] && [ "$2" = 0 ]; fi
)

tx_begin() {
    [ "$TX_LOCKED" = 1 ] && [ "$TX_ACTIVE" = 0 ] || return 1
    mkdir "$TX_DIR" || return 1
    tx_snapshot main "$1" && tx_snapshot drop "$2" && tx_snapshot other "${4:-}" || return 1
    if [ -n "$3" ]; then
        tx_snapshot sshdir "${3%/*}" && tx_snapshot auth "$3" || return 1
    fi
    if [ -n "$1" ]; then
        if ! ssh_service_snapshot 9>&- > "$TX_DIR/service" || [ ! -s "$TX_DIR/service" ]; then
            error '无法确认 SSH 服务初始状态；未修改文件。'; return 1
        fi
    fi
    # No protected file is changed until the complete rollback record is ready.
    for tx_s in main drop other sshdir auth; do
        if [ -f "$TX_DIR/$tx_s.path" ]; then printf '%s\n' "$tx_s" || return 1; fi
    done > "$TX_DIR/slots" || return 1
    : > "$TX_DIR/active" || return 1
    TX_ACTIVE=1
    sync || return 1
    for tx_s in sshdir auth main drop other; do
        [ -f "$TX_DIR/$tx_s.path" ] || continue
        IFS= read -r tx_p < "$TX_DIR/$tx_s.path" || return 1
        case "$(cat "$TX_DIR/$tx_s.meta")" in
            *' 1') warn "临时解除 immutable: $tx_p（不会修改 Port）"; tx_set_immutable "$tx_p" 0 || return 1 ;;
        esac
    done
}

tx_stage_path() {
    SSHD_CONFIG_TMP_FILE=$(make_sshd_config_tmp_file "$1") || return 1
    if [ "$TX_ACTIVE" = 1 ]; then
        printf '%s\n' "$SSHD_CONFIG_TMP_FILE" >> "$TX_DIR/stage" || return 1
    fi
}

tx_install() {
    [ -f "$1" ] && [ ! -L "$1" ] && tx_safe_path "$2" || return 1
    [ ! -e "$2" ] || [ -f "$2" ] || return 1
    tx_it_slot=$(tx_slot_for "$2") && tx_touch "$tx_it_slot" || return 1
    tx_stage_path "$2" && tx_copy_file "$1" "$SSHD_CONFIG_TMP_FILE" &&
        mv -f "$SSHD_CONFIG_TMP_FILE" "$2" || return 1
    SSHD_CONFIG_TMP_FILE=''
}

# Compare bytes, mode and numeric ownership. Deliberately ignore timestamps.
tx_same() (
    IFS= read -r dest < "$1/$2.path" && IFS= read -r meta < "$1/$2.meta" || return 1
    tx_safe_path "$dest" || return 1
    if [ "$meta" = absent ]; then [ ! -e "$dest" ]; return $?; fi
    [ "$(stat -c '%a %u %g' "$dest" 2>/dev/null)" = "${meta% *}" ] || return 1
    if [ "$2" = sshdir ]; then [ -d "$dest" ]; else [ -f "$dest" ] && cmp -s "$dest" "$1/$2.data"; fi
)

tx_touch() {
    [ "${TX_ROLLING:-0}" != 1 ] || return 0
    [ -f "$TX_DIR/$1.dirty" ] && return 0
    tx_same "$TX_DIR" "$1" || { error "文件已被其他程序修改，停止写入: $(cat "$TX_DIR/$1.path")"; return 1; }
    : > "$TX_DIR/$1.dirty" && { sync -f "$TX_DIR" 2>/dev/null || sync; }
}

# Resolve destination against the active journal, not the names in a historical
# batch (the two drop-in slots can refer to different Include directories).
tx_slot_for() (
    for slot in main drop auth other sshdir; do
        [ -f "$TX_DIR/$slot.path" ] || continue
        IFS= read -r slot_path < "$TX_DIR/$slot.path" || return 1
        if [ "$slot_path" = "$1" ]; then printf '%s\n' "$slot"; return 0; fi
    done
    return 1
)

tx_restore_slot() {
    # Isolate parsed fields from the rest of the transaction. tx_install's
    # staging path is also persisted on disk, so it survives this subshell.
    ( tx_restore_one "$1" "$2" )
}

tx_restore_one() {
    IFS= read -r dest < "$1/$2.path" && IFS= read -r meta < "$1/$2.meta" || return 1
    tx_safe_path "$dest" || return 1
    imm=0
    if [ "$meta" != absent ]; then
        imm=${meta##* }
        # Metadata never becomes shell syntax or a path.
        printf '%s\n' "$meta" | grep -Eq '^[0-7]{1,4} [0-9]+ [0-9]+ [01]$' || return 1
    fi
    dest_slot=$(tx_slot_for "$dest") && tx_touch "$dest_slot" || return 1
    if ! tx_same "$1" "$2"; then
        tx_set_immutable "$dest" 0 || return 1
        if [ "$meta" = absent ]; then
            if [ "$2" = sshdir ]; then
                if [ "${IKE_TEST_MODE:-0}" = 1 ]; then rm -f "$dest/.ssh-init-mode" "$dest/authorized_keys.ssh-init-mode"; fi
                rmdir "$dest" || return 1
            else
                [ ! -d "$dest" ] && rm -f "$dest" || return 1
            fi
        elif [ "$2" = sshdir ]; then
            [ -d "$dest" ] || (umask 077; mkdir "$dest") || return 1
            set -- $meta
            if [ "$(stat -c '%u:%g' "$dest")" != "$2:$3" ]; then chown "$2:$3" "$dest" || return 1; fi
            chmod "$1" "$dest" || return 1
        else
            if [ ! -d "${dest%/*}" ]; then
                [ "$2" = auth ] && [ "$(cat "$1/sshdir.path")" = "${dest%/*}" ] &&
                    (umask 077; mkdir "${dest%/*}") || return 1
            fi
            tx_install "$1/$2.data" "$dest" || return 1
            if [ "$(stat -c '%a %u %g' "$dest")" != "${meta% *}" ]; then
                set -- $meta
                chown "$2:$3" "$dest" && chmod "$1" "$dest" || return 1
            fi
        fi
    fi
    # Batch restore may intentionally restore *different* immutable metadata.
    # Directory immutable must be set last, after child files are installed.
    printf '%s\n' "$imm" > "$TX_DIR/$dest_slot.want-imm" || return 1
    tx_set_immutable "$dest" "$imm"
}

tx_apply_service() {
    : > "$TX_DIR/service-touched" && sync || return 1
    IFS= read -r tx_service < "$TX_DIR/service" || return 1
    restart_ssh_service "$tx_service" 9>&-
}

tx_clean_stage() (
    [ -f "$TX_DIR/stage" ] || return 0
    while IFS= read -r stage; do
        [ -n "$stage" ] || continue
        matched=0
        for slot in auth main drop other; do
            [ -f "$TX_DIR/$slot.path" ] || continue
            IFS= read -r dest < "$TX_DIR/$slot.path" || return 1
            case "$stage" in "${dest%/*}/.${dest##*/}.ssh-init."*) matched=1; break ;; esac
        done
        if [ "$matched" != 1 ] || ! tx_safe_path "$stage"; then error "无法确认暂存文件归属: $stage"; return 1; fi
        rm -f "$stage" || return 1
    done < "$TX_DIR/stage"
)

tx_rollback() {
    [ "$TX_ACTIVE" = 1 ] && [ "${TX_ROLLING:-0}" != 1 ] || return 0
    TX_ROLLING=1
    tx_failed=0
    tx_clean_stage || warn "无法清理部分暂存文件；仍将优先恢复原文件和服务。"
    if [ ! -s "$TX_DIR/slots" ]; then error '事务清单缺失。'; tx_failed=1; fi
    for tx_s in main drop other sshdir auth; do
        if grep -qx "$tx_s" "$TX_DIR/slots" && { [ ! -s "$TX_DIR/$tx_s.path" ] || [ ! -s "$TX_DIR/$tx_s.meta" ]; }; then
            error "事务快照缺失: $tx_s"; tx_failed=1
        fi
    done
    if [ -f "$TX_DIR/sshdir.path" ]; then
        IFS= read -r tx_parent < "$TX_DIR/sshdir.path" && tx_safe_path "$tx_parent" &&
            tx_set_immutable "$tx_parent" 0 || tx_failed=1
    fi
    for tx_s in auth other drop main sshdir; do
        [ -f "$TX_DIR/$tx_s.path" ] || continue
        if [ ! -f "$TX_DIR/$tx_s.dirty" ]; then
            # Unlocking for snapshot application may itself need undoing.
            if IFS= read -r tx_m < "$TX_DIR/$tx_s.meta" && IFS= read -r tx_p < "$TX_DIR/$tx_s.path"; then
                case "$tx_m" in *" 1") tx_safe_path "$tx_p" && tx_set_immutable "$tx_p" 1 || tx_failed=1 ;; esac
            else tx_failed=1; fi
            continue
        fi
        if ! tx_restore_slot "$TX_DIR" "$tx_s"; then
            error "回滚失败: $(cat "$TX_DIR/$tx_s.path")"; tx_failed=1
        fi
    done
    if [ -f "$TX_DIR/service-touched" ]; then
        tx_config_ok=0
        if grep -qx main "$TX_DIR/slots" && tx_same "$TX_DIR" main; then tx_config_ok=1; fi
        for tx_s in drop other; do
            if grep -qx "$tx_s" "$TX_DIR/slots" && ! tx_same "$TX_DIR" "$tx_s"; then tx_config_ok=0; fi
        done
        if [ "$tx_config_ok" != 1 ] || ! validate_sshd_config || ! IFS= read -r tx_service < "$TX_DIR/service" ||
            ! ssh_service_restore "$tx_service" 9>&-; then
            error '回滚后未能确认 SSH 服务恢复；请通过 VNC/Console 检查。'; tx_failed=1
        fi
    fi
    TX_ROLLING=0
    TX_ACTIVE=0
    if [ "$tx_failed" = 0 ]; then
        if ! sync || ! mv "$TX_DIR" "$TX_STATE/discard" || ! rm -rf "$TX_STATE/discard"; then
            error "回滚后清理事务记录失败: $TX_STATE"; return 1
        fi
        warn '已按快照恢复本次操作前的状态。'
    else
        error "未完整回滚；原始快照保留在 $TX_DIR。"; return 1
    fi
}

tx_commit() {
    tx_changed=0
    tx_clean_stage || return 1
    for tx_s in auth main drop other sshdir; do
        [ -f "$TX_DIR/$tx_s.path" ] || continue
        IFS= read -r tx_p < "$TX_DIR/$tx_s.path" && IFS= read -r tx_m < "$TX_DIR/$tx_s.meta" || return 1
        tx_imm=0; case "$tx_m" in *' 1') tx_imm=1 ;; esac
        tx_want="$TX_DIR/$tx_s.want-imm"
        if [ -f "$tx_want" ]; then IFS= read -r tx_imm < "$tx_want" || return 1; fi
        tx_safe_path "$tx_p" && tx_set_immutable "$tx_p" "$tx_imm" || return 1
        tx_current_meta=$(tx_metadata "$tx_p") || return 1
        if ! tx_same "$TX_DIR" "$tx_s" || [ "$tx_current_meta" != "$tx_m" ]; then tx_changed=1; fi
    done
    sync || return 1
    if [ "$tx_changed" = 1 ]; then
        tx_seq=0
        for tx_b in "$TX_STATE"/batch.*; do
            [ -d "$tx_b" ] || continue
            tx_num=${tx_b##*.}; case "$tx_num" in *[!0-9]*|'') continue ;; esac
            tx_num=$(printf '%s\n' "$tx_num" | sed 's/^0*//'); [ "${tx_num:-0}" -le "$tx_seq" ] || tx_seq=$tx_num
        done
        tx_batch=$(printf '%s/batch.%012d' "$TX_STATE" "$((tx_seq + 1))") || return 1
        [ ! -e "$tx_batch" ] && [ ! -L "$tx_batch" ] && mv "$TX_DIR" "$tx_batch" || return 1
        TX_ACTIVE=0
        sync || { error "批次已提交但持久化失败，请检查 $tx_batch"; return 1; }
        info "恢复批次: $tx_batch"
    else
        # Atomic retirement before deletion: an interrupt must never replay
        # a half-deleted journal. Same rule as publication of a changed batch.
        mv "$TX_DIR" "$TX_STATE/discard" || return 1
        TX_ACTIVE=0
        rm -rf "$TX_STATE/discard" || return 1
    fi
}

with_write_lock() {
    [ "$TX_LOCKED" = 0 ] || { error '拒绝嵌套写事务。'; return 1; }
    tx_lock || return 1
    if [ -d "$TX_DIR" ] && [ -f "$TX_DIR/active" ]; then
        warn "发现未完成事务 $TX_DIR；恢复会覆盖这些文件在中断后的人工修改。"
        if ! ask_prompt '输入 RECOVER 按快照回滚；其他输入退出:' || [ "$ASK_REPLY" != RECOVER ]; then
            tx_unlock; return 1
        fi
        TX_ACTIVE=1
        tx_rollback; tx_result=$?
        tx_unlock || return 1
        [ "$tx_result" != 0 ] || info '中断事务已恢复；如需新操作请重新执行。'
        return 1
    fi
    # Only unpublished preparation or already committed no-op debris.
    rm -rf "$TX_DIR" "$TX_STATE/discard" || { tx_unlock; return 1; }
    tx_result=0
    "$@" || tx_result=$?
    if [ "$TX_ACTIVE" = 1 ]; then
        if [ "$tx_result" = 0 ]; then tx_commit || tx_result=1; fi
        if [ "$tx_result" != 0 ]; then tx_rollback || tx_result=1; fi
    elif [ -d "$TX_DIR" ] && [ ! -f "$TX_DIR/active" ]; then
        rm -rf "$TX_DIR" || tx_result=1
    fi
    tx_unlock || tx_result=1
    return "$tx_result"
}

ssh_init_exit() {
    tx_exit_rc=$1
    trap - 0
    trap '' HUP INT TERM
    if [ "$TX_ACTIVE" = 1 ] && [ -f "$TX_DIR/active" ]; then tx_rollback || tx_exit_rc=1; fi
    tx_unlock || tx_exit_rc=1
    cleanup_tmp
    exit "$tx_exit_rc"
}
trap 'ssh_init_exit $?' 0
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

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
    # Prefer the same account database sshd uses (LDAP/NSS need not appear in
    # /etc/passwd). BusyBox installations without getent keep the local fallback.
    passwd_home=''
    if command_exists getent; then
        passwd_home=$(getent passwd "$user" | awk -F: -v u="$user" '$1 == u {print $6; exit}') || passwd_home=''
    fi
    if [ -z "$passwd_home" ]; then
        passwd_home=$(awk -F: -v u="$user" '$1 == u {print $6; exit}' /etc/passwd 2>/dev/null || true)
    fi
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

# Read the key type/blob only in their OpenSSH fields. A quoted option may
# contain spaces, escaped quotes, and even a complete *different* public key.
# Never scan the comment or the contents of command= for key-shaped text.
key_records() {
    key_record_mode=$1
    shift
    LC_ALL=C awk -v mode="$key_record_mode" '
        function keytype(s) {
            return s ~ /^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com)$/
        }
        function skip_options(s, i, c, quoted) {
            for (i = 1; i <= length(s); i++) {
                c = substr(s, i, 1)
                if (c == "\\" && substr(s, i + 1, 1) == "\"") i++
                else if (c == "\"") quoted = !quoted
                else if (!quoted && c ~ /[ \t]/) return substr(s, i + 1)
            }
            return ""
        }
        {
            line = $0
            sub(/\r$/, "", line)
            sub(/^[ \t]+/, "", line)
            if (line == "" || substr(line, 1, 1) == "#") next
            split(line, f, /[ \t]+/)
            has_options = mode == "existing" && !keytype(f[1])
            if (has_options) {
                line = skip_options(line)
                sub(/^[ \t]+/, "", line)
                split(line, f, /[ \t]+/)
            }
            if (!keytype(f[1]) || length(f[2]) < 20 || f[2] !~ /^[A-Za-z0-9+\/]+=*$/) {
                if (mode == "append") exit 2
                next
            }
            id = f[1] " " f[2]
            if (has_options) restricted[id] = 1
            if (mode == "append") {
                imports++
                if (restricted[id] && !warned++)
                    print "已沿用已有授权选项；from= 或强制命令等可能限制新连接，未验证实际登录。" >> "/dev/stderr"
            }
            if (seen[id]++) next
            if (mode != "existing") {
                sub(/^[^ \t]+[ \t]+[^ \t]+[ \t]*/, "", line)
                print id (line != "" ? " " line : "")
            }
        }
        END { if (mode == "append" && !imports) exit 2 }
    ' "$@"
}

# Status 1 means an invalid key; 2 means that validation itself failed.
validate_key_record() {
    if command_exists ssh-keygen; then
        key_tail=${1#* }
        printf '%s %s\n' "${1%% *}" "${key_tail%% *}" > "$2" || return 2
        ssh-keygen -l -f "$2" >/dev/null 2>&1 || return 1
    fi
    return 0
}

normalize_key_line() (
    key_normal=$(printf '%s\n' "$1" | key_records import) || exit 1
    [ -n "$key_normal" ] || exit 1
    key_check=$(make_tmp_file public-key) || exit 1
    trap 'rm -f "$key_check"' EXIT
    validate_key_record "$key_normal" "$key_check" || exit 1
    printf '%s\n' "$key_normal"
)

# Destinations here are scratch files (normally in the private TMP_DIR), not
# live authorized_keys. Rename a completed sibling; never truncate the caller's
# output on timeout, failed validation I/O, or a broken transfer.
key_safe_output() {
    case "$1" in /*) tx_safe_path "$1" ;; *) tx_safe_path "$PWD/${1#./}" ;; esac &&
        { [ ! -e "$1" ] || [ -f "$1" ]; }
}

key_scratch_stage() (
    key_safe_output "$1" || exit 1
    make_sshd_config_tmp_file "$1"
)

filter_valid_keys() (
    key_input=$1 key_output=$2 key_stage='' key_candidates='' key_check=''
    trap 'rm -f "${key_stage:-}" "${key_candidates:-}" "${key_check:-}"' EXIT
    trap 'exit 1' HUP INT TERM
    [ -f "$key_input" ] && [ ! -L "$key_input" ] || exit 1
    key_stage=$(key_scratch_stage "$key_output") || exit 1
    key_candidates=$(make_tmp_file key-candidates) || exit 1
    key_check=$(make_tmp_file public-key) || exit 1
    key_records import < "$key_input" > "$key_candidates" || exit 1
    if ! command_exists ssh-keygen; then
        warn "未找到 ssh-keygen，公钥格式仅使用基础规则校验。"
    fi
    key_count=0
    while IFS= read -r key_line; do
        if validate_key_record "$key_line" "$key_check"; then
            printf '%s\n' "$key_line" >> "$key_stage" || exit 1
            key_count=$((key_count + 1))
        else
            [ "$?" -eq 1 ] || exit 1
        fi
    done < "$key_candidates"
    key_safe_output "$key_output" && mv -fT "$key_stage" "$key_output" || exit 1
    key_stage=''
    printf '%s\n' "$key_count"
)

# Keep a wall deadline even on a minimal system without the timeout applet.
# The fallback owns only the child it starts; no daemon, lock or timer file.
key_deadline() (
    key_seconds=$1; shift
    if command_exists timeout; then exec timeout "$key_seconds" "$@"; fi
    "$@" & key_worker=$!
    trap 'if [ -n "$key_worker" ]; then kill -KILL "$key_worker" 2>/dev/null || :; wait "$key_worker" 2>/dev/null || :; fi' EXIT
    trap 'exit 1' HUP INT TERM
    while kill -0 "$key_worker" 2>/dev/null; do
        [ "$key_seconds" -gt 0 ] || exit 124
        sleep 1 || exit 1
        key_seconds=$((key_seconds - 1))
    done
    key_status=0; wait "$key_worker" || key_status=$?
    key_worker=''; exit "$key_status"
)

# Some BusyBox ash builds prefer their own wget applet over PATH. Its TLS
# capabilities must not be confused with the executable the watchdog starts.
key_wget_binary() (
    key_search=${PATH:-}:
    while [ -n "$key_search" ]; do
        key_dir=${key_search%%:*}; key_search=${key_search#*:}
        case "$key_dir" in /*) ;; *) continue ;; esac
        if [ -f "$key_dir/wget" ] && [ -x "$key_dir/wget" ]; then printf '%s\n' "$key_dir/wget"; exit 0; fi
    done
    exit 1
)

fetch_github_keys() (
    key_user=$1 key_output=$2 key_stage='' key_log=''
    validate_github_username "$key_user" || { error "GitHub 用户名格式无效。"; exit 1; }
    key_url="https://github.com/$key_user.keys"
    trap 'rm -f "${key_stage:-}" "${key_log:-}"' EXIT
    trap 'exit 1' HUP INT TERM
    key_stage=$(key_scratch_stage "$key_output") || exit 1
    info "正在拉取 GitHub 公钥..."
    # Bound actual disk writes even for chunked replies and old curl versions.
    # POSIX uses 512-byte blocks; some shells use KiB. Check bytes below too.
    ulimit -f 2048 || exit 1
    if command_exists curl; then
        curl -q -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 10 --max-time 30 \
            --max-filesize 1048576 "$key_url" > "$key_stage" || exit 1
    elif command_exists wget; then
        key_wget=$(key_wget_binary) || exit 1
        key_help=$(LC_ALL=C "$key_wget" --help 2>&1) || :
        case "$key_help" in
            *'GNU Wget '*)
                # Ignore user/system wgetrc and reject redirect downgrades.
                key_deadline 30 "$key_wget" --no-config --max-redirect=0 --tries=1 --timeout=10 -qO- "$key_url" > "$key_stage" || exit 1
                ;;
            *'BusyBox v'*)
                # Known OpenSSL-enabled BusyBox builds advertise the certificate
                # switch. We never pass it. The internal TLS fallback does NOT
                # authenticate the peer. Reject unknown builds, fallback warnings
                # and redirects. -Y off avoids forwarding HTTPS to an HTTP proxy.
                if ! printf '%s\n' "$key_help" | awk '/^BusyBox v[0-9]/ {split(substr($2,2),v,"[.]"); if(v[1]==1 && v[2]>=36) ok=1} END{exit !ok}' ||
                    ! printf '%s\n' "$key_help" | grep -Fq -- '--no-check-certificate' ||
                    ! command_exists openssl || ! openssl version >/dev/null 2>&1; then
                    error '无法确认 BusyBox wget 支持 TLS 证书和主机名校验，请使用 curl 或 GNU wget。'; exit 1
                fi
                key_log=$(make_tmp_file wget-status) || exit 1
                LC_ALL=C key_deadline 30 "$key_wget" -S -Y off -qO- -T 10 "$key_url" > "$key_stage" 2> "$key_log" || exit 1
                LC_ALL=C awk '
                    /TLS certificate validation not implemented/ {bad=1}
                    /^[ \t]*HTTP\/[0-9.]+[ \t]/ {if (++responses != 1 || $2 != 200) bad=1}
                    END {exit (bad || responses != 1)}
                ' "$key_log" || { error 'BusyBox wget 未返回经过证书验证且无重定向的 200 响应。'; exit 1; }
                ;;
            *) error '无法确认 wget 的 TLS/超时能力。'; exit 1 ;;
        esac
    else
        error "缺少 curl 或 wget，无法拉取 GitHub 公钥。"
        exit 1
    fi
    [ -s "$key_stage" ] || exit 2
    key_size=$(wc -c < "$key_stage") || exit 1
    [ "$key_size" -le 1048576 ] || { error '公钥响应超过 1 MiB。'; exit 1; }
    key_safe_output "$key_output" && mv -fT "$key_stage" "$key_output" || exit 1
    key_stage=''
)

# Outside the CLI transaction keep one complete, independent old inode for
# legacy direct callers. Publish it without clobbering another backup.
backup_authorized_keys() (
    ak_backup_base="$1.bak.$(timestamp)"
    ak_backup=$ak_backup_base ak_suffix=0
    while [ -e "$ak_backup" ] || [ -L "$ak_backup" ]; do
        ak_suffix=$((ak_suffix + 1))
        ak_backup="$ak_backup_base.$ak_suffix"
    done
    ak_old_stage=$(key_scratch_stage "$1") || exit 1
    trap 'rm -f "$ak_old_stage"' EXIT
    trap 'exit 1' HUP INT TERM
    tx_copy_file "$1" "$ak_old_stage" && cmp -s "$ak_existing" "$ak_old_stage" &&
        ln -T "$ak_old_stage" "$ak_backup" || exit 1
    printf '%s\n' "$ak_backup"
)

# Read-only preflight: the transaction must snapshot .ssh and authorized_keys
# BEFORE mkdir/chmod/chown. Do not follow even a dangling link or a linked
# ancestor of HOME. In particular never inspect key bytes through a hard link.
prepare_authorized_keys() {
    AUTHORIZED_KEYS_FILE=''
    ak_user=$(current_user) && ak_uid=$(current_uid) && ak_home=$(home_dir_for_user "$ak_user") || return 1
    case "$ak_home" in /|'') error "当前用户 HOME 异常。"; return 1 ;; esac
    if is_symlink_path "$ak_home" || [ ! -d "$ak_home" ] ||
        [ "$(CDPATH=; cd -P "$ak_home" && pwd -P)" != "$ak_home" ] ||
        [ "$(owner_uid "$ak_home")" != "$ak_uid" ]; then
        error "当前用户 HOME 不存在、不是无链接绝对路径，或 owner 异常。"; return 1
    fi
    ak_dir="$ak_home/.ssh" ak_file="$ak_home/.ssh/authorized_keys"
    if is_symlink_path "$ak_dir" || { [ -e "$ak_dir" ] && [ ! -d "$ak_dir" ]; }; then
        error ".ssh 不能是 symlink 或非目录。"; return 1
    fi
    if [ -d "$ak_dir" ]; then
        ak_dir_uid=$(owner_uid "$ak_dir") || return 1
        if [ "$ak_dir_uid" != "$ak_uid" ] && [ "$ak_dir_uid" != 0 ]; then
            error ".ssh owner 异常。"; return 1
        fi
    fi
    if is_symlink_path "$ak_file" || { [ -e "$ak_file" ] &&
        { [ ! -f "$ak_file" ] || [ "$(stat -c %h "$ak_file")" != 1 ]; }; }; then
        error "authorized_keys 必须是无 symlink / hard link 的普通文件。"; return 1
    fi
    AUTHORIZED_KEYS_FILE=$ak_file
}

same_authorized_keys_source() {
    prepare_authorized_keys || return 1
    if [ "${TX_ACTIVE:-0}" = 1 ]; then
        tx_same "$TX_DIR" auth
    elif [ "$ak_existing" = /dev/null ]; then
        [ ! -e "$ak_file" ]
    else
        [ -f "$ak_file" ] && cmp -s "$ak_file" "$ak_existing"
    fi
}

apply_authorized_key_delta() {
    same_authorized_keys_source || return 1
    if [ ! -d "$ak_dir" ]; then
        mkdir -m 700 "$ak_dir" || return 1
        ak_created_dir=1
    fi
    # set_mode writes a marker only in test mode. Refuse unsafe marker paths
    # before invoking it; production never creates markers.
    if [ "${IKE_TEST_MODE:-0}" = 1 ]; then
        for ak_marker in "$ak_dir/.ssh-init-mode" "$ak_file.ssh-init-mode"; do
            [ ! -L "$ak_marker" ] && { [ ! -e "$ak_marker" ] ||
                { [ -f "$ak_marker" ] && [ "$(stat -c %h "$ak_marker")" = 1 ]; }; } || return 1
        done
    fi
    set_owner "$ak_dir" "$ak_user" && chmod 700 "$ak_dir" || return 1
    if [ "${IKE_TEST_MODE:-0}" = 1 ] && [ "$(stat -c %a "$ak_dir")" != 700 ]; then
        set_mode 700 "$ak_dir" || return 1
    fi
    if [ "$ak_added" -eq 0 ] && [ -f "$ak_file" ] &&
        [ "$(stat -c %a "$ak_file")" = 600 ] && [ "$(owner_uid "$ak_file")" = "$ak_uid" ]; then
        same_authorized_keys_source; return $?
    fi
    if [ "${TX_ACTIVE:-0}" = 1 ]; then
        tx_stage_path "$ak_file" || { ak_stage=${SSHD_CONFIG_TMP_FILE:-}; return 1; }
    else
        SSHD_CONFIG_TMP_FILE=$(key_scratch_stage "$ak_file") || return 1
    fi
    ak_stage=$SSHD_CONFIG_TMP_FILE
    ak_group_source=$ak_dir
    if [ "$ak_existing" != /dev/null ]; then
        ak_group_source=$ak_file
        tx_copy_file "$ak_existing" "$ak_stage" || return 1
        if [ -s "$ak_stage" ] && [ "$ak_added" -gt 0 ]; then
            # Compare with a literal LF without shell substitution swallowing it.
            ak_last_byte=$(tail -c 1 "$ak_stage" && printf '.') || return 1
            if [ "$ak_last_byte" != "
." ]; then printf '\n' >> "$ak_stage" || return 1; fi
        fi
    fi
    cat "$ak_delta" >> "$ak_stage" || return 1
    ak_gid=$(stat -c %g "$ak_group_source") || return 1
    set_owner "$ak_stage" "$ak_user:$ak_gid" || return 1
    if [ "$(stat -c %g "$ak_stage")" != "$ak_gid" ]; then chgrp "$ak_gid" "$ak_stage" || return 1; fi
    chmod 600 "$ak_stage" || return 1
    # A second check prevents publishing into a replaced symlink/directory.
    same_authorized_keys_source || { error "authorized_keys 在写入期间已更改。"; return 1; }
    if [ "${TX_ACTIVE:-0}" != 1 ] && [ -f "$ak_file" ] && [ "$ak_added" -gt 0 ]; then
        ak_backup=$(backup_authorized_keys "$ak_file") || return 1
    fi
    mv -fT "$ak_stage" "$ak_file" || return 1
    SSHD_CONFIG_TMP_FILE=''
    if [ "${IKE_TEST_MODE:-0}" = 1 ] && [ "$(stat -c %a "$ak_file")" != 600 ]; then
        # On Windows test filesystems chmod may succeed without POSIX modes.
        printf '%s\n' 600 > "$ak_file.ssh-init-mode" || :
    fi
    return 0
}

append_keys_to_authorized_keys() {
    ak_import=$1 ak_backup='' ak_created_dir=0 ak_stage=''
    [ -f "$ak_import" ] && [ ! -L "$ak_import" ] || return 1
    prepare_authorized_keys || return 1
    ak_existing=/dev/null ak_copy='' ak_dir_meta=''
    if [ "${TX_ACTIVE:-0}" = 1 ]; then
        tx_same "$TX_DIR" auth || return 1
        [ ! -f "$ak_file" ] || ak_existing=$TX_DIR/auth.data
    elif [ -d "$ak_dir" ]; then
        ak_dir_meta=$(stat -c '%u:%g %a' "$ak_dir") || return 1
        if [ -f "$ak_file" ]; then
            ak_copy=$(make_tmp_file authorized-keys-before) || return 1
            tx_copy_file "$ak_file" "$ak_copy" || { rm -f "$ak_copy"; return 1; }
            ak_existing=$ak_copy
        fi
    fi
    ak_delta=$(make_tmp_file key-delta) || { rm -f "$ak_copy"; return 1; }
    ak_rc=1
    if key_records existing "$ak_existing" mode=append "$ak_import" > "$ak_delta" &&
        ak_added=$(wc -l < "$ak_delta") && apply_authorized_key_delta; then
        ak_rc=0
    fi
    rm -f "$ak_delta" "$ak_copy"
    if [ "$ak_rc" -ne 0 ]; then
        if [ -n "$ak_stage" ] && tx_safe_path "$ak_stage"; then rm -f "$ak_stage"; fi
        if [ -n "$ak_backup" ] && tx_safe_path "$ak_backup"; then rm -f "$ak_backup"; fi
        if [ "${TX_ACTIVE:-0}" != 1 ] && tx_safe_path "$ak_dir"; then
            if [ "$ak_created_dir" = 1 ]; then
                [ "${IKE_TEST_MODE:-0}" != 1 ] || rm -f "$ak_dir/.ssh-init-mode"
                rmdir "$ak_dir" || :
            elif [ -n "$ak_dir_meta" ] && [ "$(stat -c '%u:%g %a' "$ak_dir")" != "$ak_dir_meta" ]; then
                if ! set_owner "$ak_dir" "${ak_dir_meta% *}" || ! chmod "${ak_dir_meta##* }" "$ak_dir"; then
                    error "恢复 .ssh 元数据失败。"
                fi
            fi
        fi
        SSHD_CONFIG_TMP_FILE=''
        error "无法原子写入 authorized_keys。"
        return 1
    fi
    success "已导入 $ak_added 条新公钥。"
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
    printf '%s\n' "root 密钥登录: 默认仅允许密钥；原有更严格策略需另行确认。"
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
    # Non-root keygen never writes system settings; serialize only its local keys.
    if [ "$(current_uid)" != 0 ]; then
        TX_LOCAL_STATE=$(home_dir_for_user "$(current_user)")/.ssh-init-keygen.d
    fi
    local_key_rc=0
    with_write_lock generate_local_key_locked || local_key_rc=$?
    TX_LOCAL_STATE=""
    return "$local_key_rc"
}

generate_local_key_locked() {
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
        stamp="$(timestamp).$$"
        while [ -e "$private.bak.$stamp" ] || [ -e "$public.bak.$stamp" ] ||
            [ -L "$private.bak.$stamp" ] || [ -L "$public.bak.$stamp" ]; do stamp=$stamp.1; done
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
    harden_ssh_config "$valid_file" || return 1
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
    chmod 600 "$GENERATED_PRIVATE_KEY_FILE" && chmod 644 "$GENERATED_PUBLIC_KEY_FILE" || return 1
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
    harden_ssh_config "$valid_file" || return 1
    final_reminder
}

ensure_run_sshd_dir() {
    [ -n "$RUN_SSHD_DIR" ] || return 1
    if [ -L "$RUN_SSHD_DIR" ]; then
        return 1
    fi
    if [ ! -d "$RUN_SSHD_DIR" ]; then
        (umask 022; mkdir -p "$RUN_SSHD_DIR") || return 1
    fi
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

# Collect connection attributes independently of shell parsing. SSH_CONNECTION
# gives addresses and ports, not a verified remote hostname or routing domain.
ssh_auth_connection_spec() (
    auth_user=$(current_user) || return 1
    case "$auth_user" in ''|*','*|*'='*|*[[:space:]]*) return 1 ;; esac
    printf 'user=%s' "$auth_user"
    printf '%s\n' "${SSH_CONNECTION:-}" | awk -v dns="$1" '
        function ip(v) { return v ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ || (v ~ /:/ && v ~ /^[[:xdigit:]:.]+$/) }
        function port(v) { return v ~ /^[0-9]+$/ && v > 0 && v <= 65535 }
        NR == 1 && NF == 4 && ip($1) && port($2) && ip($3) && port($4) {
            printf ",addr=%s,laddr=%s,lport=%d", $1, $3, $4
            if (dns == "no") printf ",host=%s", $1
        }'
)

ssh_auth_global_check() {
    awk -v root="$2" '
        { v[tolower($1)] = tolower($2) }
        function check(k,want) {
            if (v[k] != want) print "  - " k ": 期望 " want "，实际 " (v[k] == "" ? "(缺失)" : v[k])
        }
        END {
            check("pubkeyauthentication", "yes"); check("passwordauthentication", "no"); check("permitemptypasswords", "no")
            if ("kbdinteractiveauthentication" in v || !("challengeresponseauthentication" in v)) check("kbdinteractiveauthentication", "no")
            if ("challengeresponseauthentication" in v) check("challengeresponseauthentication", "no")
            actual = v["permitrootlogin"]
            if (!(root == "prohibit-password" && actual == "without-password") && root != actual)
                print "  - permitrootlogin: 期望 " (root == "prohibit-password" ? "prohibit-password/without-password" : root) "，实际 " (actual == "" ? "(缺失)" : actual)
        }' "$1"
}

# Assess the login path that ssh-init actually provisions, not just global
# on/off flags. All paths/keys are data, never shell expressions or commands.
ssh_auth_target_check() (
    auth_user=$(current_user) || return 1
    auth_uid=$(current_uid) || return 1
    auth_home=$(home_dir_for_user "$auth_user") || return 1
    auth_dest=$(current_auth_file) || return 1
    auth_groups=''
    if grep -Eiq '^(allowgroups|denygroups)[[:space:]]' "$1"; then
        auth_groups=$(id -Gn "$auth_user" 2>/dev/null) || auth_groups=''
    fi
    # Pass path/identity strings through ENVIRON; awk -v interprets backslashes.
    SSH_AUTH_HOME=$auth_home SSH_AUTH_DEST=$auth_dest SSH_AUTH_GROUPS=$auth_groups \
    SSH_AUTH_USER=$auth_user SSH_AUTH_KEYS=${2:-} SSH_AUTH_WARN=$5 SSH_AUTH_GLOBAL=$7 \
    awk -v uid="$auth_uid" -v phase="$3" -v root="$4" -v uncertain_keys="$6" '
        function note(s) { print "  - " s >> warnfile }
        function is_uncertain(k) { return index(" " uncertain_keys " ", " " k " ") }
        function deny(s,k) {
            if (is_uncertain(k)) note(s "（连接条件不完整，须人工验证）")
            else print "  - " s
        }
        function tokenpath(s,   i,c,t,r) {
            r=""; for (i=1;i<=length(s);i++) {
                c=substr(s,i,1); if(c!="%") {r=r c; continue}
                t=substr(s,++i,1)
                if(t=="h") r=r home; else if(t=="u") r=r user; else if(t=="U") r=r uid
                else if(t=="%") r=r "%"; else return ""
            }
            if(substr(r,1,1)!="/") r=home "/" r
            gsub(/\/+/,"/",r); gsub(/\/\.\//,"/",r); return r
        }
        # The server dumps evaluated algorithms. An RSA key may sign with
        # rsa-sha2-256/512 even when the legacy ssh-rsa signature is disabled.
        function accepts(t,algs) {
            return index(algs,"," t ",") || (t=="ssh-rsa" && (index(algs,",rsa-sha2-256,") || index(algs,",rsa-sha2-512,")))
        }
        function methods(s,   i,n,a,k) {
            n=split(s,a,/ +/); k=0
            for(i=1;i<=n;i++) {
                if(a[i]=="any" || a[i]=="publickey") return
                if(a[i] !~ /(^|,)(password|keyboard-interactive(:[^,]+)?)(,|$)/ && a[i] ~ /(^|,)publickey(,|$)/) k=1
            }
            if(k) note("AuthenticationMethods " s " 另需密钥或外部因子，无法确认客户端能满足。")
            else deny("AuthenticationMethods " s "：脚本会禁用 password / keyboard-interactive，继续可能导致 SSH 无法登录；请检查是否需要将 AuthenticationMethods 改为 publickey。", "authenticationmethods")
        }
        # In simple user/group names only * and ? are wildcard operators.
        function name_matches(s,pat,   i,c,re) {
            re="^"; for(i=1;i<=length(pat);i++) {
                c=substr(pat,i,1); re=re (c=="*" ? ".*" : c=="?" ? "." : c=="." ? "[.]" : c)
            }; return s ~ (re "$")
        }
        function access(k,   n,p,i,j,ng,gs,hit,unknown,isgroup) {
            if (!(k in v)) return
            n=split(v[k],p,/ +/); isgroup=(k ~ /groups$/); ng=split(groups,gs,/ +/)
            if(isgroup && groups=="") { note(k "：无法确定目标用户组，须人工核对。"); return }
            for(i=1;i<=n;i++) {
                # user@host, negation, pattern lists and DNS are contextual.
                if(p[i] !~ /^[[:alnum:]_.*?-]+$/) unknown=1
                else if(!isgroup && name_matches(user,p[i])) hit=1
                else if(isgroup) for(j=1;j<=ng;j++) if(name_matches(gs[j],p[i])) hit=1
            }
            if(k ~ /^deny/ && hit) deny(k " " v[k] "：明确拒绝目标用户 " user,k)
            else if(k ~ /^allow/ && !hit && !unknown) deny(k " " v[k] "：不包含目标用户 " user " 或其所属组",k)
            else if(unknown) note(k " " v[k] " 含复杂模式或来源条件，须人工核对。")
        }
        BEGIN {
            home=ENVIRON["SSH_AUTH_HOME"]; dest=ENVIRON["SSH_AUTH_DEST"]; groups=ENVIRON["SSH_AUTH_GROUPS"]
            user=ENVIRON["SSH_AUTH_USER"]; warnfile=ENVIRON["SSH_AUTH_WARN"]; keys=ENVIRON["SSH_AUTH_KEYS"]
            baseline=ENVIRON["SSH_AUTH_GLOBAL"]
            while ((rc=(getline line < baseline))>0) {
                split(line,b,/[[:space:]]+/); before[tolower(b[1])]=b[2]
            }
            if (rc<0) exit 1
            close(baseline)
        }
        NF>=2 {
            k=tolower($1); sub(/^[^[:space:]]+[[:space:]]+/, "")
            if(k ~ /^(allowusers|denyusers|allowgroups|denygroups)$/ && k in v) v[k]=v[k] " " $0
            else v[k]=$0
        }
        END {
            # If current target and global differ, changing only the global
            # value cannot repair the retained Match override. If equal, the
            # final check decides after sshd evaluates the candidate config.
            if (phase=="pre") {
                if(v["pubkeyauthentication"]=="no" && before["pubkeyauthentication"]=="yes")
                    deny("PubkeyAuthentication no：目标 Match 禁用公钥，全局加固不会改写此限制。","pubkeyauthentication")
                if(v["passwordauthentication"]=="yes" && before["passwordauthentication"]=="no")
                    deny("PasswordAuthentication yes：目标 Match 仍允许密码认证。","passwordauthentication")
                if((v["kbdinteractiveauthentication"]=="yes" && before["kbdinteractiveauthentication"]=="no") || (v["challengeresponseauthentication"]=="yes" && before["challengeresponseauthentication"]=="no"))
                    deny("KbdInteractiveAuthentication yes：目标 Match 仍允许键盘交互。","kbdinteractiveauthentication")
                if(v["permitemptypasswords"]=="yes" && before["permitemptypasswords"]=="no")
                    deny("PermitEmptyPasswords yes：目标 Match 允许空密码。","permitemptypasswords")
            }
            if (phase=="final") {
                if(v["pubkeyauthentication"]!="yes") deny("PubkeyAuthentication：目标用户未确认启用公钥认证。","pubkeyauthentication")
                if(v["passwordauthentication"]!="no") deny("PasswordAuthentication：目标用户未确认禁用密码认证。","passwordauthentication")
                if((v["kbdinteractiveauthentication"]!="no" && v["challengeresponseauthentication"]!="no") || v["kbdinteractiveauthentication"]=="yes" || v["challengeresponseauthentication"]=="yes") deny("KbdInteractiveAuthentication：目标用户未确认禁用键盘交互。","kbdinteractiveauthentication")
                if(v["permitemptypasswords"]=="yes") deny("PermitEmptyPasswords：目标用户允许空密码。","permitemptypasswords")
            }
            if(uid==0) {
                strict=(v["permitrootlogin"]=="no" || v["permitrootlogin"]=="forced-commands-only")
                if(root!="prohibit-password" && (strict || is_uncertain("permitrootlogin") || v["permitrootlogin"]==""))
                    print "  - PermitRootLogin " root "：保留严格 root 策略，未验证可用于该目标的普通 root 会话。"
                else if(strict && (phase=="final" || v["permitrootlogin"]!=before["permitrootlogin"]))
                    deny("PermitRootLogin " v["permitrootlogin"] "：目标 root 无法使用导入密钥打开普通 SSH 会话。","permitrootlogin")
            }
            if(v["authenticationmethods"]!="") methods(v["authenticationmethods"])
            access("denyusers"); access("allowusers"); access("denygroups"); access("allowgroups")
            external=(v["authorizedkeyscommand"]!="" && v["authorizedkeyscommand"]!="none")
            if(external) note("AuthorizedKeysCommand 已配置，外部密钥来源未执行、未验证。")
            if (v["authorizedkeysfile"] != "") {
                n=split(v["authorizedkeysfile"],a,/ +/)
                for(i=1;i<=n;i++) {
                    if(a[i]=="none") continue
                    resolved=tokenpath(a[i]); if(resolved==dest) found=1
                    if(resolved=="" || resolved ~ /\/\.\.($|\/)/ || home ~ /[[:space:]]/ || a[i] ~ /["\\]/) uncertain=1
                }
                if(!found && !uncertain && !external) deny("AuthorizedKeysFile " v["authorizedkeysfile"] " 不读取脚本写入路径 " dest,"authorizedkeysfile")
                else if(!found) note("AuthorizedKeysFile " v["authorizedkeysfile"] " 未确认读取 " dest "，请核对路径和外部来源。")
            } else note("未取得 AuthorizedKeysFile，无法验证脚本写入路径。")
            alg=v["pubkeyacceptedalgorithms"]; if(alg=="") alg=v["pubkeyacceptedkeytypes"]
            if(keys!="") {
                algs="," alg ","; while((rc=(getline line < keys))>0) {
                    split(line,b,/[[:space:]]+/); if(b[1]=="") continue
                    if(accepts(b[1],algs)) compatible=1
                }
                if(rc<0) { print "  - 无法读取待导入密钥类型。"; exit 1 }; close(keys)
                if(alg=="" || alg ~ /[*?!+^]/) note("PubkeyAcceptedAlgorithms 列表不明确，无法验证签名算法。")
                else if(!compatible) deny("PubkeyAcceptedAlgorithms 不接受任何待导入密钥的签名算法。","pubkeyacceptedalgorithms")
            }
        }' "$1"
)

ssh_auth_effective() {
    auth_bin=$(find_sshd_bin) && ensure_run_sshd_dir && "$auth_bin" -T -f "$1" > "$2" 2>/dev/null && [ -s "$2" ]
}

ssh_auth_context_check() (
    # $1 config, $2 global dump, $3 supplied keys, $4 phase, $5 root policy.
    auth_target_dump=$(make_tmp_file auth-context) || return 1
    auth_warnings=$(make_tmp_file auth-warnings) || return 1
    auth_dns=$(awk '$1 == "usedns" {print $2; exit}' "$2") || return 1
    auth_spec=$(ssh_auth_connection_spec "$auth_dns") || return 1
    auth_net=1; auth_host=1; auth_fallback=0
    case "$auth_spec" in
        *,addr=*) ;;
        *) auth_net=0; warn "SSH_CONNECTION 不可用或无效；仅按本机目标用户检查，不能验证来源地址条件。" ;;
    esac
    case "$auth_spec" in *,host=*) ;; *) auth_host=0 ;; esac
    auth_sources=${auth_review:-}
    if [ ! -f "$auth_sources" ] || [ "$4" = final ]; then
        auth_sources=$(make_tmp_file auth-final-sources) || return 1
        scan_sshd_config_risk_file "$1" 0 review > "$auth_sources" || { error '无法扫描目标配置的 Match 来源。'; return 1; }
    fi
    auth_missing=$(awk -F '\t' -v net="$auth_net" -v host="$auth_host" '
        $1=="context" && ((!net && $2 ~ / network/) || (!host && $2 ~ / host/) || $2 ~ / other/) { print 1; exit }' "$auth_sources") || return 1
    auth_err=$(make_tmp_file auth-context-error) || return 1
    auth_bin=$(find_sshd_bin) || return 1
    if ! LC_ALL=C "$auth_bin" -T -f "$1" -C "$auth_spec" > "$auth_target_dump" 2> "$auth_err"; then
        # Do not downgrade broken Match authentication chains, syntax errors,
        # unsupported options or unrelated daemon failures to mere uncertainty.
        if [ -z "$auth_missing" ] || ! grep -Eiq '(missing|required|not (set|specified|provided|in connection)).*(attribute|address|addr|host|port|domain|criterion)|((attribute|address|addr|host|port|domain|criterion).*(missing|required|not (set|specified|provided|in connection)))' "$auth_err"; then
            error 'sshd -T -C 目标用户校验执行失败。'; cat "$auth_err" >&2; return 1
        fi
        warn 'sshd -T -C 缺少求值所需的连接属性；仅不确定的条件指令降为警告。'
        cp "$2" "$auth_target_dump" || return 1
        auth_fallback=1
    fi
    [ -s "$auth_target_dump" ] || { error 'sshd -T -C 未返回目标配置。'; return 1; }
    # A Match about ports must not turn an unrelated DenyUsers, unaccepted
    # key algorithm, or strict root policy into a warning. Alias equivalent keys.
    auth_uncertain=$(awk -F '\t' -v net="$auth_net" -v host="$auth_host" -v fallback="$auth_fallback" '
        $1=="scope" && (fallback || (!net && $2 ~ / network/) || (!host && $2 ~ / host/) || $2 ~ / other/) {
            split($2,a," "); k=a[1]; if(k=="authorizedkeyscommand") k="authorizedkeysfile"
            if(k=="pubkeyacceptedkeytypes") k="pubkeyacceptedalgorithms"
            if(k=="challengeresponseauthentication") k="kbdinteractiveauthentication"
            if(!seen[k]++) printf "%s ",k
        }' "$auth_sources") || return 1
    [ -z "$auth_missing" ] || warn '存在未能复现的 Match 条件，目标检查不代表所有连接。'
    ssh_auth_target_check "$auth_target_dump" "$3" "$4" "$5" "$auth_warnings" "$auth_uncertain" "$2" || return 1
    while IFS= read -r auth_note; do warn "$auth_note"; done < "$auth_warnings"
)

effective_sshd_settings_check() (
    failures_file=${2:-}
    [ -n "$failures_file" ] || failures_file=$(make_tmp_file sshd-effective-failures) || return 1
    : > "$failures_file" || return 1
    effective_file=$(make_tmp_file sshd-effective) || return 1
    if ! ssh_auth_effective "$1" "$effective_file"; then
        printf '%s\n' '__SSHD_T_FAILED__' > "$failures_file"
        return 1
    fi
    auth_root=${3:-prohibit-password}
    ssh_auth_global_check "$effective_file" "$auth_root" >> "$failures_file" || return 1
    ssh_auth_context_check "$1" "$effective_file" "${4:-}" final "$auth_root" >> "$failures_file" || return 1
    [ ! -s "$failures_file" ]
)

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
    awk -v in_match="${2:-0}" -v parent_dims="${3:-base}" '
        BEGIN { dims=parent_dims }
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
                dims = parent_dims
                # Unknown criteria are not interpreted as a successful match.
                for (i=2; i<=n; i++) {
                    criterion=tolower(parts[i]); if (criterion=="all") continue
                    if (criterion=="address" || criterion=="localaddress" || criterion=="localport") dims=dims " network"
                    else if (criterion=="host") dims=dims " host"
                    else if (criterion!="user" && criterion!="group") dims=dims " other"
                    i++
                }
                print "context\t1\t" NR "\t" dims
                next
            }
            if (key == "include") {
                if (n < 2) exit 2
                for (i = 2; i <= n; i++) {
                    if (parts[i] == "" || parts[i] ~ /[\t\r\n]/) exit 2
                    print "include\t" in_match "\t" NR "\t" parts[i] "\t" dims
                }
                next
            }
            if (in_match && key ~ /^(pubkeyauthentication|passwordauthentication|kbdinteractiveauthentication|challengeresponseauthentication|permitemptypasswords|authenticationmethods|permitrootlogin|authorizedkeysfile|authorizedkeyscommand|pubkeyacceptedalgorithms|pubkeyacceptedkeytypes|allowusers|denyusers|allowgroups|denygroups)$/)
                print "scope\t1\t" NR "\t" key " " dims
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
                 (key == "permitemptypasswords" && value == "yes") ||
                 (key == "pubkeyauthentication" && value != "yes") ||
                 key ~ /^(permitrootlogin|authorizedkeysfile|authorizedkeyscommand|pubkeyacceptedalgorithms|pubkeyacceptedkeytypes|allowusers|denyusers|allowgroups|denygroups)$/))
                print "match\t" in_match "\t" NR "\t" parts[1] " " value
        }
    ' "$scan_file"
)

config_file_include_patterns() (
    records=$(config_file_scan_records "$1" "${3:-0}") || return 1
    printf '%s\n' "$records" | awk -F '\t' -v scope="${2:-global}" '
        $1 == "include" && (scope == "all" || $2 == "0") { print $4 }
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
    if ! config_file_scan_records "$scan_file" "$scan_in_match" "${5:-base}" > "$scan_records"; then
        printf '%s\n' "$scan_file: 无法读取或解析 SSH 配置，已停止扫描。"
        return 2
    fi
    scan_tab=$(printf '\t')
    while IFS="$scan_tab" read -r record_kind record_match record_line record_value record_dims; do
        if [ "$scan_kind" = review ] && [ "$record_kind" != include ]; then
            printf '%s\t%s\t%s:%s\n' "$record_kind" "$record_value" "$scan_file" "$record_line" || return 2
            continue
        fi
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
            if scan_sshd_config_risk_file "$scan_included" "$((scan_depth + 1))" "$scan_kind" "$record_match" "$record_dims"; then
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

# Compatibility API: sets diagnostic variables for sourced callers/tests.
# shellcheck disable=SC2034
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

# shellcheck disable=SC2034
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

# Run in the transaction shell before writing keys/config. The only persistent
# results are the chosen root policy and facts used by the final -C check.
auth_preflight() {
    SSH_INIT_ROOT_POLICY=prohibit-password
    MATCH_OVERRIDE_RISK=''; MATCH_OVERRIDE_RISK_FOUND=0
    auth_review=$(make_tmp_file auth-sources) || return 1
    if ! scan_sshd_config_risk_file "$1" 0 review > "$auth_review"; then
        error '无法完整检查 SSH 配置文件或 Include，未进行加固。'
        cat "$auth_review" >&2
        return 1
    fi
    auth_tab=$(printf '\t')
    while IFS="$auth_tab" read -r auth_kind auth_value auth_source; do
        case "$auth_kind" in
            match)
                MATCH_OVERRIDE_RISK_FOUND=1
                MATCH_OVERRIDE_RISK="$auth_source: $auth_value"
                warn_match_override_risk ;;
            authentication)
                warn "$auth_source: $auth_value；按目标用户生效配置判断，不改写认证链。" ;;
        esac
    done < "$auth_review"
    auth_before=$(make_tmp_file auth-before) || return 1
    if ! ssh_auth_effective "$1" "$auth_before"; then
        error 'sshd -T 无法读取最终配置（写入前预检），未进行加固。'
        return 1
    fi
    auth_prev_root=$(awk '$1=="permitrootlogin" {print $2; exit}' "$auth_before") || return 1
    case "$auth_prev_root" in
        no|forced-commands-only)
            SSH_INIT_ROOT_POLICY=$auth_prev_root
            warn "当前生效 PermitRootLogin $auth_prev_root；默认保留此限制，不启用普通 root 密钥会话。"
            if ask_prompt '确需放宽到 PermitRootLogin prohibit-password 才输入 ROOT；回车或 EOF 保留原策略:' && [ "$ASK_REPLY" = ROOT ]; then
                SSH_INIT_ROOT_POLICY=prohibit-password
                warn '已明确选择允许 root 密钥登录；不会修改 Match 中的限制。'
            fi ;;
        prohibit-password|without-password|yes) ;;
        *) error '无法确认原有 PermitRootLogin 策略，为避免放宽限制已停止。'; return 1 ;;
    esac
    auth_problem=$(make_tmp_file auth-problems) || return 1
    ssh_auth_context_check "$1" "$auth_before" "${2:-}" pre "$SSH_INIT_ROOT_POLICY" > "$auth_problem" || return 1
    if [ -s "$auth_problem" ]; then
        error '目标用户认证预检失败，未进行加固：'
        cat "$auth_problem" >&2
        return 1
    fi
    return 0
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
        tmp_file=$(mktemp "$dir/.$base.ssh-init.XXXXXX") || { umask "$old_umask"; return 1; }
    else
        i=0
        while [ "$i" -lt 10 ]; do
            candidate="$dir/.$base.ssh-init.$$.$i"
            if [ ! -e "$candidate" ] && [ ! -L "$candidate" ] && (set -C; : > "$candidate") 2>/dev/null; then
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

sshd_dropin_dir_from_config() (
    # Traverse only global Includes in sshd order. A literal 50-cloud.conf
    # does not load 00-ssh-init-hardening.conf merely because both end in .conf.
    [ "${2:-0}" -le 16 ] && [ -f "$1" ] || return 1
    patterns=$(make_tmp_file dropin-patterns) || return 1
    config_file_include_patterns "$1" global > "$patterns" || return 1
    while IFS= read -r pattern; do
        resolved=$(list_resolved_include_patterns "$pattern") || return 1
        parent=${resolved%/*}; mask=${resolved##*/}
        # Here the candidate is deliberately fixed and the untrusted mask is
        # only a shell pattern, never re-parsed as input or executed.
        # shellcheck disable=SC2194,SC2254
        case 00-ssh-init-hardening.conf in
            $mask)
                IFS=''
                # shellcheck disable=SC2086
                for candidate in $parent; do
                    case "$candidate" in */sshd_config.d)
                        if [ -d "$candidate" ]; then printf '%s\n' "$candidate"; return 0; fi ;;
                    esac
                done ;;
        esac
        children=$(make_tmp_file dropin-includes) || return 1
        list_path_matches "$resolved" > "$children" || return 1
        while IFS= read -r child; do
            if sshd_dropin_dir_from_config "$child" "$((${2:-0} + 1))"; then return 0; fi
        done < "$children"
    done < "$patterns"
    return 1
)

sshd_hardening_dropin_path() {
    dropin_dir=$(sshd_dropin_dir_from_config "$1" 2>/dev/null || true)
    [ -n "$dropin_dir" ] || return 1
    printf '%s\n' "$dropin_dir/00-ssh-init-hardening.conf"
}

render_root_policy() {
    case "${SSH_INIT_ROOT_POLICY:-prohibit-password}" in
        no|forced-commands-only|prohibit-password) printf '%s\n' "${SSH_INIT_ROOT_POLICY:-prohibit-password}" ;;
        *) error '无效的 root 登录策略。'; return 1 ;;
    esac
}

write_sshd_hardening_dropin_content() {
    output="$1"
    write_root=$(render_root_policy) || return 1
    cat > "$output" <<EOF
# Managed by ssh-init. Do not edit manually unless you know what you are doing.
PubkeyAuthentication yes
PasswordAuthentication no
ChallengeResponseAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
PermitRootLogin $write_root
EOF
}

write_sshd_hardening_dropin() {
    tx_stage_path "$1" || return 1
    if [ -f "$1" ]; then tx_copy_file "$1" "$SSHD_CONFIG_TMP_FILE" || return 1; fi
    write_sshd_hardening_dropin_content "$SSHD_CONFIG_TMP_FILE" &&
        set_owner "$SSHD_CONFIG_TMP_FILE" 'root:root' && chmod 644 "$SSHD_CONFIG_TMP_FILE" || return 1
    if [ -f "$1" ] && cmp -s "$1" "$SSHD_CONFIG_TMP_FILE" &&
        [ "$(stat -c '%a:%u:%g' "$1")" = "$(stat -c '%a:%u:%g' "$SSHD_CONFIG_TMP_FILE")" ]; then
        rm -f "$SSHD_CONFIG_TMP_FILE" || return 1
    else
        mv -f "$SSHD_CONFIG_TMP_FILE" "$1" || return 1
    fi
    SSHD_CONFIG_TMP_FILE=''
}

# Service transaction API: persist the opaque single-line snapshot as DATA before
# touching the config. After validation, apply with restart_ssh_service "$saved";
# after restoring/validating old files, reconcile with ssh_service_restore "$saved".
# No PIDs, guessed units, shell code, enable/disable operations or socket restarts.
ssh_service_systemd_booted() { [ -d /run/systemd/system ]; }
ssh_service_openrc_booted() { [ -e /run/openrc/softlevel ]; }
ssh_service_sysv_exists() { [ -x "/etc/init.d/$1" ]; }

ssh_service_backend() (
    if command_exists systemctl && svc_version=$(systemctl show -p Version 2>/dev/null); then
        case "$svc_version" in Version=?*) printf '%s\n' systemd; return 0 ;; esac
        error 'systemd 管理器未返回可识别的版本。'; return 1
    fi
    # service(8) can redirect to systemctl. Never switch managers after a bus error.
    if ssh_service_systemd_booted; then error '无法查询运行中的 systemd。'; return 1; fi
    if command_exists rc-service && { rc-service -e ssh >/dev/null 2>&1 || rc-service -e sshd >/dev/null 2>&1; }; then
        printf '%s\n' openrc
    elif ssh_service_openrc_booted; then
        error 'OpenRC 无法确认 SSH 服务。'; return 1
    elif command_exists service; then
        printf '%s\n' sysv
    else
        error '未找到可查询的 SSH 服务管理器。'; return 1
    fi
)

# All arguments are fixed by our inventory loop, never taken from a journal.
ssh_service_unit_state() (
    svc_backend=$1 svc_unit=$2
    if [ "$svc_backend" = systemd ]; then
        svc_rc=0
        svc_props=$(systemctl show -p Id -p LoadState -p ActiveState -p SubState "$svc_unit" 2>/dev/null) || svc_rc=$?
        svc_id='' svc_load='' svc_active='' svc_sub=''
        while IFS='=' read -r svc_key svc_val; do
            case "$svc_key" in
                Id) svc_id=$svc_val ;; LoadState) svc_load=$svc_val ;;
                ActiveState) svc_active=$svc_val ;; SubState) svc_sub=$svc_val ;;
            esac
        done <<EOF
$svc_props
EOF
        case "$svc_load:$svc_rc" in
            not-found:0|not-found:4)
                case "$svc_active" in ''|inactive) printf '%s\n' absent; return 0 ;; *) return 1 ;; esac ;;
            masked:0) [ "$svc_active" = inactive ] || return 1; printf '%s\n' absent; return 0 ;;
            loaded:0) ;;
            *) return 1 ;;
        esac
        case "$svc_active" in
            active) case "$svc_unit:$svc_sub" in *.service:running|*.socket:listening|*.socket:running) ;; *) return 1 ;; esac ;;
            inactive|failed) ;;
            *) return 1 ;;
        esac
        if [ "$svc_id" != "$svc_unit" ]; then
            case "$svc_unit:$svc_id" in
                ssh.service:sshd.service|sshd.service:ssh.service|ssh.socket:sshd.socket|sshd.socket:ssh.socket)
                    printf '%s\n' alias; return 0 ;;
                *) return 1 ;;
            esac
        fi
        printf '%s\n' "$svc_active"; return 0
    fi
    case "$svc_unit" in *.socket) printf '%s\n' absent; return 0 ;; esac
    svc_name=${svc_unit%.service}
    svc_rc=0
    case "$svc_backend" in
        openrc)
            rc-service -e "$svc_name" >/dev/null 2>&1 || svc_rc=$?
            case "$svc_rc" in 0) ;; 1) printf '%s\n' absent; return 0 ;; *) return 1 ;; esac
            rc-service "$svc_name" status >/dev/null 2>&1 || svc_rc=$? ;;
        sysv)
            if ! ssh_service_sysv_exists "$svc_name"; then printf '%s\n' absent; return 0; fi
            service "$svc_name" status >/dev/null 2>&1 || svc_rc=$? ;;
        *) return 1 ;;
    esac
    # LSB: 3 is stopped; arbitrary errors are not evidence of an inactive service.
    case "$svc_rc" in 0) printf '%s\n' active ;; 3) printf '%s\n' inactive ;; *) return 1 ;; esac
)

ssh_service_inventory() (
    svc_record="v1:$1"
    for svc_unit in ssh.service sshd.service ssh.socket sshd.socket; do
        svc_state=$(ssh_service_unit_state "$1" "$svc_unit") || { error "SSH 单元状态未知或正在变化: $svc_unit"; return 1; }
        svc_record="$svc_record:$svc_state"
    done
    printf '%s\n' "$svc_record"
)

ssh_service_record_valid() (
    svc_record=$1
    IFS=:; set -f
    # Split only our fixed six-field grammar; reject extra delimiters and controls.
    # shellcheck disable=SC2086
    set -- $svc_record
    [ "$#" = 6 ] && [ "$svc_record" = "v1:$2:$3:$4:$5:$6" ] || return 1
    case "$2" in systemd) ;; openrc|sysv) [ "$5:$6" = absent:absent ] || return 1 ;; *) return 1 ;; esac
    for svc_state in "$3" "$4" "$5" "$6"; do
        case "$svc_state" in active|inactive|absent|alias) ;; *) return 1 ;; esac
    done
    for svc_pair in "$3:$4" "$5:$6"; do
        case "$svc_pair" in active:active|alias:alias|alias:absent|absent:alias) return 1 ;; esac
    done
    case ":$svc_record:" in *:active:*|*:inactive:*) return 0 ;; *) return 1 ;; esac
)

ssh_service_snapshot() (
    svc_backend=$(ssh_service_backend) || return 1
    svc_record=$(ssh_service_inventory "$svc_backend") || return 1
    ssh_service_record_valid "$svc_record" || { error 'SSH 服务不存在、异常或有多个独立活动单元，未修改运行状态。'; return 1; }
    printf '%s\n' "$svc_record"
)

ssh_service_refresh_active() (
    svc_backend=$1 svc_unit=$2
    case "$svc_backend" in
        sysv) service "${svc_unit%.service}" reload ;;
        openrc) rc-service "${svc_unit%.service}" reload ;;
        systemd)
            svc_props=$(systemctl show -p CanReload -p KillMode -p ExecStop -p ExecStopPost "$svc_unit") || return 1
            svc_reload='' svc_kill='' svc_stop=unknown svc_post=unknown
            while IFS='=' read -r svc_key svc_val; do
                case "$svc_key" in
                    CanReload) svc_reload=$svc_val ;; KillMode) svc_kill=$svc_val ;;
                    ExecStop) svc_stop=$svc_val ;; ExecStopPost) svc_post=$svc_val ;;
                esac
            done <<EOF
$svc_props
EOF
            case "$svc_reload" in
                yes) if systemctl reload "$svc_unit"; then return 0; fi ;;
                no) ;;
                *) error "无法确认 reload 能力: $svc_unit"; return 1 ;;
            esac
            # A failing reload may overlap daemon-reload. Re-query the safety
            # properties (including empty ones) immediately before try-restart.
            if [ "$svc_kill" = process ]; then
                svc_props=$(systemctl show --all -p KillMode -p ExecStop -p ExecStopPost "$svc_unit") || return 1
                svc_kill='' svc_stop=unknown svc_post=unknown
                while IFS='=' read -r svc_key svc_val; do
                    case "$svc_key" in
                        KillMode) svc_kill=$svc_val ;; ExecStop) svc_stop=$svc_val ;; ExecStopPost) svc_post=$svc_val ;;
                    esac
                done <<EOF
$svc_props
EOF
            fi
            if [ "$svc_kill" != process ] || [ -n "$svc_stop$svc_post" ]; then
                error "拒绝可能终止现有 SSH 会话的 restart: $svc_unit"; return 1
            fi
            [ "$(ssh_service_unit_state systemd "$svc_unit")" = active ] || return 1
            warn "reload 不可用或失败；仅重启仍然活动的主进程: $svc_unit"
            systemctl try-restart "$svc_unit" ;;
        *) return 1 ;;
    esac
)

ssh_service_reconcile() (
    svc_mode=$1 svc_saved=$2
    ssh_service_record_valid "$svc_saved" || { error 'SSH 事务服务快照无效。'; return 1; }
    svc_backend=$(ssh_service_backend) || return 1
    case "$svc_saved" in "v1:$svc_backend:"*) ;; *) error 'SSH 服务管理器已变化。'; return 1 ;; esac
    svc_now=$(ssh_service_inventory "$svc_backend") || return 1
    if [ "$svc_mode" = apply ] && [ "$svc_now" != "$svc_saved" ]; then
        error 'SSH 服务自取样后已变化，拒绝盲目应用。'; return 1
    fi
    # Check *all* units before mutating any. A newly active daemon might belong
    # to a connection accepted by the socket: never stop it to fake an exact rollback.
    svc_wants=${svc_saved#v1:*:} svc_states=${svc_now#v1:*:}
    svc_service='' svc_socket='' svc_action=''
    for svc_unit in ssh.service sshd.service ssh.socket sshd.socket; do
        svc_want=${svc_wants%%:*} svc_wants=${svc_wants#*:}
        svc_state=${svc_states%%:*} svc_states=${svc_states#*:}
        case "$svc_want:$svc_state" in
            active:active|active:inactive|active:failed)
                case "$svc_unit" in
                    *.socket) if [ "$svc_state" != active ]; then svc_socket=$svc_unit; fi ;;
                    *) svc_service=$svc_unit; svc_action=start; if [ "$svc_state" = active ]; then svc_action=reload; fi ;;
                esac ;;
            inactive:inactive|alias:alias|absent:absent) ;;
            *) error "SSH 单元出现非预期变化 ($svc_unit $svc_want -> $svc_state)，不主动停止现有连接。"; return 1 ;;
        esac
    done
    if [ -n "$svc_service$svc_socket" ]; then ensure_run_sshd_dir || return 1; fi
    # Re-establish a lost, originally active listener socket first. Never enable
    # a unit, stop a socket or start a daemon that was originally dormant.
    if [ -n "$svc_socket" ]; then systemctl start "$svc_socket" || return 1; fi
    if [ -n "$svc_service" ]; then
        if [ "$svc_action" = reload ]; then
            ssh_service_refresh_active "$svc_backend" "$svc_service" || return 1
        else
            case "$svc_backend" in
                systemd) systemctl start "$svc_service" || return 1 ;;
                openrc) rc-service "${svc_service%.service}" start || return 1 ;;
                sysv) service "${svc_service%.service}" start || return 1 ;;
            esac
        fi
    else
        info '无活动的 SSH 常驻服务；保留 socket/停用状态，不强制启动。' >&2
    fi
    svc_now=$(ssh_service_inventory "$svc_backend") || return 1
    [ "$svc_now" = "$svc_saved" ] || { error '应用后 SSH 服务状态与原始快照不符。'; return 1; }
)

restart_ssh_service() (
    if [ "$#" = 0 ]; then
        svc_initial=$(ssh_service_snapshot) || return 1
        set -- "$svc_initial"
    fi
    [ "$#" = 1 ] && ssh_service_reconcile apply "$1"
)

ssh_service_restore() (
    [ "$#" = 1 ] && ssh_service_reconcile restore "$1"
)

write_hardened_sshd_config() {
    input="$1"
    output="$2"
    write_root=$(render_root_policy) || return 1
    awk -v root_policy="$write_root" '
        function setting_for(key) {
            key = tolower(key)
            if (key == "pubkeyauthentication") return "PubkeyAuthentication yes"
            if (key == "passwordauthentication") return "PasswordAuthentication no"
            if (key == "challengeresponseauthentication") return "ChallengeResponseAuthentication no"
            if (key == "kbdinteractiveauthentication") return "KbdInteractiveAuthentication no"
            if (key == "permitemptypasswords") return "PermitEmptyPasswords no"
            if (key == "permitrootlogin") return "PermitRootLogin " root_policy
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
            if (!seen_root) print "PermitRootLogin " root_policy
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

warn_match_override_risk() {
    warn "检测到 Match 块可能覆盖全局 SSH 安全策略，请确认特定用户/地址仍允许密码登录是否符合预期。"
    if [ -n "${MATCH_OVERRIDE_RISK:-}" ]; then
        warn "风险位置: $MATCH_OVERRIDE_RISK"
    fi
}

harden_ssh_config() {
    require_root
    with_write_lock harden_locked "${1:-}"
}

harden_locked() {
    if [ ! -f "$SSH_CONFIG" ] || ! tx_safe_path "$SSH_CONFIG"; then error "无效的 SSH 配置路径: $SSH_CONFIG"; return 1; fi
    hard_keys=$1
    hard_auth=''
    if [ -n "$hard_keys" ]; then
        prepare_authorized_keys || return 1
        hard_auth=$AUTHORIZED_KEYS_FILE
    fi
    auth_preflight "$SSH_CONFIG" "$hard_keys" || return 1
    hard_drop=$(sshd_hardening_dropin_path "$SSH_CONFIG" || :)
    if [ -n "$hard_drop" ] && [ -e "$hard_drop" ] && ! is_managed_ssh_init_dropin "$hard_drop"; then
        error "同名 drop-in 不属于 ssh-init，不覆盖: $hard_drop"; return 1
    fi
    tx_begin "$SSH_CONFIG" "$hard_drop" "$hard_auth" || return 1
    if [ -n "$hard_keys" ]; then
        tx_touch sshdir && tx_touch auth && append_keys_to_authorized_keys "$hard_keys" || return 1
    fi
    tx_stage_path "$SSH_CONFIG" && tx_copy_file "$SSH_CONFIG" "$SSHD_CONFIG_TMP_FILE" &&
        write_hardened_sshd_config "$SSH_CONFIG" "$SSHD_CONFIG_TMP_FILE" || return 1
    if cmp -s "$SSH_CONFIG" "$SSHD_CONFIG_TMP_FILE"; then
        rm -f "$SSHD_CONFIG_TMP_FILE" || return 1
    else
        tx_touch main || return 1
        mv -f "$SSHD_CONFIG_TMP_FILE" "$SSH_CONFIG" || { error '写入 SSH 配置失败。'; return 1; }
    fi
    SSHD_CONFIG_TMP_FILE=''
    if [ -n "$hard_drop" ]; then
        tx_touch drop || return 1
        write_sshd_hardening_dropin "$hard_drop" || return 1
    fi
    validate_sshd_config || { error 'sshd -t 校验失败。'; return 1; }
    hard_failures=$(make_tmp_file effective-check) || return 1
    if ! effective_sshd_settings_check "$SSH_CONFIG" "$hard_failures" "$SSH_INIT_ROOT_POLICY" "$hard_keys"; then
        print_effective_sshd_settings_failure "$hard_failures"; return 1
    fi
    info 'SSH 最终生效配置校验通过（静态检查，不是实际登录测试）。'
    tx_apply_service || { error 'SSH 服务配置应用失败。'; return 1; }
    if [ "${MATCH_OVERRIDE_RISK_FOUND:-0}" = 1 ]; then warn_match_override_risk; fi
    info "当前选择的全局 root 策略: $SSH_INIT_ROOT_POLICY"
}

current_auth_file() {
    user=$(current_user)
    home=$(home_dir_for_user "$user")
    printf '%s\n' "$home/.ssh/authorized_keys"
}

# Batch references are direct children of the configured store. A real slot
# may describe an absent file, so its .path, not its .data, identifies it.
restore_batch_dir_ok() {
    [ "${1%/*}" = "$SSH_CONFIG.ssh-init.d" ] && [ ! -L "$SSH_CONFIG.ssh-init.d" ] &&
        [ -d "$1" ] && [ ! -L "$1" ] || return 1
    case "${1##*/}" in
        batch.[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) return 0 ;;
        *) return 1 ;;
    esac
}

list_restore_batches() (
    if [ -L "$SSH_CONFIG.ssh-init.d" ]; then warn '事务目录是符号链接，拒绝读取。'; return 1; fi
    for rb_dir in "$SSH_CONFIG.ssh-init.d"/batch.*; do
        [ -e "$rb_dir" ] || [ -L "$rb_dir" ] || continue
        if ! restore_batch_dir_ok "$rb_dir" || { ! restore_has_record "$rb_dir" main && ! restore_has_record "$rb_dir" auth; }; then
            warn "忽略无效事务批次: $rb_dir"; continue
        fi
        for rb_slot in main auth sshdir drop other; do
            if restore_has_record "$rb_dir" "$rb_slot" &&
                { ! restore_regular_file "$rb_dir/$rb_slot.path" || ! restore_regular_file "$rb_dir/$rb_slot.meta"; }; then
                warn "忽略记录不完整的事务批次: $rb_dir ($rb_slot)"; continue 2
            fi
        done
        case "$1" in
            main|auth|drop) [ -f "$rb_dir/$1.path" ] || continue ;;
            both) if [ ! -f "$rb_dir/main.path" ] || [ ! -f "$rb_dir/auth.path" ]; then continue; fi ;;
            all) ;;
            *) return 1 ;;
        esac
        printf '%s\n' "$rb_dir"
    done | LC_ALL=C sort -r
)

find_restore_batch() (
    rb_latest=$(list_restore_batches "$1" | sed -n '1p')
    [ -n "$rb_latest" ] || return 1
    case "$1" in
        main|auth|both) restore_prepare_batch "$1" "$rb_latest" "$rb_latest" || return 2 ;;
        drop) restore_prepare_batch main "$rb_latest" "$rb_latest" || return 2 ;;
        *) return 1 ;;
    esac
    printf '%s\n' "$rb_latest"
)

restore_regular_file() { [ -f "$1" ] && [ ! -L "$1" ]; }

# Sort historical files by their timestamp suffix, not by .bak/.before-clear.
list_legacy_backups() (
    for rb_file in "$1".bak.* "$1".before-restore.* "$1".before-clear.*; do
        case "$rb_file" in *[[:cntrl:]]*) warn '忽略含控制字符的备份文件名。'; continue ;; esac
        restore_regular_file "$rb_file" || continue
        rb_suffix=${rb_file#"$1".}
        printf '%s\t%s\n' "${rb_suffix#*.}" "$rb_file"
    done | LC_ALL=C sort -r | cut -f2-
)

# Compatibility for callers of the old prefix.* file-lookup helpers.
list_matching_files_reverse() (
    case "$1" in *\*) ;; *) return 1 ;; esac
    for rb_file in "${1%\*}"*; do
        case "$rb_file" in *[[:cntrl:]]*) continue ;; esac
        restore_regular_file "$rb_file" && printf '%s\n' "$rb_file"
    done | LC_ALL=C sort -r
)

latest_matching_file() (
    rb_latest=$(list_matching_files_reverse "$1" | sed -n '1p')
    [ -n "$rb_latest" ] && printf '%s\n' "$rb_latest"
)

latest_slot_backup() (
    if rb_dir=$(find_restore_batch "$1"); then
        if restore_regular_file "$rb_dir/$1.data"; then
            printf '%s\n' "$rb_dir/$1.data"
        else
            printf '%s\n' "$rb_dir"
        fi
    else
        [ "$?" -eq 1 ] || return 1
        rb_latest=$(list_legacy_backups "$2" | sed -n '1p')
        [ -n "$rb_latest" ] && printf '%s\n' "$rb_latest"
    fi
)

latest_sshd_backup() { latest_slot_backup main "$SSH_CONFIG"; }
latest_authorized_keys_backup() { latest_slot_backup auth "$(current_auth_file)"; }
is_managed_ssh_init_dropin() {
    restore_regular_file "$1" && grep -Fq 'Managed by ssh-init' "$1" 2>/dev/null
}

list_backup_section() {
    printf '[%s]\n' "$1"
    if [ -n "$2" ]; then printf '%s\n' "$2" | awk '{print NR ") " $0}'; else printf '%s\n' '(无)'; fi
    print_blank
}

list_backups() (
    printf '%s\n' '[说明]' '优先恢复所选类型的最新事务批次；同时恢复不会拼接不同批次。' \
        'authorized_keys 恢复不是清空，而是恢复备份文件内容。'
    list_backup_section '可用事务批次（最新在前）' "$(list_restore_batches all)"
    list_backup_section '可用 sshd_config 备份（旧格式）' "$(list_legacy_backups "$SSH_CONFIG")"
    list_backup_section '可用 authorized_keys 备份（旧格式）' "$(list_legacy_backups "$(current_auth_file)")"
    if rb_drop=$(sshd_hardening_dropin_path "$SSH_CONFIG"); then
        list_backup_section '可用 SSH drop-in 备份（旧格式）' "$(list_legacy_backups "$rb_drop")"
    fi
)

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
            printf '\n%s\n' "[目标用户条件关键项：静态结果，不是登录测试]"
            debug_dns=$(awk '$1=="usedns" {print $2; exit}' "$effective_file") || return 1
            if debug_spec=$(ssh_auth_connection_spec "$debug_dns") &&
                "$sshd_bin" -T -C "$debug_spec" -f "$SSH_CONFIG" > "$effective_file"; then
                printf '%s\n' "-C $debug_spec"
                grep -Ei "$SSHD_EFFECTIVE_KEYS_RE" "$effective_file" || return 1
            else
                warn "无法解析当前连接条件；请手动指定 -C。"
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

# Validate a slot before using any recorded path, including before tx_begin.
# Comparing the complete path file also rejects extra lines and embedded NULs.
restore_check_slot() (
    rs_base=$1/$2
    restore_regular_file "$rs_base.path" && restore_regular_file "$rs_base.meta" &&
        printf '%s\n' "$3" | cmp -s - "$rs_base.path" || return 1
    [ ! -L "$rs_base.data" ] || return 1
    if printf 'absent\n' | cmp -s - "$rs_base.meta"; then
        [ ! -e "$rs_base.data" ]
    else
        LC_ALL=C awk '
            NR != 1 || $0 !~ /^[0-7]+ [0-9]+ [0-9]+ [01]$/ || length($1)>4 { bad=1 }
            END { exit (bad || NR!=1) }
        ' "$rs_base.meta" || return 1
        if [ "$2" = sshdir ]; then [ ! -e "$rs_base.data" ]; else restore_regular_file "$rs_base.data"; fi
    fi
)

restore_has_record() {
    [ -e "$1/$2.path" ] || [ -L "$1/$2.path" ] || [ -e "$1/$2.meta" ] ||
        [ -L "$1/$2.meta" ] || [ -e "$1/$2.data" ] || [ -L "$1/$2.data" ]
}

restore_check_drop() (
    if ! restore_has_record "$1" "$2"; then return 0; fi
    if ! restore_regular_file "$1/$2.path" || ! IFS= read -r rs_path < "$1/$2.path" ||
        [ -z "$rs_path" ] || { [ "$rs_path" != "$3" ] && [ "$rs_path" != "$4" ]; } ||
        ! restore_check_slot "$1" "$2" "$rs_path"; then
        error "无法确认事务批次的托管 drop-in 路径或元数据：$2"
        return 1
    fi
    printf '%s\n' "$rs_path"
)

restore_validate_main() {
    validate_sshd_config || { error '恢复后的 sshd_config 未通过 sshd -t，正在回滚。'; return 1; }
}

# Read-only preflight, shared by lookup and application (never trust a caller's
# previous lookup). Outputs rs_main/drop/other/auth/sshdir in the caller.
restore_prepare_batch() {
    rs_kind=$1
    case "$rs_kind" in
        main|auth) rs_batch=$2 ;;
        both) [ "$2" = "$3" ] || { error '拒绝拼接不同事务批次。'; return 1; }; rs_batch=$2 ;;
        *) return 1 ;;
    esac
    restore_batch_dir_ok "$rs_batch" || { error '无效事务批次。'; return 1; }
    rs_main='' rs_drop='' rs_other='' rs_auth=''
    if [ "$rs_kind" != auth ]; then
        rs_main=$SSH_CONFIG
        restore_check_slot "$rs_batch" main "$rs_main" || { error '批次 sshd_config 记录无效。'; return 1; }
        rs_current_drop=$(sshd_hardening_dropin_path "$rs_main" || :)
        rs_saved_drop=$(sshd_hardening_dropin_path "$rs_batch/main.data" || :)
        rs_drop=$(restore_check_drop "$rs_batch" drop "$rs_current_drop" "$rs_saved_drop") || return 1
        rs_other=$(restore_check_drop "$rs_batch" other "$rs_current_drop" "$rs_saved_drop") || return 1
        [ -z "$rs_other" ] || [ "$rs_other" != "$rs_drop" ] || { error '批次包含重复 drop-in 目标。'; return 1; }
    fi
    if [ "$rs_kind" != main ]; then
        rs_auth=$(current_auth_file) || return 1
        rs_sshdir=${rs_auth%/*}
        if ! restore_check_slot "$rs_batch" auth "$rs_auth" || ! restore_check_slot "$rs_batch" sshdir "$rs_sshdir"; then
            error '批次 authorized_keys 或 .ssh 目录记录无效。'; return 1
        fi
        if [ -f "$rs_batch/auth.data" ] && grep -qx 'absent' "$rs_batch/sshdir.meta"; then
            error '批次的 authorized_keys 与目录存在性冲突。'; return 1
        fi
    fi
    return 0
}

# Runs in the lock-owning shell: never put tx_begin or tx_apply_service in $().
restore_batch_locked() {
    restore_prepare_batch "$@" || return 1
    tx_begin "$rs_main" "$rs_drop" "$rs_auth" "$rs_other" || return 1
    if [ -n "$rs_main" ]; then
        tx_restore_slot "$rs_batch" main || return 1
        if [ -n "$rs_drop" ]; then tx_restore_slot "$rs_batch" drop || return 1; fi
        if [ -n "$rs_other" ]; then tx_restore_slot "$rs_batch" other || return 1; fi
        restore_validate_main || return 1
    fi
    if [ -n "$rs_auth" ]; then
        if [ ! -d "$rs_sshdir" ] && ! grep -qx 'absent' "$rs_batch/sshdir.meta"; then
            tx_touch sshdir && (umask 077; mkdir "$rs_sshdir") || return 1
        fi
        tx_restore_slot "$rs_batch" auth && tx_restore_slot "$rs_batch" sshdir || return 1
    fi
    if [ -n "$rs_main" ]; then tx_apply_service || return 1; fi
    return 0
}

# Return a historical suffix only for an identifiable main backup timestamp.
restore_legacy_suffix() (
    case "$1" in "$SSH_CONFIG.bak."*|"$SSH_CONFIG.before-restore."*) ;; *) return 1 ;; esac
    rs_suffix=${1#"$SSH_CONFIG".}
    rs_stamp=${rs_suffix#*.}
    case "${rs_stamp%%.*}" in
        [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]_[0-9][0-9][0-9][0-9][0-9][0-9]) ;;
        *) return 1 ;;
    esac
    printf '%s\n' "$rs_suffix"
)

restore_legacy_drop_install() {
    [ -n "$1" ] && [ -n "$2" ] || return 0
    if [ -e "$1.$2" ] || [ -L "$1.$2" ]; then
        restore_regular_file "$1.$2" && tx_install "$1.$2" "$1" || return 1
        info "已恢复 SSH drop-in: $1"
    elif [ "$3" = target ] && is_managed_ssh_init_dropin "$1"; then
        tx_touch drop && safe_rm_f "$1" || return 1
        info "已移除 ssh-init 创建的 drop-in: $1"
    fi
    return 0
}

restore_legacy_auth_install() {
    rs_dir=${2%/*}
    rs_user=$(current_user) || return 1
    tx_touch sshdir || return 1
    if [ ! -d "$rs_dir" ]; then (umask 077; mkdir "$rs_dir") || return 1; fi
    chmod 700 "$rs_dir" && set_owner "$rs_dir" "$rs_user" &&
        tx_install "$1" "$2" && tx_touch auth && chmod 600 "$2" && set_owner "$2" "$rs_user"
}

restore_legacy_locked() {
    rs_kind=$1 rs_main_src=$2 rs_auth_src=$3
    rs_main='' rs_drop='' rs_other='' rs_auth='' rs_suffix=
    warn '旧备份没有事务批次记录，无法确定文件属于同一次操作。'
    if [ "$rs_kind" != auth ]; then
        restore_regular_file "$rs_main_src" || { error '没有找到普通文件类型的 sshd_config 备份。'; return 1; }
        rs_main=$SSH_CONFIG
        rs_suffix=$(restore_legacy_suffix "$rs_main_src" || :)
        if [ -n "$rs_suffix" ]; then
            rs_drop=$(sshd_hardening_dropin_path "$rs_main_src" || :)
            rs_other=$(sshd_hardening_dropin_path "$SSH_CONFIG" || :)
            if [ "$rs_drop" = "$rs_other" ]; then rs_other=; fi
        fi
    fi
    if [ "$rs_kind" != main ]; then
        restore_regular_file "$rs_auth_src" || { error 'authorized_keys 恢复失败：没有找到普通文件类型的备份。'; return 1; }
        rs_auth=$(current_auth_file) || return 1
    fi
    tx_begin "$rs_main" "$rs_drop" "$rs_auth" "$rs_other" || return 1
    if [ -n "$rs_main" ]; then
        tx_install "$rs_main_src" "$rs_main" &&
            restore_legacy_drop_install "$rs_drop" "$rs_suffix" target &&
            restore_legacy_drop_install "$rs_other" "$rs_suffix" other && restore_validate_main || return 1
    fi
    if [ -n "$rs_auth" ]; then
        restore_legacy_auth_install "$rs_auth_src" "$rs_auth" || { error 'authorized_keys 恢复失败。'; return 1; }
    fi
    if [ -n "$rs_main" ]; then tx_apply_service || return 1; fi
    return 0
}

restore_batch_reference() (
    case "$1" in
        "$SSH_CONFIG.ssh-init.d"/*/"$2.data") rs_ref=${1%/*} ;;
        *) rs_ref=$1 ;;
    esac
    restore_batch_dir_ok "$rs_ref" && printf '%s\n' "$rs_ref"
)

restore_source_path() (
    case "$1" in *[[:cntrl:]]*) return 1 ;; esac
    [ ! -L "$1" ] || return 1
    if [ -d "$1" ]; then
        CDPATH='' cd -P -- "$1" && pwd -P
    elif [ -f "$1" ]; then
        rb_parent=$(ssh_init_dirname "$1") || return 1
        CDPATH='' cd -P -- "$rb_parent" && printf '%s/%s\n' "${PWD%/}" "${1##*/}"
    else
        # Let the typed entrypoint diagnose an absent backup without mutation.
        printf '%s\n' "$1"
    fi
)

restore_explicit_locked() {
    rs_mref='' rs_aref=''
    rs_ms=$(restore_source_path "$2") && rs_as=$(restore_source_path "$3") || return 1
    set -- "$1" "$rs_ms" "$rs_as"
    if [ "$1" != auth ]; then
        case "$2" in "$SSH_CONFIG.ssh-init.d"/*) rs_mref=$(restore_batch_reference "$2" main) || return 1 ;; esac
    fi
    if [ "$1" != main ]; then
        case "$3" in "$SSH_CONFIG.ssh-init.d"/*) rs_aref=$(restore_batch_reference "$3" auth) || return 1 ;; esac
    fi
    if [ -n "$rs_mref$rs_aref" ]; then
        if [ "$1" = both ] && [ "$rs_mref" != "$rs_aref" ]; then error '拒绝拼接不同事务批次或新旧备份。'; return 1; fi
        restore_batch_locked "$1" "${rs_mref:-$rs_aref}" "$rs_aref"
    else
        restore_legacy_locked "$1" "$2" "$3"
    fi
}

restore_legacy_pair_main() (
    rs_legacy=$(list_legacy_backups "$SSH_CONFIG")
    rs_auth_target=$(current_auth_file) || return 1
    while IFS= read -r rs_candidate; do
        rs_suffix=$(restore_legacy_suffix "$rs_candidate") || continue
        restore_regular_file "$rs_auth_target.$rs_suffix" || continue
        printf '%s\n' "$rs_candidate"
        return 0
    done <<EOF
$rs_legacy
EOF
    return 1
)

restore_latest_locked() {
    if rs_batch=$(find_restore_batch "$1"); then
        restore_batch_locked "$1" "$rs_batch" "$rs_batch"
        return $?
    else
        [ "$?" -eq 1 ] || return 1
    fi
    case "$1" in
        main) rs_source=$(latest_sshd_backup) || { error '没有 sshd_config 备份。'; return 1; }
              restore_legacy_locked main "$rs_source" '' ;;
        auth) rs_source=$(latest_authorized_keys_backup) || { error '没有 authorized_keys 备份。'; return 1; }
              restore_legacy_locked auth '' "$rs_source" ;;
        both) rs_source=$(restore_legacy_pair_main) || {
                  error '没有包含两项的同批次备份，也没有同时间戳的旧备份；可选择单项恢复。'; return 1;
              }
              restore_legacy_locked both "$rs_source" "$(current_auth_file).${rs_source#"$SSH_CONFIG".}" ;;
        *) return 1 ;;
    esac
}

restore_report() {
    if [ "$1" != auth ]; then
        success 'sshd_config 已恢复，SSH 服务配置已应用。'
        show_effective_ssh_config
        rs_pa=$(get_effective_sshd_value passwordauthentication)
        rs_pr=$(get_effective_sshd_value permitrootlogin)
        [ -z "$rs_pa" ] || info "当前 PasswordAuthentication: $rs_pa"
        [ -z "$rs_pr" ] || info "当前 PermitRootLogin: $rs_pr"
    fi
    if [ "$1" != main ]; then
        show_authorized_keys_summary "$(current_auth_file)"
        info 'authorized_keys 已恢复为备份时的内容；这不是清空 authorized_keys。'
    fi
    info '请新开终端测试 SSH 登录是否恢复正常。'
}

restore_run() {
    case "$2" in main|both) require_root || return 1 ;; auth) ;; *) return 1 ;; esac
    make_tmp_dir && with_write_lock "$@" && restore_report "$2"
}

restore_latest_backup() { restore_run restore_latest_locked "$1"; }
restore_sshd_config_from_backup() { restore_run restore_explicit_locked main "$1" ''; }
restore_authorized_keys_from_backup() { restore_run restore_explicit_locked auth '' "$1"; }
restore_sshd_and_authorized_keys_from_backups() { restore_run restore_explicit_locked both "$1" "$2"; }
restore_sshd_transaction() {
    case "$2" in
        0) restore_sshd_config_from_backup "$1" ;;
        1) restore_sshd_and_authorized_keys_from_backups "$1" "${3:-}" ;;
        *) return 1 ;;
    esac
}

clear_authorized_keys_locked() {
    rs_auth=$(current_auth_file) || return 1
    rs_empty=$(make_tmp_file clear-authorized-keys) || return 1
    tx_begin '' '' "$rs_auth" && restore_legacy_auth_install "$rs_empty" "$rs_auth"
}

clear_authorized_keys() {
    make_tmp_dir && with_write_lock clear_authorized_keys_locked || return 1
    success 'authorized_keys 已清空。'
    show_authorized_keys_summary "$(current_auth_file)"
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
3) 同时恢复同一批次的 sshd_config 和 authorized_keys
4) 查看当前 SSH 登录配置
5) 清空当前用户 authorized_keys（危险）
6) 返回主菜单
EOF
    ask_prompt "请选择 [1-6]:" || return 1
    choice=$ASK_REPLY
    case "$choice" in
        1) restore_latest_backup main ;;
        2) restore_latest_backup auth ;;
        3) restore_latest_backup both ;;
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
    if [ -f "$SSH_CONFIG.ssh-init.d/pending/active" ]; then
        warn "发现活动或未完成的 SSH 事务：$SSH_CONFIG.ssh-init.d/pending。若上次异常退出，请从 Console 选择恢复菜单中的写操作，并按提示恢复。"
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
