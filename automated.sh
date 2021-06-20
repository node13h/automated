#!/usr/bin/env bash

# Copyright (C) 2016-2021 Sergej Alikov <sergej.alikov@gmail.com>

# This file is part of Automated.

# Automated is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.

# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

set -euo pipefail


LOCAL=FALSE
AUTO_ATTACH=TRUE
IGNORE_FAILED=FALSE
DUMP_SCRIPT=FALSE
PREFIX_TARGET_OUTPUT=FALSE
PASS_STDIN=FALSE

CMD='main'

EXPORT_VARS=()
EXPORT_FUNCTIONS=()
LOAD_PATHS=()
COPY_PAIRS=()
DRAG_PAIRS=()
MACROS=()
TARGETS=()

SSH_COMMAND='ssh'

SUDO=FALSE
SUDO_PASSWORDLESS=FALSE
SUDO_PASSWORD_ON_STDIN=FALSE
SUDO_ASK_PASSWORD_CMD=ask_sudo_password

SUDO_UID_VARIABLE='AUTOMATED_SUDO_UID'
OWNER_UID_SOURCE="\${${SUDO_UID_VARIABLE}:-\$(id -u)}"

EXIT_TIMEOUT=65
EXIT_SUDO_PASSWORD_NOT_ACCEPTED=66
EXIT_SUDO_PASSWORD_REQUIRED=67


# This command is usually run on the controlling workstation, not remote
attach_to_multiplexer () {
    local multiplexer="${1}"
    local target="${2:-LOCAL HOST}"

    local -a handler
    local -a command

    local -a ssh_args

    if is_true "${LOCAL}"; then
        handler=(eval)
    else
        mapfile -t ssh_args < <(target_as_ssh_arguments "${target}")
        handler=("${SSH_COMMAND}" '-t' '-q' "$(quoted "${ssh_args[@]}")" '--')
    fi

    case "${multiplexer}" in
        tmux)
            # shellcheck disable=SC2016
            command=('tmux' '-S' "$(quoted "${AUTOMATED_TMUX_SOCK_PREFIX}-${OWNER_UID_SOURCE}")" 'attach')
            ;;

        # TODO screen
    esac

    msg_debug "Attaching via ${handler[*]}" BRIGHT_BLUE
    msg_debug "Attach command: ${command[*]}"

    eval "${handler[@]}" "${command[@]}"
}

ask_sudo_password () {
    local sudo_password

    if is_true "${SUDO_PASSWORD_ON_STDIN}"; then
        read -r sudo_password
    else
        sudo_password=$(interactive_secret "${1:-localhost}" "SUDO password")
    fi

    printf '%s\n' "${sudo_password}"
}

