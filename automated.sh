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

AUTOMATED_EXECUTE_LOCALLY="${AUTOMATED_EXECUTE_LOCALLY:-FALSE}"
AUTOMATED_AUTO_ATTACH="${AUTOMATED_AUTO_ATTACH:-TRUE}"
AUTOMATED_IGNORE_FAILED="${AUTOMATED_IGNORE_FAILED:-FALSE}"
AUTOMATED_DUMP_SCRIPT="${AUTOMATED_DUMP_SCRIPT:-FALSE}"
AUTOMATED_PREFIX_TARGET_OUTPUT="${AUTOMATED_PREFIX_TARGET_OUTPUT:-FALSE}"
AUTOMATED_PASS_STDIN="${AUTOMATED_PASS_STDIN:-FALSE}"
AUTOMATED_CALL_CMD="${AUTOMATED_CALL_CMD:-main}"
AUTOMATED_SSH_CMD="${AUTOMATED_SSH_CMD:-ssh}"
AUTOMATED_SUDO_ENABLE="${AUTOMATED_SUDO_ENABLE:-FALSE}"
AUTOMATED_SUDO_PASSWORDLESS="${AUTOMATED_SUDO_PASSWORDLESS:-FALSE}"
AUTOMATED_SUDO_PASSWORD_ON_STDIN="${AUTOMATED_SUDO_PASSWORD_ON_STDIN:-FALSE}"
AUTOMATED_SUDO_ASK_PASSWORD_CMD="${AUTOMATED_SUDO_ASK_PASSWORD_CMD:-ask_sudo_password}"
AUTOMATED_FUNCTRACE_DEPTH="${AUTOMATED_FUNCTRACE_DEPTH:-2}"
AUTOMATED_SINGLETON_ENABLE="${AUTOMATED_SINGLETON_ENABLE:-FALSE}"
AUTOMATED_SINGLETON_LOCK_FILE="${AUTOMATED_SINGLETON_LOCK_FILE:-/tmp/automated-lock}"

declare -a EXPORT_VARS=()
declare -a EXPORT_FUNCTIONS=()
declare -a LOAD_PATHS=()
declare -a COPY_PAIRS=()
declare -a DRAG_PAIRS=()
declare -a MACROS=()
declare -a TARGETS=()

SUDO_UID_VARIABLE='AUTOMATED_SUDO_UID'

EXIT_TIMEOUT=65
EXIT_SUDO_PASSWORD_NOT_ACCEPTED=66
EXIT_SUDO_PASSWORD_REQUIRED=67


ssh_command () {
    declare command_quoted
    command_quoted=$(set -e; quoted "$@")

    eval "${AUTOMATED_SSH_CMD} ${command_quoted}"
}


# This command is usually run on the controlling workstation, not remote
attach_to_multiplexer () {
    declare multiplexer="$1"
    declare target="${2:-LOCAL HOST}"

    declare -a handler
    declare command

    declare -a ssh_args

    if is_true "$AUTOMATED_EXECUTE_LOCALLY"; then
        handler=(eval)
    else
        mapfile -t ssh_args < <(target_as_ssh_arguments "$target")
        handler=('ssh_command' '-t' '-q' "${ssh_args[@]}" '--')
    fi

    case "$multiplexer" in
        tmux)
            declare socket_quoted
            socket_quoted=$(set -e; quoted "$AUTOMATED_TMUX_SOCK_PREFIX")

            # shellcheck disable=SC2016
            command="tmux -S ${socket_quoted}-\"\$(id -u)\" attach"
            ;;
    esac

    log_debug "Attaching via ${handler[*]}" BRIGHT_BLUE
    log_debug "Attach command: ${command}"

    "${handler[@]}" "$command"
}


ask_sudo_password () {
    declare sudo_password

    if is_true "$AUTOMATED_SUDO_PASSWORD_ON_STDIN"; then
        read -r sudo_password
    else
        sudo_password=$(set -e; interactive_secret "${1:-localhost}" "SUDO password")
    fi

    printf '%s\n' "$sudo_password"
}


