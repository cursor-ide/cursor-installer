#!/usr/bin/env bash
# Cursor BYOK bootstrap (Linux; macOS untested).
# Installs a local CA and redirects Cursor's agent hostnames to your own backend.
#
#   curl -fsSL https://raw.githubusercontent.com/cursor-ide/cursor-installer/main/install.sh | sudo bash
#   curl -fsSL ... | sudo bash -s -- --ip 1.2.3.4
#   curl -fsSL ... | sudo bash -s -- --uninstall
set -euo pipefail

PROXY_IP="${CURSOR_PROXY_IP:-203.0.113.10}"
CA_URL="${CURSOR_CA_URL:-http://${PROXY_IP}/ca.crt}"
MARK_BEGIN="# BEGIN cursor-byok"
MARK_END="# END cursor-byok"
UNINSTALL=0
TARGET_USER_OPT=""

usage() {
  cat <<EOF
cursor-byok installer (Linux/macOS)
  --ip <addr>      proxy IP (default ${PROXY_IP})
  --ca-url <url>   CA download URL (default ${CA_URL})
  --user <name>    desktop user to configure (default: sudo caller)
  --uninstall      remove hosts block, CA and env file
  --help           this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ip) PROXY_IP="$2"; shift 2 ;;
    --ca-url) CA_URL="$2"; shift 2 ;;
    --user) TARGET_USER_OPT="$2"; shift 2 ;;
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
if [[ "$(id -u)" -ne 0 ]]; then SUDO="sudo"; fi

# Resolve the desktop user whose session should receive NODE_EXTRA_CA_CERTS.
TARGET_USER="${TARGET_USER_OPT:-${SUDO_USER:-}}"
if [[ -z "$TARGET_USER" ]]; then
  TARGET_USER="$(id -un)"
fi
if [[ "$TARGET_USER" == "root" ]]; then
  for d in /run/user/*; do
    uid="${d##*/}"
    [[ "$uid" == "0" ]] && continue
    candidate="$(getent passwd "$uid" | cut -d: -f1 || true)"
    if [[ -n "$candidate" ]]; then TARGET_USER="$candidate"; break; fi
  done
fi
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6 || true)"
[[ -z "${TARGET_HOME:-}" ]] && TARGET_HOME="/home/$TARGET_USER"
TARGET_UID="$(id -u "$TARGET_USER" 2>/dev/null || echo 1000)"
echo "== target desktop user: $TARGET_USER ($TARGET_HOME)"

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
  rm -f "$TARGET_HOME/.config/environment.d/99-cursor-byok.conf"
  echo "done. restart Cursor."
  exit 0
fi

echo "== 1/4 download CA"
TMP_CA="$(mktemp)"
curl -fsSL "$CA_URL" -o "$TMP_CA"

echo "== 2/4 install CA into system trust store"
CA_PATH=/usr/local/share/ca-certificates/cursor-byok-ca.crt
case "$(uname -s)" in
  Linux)
    $SUDO cp "$TMP_CA" "$CA_PATH"
    if command -v update-ca-certificates >/dev/null 2>&1; then
      $SUDO update-ca-certificates >/dev/null
    elif command -v update-ca-trust >/dev/null 2>&1; then
      $SUDO update-ca-trust >/dev/null
    fi
    ;;
  Darwin)
    $SUDO security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain "$TMP_CA"
    CA_PATH="$TARGET_HOME/.cursor-byok-ca.crt"
    $SUDO cp "$TMP_CA" "$CA_PATH"
    $SUDO chown "$TARGET_USER" "$CA_PATH"
    ;;
  *)
    echo "unsupported OS: $(uname -s)" >&2; exit 1 ;;
esac

echo "== 3/4 point Cursor agent hosts to $PROXY_IP"
strip_block
printf "\n%s\n%s %s\n%s\n" "$MARK_BEGIN" "$PROXY_IP" "$HOSTNAMES" "$MARK_END" | $SUDO tee -a "$HOSTS" >/dev/null

echo "== 4/4 export NODE_EXTRA_CA_CERTS for the desktop session"
$SUDO mkdir -p "$TARGET_HOME/.config/environment.d"
printf "NODE_EXTRA_CA_CERTS=%s\n" "$CA_PATH" | $SUDO tee "$TARGET_HOME/.config/environment.d/99-cursor-byok.conf" >/dev/null
$SUDO chown -R "$TARGET_USER" "$TARGET_HOME/.config/environment.d" 2>/dev/null || true

if command -v systemctl >/dev/null 2>&1; then
  if [[ -d "/run/user/$TARGET_UID" ]]; then
    $SUDO -u "$TARGET_USER" XDG_RUNTIME_DIR="/run/user/$TARGET_UID" \
      systemctl --user set-environment NODE_EXTRA_CA_CERTS="$CA_PATH" 2>/dev/null || true
  fi
fi
rm -f "$TMP_CA"

echo
echo "Done."
echo "  hosts:  $HOSTS"
echo "  CA:     $CA_PATH"
echo "  proxy:  https://$PROXY_IP"
echo "Log out/in (or reboot) so GUI apps inherit NODE_EXTRA_CA_CERTS, then restart Cursor."
echo "Revert: sudo bash install.sh --uninstall"
