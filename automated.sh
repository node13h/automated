#!/usr/bin/env bash

# An automation tool
# Copyright (C) 2016 Sergej Alikov <sergej.alikov@gmail.com>

# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.

# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

set -eu
set -o pipefail

# TODO Throw error on unsupported systems (CentOS5, perhaps Ubuntu 10.04)

PROG=$(basename "${BASH_SOURCE:-}")

DEBUG=FALSE
DISABLE_COLOUR=FALSE
SUDO=FALSE
SUDO_PASSWORDLESS=FALSE
SUDO_PASSWORD_ON_STDIN=FALSE
LOCAL=FALSE
AUTO_ATTACH=TRUE
IGNORE_FAILED=FALSE
DUMP_SCRIPT=FALSE
CMD='all'

EXIT_TIMEOUT=65
EXIT_SUDO_PASSWORD_NOT_ACCEPTED=66
EXIT_SUDO_PASSWORD_REQUIRED=67
EXIT_RUNNING_IN_TMUX=68
# TODO EXIT_RUNNING_IN_SCREEN=69
EXIT_MULTIPLEXER_ALREADY_RUNNING=70

SUPPORTED_MULTIPLEXERS=(tmux)

TMUX_SOCK_PREFIX="/tmp/tmux-automated"
EXPORT_VARS=()
EXPORT_FUNCTIONS=()
LOAD_PATHS=()
COPY_PAIRS=()
COPY_PAIR_LIST_PROVIDERS=()
DRAG_PAIRS=()
DRAG_PAIR_LIST_PROVIDERS=()
MACROS=()

SUDO_UID_VARIABLE='AUTOMATED_SUDO_UID'
OWNER_UID_SOURCE="\${${SUDO_UID_VARIABLE}:-\$(id -u)}"


pty_helper_script () {
    cat <<"EOF"
import os
import sys
import pty
import select
import termios
import time
import argparse

parser = argparse.ArgumentParser(description='SUDO PTY helper')
parser.add_argument('--sudo-passwordless', action='store_true', default=False)
parser.add_argument('command')

args = parser.parse_args()

DEFAULT_TIMEOUT = 60
DEFAULT_READ_BUFFER_SIZE = 1024

STDIN = sys.stdin.fileno()
STDOUT = sys.stdout.fileno()
STDERR = sys.stderr.fileno()

EXIT_TIMEOUT = int(os.environ['EXIT_TIMEOUT'])
EXIT_SUDO_PASSWORD_NOT_ACCEPTED = int(os.environ['EXIT_SUDO_PASSWORD_NOT_ACCEPTED'])
EXIT_SUDO_PASSWORD_REQUIRED = int(os.environ['EXIT_SUDO_PASSWORD_REQUIRED'])

class Timeout(Exception):
    pass


def one_of(
        fd, string_list, timeout=DEFAULT_TIMEOUT,
        read_buffer_size=DEFAULT_READ_BUFFER_SIZE):

    buffer = ''
    longest_string_len = max([len(s) for s in string_list])

    start = time.time()

    while True:

        # We might hit the EOF multiple times

        try:
            chunk = os.read(fd, read_buffer_size)
        except OSError:
            continue

        if not chunk:
            continue

        buffer = ''.join([buffer, chunk])

        for s in string_list:
            if s in buffer:
                return s

        buffer = buffer[-longest_string_len:]

        if timeout is not None:
            if time.time() - start >= timeout:
                raise Timeout()


# Save standard file descriptors for later
fd0 = os.dup(STDIN)
fd1 = os.dup(STDOUT)
fd2 = os.dup(STDERR)

# Closing these will prevent Python script itself
# from being able to output stuff onto STDOUT/STDERR
os.close(STDIN)
os.close(STDOUT)
os.close(STDERR)

sudo_pass_buffer = []

while True:
    c = os.read(fd0, 1)

    sudo_pass_buffer.append(c)

    if c == '\n':
        break

sudo_pass = ''.join(sudo_pass_buffer)

pid, child_pty = pty.fork()

if pid is 0:
    # Attach child to saved standard descriptors
    os.dup2(fd0, STDIN)
    os.dup2(fd1, STDOUT)
    os.dup2(fd2, STDERR)
    os.close(fd0)
    os.close(fd1)
    os.close(fd2)

    os.execv('/usr/bin/sudo', [
        'sudo', '-p', 'SUDO_PASSWORD_PROMPT:',
        'bash', '-c', (
            'echo "SUDO_SUCCESS" >/dev/tty; '
            'export PTY_HELPER_SCRIPT={}; '
            'export {}={}; '
            'exec {}').format(__file__,
                              os.environ['SUDO_UID_VARIABLE'], os.getuid(),
                              args.command)])

# Disable echo
attr = termios.tcgetattr(child_pty)
attr[3] = attr[3] & ~termios.ECHO
termios.tcsetattr(child_pty, termios.TCSANOW, attr)

try:
    s = one_of(child_pty, ['SUDO_PASSWORD_PROMPT:', 'SUDO_SUCCESS'])
    if s == 'SUDO_PASSWORD_PROMPT:':

        if args.sudo_passwordless:
            sys.exit(EXIT_SUDO_PASSWORD_REQUIRED)

        os.write(child_pty, sudo_pass)

        s = one_of(child_pty, ['SUDO_PASSWORD_PROMPT:', 'SUDO_SUCCESS'])
        if s == 'SUDO_PASSWORD_PROMPT:':
            sys.exit(EXIT_SUDO_PASSWORD_NOT_ACCEPTED)
except Timeout:
    sys.exit(EXIT_TIMEOUT)

pid, exitstatus = os.waitpid(pid, 0)

sys.exit(exitstatus >> 8)
EOF
}