usage () {
    cat <<EOF
Usage: ${AUTOMATED_PROG} [OPTIONS] [[TARGET] ...]

Runs commands on local host or one or more remote targets.

TARGET

  Target is an address of the host you want to run the code on. It may
  include a username and a port number (user@example.com:22 for example).
  Target can be specified multiple times.


OPTIONS:

  -s, --sudo                  Use SUDO to do the calls
                              Default: ${AUTOMATED_SUDO_ENABLE}
                              Env: AUTOMATED_SUDO_ENABLE
  --sudo-passwordless         Don't ask for SUDO password. Will ask anyway if
                              target insists.
                              Default: ${AUTOMATED_SUDO_PASSWORDLESS}
                              Env: AUTOMATED_SUDO_PASSWORDLESS
  --sudo-password-on-stdin    Read SUDO password from STDIN
                              Default: ${AUTOMATED_SUDO_PASSWORD_ON_STDIN}
                              Env: AUTOMATED_SUDO_PASSWORD_ON_STDIN
  --sudo-ask-password-cmd CMD Set command to use to ask user for SUDO password
                              The command will receive the current target as the
                              first argument.
                              Default: ${AUTOMATED_SUDO_ASK_PASSWORD_CMD}
                              Env: AUTOMATED_SUDO_ASK_PASSWORD_CMD
  -c, --call COMMAND          Command to call
                              Default: ${AUTOMATED_CALL_CMD}
                              Env: AUTOMATED_CALL_CMD
  -i, --inventory FILE        Load list of targets from the FILE
  -e, --export VARIABLE[=VALUE]
                              Make VARIABLE from the local environment available
                              on the remote side.
                              May be specified multiple times.
  --export-fn FUNCTION        Make FUNCTION from the local environment available
                              on the remote side. Functions have to be exported
                              with 'export -f FUNCTION' first (bash-specific).
                              May be specified multiple times.
  -l, --load PATH             Load file at specified PATH before calling
                              the command; in case PATH is a directory -
                              load *.sh from it. Can be specified multiple times.
  --stdin                     Pass the STDIN of this script to the remote
                              command.
                              Default: ${AUTOMATED_PASS_STDIN}
                              Env: AUTOMATED_PASS_STDIN
  --cp LOCAL-SRC-FILE REMOTE-DST-FILE
                              Copy local file to the target(s).
                              Can be specified multiple times.
  --cp-list FILE              The FILE is a text file containing a list of the
                              source/destination file path pairs.
                              Pairs should be separated by spaces, one pair per
                              line. First goes the local source file path,
                              second - the remote destination file path.
                              Use backslashes to escape spaces and/or
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
                              WARNING: This method is not suitable for large
                              files as the contents will be kept in memory
                              during the execution of the script.
                              Can be specified multiple times.
  --drag-list FILE            Similar to --cp-list, but will not write files
                              to the remote system until the drop function is
                              used (see --drag). First goes the local source
                              file path, second - the file id. One pair per line.
  -m, --macro EXPRESSION      Locally evaluate the EXPRESSION. The _output_ of
                              the EXPRESSION will be remotely executed by the
                              current target (current target is stored in
                              the \$target variable).
                              Use this to dynamically produce target-specific
                              scripts.
                              Can be specified multiple times.
  -h, --help                  Display help text and exit
  --version                   Output version and exit
  -v, --verbose               Enable verbose output
  --functrace-depth LEVEL     Set function trace call stack depth displayed in
                              verbose output
                              Default: ${AUTOMATED_FUNCTRACE_DEPTH}
                              Env: AUTOMATED_FUNCTRACE_DEPTH
  --local                     Do the call locally. Any remote targets will
                              be ignored.
                              Default: ${AUTOMATED_EXECUTE_LOCALLY}
                              Env: AUTOMATED_EXECUTE_LOCALLY
  --dont-attach               Disable auto-attach to multiplexer.
                              When running a command in a terminal
                              multiplexer - proceed to the next host immediately
                              without attaching to the multiplexer.
                              Default (do attach): ${AUTOMATED_AUTO_ATTACH}
                              Env: AUTOMATED_AUTO_ATTACH
  --ignore-failed             If one of the targets has failed - proceed to the
                              next one. Exit codes will be lost.
                              Default: ${AUTOMATED_IGNORE_FAILED}
                              Env: AUTOMATED_IGNORE_FAILED
  --dump-script               Output compiled script to STDOUT. Do not run
                              anything. Implies local operation.
                              Default: ${AUTOMATED_DUMP_SCRIPT}
                              Env: AUTOMATED_DUMP_SCRIPT
  --tmux-sock-prefix PATH     Use custom PATH prefix for tmux socket on the
                              target.
                              Default: ${AUTOMATED_TMUX_SOCK_PREFIX}
                              Env: AUTOMATED_TMUX_SOCK_PREFIX
  --tmux-fifo-prefix PATH     Use custom PATH prefix for the FIFO object to use
                              for communicating with tmux.
                              Default: ${AUTOMATED_TMUX_FIFO_PREFIX}
                              Env: AUTOMATED_TMUX_FIFO_PREFIX
  --prefix-target-output      Prefix all output from every target with
                              "TARGET: "
                              Default ${AUTOMATED_PREFIX_TARGET_OUTPUT}
                              Env: AUTOMATED_PREFIX_TARGET_OUTPUT
  --ssh-command               Set the ssh client command. One of the use cases
                              is wrapping the ssh command in sshpass.
                              Will be eval'd.
                              Default: ${AUTOMATED_SSH_CMD}
                              Env: AUTOMATED_SSH_CMD
  --singleton                 Prevent multiple copies of the script from being
                              executed in parallel.
                              Default: ${AUTOMATED_SINGLETON_ENABLE}
                              Env: AUTOMATED_SINGLETON_ENABLE
  --singleton-lock-file       Remote lock file to use for --singleton.
                              Real filename will be suffixed with uid.
                              Default: ${AUTOMATED_SINGLETON_LOCK_FILE}
                              Env: AUTOMATED_SINGLETON_LOCK_FILE

EOF
}


