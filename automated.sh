#!/usr/bin/env bash

# Copyright (C) 2016-2017 Sergej Alikov <sergej.alikov@gmail.com>

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

AUTOMATED_PROG=$(basename "${BASH_SOURCE[0]:-}")
AUTOMATED_PROG_DIR=$(dirname "${BASH_SOURCE[0]:-}")

# shellcheck source=automated-config.sh
source "${AUTOMATED_PROG_DIR%/}/automated-config.sh"
# shellcheck source=libautomated.sh
source "${AUTOMATED_LIBDIR%/}/libautomated.sh"

# TODO Throw error on unsupported systems (CentOS5, perhaps Ubuntu 10.04)

FACTDIR="${AUTOMATED_LIBDIR%/}/facts"

LOCAL=FALSE
AUTO_ATTACH=TRUE
IGNORE_FAILED=FALSE
DUMP_SCRIPT=FALSE
AUTOLOAD_FACTS=TRUE
PREFIX_TARGET_OUTPUT=FALSE
PASS_STDIN=FALSE

CMD='main'

EXPORT_VARS=()
EXPORT_FUNCTIONS=()
LOAD_PATHS=()
COPY_PAIRS=()
DRAG_PAIRS=()
MACROS=()


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
                              Default: ${TMUX_SOCK_PREFIX}
  --no-autoload-facts         Disable autoloading of the ${FACTDIR%/}/*.sh
  --prefix-target-output      Prefix all output from every target with
                              a "TARGET: "

EOF
}

rendered_script () {
    local target="${1}"
    local command="${2}"

    local path macro var fn pair
    local -a paths=()

    # sudo password has to go first!
    if is_true "${SUDO}"; then
        if is_true "${DUMP_SCRIPT}"; then
            printf '%s\n' '*** SUDO PASSWORD IS HIDDEN IN SCRIPT DUMP MODE ***'
        else
            printf '%s\n' "${sudo_password}"  # This one will be consumed by the PTY helper
        fi
    fi

    cat <<"EOF"
#!/usr/bin/env bash

set -euo pipefail
EOF
    sourced_file "${AUTOMATED_LIBDIR%/}/libautomated.sh"

    printf 'DEBUG=%s\n' "$(quoted "${DEBUG}")"
    printf 'AUTOMATED_OWNER_UID=%s\n' "${OWNER_UID_SOURCE}"  # Do not quote!
    printf 'TMUX_SOCK_PREFIX=%s\n' "$(quoted "${TMUX_SOCK_PREFIX}")"
    printf 'CURRENT_TARGET=%s\n' "$(quoted "${target}")"

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

    if [[ "${#COPY_PAIRS[@]}" -gt 0 ]]; then
        for pair in "${COPY_PAIRS[@]}"; do
            # shellcheck disable=SC2086
            file_as_code ${pair}
        done
    fi

    if [[ "${#DRAG_PAIRS[@]}" -gt 0 ]]; then
        for pair in "${DRAG_PAIRS[@]}"; do
            # shellcheck disable=SC2086
            file_as_function ${pair}
        done
    fi

    if is_true "${AUTOLOAD_FACTS}"; then
        paths+=("${FACTDIR}")
    fi

    if [[ "${#LOAD_PATHS[@]}" -gt 0 ]]; then
        paths+=("${LOAD_PATHS[@]}")
    fi

    if [[ "${#paths[@]}" -gt 0 ]]; then
        while read -r path; do
            sourced_file "${path}"
        done < <(loadable_files "${paths[@]}")
    fi

    if [[ "${#MACROS[@]}" -gt 0 ]]; then
        for macro in "${MACROS[@]}"; do
            eval "${macro}"
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


execute () {
    local command="${1}"
    local target="${2:-LOCAL HOST}"

    local sudo_password
    local force_sudo_password=FALSE

    local handler rc do_attach multiplexer
    local -a output_processor

    # Loop until SUDO password is accepted
    while true; do

        if is_true "${DUMP_SCRIPT}"; then
            handler=(cat)
        else
            if is_true "${LOCAL}"; then
                handler=(eval)
            else
                handler=(ssh -q $(target_as_ssh_arguments "${target}") --)
            fi

            handler+=("$(in_proper_context bash "${force_sudo_password}")")
        fi

        sudo_password=''

        rc=0

        if is_true "${SUDO}"; then
            if is_true "${force_sudo_password}" || ! is_true "${SUDO_PASSWORDLESS}"; then
                sudo_password=$(ask_sudo_password "${target}")
            fi
        fi

        msg_debug "Executing on ${target}"

        if is_true "${PREFIX_TARGET_OUTPUT}"; then
            output_processor=(prefixed_lines "${target}: ")
        else
            output_processor=(cat)
        fi

        { cmd "${handler[@]}" > >("${output_processor[@]}") 2> >("${output_processor[@]}" >&2) || rc=$?; } < <(rendered_script "${target}" "${command}")

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

        "${EXIT_MULTIPLEXER_ALREADY_RUNNING_TMUX}")
            msg "Terminal multiplexer appears to be already running. Attaching ..."
            do_attach=TRUE
            multiplexer='tmux'
            ;;

        "${EXIT_RUNNING_IN_TMUX}")
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
        attach_to_multiplexer "${multiplexer}" "${target}" || msg "Unable to attach to multiplexer on ${target}. Perhaps it completed it's job and exited already?"
    fi
}

main () {
    local inventory_file rc
    local -a targets=()

    [[ "${#}" -gt 0 ]] || exit_after 1 usage | to_stderr

    while [[ "${#}" -gt 0 ]]; do

        case "${1}" in

            -h|--help|help|'')
                exit_after 0 usage
                ;;

            -v|--verbose)
                DEBUG=TRUE
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
                TMUX_SOCK_PREFIX="${2}"
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
                    mapfile -t -O "${#targets[@]}" targets < "${inventory_file}"
                else
                    throw "Could not read inventory file"
                fi
                ;;

            --local)
                LOCAL=TRUE
                ;;

            --no-autoload-facts)
                AUTOLOAD_FACTS=FALSE
                ;;

            --version)
                exit_after 0 printf '%s\n' "${AUTOMATED_VERSION}"
                ;;

            *)
                targets+=("${1}")
                ;;
        esac

        shift

    done

    if is_true "${LOCAL}"; then
        execute "${CMD}"
    elif [[ "${#targets[@]}" -gt 0 ]]; then
        for target in "${targets[@]}"; do

            rc=0

            execute "${CMD}" "${target}" || rc=$?

            if [[ "${rc}" -ne 0 ]]; then
                is_true "${IGNORE_FAILED}" || exit "${rc}"
            fi
        done
    else
        throw "No targets specified"
    fi
}


if [[ -n "${BASH_SOURCE[0]:-}" && "${0}" = "${BASH_SOURCE[0]}" ]]; then
    main "${@}"
fi
