#!/usr/bin/env bash

# MIT license
# Copyright 2021 Sergej Alikov <sergej@alikov.com>

set -euo pipefail

ACTION="$1"
STATE_FILE="$2"
shift 2

start () {
    declare deployment_id="$1"
    declare image="$2"
    declare ssh_port="$3"
    declare ssh_command="$4"

    if [[ -s "$STATE_FILE" ]]; then
        printf 'State file %s already exists\n' "$STATE_FILE" >&2
        return 1
    fi

    if ! podman image exists "$image"; then
        printf 'Image %s was not found. SSHD target images can be built by running "make images" in the e2e directory\n' "$image" >&2
        return 1
    fi

    declare pod
    pod=$(podman pod create --name "${deployment_id}-services" \
                 -p "${ssh_port}:22")
    cat <<EOF >>"$STATE_FILE"
POD=${pod}
EOF

    podman pod start "$pod"

    podman run --pod "$pod" -d --name "${deployment_id}-sshd" "$image"
    cat <<EOF >>"$STATE_FILE"
SSHD_ADDRESS=localhost
SSHD_PORT=${ssh_port}
EOF

    printf 'Waiting for the sshd service to start ' >&2
    until
        "$ssh_command" localhost -p "$ssh_port" -- true >/dev/null 2>&1
    do
        printf '.' >&2
        sleep 1
    done
    printf ' done.\n' >&2

    cat <<EOF >>"$STATE_FILE"
DEPLOYMENT_ID=${deployment_id}
EOF

}

stop () {
    if ! [[ -e "$STATE_FILE" ]]; then
        return 0
    fi

    # shellcheck disable=SC1090
    source "$STATE_FILE"

    if [[ -v POD ]] && podman pod exists "$POD"; then
        podman pod rm -f "$POD"
    fi

    rm -f -- "$STATE_FILE"
}


case "$ACTION" in
    start)
        start "$@"
        ;;
    stop)
        stop "$@"
        ;;
esac
