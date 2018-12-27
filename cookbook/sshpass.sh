#!/usr/bin/env bash

# MIT license

# Copyright (c) 2018 Sergej Alikov <sergej.alikov@gmail.com>

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

get_ssh_password () {
    # target format is [user@]address[:port], passed as-is from automated
    declare target="$1"

    declare -a ssh_args
    declare -A secrets_db=()

    secrets_db['user1@host1:22']='secret1'
    secrets_db['user2@host2:22']='secret2'

    mapfile -t ssh_args < <(target_as_ssh_arguments "${target}")

    # Resolve the actual user/host/port values using ssh -G
    # shellcheck disable=SC1090
    source <(ssh -T -G "${ssh_args[@]}" | grep -E '(^user|^hostname|^port)\s' | sed -e 's/\s\+/=/' -e 's/^/declare /')

    printf '%s\n' "${secrets_db["${user}@${hostname}:${port}"]}"
}

# Make the get_ssh_password function available to the child shells
export -f get_ssh_password

# shellcheck disable=SC2016
automated.sh \
    --ssh-command 'sshpass -f<(get_ssh_password "$target") ssh' \
    -c 'echo "Hello World!"' \
    --verbose \
    user1@host1 user2@host2
