#!/usr/bin/env bash
# Cursor BYOK bootstrap (Linux; macOS untested).
# Installs a local CA and redirects Cursor's agent hostnames to your own backend.
#
#   curl -fsSL https://raw.githubusercontent.com/cursor-ide/cursor-installer/main/install.sh | sudo bash
#   curl -fsSL ... | sudo bash -s -- --ip 1.2.3.4 --uninstall
set -euo pipefail

PROXY_IP="${CURSOR_PROXY_IP:-203.0.113.10}"
CA_URL="${CURSOR_CA_URL:-http://${PROXY_IP}/ca.crt}"
MARK_BEGIN="# BEGIN cursor-byok"
MARK_END="# END cursor-byok"
UNINSTALL=0

usage() {
  cat <<EOF
cursor-byok installer (Linux/macOS)
  --ip <addr>     proxy IP (default ${PROXY_IP})
  --ca-url <url>  CA download URL (default ${CA_URL})
  --uninstall     remove hosts block, CA and env file
  --help          this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ip) PROXY_IP="$2"; shift 2 ;;
    --ca-url) CA_URL="$2"; shift 2 ;;
    --uninstall) UNINSTALL=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

HOSTNAMES="agent.api5.cursor.sh agentn.api5.cursor.sh \
agent-gcpp-uswest.api5.cursor.sh agentn-gcpp-uswest.api5.cursor.sh \
agentn-gcpp-eucentral.api5.cursor.sh agentn-gcpp-apsoutheast.api5.cursor.sh \
agent.global.api5.cursor.sh agentn.global.api5.cursor.sh \
agentn-gcpp-uswest.global.api5.cursor.sh agent-gcpp-uswest.global.api5.cursor.sh \
agentn-gcpp-eucentral.global.api5.cursor.sh agentn-gcpp-apsoutheast.global.api5.cursor.sh"

SUDO=""
if [[ "$(id -u)" -ne 0 ]]; then
  SUDO="sudo"
fi

HOSTS=/etc/hosts
[[ -f /private/etc/hosts ]] && HOSTS=/private/etc/hosts

strip_block() {
  $SUDO sed -i.bak "\\|^${MARK_BEGIN}$|,\\|^${MARK_END}$|d" "$HOSTS"
}

if [[ "$UNINSTALL" == "1" ]]; then
  echo "== removing hosts block"
  strip_block
  if [[ -f /usr/local/share/ca-certificates/cursor-byok-ca.crt ]]; then
    $SUDO rm -f /usr/local/share/ca-certificates/cursor-byok-ca.crt
    if command -v update-ca-certificates >/dev/null 2>&1; then $SUDO update-ca-certificates >/dev/null; fi
    if command -v update-ca-trust >/dev/null 2>&1; then $SUDO update-ca-trust >/dev/null; fi
  fi
  rm -f "$HOME/.config/environment.d/99-cursor-byok.conf"
  echo "done. restart Cursor."
  exit 0
fi

echo "== 1/4 download CA"
TMP_CA="$(mktemp)"
curl -fsSL "$CA_URL" -o "$TMP_CA"

echo "== 2/4 install CA into system trust store"
case "$(uname -s)" in
  Linux)
    $SUDO cp "$TMP_CA" /usr/local/share/ca-certificates/cursor-byok-ca.crt
    if command -v update-ca-certificates >/dev/null 2>&1; then
      $SUDO update-ca-certificates >/dev/null
    elif command -v update-ca-trust >/dev/null 2>&1; then
      $SUDO update-ca-trust >/dev/null
    fi
    ;;
  Darwin)
    $SUDO security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain "$TMP_CA"
    ;;
  *)
    echo "unsupported OS: $(uname -s)" >&2; exit 1 ;;
esac

echo "== 3/4 point Cursor agent hosts to $PROXY_IP"
strip_block
printf "\n%s\n%s %s\n%s\n" "$MARK_BEGIN" "$PROXY_IP" "$HOSTNAMES" "$MARK_END" | $SUDO tee -a "$HOSTS" >/dev/null

echo "== 4/4 export NODE_EXTRA_CA_CERTS for the desktop session"
CA_PATH=/usr/local/share/ca-certificates/cursor-byok-ca.crt
[[ "$(uname -s)" == "Darwin" ]] && CA_PATH="$HOME/.cursor-byok-ca.crt" && cp "$TMP_CA" "$CA_PATH"
mkdir -p "$HOME/.config/environment.d"
printf "NODE_EXTRA_CA_CERTS=%s\n" "$CA_PATH" > "$HOME/.config/environment.d/99-cursor-byok.conf"
if command -v systemctl >/dev/null 2>&1; then
  systemctl --user set-environment NODE_EXTRA_CA_CERTS="$CA_PATH" 2>/dev/null || true
fi
rm -f "$TMP_CA"

echo
echo "Done."
echo "  hosts:  $HOSTS"
echo "  CA:     $CA_PATH"
echo "  proxy:  https://$PROXY_IP"
echo "Log out/in (or reboot) so GUI apps inherit NODE_EXTRA_CA_CERTS, then restart Cursor."
echo "Revert: sudo bash install.sh --uninstall"
