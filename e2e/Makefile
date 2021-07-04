VERSION := 1.0.0

FEDORA34_IMAGE := automated-test-sshd-fedora34
CENTOS7_IMAGE := automated-test-sshd-centos7
CENTOS8_IMAGE := automated-test-sshd-centos8
UBUNTU2104_IMAGE := automated-test-sshd-ubuntu2104

.PHONY: images image-fedora34 image-centos7 image-centos8 image-ubuntu2104

image-fedora34: keys
	podman build --build-arg TESTUSER_HASH="$$(openssl passwd -6 -stdin <testuser_password)" -t $(FEDORA34_IMAGE):$(VERSION) -f Dockerfile.sshd.fedora34 .

image-centos7: keys
	podman build --build-arg TESTUSER_HASH="$$(openssl passwd -6 -stdin <testuser_password)" -t $(CENTOS7_IMAGE):$(VERSION) -f Dockerfile.sshd.centos7 .

image-centos8: keys
	podman build --build-arg TESTUSER_HASH="$$(openssl passwd -6 -stdin <testuser_password)" -t $(CENTOS8_IMAGE):$(VERSION) -f Dockerfile.sshd.centos8 .

image-ubuntu2104: keys
	podman build --build-arg TESTUSER_HASH="$$(openssl passwd -6 -stdin <testuser_password)" -t $(UBUNTU2104_IMAGE):$(VERSION) -f Dockerfile.sshd.ubuntu2104 .

images: image-fedora34 image-centos7 image-centos8 image-ubuntu2104

.PHONY: keys

ssh_host_%_key:
	ssh-keygen -q -t $* -f $@ -C '' -N ''

ssh_host_%_key.pub: ssh_host_%_key

id_rsa:
	ssh-keygen -q -t rsa -f id_rsa -C '' -N ''

id_rsa.pub: id_rsa

testuser_password:
	openssl rand -hex 16 >testuser_password

keys: id_rsa ssh_host_ecdsa_key ssh_host_ed25519_key ssh_host_rsa_key testuser_password


.PHONY: clean

clean:
	-podman image rm $(FEDORA34_IMAGE) $(CENTOS7_IMAGE) $(CENTOS8_IMAGE) $(UBUNTU2104_IMAGE)
	rm -f id_rsa id_rsa.pub ssh_host_ecdsa_key ssh_host_ecdsa_key.pub ssh_host_ed25519_key ssh_host_ed25519_key.pub ssh_host_rsa_key ssh_host_rsa_key.pub testuser_password