automated_environment_script () {
    # shellcheck disable=SC2034
    declare AUTOMATED_CURRENT_TARGET="$1"

    declare var fn pair macro path file_path

    declare -a paths=()

    cat <<EOF
#!/usr/bin/env bash

set -euo pipefail

AUTOMATED_OWNER_UID="\${${SUDO_UID_VARIABLE}:-\$(id -u)}"
EOF
    file_as_function "${AUTOMATED_LIBDIR%/}/libautomated.sh" \
                     '__automated_libautomated'
    sourced_drop '__automated_libautomated'

    declared_var AUTOMATED_DEBUG
    declared_var AUTOMATED_CURRENT_TARGET
    declared_var AUTOMATED_TMUX_SOCK_PREFIX
    declared_var AUTOMATED_VERSION
    declared_var AUTOMATED_FUNCTRACE_DEPTH

    if [[ "${#EXPORT_VARS[@]}" -gt 0 ]]; then
        for var in "${EXPORT_VARS[@]}"; do
            (
                set -e

                if [[ "$var" == *=* ]]; then
                    declare key value

                    key="${var%%=*}"
                    value="${var#*=}"

                    declared_var "$key" "$value"
                else
                    declared_var "$var"
                fi
            )
        done
    fi

    if [[ "${#EXPORT_FUNCTIONS[@]}" -gt 0 ]]; then
        for fn in "${EXPORT_FUNCTIONS[@]}"; do
            declared_function "$fn"
        done
    fi

    if [[ "${#DRAG_PAIRS[@]}" -gt 0 ]]; then
        for pair in "${DRAG_PAIRS[@]}"; do
            # shellcheck disable=SC2086
            eval "file_as_function ${pair}"
        done
    fi

    if [[ "${#LOAD_PATHS[@]}" -gt 0 ]]; then
        for path in "${LOAD_PATHS[@]}"; do
            if [[ -d "$path" ]]; then
                for file_path in "${path%/}/"*.sh; do
                    paths+=("$file_path")
                done
            else
                paths+=("$path")
            fi
        done
    fi

    if [[ "${#paths[@]}" -gt 0 ]]; then
        for path in "${paths[@]}"; do
            file_as_function "$path"
            sourced_drop "$path"
        done
    fi

    if [[ "${#MACROS[@]}" -gt 0 ]]; then
        for macro in "${MACROS[@]}"; do
            eval "$macro"
        done
    fi
}


