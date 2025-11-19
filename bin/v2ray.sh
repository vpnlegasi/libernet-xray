#!/bin/bash

# Libernet Xray Service Wrapper
# Modded By Vpn Legasi

if [ "$(id -u)" != "0" ]; then
  echo "This script must be run as root" 1>&2
  exit 1
fi

SERVICE_NAME="Xray"
SYSTEM_CONFIG="${LIBERNET_DIR}/system/config.json"

# Get active V2Ray/Xray profile name
PROFILE_NAME="$(grep 'v2ray":' ${SYSTEM_CONFIG} | awk '{print $2}' | sed 's/[",]//g')"

XRAY_CONFIG="${LIBERNET_DIR}/bin/config/v2ray/${PROFILE_NAME}.json"

# Detect protocol inside JSON (vmess, vless, trojan)
XRAY_PROTOCOL="$(grep '"protocol"' ${XRAY_CONFIG} | awk -F '"' '{print $4}' | tail -n1)"

case "${XRAY_PROTOCOL}" in
  vmess)
    XRAY_PROTOCOL="VMess"
    ;;
  vless)
    XRAY_PROTOCOL="VLESS"
    ;;
  trojan)
    XRAY_PROTOCOL="Trojan"
    ;;
  *)
    XRAY_PROTOCOL="Unknown"
    ;;
esac

run() {
  "${LIBERNET_DIR}/bin/log.sh" -w "Config: ${PROFILE_NAME}, Mode: ${SERVICE_NAME}, Protocol: ${XRAY_PROTOCOL}"
  "${LIBERNET_DIR}/bin/log.sh" -w "Starting ${SERVICE_NAME} service"
  echo -e "Starting ${SERVICE_NAME} service ..."

  # Run Xray inside screen, autorestart forever
  screen -AmdS xray-client bash -c "
    while true; do 
      xray -c '${XRAY_CONFIG}'; 
      sleep 3; 
    done"

  echo -e "${SERVICE_NAME} service started!"
}

stop() {
  "${LIBERNET_DIR}/bin/log.sh" -w "Stopping ${SERVICE_NAME} service"
  echo -e "Stopping ${SERVICE_NAME} service ..."

  # Kill screen session
  kill $(screen -list | grep xray-client | awk -F '[.]' '{print $1}') 2>/dev/null

  # Kill all xray processes
  killall xray 2>/dev/null

  echo -e "${SERVICE_NAME} service stopped!"
}

usage() {
  cat <<EOF
Usage:
  -r  Run ${SERVICE_NAME} service
  -s  Stop ${SERVICE_NAME} service
EOF
}

case "$1" in
  -r) run ;;
  -s) stop ;;
  *) usage ;;
esac
