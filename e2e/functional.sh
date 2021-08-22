#!/usr/bin/env bash

# MIT license
# Copyright 2021 Sergej Alikov <sergej@alikov.com>

__DOC__='Functional tests for automated'

set -euo pipefail

# Run a command in the environment under test which has automated.sh pre-installed.
# This might be a local system, or a local container,
# or a remote machine (not implemented yet)
runcmd () {
    case "$APP_ENV_STACK_MODE" in
        container)
            declare -a vars=()
            declare var_name var_value

            # Bash stores exported functions in variables named BASH_FUNC_function_name%%
            # which are not accessible using Bash itself, but can be extracted using
            # other languages, like awk.
            # The following collects:
            #   - definitions for function names starting with a_test_
            #   - variable definitions for names starting with a_test_
            #   - variable definitions for names starting with AUTOMATED_
            #   - SSHD_ADDRESS SSHD_PORT SSHD_SUDO_PASSWORD variable definitions
            # into the vars array, so we can pass it to `env` later.
            while read -r var_name; do
                var_value=$(awk "BEGIN {print ENVIRON[\"${var_name}\"]}")
                vars+=("${var_name}=${var_value}")
            done < <(awk 'BEGIN{for(v in ENVIRON) if ( v ~ /^BASH_FUNC_a_test_|^a_test_|^AUTOMATED_|^SSHD_ADDRESS$|^SSHD_PORT$|^SSHD_SUDO_PASSWORD$|^APP_ENV_SUDO_PASSWORD$/ ) { print v }}')

            # Could also do env via -e
            podman exec --user testuser -i "$APP_ENV_CONTAINER" env "${vars[@]}" "$@"
            ;;
        remote-ssh)
            printf 'Not implemented yet!\n' >&2
            ;;
        kubernetes)
            printf 'Not implemented yet!\n' >&2
            ;;
        local)
            "$@"
            ;;
    esac
}

cleanup () {
    if [[ -v TEMP_DIR ]]; then
        runcmd rm -rf -- "${TEMP_DIR}/mylib"
        runcmd rmdir "$TEMP_DIR"
    fi
}

# We define our own trap before loading shelter.sh because shelter
# sets it's own EXIT trap, but also preserves existing ones.
trap cleanup EXIT

TEMP_DIR=$(runcmd mktemp -d)

# shellcheck disable=SC1091
source shelter.sh


test_local_env () {
    export AUTOMATED_EXECUTE_LOCALLY=TRUE

    # shellcheck disable=SC2016
    assert_stdout 'runcmd automated.sh -c "echo Hello   World"' <<"EOF"
Hello World
EOF
}

test_local_command () {
    # shellcheck disable=SC2016
    assert_stdout 'runcmd automated.sh -c "echo Hello   World" --local' <<"EOF"
Hello World
EOF
}

test_local_command_env () {
    export AUTOMATED_CALL_CMD='echo Hello   World'

    # shellcheck disable=SC2016
    assert_stdout 'runcmd automated.sh --local' <<"EOF"
Hello World
EOF
}

test_local_macro () {
    # shellcheck disable=SC2016
    assert_stdout 'runcmd automated.sh -m "echo MYVAR=Foo" -c "echo \$MYVAR" --local' <<"EOF"
Foo
EOF
}

test_local_load_file () {
    runcmd mkdir -p "${TEMP_DIR}/mylib"

    runcmd tee "${TEMP_DIR}/mylib/functions.sh" <<"EOF" >/dev/null
do_stuff () {
  echo "Hello World"
}
EOF

    # shellcheck disable=SC2016
    assert_stdout 'runcmd automated.sh -l "${TEMP_DIR}/mylib/functions.sh" -c do_stuff --local' <<"EOF"
Hello World
EOF

runcmd rm -rf -- "${TEMP_DIR}/mylib"

}

test_local_load_dir () {
    runcmd mkdir -p "${TEMP_DIR}/mylib"

    runcmd tee "${TEMP_DIR}/mylib/functions1.sh" <<"EOF" >/dev/null
do_stuff () {
  do_the_other_stuff
}
EOF

    runcmd tee "${TEMP_DIR}/mylib/functions2.sh" <<"EOF" >/dev/null
do_the_other_stuff () {
  echo "Hello World"
}
EOF

    runcmd tee "${TEMP_DIR}/mylib/somefile" <<"EOF" >/dev/null
# This file does not have the .sh extension
# therefore should be ignored
# and commands like
exit 99
# should have no effect
EOF

    # shellcheck disable=SC2016
    assert_stdout 'runcmd automated.sh -l "${TEMP_DIR}/mylib" -c do_stuff --local' <<"EOF"
Hello World
EOF

    runcmd rm -rf -- "${TEMP_DIR}/mylib"
}

test_local_exported_function () (

    a_test_function () {
        echo 'Hello World'
    }

    export -f a_test_function

    # shellcheck disable=SC2016
    assert_stdout 'runcmd automated.sh -e a_test_function -c a_test_function --local' <<"EOF"
Hello World
EOF
)

