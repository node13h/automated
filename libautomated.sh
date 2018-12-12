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

LOCAL_KERNEL=$(uname -s)

DEBUG=FALSE
DISABLE_COLOUR=FALSE

SUDO=FALSE
SUDO_PASSWORDLESS=FALSE
SUDO_PASSWORD_ON_STDIN=FALSE

EXIT_TIMEOUT=65
EXIT_SUDO_PASSWORD_NOT_ACCEPTED=66
EXIT_SUDO_PASSWORD_REQUIRED=67
EXIT_RUNNING_IN_TMUX=68
# TODO EXIT_RUNNING_IN_SCREEN=69
EXIT_MULTIPLEXER_ALREADY_RUNNING_TMUX=70

SUPPORTED_MULTIPLEXERS=(tmux)

SUDO_UID_VARIABLE='AUTOMATED_SUDO_UID'
OWNER_UID_SOURCE="\${${SUDO_UID_VARIABLE}:-\$(id -u)}"

TMUX_SOCK_PREFIX="/tmp/tmux-automated"

ANSI_FG_BLACK=30
ANSI_FG_RED=31
ANSI_FG_GREEN=32
ANSI_FG_YELLOW=33
ANSI_FG_BLUE=34
ANSI_FG_MAGENTA=35
ANSI_FG_CYAN=36
ANSI_FG_WHITE=37

ANSI_FG_BRIGHT_BLACK=90
ANSI_FG_BRIGHT_RED=91
ANSI_FG_BRIGHT_GREEN=92
ANSI_FG_BRIGHT_YELLOW=93
ANSI_FG_BRIGHT_BLUE=94
ANSI_FG_BRIGHT_MAGENTA=95
ANSI_FG_BRIGHT_CYAN=96
ANSI_FG_BRIGHT_WHITE=97

ANSWER_READ_COMMAND=('read' '-r')


newline () { printf '\n'; }

is_true () {
    [[ "${1,,}" =~ ^(yes|true|on|1)$ ]]
}

to_stderr () {
    >&2 cat
}

to_null () {
    cat >/dev/null
}

printable_only () {
  tr -cd '\11\12\15\40-\176'
}

translated () {
    local str="${1}"
    shift
    local a b

    while [[ "${#}" -gt 1 ]]; do
        a="${1}"
        b="${2}"
        str="${str//"${a}"/"${b}"}"

        shift 2
    done

    printf '%s\n' "${str}"
}

sed_replacement () {
    local str="${1}"

    # shellcheck disable=SC1003
    translated "${str}" '\' '\\' '/' '\/' '&' '\&' $'\n' '\n'
}

