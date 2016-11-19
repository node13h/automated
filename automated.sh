#!/bin/bash

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

PROG=$(basename "${BASH_SOURCE:-}")

DEBUG=FALSE
DISABLE_COLOUR=FALSE
SUDO=FALSE
PASSWORDLESS_SUDO=FALSE
LOCAL=FALSE
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
parser.add_argument('--passwordless-sudo', action='store_true', default=False)
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

        if args.passwordless_sudo:
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

to_debug () {
    if is_true "${DEBUG}"; then

        {
            [[ -z "${1:-}" ]] || echo "BEGIN ${1}"
            is_true "${DISABLE_COLOUR}" || echo -ne '\e[33m'
            cat | tr -cd '\11\12\15\40-\176'
            is_true "${DISABLE_COLOUR}" || echo -ne '\e[39m'
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

cmd () {
    msg_debug $(quote "${@}")
    "${@}"
}

readable_file () {
    [[ -f "${1}" && -r "${1}" ]]
}

readable_directory () {
    [[ -d "${1}" && -r "${1}" ]]
}

get_the_facts () {
    local pkg ver

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
        while read var_definition; do
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

# TODO services_ensure enabled|disabled


tmux_command () {
    tmux -S "${TMUX_SOCK_PREFIX}-${AUTOMATED_OWNER_UID}" "${@}"
}

multiplexer_present () {
    local multiplexer

    for multiplexer in "${SUPPORTED_MULTIPLEXERS[@]}"; do
        if which "${multiplexer}" 1>/dev/null 2>&1; then
            echo "${multiplexer}"
            return 0
        fi
    done

    return 1
}

multiplexer_ensure_installed () {
    if ! multiplexer_present >/dev/null; then
        packages_ensure installed "${SUPPORTED_MULTIPLEXERS}"  # Install first one
    fi
}

run_in_multiplexer () {

    local multiplexer

    if ! multiplexer=$(multiplexer_present); then
        abort "Multiplexer is not available. Please install one of the following: ${SUPPORTED_MULTIPLEXERS[@]}"
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
    {

        echo -n "SUDO password (${1:-localhost}): "
        read -s sudo_password
        newline

    } </dev/tty >/dev/tty

    echo "${sudo_password}"
}

display_automated_usage_and_exit () {
    cat <<EOF
Usage: ${PROG} [OPTIONS] [[<[USER@]ADDRESS[:PORT]>] ...]

Runs commands on local host or one or more remote targets.

OPTIONS:

  -s, --sudo                  Use SUDO to do the calls
  --passwordless-sudo         Don't ask for SUDO password. Will ask anyway if target insists.
  -c, --call <COMMAND>        Command to call. Default is "${CMD}"
  -i, --inventory <FILE>      Load list of targets from the FILE
  -e, --export <VAR>          Make VAR from local environment available on the remote
                              side. May be specified multiple times
  -l, --load <PATH>           Load file at specified PATH before calling
                              the command; in case PATH is a directory -
                              load *.sh from it
  -h, --help                  Display help text and exit
  -v, --verbose               Enable verbose output
  --local                     Do the local call only. Any remote targets will
                              be ignored.

EOF
    exit "${1:-0}"
}

loadable_files () {
    local file_path

    [[ -n "${1:-}" ]] || return 0

    if readable_file "${1}"; then
        echo "${1}"
    elif readable_directory "${1}"; then
        for file_path in "${1%/}/"*.sh; do
            if readable_file "${file_path}"; then
                echo "${file_path}"
            fi
        done
    fi
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
    local cmdline=()

    if is_true "${SUDO}"; then
        cmdline+=("$(pty_helper_settings) python <(base64 -d <<< $(pty_helper_script | gzip | base64 -w 0) | gunzip)")

        if is_true "${PASSWORDLESS_SUDO}"; then
            cmdline+=("--passwordless-sudo")
        fi
    fi

    cmdline+=("${command}")

    echo "${cmdline[@]}"
}

pty_helper_settings () {
    echo "SUDO_UID_VARIABLE=\"${SUDO_UID_VARIABLE}\" EXIT_TIMEOUT=\"${EXIT_TIMEOUT}\" EXIT_SUDO_PASSWORD_NOT_ACCEPTED=\"${EXIT_SUDO_PASSWORD_NOT_ACCEPTED}\" EXIT_SUDO_PASSWORD_REQUIRED=\"${EXIT_SUDO_PASSWORD_REQUIRED}\""
}

execute () {
    local command="${1}"
    local target="${2:-LOCAL HOST}"

    local sudo_password=''

    local handler args var_definition file_path rc do_attach multiplexer

    if is_true "${LOCAL}"; then
        handler=(eval)
    else
        handler=(ssh -q $(target_as_ssh_arguments "${target}") --)
    fi

    # Loop until SUDO password is accepted
    while true; do

        rc=0

        if ! is_true "${PASSWORDLESS_SUDO}" && is_true "${SUDO}"; then
            sudo_password=$(ask_sudo_password "${target}")
        fi

        msg_debug "Executing on ${target}"
        {
            # sudo password has to go first!
            if is_true "${SUDO}"; then
                echo "${sudo_password}"  # This one will be consumed by the PTY helper
            fi

            if [[ "${#EXPORT_VARS[@]}" -gt 0 ]]; then
                echo "# Vars"
                msg_debug "Exporting variables"
                while read -r var_definition; do
                    msg_debug "${var_definition}"
                    echo "${var_definition}"
                done < <(env_var_definitions "${EXPORT_VARS[@]}")
            fi

            if is_true "${DEBUG}"; then
                echo "DEBUG=TRUE"
            fi

            echo "AUTOMATED_OWNER_UID=${OWNER_UID_SOURCE}"

            echo "# ${PROG}"
            msg_debug "Concatenating ${0}"
            cat "${0}"

            while read -r file_path; do
                msg_debug "Concatenating ${file_path}"
                echo "# $(basename ${file_path})"
                cat "${file_path}"
                newline
            done < <(loadable_files "${LOAD_PATH:-}")

            echo "# Facts"
            echo "get_the_facts"

            echo "# Entry point"
            echo "${command}"

        } | cmd "${handler[@]}" "$(in_proper_context bash)" || rc=$?

        case "${rc}" in
            "${EXIT_SUDO_PASSWORD_NOT_ACCEPTED}")
                msg_debug 'SUDO password was rejected. Looping over'
                ;;

            "${EXIT_SUDO_PASSWORD_REQUIRED}")
                msg_debug "${target} requested the password for SUDO, disabling passwordless SUDO mode and looping over."
                PASSWORDLESS_SUDO=FALSE
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
            # TODO Support disabling auto attach via commandline args
            do_attach=TRUE
            multiplexer='tmux'
            ;;

        # TODO screen
        *)
            # TODO Make exit on fist error optional (will lose exit codes)
            exit "${rc}"
            ;;
    esac

    if is_true "${do_attach}"; then
        msg_debug "Attaching to multiplexer (${multiplexer}) ..."
        attach_to_multiplexer "${multiplexer}" "${target}" || msg "Unable to attach to multiplexer on ${target}. Perhaps it completed it's job and exited already?"
    fi
}

main () {
    local inventory_file
    local -a targets=()

    [[ "${#}" -gt 0 ]] || display_automated_usage_and_exit 1

    while [[ "${#}" -gt 0 ]]; do

        case "${1}" in

            # TODO Argument to show compiled script
            # TODO --sudo-password-on-stdin
            # TODO Argument to set custom tmux socket path

            -h|--help|help|'')
                display_automated_usage_and_exit
                ;;

            -v|--verbose)
                DEBUG=TRUE
                ;;

            -s|--sudo)
                SUDO=TRUE
                ;;

            --passwordless-sudo)
                PASSWORDLESS_SUDO=TRUE
                ;;

            -l|--load)
                LOAD_PATH="${2}"
                shift
                ;;

            -c|--call)
                CMD="${2}"
                shift
                ;;

            -e|--export)
                EXPORT_VARS+=("${2}")
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
            execute "${CMD}" "${target}"
        done
    else
        abort "No targets specified"
    fi
}


if [[ -n "${BASH_SOURCE:-}" && "${0}" = "${BASH_SOURCE}" ]]; then
    main "${@}"
fi
