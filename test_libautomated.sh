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
    declare rc temp_file temp_file_quoted owner mode
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
msg_debug shipped\ ${temp_file_quoted}\ as\ the\ file\ id\ my-file-id
EOF
    )
    rc="$?"
    set -e

    rm -f -- "$temp_file"

    return "$rc"
}

test_file_as_function_id_defaults_to_path () {
    declare rc temp_file temp_file_quoted name_md5 owner mode
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
        name_md5=$(md5sum -b - <<< "$temp_file" | cut -f 1 -d ' ')

        assert_stdout "file_as_function ${temp_file_quoted}" - <<EOF
drop_${name_md5}_body () {
    base64_decode <<"EOF-${name_md5}" | gzip -d
H4sIAAAAAAAAA/NIzcnJ5wrPL8pJ4QIAMYNY2wwAAAA=
EOF-${name_md5}
}

drop_${name_md5}_mode () {
    printf '%s\n' '${mode}'
}

drop_${name_md5}_owner () {
    printf '%s\n' '${owner}'
}
msg_debug shipped\ ${temp_file_quoted}\ as\ the\ file\ id\ ${temp_file_quoted}
EOF
    )
    rc="$?"
    set -e

    rm -f -- "$temp_file"

    return "$rc"
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
msg_debug shipped\ /dev/fd/0\ as\ the\ file\ id\ my-file-id
EOF
)
    } <<EOF
Hello
World
EOF
}

test_file_as_function_dir_fail () {
    declare rc temp_dir
    temp_dir=$(mktemp -d)

    set +e
    (
        set -e

        temp_dir_quoted=$(printf '%q' "$temp_dir")

        assert_fail "file_as_function ${temp_dir_quoted} my-file-id >/dev/null"
        assert_stdout "file_as_function ${temp_dir_quoted} my-file-id" - <<EOF
throw ${temp_dir_quoted}\ is\ a\ directory.\ directories\ are\ not\ supported
EOF
    )
    rc="$?"
    set -e

    rmdir -- "$temp_dir"

    return "$rc"
}

test_file_as_function_unreadable () {
    assert_fail "file_as_function /non/existing/file my-file-id >/dev/null"
        assert_stdout "file_as_function /non/existing/file my-file-id" - <<EOF
throw /non/existing/file\ was\ not\ readable\ at\ the\ moment\ of\ the\ shipping\ attempt
EOF
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
    declare rc temp_dir dst_quoted
    temp_dir=$(mktemp -d)

    set +e
    (
        set -e

        dst_quoted=$(printf '%q' "${temp_dir%/}/dst")

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
    rc="$?"
    set -e

    rm -f -- "${temp_dir%/}/dst"
    rmdir -- "$temp_dir"

    return "$rc"
}

test_drop_fail () {
    assert_fail "drop my-file-id 2>/dev/null"
}

test_file_as_code_file () {
    declare rc temp_file temp_file_quoted mode
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

msg_debug copied\ ${temp_file_quoted}\ to\ /tmp/dst\ on\ the\ target
EOF
    )
    rc="$?"
    set -e

    rm -f -- "$temp_file"

    return "$rc"
}

test_file_as_code_pipe () {
    declare mode

    {
        mode=$(stat -c '%#03a' '/dev/fd/0')

        assert_stdout "file_as_code /dev/fd/0 /tmp/dst" <(cat <<EOF
touch /tmp/dst
chmod 0600 /tmp/dst
base64_decode <<"EOF-d075c6918aed70a32aaebbd10eb9ecab" | gzip -d >/tmp/dst
chmod ${mode} /tmp/dst
H4sIAAAAAAAAA/NIzcnJ5wrPL8pJ4QIAMYNY2wwAAAA=
EOF-d075c6918aed70a32aaebbd10eb9ecab

msg_debug copied\ /dev/fd/0\ to\ /tmp/dst\ on\ the\ target
EOF
)
    } <<EOF
Hello
World
EOF
}