usage () {
    cat <<EOF
Usage: ${AUTOMATED_PROG} [OPTIONS] [[TARGET] ...]

Runs commands on local host or one or more remote targets.

TARGET

  Target is an address of the host you want to run the code on. It may
  include the username and the port number (user@example.com:22 for example).
  Target can be specified multiple times.


OPTIONS:

  -s, --sudo                  Use SUDO to do the calls
  --sudo-passwordless         Don't ask for SUDO password. Will ask anyway if
                              target insists.
  --sudo-password-on-stdin    Read SUDO password from STDIN
  --sudo-ask-password-cmd CMD Set command to use to ask user for SUDO password
                              The command will receive the current target as the
                              first argument.
                              Defaults to the built-in ask_sudo_password command.
                              Current value: ${SUDO_ASK_PASSWORD_CMD}
  -c, --call COMMAND          Command to call. Default is "${CMD}"
  -i, --inventory FILE        Load list of targets from the FILE
  -e, --export NAME           Make NAME from local environment available on the
                              remote side. NAME can be either variable or
                              function name. Functions have to be exported with
                              the 'export -f NAME' first (bash-specific).
                              May be specified multiple times
  -l, --load PATH             Load file at specified PATH before calling
                              the command; in case PATH is a directory -
                              load *.sh from it. Can be specified multiple times.
  --stdin                     Pass the STDIN of this script to the remote
                              command. Disabled by default.
  --cp LOCAL-SRC-FILE REMOTE-DST-FILE
                              Copy local file to the target(s).
                              Can be specified multiple times.
  --cp-list FILE              The FILE is a text file containing a list of the
                              source/destination file path pairs.
                              Pairs should be separated by spaces, one pair per
                              line. First goes the local source file path,
                              second - the remote destination file path.
                              Use the backslashes to escape the spaces and/or
                              special characters.
                              Can be specified multiple times.
  --drag LOCAL-SRC-FILE FILE-ID
                              Transport the local file to the target(s).
                              FILE-ID is a text identifier for referencing this
                              file in the drop function, must be unique for
                              every file. To actually write file on the remote
                              system use the drop FILE-ID, REMOTE-DST-FILE
                              function in the script.
                              Allows for the destination path calculation at
                              runtime on the remote side.
                              WARNING: This method is not suitable for the large
                              files as the contents will be kept in memory
                              during the execution of the script.
                              Can be specified multiple times.
  --drag-list FILE            Similar to the --cp-list, but will not write files
                              to the remote system until the drop function is
                              used (see --drag). First goes the local source
                              file path, second - the file id. One pair per line.
  -m, --macro EXPRESSION      Locally evaluate the EXPRESSION. The _output_ of
                              the EXPRESSION will be remotely executed by the
                              current target (current target is stored in
                              the \$target variable).
                              Use this to dynamically produce the target-
                              specific scripts.
                              Can be specified multiple times.
  -h, --help                  Display help text and exit
  --version                   Output version and exit
  -v, --verbose               Enable verbose output
  --local                     Do the local call only. Any remote targets will
                              be ignored.
  --dont-attach               When running a command in the terminal
                              multiplexer - proceed to the next host immediately
                              without attaching to the multiplexer.
  --ignore-failed             If one of the targets has failed - proceed to the
                              next one. Exit codes will be lost.
  --dump-script               Output compiled script to STDOUT. Do not run
                              anything. Implies the local operation.
  --tmux-sock-prefix PATH     Use custom PATH prefix for tmux socket on the
                              target.
                              Default: ${AUTOMATED_TMUX_SOCK_PREFIX}
  --tmux-fifo-prefix PATH     Use custom PATH prefix for the FIFO object to use
                              for communicating with tmux.
                              Default: ${AUTOMATED_TMUX_FIFO_PREFIX}
                              target.
  --prefix-target-output      Prefix all output from every target with
                              a "TARGET: "
  --ssh-command               Set the ssh client command. One of the use cases
                              is wrapping the ssh command in sshpass.
                              Will be eval'd.
                              Default: ${SSH_COMMAND}

EOF
}

automated_environment_script () {
    # shellcheck disable=SC2034
    local AUTOMATED_CURRENT_TARGET="${1}"

    local var fn pair macro path file_path

    local -a paths=()

    # TODO: Check if we're taliking about quoted() or "" here
    # OWNER_UID_SOURCE is not quoted intentionally!
    cat <<EOF
#!/usr/bin/env bash

set -euo pipefail

AUTOMATED_OWNER_UID=${OWNER_UID_SOURCE}
EOF
    file_as_function "${AUTOMATED_LIBDIR%/}/libautomated.sh" \
                     '__automated_libautomated'
    sourced_drop '__automated_libautomated'

    declared_var AUTOMATED_DEBUG
    declared_var AUTOMATED_CURRENT_TARGET
    declared_var AUTOMATED_TMUX_SOCK_PREFIX
    declared_var AUTOMATED_VERSION

    if [[ "${#EXPORT_VARS[@]}" -gt 0 ]]; then
        for var in "${EXPORT_VARS[@]}"; do
            declared_var "${var}"
        done
    fi

    if [[ "${#EXPORT_FUNCTIONS[@]}" -gt 0 ]]; then
        for fn in "${EXPORT_FUNCTIONS[@]}"; do
            declared_function "${fn}"
        done
    fi

    if [[ "${#DRAG_PAIRS[@]}" -gt 0 ]]; then
        for pair in "${DRAG_PAIRS[@]}"; do
            # shellcheck disable=SC2086
            file_as_function ${pair}
        done
    fi

    if [[ "${#LOAD_PATHS[@]}" -gt 0 ]]; then
        paths+=("${LOAD_PATHS[@]}")
    fi

    if [[ "${#paths[@]}" -gt 0 ]]; then
        for path in "${paths[@]}"; do
            if [[ -d "${path}" ]]; then
                for file_path in "${path%/}/"*.sh; do
                    file_as_function "${file_path}"
                    sourced_drop "${file_path}"
                done
            else
                file_as_function "${path}"
                sourced_drop "${path}"
            fi
        done
    fi

    if [[ "${#MACROS[@]}" -gt 0 ]]; then
        for macro in "${MACROS[@]}"; do
            eval "${macro}"
        done
    fi
}

