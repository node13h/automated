#!/usr/bin/env bash

# MIT license
# Copyright 2021 Sergej Alikov <sergej@alikov.com>

__DOC__='Functional tests for automated'

set -euo pipefail

# shellcheck disable=SC1091
source shelter.sh


automated_sh_cmd () {
    if [[ -n "$APP_CONTAINER" ]]; then
        declare -a flags=()

        if [[ -t 0 ]]; then
            flags+=(-it)
        else
            flags+=(-i)
        fi
        podman exec "${flags[@]}" "$APP_CONTAINER" automated.sh "$@"
    else
        automated.sh "$@"
    fi
}

# TODO: Test running exported functions remotely
# TODO: Test exporting vars
# TODO: Test macros
# TODO: Test sudo password command
# TODO: Test custom ssh command
# TODO: Test local command
# TODO: Test local sudo command

test_remote_command () {
    # shellcheck disable=SC2016
    assert_stdout 'automated_sh_cmd -c "echo Hello   World" "${SSHD_ADDRESS}:${SSHD_PORT}"' <<"EOF"
Hello World
EOF
}

test_remote_exit_code () {
    # shellcheck disable=SC2016
    assert_fail 'automated_sh_cmd -c "exit 42" "${SSHD_ADDRESS}:${SSHD_PORT}"' 42
}

test_remote_sudo_password_stdin () {
    # shellcheck disable=SC2016
    assert_stdout 'automated_sh_cmd -s --sudo-password-on-stdin -c "id -u" "${SSHD_ADDRESS}:${SSHD_PORT}" <<< "$SUDO_PASSWORD"' <<"EOF"
0
EOF
}

test_remote_sudo_password_wrong () {
    # shellcheck disable=SC2016
    assert_fail 'automated_sh_cmd -s --sudo-password-on-stdin -c "id -u" "${SSHD_ADDRESS}:${SSHD_PORT}" <<< "THIS-PASSWORD-IS-WRONG" 2>/dev/null'
}

test_remote_stdin () {
    # shellcheck disable=SC2016
    assert_stdout 'echo "Hello World" | automated_sh_cmd --stdin -c cat "${SSHD_ADDRESS}:${SSHD_PORT}"' <<"EOF"
Hello World
EOF
}


suite () {
    shelter_run_test_class Remote test_remote_
}

usage () {
    cat <<EOF
Usage: ${0} [--help]
${__DOC__}

ENVIRONMENT VARIABLES:
  ENABLE_CI_MODE    set to non-empty value to enable the Junit XML
                    output mode

EOF
}

main () {
    if [[ "${1:-}" = '--help' ]]; then
        usage
        return 0
    fi

    declare var
    for var in SSHD_ADDRESS SSHD_PORT SUDO_PASSWORD; do
        if ! [[ -v "$var" ]]; then
            printf 'Variable %s is required, but not defined!\n' "$var" >&2
            exit 1
        fi
    done

    if [[ -v APP_CONTAINER ]]; then
        printf 'Executing tests in the app container %s\n' "$APP_CONTAINER" >&2
    else
        printf 'Executing tests using a system-wide copy of automated.sh\n' >&2
    fi

    supported_shelter_versions 0.7

    if [[ -n "${ENABLE_CI_MODE:-}" ]]; then
        mkdir -p junit
        shelter_run_test_suite suite | shelter_junit_formatter >junit/test_automated_functional.xml
    else
        shelter_run_test_suite suite | shelter_human_formatter
    fi
}


if ! (return 2>/dev/null); then
    main "$@"
fi
