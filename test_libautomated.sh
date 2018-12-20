#!/usr/bin/env bash

# Copyright (C) 2018 Sergej Alikov <sergej.alikov@gmail.com>

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

__DOC__='
Unit-test libautomated.sh
This script uses shelter.sh as the testing framework. Please see
https://github.com/node13h/shelter for more information'

set -euo pipefail

PROG_DIR=$(dirname "${BASH_SOURCE[0]:-}")

# shellcheck disable=SC1091
source shelter.sh

# shellcheck disable=SC1090
source "${PROG_DIR%/}/libautomated.sh"


test_file_as_function_file () {
    declare temp_file temp_file_quoted owner mode
    temp_file=$(mktemp)

    set +e
    (
        set -e
        cat <<EOF >"$temp_file"
Hello
World
EOF
        owner=$(stat -c '%U:%G' "$temp_file")
        mode=$(stat -c '%#03a' "$temp_file")
        temp_file_quoted=$(printf '%q' "$temp_file")

        assert_stdout "file_as_function ${temp_file_quoted} my-file-id" - <<EOF
drop_85f3735d27bcffbd74d4d5b092e52da0_body () {
    base64_decode <<"EOF-85f3735d27bcffbd74d4d5b092e52da0" | gzip -d
H4sIAAAAAAAAA/NIzcnJ5wrPL8pJ4QIAMYNY2wwAAAA=
EOF-85f3735d27bcffbd74d4d5b092e52da0
}

drop_85f3735d27bcffbd74d4d5b092e52da0_mode () {
    printf '%s\n' '${mode}'
}

drop_85f3735d27bcffbd74d4d5b092e52da0_owner () {
    printf '%s\n' '${owner}'
}
EOF
    )
    set -e

    rm -f -- "$temp_file"
}

test_file_as_function_pipe () {
    declare owner mode

    {
        owner=$(stat -c '%U:%G' '/dev/fd/0')
        mode=$(stat -c '%#03a' '/dev/fd/0')

        assert_stdout "file_as_function /dev/fd/0 my-file-id" <(cat <<EOF
drop_85f3735d27bcffbd74d4d5b092e52da0_body () {
    base64_decode <<"EOF-85f3735d27bcffbd74d4d5b092e52da0" | gzip -d
H4sIAAAAAAAAA/NIzcnJ5wrPL8pJ4QIAMYNY2wwAAAA=
EOF-85f3735d27bcffbd74d4d5b092e52da0
}

drop_85f3735d27bcffbd74d4d5b092e52da0_mode () {
    printf '%s\n' '${mode}'
}

drop_85f3735d27bcffbd74d4d5b092e52da0_owner () {
    printf '%s\n' '${owner}'
}
EOF
)
    } <<EOF
Hello
World
EOF
}

test_file_as_function_dir_fail () {
    declare temp_dir
    temp_dir=$(mktemp -d)
    temp_dir_quoted=$(printf '%q' "$temp_dir")

    set +e
    (
        set -e
        assert_fail "file_as_function ${temp_dir_quoted} my-file-id 2>/dev/null"
    )
    set -e

    rmdir -- "$temp_dir"
}

test_drop_stdout () {
    (
        drop_85f3735d27bcffbd74d4d5b092e52da0_body () {
            base64_decode <<"EOF-85f3735d27bcffbd74d4d5b092e52da0" | gzip -d
H4sIAAAAAAAAA/NIzcnJ5wrPL8pJ4QIAMYNY2wwAAAA=
EOF-85f3735d27bcffbd74d4d5b092e52da0
        }

        drop_85f3735d27bcffbd74d4d5b092e52da0_mode () {
            printf '%s\n' '0750'
        }

        drop_85f3735d27bcffbd74d4d5b092e52da0_owner () {
            printf '%s\n' 'root:root'
        }

        assert_stdout "drop my-file-id" - <<"EOF"
Hello
World
EOF
    )
}