rendered_script () {
    local target="${1}"
    local command="${2}"

    local pair

    # sudo password has to go first!
    if is_true "${SUDO}"; then
        if is_true "${DUMP_SCRIPT}"; then
            printf '%s\n' '*** SUDO PASSWORD IS HIDDEN IN SCRIPT DUMP MODE ***'
        else
            printf '%s\n' "${sudo_password}"  # This one will be consumed by the PTY helper
        fi
    fi

    automated_bootstrap_environment "${target}"

    if [[ "${#COPY_PAIRS[@]}" -gt 0 ]]; then
        for pair in "${COPY_PAIRS[@]}"; do
            # shellcheck disable=SC2086
            file_as_code ${pair}
        done
    fi

    # This block has to be the last block in the script as it
    # joins the STDIN of this script to the STDIN of the executed command
    if is_true "${PASS_STDIN}"; then
        cat <<EOF
{
    ${command}
    msg_debug 'done'

    # exit() is required so we don't try to execute the STDIN in case
    # no one has consumed it.
    # Exit code is always zero if we've got to this point (set -e in effect)
    exit 0

} < <(cat)
EOF
        cat
    else
        cat <<EOF
{
    ${command}
    msg_debug 'done'
}
EOF
    fi
}


handler_command () {
    local -a force_sudo_password="${1}"
    local -a handler=()

    local -a command_environment=()

    local packaged_pty_helper_script wrapper_command

    if is_true "${DUMP_SCRIPT}"; then
        handler=(cat)
    else
        if is_true "${LOCAL}"; then
            handler=(eval)
        else
            mapfile -t ssh_args < <(target_as_ssh_arguments "${target}")
            handler=("${SSH_COMMAND}" '-q' "${ssh_args[@]}" '--')
        fi

        if is_true "${SUDO}"; then
            for var in SUDO_UID_VARIABLE EXIT_TIMEOUT EXIT_SUDO_PASSWORD_NOT_ACCEPTED EXIT_SUDO_PASSWORD_REQUIRED; do
                command_environment+=("${var}=$(quoted "${!var}")")
            done

            packaged_pty_helper_script=$(gzip <"${AUTOMATED_LIBDIR%/}/pty_helper.py" | base64_encode)
            wrapper_command="\"\${PYTHON_INTERPRETER}\" <(\"\${PYTHON_INTERPRETER}\" -m base64 -d <<< ${packaged_pty_helper_script} | gunzip)"

            handler+=("PYTHON_INTERPRETER=\$(command -v python3 || command -v python2) && ${command_environment[*]} ${wrapper_command}")

            if ! is_true "${force_sudo_password}" && is_true "${SUDO_PASSWORDLESS}"; then
                handler+=("--sudo-passwordless")
            fi
        fi

        handler+=(bash)
    fi

    msg_debug "Executing via $(quoted "${handler[*]}")" BRIGHT_BLUE
    "${handler[@]}"
}


