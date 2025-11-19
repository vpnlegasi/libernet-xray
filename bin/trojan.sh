#!/bin/bash

# Libernet Service Wrapper (Xray Version)
# Modded By Vpn Legasi

if [ "$(id -u)" != "0" ]; then
  echo "This script must be run as root" 1>&2
  exit 1
fi

SERVICE_NAME="Trojan (Xray)"
SYSTEM_CONFIG="${LIBERNET_DIR}/system/config.json"
TROJAN_PROFILE="$(grep 'trojan":' ${SYSTEM_CONFIG} | awk '{print $2}' | sed 's/,//g; s/"//g')"

# Xray client config folder
TROJAN_CONFIG="${LIBERNET_DIR}/bin/config/trojan/${TROJAN_PROFILE}.json"

function run() {
  "${LIBERNET_DIR}/bin/log.sh" -w "Config: ${TROJAN_PROFILE}, Mode: ${SERVICE_NAME}"
  "${LIBERNET_DIR}/bin/log.sh" -w "Starting ${SERVICE_NAME} service"
  echo -e "Starting ${SERVICE_NAME} service ..."

  screen -AmdS trojan-client bash -c "while true; do xray run -c \"${TROJAN_CONFIG}\"; sleep 3; done" \
    && echo -e "${SERVICE_NAME} service started!"
}

function stop() {
  "${LIBERNET_DIR}/bin/log.sh" -w "Stopping ${SERVICE_NAME} service"
  echo -e "Stopping ${SERVICE_NAME} service ..."

  kill $(screen -list | grep trojan-client | awk -F '[.]' {'print $1'})
  killall xray 2>/dev/null

  echo -e "${SERVICE_NAME} service stopped!"
}

function usage() {
  cat <<EOF
Usage:
  -r  Run ${SERVICE_NAME} service
  -s  Stop ${SERVICE_NAME} service
EOF
}

case "${1}" in
  -r)
    run
    ;;
  -s)
    stop
    ;;
  *)
    usage
    ;;
esac
