# Copyright (C) 2016-2017 Sergej Alikov <sergej.alikov@gmail.com>

# This file is part of Automated.

# Automated is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.

# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

from __future__ import unicode_literals
import os
import sys
import pty
import termios
import time
import argparse
import fcntl


parser = argparse.ArgumentParser(description='SUDO PTY helper')
parser.add_argument('--sudo-passwordless', action='store_true', default=False)
parser.add_argument('command')

args = parser.parse_args()

DEFAULT_TIMEOUT = 60
DEFAULT_READ_BUFFER_SIZE = 1024

STDIN = sys.stdin.fileno()
STDOUT = sys.stdout.fileno()
STDERR = sys.stderr.fileno()

EXIT_TIMEOUT = int(os.environ['EXIT_TIMEOUT'])
EXIT_SUDO_PASSWORD_NOT_ACCEPTED = int(os.environ['EXIT_SUDO_PASSWORD_NOT_ACCEPTED'])
EXIT_SUDO_PASSWORD_REQUIRED = int(os.environ['EXIT_SUDO_PASSWORD_REQUIRED'])


class Timeout(Exception):
    pass


def one_of(
        fd, string_list, timeout=DEFAULT_TIMEOUT,
        read_buffer_size=DEFAULT_READ_BUFFER_SIZE):

    buffer = b''
    longest_string_len = max([len(s) for s in string_list])

    start = time.time()

    while True:

        # We might hit the EOF multiple times

        try:
            chunk = os.read(fd, read_buffer_size)
        except OSError:
            continue

        if not chunk:
            continue

        buffer = b''.join([buffer, chunk])

        for s in string_list:
            if s in buffer:
                return s

        buffer = buffer[-longest_string_len:]

        if timeout is not None:
            if time.time() - start >= timeout:
                raise Timeout()


# Save standard file descriptors for later
fd0 = os.dup(STDIN)
fd1 = os.dup(STDOUT)
fd2 = os.dup(STDERR)

# Open PTY before closing the standard descriptors.
# Otherwise OS will assign one of the now unused standard
# descriptor numbers causing it to be replaced in the
# child process later.
parent_fd, child_fd = pty.openpty()

# Closing these will prevent Python script itself
# from being able to output stuff onto STDOUT/STDERR
os.close(STDIN)
os.close(STDOUT)
os.close(STDERR)

sudo_pass_buffer = []

while True:
    c = os.read(fd0, 1)

    sudo_pass_buffer.append(c)

    if c == b'\n':
        break

sudo_pass = b''.join(sudo_pass_buffer)

pid = os.fork()

if pid is 0:
    os.close(parent_fd)
    os.setsid()
    # Attach to the controlling terminal on the BSD
    # systems
    fcntl.ioctl(child_fd, termios.TIOCSCTTY)

    # Attach to the controlling terminal on Linux
    fd = os.open(os.ttyname(child_fd), os.O_RDWR)
    os.close(fd)

    # Replace the standard descriptors with the saved ones
    os.dup2(fd0, STDIN)
    os.dup2(fd1, STDOUT)
    os.dup2(fd2, STDERR)
    os.close(fd0)
    os.close(fd1)
    os.close(fd2)

    os.execvp('sudo', [
        'sudo', '-p', 'SUDO_PASSWORD_PROMPT:',
        'bash', '-c', (
            'echo "SUDO_SUCCESS" >/dev/tty; '
            'export PTY_HELPER_SCRIPT={}; '
            'export {}={}; '
            'exec {}').format(__file__,
                              os.environ['SUDO_UID_VARIABLE'], os.getuid(),
                              args.command)])

os.close(child_fd)
# Disable echo
attr = termios.tcgetattr(parent_fd)
attr[3] = attr[3] & ~termios.ECHO
termios.tcsetattr(parent_fd, termios.TCSANOW, attr)

try:
    s = one_of(parent_fd, [b'SUDO_PASSWORD_PROMPT:', b'SUDO_SUCCESS'])
    if s == b'SUDO_PASSWORD_PROMPT:':

        if args.sudo_passwordless:
            sys.exit(EXIT_SUDO_PASSWORD_REQUIRED)

        os.write(parent_fd, sudo_pass)

        s = one_of(parent_fd, [b'SUDO_PASSWORD_PROMPT:', b'SUDO_SUCCESS'])
        if s == b'SUDO_PASSWORD_PROMPT:':
            sys.exit(EXIT_SUDO_PASSWORD_NOT_ACCEPTED)
except Timeout:
    sys.exit(EXIT_TIMEOUT)

pid, exitstatus = os.waitpid(pid, 0)

sys.exit(exitstatus >> 8)