execute () {
    local command="${1}"
    local target="${2:-LOCAL HOST}"

    local sudo_password
    local force_sudo_password=FALSE

    local handler rc do_attach multiplexer
    local -a output_processor

    # Loop until SUDO password is accepted
    while true; do

        sudo_password=''

        rc=0

        if is_true "${SUDO}"; then
            if is_true "${force_sudo_password}" || ! is_true "${SUDO_PASSWORDLESS}"; then
                sudo_password=$("${SUDO_ASK_PASSWORD_CMD}" "${target}")
            fi
        fi

        msg_debug "Executing on ${target}"

        if is_true "${PREFIX_TARGET_OUTPUT}"; then
            output_processor=(prefixed_lines "${target}: ")
        else
            output_processor=(cat)
        fi

        set +e
        (
            set -e
            handler_command "${force_sudo_password}" > >("${output_processor[@]}") 2> >("${output_processor[@]}" >&2) < <(rendered_script "${target}" "${command}")
        )
        rc="$?"
        set -e

        case "${rc}" in
            "${EXIT_SUDO_PASSWORD_NOT_ACCEPTED}")
                if is_true "${SUDO_PASSWORD_ON_STDIN}"; then
                    msg_debug "SUDO password was provided on STDIN, but rejected by the target. Can't prompt, giving up"
                    break
                else
                    msg_debug 'SUDO password was rejected. Looping over'
                fi
                ;;

            "${EXIT_SUDO_PASSWORD_REQUIRED}")
                msg_debug "${target} requested the password for SUDO, disabling passwordless SUDO mode for this target and looping over."
                force_sudo_password=TRUE
                ;;
            *)
                break
                ;;
        esac

    done

    case "${rc}" in
        "${EXIT_TIMEOUT}")
            msg "Timeout while connecting to ${target}"
            ;;

        "${AUTOMATED_EXIT_MULTIPLEXER_ALREADY_RUNNING_TMUX}")
            msg "Terminal multiplexer appears to be already running. Attaching ..."
            do_attach=TRUE
            multiplexer='tmux'
            ;;

        "${AUTOMATED_EXIT_RUNNING_IN_TMUX}")
            do_attach="${AUTO_ATTACH}"
            multiplexer='tmux'
            ;;

        # TODO screen
        *)
            return "${rc}"
            ;;
    esac

    if is_true "${do_attach}"; then
        msg_debug "Attaching to multiplexer (${multiplexer}) ..."
        attach_to_multiplexer "${multiplexer}" "${target}"
    fi
}

