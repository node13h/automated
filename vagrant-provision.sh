#/usr/bin/env bash

set -euo pipefail

declare -A hosts

hosts[fedora.test]=192.168.50.2
hosts[centos.test]=192.168.50.3
hosts[ubuntu.test]=192.168.50.4
hosts[freebsd.test]=192.168.50.5

if grep -q CentOS /etc/redhat-release; then
    yum -y install wget
fi

if [[ -f /etc/debian_version ]]; then
    apt-get install make
fi

if [[ "$(firewall-cmd --state)" = 'running' ]]; then
    firewall-cmd --add-port=8080/tcp
    firewall-cmd --runtime-to-permanent
fi

for host in "${!hosts[@]}"; do
    printf '%s %s\n' "${hosts[$host]}" "$host" >>/etc/hosts
done

case "$(uname -s)" in
    FreeBSD)
        pw addgroup user
        printf 'secret\n' | pw adduser -q -d /home/user -s /bin/bash -n user -g user -h 0
        sudoersd_path=/usr/local/etc/sudoers.d
        ;;
    Linux)
        useradd -d /home/user -s /bin/bash user
        printf 'user:secret\n' | chpasswd
        sudoersd_path=/etc/sudoers.d
        ;;
    *)
        prinf 'Unsupported operating system'
        exit 1
        ;;
esac
mkdir -p /home/user/.ssh
chown -R user:user /home/user
chmod 0700 /home/user/.ssh
sudo -u user ssh-keygen -N '' -f /home/user/.ssh/id_rsa

cat <<"EOF" >"${sudoersd_path%/}/user"
user ALL=(ALL:ALL) ALL
EOF

mkdir -p /srv/http
cp /home/user/.ssh/id_rsa.pub /srv/http/

(
    cd /srv/http
    if command -v python3; then
        python3 -m http.server 8080 &>/var/log/http.log &
    else
        python2 -m SimpleHTTPServer 8080 &>/var/log/http.log &
    fi
)

cat <<"EOF" >/usr/local/bin/pull-keys.sh
#/usr/bin/env bash

set -euo pipefail

dir=$(mktemp -d)

for host in "$@"; do
  until wget "http://${host}:8080/id_rsa.pub" -O "${dir%/}/${host}.pub"; do
    sleep 1
  done
done

cat "${dir%/}/"* >>/home/user/.ssh/authorized_keys
EOF

bash /usr/local/bin/pull-keys.sh "${!hosts[@]}" &>/var/log/pull-keys.log &

(
    cd /tmp/code
    make PREFIX=/usr install
)
