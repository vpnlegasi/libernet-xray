#!/bin/bash

# Libernet Service Wrapper
# Modded By Vpn Legasi

if [ "$(id -u)" != "0" ]; then
  echo "This script must be run as root" 1>&2
  exit 1
fi

function connect() {
  sshpass -p "${2}" ssh \
    -4CND "${3}" \
    -p 10443 \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    "${1}@127.0.0.1"
}

while true; do
  # command username password dynamic_port
  connect "${1}" "${2}" "${3}"
  sleep 3
done
