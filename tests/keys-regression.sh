#!/bin/sh

# Sourced by tests/run.sh after its fixture helpers and init.sh are loaded.

keys_regression_append_case() {
    keys_case_name="$1"
    keys_case_existing="$2"
    keys_case_new="$3"
    keys_case_terminated="$4"
    keys_case_tmp=$(make_test_dir)
    if (
        setup_home "$keys_case_tmp"
        mkdir -p "$IKE_TEST_HOME/.ssh" || exit 1
        keys_case_auth="$IKE_TEST_HOME/.ssh/authorized_keys"
        printf '%s' "$keys_case_existing" > "$keys_case_auth" || exit 1
        if [ "$keys_case_terminated" = "yes" ]; then
            printf '\n' >> "$keys_case_auth" || exit 1
        fi
        printf '%s\n' "$keys_case_new" > "$keys_case_tmp/import" || exit 1
        printf '%s\n' "$keys_case_existing" "$keys_case_new" > "$keys_case_tmp/expected" || exit 1
        append_keys_to_authorized_keys "$keys_case_tmp/import" > "$keys_case_tmp/out" 2>&1 || exit 1
        cmp -s "$keys_case_tmp/expected" "$keys_case_auth" || exit 1
        grep -Fxq "$keys_case_new" "$keys_case_auth" || exit 1
        has_mode "$keys_case_auth" 600 || exit 1
    ); then
        pass "$keys_case_name"
    else
        fail "$keys_case_name"
    fi
    rm -rf "$keys_case_tmp"
}

test_authorized_keys_unterminated_comment() {
    keys_regression_append_case "append separates a new key from an unterminated comment" "# existing comment" "$VALID_KEY" no
}

test_authorized_keys_unterminated_public_key() {
    keys_regression_append_case "append preserves an unterminated old public key" "$VALID_KEY" "$VALID_KEY_2" no
}

test_authorized_keys_terminated_public_key() {
    keys_regression_append_case "append does not add a blank line after an existing LF" "$VALID_KEY" "$VALID_KEY_2" yes
}

test_authorized_keys_unterminated_duplicate() {
    keys_case_tmp=$(make_test_dir)
    if (
        setup_home "$keys_case_tmp"
        mkdir -p "$IKE_TEST_HOME/.ssh" || exit 1
        keys_case_auth="$IKE_TEST_HOME/.ssh/authorized_keys"
        printf '%s' "$VALID_KEY" > "$keys_case_auth" || exit 1
        cp "$keys_case_auth" "$keys_case_tmp/original" || exit 1
        printf '%s\n' "$VALID_KEY" > "$keys_case_tmp/import" || exit 1
        append_keys_to_authorized_keys "$keys_case_tmp/import" > "$keys_case_tmp/out" 2>&1 || exit 1
        cmp -s "$keys_case_tmp/original" "$keys_case_auth" || exit 1
    ); then
        pass "duplicate import leaves an unterminated existing key unchanged"
    else
        fail "duplicate import leaves an unterminated existing key unchanged"
    fi
    rm -rf "$keys_case_tmp"
}

