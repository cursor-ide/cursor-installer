#!/usr/bin/env bash
# cursor-byok bootstrap (Linux + macOS).
# Installs a local CA and redirects every Cursor backend hostname (agent, account
# dashboard and repository ingestion) to your own backend.
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
DRY_RUN=0

usage() {
  cat <<EOF
cursor-byok installer (Linux/macOS)
  --ip <addr>      proxy IP (default ${PROXY_IP})
  --ca-url <url>   CA download URL (default ${CA_URL})
  --user <name>    desktop user to configure (default: sudo caller)
  --uninstall      remove hosts block, CA and env
  --dry-run        list every redirected host and the CA path, change nothing
  --help           this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ip) PROXY_IP="$2"; shift 2 ;;
    --ca-url) CA_URL="$2"; shift 2 ;;
    --user) TARGET_USER_OPT="$2"; shift 2 ;;
    --uninstall) UNINSTALL=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

OS="$(uname -s)"
case "$OS" in
  Linux|Darwin) ;;
  *) echo "unsupported OS: $OS" >&2; exit 1 ;;
esac

# Agent traffic (agent.v1.AgentService, inference, CmdK/Cpp).
AGENT_HOSTNAMES="agent.api5.cursor.sh agentn.api5.cursor.sh \
agent-gcpp-uswest.api5.cursor.sh agentn-gcpp-uswest.api5.cursor.sh \
agentn-gcpp-eucentral.api5.cursor.sh agentn-gcpp-apsoutheast.api5.cursor.sh \
agent.global.api5.cursor.sh agentn.global.api5.cursor.sh \
agentn-gcpp-uswest.global.api5.cursor.sh agent-gcpp-uswest.global.api5.cursor.sh \
agentn-gcpp-eucentral.global.api5.cursor.sh agentn-gcpp-apsoutheast.global.api5.cursor.sh"

# Account/membership dashboard (api3), repository ingestion (repo42) and the
# extension's HTTP/1.1 fallback host (api2).
API_HOSTNAMES="api3.cursor.sh repo42.cursor.sh api2.cursor.sh"

HOSTNAMES="$AGENT_HOSTNAMES $API_HOSTNAMES"
# shellcheck disable=SC2086  # intentional word splitting of the hostname list
HOST_COUNT=$(printf '%s\n' $HOSTNAMES | wc -w | tr -d ' ')

SUDO=""
if [[ "$(id -u)" -ne 0 ]]; then SUDO="sudo"; fi

run() {
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "  [dry-run] $*"
  else
    "$@"
  fi
}

# macOS has no getent; ask the directory service instead.
user_home() {
  local user="$1"
  if [[ "$OS" == "Darwin" ]]; then
    dscl . -read "/Users/$user" NFSHomeDirectory 2>/dev/null | awk '{print $2}'
  else
    getent passwd "$user" 2>/dev/null | cut -d: -f6
  fi
}

TARGET_USER="${TARGET_USER_OPT:-${SUDO_USER:-}}"
if [[ -z "$TARGET_USER" ]]; then TARGET_USER="$(id -un)"; fi
if [[ "$TARGET_USER" == "root" && "$OS" == "Linux" ]]; then
  for d in /run/user/*; do
    uid="${d##*/}"
    [[ "$uid" == "0" ]] && continue
    candidate="$(getent passwd "$uid" | cut -d: -f1 || true)"
    if [[ -n "$candidate" ]]; then TARGET_USER="$candidate"; break; fi
  done
fi
TARGET_HOME="$(user_home "$TARGET_USER")"
[[ -z "${TARGET_HOME:-}" ]] && TARGET_HOME="/home/$TARGET_USER"
TARGET_UID="$(id -u "$TARGET_USER" 2>/dev/null || echo 1000)"
echo "== platform: $OS $(uname -m)"
echo "== target desktop user: $TARGET_USER ($TARGET_HOME)"

HOSTS=/etc/hosts
[[ -f /private/etc/hosts ]] && HOSTS=/private/etc/hosts

CA_DIR_LINUX=/usr/local/share/ca-certificates
CA_FILE_LINUX="$CA_DIR_LINUX/cursor-byok-ca.crt"
CA_FILE_USER="$TARGET_HOME/.cursor-byok-ca.crt"
LAUNCH_AGENT="$TARGET_HOME/Library/LaunchAgents/net.cursor-ide.cursor-byok.plist"
LAUNCH_AGENT_LABEL="net.cursor-ide.cursor-byok"
SHELL_RC="$TARGET_HOME/.zprofile"
ENV_DIR_CONF="$TARGET_HOME/.config/environment.d/99-cursor-byok.conf"

