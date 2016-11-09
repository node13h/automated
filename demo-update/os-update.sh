all () {
    case "${FACT_OS_NAME}" in
        "Fedora")
            run_in_multiplexer "dnf -y update; exit"
            ;;
        "RHEL"|"CentOS")
            run_in_multiplexer "yum -y update; exit"
            ;;
        "Debian"|"Ubuntu")
            run_in_multiplexer "apt-get -y update && apt-get -y dist-upgrade; exit"
            ;;
    esac
}
