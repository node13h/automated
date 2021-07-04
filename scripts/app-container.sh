#!/usr/bin/env bash

# MIT license
# Copyright 2021 Sergej Alikov <sergej@alikov.com>

set -euo pipefail

ACTION="$1"
STATE_FILE="$2"
shift 2

start () {
    declare deployment_id="$1"
    declare e2e_dir="$2"

    if [[ -s "$STATE_FILE" ]]; then
        printf 'State file %s already exists\n' "$STATE_FILE" >&2
        return 1
    fi

    declare app_image
    app_image=$(podman build -q .)

    declare app_container
    app_container=$(
        podman create -it --rm \
               --network host \
               --name "${deployment_id}-app" \
               --entrypoint bash \
               -e PATH=/e2e:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
               "$app_image")
    cat <<EOF >>"$STATE_FILE"
APP_CONTAINER=${app_container}
EOF
    podman cp "$e2e_dir" "${app_container}:/e2e"

    podman start "$app_container"

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

    if [[ -v APP_CONTAINER ]]; then
        podman stop -i "$APP_CONTAINER"
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