as_user() {
  if [[ "$(id -u)" -eq 0 && "$TARGET_USER" != "root" ]]; then
    run sudo -u "$TARGET_USER" "$@"
  else
    run "$@"
  fi
}

strip_block() {
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "  [dry-run] strip $MARK_BEGIN block from $HOSTS"
  else
    $SUDO sed -i.bak "\\|^${MARK_BEGIN}$|,\\|^${MARK_END}$|d" "$HOSTS"
  fi
}

flush_dns_macos() {
  [[ "$OS" == "Darwin" ]] || return 0
  run dscacheutil -flushcache
  run killall -HUP mDNSResponder 2>/dev/null || true
}

# Trust store helpers -------------------------------------------------------
trust_ca_linux() {
  run $SUDO cp "$1" "$CA_FILE_LINUX"
  if command -v update-ca-certificates >/dev/null 2>&1; then
    run $SUDO update-ca-certificates >/dev/null
  elif command -v update-ca-trust >/dev/null 2>&1; then
    run $SUDO update-ca-trust >/dev/null
  fi
}

trust_ca_macos() {
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "   [dry-run] trust CA in the System keychain"
    return 0
  fi
  # Only works when macOS can show an authorization prompt (Desktop login window or
  # Terminal.app). Over plain SSH the Security framework denies it, so treat this as
  # best effort: Cursor's agent host is a Node process and trusts NODE_EXTRA_CA_CERTS.
  if $SUDO security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain "$1" 2>/dev/null; then
    echo "   installed into the System keychain"
    return 0
  fi
  echo "   ! could not add the CA to the System keychain (macOS needs an interactive approval)"
  echo "     Cursor's Node agent host is covered by NODE_EXTRA_CA_CERTS, so chat still works."
  echo "     To trust it system-wide, run in Terminal.app on this Mac:"
  echo "       sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain $CA_FILE_USER"
  echo "     (or open the file in Keychain Access and set Always Trust)"
  return 0
}

untrust_ca_macos() {
  # Match by subject CN; the same CA may be installed more than once.
  local cn="Cursor Local CA"
  while $SUDO security find-certificate -c "$cn" /Library/Keychains/System.keychain >/dev/null 2>&1; do
    run $SUDO security delete-certificate -c "$cn" /Library/Keychains/System.keychain >/dev/null || break
  done
}

# Env export per platform ---------------------------------------------------
set_env_linux() {
  run $SUDO mkdir -p "$TARGET_HOME/.config/environment.d"
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "  [dry-run] write $ENV_DIR_CONF"
  else
    printf "NODE_EXTRA_CA_CERTS=%s\n" "$CA_FILE_USER" | $SUDO tee "$ENV_DIR_CONF" >/dev/null
    $SUDO chown -R "$TARGET_USER" "$TARGET_HOME/.config/environment.d" 2>/dev/null || true
  fi
  if command -v systemctl >/dev/null 2>&1 && [[ -d "/run/user/$TARGET_UID" ]]; then
    if [[ "$DRY_RUN" == "1" ]]; then
      echo "  [dry-run] systemctl --user set-environment NODE_EXTRA_CA_CERTS"
      return 0
    fi
    if [[ "$(id -u)" -eq 0 && "$TARGET_USER" != "root" ]]; then
      sudo -u "$TARGET_USER" env \
        XDG_RUNTIME_DIR="/run/user/$TARGET_UID" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$TARGET_UID/bus" \
        systemctl --user set-environment NODE_EXTRA_CA_CERTS="$CA_FILE_USER" 2>/dev/null || true
    else
      XDG_RUNTIME_DIR="/run/user/$TARGET_UID" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$TARGET_UID/bus" \
        systemctl --user set-environment NODE_EXTRA_CA_CERTS="$CA_FILE_USER" 2>/dev/null || true
    fi
  fi
}

