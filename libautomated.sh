#!/usr/bin/env bash

# MIT license

# Copyright (c) 2016-2022 Sergej Alikov <sergej.alikov@gmail.com>

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
    declare str="$1"
    shift
    declare a b

    while [[ "$#" -gt 1 ]]; do
        a="$1"
        b="$2"
        str="${str//"${a}"/"${b}"}"

        shift 2
    done

    printf '%s\n' "$str"
}


sed_replacement () {
    declare str="$1"

    # shellcheck disable=SC1003
    translated "$str" '\' '\\' '/' '\/' '&' '\&' $'\n' '\n'
}


colorized () {
    declare fg_colour="$1"

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

    if is_true "$AUTOMATED_DISABLE_COLOUR"; then
        cat
    else
        sed -u -e s/^/$'\e'\["${colour_mappings[${fg_colour}]}"m/ -e s/$/$'\e'\[0m/
    fi
}


text_block () {
    declare name="$1"

    declare sed_replacement_begin
    sed_replacement_begin=$(set -e; sed_replacement "BEGIN ${name}")

    declare sed_replacement_end
    sed_replacement_end=$(sed_replacement "END ${name}")

    sed -u -e 1s/^/"${sed_replacement_begin}"\\$'\n'/ -e \$s/$/\\$'\n'"${sed_replacement_end}"/
}


prefixed_lines () {
    declare prefix="$1"

    declare sed_replacement
    sed_replacement=$(set -e; sed_replacement "$prefix")

    sed -u -e s/^/"${sed_replacement}"/
}


# shellcheck disable=SC2120
to_debug () {
    declare fg_colour="${1:-YELLOW}"

    if is_true "$AUTOMATED_DEBUG"; then
        colorized "$fg_colour" >&2
    else
        cat >/dev/null
    fi
}


pipe_debug () {
    tee >(to_debug)
}


log_info () {
    declare msg="$1"

    printf '%s\n' "$msg" | colorized WHITE >&2
}


log_error () {
    declare msg="$1"

    printf 'ERROR %s\n' "$msg" | colorized RED >&2
}


log_debug () {
    declare msg="$1"
    declare fg_colour="${2:-YELLOW}"

    if is_true "$AUTOMATED_DEBUG"; then
        printf 'DEBUG %s\n' "$msg" | colorized "$fg_colour" >&2
    fi
}

# WARNING: this function is a trap which might be executed
# for each command, including process substitutions.
# Do not use anything which might alter global built-in Bash variables,
# for example do not use regex matches as they alter BASH_REMATCH.
# Do not use pipes - they break process substitution FIFOs (in some
# Bash versions, like 4.2 it's obvious, in some - it might be a rarely
# reproducible race condition which only manifests occassionally.
log_cmd_trap () {
    declare bash_command_firstline
    bash_command_firstline="${BASH_COMMAND%%$'\n'*}"

    # shellcheck disable=SC2086
    set -- $bash_command_firstline

    [[ "$#" -gt 0 ]] || return 0

    declare stack_depth="${#FUNCNAME[@]}"

    [[ "$stack_depth" -gt 0 ]] || return 0

    ! [[ "$stack_depth" -gt $((AUTOMATED_FUNCTRACE_DEPTH+1)) ]] || return 0

    declare current_fn="${FUNCNAME[1]:-}"

    # Only trace supported commands
    declare current_command="$1"

    # Filter out function entrypoints
    ! [[ "$current_fn" == "$current_command" ]] || return 0

    declare current_command_type
    current_command_type=$(type -t "$current_command") || return 0

    if ! [[ "$current_command_type" == file || "$current_command_type" == function ]]; then
        return 0
    fi

    declare indent
    indent=$((stack_depth-1))

    declare padding
    padding=$(printf "%${indent}s\n" '')

    declare format

    if is_true "$AUTOMATED_DISABLE_COLOUR"; then
        format='CMD %s%s%s\n'
    else
        format=$'\e[32mCMD %s%s%s\e[0m\\n'
    fi

    # shellcheck disable=SC2059
    printf "$format" "${padding// /|}${padding:+ }" "${current_fn:+${current_fn}(): }" "$*" >&2
} <&- >&-


throw () {
    declare msg="$1"

    printf '%s\n' "$msg" | colorized RED >&2
    exit 1
}


# This function reads from STDIN. Any command which has a potential to swallow
# the STDIN data must have it's STDIN descriptor closed.
to_file () {
    declare target_path="$1"
    declare callback="${2:-}"

    if [[ -n "$callback" ]]; then
        declare mtime_before mtime_after

        if [[ -e "$target_path" ]]; then
            mtime_before=$(set -e; file_mtime "$target_path" 2>/dev/null <&-)
        else
            mtime_before=0
        fi
    fi

    declare diff_mode
    if cmd_is_available 'diff' <&- && cmd_is_available 'patch' <&-; then
        diff_mode=1
    else
        log_debug 'Please consider installing patch and diff commands to enable diff support for to_file()' <&-
        diff_mode=0
    fi

    if [[ -e "$target_path" ]] && is_true "$diff_mode"; then
        (
            set +e

            # TODO: AUT-125 Wait for process substitution subshell using { tee >(...); wait $!; }
            # to prevent the script from moving onto the next command after the pipeline has
            # completed, but the subshell is still sending output in background.
            diff -duaN "$target_path" - | tee >(printable_only | text_block "$target_path" | to_debug BRIGHT_BLACK >/dev/null) | patch -s -p0 "$target_path" >/dev/null

            declare -a exit_codes=("${PIPESTATUS[@]}")

            set -e

            if [[ "${exit_codes[0]}" -eq 0 ]]; then
                # No diff and we don't care about the patch exit code
                log_debug "${target_path} is up to date" <&-
                exit 0
            elif [[ "${exit_codes[0]}" -gt 1 ]]; then
                log_error "diff ${target_path} failed" <&-
                exit "${exit_codes[0]}"
            elif [[ "${exit_codes[2]}" -gt 0 ]]; then
                log_error "patch ${target_path} failed" <&-
                exit "${exit_codes[2]}"
            fi
        )
    else
        # TODO: AUT-126 Write files atomically.
        # shellcheck disable=SC2094
        tee >(printable_only | text_block "$target_path" | to_debug BRIGHT_BLACK >/dev/null) >"$target_path"
    fi

    if [[ -n "$callback" ]]; then
        mtime_after=$(set -e; file_mtime "$target_path")

        if [[ "$mtime_before" -ne "$mtime_after" ]]; then
            eval "$callback"
        fi
    fi
}


quoted () {
    declare -a result=()

    declare item
    for token in "$@"; do
        item="$(printf "%q\n" "$token")"
        result+=("$item")
    done

    printf '%s\n' "${result[*]}"
}


md5 () {
    md5sum -b | cut -f 1 -d ' '
}


joined () {
    declare sep="$1"
    shift
    declare item

    [[ "$#" -gt 0 ]] || return 0

    printf '%s' "$1"
    shift

    for item in "$@"; do
        printf "${sep}%s" "$item"
    done

    printf '\n'
}


cmd_is_available () {
    command -v "$1" >/dev/null 2>&1
}


readable_file () {
    [[ -f "$1" && -r "$1" ]]
}


readable_directory () {
    [[ -d "$1" && -r "$1" ]]
}


# TODO: Replace with $OSTYPE?
local_kernel () {
    uname -s
}


file_mode () {
    declare path="$1"

    case "$(set -e; local_kernel)" in
        FreeBSD|OpenBSD|Darwin)
            stat -f '%#Mp%03Lp' "$path"
            ;;
        Linux)
            stat -c "%#03a" "$path"
            ;;
        *)
            python_interpreter -c "from __future__ import print_function; import sys, os, stat; print('0{:o}'.format((stat.S_IMODE(os.stat(sys.argv[1]).st_mode))))" "$path"
            ;;
    esac
}