newline () { echo; }

is_true () {
    [[ "${1,,}" =~ yes|true|on|1 ]]
}

to_stderr () {
    >&2 cat
}

msg () {
    echo "${*}" | to_stderr
}

colorize () {
    local colour="${1}"
    shift

    is_true "${DISABLE_COLOUR}" || echo -ne "\\e[${colour}m"
    "${@}"
    is_true "${DISABLE_COLOUR}" || echo -ne '\e[39m'
}

to_debug () {
    if is_true "${DEBUG}"; then

        {
            [[ -z "${1:-}" ]] || echo "BEGIN ${1}"
            colorize 33 tr -cd '\11\12\15\40-\176'
            [[ -z "${1:-}" ]] || echo "END ${1}"

        } | to_stderr

    else
        # Consume, to keep file descriptor open
        cat >/dev/null
    fi
}

msg_debug () {
    echo "DEBUG ${*}" | to_debug
}

abort () {
    echo "${*}" | to_stderr
    exit 1
}

to_file () {
    tee "${1}" | to_debug "${1}"
}

quote () {
    local result=""

    for token in "${@}"; do
        result="${result:+${result} }$(printf "%q" "${token}")"
    done

    echo "${result}"
}

md5 () {
    md5sum -b | cut -f 1 -d ' '
}

cmd () {
    # to_stderr or to_debug may swallow STDIN intended for the command - hence the simple printf
    if is_true "${DEBUG}"; then
        colorize 32 printf 'CMD %s\n' "$(quote "${@}")" >&2
    fi
    "${@}"
}

cmd_is_available () {
    which "${1}" >/dev/null 2>&1
}

readable_file () {
    [[ -f "${1}" && -r "${1}" ]]
}

readable_directory () {
    [[ -d "${1}" && -r "${1}" ]]
}

get_the_facts () {
    local pkg ver

    FACT_SYSTEMD=FALSE

    if cmd_is_available systemctl; then
        if systemctl --quiet is-active -- '-.mount'; then
            FACT_SYSTEMD=TRUE
        fi
    fi

    # shellcheck disable=SC1091,SC2034
    if [[ -f /etc/redhat-release ]]; then
        FACT_OS_FAMILY='RedHat'
        for pkg in 'centos-release' 'redhat-release' 'fedora-release'; do
            if ver=$(rpm -q --queryformat '%{VERSION} %{RELEASE}' "${pkg}"); then
                read -r FACT_OS_VERSION FACT_OS_RELEASE <<< "${ver}"
                case "${pkg}" in
                    'centos-release')
                        FACT_OS_NAME='CentOS'
                        ;;
                    'redhat-release')
                        FACT_OS_NAME='RHEL'
                        ;;
                    'fedora-release')
                        FACT_OS_NAME='Fedora'
                        ;;
                esac
            fi
        done
    elif [[ -f /etc/debian_version ]]; then
        FACT_OS_FAMILY='Debian'
        while read -r var_definition; do
            declare -g "${var_definition}"
        done < <(source /etc/os-release
                 echo "FACT_OS_NAME=${NAME}"
                 echo "FACT_OS_VERSION=${VERSION_ID}"
                 echo "FACT_OS_RELEASE=${VERSION}")

    else
        abort "Unsupported operating system"
    fi
}

