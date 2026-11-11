# cursor-byok bootstrap

One-line installer that points **Cursor** at your own OpenAI-compatible backend
without patching Cursor's installation files.

It does two things on the client machine:

1. adds a managed block to the system `hosts` file so every Cursor backend
   hostname resolves to your proxy IP — agent hosts (`*.api5.cursor.sh`), the
   account/dashboard host (`api3.cursor.sh`) and the repository hosts
   (`repo42.cursor.sh`, `api2.cursor.sh`);
2. installs the proxy's local CA into the OS trust store and exports
   `NODE_EXTRA_CA_CERTS` so Cursor's Node-based agent host trusts the proxy's TLS
   certificate.

Because nothing inside `Cursor.app` / `Program Files\cursor` is modified, a Cursor
update does not undo the redirect (you may only need to add newly introduced
hostnames — see [Maintenance](#maintenance)).

Proxy IP is **required** (`-Ip` / `--ip` or `CURSOR_PROXY_IP`). There is no
hardcoded default in the repo.

Pinned to release **v1.1.1** (immutable, CDN-friendly). Replace `v1.1.1` with `main`
if you want the latest commit instead of a release.

---

## Quick start

### Linux and macOS

```bash
curl -fsSL https://raw.githubusercontent.com/cursor-ide/cursor-installer/v1.1.1/install.sh \
  | sudo bash -s -- --ip "$CURSOR_PROXY_IP"
```

Example:

```bash
curl -fsSL https://raw.githubusercontent.com/cursor-ide/cursor-installer/v1.1.1/install.sh \
  | sudo bash -s -- --ip 203.0.113.10
```

### Windows (PowerShell **as Administrator**)

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/cursor-ide/cursor-installer/v1.1.1/install.ps1))) -Ip $env:CURSOR_PROXY_IP
```

Example:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/cursor-ide/cursor-installer/v1.1.1/install.ps1))) -Ip 203.0.113.10
```

Then **restart Cursor**. On Linux, log out and back in once (or reboot) so the
desktop session inherits `NODE_EXTRA_CA_CERTS`. On macOS, quit Cursor (Cmd-Q) and
open it again; the installer already set the variable in the GUI session.

### macOS notes

macOS needs one interactive approval to add a root CA to the **System** keychain, and
the Security framework denies it when the script runs over plain SSH. The installer
therefore treats that step as best effort:

* if you run it from **Terminal.app** on the Mac, macOS shows the authorization dialog
  and the CA becomes system-trusted;
* over SSH (no GUI prompt) it prints the exact command to run later, and continues:
  Cursor's agent host is a Node process and trusts `NODE_EXTRA_CA_CERTS`, which is
  exported through `launchctl` plus a login LaunchAgent. That is enough for chat and
  the agent tool loop.

To trust it system-wide afterwards:

```bash
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain ~/.cursor-byok-ca.crt
# or: open ~/.cursor-byok-ca.crt in Keychain Access and set "Always Trust"
```

---

## Requirements

