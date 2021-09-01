#!/usr/bin/env bash

# MIT license
# Copyright 2021 Sergej Alikov <sergej@alikov.com>

set -euo pipefail

ACTION="$1"
STATE_FILE="$2"
shift 2

start () {
    declare deployment_id="$1"
    declare context_dir="$2"

    if [[ -s "$STATE_FILE" ]]; then
        printf 'State file %s already exists\n' "$STATE_FILE" >&2
        return 1
    fi

    cat <<EOF >>"$STATE_FILE"
APP_ENV_STACK_MODE=container
EOF

    printf 'Building the app container image\n' >&2
    declare app_image
    app_image=$(podman build -q .)

    declare app_container
    app_container=$(
        podman create -it --rm \
               --network host \
               --name "${deployment_id}-app-env" \
               --entrypoint bash \
               -e PATH=/e2e:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
               "$app_image")
    cat <<EOF >>"$STATE_FILE"
APP_ENV_CONTAINER=${app_container}
EOF
    podman cp "$context_dir" "${app_container}:/e2e"

    podman start "$app_container"

    declare testuser_hash
    testuser_hash=$(openssl passwd -6 -stdin <"${context_dir%/}/app_env_testuser_password")

    podman exec "$app_container" useradd -u 1001 -d /home/testuser -G wheel -p "$testuser_hash" testuser
    podman exec "$app_container" chown -R testuser:testuser /e2e

    declare sudo_password
    sudo_password=$(cat "${context_dir%/}/app_env_testuser_password")

    cat <<EOF >>"$STATE_FILE"
APP_ENV_SUDO_PASSWORD=$(printf '%q\n' "$sudo_password")
APP_ENV_DEPLOYMENT_ID=${deployment_id}
EOF

}

stop () {
    if ! [[ -e "$STATE_FILE" ]]; then
        return 0
    fi

    # shellcheck disable=SC1090
    source "$STATE_FILE"

    if ! [[ "$APP_ENV_STACK_MODE" == 'container' ]]; then
        printf 'Currently deployed app environment stack mode (%s) is not "container"\n' "$APP_ENV_STACK_MODE" >&2
        return 1
    fi

    if [[ -v APP_ENV_CONTAINER ]]; then
        podman stop -i "$APP_ENV_CONTAINER"
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