test_local_exported_variable () (

    a_test_variable=Foo
    export a_test_variable

    # shellcheck disable=SC2016
    assert_stdout 'runcmd automated.sh -e a_test_variable -c "echo \$a_test_variable" --local' <<"EOF"
Foo
EOF
)

test_local_exit_code () {
    # shellcheck disable=SC2016
    assert_fail 'runcmd automated.sh -c "exit 42" --local' 42
}

test_local_sudo_env_password_command () (

    a_test_sudo_ask_password_cmd () {
        printf '%s\n' "$APP_ENV_SUDO_PASSWORD"
    }

    export -f a_test_sudo_ask_password_cmd
    export AUTOMATED_SUDO_ENABLE=TRUE

    # shellcheck disable=SC2016
    assert_stdout 'runcmd automated.sh --sudo-ask-password-cmd a_test_sudo_ask_password_cmd -c "id -u" --local' <<"EOF"
0
EOF
)

test_local_sudo_password_command () (

    a_test_sudo_ask_password_cmd () {
        printf '%s\n' "$APP_ENV_SUDO_PASSWORD"
    }

    export -f a_test_sudo_ask_password_cmd

    # shellcheck disable=SC2016
    assert_stdout 'runcmd automated.sh -s --sudo-ask-password-cmd a_test_sudo_ask_password_cmd -c "id -u" --local' <<"EOF"
0
EOF
)

test_local_sudo_password_command_env () (

    a_test_sudo_ask_password_cmd () {
        printf '%s\n' "$APP_ENV_SUDO_PASSWORD"
    }

    export -f a_test_sudo_ask_password_cmd
    export AUTOMATED_SUDO_ASK_PASSWORD_CMD=a_test_sudo_ask_password_cmd

    # shellcheck disable=SC2016
    assert_stdout 'runcmd automated.sh -s -c "id -u" --local' <<"EOF"
0
EOF
)

test_local_sudo_password_stdin () {
    # shellcheck disable=SC2016
    assert_stdout 'runcmd automated.sh -s --sudo-password-on-stdin -c "id -u" --local <<< "$APP_ENV_SUDO_PASSWORD"' <<"EOF"
0
EOF
}

test_local_sudo_password_stdin_env () {
    export AUTOMATED_SUDO_PASSWORD_ON_STDIN=TRUE

    # shellcheck disable=SC2016
    assert_stdout 'runcmd automated.sh -s -c "id -u" --local <<< "$APP_ENV_SUDO_PASSWORD"' <<"EOF"
0
EOF
}

test_local_sudo_password_wrong () {
    # shellcheck disable=SC2016
    assert_fail 'runcmd automated.sh -s --sudo-password-on-stdin -c "id -u" --local <<< "THIS-PASSWORD-IS-WRONG" 2>/dev/null'
}

test_local_stdin () {
    # shellcheck disable=SC2016
    assert_stdout 'echo "Hello World" | runcmd automated.sh --stdin -c cat --local' <<"EOF"
Hello World
EOF
}

test_local_stdin_env () {
    export AUTOMATED_PASS_STDIN=TRUE

    # shellcheck disable=SC2016
    assert_stdout 'echo "Hello World" | runcmd automated.sh -c cat --local' <<"EOF"
Hello World
EOF
}

test_remote_command () {
    # shellcheck disable=SC2016
    assert_stdout 'runcmd automated.sh -c "echo Hello   World" "${SSHD_ADDRESS}:${SSHD_PORT}"' <<"EOF"
Hello World
EOF
}

test_remote_macro () {
    # shellcheck disable=SC2016
    assert_stdout 'runcmd automated.sh -m "echo MYVAR=Foo" -c "echo \$MYVAR" "${SSHD_ADDRESS}:${SSHD_PORT}"' <<"EOF"
Foo
EOF
}

test_remote_prefix_target_output () {
    # shellcheck disable=SC2016
    assert_stdout 'runcmd automated.sh --prefix-target-output -c "echo Hello World" "${SSHD_ADDRESS}:${SSHD_PORT}"' <<EOF
${SSHD_ADDRESS}:${SSHD_PORT}: Hello World
EOF
}

test_remote_prefix_target_output_env () {
    export AUTOMATED_PREFIX_TARGET_OUTPUT=TRUE

    # shellcheck disable=SC2016
    assert_stdout 'runcmd automated.sh -c "echo Hello World" "${SSHD_ADDRESS}:${SSHD_PORT}"' <<EOF
${SSHD_ADDRESS}:${SSHD_PORT}: Hello World
EOF
}

test_remote_custom_ssh_command () (

    a_test_ssh_command () {
        echo 'Executing custom ssh command'
        ssh "$@"
    }

    export -f a_test_ssh_command

    # shellcheck disable=SC2016
    assert_stdout 'runcmd automated.sh --ssh-command a_test_ssh_command -c "echo Hello   World" "${SSHD_ADDRESS}:${SSHD_PORT}"' <<"EOF"
Executing custom ssh command
Hello World
EOF
)