* Cursor installed.
* Windows: an **elevated** PowerShell (Run as Administrator).
* Linux/macOS: run with `sudo`.
* Outbound HTTPS to the proxy IP.
* The proxy must be running and serve:
  * `GET /ca.crt` — the CA certificate (plain HTTP on port 80 is fine), and
  * every hostname listed below over TLS on port 443, with a server certificate
    whose SAN list covers those names. Agent, dashboard and repository calls are
    gRPC and need HTTP/2; see [Backend requirements](#backend-requirements).
* Administrator/root rights to edit `hosts` and the trust store.

---

## What gets changed

| Platform | hosts | trust store | env |
| --- | --- | --- | --- |
| Linux | `/etc/hosts` (managed block) | `/usr/local/share/ca-certificates/cursor-byok-ca.crt` + `update-ca-certificates` | `~/.config/environment.d/99-cursor-byok.conf` and `systemctl --user set-environment` |
| Windows | `%SystemRoot%\System32\drivers\etc\hosts` (managed block) | `LocalMachine\Root` via `certutil -addstore` | user `NODE_EXTRA_CA_CERTS` → `%ProgramData%\cursor-byok\ca-combined.pem` |
| macOS | `/private/etc/hosts` (managed block) | System keychain via `security add-trusted-cert` (needs an interactive approval; best effort over SSH) | `launchctl setenv` in the GUI session + `~/Library/LaunchAgents/net.cursor-ide.cursor-byok.plist` + managed block in `~/.zprofile` |

The hosts entries live between two markers and are rewritten on every run:

```
# BEGIN cursor-byok
<proxy-ip> agent.api5.cursor.sh ... api3.cursor.sh repo42.cursor.sh api2.cursor.sh
# END cursor-byok
```

Hostnames covered:

**Agent traffic** (`agent.v1.AgentService`, `aiserver.v1.InferenceService`,
`CmdKService`, Cpp):

* `agent.api5.cursor.sh`, `agentn.api5.cursor.sh`
* `agent-gcpp-uswest.api5.cursor.sh`, `agentn-gcpp-uswest.api5.cursor.sh`
* `agentn-gcpp-eucentral.api5.cursor.sh`, `agentn-gcpp-apsoutheast.api5.cursor.sh`
* `agent.global.api5.cursor.sh`, `agentn.global.api5.cursor.sh`
* `agentn-gcpp-uswest.global.api5.cursor.sh`, `agent-gcpp-uswest.global.api5.cursor.sh`
* `agentn-gcpp-eucentral.global.api5.cursor.sh`, `agentn-gcpp-apsoutheast.global.api5.cursor.sh`

**Account / membership / usage** (`aiserver.v1.DashboardService`: `GetMe`,
`GetPlanInfo`, `GetCurrentPeriodUsage`, `GetHardLimit`, `GetMonthlyBillingCycle`,
`GetTeams`, `GetUserPrivacyMode`, `GetUsageBasedPremiumRequests`):

* `api3.cursor.sh` — also the telemetry host (`telemBackendUrl`: `AnalyticsService`,
  `MetricsService`, `TraceService`, `SubmitLogs`). The hosts block points it at
  the proxy on purpose. Those RPCs are not implemented; the proxy log line
  includes `rpc=… telemetry=1` so a client error can be tied to the request.

**Repository ingestion** (`aiserver.v1.RepositoryService`):

* `repo42.cursor.sh` (primary, HTTP/2 gRPC)
* `api2.cursor.sh` (the retrieval extension's HTTP/1.1 fallback)

---

## Backend requirements

### Certificate and SANs

The server certificate must include a SAN for every hostname above. In
`cursor-backend`, `tools/vps/deploy-vps.sh` writes `san.cnf` with `api2`, `api3`,
`api4`, `repo42`, `*.api5.cursor.sh`, `*.global.api5.cursor.sh` and the proxy IP, so
re-running that script is enough to cover the new names. The CA is only created
when `/etc/nginx/ssl/cursor/ca.key` is absent; the server key and certificate are
reissued on every run. Remove or rotate `ca.key` to mint a new CA, then re-run
this installer on every client. Certs are not per-name — there is one SAN
certificate for all names. It is issued for 3650 days, so no scheduled renewal is
required; rotate manually before expiry.

### HTTP/2 vs HTTP/1.1

* Agent, inference, CmdK, DashboardService and RepositoryService traffic is gRPC
  and must reach the backend over HTTP/2 (`listen 443 ssl http2` + `grpc_pass`).
* `repo42.cursor.sh` is the repository path that must work; it uses HTTP/2.
* `api2.cursor.sh` is only the extension's HTTP/1.1 fallback. nginx `grpc_pass`
  accepts HTTP/2 only, so the fallback cannot use the same location: it needs a
  separate `proxy_pass http://127.0.0.1:8099` location (with
  `proxy_http_version 1.1`) if the backend accepts HTTP/1.1 there. If it does not,
  repository ingestion still works over `repo42.cursor.sh`, and only the fallback
  path is unavailable.

### Environment (proxy host)

* `REPO_STORE_DIR` — directory where the backend stores repository snapshots and
  index state. Create it writable by the proxy container/user and keep it on a
  persistent volume so indexes survive container restarts.
* `PROXY_TOKEN` — shared secret checked by the backend (`x-proxy-token`). Cursor
  cannot add that header, so when it is set nginx must inject it upstream:
  `grpc_set_header x-proxy-token <value>;` (or the backend must exempt the client
  path). Never put the token in this repository or in a client installer.

Both variables belong to the backend deployment, not to the client machine.

---

## Verify

Preview without changing anything (lists every redirected host, the hosts file and
the CA path):

```bash
# Linux / macOS
curl -fsSL https://raw.githubusercontent.com/cursor-ide/cursor-installer/v1.1.1/install.sh \
  | sudo bash -s -- --ip "$CURSOR_PROXY_IP" --dry-run
```

```powershell
# Windows
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/cursor-ide/cursor-installer/v1.1.1/install.ps1))) -Ip $env:CURSOR_PROXY_IP -DryRun
```

After restarting Cursor, open a chat and send a message. On the proxy you should see
`POST /agent.v1.AgentService/Run` and the model being proxied. Account and repository
calls appear as `DashboardService` and `RepositoryService` RPCs.

The installer ends with its own checks: DNS resolution for every redirected host,
TLS requests (with the installed CA) to one representative each for agent, dashboard
and repository traffic, and (on macOS) a request made by Cursor's own Electron/Node
runtime, which is the process that actually calls the proxy.

Manual check (Linux/macOS):

```bash
getent hosts agentn.global.api5.cursor.sh     # Linux; macOS: dscacheutil -q host -a name agentn.global.api5.cursor.sh
curl -sS --cacert ~/.cursor-byok-ca.crt https://agentn.global.api5.cursor.sh/ -o /dev/null -w '%{http_code}\n'
# new names — TLS SAN check proves the cert covers them
curl -sS --http2 --cacert ~/.cursor-byok-ca.crt https://api3.cursor.sh/ -o /dev/null -w '%{http_code}\n'
curl -sS --http2 --cacert ~/.cursor-byok-ca.crt https://repo42.cursor.sh/ -o /dev/null -w '%{http_code}\n'
# macOS: prove Cursor's runtime trusts the CA
NODE_EXTRA_CA_CERTS=~/.cursor-byok-ca.crt ELECTRON_RUN_AS_NODE=1 \
  /Applications/Cursor.app/Contents/MacOS/Cursor -e \
  'require("https").get("https://agentn.global.api5.cursor.sh/",r=>{console.log(r.statusCode);process.exit(0)}).on("error",e=>{console.log(e.code);process.exit(1)})'
```

Windows:

```powershell
Resolve-DnsName agentn.global.api5.cursor.sh -Type A | Select-Object -First 1 IPAddress
```

---

## Uninstall

Linux/macOS (also removes the macOS LaunchAgent and `~/.zprofile` block):

```bash
curl -fsSL https://raw.githubusercontent.com/cursor-ide/cursor-installer/v1.1.1/install.sh \
  | sudo bash -s -- --uninstall
```

Windows (elevated):

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/cursor-ide/cursor-installer/v1.1.1/install.ps1))) -Uninstall
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
  `NODE_EXTRA_CA_CERTS` (log out/in on Linux; on macOS check
  `launchctl getenv NODE_EXTRA_CA_CERTS` inside the GUI session).
