#!/bin/sh

# Sourced by run.sh. The service and validation hooks below are case-local.
restore_regression_case() {
    restore_case_name="$1"
    restore_case_kind="$2"
    restore_case_dir=$(make_test_dir)
    if (
        setup_home "$restore_case_dir"
        mkdir -p "$restore_case_dir/sshd_config.d" "$IKE_TEST_HOME/.ssh" || exit 1
        SSH_CONFIG="$restore_case_dir/sshd_config"
        RUN_SSHD_DIR="$restore_case_dir/run/sshd"
        restore_case_dropin="$restore_case_dir/sshd_config.d/00-ssh-init-hardening.conf"
        restore_case_auth="$IKE_TEST_HOME/.ssh/authorized_keys"
        restore_case_backup="$SSH_CONFIG.bak.20260101_000000"
        printf 'Include %s/sshd_config.d/*.conf\nPasswordAuthentication no\n' "$restore_case_dir" > "$SSH_CONFIG"
        printf 'Include %s/sshd_config.d/*.conf\nPasswordAuthentication yes\n' "$restore_case_dir" > "$restore_case_backup"
        write_sshd_hardening_dropin_content "$restore_case_dropin" || exit 1
        printf '%s\n' 'PasswordAuthentication yes' > "$restore_case_dropin.bak.20260101_000000"
        printf '%s\n' 'original-authorized-keys' > "$restore_case_auth"
        printf '%s\n' 'restored-authorized-keys' > "$restore_case_auth.bak.test"
        cp "$SSH_CONFIG" "$restore_case_dir/main-before" || exit 1
        cp "$restore_case_dropin" "$restore_case_dir/dropin-before" || exit 1
        cp "$restore_case_auth" "$restore_case_dir/auth-before" || exit 1

        # All four hooks are invoked indirectly by the sourced implementation.
        # shellcheck disable=SC2317,SC2329
        require_root() { return 0; }
        # shellcheck disable=SC2317,SC2329
        unlock_immutable_if_needed() { SSHD_CONFIG_WAS_IMMUTABLE=0; }
        # shellcheck disable=SC2317,SC2329
        validate_sshd_config() { ! grep -q '^Broken yes$' "$SSH_CONFIG"; }
        # shellcheck disable=SC2317,SC2329
        restart_ssh_service() {
            printf '%s\n' 'restart' >> "$restore_case_dir/restarts"
            case "$restore_case_kind" in
                restart-fail|both-restart-fail)
                    [ "$(wc -l < "$restore_case_dir/restarts" | tr -d ' ')" -gt 1 ]
                    ;;
                *) return 0 ;;
            esac
        }
        # shellcheck disable=SC2317,SC2329
        show_effective_ssh_config() { printf '%s\n' 'passwordauthentication no' 'permitrootlogin prohibit-password'; }

        case "$restore_case_kind" in
            validate-existing|validate-removed)
                printf '%s\n' 'Broken yes' >> "$restore_case_backup"
                if [ "$restore_case_kind" = validate-removed ]; then
                    rm -f "$restore_case_dropin.bak.20260101_000000"
                fi
                if restore_sshd_config_from_backup "$restore_case_backup"; then exit 1; fi
                [ ! -e "$restore_case_dir/restarts" ] || exit 1
                ;;
            restart-fail)
                if restore_sshd_config_from_backup "$restore_case_backup"; then exit 1; fi
                [ "$(wc -l < "$restore_case_dir/restarts" | tr -d ' ')" = 2 ] || exit 1
                ;;
            both-auth-fail|both-auth-missing)
                if [ "$restore_case_kind" = both-auth-missing ]; then rm -f "$restore_case_auth"; fi
                # Simulate a partial write followed by an I/O or metadata error.
                # shellcheck disable=SC2317,SC2329
                restore_authorized_keys_from_backup() {
                    printf '%s\n' 'partial replacement' > "$restore_case_auth"
                    return 1
                }
                if restore_sshd_and_authorized_keys_from_backups "$restore_case_backup" "$restore_case_auth.bak.test"; then exit 1; fi
                [ ! -e "$restore_case_dir/restarts" ] || exit 1
                ;;
            both-restart-fail)
                if restore_sshd_and_authorized_keys_from_backups "$restore_case_backup" "$restore_case_auth.bak.test"; then exit 1; fi
                [ "$(wc -l < "$restore_case_dir/restarts" | tr -d ' ')" = 2 ] || exit 1
                ;;
            different-directory)
                mkdir -p "$restore_case_dir/other/sshd_config.d" || exit 1
                restore_case_other="$restore_case_dir/other/sshd_config.d/00-ssh-init-hardening.conf"
                printf 'Include %s/other/sshd_config.d/*.conf\nBroken yes\n' "$restore_case_dir" > "$restore_case_backup"
                printf '%s\n' 'PasswordAuthentication yes' > "$restore_case_other.bak.20260101_000000"
                if restore_sshd_config_from_backup "$restore_case_backup"; then exit 1; fi
                [ ! -e "$restore_case_other" ] || exit 1
                ;;
            success|repeated)
                restore_sshd_and_authorized_keys_from_backups "$restore_case_backup" "$restore_case_auth.bak.test" || exit 1
                cmp -s "$SSH_CONFIG" "$restore_case_backup" || exit 1
                grep -qx 'PasswordAuthentication yes' "$restore_case_dropin" || exit 1
                grep -qx 'restored-authorized-keys' "$restore_case_auth" || exit 1
                if [ "$restore_case_kind" = repeated ]; then
                    restore_sshd_config_from_backup "$restore_case_backup" || exit 1
                fi
                exit 0
                ;;
            *) exit 1 ;;
        esac
        cmp -s "$SSH_CONFIG" "$restore_case_dir/main-before" || exit 1
        cmp -s "$restore_case_dropin" "$restore_case_dir/dropin-before" || exit 1
        if [ "$restore_case_kind" = both-auth-missing ]; then
            [ ! -e "$restore_case_auth" ] || exit 1
        else
            cmp -s "$restore_case_auth" "$restore_case_dir/auth-before" || exit 1
        fi
    ) > "$restore_case_dir.log" 2>&1; then
        pass "$restore_case_name"
    else
        fail "$restore_case_name"
        cat "$restore_case_dir.log" >&2
    fi
    rm -rf "$restore_case_dir"
    rm -f "$restore_case_dir.log"
}

restore_regression_case 'validation failure restores an overwritten drop-in' validate-existing
restore_regression_case 'validation failure recreates a removed managed drop-in' validate-removed
restore_regression_case 'restart failure restores main and drop-in before retry' restart-fail
restore_regression_case 'partial authorized_keys failure rolls back all files' both-auth-fail
restore_regression_case 'failed combined restore removes an originally absent authorized_keys' both-auth-missing
restore_regression_case 'combined restart failure restores authorized_keys as well' both-restart-fail
restore_regression_case 'rollback preserves both Include directories and absent target state' different-directory
restore_regression_case 'successful combined restore commits all three files' success
restore_regression_case 'repeated restores use distinct recovery snapshots' repeated