test_remote_custom_ssh_command_env () (

    a_test_ssh_command () {
        echo 'Executing custom ssh command'
        ssh "$@"
    }

    export -f a_test_ssh_command
    export AUTOMATED_SSH_CMD=a_test_ssh_command

    # shellcheck disable=SC2016
    assert_stdout 'runcmd automated.sh -c "echo Hello   World" "${SSHD_ADDRESS}:${SSHD_PORT}"' <<"EOF"
Executing custom ssh command
Hello World
EOF
)

test_remote_option_terminator () (

    a_test_ssh_command () {
        printf '%s\n' "$*"
    }

    export -f a_test_ssh_command

    # shellcheck disable=SC2016
    assert_stdout 'runcmd automated.sh --ssh-command a_test_ssh_command -- --help target2' <<"EOF"
-q --help -- bash
-q target2 -- bash
EOF
)

test_remote_load_file () {
    runcmd mkdir -p "${TEMP_DIR}/mylib"

    runcmd tee "${TEMP_DIR}/mylib/functions.sh" <<"EOF" >/dev/null
do_stuff () {
  echo "Hello World"
}
EOF

    # shellcheck disable=SC2016
    assert_stdout 'runcmd automated.sh -l "${TEMP_DIR}/mylib/functions.sh" -c do_stuff "${SSHD_ADDRESS}:${SSHD_PORT}"' <<"EOF"
Hello World
EOF

runcmd rm -rf -- "${TEMP_DIR}/mylib"

}

test_remote_load_dir () {
    runcmd mkdir -p "${TEMP_DIR}/mylib"

    runcmd tee "${TEMP_DIR}/mylib/functions1.sh" <<"EOF" >/dev/null
do_stuff () {
  do_the_other_stuff
}
EOF

    runcmd tee "${TEMP_DIR}/mylib/functions2.sh" <<"EOF" >/dev/null
do_the_other_stuff () {
  echo "Hello World"
}
EOF

    runcmd tee "${TEMP_DIR}/mylib/somefile" <<"EOF" >/dev/null
# This file does not have the .sh extension
# therefore should be ignored
# and commands like
exit 99
# should have no effect
EOF

    # shellcheck disable=SC2016
    assert_stdout 'runcmd automated.sh -l "${TEMP_DIR}/mylib" -c do_stuff "${SSHD_ADDRESS}:${SSHD_PORT}"' <<"EOF"
Hello World
EOF

    runcmd rm -rf -- "${TEMP_DIR}/mylib"
}

test_remote_exported_function () (

    a_test_function () {
        echo 'Hello World'
    }

    export -f a_test_function

    # shellcheck disable=SC2016
    assert_stdout 'runcmd automated.sh -e a_test_function -c a_test_function "${SSHD_ADDRESS}:${SSHD_PORT}"' <<"EOF"
Hello World
EOF
)

test_remote_exported_variable () (

    a_test_variable=Foo
    export a_test_variable

    # shellcheck disable=SC2016
    assert_stdout 'runcmd automated.sh -e a_test_variable -c "echo \$a_test_variable" "${SSHD_ADDRESS}:${SSHD_PORT}"' <<"EOF"
Foo
EOF
)

test_remote_exit_code () {
    # shellcheck disable=SC2016
    assert_fail 'runcmd automated.sh -c "exit 42" "${SSHD_ADDRESS}:${SSHD_PORT}"' 42
}

test_remote_sudo_password_command () (

    a_test_sudo_ask_password_cmd () {
        if [[ "$1" == "${SSHD_ADDRESS}:${SSHD_PORT}" ]]; then
            printf '%s\n' "$SSHD_SUDO_PASSWORD"
        else
            exit 1
        fi
    }

    export -f a_test_sudo_ask_password_cmd

    # shellcheck disable=SC2016
    assert_stdout 'runcmd automated.sh -s --sudo-ask-password-cmd a_test_sudo_ask_password_cmd -c "id -u" "${SSHD_ADDRESS}:${SSHD_PORT}"' <<"EOF"
0
EOF
)

test_remote_sudo_password_stdin () {
    # shellcheck disable=SC2016
    assert_stdout 'runcmd automated.sh -s --sudo-password-on-stdin -c "id -u" "${SSHD_ADDRESS}:${SSHD_PORT}" <<< "$SSHD_SUDO_PASSWORD"' <<"EOF"
0
EOF
}

test_remote_sudo_password_wrong () {
    # shellcheck disable=SC2016
    assert_fail 'runcmd automated.sh -s --sudo-password-on-stdin -c "id -u" "${SSHD_ADDRESS}:${SSHD_PORT}" <<< "THIS-PASSWORD-IS-WRONG" 2>/dev/null'
}

test_remote_stdin () {
    # shellcheck disable=SC2016
    assert_stdout 'echo "Hello World" | runcmd automated.sh --stdin -c cat "${SSHD_ADDRESS}:${SSHD_PORT}"' <<"EOF"
Hello World
EOF
}


suite () {
    shelter_run_test_class Local test_local_
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
    for var in SSHD_ADDRESS SSHD_PORT SSHD_SUDO_PASSWORD APP_ENV_STACK_MODE APP_ENV_SUDO_PASSWORD; do
        if ! [[ -v "$var" ]]; then
            printf 'Variable %s is required, but not defined!\n' "$var" >&2
            exit 1
        fi
    done

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