file_owner () {
    declare path="$1"

    case "$(set -e; local_kernel)" in
        FreeBSD|OpenBSD|Darwin)
            stat -f '%Su:%Sg' "$path"
            ;;
        Linux)
            stat -c "%U:%G" "$path"
            ;;
        *)
            python_interpreter -c "from __future__ import print_function; import sys, os, stat, pwd, grp; st = os.stat(sys.argv[1]); print('{}:{}'.format(pwd.getpwuid(st.st_uid)[0], grp.getgrgid(st.st_gid)[0]))" "$path"
            ;;
    esac
}


file_mtime () {
    declare path="$1"

    case "$(set -e; local_kernel)" in
        FreeBSD|OpenBSD|Darwin)
            stat -f '%Um' "$path"
            ;;
        Linux)
            stat -c "%Y" "$path"
            ;;
        *)
            python_interpreter -c "from __future__ import print_function; import sys, os, stat; print(os.stat(sys.argv[1])[stat.ST_MTIME])" "$path"
            ;;
    esac
}


tmux_command () {
    log_debug "tmux command ${*} over the ${AUTOMATED_TMUX_SOCK_PREFIX}-${AUTOMATED_OWNER_UID} socket" BRIGHT_BLUE
    tmux -S "${AUTOMATED_TMUX_SOCK_PREFIX}-${AUTOMATED_OWNER_UID}" "$@"
}


