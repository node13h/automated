#!/usr/bin/env bash

# MIT license

# Copyright (c) 2016-2021 Sergej Alikov <sergej.alikov@gmail.com>

# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:

# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.

# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

set -euo pipefail

AUTOMATED_DEBUG=FALSE
AUTOMATED_DISABLE_COLOUR=FALSE

AUTOMATED_EXIT_RUNNING_IN_TMUX=68
AUTOMATED_EXIT_MULTIPLEXER_ALREADY_RUNNING_TMUX=69

AUTOMATED_SUPPORTED_MULTIPLEXERS=(tmux)

AUTOMATED_TMUX_SOCK_PREFIX='/tmp/tmux-automated'
AUTOMATED_TMUX_FIFO_PREFIX='/tmp/tmux-fifo'

AUTOMATED_ANSWER_READ_COMMAND=('read' '-r')

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


is_true () {
    [[ "${1,,}" =~ ^(yes|true|on|1)$ ]]
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

    if is_true "${AUTOMATED_DISABLE_COLOUR}"; then
        cat
    else
        sed -e s/^/$'\e'\["${colour}"m/ -e s/$/$'\e'\[0m/
    fi
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

    if is_true "${AUTOMATED_DEBUG}"; then
        colorized "${colour}" >&2
    else
        cat >/dev/null
    fi
}

pipe_debug () {
    tee >(to_debug)
}

msg () {
    local msg="${1}"
    local colour="${2:-${ANSI_FG_WHITE}}"

    if is_true "${AUTOMATED_DISABLE_COLOUR}"; then
        printf '%s\n' "${msg}" >&2
    else
        printf $'\e''[%sm%s'$'\e''[0m\n' "${colour}" "${msg}" >&2
    fi
}

msg_debug () {
    local msg="${1}"
    local colour="${2:-${ANSI_FG_YELLOW}}"

    if is_true "${AUTOMATED_DEBUG}"; then
        msg "DEBUG ${msg}" "${colour}"
    fi
}

throw () {
    local msg="${1}"

    printf '%s\n' "${msg}" >&2
    exit 1
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

    if cmd_is_available 'diff' && cmd_is_available 'patch'; then
        diff -duaN "${target_path}" - | tee >(printable_only | text_block "${1}" | to_debug "${ANSI_FG_BRIGHT_BLACK}") | patch --binary -s -p0 "$target_path"
    else
        msg_debug 'Please consider installing patch and diff commands to enable diff support for to_file()'

        tee >(printable_only | text_block "${1}" | to_debug "${ANSI_FG_BRIGHT_BLACK}") >"${target_path}"
    fi

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

joined () {
    local sep="${1}"
    shift
    local item

    [[ "${#}" -gt 0 ]] || return 0

    printf '%s' "${1}"
    shift

    for item in "${@}"; do
        printf "${sep}%s" "${item}"
    done

    printf '\n'
}

cmd () {
    msg_debug "CMD $(quoted "${@}")" "${ANSI_FG_GREEN}"

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

local_kernel () {
    uname -s
}

file_mode () {
    local path="${1}"

    case "$(local_kernel)" in
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

file_owner () {
    local path="${1}"

    case "$(local_kernel)" in
        FreeBSD|OpenBSD|Darwin)
            stat -f '%Su:%Sg' "${path}"
            ;;
        Linux)
            stat -c "%U:%G" "${path}"
            ;;
        *)
            python_interpreter -c "from __future__ import print_function; import sys, os, stat, pwd, grp; st = os.stat(sys.argv[1]); print('{}:{}'.format(pwd.getpwuid(st.st_uid)[0], grp.getgrgid(st.st_gid)[0]))" "${path}"
            ;;
    esac
}

file_mtime () {
    local path="${1}"

    case "$(local_kernel)" in
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

tmux_command () {
    msg_debug "tmux command ${*} over the ${AUTOMATED_TMUX_SOCK_PREFIX}-${AUTOMATED_OWNER_UID} socket" \
              "${ANSI_FG_BRIGHT_BLUE}"
    tmux -S "${AUTOMATED_TMUX_SOCK_PREFIX}-${AUTOMATED_OWNER_UID}" "${@}"
}

multiplexer_present () {
    local multiplexer

    for multiplexer in "${AUTOMATED_SUPPORTED_MULTIPLEXERS[@]}"; do
        if cmd_is_available "${multiplexer}"; then
            printf '%s\n' "${multiplexer}"
            return 0
        fi
    done

    return 1
}

run_in_tmux () {
    local command="${1}"

    if tmux_command ls 2>/dev/null | to_debug; then
        msg_debug "Multiplexer is already running"
        exit "${AUTOMATED_EXIT_MULTIPLEXER_ALREADY_RUNNING_TMUX}"
    fi

    local sock_file="${AUTOMATED_TMUX_SOCK_PREFIX}-${AUTOMATED_OWNER_UID}"
    local fifo_file="${AUTOMATED_TMUX_FIFO_PREFIX}-${AUTOMATED_OWNER_UID}"

    msg_debug "Starting multiplexer and executing commands"

    msg_debug "$command"

    mkfifo "${fifo_file}"

    tmux_command \
        new-session \
        -d \
        "/usr/bin/env bash $(quoted "${fifo_file}")"

    {
        cat <<EOF
rm -f -- $(quoted "${fifo_file}")
EOF
        automated_bootstrap_environment "${AUTOMATED_CURRENT_TARGET}"

        cat <<EOF
${command}
EOF
    } >"${fifo_file}"

    chown "${AUTOMATED_OWNER_UID}" "${sock_file}"

    exit "${AUTOMATED_EXIT_RUNNING_IN_TMUX}"
}

run_in_multiplexer () {
    local multiplexer

    if ! multiplexer=$(multiplexer_present); then
        throw "Multiplexer is not available. Please install one of the following: ${AUTOMATED_SUPPORTED_MULTIPLEXERS[*]}"
    fi

    case "${multiplexer}" in
        tmux)
            run_in_tmux "${@}"
            ;;
    esac
}

# shellcheck disable=SC2016
interactive_multiplexer_session () {
    run_in_multiplexer "bash -i -s -- <(automated_bootstrap_environment $(quoted "$AUTOMATED_CURRENT_TARGET")) <<< $(quoted 'source $1; exec </dev/tty')"
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
        "${AUTOMATED_ANSWER_READ_COMMAND[@]}" answer
        newline

    } </dev/tty >/dev/tty

    if [[ -n "${default_value}" && -z "${answer}" ]]; then
        printf '%s\n' "${default_value}"
    else
        printf '%s\n' "${answer}"
    fi
}

interactive_secret () {
    local -a AUTOMATED_ANSWER_READ_COMMAND=('read' '-r' '-s')

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

target_as_vars () {
    local target="${1}"
    local username_var="${2:-username}"
    local address_var="${3:-address}"
    local port_var="${4:-port}"

    local username address port
    local -a args=()

    if [[ "${target}" =~ ^((.+)@)?(\[([:0-9A-Fa-f]+)\])(:([0-9]+))?$ ]] ||
           [[ "${target}" =~ ^((.+)@)?(([-.0-9A-Za-z]+))(:([0-9]+))?$ ]]; then
        printf '%s=%q\n' "${username_var}" "${BASH_REMATCH[2]}"
        printf '%s=%q\n' "${address_var}" "${BASH_REMATCH[4]}"
        printf '%s=%q\n' "${port_var}" "${BASH_REMATCH[6]}"
    else
        return 1
    fi
}

target_address_only () {
    local target="${1}"
    local username address port

    eval "$(target_as_vars "${target}" username address port)"

    printf '%s\n' "${address}${port:+:${port}}"
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

    printf '%s\n' "${args[@]}"
}

is_function () {
    local name="${1}"

    [[ "$(type -t "${name}")" = 'function' ]]
}

file_as_code () {
    local src="${1}"
    local dst="${2}"
    local mode boundary

    if [[ -d "${src}" ]]; then
        cat <<EOF
throw $(quoted "${src} is a directory. directories are not supported")
EOF
        return 1
    fi

    if ! [[ -r "${src}" ]]; then
        cat <<EOF
throw $(quoted "${src} was not readable at the moment of the shipping attempt")
EOF
        return 1
    fi

    mode=$(file_mode "${src}")

    boundary="EOF-$(md5 <<< "${dst}")"

    cat <<EOF
touch $(quoted "${dst}")
chmod 0600 $(quoted "${dst}")
base64_decode <<"${boundary}" | gzip -d >$(quoted "${dst}")
EOF

    gzip -n -6 - <"${src}" | base64_encode

    cat <<EOF
${boundary}
chmod ${mode} $(quoted "${dst}")
msg_debug $(quoted "copied ${src} to ${dst} on the target")
EOF
}


file_as_function () {
    local src="${1}"
    local file_id="${2:-"${src}"}"
    local mode owner file_id_hash

    if [[ -d "${src}" ]]; then
        cat <<EOF
throw $(quoted "${src} is a directory. directories are not supported")
EOF
        return 1
    fi

    if ! [[ -r "${src}" ]]; then
        cat <<EOF
throw $(quoted "${src} was not readable at the moment of the shipping attempt")
EOF
        return 1
    fi

    file_id_hash=$(md5 <<< "${file_id}")

    mode=$(file_mode "${src}")
    owner=$(file_owner "${src}")

    cat <<EOF
drop_${file_id_hash}_body () {
    base64_decode <<"EOF-${file_id_hash}" | gzip -d
EOF

    gzip -n -6 - <"${src}" | base64_encode

    cat <<EOF
EOF-${file_id_hash}
}

drop_${file_id_hash}_mode () {
    printf '%s\n' '${mode}'
}

drop_${file_id_hash}_owner () {
    printf '%s\n' '${owner}'
}
msg_debug $(quoted "shipped ${src} as the file id ${file_id}")
EOF
}

declared_var () {
    local var="${1}"

    declare -p "${var}"
    printf 'msg_debug "declared variable %s"\n' "$(quoted "${var}")"
}

declared_function () {
    local fn="${1}"

    declare -f "${fn}"
    printf 'msg_debug "declared function %s"\n' "$(quoted "${fn}")"
}

drop () {
    local file_id="${1}"
    local dst="${2:-}"

    local file_id_hash original_mode

    file_id_hash=$(md5 <<< "${file_id}")

    is_function "drop_${file_id_hash}_body" || throw "File id ${file_id} is not dragged"

    if [[ -n "${dst}" ]]; then
        original_mode=$("drop_${file_id_hash}_mode")

        local mode="${3:-${original_mode}}"

        touch "${dst}"
        chmod 0600 "${dst}"

        "drop_${file_id_hash}_body" "${file_id}" >"${dst}"

        chmod "${mode}" "${dst}"
    else
        "drop_${file_id_hash}_body" "${file_id}"
    fi
}

sourced_drop () {
    local file_id="${1}"

    local file_id_hash

    file_id_hash=$(md5 <<< "${file_id}")

    cat <<EOF
is_function "drop_${file_id_hash}_body" || throw $(quoted "File id ${file_id} is not dragged")
source <(drop_${file_id_hash}_body)
msg_debug $(quoted "sourced file id ${file_id}")
EOF
}

exit_after () {
    local exit_code="${1}"
    shift

    "${@}"

    exit "${exit_code}"
}

base64_encode () {
    if [[ "$(local_kernel)" = 'Linux' ]] && cmd_is_available base64; then
        base64 -w 0
    elif cmd_is_available openssl; then
        openssl base64 -A
    else
        python_interpreter -c 'from __future__ import unicode_literals, print_function; import sys; import base64; stdout = sys.stdout.buffer.write if hasattr(sys.stdout, "buffer") else sys.stdout.write; stdin = sys.stdin.buffer.read if hasattr(sys.stdin, "buffer") else sys.stdin.read; list(filter(None, (stdout(base64.b64encode(i)) for i in iter(lambda: stdin(3072), b""))))'
    fi

    printf '\n'
}

base64_decode () {
    if [[ "$(local_kernel)" = 'Linux' ]] && cmd_is_available base64; then
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

semver_matches_one_of () {
    local version_to_match="${1}"
    shift

    declare -r SEMVER_RE='^([0-9]+).([0-9]+).([0-9]+)(-([0-9A-Za-z.-]+))?(\+([0-9A-Za-z.-]))?$'
    declare -r VER_RE='^([0-9]+)(.([0-9]+))?(.([0-9]+))?$'

    [[ "${version_to_match}" =~ $SEMVER_RE ]] || return 1

    declare major="${BASH_REMATCH[1]}"
    declare minor="${BASH_REMATCH[2]}"
    declare patch="${BASH_REMATCH[3]}"

    declare version

    for version in "$@"; do

        [[ "$version" =~ $VER_RE ]] || continue

        [[ "$major" -eq "${BASH_REMATCH[1]}" ]] || continue

        if [[ -n "${BASH_REMATCH[3]:-}" ]]; then
            [[ "$minor" -eq "${BASH_REMATCH[3]}" ]] || continue
        fi

        if [[ -n "${BASH_REMATCH[5]:-}" ]]; then
            [[ "$patch" -eq "${BASH_REMATCH[5]}" ]] || continue
        fi

        return 0
    done

    return 1
}

supported_automated_versions () {
    if ! semver_matches_one_of "${AUTOMATED_VERSION}" "$@"; then
        throw "Unsupported version ${AUTOMATED_VERSION} of Automated detected. Supported versions are: $(joined ', ' "${@}")"
    fi
}

automated_bootstrap_environment () {
    local target="${1}"

    cat <<EOF
#!/usr/bin/env bash

set -euo pipefail

msg_debug () {
    # Mock for the bootstrap envirnment
    return 0
}

# Inception :)
automated_environment_script () {
    drop '__automated_environment'
}

EOF
    declared_function 'cmd_is_available'
    declared_function 'python_interpreter'
    declared_function 'local_kernel'
    declared_function 'base64_decode'
    declared_function 'is_function'
    declared_function 'throw'

    file_as_function <(automated_environment_script "${target}") \
                     '__automated_environment'
    sourced_drop '__automated_environment'
}
