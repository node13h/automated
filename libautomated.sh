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
EXIT_MULTIPLEXER_ALREADY_RUNNING=70

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
        str="${str//${a}/${b}}"

        shift 2
    done

    printf '%s\n' "${str}"
}

sed_replacement () {
    local str="${1}"

    # shellcheck disable=SC1003
    printf '%s\n' "$(translated "${str}" '\' '\\' '/' '\/' '&' '\&' $'\n' '\n')"
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
    which "${1}" >/dev/null 2>&1
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
            python -c "import sys, os, stat; print oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode))" "${path}"
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
            python -c "import sys, os, stat; print os.stat(sys.argv[1])[stat.ST_MTIME]" "${path}"
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

ask_sudo_password () {
    local sudo_password

    if is_true "${SUDO_PASSWORD_ON_STDIN}"; then
        read -r sudo_password
    else
        {

            printf 'SUDO password (%s): ' "${1:-localhost}"
            read -r -s sudo_password
            newline

        } </dev/tty >/dev/tty
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
    local cmdline=()

    if is_true "${SUDO}"; then
        cmdline+=("$(pty_helper_settings) python <(base64 -d <<< $(pty_helper_script | gzip | base64 -w 0) | gunzip)")

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
base64 -d <<"${boundary}" | gzip -d >$(quoted "${dst}")
EOF

    gzip -c "${src}" | base64

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
  base64 -d <<"${boundary}" | gzip -d >"\${dst}"
EOF

    gzip -c "${src}" | base64

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