multiplexer_present () {
    declare multiplexer

    for multiplexer in "${AUTOMATED_SUPPORTED_MULTIPLEXERS[@]}"; do
        if cmd_is_available "$multiplexer"; then
            printf '%s\n' "$multiplexer"
            return 0
        fi
    done

    return 1
}


run_in_tmux () {
    declare command="$1"

    if tmux_command ls 2>/dev/null | to_debug; then
        log_debug "Multiplexer is already running"
        exit "$AUTOMATED_EXIT_MULTIPLEXER_ALREADY_RUNNING_TMUX"
    fi

    declare sock_file="${AUTOMATED_TMUX_SOCK_PREFIX}-${AUTOMATED_OWNER_UID}"
    declare fifo_file="${AUTOMATED_TMUX_FIFO_PREFIX}-${AUTOMATED_OWNER_UID}"

    declare fifo_file_quoted
    fifo_file_quoted=$(set -e; quoted "$fifo_file")

    log_debug "Starting multiplexer and executing commands"

    log_debug "$command"

    mkfifo "$fifo_file"

    declare tmux_version tmux_major tmux_minor
    tmux_version=$(tmux_command -V)

    if [[ "$tmux_version" =~ ^tmux\ ([0-9]+)\.([0-9]+) ]]; then
       tmux_major="${BASH_REMATCH[1]}"
       tmux_minor="${BASH_REMATCH[2]}"
    else
        throw "Failed to parse tmux version ${tmux_version}"
    fi

    tmux_command \
        new-session \
        -d \
        "/usr/bin/env bash ${fifo_file_quoted}"

    # https://github.com/tmux/tmux/issues/3220
    if [[ "$tmux_major" -eq 3 && "$tmux_minor" -gt 2 ]] || [[ "$tmux_major" -gt 3 ]]; then
        declare current_uid
        current_uid=$(id -u)
        if [[ "$current_uid" -ne "$AUTOMATED_OWNER_UID" ]]; then
            declare owner_username
            owner_username=$(id -un "$AUTOMATED_OWNER_UID")
            tmux_command server-access -aw "$owner_username"
        fi
    fi

    # shellcheck disable=SC2094
    {
        cat <<EOF
rm -f -- ${fifo_file_quoted}
EOF
        automated_bootstrap_environment "$AUTOMATED_CURRENT_TARGET"

        cat <<EOF
${command}
EOF
    } >"$fifo_file"

    chown "$AUTOMATED_OWNER_UID" "$sock_file"

    exit "$AUTOMATED_EXIT_RUNNING_IN_TMUX"
}


run_in_multiplexer () {
    declare multiplexer

    if ! multiplexer=$(set -e; multiplexer_present); then
        throw "Multiplexer is not available. Please install one of the following: ${AUTOMATED_SUPPORTED_MULTIPLEXERS[*]}"
    fi

    case "$multiplexer" in
        tmux)
            run_in_tmux "$@"
            ;;
    esac
}


# shellcheck disable=SC2016
interactive_multiplexer_session () {
    declare current_target_quoted
    current_target_quoted=$(set -e; quoted "$AUTOMATED_CURRENT_TARGET")

    declare script_quoted
    script_quoted=$(set -e; quoted 'source $1; exec </dev/tty')

    run_in_multiplexer "bash -i -s -- <(automated_bootstrap_environment ${current_target_quoted}) <<< ${script_quoted}"
}


interactive_answer () {
    declare target="$1"
    declare prompt="$2"
    declare default_value="${3:-}"

    declare answer

    declare -a message=("$prompt" "(${target})")
    [[ -z "$default_value" ]] || message+=("[${default_value}]")

    {
        printf '%s: ' "${message[*]}"
        "${AUTOMATED_ANSWER_READ_COMMAND[@]}" answer
        printf '\n'

    } </dev/tty >/dev/tty

    if [[ -n "$default_value" && -z "$answer" ]]; then
        printf '%s\n' "$default_value"
    else
        printf '%s\n' "$answer"
    fi
}


interactive_secret () {
    declare -a AUTOMATED_ANSWER_READ_COMMAND=('read' '-r' '-s')

    interactive_answer "$@"
}