test_drop_file () {
    declare temp_dir dst_quoted
    temp_dir=$(mktemp -d)
    dst_quoted=$(printf '%q' "${temp_dir%/}/dst")

    set +e
    (
        set -e

        drop_85f3735d27bcffbd74d4d5b092e52da0_body () {
            base64_decode <<"EOF-85f3735d27bcffbd74d4d5b092e52da0" | gzip -d
H4sIAAAAAAAAA/NIzcnJ5wrPL8pJ4QIAMYNY2wwAAAA=
EOF-85f3735d27bcffbd74d4d5b092e52da0
        }

        drop_85f3735d27bcffbd74d4d5b092e52da0_mode () {
            printf '%s\n' '0750'
        }

        drop_85f3735d27bcffbd74d4d5b092e52da0_owner () {
            printf '%s\n' 'root:root'
        }

        assert_success "drop my-file-id ${dst_quoted}"
        assert_stdout "cat ${dst_quoted}" <<"EOF"
Hello
World
EOF
        assert_stdout "stat -c '%#03a' ${dst_quoted}" <<< '0750'

    )
    set -e
    rm -f -- "${temp_dir%/}/dst"
    rmdir -- "$temp_dir"
}

test_drop_fail () {
    assert_fail "drop my-file-id 2>/dev/null"
}

test_file_as_code_file () {
    declare temp_file temp_file_quoted mode
    temp_file=$(mktemp)

    set +e
    (
        set -e
        cat <<EOF >"$temp_file"
Hello
World
EOF
        mode=$(stat -c '%#03a' "$temp_file")
        temp_file_quoted=$(printf '%q' "$temp_file")

        assert_stdout "file_as_code ${temp_file_quoted} /tmp/dst" - <<EOF
touch /tmp/dst
chmod 0600 /tmp/dst
base64_decode <<"EOF-d075c6918aed70a32aaebbd10eb9ecab" | gzip -d >/tmp/dst
chmod ${mode} /tmp/dst
H4sIAAAAAAAAA/NIzcnJ5wrPL8pJ4QIAMYNY2wwAAAA=
EOF-d075c6918aed70a32aaebbd10eb9ecab
EOF
    )
    set -e

    rm -f -- "$temp_file"
}

test_file_code_pipe () {
    declare mode

    {
        mode=$(stat -c '%#03a' '/dev/fd/0')

        assert_stdout "file_as_function /dev/fd/0 my-file-id" <(cat <<EOF
touch /tmp/dst
chmod 0600 /tmp/dst
base64_decode <<"EOF-d075c6918aed70a32aaebbd10eb9ecab" | gzip -d >/tmp/dst
chmod ${mode} /tmp/dst
H4sIAAAAAAAAA/NIzcnJ5wrPL8pJ4QIAMYNY2wwAAAA=
EOF-d075c6918aed70a32aaebbd10eb9ecab
EOF
)
    } <<EOF
Hello
World
EOF
}

test_is_function_true () {
    (
        my_test_function_name () {
            true
        }

        assert_success 'is_function my_test_function_name'
    )
}

test_is_function_false () {
    (
        assert_fail 'is_function my_test_function_name'
    )
}

suite () {
    shelter_run_test_class upload test_file_as_function_
    shelter_run_test_class upload test_drop_
    shelter_run_test_class upload test_file_as_code_
    shelter_run_test_class utility test_is_function_
}

usage () {
    cat <<EOF
Usage: ${0} [--help]
${__DOC__}

ENVIRONMENT VARIABLES:
  ENABLE_CI_MODE    set to non-empty value to enable the Junit XML
                    output mode

EOF
}


main () {
    if [[ "${1:-}" = '--help' ]]; then
        usage
        return 0
    fi

    if [[ -n "${ENABLE_CI_MODE:-}" ]]; then
        mkdir -p junit
        shelter_run_test_suite suite | shelter_junit_formatter >junit/test_libautomated.xml
    else
        shelter_run_test_suite suite | shelter_human_formatter
    fi
}


if [[ -n "${BASH_SOURCE[0]:-}" && "${0}" = "${BASH_SOURCE[0]}" ]]; then
    main "$@"
fi