* **macOS: chat fails but `curl` works** — Cursor was still running when the installer
  set the environment. Quit it (Cmd-Q, not just closing the window) and reopen, or run
  `sudo security add-trusted-cert …` in Terminal.app to trust the CA system-wide.
* **"Local loop can't run this model … no prompt metadata"** — the account is on Cursor's
  local agent loop. Select an OpenAI-compatible custom model (see
  [Model selection](#model-selection-important)); the proxy cannot emulate vendor
  prompt metadata.
* **Commands hang / "Running command" forever** — the proxy must fall back from HTTP/2
  shell streaming to plain shell execution for older Cursor builds; make sure you run a
  current proxy image.

## Model selection (important)

The redirect only changes where Cursor sends its agent traffic. Cursor still decides
*which model* to run, and for some accounts it runs the agent loop locally
(`agent_host_local_loop`), requesting vendor prompt metadata from the backend. A
self-hosted proxy cannot provide vendor metadata, so those accounts fail with:

```
Local loop can't run this model
The server sent no prompt metadata for "<model>"
```

Fix: add and select an **OpenAI-compatible custom model** in Cursor
(Settings → Models → Add model, base URL = your provider, e.g.
`https://api.example.com/v1`, plus its API key). With a custom model selected,
Cursor uses the backend loop, and chat plus the tool loop work through the proxy.
Pick that model in a new chat before testing.

## Security notes

* The CA private key stays on the proxy; clients only receive the certificate.
* The managed hosts block is easy to audit and remove (`--uninstall`).
* Anyone with access to the proxy has access to the API keys configured on it —
  keep the proxy and its credentials private.