# macOS GUI apps inherit the launchd session environment, not the shell's, so
# set it with launchctl and persist it in a LaunchAgent that re-applies it at login.
set_env_macos() {
  # GUI apps take their environment from the launchd session, not from the shell.
  run $SUDO launchctl asuser "$TARGET_UID" launchctl setenv NODE_EXTRA_CA_CERTS "$CA_FILE_USER" 2>/dev/null || true

  run $SUDO mkdir -p "$(dirname "$LAUNCH_AGENT")"
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "  [dry-run] write $LAUNCH_AGENT"
  else
    $SUDO tee "$LAUNCH_AGENT" >/dev/null <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${LAUNCH_AGENT_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/sh</string>
    <string>-c</string>
    <string>launchctl setenv NODE_EXTRA_CA_CERTS "${CA_FILE_USER}"</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
</dict>
</plist>
PLIST
    $SUDO chown "$TARGET_USER" "$LAUNCH_AGENT"
  fi
  # (re)load it into the user's GUI session so the value applies before the next login
  run $SUDO launchctl asuser "$TARGET_UID" launchctl bootout "gui/$TARGET_UID/$LAUNCH_AGENT_LABEL" 2>/dev/null || true
  run $SUDO launchctl asuser "$TARGET_UID" launchctl bootstrap "gui/$TARGET_UID" "$LAUNCH_AGENT" 2>/dev/null || \
    run $SUDO launchctl asuser "$TARGET_UID" launchctl load -w "$LAUNCH_AGENT" 2>/dev/null || true

  # Terminal-launched Cursor / cursor-agent should see it too.
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "  [dry-run] append managed export block to $SHELL_RC"
  else
    $SUDO touch "$SHELL_RC"
    $SUDO sed -i.bak "\\|^${MARK_BEGIN}$|,\\|^${MARK_END}$|d" "$SHELL_RC" 2>/dev/null || true
    printf '\n%s\n%s\n%s\n' "$MARK_BEGIN" "export NODE_EXTRA_CA_CERTS=\"$CA_FILE_USER\"" "$MARK_END" \
      | $SUDO tee -a "$SHELL_RC" >/dev/null
    $SUDO chown "$TARGET_USER" "$SHELL_RC"
  fi
}

remove_env_macos() {
  run $SUDO launchctl asuser "$TARGET_UID" launchctl bootout "gui/$TARGET_UID/$LAUNCH_AGENT_LABEL" 2>/dev/null || true
  run $SUDO rm -f "$LAUNCH_AGENT"
  run $SUDO launchctl asuser "$TARGET_UID" launchctl unsetenv NODE_EXTRA_CA_CERTS 2>/dev/null || true
  if [[ -f "$SHELL_RC" ]]; then
    run $SUDO sed -i.bak "\\|^${MARK_BEGIN}$|,\\|^${MARK_END}$|d" "$SHELL_RC" 2>/dev/null || true
  fi
}

# --------------------------------------------------------------------------
if [[ "$UNINSTALL" == "1" ]]; then
  echo "== removing hosts block"
  strip_block
  flush_dns_macos

  echo "== removing CA from the trust store"
  case "$OS" in
    Linux)
      if [[ -f "$CA_FILE_LINUX" ]]; then
        run $SUDO rm -f "$CA_FILE_LINUX"
        if command -v update-ca-certificates >/dev/null 2>&1; then run $SUDO update-ca-certificates >/dev/null; fi
        if command -v update-ca-trust >/dev/null 2>&1; then run $SUDO update-ca-trust >/dev/null; fi
      fi
      run rm -f "$ENV_DIR_CONF"
      ;;
    Darwin)
      untrust_ca_macos
      remove_env_macos
      ;;
  esac
  run rm -f "$CA_FILE_USER"
  echo "done. restart Cursor."
  exit 0
fi

echo "== 1/4 download CA"
TMP_CA="$(mktemp)"
trap 'rm -f "$TMP_CA"' EXIT

print_plan() {
  echo "== redirect plan"
  # shellcheck disable=SC2086
  for h in $HOSTNAMES; do
    printf '   %-42s -> %s\n' "$h" "$PROXY_IP"
  done
  echo "   hosts file: $HOSTS"
  echo "   CA source:  $CA_URL"
  echo "   CA target:  $CA_FILE_USER"
  echo "   note: repository traffic (repo42) is gRPC over HTTP/2; api2 is the"
  echo "         extension's HTTP/1.1 fallback host and is redirected too."
}

if [[ "$DRY_RUN" == "1" ]]; then
  print_plan
  echo "   [dry-run] download $CA_URL -> $CA_FILE_USER (skipped)"
else
  curl -fsSL "$CA_URL" -o "$TMP_CA"
  openssl x509 -in "$TMP_CA" -noout -subject -enddate 2>/dev/null | sed 's/^/   /' || true
fi

echo "== 2/4 install CA into system trust store"
case "$OS" in
  Linux) trust_ca_linux "$TMP_CA" ;;
  Darwin) trust_ca_macos "$TMP_CA" ;;