colorized () {
    local colour="${1}"
    local -a processor

    if is_true "${DISABLE_COLOUR}"; then
        processor=(cat)
    else
        processor=(sed -e s/^/$'\e'\["${colour}"m/ -e s/$/$'\e'\[0m/)
    fi

    "${processor[@]}"
}

text_block () {
    local name="${1}"

    sed -e 1s/^/"$(sed_replacement "BEGIN ${name}")"\\n/ -e \$s/$/\\n"$(sed_replacement "END ${name}")"/
}

prefixed_lines () {
    local prefix="${1}"

    sed -e "s/^/$(sed_replacement "${prefix}")/"
}

# shellcheck disable=SC2120
to_debug () {
    local colour="${1:-${ANSI_FG_YELLOW}}"

    if is_true "${DEBUG}"; then
        colorized "${colour}" | to_stderr
    else
        to_null
    fi
}

pipe_debug () {
    tee >(to_debug)
}

msg () {
    local msg="${1}"
    local colour="${2:-${ANSI_FG_WHITE}}"

    printf '%s\n' "${msg}" | colorized "${colour}" | to_stderr
}

msg_debug () {
    local msg="${1}"

    printf 'DEBUG %s\n' "${msg}" | to_debug
}

throw () {
    local msg="${1}"

    printf '%s\n' "${msg}" | to_stderr
    return 1
}

to_file () {
    local target_path="${1}"
    local callback="${2:-}"
    local restore_pipefail mtime_before mtime_after

    # diff will return non-zero exit code if file differs, therefore
    # pipefail shell attribute should be disabled for this
    # special case
    restore_pipefail=$(shopt -p -o pipefail)
    set +o pipefail

    mtime_before=$(file_mtime "${target_path}" 2>/dev/null) || mtime_before=0

    diff -duaN "${target_path}" - | tee >(printable_only | text_block "${1}" | to_debug "${ANSI_FG_BRIGHT_BLACK}") | patch --binary -s -p0 "$target_path"

    mtime_after=$(file_mtime "${target_path}")

    if [[ -n "${callback}" ]] && [[ "${mtime_before}" -ne "${mtime_after}" ]]; then
        "${callback}" "${target_path}"
    fi

    eval "${restore_pipefail}"
}

quoted () {
    local -a result=()

    for token in "${@}"; do
        result+=("$(printf "%q" "${token}")")
    done

    printf '%s\n' "${result[*]}"
}

md5 () {
    md5sum -b | cut -f 1 -d ' '
}

cmd () {
    # For some reason bash 4.2 does play well if the pipe is used in this function
    # causing use cases like `cmd cat <(echo "hello")` to fail.
    # For now I am redirecting the STDOUT to a subprocess as an
    # alternative.
    printf 'CMD %s\n' "$(quoted "${@}")" > >(to_debug "${ANSI_FG_GREEN}")

    "${@}"
}

cmd_is_available () {
    command -v "${1}" >/dev/null 2>&1
}

readable_file () {
    [[ -f "${1}" && -r "${1}" ]]
}

readable_directory () {
    [[ -d "${1}" && -r "${1}" ]]
}

file_mode () {
    local path="${1}"

    case "${LOCAL_KERNEL}" in
        FreeBSD|OpenBSD|Darwin)
            stat -f '%#Mp%03Lp' "${path}"
            ;;
        Linux)
            stat -c "%#03a" "${path}"
            ;;
        *)
            python_interpreter -c "from __future__ import print_function; import sys, os, stat; print('0{:o}'.format((stat.S_IMODE(os.stat(sys.argv[1]).st_mode))))" "${path}"
            ;;
    esac
}

file_mtime () {
    local path="${1}"

    case "${LOCAL_KERNEL}" in
        FreeBSD|OpenBSD|Darwin)
            stat -f '%Um' "${path}"
            ;;
        Linux)
            stat -c "%Y" "${path}"
            ;;
        *)
            python_interpreter -c "from __future__ import print_function; import sys, os, stat; print(os.stat(sys.argv[1])[stat.ST_MTIME])" "${path}"
            ;;
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

tmux_command () {
    cmd tmux -S "${TMUX_SOCK_PREFIX}-${AUTOMATED_OWNER_UID}" "${@}"
}

multiplexer_present () {
    local multiplexer

    for multiplexer in "${SUPPORTED_MULTIPLEXERS[@]}"; do
        if cmd_is_available "${multiplexer}"; then
            printf '%s\n' "${multiplexer}"
            return 0
        fi
    done

    return 1
}

supported_multiplexers () {
    printf '%s\n' "${SUPPORTED_MULTIPLEXERS[@]}"
}

run_in_multiplexer () {
    local multiplexer

    if ! multiplexer=$(multiplexer_present); then
        throw "Multiplexer is not available. Please install one of the following: ${SUPPORTED_MULTIPLEXERS[*]}"
    fi

    case "${multiplexer}" in
        tmux)
            if tmux_command ls 2>/dev/null | to_debug; then
                msg_debug "Multiplexer is already running"
                exit "${EXIT_MULTIPLEXER_ALREADY_RUNNING_TMUX}"
            else
                msg_debug "Starting multiplexer and sending commands"
                tmux_command new-session -d
                tmux_command -l send "${@}"
                tmux_command send ENTER
            fi

            chown "${AUTOMATED_OWNER_UID}" "${TMUX_SOCK_PREFIX}-${AUTOMATED_OWNER_UID}"

            exit "${EXIT_RUNNING_IN_TMUX}"
            ;;

        # TODO screen
    esac
}

interactive_answer () {
    local target="${1}"
    local prompt="${2}"
    local default_value="${3:-}"

    local answer

    local -a message=("${prompt}" "(${target})")
    [[ -z "${default_value}" ]] || message+=("[${default_value}]")

    {
        printf '%s: ' "${message[*]}"
        "${ANSWER_READ_COMMAND[@]}" answer
        newline

    } </dev/tty >/dev/tty

    if [[ -n "${default_value}" && -z "${answer}" ]]; then
        printf '%s\n' "${default_value}"
    else
        printf '%s\n' "${answer}"
    fi
}

