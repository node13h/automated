#!/usr/bin/env bash
# shellcheck disable=SC2034

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
