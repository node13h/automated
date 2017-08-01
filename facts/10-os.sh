#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034

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

declare pkg ver

FACT_SYSTEMD=FALSE


if cmd_is_available systemctl; then
    if systemctl --quiet is-active -- '-.mount'; then
        FACT_SYSTEMD=TRUE
    fi
fi

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
             printf 'FACT_OS_NAME=%s\n' "${NAME}"
             printf 'FACT_OS_VERSION=%s\n' "${VERSION_ID}"
             printf 'FACT_OS_RELEASE=%s\n' "${VERSION}")

else
    FACT_US_FAMILY='Unsupported'
fi