interactive_secret () {
    local -a ANSWER_READ_COMMAND=('read' '-r' '-s')

    interactive_answer "${@}"
}

confirm () {
    local target="${1}"
    local prompt="${2}"
    local default_value="${3:-N}"

    local answer

    while true; do
        answer=$(interactive_answer "${target}" "${prompt} Y/N?" "${default_value}")

        case "${answer}" in
            [yY]) return 0
                  ;;
            [nN]) return 1
                  ;;
        esac
    done
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

target_as_vars () {
    local target="${1}"
    local username_var="${2:-username}"
    local address_var="${3:-address}"
    local port_var="${4:-port}"

    local username address port
    local -a args=()

    if [[ "${target}" =~ ^((.+)@)?(\[([:0-9A-Fa-f]+)\])(:([0-9]+))?$ ]] ||
           [[ "${target}" =~ ^((.+)@)?(([-.0-9A-Za-z]+))(:([0-9]+))?$ ]]; then
        printf '%s=%s\n' "${username_var}" "$(quoted "${BASH_REMATCH[2]}")"
        printf '%s=%s\n' "${address_var}" "$(quoted "${BASH_REMATCH[4]}")"
        printf '%s=%s\n' "${port_var}" "$(quoted "${BASH_REMATCH[6]}")"
    else
        return 1
    fi
}

target_address_only () {
    local target="${1}"
    local username address port

    eval "$(target_as_vars "${target}" username address port)"

    printf '%s\n' "${address}"
}

target_as_ssh_arguments () {
    local target="${1}"
    local username address port
    local -a args=()

    eval "$(target_as_vars "${target}" username address port)"

    if [[ -n "${port}" ]]; then
        args+=(-p "${port}")
    fi

    if [[ -n "${username}" ]]; then
        args+=(-l "${username}")
    fi

    args+=("${address}")

    printf '%s\n' "${args[*]}"
}

pty_helper_script () {
    cat "${AUTOMATED_LIBDIR%/}/pty_helper.py"
}

pty_helper_settings () {
    local var
    local -a result=()

    for var in SUDO_UID_VARIABLE EXIT_TIMEOUT EXIT_SUDO_PASSWORD_NOT_ACCEPTED EXIT_SUDO_PASSWORD_REQUIRED; do
        result+=("${var}=$(quoted "${!var}")")
    done

    printf '%s\n' "${result[*]}"
}

in_proper_context () {
    local command="${1}"
    local force_sudo_password="${2:-FALSE}"
    # shellcheck disable=SC2016
    local cmdline=('PYTHON_INTERPRETER=$(command -v python3) || PYTHON_INTERPRETER=$(command -v python2);')

    if is_true "${SUDO}"; then
        cmdline+=("$(pty_helper_settings) \"\${PYTHON_INTERPRETER}\" <(\"\${PYTHON_INTERPRETER}\" -m base64 -d <<< $(pty_helper_script | gzip | base64_encode) | gunzip)")

        if ! is_true "${force_sudo_password}" && is_true "${SUDO_PASSWORDLESS}"; then
            cmdline+=("--sudo-passwordless")
        fi
    fi

    cmdline+=("${command}")

    printf '%s\n' "${cmdline[*]}"
}

loadable_files () {
    local file_path load_path

    [[ "${#}" -gt 0 ]] || return 0

    for load_path in "${@}"; do
        if readable_file "${load_path}"; then
            printf '%s\n' "${load_path}"
        elif readable_directory "${load_path}"; then
            for file_path in "${load_path%/}/"*.sh; do
                if readable_file "${file_path}"; then
                    printf '%s\n' "${file_path}"
                fi
            done
        fi
    done
}

file_as_code () {
    local src="${1}"
    local dst="${2}"
    local mode boundary

    ! [[ -d "${src}" ]] || throw "${src} is a directory. Directories are not supported"

    mode=$(file_mode "${src}")
    # Not copying owner information intentionally

    boundary="EOF-$(md5 <<< "${dst}")"

    cat <<EOF
touch $(quoted "${dst}")
chmod ${mode} $(quoted "${dst}")
base64_decode <<"${boundary}" | gzip -d >$(quoted "${dst}")
EOF

    gzip -c "${src}" | base64_encode

    cat <<EOF
${boundary}
EOF
}

drop_fn_name () {
    local file_id="${1}"

    printf 'drop_%s\n' "$(md5 <<< "${file_id}")"
}

