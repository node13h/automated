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

AUTOMATED_DEBUG="${AUTOMATED_DEBUG:-FALSE}"

# https://no-color.org/
if [[ -n "${NO_COLOR:-}" ]]; then
    AUTOMATED_DISABLE_COLOUR="${AUTOMATED_DISABLE_COLOUR:-TRUE}"
else
    AUTOMATED_DISABLE_COLOUR="${AUTOMATED_DISABLE_COLOUR:-FALSE}"
fi

AUTOMATED_EXIT_RUNNING_IN_TMUX=68
AUTOMATED_EXIT_MULTIPLEXER_ALREADY_RUNNING_TMUX=69

declare -a AUTOMATED_SUPPORTED_MULTIPLEXERS=(tmux)

AUTOMATED_TMUX_SOCK_PREFIX="${AUTOMATED_TMUX_SOCK_PREFIX:-/tmp/tmux-automated}"
AUTOMATED_TMUX_FIFO_PREFIX="${AUTOMATED_TMUX_FIFO_PREFIX:-/tmp/tmux-fifo}"

declare -a AUTOMATED_ANSWER_READ_COMMAND=('read' '-r')

is_true () {
    [[ "${1,,}" =~ ^(yes|true|on|1)$ ]]
}

printable_only () {
  tr -cd '\11\12\15\40-\176'
}

translated () {
    declare str="${1}"
    shift
    declare a b

    while [[ "${#}" -gt 1 ]]; do
        a="${1}"
        b="${2}"
        str="${str//"${a}"/"${b}"}"

        shift 2
    done

    printf '%s\n' "${str}"
}

sed_replacement () {
    declare str="${1}"

    # shellcheck disable=SC1003
    translated "${str}" '\' '\\' '/' '\/' '&' '\&' $'\n' '\n'
}