keys_regression_gen_case() {
    keys_case_name="$1"
    keys_case_assume_yes="$2"
    keys_case_initial_reply="$3"
    keys_case_saved_reply="$4"
    keys_case_expect="$5"
    keys_case_output_failure="${6:-none}"
    keys_case_tmp=$(make_test_dir)
    if (
        TMP_DIR="$keys_case_tmp/work"
        SSH_INIT_ASSUME_YES="$keys_case_assume_yes"
        export SSH_INIT_ASSUME_YES
        mkdir "$TMP_DIR" || exit 1
        printf '%s\n' "original-authorized-keys" > "$keys_case_tmp/authorized_keys" || exit 1
        printf '%s\n' "PasswordAuthentication yes" > "$keys_case_tmp/sshd_config" || exit 1
        cp "$keys_case_tmp/authorized_keys" "$keys_case_tmp/original-authorized-keys" || exit 1
        cp "$keys_case_tmp/sshd_config" "$keys_case_tmp/original-sshd-config" || exit 1
        : > "$keys_case_tmp/in" || exit 1
        if [ "$keys_case_initial_reply" != "EOF" ]; then
            printf '%s\n' "$keys_case_initial_reply" >> "$keys_case_tmp/in" || exit 1
        fi
        if [ "$keys_case_saved_reply" != "EOF" ]; then
            printf '%s\n' "$keys_case_saved_reply" >> "$keys_case_tmp/in" || exit 1
        fi

        # Invoked indirectly by gen_mode from the separately sourced init.sh.
        # shellcheck disable=SC2317,SC2329
        generate_ed25519_key_pair() {
            GENERATED_PRIVATE_KEY_FILE="$TMP_DIR/generated_ed25519"
            GENERATED_PUBLIC_KEY_FILE="$GENERATED_PRIVATE_KEY_FILE.pub"
            printf '%s\n' "MOCK-PRIVATE-KEY-ONLY-FOR-TESTS" > "$GENERATED_PRIVATE_KEY_FILE" || return 1
            printf '%s\n' "$VALID_KEY" > "$GENERATED_PUBLIC_KEY_FILE"
        }
        # Invoked indirectly by gen_mode from the separately sourced init.sh.
        # shellcheck disable=SC2317,SC2329
        filter_valid_keys() {
            cp "$1" "$2" || return 1
            printf '%s\n' 1
        }
        # Invoked indirectly by gen_mode from the separately sourced init.sh.
        # shellcheck disable=SC2317,SC2329
        append_keys_to_authorized_keys() {
            grep -Fxq "$VALID_KEY" "$1" || die "mock expected a valid public key"
            printf '\nMOCK_APPEND\n'
            printf '%s\n' "appended" > "$keys_case_tmp/authorized_keys"
        }
        # Invoked indirectly by gen_mode from the separately sourced init.sh.
        # shellcheck disable=SC2317,SC2329
        harden_ssh_config() {
            printf '%s\n' "MOCK_HARDEN"
            printf '%s\n' "PasswordAuthentication no" > "$keys_case_tmp/sshd_config"
        }
        # The key-printing functions in init.sh call this fixture-only mock.
        # shellcheck disable=SC2317,SC2329
        cat() {
            case "$keys_case_output_failure:${1:-}" in
                public-cat:*/generated_ed25519.pub|private-cat:*/generated_ed25519)
                    return 1
                    ;;
            esac
            command cat "$@"
        }
        if [ "$keys_case_output_failure" = "public-heading" ] ||
            [ "$keys_case_output_failure" = "private-heading" ]; then
            # Exercise propagation of a formatting failure before key output.
            # shellcheck disable=SC2317,SC2329
            print_section_title() {
                case "$keys_case_output_failure:$1" in
                    "public-heading:请复制以下公钥到 GitHub"|"private-heading:请复制保存以下私钥")
                        return 1
                        ;;
                esac
                print_line || return 1
                printf ' %s\n' "$1" || return 1
                print_line
            }
        fi

        keys_case_rc=0
        gen_mode < "$keys_case_tmp/in" > "$keys_case_tmp/out" 2>&1 || keys_case_rc=$?
        [ ! -e "$TMP_DIR/generated_ed25519" ] || exit 1
        [ ! -e "$TMP_DIR/generated_ed25519.pub" ] || exit 1
        ! grep -Eq "该公钥已自动写入|密码登录已禁用" "$keys_case_tmp/out" || exit 1
        if [ "$keys_case_expect" = "success" ]; then
            [ "$keys_case_rc" -eq 0 ] || exit 1
            grep -Fxq "appended" "$keys_case_tmp/authorized_keys" || exit 1
            grep -Fxq "PasswordAuthentication no" "$keys_case_tmp/sshd_config" || exit 1
            awk '
                /^ssh-ed25519 / { public_line = NR }
                /^MOCK-PRIVATE-KEY-ONLY-FOR-TESTS$/ { private_line = NR }
                /确认私钥已保存到本地/ { confirm_line = NR }
                /^MOCK_APPEND$/ { append_line = NR }
                /^MOCK_HARDEN$/ { harden_line = NR }
                END {
                    exit !(public_line > 0 && private_line > public_line &&
                        confirm_line > private_line && append_line > confirm_line &&
                        harden_line > append_line)
                }
            ' "$keys_case_tmp/out" || exit 1
        else
            [ "$keys_case_rc" -ne 0 ] || exit 1
            cmp -s "$keys_case_tmp/original-authorized-keys" "$keys_case_tmp/authorized_keys" || exit 1
            cmp -s "$keys_case_tmp/original-sshd-config" "$keys_case_tmp/sshd_config" || exit 1
            ! grep -Eq '^MOCK_APPEND$|^MOCK_HARDEN$' "$keys_case_tmp/out" || exit 1
            if [ "$keys_case_output_failure" != "none" ]; then
                grep -q "无法完整显示密钥" "$keys_case_tmp/out" || exit 1
                ! grep -q "确认私钥已保存到本地" "$keys_case_tmp/out" || exit 1
            fi
        fi
    ); then
        pass "$keys_case_name"
    else
        fail "$keys_case_name"
    fi
    rm -rf "$keys_case_tmp"
}

