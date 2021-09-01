#!/usr/bin/env bash

# MIT license
# Copyright 2021 Sergej Alikov <sergej@alikov.com>

set -euo pipefail

ACTION="$1"
STATE_FILE="$2"
shift 2

start () {
    declare deployment_id="$1"
    declare os="$2"
    declare context_dir="$3"
    declare local_ssh_port="$4"

    if [[ -s "$STATE_FILE" ]]; then
        printf 'State file %s already exists\n' "$STATE_FILE" >&2
        return 1
    fi

    cat <<EOF >>"$STATE_FILE"
SSHD_STACK_MODE=container
EOF

    declare dockerfile="${context_dir%/}/Dockerfile.sshd.${os}"

    if ! [[ -f "$dockerfile" ]]; then
        printf '%s OS is unsupported\n' "$os" >&2
        return 1
    fi

    declare testuser_hash
    testuser_hash=$(openssl passwd -6 -stdin <"${context_dir%/}/sshd_target_testuser_password")

    printf 'Building a container image using %s\n' "$dockerfile" >&2
    declare sshd_image
    sshd_image=$(podman build -q --build-arg TESTUSER_HASH="$testuser_hash" -f "$dockerfile" -t "${deployment_id}-sshd-${os}" "$context_dir")

    declare pod
    pod=$(podman pod create --name "${deployment_id}-services" \
                 -p "${local_ssh_port}:22")
    cat <<EOF >>"$STATE_FILE"
SSHD_POD=${pod}
EOF

    podman pod start "$pod"

    podman run --pod "$pod" -d --name "${deployment_id}-sshd" "$sshd_image"

    declare sudo_password
    sudo_password=$(cat "${context_dir%/}/sshd_target_testuser_password")

    cat <<EOF >>"$STATE_FILE"
SSHD_ADDRESS=localhost
SSHD_PORT=${local_ssh_port}
SSHD_SUDO_PASSWORD=$(printf '%q\n' "$sudo_password")
EOF

    printf 'Waiting for the sshd service to start ' >&2
    until
        "${context_dir%/}/ssh" localhost -p "$local_ssh_port" -- true >/dev/null 2>&1
    do
        printf '.' >&2
        sleep 1
    done
    printf ' done.\n' >&2

    cat <<EOF >>"$STATE_FILE"
SSHD_DEPLOYMENT_ID=${deployment_id}
EOF

}

stop () {
    if ! [[ -e "$STATE_FILE" ]]; then
        return 0
    fi

    # shellcheck disable=SC1090
    source "$STATE_FILE"

    if ! [[ "$SSHD_STACK_MODE" == 'container' ]]; then
        printf 'Currently deployed sshd target stack mode (%s) is not "container"\n' "$SSHD_STACK_MODE" >&2
        return 1
    fi

    if [[ -v SSHD_POD ]] && podman pod exists "$SSHD_POD"; then
        podman pod rm -f "$SSHD_POD"
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