colorized () {
    declare fg_colour="${1}"

    declare -A colour_mappings=(
        [BLACK]=30
        [RED]=31
        [GREEN]=32
        [YELLOW]=33
        [BLUE]=34
        [MAGENTA]=35
        [CYAN]=36
        [WHITE]=37
        [BRIGHT_BLACK]=90
        [BRIGHT_RED]=91
        [BRIGHT_GREEN]=92
        [BRIGHT_YELLOW]=93
        [BRIGHT_BLUE]=94
        [BRIGHT_MAGENTA]=95
        [BRIGHT_CYAN]=96
        [BRIGHT_WHITE]=97
    )

    [[ -n "${colour_mappings[$fg_colour]:-}" ]] || throw "Invalid colour ${fg_colour}"

    if is_true "${AUTOMATED_DISABLE_COLOUR}"; then
        cat
    else
        sed -e s/^/$'\e'\["${colour_mappings[${fg_colour}]}"m/ -e s/$/$'\e'\[0m/
    fi
}

text_block () {
    declare name="${1}"

    sed -e 1s/^/"$(sed_replacement "BEGIN ${name}")"\\n/ -e \$s/$/\\n"$(sed_replacement "END ${name}")"/
}

prefixed_lines () {
    declare prefix="${1}"

    sed -e "s/^/$(sed_replacement "${prefix}")/"
}

# shellcheck disable=SC2120
to_debug () {
    declare fg_colour="${1:-YELLOW}"

    if is_true "${AUTOMATED_DEBUG}"; then
        colorized "${fg_colour}" >&2
    else
        cat >/dev/null
    fi
}

pipe_debug () {
    tee >(to_debug)
}

log_info () {
    declare msg="${1}"

    printf '%s\n' "$msg" | colorized WHITE >&2
}

log_error () {
    declare msg="${1}"

    printf 'ERROR %s\n' "$msg" | colorized RED >&2
}

log_debug () {
    declare msg="${1}"
    declare fg_colour="${2:-YELLOW}"

    if is_true "${AUTOMATED_DEBUG}"; then
        printf 'DEBUG %s\n' "$msg" | colorized "${fg_colour}" >&2
    fi
}

log_cmd_trap () {
    declare bash_command_firstline
    bash_command_firstline=$(printf '%s\n' "$BASH_COMMAND" | head -n 1)

    # shellcheck disable=SC2086
    set -- $bash_command_firstline

    [[ "${#}" -gt 0 ]] || return 0

    declare stack_depth="${#FUNCNAME[@]}"

    [[ "${stack_depth}" -gt 0 ]] || return 0

    ! [[ "${stack_depth}" -gt $((AUTOMATED_FUNCTRACE_DEPTH+1)) ]] || return 0

    declare current_fn="${FUNCNAME[1]:-}"

    # Only trace supported commands
    declare current_command="${1}"

    # Filter out function entrypoints
    ! [[ "${current_fn}" == "${current_command}" ]] || return 0

    declare current_command_type
    current_command_type=$(type -t "${current_command}") || return 0

    [[ "${current_command_type}" =~ file|function ]] || return 0

    declare indent
    indent=$((stack_depth-1))

    declare padding
    padding=$(printf "%${indent}s" | tr ' ' '|')

    # This intermediate variable exists solely for Bash 4.2 compatibility.
    # A bug in this Bash version would cause all process substitution FIFOs
    # to be invalidated when pipeline is executed.
    #
    # Pipeline wrapped in a command substitution does not seem
    # to trigger the bug, however.
    #
    # This does not solve the problem in general, we just ensure this
    # debug trap handler does not contribute to it.
    declare msg
    msg=$(printf 'CMD %s%s%s\n' "${padding}${padding:+ }" "${current_fn:+${current_fn}(): }" "${*}" | head -n 1 | colorized GREEN)

    printf '%s\n' "$msg"  >&2
}

throw () {
    declare msg="${1}"

    printf '%s\n' "${msg}" | colorized RED >&2
    exit 1
}

to_file () {
    declare target_path="${1}"
    declare callback="${2:-}"
    declare restore_pipefail mtime_before mtime_after

    # diff will return non-zero exit code if file differs, therefore
    # pipefail shell attribute should be disabled for this
    # special case
    restore_pipefail=$(shopt -p -o pipefail)
    set +o pipefail

    mtime_before=$(file_mtime "${target_path}" 2>/dev/null) || mtime_before=0

    if cmd_is_available 'diff' && cmd_is_available 'patch'; then
        diff -duaN "${target_path}" - | tee >(printable_only | text_block "${1}" | to_debug BRIGHT_BLACK) | patch --binary -s -p0 "$target_path"
    else
        log_debug 'Please consider installing patch and diff commands to enable diff support for to_file()'

        tee >(printable_only | text_block "${1}" | to_debug BRIGHT_BLACK) >"${target_path}"
    fi

    mtime_after=$(file_mtime "${target_path}")

    if [[ -n "${callback}" ]] && [[ "${mtime_before}" -ne "${mtime_after}" ]]; then
        eval "${callback}"
    fi

    eval "${restore_pipefail}"
}

quoted () {
    declare -a result=()

    for token in "${@}"; do
        result+=("$(printf "%q" "${token}")")
    done

    printf '%s\n' "${result[*]}"
}

md5 () {
    md5sum -b | cut -f 1 -d ' '
}

joined () {
    declare sep="${1}"
    shift
    declare item

    [[ "${#}" -gt 0 ]] || return 0

    printf '%s' "${1}"
    shift

    for item in "${@}"; do
        printf "${sep}%s" "${item}"
    done

    printf '\n'
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

# TODO: Replace with $OSTYPE?
local_kernel () {
    uname -s
}

file_mode () {
    declare path="${1}"

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
    declare path="${1}"

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
    declare path="${1}"

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
    log_debug "tmux command ${*} over the ${AUTOMATED_TMUX_SOCK_PREFIX}-${AUTOMATED_OWNER_UID} socket" BRIGHT_BLUE
    tmux -S "${AUTOMATED_TMUX_SOCK_PREFIX}-${AUTOMATED_OWNER_UID}" "${@}"
}

multiplexer_present () {
    declare multiplexer

    for multiplexer in "${AUTOMATED_SUPPORTED_MULTIPLEXERS[@]}"; do
        if cmd_is_available "${multiplexer}"; then
            printf '%s\n' "${multiplexer}"
            return 0
        fi
    done

    return 1
}

run_in_tmux () {
    declare command="${1}"

    if tmux_command ls 2>/dev/null | to_debug; then
        log_debug "Multiplexer is already running"
        exit "${AUTOMATED_EXIT_MULTIPLEXER_ALREADY_RUNNING_TMUX}"
    fi

    declare sock_file="${AUTOMATED_TMUX_SOCK_PREFIX}-${AUTOMATED_OWNER_UID}"
    declare fifo_file="${AUTOMATED_TMUX_FIFO_PREFIX}-${AUTOMATED_OWNER_UID}"

    log_debug "Starting multiplexer and executing commands"

    log_debug "$command"

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
    declare multiplexer

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
    declare target="${1}"
    declare prompt="${2}"
    declare default_value="${3:-}"

    declare answer

    declare -a message=("${prompt}" "(${target})")
    [[ -z "${default_value}" ]] || message+=("[${default_value}]")

    {
        printf '%s: ' "${message[*]}"
        "${AUTOMATED_ANSWER_READ_COMMAND[@]}" answer
        printf '\n'

    } </dev/tty >/dev/tty

    if [[ -n "${default_value}" && -z "${answer}" ]]; then
        printf '%s\n' "${default_value}"
    else
        printf '%s\n' "${answer}"
    fi
}

interactive_secret () {
    declare -a AUTOMATED_ANSWER_READ_COMMAND=('read' '-r' '-s')

    interactive_answer "${@}"
}

confirm () {
    declare target="${1}"
    declare prompt="${2}"
    declare default_value="${3:-N}"

    declare answer

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
    declare target="${1}"
    declare username_var="${2:-username}"
    declare address_var="${3:-address}"
    declare port_var="${4:-port}"

    declare username address port
    declare -a args=()

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
    declare target="${1}"
    declare username address port

    eval "$(target_as_vars "${target}" username address port)"

    printf '%s\n' "${address}${port:+:${port}}"
}

target_as_ssh_arguments () {
    declare target="${1}"
    declare username address port
    declare -a args=()

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
    declare name="${1}"

    [[ "$(type -t "${name}")" = 'function' ]]
}

file_as_code () {
    declare src="${1}"
    declare dst="${2}"
    declare mode boundary

    if [[ -d "${src}" ]]; then
        throw "${src} is a directory. directories are not supported"
    fi

    if ! [[ -e "${src}" ]]; then
        throw "${src} does not exist"
    fi

    boundary="EOF-$(md5 <<< "${dst}")"

    if [[ -f "${src}" ]]; then
        mode=$(file_mode "${src}")
    fi

    cat <<EOF
base64_decode <<"${boundary}" | gzip -d >$(quoted "${dst}")
EOF

    gzip -n -6 - <"${src}" | base64_encode

    cat <<EOF
${boundary}
EOF

    if [[ -f "${src}" ]]; then
        cat <<EOF
chmod ${mode} $(quoted "${dst}")
EOF
    fi

    cat <<EOF
log_debug $(quoted "copied ${src} to ${dst} on the target")
EOF
}


file_as_function () {
    declare src="${1}"
    declare file_id="${2:-${src}}"
    declare mode file_id_hash

    if [[ -d "${src}" ]]; then
        throw "${src} is a directory. directories are not supported"
    fi

    if ! [[ -e "${src}" ]]; then
        throw "${src} does not exist"
    fi

    file_id_hash=$(md5 <<< "${file_id}")

    if [[ -f "${src}" ]]; then
        mode=$(file_mode "${src}")
    fi

    cat <<EOF
drop_${file_id_hash}_body () {
    base64_decode <<"EOF-${file_id_hash}" | gzip -d
EOF

    gzip -n -6 - <"${src}" | base64_encode

    cat <<EOF
EOF-${file_id_hash}
}
EOF
    if [[ -f "${src}" ]]; then
        cat <<EOF
AUTOMATED_DROP_${file_id_hash^^}_MODE=${mode}
EOF
    fi

    cat <<EOF
log_debug $(quoted "shipped ${src} as the file id ${file_id}")
EOF
}

declared_var () {
    declare var="${1}"

    (
        set -e

        if [[ -n "${2+defined}" ]]; then
            unset "${var}"
            declare "${var}=${2}"
        fi

        declare -p "${var}"
    )

    printf 'log_debug "declared variable %s"\n' "$(quoted "${var}")"
}

declared_function () {
    declare fn="${1}"

    declare -f "${fn}"
    printf 'log_debug "declared function %s"\n' "$(quoted "${fn}")"
}

drop () {
    declare file_id="${1}"
    declare dst="${2:-}"

    declare mode file_id_hash mode_var

    file_id_hash=$(md5 <<< "${file_id}")

    is_function "drop_${file_id_hash}_body" || throw "File id ${file_id} is not dragged"

    if [[ -n "${dst}" ]]; then
        mode_var="AUTOMATED_DROP_${file_id_hash^^}_MODE"
        if [[ -n "${!mode_var:-}" ]]; then
            mode="${3:-${!mode_var}}"
        else
            mode="${3:-}"
        fi

        "drop_${file_id_hash}_body" "${file_id}" >"${dst}"

        if [[ -n "${mode:-}" ]]; then
            chmod "${mode}" "${dst}"
        fi
    else
        "drop_${file_id_hash}_body" "${file_id}"
    fi
}

sourced_drop () {
    declare file_id="${1}"

    declare file_id_hash

    file_id_hash=$(md5 <<< "${file_id}")

    cat <<EOF
is_function "drop_${file_id_hash}_body" || throw $(quoted "File id ${file_id} is not dragged")
source <(drop_${file_id_hash}_body)
log_debug $(quoted "sourced file id ${file_id}")
EOF
}

exit_after () {
    declare exit_code="${1}"
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
    declare version_to_match="${1}"
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

bash_minor_version_is_higher_than () {
    declare major="${1}"
    declare minor="${2}"

    ! [[ "${BASH_VERSINFO[0]}" -lt "${major}" ]] || return 1

    ! [[ "${BASH_VERSINFO[0]}" -eq "${major}" && "${BASH_VERSINFO[1]}" -lt "${minor}" ]] || return 1
}

supported_automated_versions () {
    if ! semver_matches_one_of "${AUTOMATED_VERSION}" "$@"; then
        throw "Unsupported version ${AUTOMATED_VERSION} of Automated detected. Supported versions are: $(joined ', ' "${@}")"
    fi
}

automated_bootstrap_environment () {
    declare target="${1}"

    cat <<EOF
#!/usr/bin/env bash

set -euo pipefail

log_debug () {
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

    # coproc is necessary to catch an error exit code from the process
    # substitution
    declare cpid
    coproc automated_environment_script "${target}"
    cpid="${COPROC_PID}"

    file_as_function <(cat <&"${COPROC[0]}") '__automated_environment'

    # wait will return the exit code of the coproc
    wait "$cpid"
    sourced_drop '__automated_environment'
}


deprecated_with () {
    log_debug "${FUNCNAME[1]}() is DEPRECATED. Use ${1}() instead."

    "$@"
}

deprecated_with_alternatives () {
    log_debug "${FUNCNAME[1]}() is DEPRECATED. Alternatives ${*}"
}

deprecated_function () {
    log_debug "${FUNCNAME[1]}() is DEPRECATED."
}