rendered_script () {
    declare target="$1"
    declare command="$2"

    declare pair

    # sudo password has to go first!
    if is_true "$AUTOMATED_SUDO_ENABLE"; then
        if is_true "$AUTOMATED_DUMP_SCRIPT"; then
            printf '%s\n' '*** SUDO PASSWORD IS HIDDEN IN SCRIPT DUMP MODE ***'
        else
            printf '%s\n' "$sudo_password"  # This one will be consumed by the PTY helper
        fi
    fi

    automated_bootstrap_environment "$target"

    if [[ "${#COPY_PAIRS[@]}" -gt 0 ]]; then
        for pair in "${COPY_PAIRS[@]}"; do
            # shellcheck disable=SC2086
            eval "file_as_code ${pair}"
        done
    fi

    cat <<"EOF"
if is_true "${AUTOMATED_DEBUG}"; then
  set -o functrace
  trap 'log_cmd_trap' DEBUG
fi

{

EOF
    if is_true "$AUTOMATED_SINGLETON_ENABLE"; then
        cat <<EOF
    (
        if ! flock -x -n "\$AUTOMATED_SINGLETON_LOCK_FD"; then
            throw "Another instance of automated script is already running"
        fi

        {

            ${command}

        # Close AUTOMATED_SINGLETON_LOCK_FD to prevent it from leaking into
        # sub-processes (conmon for example) which may stay resident
        # and retain the lock.
        } {AUTOMATED_SINGLETON_LOCK_FD}>&-

    ) {AUTOMATED_SINGLETON_LOCK_FD}>$(quoted "$AUTOMATED_SINGLETON_LOCK_FILE")-"\$(id -u)"
EOF
    else
        cat <<EOF
    ${command}
EOF
    fi

    cat <<"EOF"

    log_debug 'done'

    if is_true "${AUTOMATED_DEBUG}"; then
      trap - DEBUG
    fi

EOF

    # This block has to be the last block in the script as it
    # joins the STDIN of this script to the STDIN of the executed command
    if is_true "$AUTOMATED_PASS_STDIN"; then
        cat <<EOF
    # exit() is required so we don't try to execute the STDIN in case
    # no one has consumed it.
    # Exit code is always zero if we've got to this point (set -e in effect)
    exit 0

} < <(cat)
EOF
        cat
    else
        cat <<EOF
}
EOF
    fi
}


handler_command () {
    declare force_sudo_password="$1"
    declare -a handler=()

    declare -a command_environment=()

    declare packaged_pty_helper_script pty_helper_command

    if is_true "$AUTOMATED_DUMP_SCRIPT"; then
        handler=(cat)
    else
        if is_true "$AUTOMATED_EXECUTE_LOCALLY"; then
            handler=(eval)
        else
            mapfile -t ssh_args < <(target_as_ssh_arguments "$target")
            handler=('ssh_command' '-q' "${ssh_args[@]}" '--')
        fi

        if is_true "$AUTOMATED_SUDO_ENABLE"; then
            declare var var_value_quoted
            for var in SUDO_UID_VARIABLE EXIT_TIMEOUT EXIT_SUDO_PASSWORD_NOT_ACCEPTED EXIT_SUDO_PASSWORD_REQUIRED; do
                var_value_quoted=$(set -e; quoted "${!var}")
                command_environment+=("${var}=${var_value_quoted}")
            done

            packaged_pty_helper_script=$(gzip <"${AUTOMATED_LIBDIR%/}/pty_helper.py" | base64_encode)
            # shellcheck disable=SC2016
            pty_helper_command=('"$PYTHON_INTERPRETER"' "<(\"\$PYTHON_INTERPRETER\" -m base64 -d <<< ${packaged_pty_helper_script} | gunzip)")

            if ! is_true "$force_sudo_password" && is_true "$AUTOMATED_SUDO_PASSWORDLESS"; then
                pty_helper_command+=("--sudo-passwordless")
            fi

            pty_helper_command+=(bash)

            declare command_quoted
            command_quoted=$(set -e; quoted "PYTHON_INTERPRETER=\$(command -v python3 || command -v python2) && ${command_environment[*]} exec ${pty_helper_command[*]}")

            handler+=("bash --norc -euc ${command_quoted}")

        else
            handler+=(bash)
        fi
    fi

    declare handler_commandline_quoted
    handler_commandline_quoted=$(set -e; quoted "${handler[@]}")

    log_debug "Executing via ${handler_commandline_quoted}" BRIGHT_BLUE

    "${handler[@]}"
}