parse_args () {
    local list_file inventory_file path line
    local -a pair

    while [[ "${#}" -gt 0 ]]; do

        case "${1}" in

            -h|--help|help|'')
                exit_after 0 usage
                ;;

            -v|--verbose)
                AUTOMATED_DEBUG=TRUE
                ;;

            --ssh-command)
                SSH_COMMAND="${2}"
                shift
                ;;

            -s|--sudo)
                SUDO=TRUE
                ;;

            --sudo-password-on-stdin)
                SUDO_PASSWORD_ON_STDIN=TRUE
                ;;

            --sudo-passwordless)
                SUDO_PASSWORDLESS=TRUE
                ;;

            --sudo-ask-password-cmd)
                SUDO_ASK_PASSWORD_CMD="${2}"
                shift
                ;;

            --dont-attach)
                AUTO_ATTACH=FALSE
                ;;

            --ignore-failed)
                IGNORE_FAILED=TRUE
                ;;

            --prefix-target-output)
                PREFIX_TARGET_OUTPUT=TRUE
                ;;

            --dump-script)
                DUMP_SCRIPT=TRUE
                LOCAL=TRUE
                ;;

            --tmux-sock-prefix)
                AUTOMATED_TMUX_SOCK_PREFIX="${2}"
                shift
                ;;

            --tmux-fifo-prefix)
                AUTOMATED_TMUX_FIFO_PREFIX="${2}"
                shift
                ;;

            --stdin)
                PASS_STDIN=TRUE
                ;;

            --cp)
                COPY_PAIRS+=("$(printf '%q %q' "${2}" "${3}")")
                shift 2
                ;;

            --cp-list)
                list_file="${2}"
                shift

                mapfile -t -O "${#COPY_PAIRS[@]}" COPY_PAIRS < "${list_file}"
                ;;

            --drag)
                DRAG_PAIRS+=("$(printf '%q %q' "${2}" "${3}")")
                shift 2
                ;;

            --drag-list)
                list_file="${2}"
                shift

                mapfile -t -O "${#DRAG_PAIRS[@]}" DRAG_PAIRS < "${list_file}"
                ;;

            -m|--macro)
                MACROS+=("${2}")
                shift
                ;;

            -l|--load)
                LOAD_PATHS+=("${2}")
                shift
                ;;

            -c|--call)
                CMD="${2}"
                shift
                ;;

            -e|--export)
                # NAME can be both function and variable at the same time
                if [[ "$(type -t "${2}")" = 'function' ]]; then
                    EXPORT_FUNCTIONS+=("${2}")
                fi
                if [[ "${!2+x}" = 'x' ]]; then
                    EXPORT_VARS+=("${2}")
                fi
                shift
                ;;

            -i|--inventory)
                inventory_file="${2}"
                shift
                if [[ -r "${inventory_file}" ]]; then
                    mapfile -t -O "${#TARGETS[@]}" TARGETS < "${inventory_file}"
                else
                    throw "Could not read inventory file"
                fi
                ;;

            --local)
                LOCAL=TRUE
                ;;

            --version)
                exit_after 0 printf '%s\n' "${AUTOMATED_VERSION}"
                ;;

            *)
                TARGETS+=("${1}")
                ;;
        esac

        shift

    done

    # Validate

    for path in "${LOAD_PATHS[@]}"; do
        [[ -r "${path}" ]] || throw "Load path ${path} is not readable"
    done

    for line in "${COPY_PAIRS[@]}"; do
        # shellcheck disable=SC2206
        pair=(${line})
        path="${pair[0]}"

        [[ -r "${path}" ]] || throw "Copy path ${path} is not readable"
        ! [[ -d "${path}" ]] || throw "Copy path ${path} is a directory"
    done

    for line in "${DRAG_PAIRS[@]}"; do
        # shellcheck disable=SC2206
        pair=(${line})
        path="${pair[0]}"

        [[ -r "${path}" ]] || throw "Drag path ${path} is not readable"
        ! [[ -d "${path}" ]] || throw "Copy path ${path} is a directory"
    done
}


main () {
    local rc target

    [[ "${#}" -gt 0 ]] || exit_after 1 usage >&2

    parse_args "$@"

    if is_true "${LOCAL}"; then
        execute "${CMD}"
    elif [[ "${#TARGETS[@]}" -gt 0 ]]; then
        for target in "${TARGETS[@]}"; do

            set +e
            (
                set -e
                execute "${CMD}" "${target}"
            )
            rc="$?"
            set -e

            if [[ "${rc}" -ne 0 ]]; then
                is_true "${IGNORE_FAILED}" || exit "${rc}"
            fi
        done
    else
        throw 'No targets specified'
    fi
}


if [[ -n "${BASH_SOURCE[0]:-}" && "${0}" = "${BASH_SOURCE[0]}" ]]; then

    AUTOMATED_PROG=$(basename "${BASH_SOURCE[0]:-}")
    AUTOMATED_PROG_DIR=$(dirname "${BASH_SOURCE[0]:-}")

    # shellcheck source=automated-config.sh
    source "${AUTOMATED_PROG_DIR%/}/automated-config.sh"
    # shellcheck source=libautomated.sh
    source "${AUTOMATED_LIBDIR%/}/libautomated.sh"

    main "${@}"
fi
