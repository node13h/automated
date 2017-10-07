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

SUPPORTED_MULTIPLEXERS=(tmux)


enable_epel () {
    if ! [[ -e /etc/yum.repos.d/epel.repo ]]; then
        cmd yum localinstall -y "https://dl.fedoraproject.org/pub/epel/epel-release-latest-${FACT_OS_VERSION}.noarch.rpm"
    fi
}

user_exists () {
    local username="${1}"

    getent passwd "${username}" >/dev/null
}

group_exists () {
    local groupname="${1}"

    getent group "${groupname}" >/dev/null
}

homedir () {
    local username="${1}"

    getent passwd "${username}" | cut -d ':' -f 6
}

quoted_for_systemd () {
    local arg
    local -a result=()

    for arg in "${@}"; do
        # shellcheck disable=SC1003
        result+=("\"$(translated "${arg}" '\' '\\' '"' '\"')\"")
    done

    printf '%s\n' "${result[*]}"
}

packages_ensure () {
    local command="${1}"
    shift

    case "${FACT_OS_FAMILY}-${command}" in
        'RedHat-present')
            cmd yum -y install "${@}"
            ;;
        'RedHat-absent')
            cmd yum -y remove "${@}"
            ;;
        'Debian-present')
            cmd apt-get -y install "${@}"
            ;;
        'Debian-absent')
            cmd apt-get -y remove "${@}"
            ;;
        *)
            throw "Command ${command} is unsupported on ${FACT_OS_FAMILY}"
            ;;
    esac
}

service_ensure () {
    local command="${1}"
    local service="${2}"

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
                throw "Command ${command} is unsupported on ${FACT_OS_FAMILY}"
                ;;
        esac
    fi
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

multiplexer_ensure_installed () {
    if ! multiplexer_present >/dev/null; then
        packages_ensure installed "${SUPPORTED_MULTIPLEXERS[0]}"  # Install first one
    fi
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
                exit "${EXIT_MULTIPLEXER_ALREADY_RUNNING}"
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
