#!/bin/bash

if [ "$(id -u)" != "0" ]; then
  echo "This script must be run as root" 1>&2
  exit 1
fi

HOME="/root"
ARCH="$(grep 'DISTRIB_ARCH' /etc/openwrt_release | awk -F '=' '{print $2}' | sed "s/'//g")"
LIBERNET_DIR="${HOME}/libernet"
LIBERNET_WWW="/www/libernet"
STATUS_LOG="${LIBERNET_DIR}/log/status.log"
DOWNLOADS_DIR="${HOME}/Downloads"
LIBERNET_TMP="${DOWNLOADS_DIR}/libernet"
REPOSITORY_URL="https://github.com/vpnlegasi/libernet-xray"

# Compare two versions, returns 0 if $1 < $2
function version_lt() {
  [ "$1" = "$2" ] && return 1
  [ "$(printf '%s\n' "$1" "$2" | sort -V | head -n1)" != "$2" ]
}

function fixes_os() {
  DISTFILE="/etc/opkg/distfeeds.conf"
  RELEASE_FILE="/etc/openwrt_release"

  # Default to env variables if set
  ver="${OPENWRT_VER:-}"
  target_info="${OPENWRT_TARGET_INFO:-}"
  arch="${OPENWRT_ARCH:-}"

  # Read release file if available
  if [ -f "$RELEASE_FILE" ]; then
    : "${ver:=$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+' "$RELEASE_FILE" | head -n1)}"
    : "${target_info:=$(grep DISTRIB_TARGET "$RELEASE_FILE" 2>/dev/null | cut -d"'" -f2)}"
    : "${arch:=$(grep DISTRIB_ARCH "$RELEASE_FILE" 2>/dev/null | cut -d"'" -f2)}"
  fi

  # Fallback for snapshot or unknown (ImmortalWrt)
  if [ -z "$ver" ] || [[ "${ver,,}" == *snapshot* ]]; then
    echo "Detected snapshot or unknown version, using fallback 23.05.3"
    ver="23.05.3"
  fi

  # Skip fixes if version >= 23.00
  if ! version_lt "$ver" "23.00"; then
    echo "OpenWrt $ver is 23.00 or newer, skipping fixes"
    return
  fi

  # Determine architecture if target_info missing
  if [ -z "$target_info" ]; then
    cpu="$(uname -m)"
    case "${cpu,,}" in
      aarch64|arm64)
        arch="${arch:-aarch64_generic}"
        target_info="rockchip/armv8"
        ;;
      armv7*|armv6*|armhf)
        arch="${arch:-arm_cortex-a9_vfpv3-d16}"
        target_info="ramips/mt7621"
        ;;
      x86_64)
        arch="${arch:-x86_64}"
        target_info="x86/64"
        ;;
      i686|i386)
        arch="${arch:-x86_generic}"
        target_info="x86/generic"
        ;;
      mips*)
        arch="${arch:-mips_24kc}"
        target_info="ath79/generic"
        ;;
      mipsel*)
        arch="${arch:-mipsel_24kc}"
        target_info="ramips/mt7621"
        ;;
      *)
        arch="${arch:-aarch64_generic}"
        target_info="rockchip/armv8"
        ;;
    esac
  fi

  target="$(printf '%s' "$target_info" | cut -d'/' -f1)"
  subtarget="$(printf '%s' "$target_info" | cut -d'/' -f2)"
  target="${target:-rockchip}"
  subtarget="${subtarget:-armv8}"

  # Special handling for IPQ platform
  if echo "$target_info" | grep -qiE 'ipq'; then
    target="qualcommax"
    case "$target_info" in
      *ipq807x*|*ipq807*)
        arch="${arch:-aarch64_cortex-a53}"
        subtarget="ipq807x"
        ;;
      *ipq60*|*ipq60xx*)
        arch="${arch:-aarch64_cortex-a53}"
        subtarget="ipq60xx"
        ;;
      *)
        arch="${arch:-aarch64_cortex-a53}"
        subtarget="${subtarget:-ipq807x}"
        ;;
    esac
  fi

  echo "Regenerating distfeeds.conf for OpenWrt $ver ($arch → $target/$subtarget)"

  # Write distfeeds.conf
  cat > "$DISTFILE" <<EOF
src/gz openwrt_core https://downloads.openwrt.org/releases/${ver}/targets/${target}/${subtarget}/packages
src/gz openwrt_base https://downloads.openwrt.org/releases/${ver}/packages/${arch}/base
src/gz openwrt_luci https://downloads.openwrt.org/releases/${ver}/packages/${arch}/luci
src/gz openwrt_packages https://downloads.openwrt.org/releases/${ver}/packages/${arch}/packages
src/gz openwrt_routing https://downloads.openwrt.org/releases/${ver}/packages/${arch}/routing
src/gz openwrt_telephony https://downloads.openwrt.org/releases/${ver}/packages/${arch}/telephony
EOF
}