test_file_as_code_dir_fail () {
    declare rc temp_dir
    temp_dir=$(mktemp -d)

    set +e
    (
        set -e

        temp_dir_quoted=$(printf '%q' "$temp_dir")

        assert_fail "file_as_code ${temp_dir_quoted} /tmp/dst >/dev/null"
        assert_stdout "file_as_code ${temp_dir_quoted} /tmp/dst" - <<EOF
throw ${temp_dir_quoted}\ is\ a\ directory.\ directories\ are\ not\ supported
EOF
    )
    rc="$?"
    set -e

    rmdir -- "$temp_dir"

    return "$rc"
}

test_file_as_code_unreadable () {
    assert_fail "file_as_code /non/existing/file /tmp/dst >/dev/null"
    assert_stdout "file_as_code /non/existing/file /tmp/dst" - <<EOF
throw /non/existing/file\ was\ not\ readable\ at\ the\ moment\ of\ the\ shipping\ attempt
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

test_sourced_drop_correct () {
    assert_stdout 'sourced_drop my-file-id' - <<"EOF"
is_function "drop_85f3735d27bcffbd74d4d5b092e52da0_body" || throw File\ id\ my-file-id\ is\ not\ dragged
source <(drop_85f3735d27bcffbd74d4d5b092e52da0_body)
msg_debug sourced\ file\ id\ my-file-id
EOF
}

test_bootstrap_environment_correct () {
    (
        environment_script () {
            cat <<EOF
echo "environment for ${1}"
EOF
        }

        assert_stdout 'source <(bootstrap_environment my-target)' - <<"EOF"
environment for my-target
EOF
    )
}

test_bootstrap_environment_includes_environment_script () {
    (
        environment_script () {
            cat <<EOF
echo "environment for ${1}"
EOF
        }

        assert_stdout 'source <(bootstrap_environment my-target); environment_script' - <<"EOF"
environment for my-target
echo "environment for my-target"
EOF
    )
}

test_semver_matches_one_of_major_minor_patch_match () {
    assert_success 'semver_matches_one_of 1.2.3 0 1.2.3 2 3'
}

test_semver_matches_one_of_major_minor_match () {
    assert_success 'semver_matches_one_of 1.2.3 0 1.2 2 3'
}

test_semver_matches_one_of_major_match () {
    assert_success 'semver_matches_one_of 1.2.3 0 1 2 3'
}

test_semver_matches_one_of_no_match () {
    assert_fail 'semver_matches_one_of 1.2.3 0 1.2.4 2 3'
}

test_supported_automated_versions_major_minor_patch_match () {
    assert_success 'AUTOMATED_VERSION=1.2.3 supported_automated_versions 0 1.2.3 2 3'
}

test_supported_automated_versions_major_minor_match () {
    assert_success 'AUTOMATED_VERSION=1.2.3 supported_automated_versions 0 1.2 2 3'
}

test_supported_automated_versions_major_match () {
    assert_success 'AUTOMATED_VERSION=1.2.3 supported_automated_versions 0 1 2 3'
}

test_supported_automated_versions_no_match () {
    assert_fail 'AUTOMATED_VERSION=1.2.3 supported_automated_versions 0 1.2.4 2 3 2>/dev/null'
}

test_joined_single () {
    assert_stdout 'joined ", " one' - <<EOF
one
EOF
}

test_joined_multiple () {
    assert_stdout 'joined ", " one two three' - <<EOF
one, two, three
EOF
}

test_joined_none () {
    assert_success 'joined ","'
    assert_stdout 'joined ","' <(true)
}


suite () {
    shelter_run_test_class upload test_file_as_function_
    shelter_run_test_class upload test_drop_
    shelter_run_test_class upload test_file_as_code_
    shelter_run_test_class upload test_sourced_drop_
    shelter_run_test_class utility test_is_function_
    shelter_run_test_class utility test_bootstrap_environment_
    shelter_run_test_class utility test_semver_matches_one_of_
    shelter_run_test_class utility test_supported_automated_versions_
    shelter_run_test_class utility test_joined_
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

    supported_shelter_versions 0.6 0.7

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