packages_ensure () {
    local command="${1}"
    shift

    case "${FACT_OS_FAMILY}-${command}" in
        'RedHat-present')
            yum -y -q install "${@}"
            ;;
        'RedHat-absent')
            yum -y -q remove "${@}"
            ;;
        'Debian-present')
            apt-get -yqq install "${@}"
            ;;
        'Debian-absent')
            apt-get -yqq remove "${@}"
            ;;
        *)
            abort "Command ${command} is unsupported on ${FACT_OS_FAMILY}"
            ;;
    esac
}


service_ensure () {
    local service="${1}"
    local command="${2}"

    if is_true "${FACT_SYSTEMD}"; then
        case "${command}" in
            enabled)
                systemctl enable "${service}"
                ;;
            disabled)
                systemctl disable "${service}"
                ;;
        esac
    else
        case "${FACT_OS_FAMILY}-${command}" in
            'RedHat-enabled')
                chkconfig "${service}" on
                ;;
            'RedHat-disabled')
                chkconfig "${service}" off
                ;;
            'Debian-enabled')
                update-rc.d "${service}" enable
                ;;
            'Debian-disabled')
                update-rc.d "${service}" disable
                ;;
            *)
                abort "Command ${command} is unsupported on ${FACT_OS_FAMILY}"
                ;;
        esac
    fi
}

tmux_command () {
    tmux -S "${TMUX_SOCK_PREFIX}-${AUTOMATED_OWNER_UID}" "${@}"
}

multiplexer_present () {
    local multiplexer

    for multiplexer in "${SUPPORTED_MULTIPLEXERS[@]}"; do
        if cmd_is_available "${multiplexer}"; then
            echo "${multiplexer}"
            return 0
        fi
    done

    return 1
}

multiplexer_ensure_installed () {
    if ! multiplexer_present >/dev/null; then
        packages_ensure installed "${SUPPORTED_MULTIPLEXERS[0]}"  # Install first one
    fi
}

run_in_multiplexer () {

    local multiplexer

    if ! multiplexer=$(multiplexer_present); then
        abort "Multiplexer is not available. Please install one of the following: ${SUPPORTED_MULTIPLEXERS[*]}"
    fi

    case "${multiplexer}" in
        tmux)
            if tmux_command ls 2>/dev/null | to_debug; then
                msg_debug "Multiplexer is already running"
                exit "${EXIT_MULTIPLEXER_ALREADY_RUNNING}"
            else
                msg_debug "Starting multiplexer and sending commands"
                cmd tmux_command new-session -d
                cmd tmux_command -l send "${@}"
                cmd tmux_command send ENTER
            fi

            chown "${AUTOMATED_OWNER_UID}" "${TMUX_SOCK_PREFIX}-${AUTOMATED_OWNER_UID}"

            exit "${EXIT_RUNNING_IN_TMUX}"
            ;;

        # TODO screen
    esac
}


# This command is usually run on the controlling workstation, not remote
attach_to_multiplexer () {
    local multiplexer="${1}"
    local target="${2:-LOCAL HOST}"

    local handler

    if is_true "${LOCAL}"; then
        handler=(eval)
    else
        handler=(ssh -t -q $(target_as_ssh_arguments "${target}") --)
    fi

    case "${multiplexer}" in
        tmux)
            cmd "${handler[@]}" "tmux -S \"${TMUX_SOCK_PREFIX}-${OWNER_UID_SOURCE}\" attach"
            ;;

        # TODO screen
    esac
}

ask_sudo_password () {
    local sudo_password

    if is_true "${SUDO_PASSWORD_ON_STDIN}"; then
        read -r sudo_password
    else
        {

            echo -n "SUDO password (${1:-localhost}): "
            read -r -s sudo_password
            newline

        } </dev/tty >/dev/tty
    fi

    echo "${sudo_password}"
}

