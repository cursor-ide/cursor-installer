# cursor-byok bootstrap

One-line installer that points **Cursor** at your own OpenAI-compatible backend
without patching Cursor's installation files.

It does two things on the client machine:

1. adds a managed block to the system `hosts` file so Cursor's agent hostnames
   (`*.api5.cursor.sh`) resolve to your proxy IP;
2. installs the proxy's local CA into the OS trust store and exports
   `NODE_EXTRA_CA_CERTS` so Cursor's Node-based agent host trusts the proxy's TLS
   certificate.

Because nothing inside `Cursor.app` / `Program Files\cursor` is modified, a Cursor
update does not undo the redirect (you may only need to add newly introduced
hostnames — see [Maintenance](#maintenance)).

Default proxy: `203.0.113.10` (override with `-Ip` / `--ip` or `CURSOR_PROXY_IP`).

---

## Quick start

### Linux (and macOS, untested)

```bash
curl -fsSL https://raw.githubusercontent.com/cursor-ide/cursor-installer/main/install.sh | sudo bash
```

With a custom proxy IP:

```bash
curl -fsSL https://raw.githubusercontent.com/cursor-ide/cursor-installer/main/install.sh | sudo bash -s -- --ip 203.0.113.10
```

### Windows (PowerShell **as Administrator**)

```powershell
irm https://raw.githubusercontent.com/cursor-ide/cursor-installer/main/install.ps1 | iex
```

With a custom proxy IP:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/cursor-ide/cursor-installer/main/install.ps1))) -Ip 203.0.113.10
```

Then **restart Cursor**. On Linux, log out and back in once (or reboot) so the
desktop session inherits `NODE_EXTRA_CA_CERTS`.

---

## Requirements

* Cursor installed.
* Windows: an **elevated** PowerShell (Run as Administrator).
* Linux/macOS: run with `sudo`.
* Outbound HTTPS to the proxy IP.
* The proxy must be running and serve:
  * `GET /ca.crt` — the CA certificate (plain HTTP on port 80 is fine), and
  * the agent service over HTTP/2 + TLS on port 443.
* Administrator/root rights to edit `hosts` and the trust store.

---

## What gets changed

| Platform | hosts | trust store | env |
| --- | --- | --- | --- |
| Linux | `/etc/hosts` (managed block) | `/usr/local/share/ca-certificates/cursor-byok-ca.crt` + `update-ca-certificates` | `~/.config/environment.d/99-cursor-byok.conf` and `systemctl --user set-environment` |
| Windows | `%SystemRoot%\System32\drivers\etc\hosts` (managed block) | `LocalMachine\Root` via `certutil -addstore` | user `NODE_EXTRA_CA_CERTS` → `%ProgramData%\cursor-byok\ca-combined.pem` |
| macOS | `/private/etc/hosts` (managed block) | System keychain via `security add-trusted-cert` | `~/.config/environment.d` (best effort) |

The hosts entries live between two markers and are rewritten on every run:

```
# BEGIN cursor-byok
<proxy-ip> agent.api5.cursor.sh agentn.api5.cursor.sh ... agentn.global.api5.cursor.sh
# END cursor-byok
```

Hostnames covered:

* `agent.api5.cursor.sh`, `agentn.api5.cursor.sh`
* `agent-gcpp-uswest.api5.cursor.sh`, `agentn-gcpp-uswest.api5.cursor.sh`
* `agentn-gcpp-eucentral.api5.cursor.sh`, `agentn-gcpp-apsoutheast.api5.cursor.sh`
* `agent.global.api5.cursor.sh`, `agentn.global.api5.cursor.sh`
* `agentn-gcpp-uswest.global.api5.cursor.sh`, `agent-gcpp-uswest.global.api5.cursor.sh`
* `agentn-gcpp-eucentral.global.api5.cursor.sh`, `agentn-gcpp-apsoutheast.global.api5.cursor.sh`

---

## Verify

After restarting Cursor, open a chat and send a message. On the proxy you should see
`POST /agent.v1.AgentService/Run` and the model being proxied.

Quick connectivity check (Linux/macOS):

```bash
getent hosts agentn.global.api5.cursor.sh     # should print the proxy IP
curl -sS --cacert cursor-byok-ca.crt https://agentn.global.api5.cursor.sh/ -o /dev/null -w '%{http_code}\n'
```

Windows:

```powershell
Resolve-DnsName agentn.global.api5.cursor.sh -Type A | Select-Object -First 1 IPAddress
```

---

## Uninstall

Linux/macOS:

```bash
curl -fsSL https://raw.githubusercontent.com/cursor-ide/cursor-installer/main/install.sh | sudo bash -s -- --uninstall
```

Windows (elevated):

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/cursor-ide/cursor-installer/main/install.ps1))) -Uninstall
```

This removes the hosts block, the CA from the trust store and the env var/file.
On Windows the installer remembers your previous `NODE_EXTRA_CA_CERTS` value
(for example a Charles/Proxyman bundle) and restores it instead of clearing it.
Restart Cursor afterwards.

---

## Maintenance

Cursor occasionally introduces new agent hostnames (for example 3.29 moved to
`*.global.api5.cursor.sh`). If chat stops reaching your proxy after an update:

1. check which hostname is contacted (proxy logs, or `Resolve-DnsName` on Windows);
2. add it to the `Hostnames` list in `install.sh` / `install.ps1` and re-run the
   installer.

Because the Cursor installation itself is untouched, updates no longer undo the
redirect — only the hostname list may need refreshing.

## Troubleshooting

* **Cursor shows "Agent and Edit rely on custom models that require a paid subscription"**
  — traffic is still reaching Cursor. Check that every agent hostname resolves to the
  proxy (`Resolve-DnsName agentn.global.api5.cursor.sh` on Windows,
  `getent hosts agentn.global.api5.cursor.sh` on Linux). New Cursor versions may add
  hostnames; update the `Hostnames` list and re-run the installer.
* **TLS error `self signed certificate in certificate chain`** — the CA is not trusted by
  the process. Re-run the installer and restart Cursor from a session that has
  `NODE_EXTRA_CA_CERTS` (log out/in on Linux).
* **Commands hang / "Running command" forever** — the proxy must fall back from HTTP/2
  shell streaming to plain shell execution for older Cursor builds; make sure you run a
  current proxy image.

## Security notes

* The CA private key stays on the proxy; clients only receive the certificate.
* The managed hosts block is easy to audit and remove (`--uninstall`).
* Anyone with access to the proxy has access to the API keys configured on it —
  keep the proxy and its credentials private.