confirm () {
    declare target="$1"
    declare prompt="$2"
    declare default_value="${3:-N}"

    declare answer

    while true; do
        answer=$(set -e; interactive_answer "$target" "${prompt} Y/N?" "$default_value")

        case "$answer" in
            [yY]) return 0
                  ;;
            [nN]) return 1
                  ;;
        esac
    done
}


target_as_vars () {
    declare target="$1"
    declare username_var="${2:-username}"
    declare address_var="${3:-address}"
    declare port_var="${4:-port}"

    declare username address port
    declare -a args=()

    if [[ "$target" =~ ^((.+)@)?(\[([:0-9A-Fa-f]+)\])(:([0-9]+))?$ ]] ||
           [[ "$target" =~ ^((.+)@)?(([-.0-9A-Za-z]+))(:([0-9]+))?$ ]]; then
        printf '%s=%q\n' "$username_var" "${BASH_REMATCH[2]}"
        printf '%s=%q\n' "$address_var" "${BASH_REMATCH[4]}"
        printf '%s=%q\n' "$port_var" "${BASH_REMATCH[6]}"
    else
        return 1
    fi
}


# TODO: AUT-127 IPv6 addresses must be enclosed in square brackets.
target_address_only () {
    declare target="$1"
    declare username address port

    declare var_definitions
    var_definitions=$(set -e; target_as_vars "$target" username address port)

    eval "$var_definitions"

    printf '%s\n' "${address}${port:+:${port}}"
}


target_as_ssh_arguments () {
    declare target="$1"
    declare username address port
    declare -a args=()

    declare var_definitions
    var_definitions=$(set -e; target_as_vars "$target" username address port)

    eval "$var_definitions"

    if [[ -n "$port" ]]; then
        args+=(-p "$port")
    fi

    if [[ -n "$username" ]]; then
        args+=(-l "$username")
    fi

    args+=("$address")

    printf '%s\n' "${args[@]}"
}


is_function () {
    declare name="$1"

    [[ "$(type -t "$name")" = 'function' ]]
}


stdin_as_code () {
    declare dst="${1:-}"

    if [[ -n "$dst" ]]; then
        printf 'base64_decode <<"EOF" | gzip -d >%q\n' "$dst"
    else
        printf 'base64_decode <<"EOF" | gzip -d\n'
    fi
    gzip -n -6 - | base64_encode
    printf 'EOF\n'
}


file_as_code () {
    declare src="$1"
    declare dst="$2"
    declare mode

    if [[ -d "$src" ]]; then
        throw "${src} is a directory. directories are not supported"
    fi

    if ! [[ -e "$src" ]]; then
        throw "${src} does not exist"
    fi

    if [[ -f "$src" ]]; then
        mode=$(set -e; file_mode "$src")
    fi

    stdin_as_code "$dst" <"$src"

    if [[ -f "$src" ]]; then
        printf 'chmod %s %q\n' "$mode" "$dst"
    fi

    printf 'log_debug %q\n' "copied ${src} to ${dst} on the target"
}


stdin_as_function () {
    declare file_id="$1"

    file_id_hash=$(md5 <<< "$file_id")

    printf 'drop_%s_body () {\n' "$file_id_hash"

    stdin_as_code

    printf '}\n'

    printf 'log_debug %q\n' "shipped STDIN as the file id ${file_id}"
}


file_as_function () {
    declare src="$1"
    declare file_id="${2:-${src}}"
    declare mode file_id_hash

    if [[ -d "$src" ]]; then
        throw "${src} is a directory. directories are not supported"
    fi

    if ! [[ -e "$src" ]]; then
        throw "${src} does not exist"
    fi

    file_id_hash=$(md5 <<< "$file_id")

    if [[ -f "$src" ]]; then
        mode=$(set -e; file_mode "$src")
        printf 'AUTOMATED_DROP_%s_MODE=%s\n' "${file_id_hash^^}" "$mode"
    fi

    printf 'drop_%s_body () {\n' "$file_id_hash"

    stdin_as_code <"$src"

    printf '}\n'

    printf 'log_debug %q\n' "shipped ${src} as the file id ${file_id}"
}


declared_var () {
    declare var="$1"

    (
        set -e

        if [[ -n "${2+defined}" ]]; then
            unset "$var"
            declare "${var}=${2}"
        fi

        declare -p "$var"
    )

    declare var_quoted
    var_quoted=$(set -e; quoted "$var")

    printf 'log_debug "declared variable %s"\n' "$var_quoted"
}


declared_function () {
    declare fn="$1"

    declare -f "$fn"

    declare fn_quoted
    fn_quoted=$(set -e; quoted "$fn")

    printf 'log_debug "declared function %s"\n' "$fn_quoted"
}