execute () {
    declare command="$1"
    declare target="${2:-LOCAL HOST}"

    declare sudo_password
    declare force_sudo_password=FALSE

    declare handler rc do_attach multiplexer

    # Loop until SUDO password is accepted
    while true; do

        sudo_password=''

        rc=0

        if is_true "$AUTOMATED_SUDO_ENABLE"; then
            if is_true "$force_sudo_password" || ! is_true "$AUTOMATED_SUDO_PASSWORDLESS"; then
                sudo_password=$(set -e; "$AUTOMATED_SUDO_ASK_PASSWORD_CMD" "$target")
            fi
        fi

        log_debug "Executing on ${target}"

        set +e
        (
            set -e

            # coproc is used to pass the exit code from the process substitution
            # to the main thread so we can catch both handler command and script
            # render errors.
            declare cpid
            coproc { read -r exit_code; exit "$exit_code"; }
            cpid="$COPROC_PID"

            # shellcheck disable=SC2064
            {
                if is_true "$AUTOMATED_PREFIX_TARGET_OUTPUT"; then
                    handler_command "$force_sudo_password" > >(prefixed_lines "${target}: ") 2> >(prefixed_lines "${target}: " >&2)
                else
                    handler_command "$force_sudo_password"
                fi
            } < <(trap "printf -- '%s\n' \"\$?\" >&\"${COPROC[1]}\"" EXIT; rendered_script "$target" "$command")

            # This wait will return the exit code of the coproc.
            wait "$cpid"
        )
        rc="$?"
        set -e

        case "$rc" in
            "$EXIT_SUDO_PASSWORD_NOT_ACCEPTED")
                if is_true "$AUTOMATED_SUDO_PASSWORD_ON_STDIN"; then
                    log_debug "SUDO password was provided on STDIN, but rejected by the target. Can't prompt, giving up"
                    break
                else
                    log_debug 'SUDO password was rejected. Looping over'
                fi
                ;;

            "$EXIT_SUDO_PASSWORD_REQUIRED")
                log_debug "${target} requested the password for SUDO, disabling passwordless SUDO mode for this target and looping over."
                force_sudo_password=TRUE
                ;;
            *)
                break
                ;;
        esac

    done

    case "$rc" in
        "$EXIT_TIMEOUT")
            throw "Timeout while connecting to ${target}"
            ;;

        "$AUTOMATED_EXIT_MULTIPLEXER_ALREADY_RUNNING_TMUX")
            log_info "Terminal multiplexer appears to be already running. Attaching ..."
            do_attach=TRUE
            multiplexer='tmux'
            ;;

        "$AUTOMATED_EXIT_RUNNING_IN_TMUX")
            do_attach="$AUTOMATED_AUTO_ATTACH"
            multiplexer='tmux'
            ;;

        *)
            return "$rc"
            ;;
    esac

    if is_true "$do_attach"; then
        log_debug "Attaching to multiplexer (${multiplexer}) ..."
        attach_to_multiplexer "$multiplexer" "$target"
    fi
}


