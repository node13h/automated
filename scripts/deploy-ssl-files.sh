#!/usr/bin/env bash

set -eu
set -o pipefail

# We expect the caller to export the correct values
# of the following variables
CA_NAME="${CA_NAME:-default}"

PASS_NAMESPACE="${PASS_NAMESPACE:-CA/${CA_NAME}}"
PKI_DIR="${PKI_DIR:-${HOME}/CA/${CA_NAME}/pki}"
PKI_KEYS_DIR="${PKI_KEYS_DIR:-${PKI_DIR%/}/private}"
PKI_CERTS_DIR="${PKI_CERTS_DIR:-${PKI_DIR%/}/issued}"

# Use automated.sh as a library
# shellcheck disable=SC1090
source "$(which automated.sh)"


usage () {
    cat <<EOF
Generates code to transport SSL files to the remote node.
Intended to be used as an argument to the automated.sh --macro

Usage ${0} TARGET

If you need to make more complex decisions based on the
target - base your own script on this one then
EOF
}

print_usage_and_exit () {
    usage
    exit "${1:-0}"
}

decrypted_key () {
    local key_file="${1}"
    local passphrase="${2}"

    openssl rsa -passin stdin -in "${key_file}" <<< "${passphrase}"
}

ssl_facts () {
    cat <<"EOF"
case "${FACT_OS_FAMILY}" in
     RedHat)
        FACT_PKI_CERTS=/etc/pki/tls/certs
        FACT_PKI_KEYS=/etc/pki/tls/private
        ;;
     Debian)
        FACT_PKI_CERTS=/etc/ssl/certs
        FACT_PKI_KEYS=/etc/ssl/private
        ;;
esac
EOF
}

main () {
    local target="${1}"

    local cacert cert key pass_name
    local dest_cacert_name dest_cert_name dest_key_name
    local passphrase

    cacert="${PKI_DIR%/}/ca.crt"
    dest_cacert_name="${CA_NAME}.crt"
    cert="${PKI_CERTS_DIR%/}/${target}.crt"
    dest_cert_name="${target}.crt"
    key="${PKI_KEYS_DIR%/}/${target}.key"
    dest_key_name="${target}.key"
    pass_name="${PASS_NAMESPACE%/}/${target}"

    passphrase=$(pass "${pass_name}")

    ssl_facts

    file_as_function <(decrypted_key "${key}" "${passphrase}") ssl-key
    file_as_function "${cert}" ssl-cert
    file_as_function "${cacert}" ssl-cacert

    cat <<EOF
drop ssl-key "\${FACT_PKI_KEYS%/}/${dest_key_name}"
drop ssl-cert "\${FACT_PKI_CERTS%/}/${dest_cert_name}"
drop ssl-cacert "\${FACT_PKI_CERTS%/}/${dest_cacert_name}"
EOF
}


[[ "${#}" -eq 1 ]] || print_usage_and_exit 1

main "${@}"

