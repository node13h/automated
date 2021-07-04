FROM docker.io/fedora:34

RUN dnf -y install make openssh-clients expect && dnf clean all && rm -rf /var/cache/yum

COPY . /dist

WORKDIR /dist

RUN make install

ENTRYPOINT ["/usr/local/bin/automated.sh"]