display_automated_usage_and_exit () {
    cat <<EOF
Usage: ${PROG} [OPTIONS] [[<[USER@]ADDRESS[:PORT]>] ...]

Runs commands on local host or one or more remote targets.

OPTIONS:

  -s, --sudo                  Use SUDO to do the calls
  --sudo-passwordless         Don't ask for SUDO password. Will ask anyway if target insists.
  --sudo-password-on-stdin    Read SUDO password from STDIN
  -c, --call <COMMAND>        Command to call. Default is "${CMD}"
  -i, --inventory <FILE>      Load list of targets from the FILE
  -e, --export <NAME>         Make NAME from local environment available on the remote
                              side. NAME can be either variable or function name.
                              Functions have to be exported with the 'export -f NAME'
                              first (bash-specific). May be specified multiple times
  -l, --load <PATH>           Load file at specified PATH before calling
                              the command; in case PATH is a directory -
                              load *.sh from it. Can be specified multiple times.
  --cp LOCAL-SRC-FILE REMOTE-DST-FILE
                              Copy local file to the target(s). Can be specified multiple
                              times.
  --cp-list FILE              The FILE should be either a text file containing a
                              list of the source/destination file path pairs or
                              a executable bash script which will write the mentioned list
                              to the STDOUT. Script will be executed once for each target
                              (the target will be passed to the script as a first argument)
                              thus allowing you to different sets of files to the
                              different targets in a single run.
                              Pairs should be separated by spaces, one pair per line.
                              First goes the local source file path, second -
                              the remote destination file path.
                              Use the backslashes to escape the spaces and/or special
                              characters.
                              Can be specified multiple times.
  --drag LOCAL-SRC-FILE FILE-ID
                              Transport the local file to the target(s).
                              FILE-ID is a text identifier for referencing this file
                              in the drop function, must be unique for every file.
                              To actually write file on the remote system use
                              the drop FILE-ID, REMOTE-DST-FILE function in the script.
                              Allows for the destination path calculation at runtime on the
                              remote side.
                              WARNING: This method is not suitable for the large files
                              as the contents will be kept in memory during the execution
                              of the script.
                              Can be specified multiple times.
  --drag-list FILE            Similar to the --cp-list, but will not write files to the
                              remote system until the drop function is used (see --drag).
                              First goes the local source file path, second -
                              the file id. One pair per line.
  -m, --macro FILE            FILE is an executable file. It will be run locally with
                              a target as an argument. The output will be sent to the
                              target and executed in the remote bash before the COMMAND.
                              Use this to dynamically produce the target-specific scripts.
                              Can be specified multiple times.
  -h, --help                  Display help text and exit
  -v, --verbose               Enable verbose output
  --local                     Do the local call only. Any remote targets will
                              be ignored.
  --dont-attach               When running a command in the terminal multiplexer - proceed to the
                              next host immediately without attaching to the multiplexer.
  --ignore-failed             If one of the targets has failed - proceed to the next one. Exit
                              codes will be lost.
  --dump-script               Output compiled script to STDOUT. Do not run anything. Implies
                              the local operation.
  --tmux-sock-prefix <PATH>   Use custom PATH prefix for tmux socket on the target.
                              Default: ${TMUX_SOCK_PREFIX}

EOF
    exit "${1:-0}"
}

loadable_files () {
    local file_path load_path

    [[ "${#}" -gt 0 ]] || return 0

    for load_path in "${@}"; do
        if readable_file "${load_path}"; then
            echo "${load_path}"
        elif readable_directory "${load_path}"; then
            for file_path in "${load_path%/}/"*.sh; do
                if readable_file "${file_path}"; then
                    echo "${file_path}"
                fi
            done
        fi
    done
}

env_var_definitions () {
    local var

    [[ "${#}" -gt 0 ]] || return 0

    for var in "${@}"; do
        if [[ -n ${!var+set} ]]; then
            echo "${var}=$(quote "${!var}")"
        fi
    done
}