drop () {
    declare file_id="$1"
    declare dst="${2:-}"

    declare mode owner file_id_hash mode_var

    file_id_hash=$(md5 <<< "$file_id")

    is_function "drop_${file_id_hash}_body" || throw "File id ${file_id} is not dragged"

    if [[ -n "$dst" ]]; then
        mode_var="AUTOMATED_DROP_${file_id_hash^^}_MODE"
        if [[ -n "${!mode_var:-}" ]]; then
            mode="${3:-${!mode_var}}"
        else
            mode="${3:-}"
        fi

        owner="${4:-}"

        # TODO: AUT-128 Support writing to pipes.

        if ! [[ -e "$dst" ]]; then
            touch "$dst"
        fi

        if [[ -n "${mode:-}" ]]; then
            chmod "$mode" "$dst"
        fi

        if [[ -n "${owner:-}" ]]; then
            chown "$owner" "$dst"
        fi

        "drop_${file_id_hash}_body" "${file_id}" | to_file "$dst"
    else
        "drop_${file_id_hash}_body" "$file_id"
    fi
}


sourced_drop () {
    declare file_id="$1"

    declare file_id_hash

    file_id_hash=$(md5 <<< "$file_id")

    declare error_message_quoted log_message_quoted
    error_message_quoted=$(set -e; quoted "File id ${file_id} is not dragged")
    log_message_quoted=$(set -e; quoted "sourced file id ${file_id}")

    cat <<EOF
is_function "drop_${file_id_hash}_body" || throw ${error_message_quoted}
source <(drop_${file_id_hash}_body)
log_debug ${log_message_quoted}
EOF
}


exit_after () {
    declare exit_code="$1"
    shift

    "$@"

    exit "$exit_code"
}


base64_encode () {
    if [[ "$(set -e; local_kernel)" = 'Linux' ]] && cmd_is_available base64; then
        base64 -w 0
    elif cmd_is_available openssl; then
        openssl base64 -A
    else
        python_interpreter -c 'from __future__ import unicode_literals, print_function; import sys; import base64; stdout = sys.stdout.buffer.write if hasattr(sys.stdout, "buffer") else sys.stdout.write; stdin = sys.stdin.buffer.read if hasattr(sys.stdin, "buffer") else sys.stdin.read; list(filter(None, (stdout(base64.b64encode(i)) for i in iter(lambda: stdin(3072), b""))))'
    fi

    printf '\n'
}


base64_decode () {
    if [[ "$(set -e; local_kernel)" = 'Linux' ]] && cmd_is_available base64; then
        base64 -d
    elif cmd_is_available openssl; then
        openssl base64 -d -A
    else
        python_interpreter -c 'from __future__ import unicode_literals, print_function; import sys; import base64; stdout = sys.stdout.buffer.write if hasattr(sys.stdout, "buffer") else sys.stdout.write; stdin = sys.stdin.buffer.read if hasattr(sys.stdin, "buffer") else sys.stdin.read; list(filter(None, (stdout(base64.b64decode(i)) for i in iter(lambda: stdin(3072), b""))))'
    fi
}


python_interpreter () {
    if cmd_is_available python3; then
        python3 "$@"
    else
        python2 "$@"
    fi
}


semver_matches_one_of () {
    declare version_to_match="$1"
    shift

    declare -r SEMVER_RE='^([0-9]+).([0-9]+).([0-9]+)(-([0-9A-Za-z.-]+))?(\+([0-9A-Za-z.-]))?$'
    declare -r VER_RE='^([0-9]+)(.([0-9]+))?(.([0-9]+))?$'

    [[ "$version_to_match" =~ $SEMVER_RE ]] || return 1

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
    declare major="$1"
    declare minor="$2"

    ! [[ "${BASH_VERSINFO[0]}" -lt "$major" ]] || return 1

    ! [[ "${BASH_VERSINFO[0]}" -eq "$major" && "${BASH_VERSINFO[1]}" -lt "$minor" ]] || return 1
}


supported_automated_versions () {
    if ! semver_matches_one_of "$AUTOMATED_VERSION" "$@"; then
        declare supported_versions
        supported_versions=$(set -e; joined ', ' "$@")

        throw "Unsupported version ${AUTOMATED_VERSION} of Automated detected. Supported versions are: ${supported_versions}"
    fi
}


automated_bootstrap_environment () {
    declare target="$1"

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

    # shellcheck disable=SC2064
    automated_environment_script "$target" | file_as_function /dev/stdin '__automated_environment'
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