function install_packages() {
  echo "Updating package lists (optional)..."
  packages=(
    bash
    curl
    librt
    libpthread
    coreutils
    coreutils-stdbuf
    screen
    jq
    ip-full
    kmod-tun
    openssh-client
    dnsmasq-full
    stubby
    php8
    php8-cgi
    php8-mod-session
    python3
    httping
    stunnel
    openvpn-openssl
  )

  for pkg in "${packages[@]}"; do
    echo "Checking ${pkg} ..."

    # ---- Force recheck for curl even if installed ----
    if opkg list-installed "${pkg}" 2>/dev/null | grep -q "^${pkg} -"; then
      if [ "${pkg}" = "curl" ]; then
        if ! curl -V >/dev/null 2>&1; then
          echo "  curl appears broken, forcing reinstall..."
          opkg remove curl libcurl4 --force-depends >/dev/null 2>&1
          rm -f /usr/bin/curl /usr/lib/libcurl.so*
          fixes_os
          rm -rf /tmp/opkg-lists/*
          opkg update >/dev/null 2>&1
          opkg install libcurl4 curl ca-certificates >/dev/null 2>&1
          if curl -V >/dev/null 2>&1; then
            echo "  curl repaired successfully."
          else
            echo "  Warning: curl reinstall failed, manual check required."
          fi
        else
          echo "  curl already installed and working, skipping."
        fi
      else
        echo "  ${pkg} already installed, skipping."
      fi
      continue
    fi
    # --------------------------------------------------

    success=0
    for attempt in 1 2 3; do
      echo "  Installing ${pkg} (attempt $attempt of 3)..."
      if opkg install "${pkg}" >/dev/null 2>&1; then
        echo "  Installed ${pkg}."
        success=1
        break
      else
        echo "  Failed to install ${pkg} on attempt $attempt, running fixes..."
        fixes_os
        rm -rf /tmp/opkg-lists/*
        opkg update >/dev/null 2>&1
      fi
    done

    if [ "$success" -eq 0 ]; then
      echo "  Warning: failed to install ${pkg} after 3 attempts, skipping..."
      continue
    fi

    # --- Special handling for curl after installation ---
    if [ "${pkg}" = "curl" ]; then
      echo "  Testing curl version..."
      if ! curl -V >/dev/null 2>&1; then
        echo "  curl test failed — attempting full repair..."
        for attempt in 1 2 3; do
          echo "  Repairing curl (attempt $attempt of 3)..."
          fixes_os
          rm -rf /tmp/opkg-lists/*
          opkg update >/dev/null 2>&1
          opkg remove curl libcurl4 --force-depends >/dev/null 2>&1
          opkg install libcurl4 curl ca-certificates >/dev/null 2>&1

          curl_ver=$(opkg info curl 2>/dev/null | grep Version | awk '{print $2}')
          libcurl_ver=$(opkg info libcurl4 2>/dev/null | grep Version | awk '{print $2}')
          echo "    curl version: ${curl_ver}"
          echo "    libcurl4 version: ${libcurl_ver}"

          if curl -V >/dev/null 2>&1; then
            echo "  curl repaired successfully."
            success=1
            break
          else
            echo "  curl still not working, retrying..."
          fi
        done

        if ! curl -V >/dev/null 2>&1; then
          echo "  Warning: curl still not functional after repair attempts."
        fi
      else
        echo "  curl verified working."
      fi
    fi
  done
}

function install_proprietary_binaries() {
  echo -e "Installing proprietary binaries"
  bins=(
    badvpn-tun2socks
    ck-client
    corkscrew
    go-tun2socks
    obfs-local
    sshpass
    trojan-go
  )

  for line in "${bins[@]}"; do
    if ! command -v "${line}" >/dev/null 2>&1; then
      bin="/usr/bin/${line}"
      echo "Installing ${line} to ${bin} ..."
      if curl -fsSL -o "${bin}" "https://github.com/vpnlegasi/libernet-core/raw/main/${ARCH}/binaries/${line}"; then
        chmod +x "${bin}"
        echo "Installed ${line} successfully."
      else
        echo "Warning: failed to download ${line}, skipping..."
        continue
      fi
    else
      echo "${line} already installed, skipping."
    fi
  done
}

function install_proprietary_packages() {
  echo -e "Installing proprietary packages"
  packages=(
    xray
  )

  for line in "${packages[@]}"; do
    pkg="/tmp/${line}.ipk"
    fallback_zip="/tmp/xray-fallback.zip"
    echo "Downloading latest ${line} from Libernet repo..."
    if ! curl -fsSL -o "${pkg}" "https://github.com/vpnlegasi/libernet-core/raw/main/${ARCH}/packages/${line}.ipk"; then
      echo "Libernet repo xray.ipk not found, fallback to official Xray release"
      # Tentukan ARCH untuk Xray
      case "$ARCH" in
        aarch64*) arch="arm64" ;;
        arm*)    arch="arm32-v7a" ;;
        mips*)   arch="mipsle" ;;
        x86_64)  arch="64" ;;
        i386)    arch="32" ;;
        *)       arch="64" ;;
      esac
      echo "Downloading official Xray release for $arch..."
      curl -fsSL -o "${fallback_zip}" "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${arch}.zip" || { 
        echo "Failed to download official Xray release, skipping..."; continue; 
      }
      unzip -o "${fallback_zip}" -d /tmp >/dev/null 2>&1
      chmod +x /tmp/xray
      mv /tmp/xray /usr/bin/xray
      rm -f "${fallback_zip}"
      echo "Installed Xray from official release"
      continue
    fi

    # Remove old Xray if exists
    if command -v xray >/dev/null 2>&1; then
      echo "Removing old Xray..."
      opkg remove xray >/dev/null 2>&1
      rm -f /usr/bin/xray
    fi

    echo "Installing ${line} from Libernet repo..."
    if opkg install "${pkg}" >/dev/null 2>&1; then
      echo "Installed ${line} successfully."
      chmod +x /usr/bin/xray
    else
      echo "Warning: failed to install ${line} from Libernet repo, skipping..."
    fi
    rm -f "${pkg}"
  done
}

function install_proprietary() {
  install_proprietary_binaries
  install_proprietary_packages
}

function install_prerequisites() {
  # update packages index
  opkg update
}

function install_requirements() {
  echo -e "Installing packages" \
    && install_prerequisites \
    && install_packages \
    && install_proprietary
}

function enable_uhttp_php() {
  if ! grep -q ".php=/usr/bin/php-cgi" /etc/config/uhttpd; then
    echo -e "Enabling uhttp php execution" \
      && uci set uhttpd.main.interpreter='.php=/usr/bin/php-cgi' \
      && uci add_list uhttpd.main.index_page='index.php' \
      && uci commit uhttpd \
      && echo -e "Restarting uhttp service" \
      && /etc/init.d/uhttpd restart
  else
    echo -e "uhttp php already enabled, skipping ..."
  fi
}

function add_libernet_environment() {
  if ! grep -q LIBERNET_DIR /etc/profile; then
    echo -e "Adding Libernet environment" \
      && echo -e "\n# Libernet\nexport LIBERNET_DIR=${LIBERNET_DIR}" | tee -a '/etc/profile'
  fi
}

function fix_web() {
  folders=(
    "${LIBERNET_DIR}/log"
    "${LIBERNET_DIR}/bin/config/openvpn"
    "${LIBERNET_DIR}/bin/config/shadowsocks"
    "${LIBERNET_DIR}/bin/config/ssh"
    "${LIBERNET_DIR}/bin/config/ssh_ssl"
    "${LIBERNET_DIR}/bin/config/ssh_ws_cdn"
    "${LIBERNET_DIR}/bin/config/stunnel"
    "${LIBERNET_DIR}/bin/config/trojan"
    "${LIBERNET_DIR}/bin/config/v2ray"
  )

  for dir in "${folders[@]}"; do
    mkdir -p "$dir"
    cat <<EOF > "${dir}/.gitignore"
# Ignore everything in this directory
*
# Except this file
!.gitignore
EOF
    echo "Created ${dir}/.gitignore"
  done
}

function install_libernet() {
  # stop Libernet before install
  if [[ -f "${LIBERNET_DIR}/bin/service.sh" && $(cat "${STATUS_LOG}") != "0" ]]; then
    echo -e "Stopping Libernet"
    "${LIBERNET_DIR}/bin/service.sh" -ds > /dev/null 2>&1
  fi
  rm -rf "${LIBERNET_WWW}"
  echo -e "Installing Libernet" \
    && mkdir -p "${LIBERNET_DIR}" \
    && echo -e "Copying binary" \
    && cp -arvf bin "${LIBERNET_DIR}/" \
    && find "${LIBERNET_DIR}/bin" -type f -exec chmod +x {} \; > /dev/null 2>&1 \
    && echo -e "Copying system" \
    && cp -arvf system "${LIBERNET_DIR}/" \
    && echo -e "Copying web files" \
    && fix_web >/dev/null 2>&1 \
    && mkdir -p "${LIBERNET_WWW}" \
    && cp -arvf web/* "${LIBERNET_WWW}/" \
    && echo -e "Configuring Libernet" \
    && sed -i "s/LIBERNET_DIR/$(echo ${LIBERNET_DIR} | sed 's/\//\\\//g')/g" "${LIBERNET_WWW}/config.inc.php"
}

function configure_vpnlegasi_firewall() {
  if ! uci get network.vpnlegasi > /dev/null 2>&1; then
    ver="$(. /etc/openwrt_release; echo $DISTRIB_RELEASE)"
    major_ver="$(echo "$ver" | cut -d'.' -f1)"

    echo "Configuring vpnlegasi firewall" \
      && uci set network.vpnlegasi=interface \
      && uci set network.vpnlegasi.proto='none' \
      && if [ "$major_ver" -ge 23 ]; then \
           uci set network.vpnlegasi.device='tun1'; \
         else \
           uci set network.vpnlegasi.ifname='tun1'; \
         fi \
      && uci commit \
      && uci add firewall zone \
      && uci set firewall.@zone[-1].network='vpnlegasi' \
      && uci set firewall.@zone[-1].name='vpnlegasi' \
      && uci set firewall.@zone[-1].masq='1' \
      && uci set firewall.@zone[-1].mtu_fix='1' \
      && uci set firewall.@zone[-1].input='REJECT' \
      && uci set firewall.@zone[-1].forward='REJECT' \
      && uci set firewall.@zone[-1].output='ACCEPT' \
      && uci commit \
      && uci add firewall forwarding \
      && uci set firewall.@forwarding[-1].src='lan' \
      && uci set firewall.@forwarding[-1].dest='vpnlegasi' \
      && uci commit \
      && /etc/init.d/network restart
  fi
}

function configure_libernet_service() {
  echo -e "Configuring Libernet service"
  # disable services startup
  # DoT
  /etc/init.d/stubby disable
  # shadowsocks
  /etc/init.d/shadowsocks-libev disable
  # openvpn
  /etc/init.d/openvpn disable
  # stunnel
  /etc/init.d/stunnel disable
}

function setup_system_logs() {
  echo -e "Setup system logs"
  logs=("status.log" "service.log" "connected.log")
  for log in "${logs[@]}"; do
    if [[ ! -f "${LIBERNET_DIR}/log/${log}" ]]; then
      touch "${LIBERNET_DIR}/log/${log}"
    fi
  done
}

function finish_install() {
  clear
  chmod +x /root/libernet/bin/*
  router_ip="$(ifconfig br-lan | grep 'inet addr:' | awk '{print $2}' | awk -F ':' '{print $2}')"
  echo -e "Libernet URL: http://${router_ip}/libernet"
  echo -e "Username : admin"
  echo -e "Password : vpnlegasi"
  echo -e "Libernet successfully installed!"
}

function clean_install() {
  rm -rf /root/install.sh > /dev/null 2>&1
  rm -rf /root/Downloads > /dev/null 2>&1
  find /root/libernet/bin -type f -exec chmod +x {} \; > /dev/null 2>&1
  sleep 10
  echo -e "System will reboot in 10 sec"
  reboot
}

function main_installer() {
  install_requirements \
    && install_libernet \
    && add_libernet_environment \
    && enable_uhttp_php \
    && configure_vpnlegasi_firewall \
    && configure_libernet_service \
    && setup_system_logs \
    && finish_install \
    && clean_install
}

function main() {
  # install git if it's unavailable
  if [[ $(opkg list-installed git | grep -c git) != "1" ]]; then
    opkg update \
      && opkg install git
  fi
  if [[ $(opkg list-installed git-http | grep -c git-http) != "1" ]]; then
    opkg update \
      && opkg install git-http
  fi
  # create ~/Downloads directory if not exist
  if [[ ! -d "${DOWNLOADS_DIR}" ]]; then
    mkdir -p "${DOWNLOADS_DIR}"
  fi
  # install Libernet
  if [[ ! -d "${LIBERNET_TMP}" ]]; then
    git clone --depth 1 "${REPOSITORY_URL}" "${LIBERNET_TMP}" \
      && cd "${LIBERNET_TMP}" \
      && bash install.sh
  else
    cd "${LIBERNET_TMP}" \
      && main_installer
  fi
}

main