esac
if [[ "$DRY_RUN" == "1" ]]; then
  echo "  [dry-run] copy CA to $CA_FILE_USER"
else
  $SUDO cp "$TMP_CA" "$CA_FILE_USER"
  $SUDO chown "$TARGET_USER" "$CA_FILE_USER"
  $SUDO chmod 644 "$CA_FILE_USER"
fi

echo "== 3/4 point Cursor backend hosts to $PROXY_IP"
strip_block
if [[ "$DRY_RUN" == "1" ]]; then
  echo "   [dry-run] append hosts block for $HOST_COUNT hostnames to $HOSTS"
else
  printf "\n%s\n%s %s\n%s\n" "$MARK_BEGIN" "$PROXY_IP" "$HOSTNAMES" "$MARK_END" | $SUDO tee -a "$HOSTS" >/dev/null
fi
flush_dns_macos

echo "== 4/4 export NODE_EXTRA_CA_CERTS for the desktop session"
case "$OS" in
  Linux) set_env_linux ;;
  Darwin) set_env_macos ;;
esac

echo
echo "== verify"
if [[ "$DRY_RUN" == "1" ]]; then
  echo "   [dry-run] skipped; plan above lists every redirected host and the CA path"
else
  ok=0
  bad=0
  # shellcheck disable=SC2086
  for h in $HOSTNAMES; do
    if command -v getent >/dev/null 2>&1; then
      ip="$(getent hosts "$h" 2>/dev/null | awk 'NR==1{print $1}')"
    else
      ip="$(dscacheutil -q host -a name "$h" 2>/dev/null | awk '/ip_address:/{print $2; exit}')"
    fi
    if [[ "$ip" == "$PROXY_IP" ]]; then
      printf '   dns: %-42s -> %s\n' "$h" "$ip"
      ok=$((ok+1))
    else
      printf '   dns: %-42s -> %s (expected %s)\n' "$h" "${ip:-none}" "$PROXY_IP"
      bad=$((bad+1))
    fi
  done
  echo "   dns: $ok/$HOST_COUNT hostnames redirected, $bad mismatched"

  # One representative per traffic class. curl validates the server cert SAN
  # against the installed CA, so this also proves the cert covers the new names.
  for h in agentn.global.api5.cursor.sh api3.cursor.sh repo42.cursor.sh; do
    code="$(curl -sS --http2 --max-time 10 --resolve "$h:443:${PROXY_IP}" \
      --cacert "$CA_FILE_USER" "https://$h/" -o /dev/null \
      -w '%{http_code}' 2>/dev/null || echo failed)"
    if [[ "$code" == "failed" ]]; then
      echo "   tls: $h FAILED — cert SAN/CA chain or HTTP/2 handshake"
    else
      echo "   tls: $h ok (http/2, SAN + CA chain, status $code)"
    fi
  done
  # Cursor's agent host is a Node process. Prove that its own runtime trusts the CA
  # even when the System keychain could not be touched (headless install).
  if [[ "$OS" == "Darwin" && -x /Applications/Cursor.app/Contents/MacOS/Cursor ]]; then
    probe='const https=require("https");const r=https.get("https://agentn.api5.cursor.sh/",{timeout:8000},(x)=>{console.log(x.statusCode);process.exit(0)});r.on("error",e=>{console.log(e.code||e.message);process.exit(1)});r.on("timeout",()=>{console.log("timeout");process.exit(1)})'
    out=$(NODE_EXTRA_CA_CERTS="$CA_FILE_USER" ELECTRON_RUN_AS_NODE=1 \
      /Applications/Cursor.app/Contents/MacOS/Cursor -e "$probe" 2>/dev/null || true)
    case "$out" in
      404|200) echo "   cursor runtime: node TLS ok ($out)" ;;
      *) echo "   cursor runtime: TLS failed (${out:-no output}) — Cursor will not reach the proxy" ;;
    esac
  fi
fi

echo
echo "Done."
echo "  hosts:  $HOSTS"
echo "  CA:     $CA_FILE_USER (installed; NODE_EXTRA_CA_CERTS points at it)"
echo "  proxy:  https://$PROXY_IP"
if [[ "$OS" == "Darwin" ]]; then
  echo "Quit and reopen Cursor (Cmd-Q, then launch it again)."
else
  echo "Log out/in (or reboot) so GUI apps inherit NODE_EXTRA_CA_CERTS, then restart Cursor."
fi
echo "Revert: sudo bash install.sh --uninstall"