test_gen_delivers_keys_before_authentication_changes() {
    keys_regression_gen_case "gen delivers both keys and confirms SAVED before authentication changes" 0 yes SAVED success
}

test_gen_initial_cancel_preserves_authentication() {
    keys_regression_gen_case "gen initial cancellation leaves authentication unchanged" 0 no EOF cancelled
}

test_gen_saved_cancel_preserves_authentication() {
    keys_regression_gen_case "gen rejects lowercase saved and removes temporary keys without authentication changes" 0 yes saved cancelled
}

test_gen_saved_eof_preserves_authentication() {
    keys_regression_gen_case "gen EOF at the SAVED prompt leaves authentication unchanged" 0 yes EOF cancelled
}

test_gen_assume_yes_still_requires_saved() {
    keys_regression_gen_case "ASSUME_YES cannot bypass SAVED confirmation on EOF" 1 EOF EOF cancelled
}

test_gen_assume_yes_rejects_generic_yes() {
    keys_regression_gen_case "ASSUME_YES still rejects a generic yes instead of SAVED" 1 EOF yes cancelled
}

test_gen_assume_yes_accepts_explicit_saved() {
    keys_regression_gen_case "ASSUME_YES proceeds only after explicit SAVED confirmation" 1 EOF SAVED success
}

test_gen_public_key_read_failure_preserves_authentication() {
    keys_regression_gen_case "gen public-key read failure cancels before SAVED and authentication changes" 0 yes SAVED cancelled public-cat
}

test_gen_private_key_read_failure_preserves_authentication() {
    keys_regression_gen_case "gen private-key read failure cancels before SAVED and authentication changes" 0 yes SAVED cancelled private-cat
}

test_gen_public_key_output_failure_preserves_authentication() {
    keys_regression_gen_case "gen public-key heading output failure leaves authentication unchanged" 0 yes SAVED cancelled public-heading
}

test_gen_private_key_output_failure_preserves_authentication() {
    keys_regression_gen_case "gen private-key heading output failure leaves authentication unchanged" 0 yes SAVED cancelled private-heading
}

test_authorized_keys_unterminated_comment
test_authorized_keys_unterminated_public_key
test_authorized_keys_terminated_public_key
test_authorized_keys_unterminated_duplicate
test_gen_delivers_keys_before_authentication_changes
test_gen_initial_cancel_preserves_authentication
test_gen_saved_cancel_preserves_authentication
test_gen_saved_eof_preserves_authentication
test_gen_assume_yes_still_requires_saved
test_gen_assume_yes_rejects_generic_yes
test_gen_assume_yes_accepts_explicit_saved
test_gen_public_key_read_failure_preserves_authentication
test_gen_private_key_read_failure_preserves_authentication
test_gen_public_key_output_failure_preserves_authentication
test_gen_private_key_output_failure_preserves_authentication