target_as_ssh_arguments () {
    local target="${1}"
    local username address port

    if [[ "${target}" =~ ^((.+)@)?(\[([:0-9A-Fa-f]+)\])(:([0-9]+))?$ ]] ||
       [[ "${target}" =~ ^((.+)@)?(([-.0-9A-Za-z]+))(:([0-9]+))?$ ]]; then
        username="${BASH_REMATCH[2]}"
        address="${BASH_REMATCH[4]}"
        port="${BASH_REMATCH[6]}"
    else
        return 1
    fi
    echo "${port:+-p ${port} }${username:+-l ${username} }${address}"
}

in_proper_context () {
    local command="${1}"
    local force_sudo_password="${2:-FALSE}"
    local cmdline=()

    if is_true "${SUDO}"; then
        cmdline+=("$(pty_helper_settings) python <(base64 -d <<< $(pty_helper_script | gzip | base64 -w 0) | gunzip)")

        if ! is_true "${force_sudo_password}" && is_true "${SUDO_PASSWORDLESS}"; then
            cmdline+=("--sudo-passwordless")
        fi
    fi

    cmdline+=("${command}")

    echo "${cmdline[@]}"
}

pty_helper_settings () {
    echo "SUDO_UID_VARIABLE=\"${SUDO_UID_VARIABLE}\" EXIT_TIMEOUT=\"${EXIT_TIMEOUT}\" EXIT_SUDO_PASSWORD_NOT_ACCEPTED=\"${EXIT_SUDO_PASSWORD_NOT_ACCEPTED}\" EXIT_SUDO_PASSWORD_REQUIRED=\"${EXIT_SUDO_PASSWORD_REQUIRED}\""
}

files_as_code() {
    local src dst mode boundary
    local eof=false

    until ${eof}; do

        # shellcheck disable=SC2162
        read src dst || eof=true

        [[ -n "${src}" && -n "${dst}" ]] || continue

        [[ -f "${src}" ]] || abort "${src} is not a file. Only files are supported"

        mode=$(stat -c "%#03a" "${src}")
        # Not copying owner information intentionally

        boundary="EOF-$(md5 <<< "${dst}")"

        cat <<EOF
touch $(quote "${dst}")
chmod ${mode} $(quote "${dst}")
base64 -d <<"${boundary}" | gzip -d >$(quote "${dst}")
$(gzip -c "${src}" | base64)
${boundary}
EOF
    done
}

drop_fn_name () {
    local file_id="${1}"

    printf '%s\n' "drop_$(md5 <<< "${file_id}")"
}


drop () {
    local file_id="${1}"
    local dst="${2}"

    # shellcheck disable=SC2091
    "$(drop_fn_name "${file_id}")" "${dst}"
}

files_as_functions() {
    local src file_id mode boundary fn_name
    local eof=false

    until ${eof}; do
        # shellcheck disable=SC2162
        read src file_id || eof=true

        [[ -n "${src}" && -n "${file_id}" ]] || continue

        [[ -f "${src}" ]] || abort "${src} is not a file. Only files are supported"

        mode=$(stat -c "%#03a" "${src}")
        # Not copying owner information intentionally

        boundary="EOF-$(md5 <<< "${file_id}")"
        fn_name=$(drop_fn_name "${file_id}")

        cat <<EOF
${fn_name} () {
  local dst="\${1}"

  touch "\${dst}"
  chmod ${mode} "\${dst}"
  base64 -d <<"${boundary}" | gzip -d >"\${dst}"
$(gzip -c "${src}" | base64)
${boundary}
}
EOF
    done
}

