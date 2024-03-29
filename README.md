# automated - Run commands remotely

This automation framework will enable you to run commands (including locally defined Bash functions) remotely.

![Demo](demo.gif)


## Features
- **SUDO support**

  Use the `-s` argument to run a command on remote targets as SUDO root.

- **Simple, yet powerful API**

  Commands running via automated.sh have access to all functions defined in [libautomated.sh](libautomated.sh).

- **Running functions from local libraries remotely**

  Load any number of extra files with the `-l` argument.

- **STDIN, STDOUT and STDERR are transparently attached to the remotely running command**

  Yes, you can do this:

  ```bash
  # Save ping output both on target.example.com and local controlling workstation
  ping -c10 www.google.com | automated.sh -s --stdin -c 'tee /tmp/test.txt' target.example.com | tee /tmp/test.txt
  ```
  and this:

  ```bash
  echo "I have travelled over the remote target back to the STDOUT on the controlling workstation" | automated.sh --stdin -c 'echo "Look, I am on STDERR" >&2; cat' target.example.com
  ```

- **Exit code of the remote command is retained**

  The following will output `5`:

  ```bash
  automated.sh -c 'exit 5' target.example.com; echo $?
  ```

- **Macro support**

  You can use macros to run dynamically generated code. Commands specified with the `-m` argument are evaluated locally and the output is executed remotely. The following is an example for unlocking the remote encrypted LUKS volumes on multiple remote machines using individual passwords for every target from local [pass](https://www.passwordstore.org/) store:

  ```bash
  automated.sh -m 'printf "%s\n" "PASSPHRASE=$(pass "LUKS/${target}")"' -c 'cryptsetup luksOpen --key-file <(printf "%s" "$PASSPHRASE") /dev/vg0/encrypted decrypted' target1.example.com target2.example.com
  ```

- **Commands can be run in remote terminal multiplexer session**

  Safe OS updates over flaky SSH connections:

  ```bash
  # Simply repeat this command if the SSH connection drops and you will be
  # re-attached to the existing session
  automated.sh -s -c 'run_in_multiplexer "yum -y update; exit"' centos.test
  ```
  Take a look at the [OS script from the ops-scripts repository](https://github.com/node13h/ops-scripts/blob/master/scripts/OS) for an extended version of this example.


- **File upload support**

  Use `--cp` or `--cp-list` arguments to copy files from the controlling workstation to the remote targets. Use `--drag` argument and `drop()` function if you want to calculate destination filename during runtime on every target individually. The following example uses facts to decide decide where to put the certificate:

  ```bash
  automated.sh --drag CA.crt ca_cert_file -c 'drop ca_cert_file "${FACT_PKI_CERTS}/CA.crt"' target.example.com
  ```

- **Zero remote footprint**

  Nothing is written on the remote targets unless you do that explicitly. All commands are executed on the fly, no temporary files are created.

- **Minimal number of dependencies**

  SUDO functionality and some API functions depend on Python 2.7 or later (including 3.x).

- **Local mode**

  Specify `--local` as a target to run commands directly on local system, bypassing the SSH. For example:

  ```bash
  automated.sh -s -c 'id' --local
  ```


## Use cases
- Deployment of various agents, like Puppet Agent, CollectD or Beats
- Deployment of applications
- Configuration management
- Delivery and remote decryption of SSL certificates
- OS updates
- Automation of ad hoc tasks executed on multiple systems

See the [cookbook directory](cookbook/) and the [ops-scripts repository](https://github.com/node13h/ops-scripts/tree/master/scripts) for some examples.


## Foundation for your automation scripts

You can use automated.sh as the framework for your own automation scripts

`my_script.sh`:
```bash
#!/usr/bin/env bash

set -euo pipefail

# This block will execute when this script is run directly, not sourced
# or piped into an interpreter
if ! (return 2> /dev/null); then

    # source libautomated.sh so we can use the quoted() function locally.
    source automated-config.sh
    source "${AUTOMATED_LIBDIR%/}/libautomated.sh"

    exec automated.sh \
         -s \
         -m 'printf "%s\n" "ADMIN=$(quoted "$(whoami)@$(uname -n)")"' \
         -c main \
         -l "${BASH_SOURCE[0]}" \
         "${@}"

fi

print_message () {
    echo "Hello World from $(whoami)@$(uname -n). ${ADMIN} controls me" | colorized 94
}

main () {
  print_message
}
```

Using:
```bash
my_script.sh centos.test ubuntu.test fedora.test freebsd.test
```

## Supported systems

Any *NIX system with Bash version 4 or later should work. SUDO PTY handling and file descriptor magic on targets is done by the helper Python script.

The following systems were confirmed to work both as controlling workstation and remote targets

- CentOS 7+
- Ubuntu 16.04+
- Fedora
- FreeBSD 11+


## Installing

### From source

```bash
sudo make install
```

## Testing

### Unit-tests

Run `make test`.


### End-to-end tests

Prerequisites:
- Podman

1. Create the test environment:

    - `make SSHD_TARGET_OS=centos7 sshd-target`
    - `make app-env`

    First step creates a sshd container with a pre-configured test user. Supported values for `SSHD_TARGET_OS` are `centos7`, `centos8`, `fedora34`, and `ubuntu2104`.
    Second step creates a container with the `ssh` command overriden (see [e2e/ssh](e2e/ssh)) to enable access the sshd target and a working copy Automated installed. You need to run `make app-env-down app-env` each time you modify the Automated code to update the app env container with the new changes.

2. Run `make e2e-test` to run the functional tests inside the created containers. Due to some issues with STDIN handling in Podman you might get an occassional `Error: read unixpacket @->/proc/self/fd/17/attach: read: connection reset by peer` error.
3. Run `make app-env-down sshd-target-down` to destroy both containers.


### Vagrant
`vagrant up` will bring Fedora, CentOS, Ubuntu and FreeBSD VMs with the pre-installed automated.sh and the pre-configured user account `user`. The password for this user is `secret`. Every machine will allow passwordless SSH pubkey-based login and SUDO using this user account.

Example:
```bash
vagrant up

vagrant ssh fedora
sudo -u user -i

automated.sh -c 'uname -a' centos.test ubuntu.test freebsd.test fedora.test

exit

vagrant ssh freebsd
sudo -u user -i

automated.sh -c 'uname -a' centos.test ubuntu.test freebsd.test fedora.test
```
