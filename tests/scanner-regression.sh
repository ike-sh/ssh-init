#!/bin/sh

# Sourced by run.sh; each case owns its globals and files in a subshell.
scanner_regression_case() {
    scanner_case_name="$1"
    scanner_case_kind="$2"
    scanner_case_dir=$(make_test_dir)
    if (
        scanner_config="$scanner_case_dir/sshd_config"
        scanner_child="$scanner_case_dir/child.conf"
        case "$scanner_case_kind" in
            match-include)
                printf 'Match User deploy\n    Include %s\n' "$scanner_child" > "$scanner_config"
                printf '%s\n' 'AuthenticationMethods publickey,password' > "$scanner_child"
                ! detect_authentication_methods_risk "$scanner_config" || exit 1
                [ "$AUTHENTICATION_METHODS_SCAN_FAILED" = 0 ] || exit 1
                case "$AUTHENTICATION_METHODS_RISK" in *"$scanner_child:1:"*) ;; *) exit 1 ;; esac
                ;;
            siblings)
                printf 'Include %s\nInclude %s\n' "$scanner_child" "$scanner_case_dir/danger.conf" > "$scanner_config"
                printf '%s\n' '# harmless first Include' > "$scanner_child"
                printf '%s\n' 'AuthenticationMethods publickey,keyboard-interactive' > "$scanner_case_dir/danger.conf"
                ! detect_authentication_methods_risk "$scanner_config" || exit 1
                [ "$AUTHENTICATION_METHODS_SCAN_FAILED" = 0 ] || exit 1
                case "$AUTHENTICATION_METHODS_RISK" in *danger.conf:1:*) ;; *) exit 1 ;; esac
                ;;
            nested)
                scanner_i=0
                while [ "$scanner_i" -lt 6 ]; do
                    printf 'Include %s/level%s.conf\n' "$scanner_case_dir" "$((scanner_i + 1))" > "$scanner_case_dir/level$scanner_i.conf"
                    scanner_i=$((scanner_i + 1))
                done
                printf '%s\n' 'AuthenticationMethods publickey,password' > "$scanner_case_dir/level6.conf"
                ! detect_authentication_methods_risk "$scanner_case_dir/level0.conf" || exit 1
                [ "$AUTHENTICATION_METHODS_SCAN_FAILED" = 0 ] || exit 1
                ;;
            inherited-match)
                printf 'Match User deploy\nInclude %s\n' "$scanner_child" > "$scanner_config"
                printf '%s\n' 'PasswordAuthentication yes' > "$scanner_child"
                detect_match_override_risk "$scanner_config" || exit 1
                [ "$MATCH_OVERRIDE_SCAN_FAILED" = 0 ] || exit 1
                case "$MATCH_OVERRIDE_RISK" in *"$scanner_child:1:"*) ;; *) exit 1 ;; esac
                ;;
            isolated-match)
                printf 'Include %s\nInclude %s\n' "$scanner_child" "$scanner_case_dir/global.conf" > "$scanner_config"
                printf '%s\n' 'Match User deploy' 'PasswordAuthentication no' > "$scanner_child"
                printf '%s\n' 'PasswordAuthentication yes' > "$scanner_case_dir/global.conf"
                ! detect_match_override_risk "$scanner_config" || exit 1
                [ "$MATCH_OVERRIDE_SCAN_FAILED" = 0 ] || exit 1
                ;;
            global-dropin)
                mkdir "$scanner_case_dir/sshd_config.d" || exit 1
                printf 'Match User deploy\nInclude %s/sshd_config.d/*.conf\n' "$scanner_case_dir" > "$scanner_config"
                ! sshd_hardening_dropin_path "$scanner_config" > "$scanner_case_dir/path" || exit 1
                [ ! -s "$scanner_case_dir/path" ] || exit 1
                ;;
            quoted-glob)
                mkdir -p "$scanner_case_dir/quoted dir/nested" || exit 1
                printf 'Include "%s/quoted dir/*/*.conf"\n' "$scanner_case_dir" > "$scanner_config"
                printf '%s\n' 'AuthenticationMethods publickey,password' > "$scanner_case_dir/quoted dir/nested/auth.conf"
                ! detect_authentication_methods_risk "$scanner_config" || exit 1
                [ "$AUTHENTICATION_METHODS_SCAN_FAILED" = 0 ] || exit 1
                ;;
            cycle)
                printf 'Include %s\n' "$scanner_config" > "$scanner_config"
                ! detect_authentication_methods_risk "$scanner_config" || exit 1
                [ "$AUTHENTICATION_METHODS_SCAN_FAILED" = 1 ] || exit 1
                ;;
            bad-include)
                mkdir "$scanner_case_dir/not-a-file" || exit 1
                printf 'Include %s/not-a-file\n' "$scanner_case_dir" > "$scanner_config"
                ! detect_authentication_methods_risk "$scanner_config" || exit 1
                [ "$AUTHENTICATION_METHODS_SCAN_FAILED" = 1 ] || exit 1
                SSH_CONFIG=$scanner_config
                IKE_TEST_UID=0
                cp "$scanner_config" "$scanner_case_dir/before" || exit 1
                if (harden_ssh_config); then exit 1; fi
                cmp -s "$scanner_config" "$scanner_case_dir/before" || exit 1
                [ "$(find "$scanner_case_dir" -name 'sshd_config.bak.*' | wc -l | tr -d ' ')" = 0 ] || exit 1
                ;;
            malformed)
                printf '%s\n' 'Include "unterminated' > "$scanner_config"
                ! detect_authentication_methods_risk "$scanner_config" || exit 1
                [ "$AUTHENTICATION_METHODS_SCAN_FAILED" = 1 ] || exit 1
                ;;
            equals)
                printf 'Match=User deploy\nInclude = "%s"\n' "$scanner_child" > "$scanner_config"
                printf '%s\n' 'AuthenticationMethods=publickey,password' > "$scanner_child"
                ! detect_authentication_methods_risk "$scanner_config" || exit 1
                [ "$AUTHENTICATION_METHODS_SCAN_FAILED" = 0 ] || exit 1
                printf '%s\n' 'PasswordAuthentication = yes' > "$scanner_child"
                detect_match_override_risk "$scanner_config" || exit 1
                [ "$MATCH_OVERRIDE_SCAN_FAILED" = 0 ] || exit 1
                ;;
            equals-writer)
                printf '%s\n' 'Port=2222' 'PasswordAuthentication=yes' 'Match=User deploy' '    PasswordAuthentication=yes' > "$scanner_config"
                write_hardened_sshd_config "$scanner_config" "$scanner_case_dir/written" || exit 1
                grep -qx 'Port=2222' "$scanner_case_dir/written" || exit 1
                grep -qx 'PasswordAuthentication no' "$scanner_case_dir/written" || exit 1
                grep -qx 'Match=User deploy' "$scanner_case_dir/written" || exit 1
                grep -qx '    PasswordAuthentication=yes' "$scanner_case_dir/written" || exit 1
                ;;
            safe)
                printf 'Include %s\nMatch User deploy\nAuthenticationMethods publickey\n' "$scanner_child" > "$scanner_config"
                printf '%s\n' '# AuthenticationMethods publickey,password' 'PubkeyAuthentication yes' > "$scanner_child"
                detect_authentication_methods_risk "$scanner_config" || exit 1
                ! detect_match_override_risk "$scanner_config" || exit 1
                ;;
            unique|fallback)
                if [ "$scanner_case_kind" = fallback ]; then
                    # Invoked by make_tmp_file in init.sh, not directly here.
                    # shellcheck disable=SC2317,SC2329
                    command_exists() { [ "$1" != mktemp ] && command -v "$1" >/dev/null 2>&1; }
                fi
                scanner_first=$(make_tmp_file scanner-unique) || exit 1
                printf '%s\n' 'preserve first file' > "$scanner_first" || exit 1
                scanner_second=$(make_tmp_file scanner-unique) || exit 1
                [ "$scanner_first" != "$scanner_second" ] || exit 1
                grep -qx 'preserve first file' "$scanner_first" || exit 1
                ;;
            no-parent-dir)
                TMP_DIR=""
                TMPDIR="$scanner_case_dir"
                if scanner_unowned=$(make_tmp_file unowned); then exit 1; fi
                [ -z "$scanner_unowned" ] || exit 1
                [ "$(find "$scanner_case_dir" -mindepth 1 | wc -l | tr -d ' ')" = 0 ] || exit 1
                ;;
            *) exit 1 ;;
        esac
    ) > "$scanner_case_dir.log" 2>&1; then
        pass "$scanner_case_name"
    else
        fail "$scanner_case_name"
        cat "$scanner_case_dir.log" >&2
    fi
    rm -rf "$scanner_case_dir"
    rm -f "$scanner_case_dir.log"
}

scanner_regression_case 'Match Include authentication chain is detected' match-include
scanner_regression_case 'later sibling Include is not truncated by recursion' siblings
scanner_regression_case 'nested Includes beyond three levels are scanned' nested
scanner_regression_case 'included directives inherit Match context' inherited-match
scanner_regression_case 'child Match context does not leak into sibling Includes' isolated-match
scanner_regression_case 'Match-only Include is not chosen for global hardening drop-in' global-dropin
scanner_regression_case 'quoted Include paths and parent directory globs are scanned' quoted-glob
scanner_regression_case 'Include cycles fail closed rather than being skipped' cycle
scanner_regression_case 'unscannable Include aborts hardening before mutation' bad-include
scanner_regression_case 'malformed Include fails closed' malformed
scanner_regression_case 'equals separators cannot bypass Include or Match risk scanning' equals
scanner_regression_case 'writer handles equals separators without changing Match or Port' equals-writer
scanner_regression_case 'safe authentication and commented risks remain accepted' safe
scanner_regression_case 'temporary files are unique and preserve earlier contents' unique
scanner_regression_case 'temporary fallback does not clobber an earlier file' fallback
scanner_regression_case 'temporary helper never creates an unowned directory' no-parent-dir