execute () {
    local command="${1}"
    local target="${2:-LOCAL HOST}"

    local sudo_password
    local force_sudo_password=FALSE

    local handler var_definition file_path rc do_attach multiplexer fn

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
        {
            # sudo password has to go first!
            if is_true "${SUDO}"; then
                if is_true "${DUMP_SCRIPT}"; then
                    echo '*** SUDO PASSWORD IS HIDDEN IN SCRIPT DUMP MODE ***'
                else
                    echo "${sudo_password}"  # This one will be consumed by the PTY helper
                fi
            fi

            if [[ "${#EXPORT_VARS[@]}" -gt 0 ]]; then
                echo "# Vars"
                msg_debug "Exporting variables"
                while read -r var_definition; do
                    msg_debug "${var_definition}"
                    echo "${var_definition}"
                done < <(env_var_definitions "${EXPORT_VARS[@]}")
            fi

            if [[ "${#EXPORT_FUNCTIONS[@]}" -gt 0 ]]; then
                echo "# Functions"
                msg_debug "Exporting functions"

                for fn in "${EXPORT_FUNCTIONS[@]}"; do
                    declare -f "${fn}"
                done
            fi

            echo "# ${PROG}"
            msg_debug "Concatenating ${BASH_SOURCE[0]}"
            cat "${BASH_SOURCE[0]}"

            if [[ "${#LOAD_PATHS[@]}" -gt 0 ]]; then
                while read -r file_path; do
                    msg_debug "Concatenating ${file_path}"
                    echo "# $(basename "${file_path}")"
                    cat "${file_path}"
                    newline
                done < <(loadable_files "${LOAD_PATHS[@]}")
            fi

            if [[ "${#COPY_PAIRS[@]}" -gt 0 ]]; then
                files_as_code < <(printf '%s\n' "${COPY_PAIRS[@]}")
            fi

            if [[ "${#COPY_PAIR_LIST_PROVIDERS[@]}" -gt 0 ]]; then
                for file_path in "${COPY_PAIR_LIST_PROVIDERS[@]}"; do
                    files_as_code < <($(readlink -f "${file_path}") "${target}")
                done
            fi

            if [[ "${#DRAG_PAIRS[@]}" -gt 0 ]]; then
                files_as_functions < <(printf '%s\n' "${DRAG_PAIRS[@]}")
            fi

            if [[ "${#DRAG_PAIR_LIST_PROVIDERS[@]}" -gt 0 ]]; then
                for file_path in "${DRAG_PAIR_LIST_PROVIDERS[@]}"; do
                    files_as_functions < <($(readlink -f "${file_path}") "${target}")
                done
            fi

            if is_true "${DEBUG}"; then
                echo "DEBUG=TRUE"
            fi
            echo "AUTOMATED_OWNER_UID=${OWNER_UID_SOURCE}"
            echo "TMUX_SOCK_PREFIX=${TMUX_SOCK_PREFIX}"

            echo "# Facts"
            echo "get_the_facts"

            if [[ "${#MACROS[@]}" -gt 0 ]]; then
                for file_path in "${MACROS[@]}"; do
                    $(readlink -f "${file_path}") "${target}"
                done
            fi

            echo "# Entry point"
            echo "${command}"

        } | cmd "${handler[@]}" || rc=$?

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

        "${EXIT_MULTIPLEXER_ALREADY_RUNNING}")
            msg "Terminal multiplexer appears to be already running. Attaching ..."
            do_attach=TRUE
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
    local inventory_file rc list_file
    local -a targets=()

    [[ "${#}" -gt 0 ]] || display_automated_usage_and_exit 1

    while [[ "${#}" -gt 0 ]]; do

        case "${1}" in

            -h|--help|help|'')
                display_automated_usage_and_exit
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

            --dump-script)
                DUMP_SCRIPT=TRUE
                LOCAL=TRUE
                ;;

            --tmux-sock-prefix)
                TMUX_SOCK_PREFIX="${2}"
                shift
                ;;

            --cp)
                COPY_PAIRS+=("$(printf '%q %q' "${2}" "${3}")")
                shift 2
                ;;

            --cp-list)
                list_file="${2}"
                shift

                if [[ -x "${list_file}" ]]; then
                    COPY_PAIR_LIST_PROVIDERS+=("${list_file}")
                else
                    mapfile -t -O "${#COPY_PAIRS[@]}" COPY_PAIRS < "${list_file}"
                fi
                ;;

            --drag)
                DRAG_PAIRS+=("$(printf '%q %q' "${2}" "${3}")")
                shift 2
                ;;

            --drag-list)
                list_file="${2}"
                shift

                if [[ -x "${list_file}" ]]; then
                    DRAG_PAIR_LIST_PROVIDERS+=("${list_file}")
                else
                    mapfile -t -O "${#DRAG_PAIRS[@]}" DRAG_PAIRS < "${list_file}"
                fi
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
                    abort "Could not read inventory file"
                fi
                ;;

            --local)
                LOCAL=TRUE
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
        abort "No targets specified"
    fi
}


if [[ -n "${BASH_SOURCE[0]:-}" && "${0}" = "${BASH_SOURCE[0]}" ]]; then
    main "${@}"
fi