parse_args () {
    declare list_file inventory_file path
    declare -a pair

    while [[ "$#" -gt 0 ]]; do

        case "$1" in

            -h|--help|help|'')
                exit_after 0 usage
                ;;

            -v|--verbose)
                AUTOMATED_DEBUG=TRUE
                ;;

            --functrace-depth)
                AUTOMATED_FUNCTRACE_DEPTH="$2"
                shift
                ;;

            --ssh-command)
                AUTOMATED_SSH_CMD="$2"
                shift
                ;;

            -s|--sudo)
                AUTOMATED_SUDO_ENABLE=TRUE
                ;;

            --sudo-password-on-stdin)
                AUTOMATED_SUDO_PASSWORD_ON_STDIN=TRUE
                ;;

            --sudo-passwordless)
                AUTOMATED_SUDO_PASSWORDLESS=TRUE
                ;;

            --sudo-ask-password-cmd)
                AUTOMATED_SUDO_ASK_PASSWORD_CMD="$2"
                shift
                ;;

            --dont-attach)
                AUTOMATED_AUTO_ATTACH=FALSE
                ;;

            --ignore-failed)
                AUTOMATED_IGNORE_FAILED=TRUE
                ;;

            --prefix-target-output)
                AUTOMATED_PREFIX_TARGET_OUTPUT=TRUE
                ;;

            --dump-script)
                AUTOMATED_DUMP_SCRIPT=TRUE
                AUTOMATED_EXECUTE_LOCALLY=TRUE
                ;;

            --tmux-sock-prefix)
                AUTOMATED_TMUX_SOCK_PREFIX="$2"
                shift
                ;;

            --tmux-fifo-prefix)
                AUTOMATED_TMUX_FIFO_PREFIX="$2"
                shift
                ;;

            --stdin)
                AUTOMATED_PASS_STDIN=TRUE
                ;;

            --cp)
                COPY_PAIRS+=("$(printf '%q %q' "$2" "$3")")
                shift 2
                ;;

            --cp-list)
                list_file="$2"
                shift

                mapfile -t -O "${#COPY_PAIRS[@]}" COPY_PAIRS < "$list_file"
                ;;

            --drag)
                DRAG_PAIRS+=("$(printf '%q %q' "$2" "$3")")
                shift 2
                ;;

            --drag-list)
                list_file="$2"
                shift

                mapfile -t -O "${#DRAG_PAIRS[@]}" DRAG_PAIRS < "$list_file"
                ;;

            -m|--macro)
                MACROS+=("$2")
                shift
                ;;

            -l|--load)
                LOAD_PATHS+=("$2")
                shift
                ;;

            -c|--call)
                AUTOMATED_CALL_CMD="$2"
                shift
                ;;

            -e|--export)
                EXPORT_VARS+=("$2")
                shift
                ;;

            --export-fn)
                if [[ "$(type -t "$2")" = 'function' ]]; then
                    EXPORT_FUNCTIONS+=("$2")
                fi
                shift
                ;;

            -i|--inventory)
                inventory_file="$2"
                shift
                if [[ -r "$inventory_file" ]]; then
                    mapfile -t -O "${#TARGETS[@]}" TARGETS < "$inventory_file"
                else
                    throw "Could not read inventory file"
                fi
                ;;

            --singleton)
                AUTOMATED_SINGLETON_ENABLE=TRUE
                ;;

            --singleton-lock-file)
                AUTOMATED_SINGLETON_LOCK_FILE="$2"
                shift
                ;;

            --local)
                AUTOMATED_EXECUTE_LOCALLY=TRUE
                ;;

            --version)
                exit_after 0 printf '%s\n' "$AUTOMATED_VERSION"
                ;;

            --)
                shift
                TARGETS+=("$@")
                break
                ;;
            *)
                TARGETS+=("$1")
                ;;
        esac

        shift

    done
}


main () {
    declare rc target

    [[ "$#" -gt 0 ]] || exit_after 1 usage >&2

    parse_args "$@"

    if is_true "$AUTOMATED_EXECUTE_LOCALLY"; then
        execute "$AUTOMATED_CALL_CMD"
    elif [[ "${#TARGETS[@]}" -gt 0 ]]; then
        for target in "${TARGETS[@]}"; do

            set +e
            (
                set -e
                execute "$AUTOMATED_CALL_CMD" "$target"
            )
            rc="$?"
            set -e

            if [[ "$rc" -ne 0 ]]; then
                is_true "$AUTOMATED_IGNORE_FAILED" || exit "$rc"
            fi
        done
    else
        throw 'No targets specified'
    fi
}


if ! (return 2> /dev/null); then

    AUTOMATED_PROG=$(basename "${BASH_SOURCE[0]:-}")
    AUTOMATED_PROG_DIR=$(dirname "${BASH_SOURCE[0]:-}")

    # shellcheck source=automated-config.sh
    source "${AUTOMATED_PROG_DIR%/}/automated-config.sh"
    # shellcheck source=libautomated.sh
    source "${AUTOMATED_LIBDIR%/}/libautomated.sh"

    if ! bash_minor_version_is_higher_than 4 1; then
        throw "Minimum supported Bash version is 4.1 (present version is ${BASH_VERSION})"
    fi

    main "$@"
fi
