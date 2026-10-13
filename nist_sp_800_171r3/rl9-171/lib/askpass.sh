#!/bin/sh
# SSH_ASKPASS for tools/lab-ssh.sh: prints the password in the file
# NIST_ASKPASS_FILE names - a 0600 file in the container's own /dev/shm,
# written by nist_askpass_for (lib/ssh-env.sh). This script is the executable
# part, from the repository, because /dev/shm in a container is mounted
# noexec: an askpass written there could not run, ssh offered no password and
# the host refused the login (DEFECTS 7.44).
exec cat "${NIST_ASKPASS_FILE:?}"