drop () {
    local file_id="${1}"
    local dst="${2}"
    local mode="${3:-}"

    # shellcheck disable=SC2091
    "$(drop_fn_name "${file_id}")" "${dst}" "${mode}"
}

file_as_function () {
    local src="${1}"
    local file_id="${2}"
    local mode boundary fn_name

    ! [[ -d "${src}" ]] || throw "${src} is a directory. Directories are not supported"

    mode=$(file_mode "${src}")
    # Not copying owner information intentionally

    boundary="EOF-$(md5 <<< "${file_id}")"
    fn_name=$(drop_fn_name "${file_id}")

    cat <<EOF
${fn_name} () {
  local dst="\${1}"
  local mode="\${2:-${mode}}"

  touch "\${dst}"
  chmod "\${mode}" "\${dst}"
  base64_decode <<"${boundary}" | gzip -d >"\${dst}"
EOF

    gzip -c "${src}" | base64_encode

    cat <<EOF
${boundary}
}
EOF
}

declared_var () {
    local var="${1}"

    declare -p "${var}"
    printf 'msg_debug "declared variable %s"\n' "$(quoted "${var}")"
}

declared_function () {
    local fn="${1}"

    declare -pf "${fn}"
    printf 'msg_debug "declared function %s"\n' "$(quoted "${fn}")"
}

sourced_file () {
    local path="${1}"

    cat "${path}"
    newline
    printf 'msg_debug "sourced %s"\n' "$(quoted "${path}")"
}

exit_after () {
    local exit_code="${1}"
    shift

    "${@}"

    exit "${exit_code}"
}

base64_encode () {
    if [[ "${LOCAL_KERNEL}" = 'Linux' ]] && cmd_is_available base64; then
        base64 -w 0
    elif cmd_is_available openssl; then
        openssl base64 -A
    else
        python_interpreter -c 'from __future__ import unicode_literals, print_function; import sys; import base64; stdout = sys.stdout.buffer.write if hasattr(sys.stdout, "buffer") else sys.stdout.write; stdin = sys.stdin.buffer.read if hasattr(sys.stdin, "buffer") else sys.stdin.read; list(filter(None, (stdout(base64.b64encode(i)) for i in iter(lambda: stdin(3072), b""))))'
    fi

    printf '\n'
}

base64_decode () {
    if [[ "${LOCAL_KERNEL}" = 'Linux' ]] && cmd_is_available base64; then
        base64 -d
    elif cmd_is_available openssl; then
        openssl base64 -d -A
    else
        python_interpreter -c 'from __future__ import unicode_literals, print_function; import sys; import base64; stdout = sys.stdout.buffer.write if hasattr(sys.stdout, "buffer") else sys.stdout.write; stdin = sys.stdin.buffer.read if hasattr(sys.stdin, "buffer") else sys.stdin.read; list(filter(None, (stdout(base64.b64decode(i)) for i in iter(lambda: stdin(3072), b""))))'
    fi
}

python_interpreter () {
    if cmd_is_available python3; then
        python3 "${@}"
    else
        python2 "${@}"
    fi
}

supported_automated_versions () {
    declare -r SEMVER_RE='^([0-9]+).([0-9]+).([0-9]+)(-([0-9A-Za-z.-]+))?(\+([0-9A-Za-z.-]))?$'
    declare -r VER_RE='^([0-9]+)(.([0-9]+))?(.([0-9]+))?$'

    [[ "$AUTOMATED_VERSION" =~ $SEMVER_RE ]]

    declare automated_major="${BASH_REMATCH[1]}"
    declare automated_minor="${BASH_REMATCH[2]}"
    declare automated_patch="${BASH_REMATCH[3]}"

    declare version match

    for version in "$@"; do

        match=1

        [[ "$version" =~ $VER_RE ]]

        [[ "$automated_major" -eq "${BASH_REMATCH[1]}" ]] || match=0

        if [[ -n "${BASH_REMATCH[3]:+x}" ]]; then
            [[ "$automated_minor" -eq "${BASH_REMATCH[3]}" ]] || match=0
        fi

        if [[ -n "${BASH_REMATCH[5]:+x}" ]]; then
            [[ "$automated_patch" -eq "${BASH_REMATCH[5]}" ]] || match=0
        fi

        if [[ "$match" -eq 1 ]]; then
            return 0
        fi
    done

    return 1
}
