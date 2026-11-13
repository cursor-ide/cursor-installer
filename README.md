# cursor-backend bootstrap

One-line installer that points **Cursor** at your own OpenAI-compatible backend
without patching Cursor's installation files.

It does two things on the client machine:

1. adds a managed block to the system `hosts` file so Cursor agent hostnames
   resolve to your proxy IP — agent hosts (`*.api5.cursor.sh`), telemetry
   (`api3.cursor.sh`), repository ingestion (`repo42.cursor.sh`), and `api2*`
   (`api2` / `api2geo` / `api2direct`) so PrivateInference AdmitRun/ReportUsage
   and local Plan & Usage stubs stay on the proxy instead of Cursor origin;
2. installs the proxy's local CA into the OS trust store and exports
   `NODE_EXTRA_CA_CERTS` so Cursor's Node-based agent host trusts the proxy's TLS
   certificate.

Because nothing inside `Cursor.app` / `Program Files\cursor` is modified, a Cursor
update does not undo the redirect (you may only need to add newly introduced
hostnames — see [Maintenance](#maintenance)).

Proxy IP is **required** (`-Ip` / `--ip` or `CURSOR_PROXY_IP`). There is no
hardcoded default in the repo.

Pinned to release **v1.0.0** (immutable, CDN-friendly). Replace `v1.0.0` with `main`
if you want the latest commit instead of a release.

---

## Quick start

### Linux and macOS

```bash
curl -fsSL https://raw.githubusercontent.com/cursor-ide/cursor-installer/v1.0.0/install.sh \
  | sudo bash -s -- --ip "$CURSOR_PROXY_IP"
```

Example:

```bash
curl -fsSL https://raw.githubusercontent.com/cursor-ide/cursor-installer/v1.0.0/install.sh \
  | sudo bash -s -- --ip 203.0.113.10
```

### Windows (PowerShell **as Administrator**)

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/cursor-ide/cursor-installer/v1.0.0/install.ps1))) -Ip $env:CURSOR_PROXY_IP
```

Example:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/cursor-ide/cursor-installer/v1.0.0/install.ps1))) -Ip 203.0.113.10
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
  -k /Library/Keychains/System.keychain ~/.cursor-backend-ca.crt
# or: open ~/.cursor-backend-ca.crt in Keychain Access and set "Always Trust"
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
| Linux | `/etc/hosts` (managed block) | `/usr/local/share/ca-certificates/cursor-backend-ca.crt` + `update-ca-certificates` | `~/.config/environment.d/99-cursor-backend.conf` and `systemctl --user set-environment` |
| Windows | `%SystemRoot%\System32\drivers\etc\hosts` (managed block) | `LocalMachine\Root` via `certutil -addstore` | user `NODE_EXTRA_CA_CERTS` → `%ProgramData%\cursor-backend\ca-combined.pem` |
| macOS | `/private/etc/hosts` (managed block) | System keychain via `security add-trusted-cert` (needs an interactive approval; best effort over SSH) | `launchctl setenv` in the GUI session + `~/Library/LaunchAgents/net.cursor-ide.cursor-backend.plist` + managed block in `~/.zprofile` |

The hosts entries live between two markers and are rewritten on every run:

```
# BEGIN cursor-backend
# api2* redirected: AdmitRun/ReportUsage must not meter Cursor Included Usage.
<proxy-ip> agent.api5.cursor.sh ...            # at most 9 names per line
<proxy-ip> ... repo42.cursor.sh api3.cursor.sh
  api2.cursor.sh api2geo.cursor.sh api2direct.cursor.sh
# END cursor-backend
```

Windows applies only the first 9 names on a hosts line and ignores the rest.
The installer writes one IP line per 9 names, on every platform.

Hostnames covered:

**Agent traffic** (`agent.v1.AgentService`, `aiserver.v1.InferenceService`,
`CmdKService`, Cpp):

* `agent.api5.cursor.sh`, `agentn.api5.cursor.sh`
* `agent-gcpp-uswest.api5.cursor.sh`, `agentn-gcpp-uswest.api5.cursor.sh`
* `agentn-gcpp-eucentral.api5.cursor.sh`, `agentn-gcpp-apsoutheast.api5.cursor.sh`
* `agent.global.api5.cursor.sh`, `agentn.global.api5.cursor.sh`
* `agentn-gcpp-uswest.global.api5.cursor.sh`, `agent-gcpp-uswest.global.api5.cursor.sh`
* `agentn-gcpp-eucentral.global.api5.cursor.sh`, `agentn-gcpp-apsoutheast.global.api5.cursor.sh`

**Account + private-inference metering** (`backendUrl` / CNAME chain):

* `api2.cursor.sh`, `api2geo.cursor.sh`, `api2direct.cursor.sh` — pointed at the
  proxy. Local stubs answer `PrivateInferenceService` (`AdmitRun` always admits,
  `ReportUsage` discards meters) and the truthful `DashboardService` subset
  (including `GetCurrentPeriodUsage`), so local-loop turns do not burn Cursor
  Included Usage and Plan & Usage reflects the proxy's local numbers.

**Telemetry** (`telemBackendUrl`: `AnalyticsService`, `MetricsService`,
`TraceService`, `SubmitLogs`, and related services):

* `api3.cursor.sh` — pointed at the VPS public IP. nginx terminates TLS and
  routes those RPCs to the `telemetry-receiver` on `127.0.0.1:18198`. The
  receiver acks locally (same shapes as the proxy stubs) and, when
  `TELEMETRY_CAPTURE=1`, writes decoded rows to `telemetry.db`. It does not
  forward to Cursor origin. Agent / CmdK traffic stays on the proxy path.

**Repository ingestion** (`aiserver.v1.RepositoryService`):

* `repo42.cursor.sh` (HTTP/2 gRPC)

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

* Agent, inference, CmdK, RepositoryService and api2 (Dashboard /
  PrivateInference) traffic is gRPC and must reach the backend over HTTP/2
  (`listen 443 ssl http2` + `grpc_pass`).
* Telemetry on `api3.cursor.sh` is Connect unary (`application/proto`); nginx
  may `proxy_pass` those paths over HTTP/1.1 to the telemetry receiver while
  everything else stays on `grpc_pass`.
* `repo42.cursor.sh` is the repository path that must work; it uses HTTP/2.
* `api2.cursor.sh` (plus geo/direct CNAMEs) must be in the hosts block so
  AdmitRun/ReportUsage and Plan & Usage hit the proxy stubs.

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
curl -fsSL https://raw.githubusercontent.com/cursor-ide/cursor-installer/v1.0.0/install.sh \
  | sudo bash -s -- --ip "$CURSOR_PROXY_IP" --dry-run
```

```powershell
# Windows
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/cursor-ide/cursor-installer/v1.0.0/install.ps1))) -Ip $env:CURSOR_PROXY_IP -DryRun
```

After restarting Cursor, open a chat and send a message. On the proxy you should see
`POST /agent.v1.AgentService/Run` (or `InferenceService/RunInference`) and the model
being proxied, plus `[private-inference] method=AdmitRun` / `ReportUsage` when the
local loop meters a turn. Repository and Dashboard calls appear as their own RPCs.

The installer ends with its own checks: DNS resolution for every redirected host,
TLS requests (with the installed CA) to one representative each for agent, dashboard
and repository traffic, and (on macOS) a request made by Cursor's own Electron/Node
runtime, which is the process that actually calls the proxy.

Manual check (Linux/macOS):

```bash
getent hosts agentn.global.api5.cursor.sh     # Linux; macOS: dscacheutil -q host -a name agentn.global.api5.cursor.sh
curl -sS --cacert ~/.cursor-backend-ca.crt https://agentn.global.api5.cursor.sh/ -o /dev/null -w '%{http_code}\n'
# new names — TLS SAN check proves the cert covers them
curl -sS --http2 --cacert ~/.cursor-backend-ca.crt https://api3.cursor.sh/ -o /dev/null -w '%{http_code}\n'
curl -sS --http2 --cacert ~/.cursor-backend-ca.crt https://repo42.cursor.sh/ -o /dev/null -w '%{http_code}\n'
# macOS: prove Cursor's runtime trusts the CA
NODE_EXTRA_CA_CERTS=~/.cursor-backend-ca.crt ELECTRON_RUN_AS_NODE=1 \
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
curl -fsSL https://raw.githubusercontent.com/cursor-ide/cursor-installer/v1.0.0/install.sh \
  | sudo bash -s -- --uninstall
```

Windows (elevated):

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/cursor-ide/cursor-installer/v1.0.0/install.ps1))) -Uninstall
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
  `getent hosts agentn.global.api5.cursor.sh` on Linux). On Windows, only the first
  9 names on a hosts line are applied; keep the managed block split that way.
  New Cursor versions may add hostnames; update the `Hostnames` list and re-run
  the installer.
* **TLS error `self signed certificate in certificate chain`** — the CA is not trusted by
  the process. Re-run the installer and restart Cursor from a session that has
  `NODE_EXTRA_CA_CERTS` (log out/in on Linux; on macOS check
  `launchctl getenv NODE_EXTRA_CA_CERTS` inside the GUI session).
* **macOS: chat fails but `curl` works** — Cursor was still running when the installer
  set the environment. Quit it (Cmd-Q, not just closing the window) and reopen, or run
  `sudo security add-trusted-cert …` in Terminal.app to trust the CA system-wide.
* **"Local loop can't run this model … no prompt metadata"** — rare with a current
  proxy image: the proxy already sends minimal `RunInference` prompt metadata for
  local-loop accounts. If you still see this, update the proxy and confirm
  `UPSTREAM_BASE_URL` / `UPSTREAM_API_KEY` are set (see
  [Model selection](#model-selection-important)).
* **Commands hang / "Running command" forever** — the proxy must fall back from HTTP/2
  shell streaming to plain shell execution for older Cursor builds; make sure you run a
  current proxy image.

## Model selection (important)

The redirect only changes *where* Cursor sends agent and model-catalog traffic.
Which model id runs is still chosen in the Cursor UI.

With a current `cursor-backend` image you do **not** need to add a separate
OpenAI-compatible “custom model” in Settings for local-loop accounts to work:

* The proxy answers `AiService/AvailableModels` and `AgentService/GetUsableModels`
  from the same catalog (`USABLE_MODELS`, or `upstream`/`*` → provider `/models`,
  else `DEFAULT_MODEL`).
* For `agent_host_local_loop`, `InferenceService/RunInference` includes minimal
  prompt metadata (`vendor=openai`, `prompt_version=latest`, resolved model id,
  mode ids). Chat can start without a client-side custom-model entry.
* The proxy then calls your OpenAI-compatible upstream. Set `UPSTREAM_BASE_URL`
  and `UPSTREAM_API_KEY` on the proxy. If the client sends no model id, the proxy
  uses `DEFAULT_MODEL`.

What to do on the client:

1. Open Settings → Models and confirm the listed ids match the proxy catalog
   (not only Cursor’s stock cloud models).
2. Start a **new** chat and pick one of those ids before sending.
3. Optional: if you configure BYOK fields in Cursor (base URL + key on the
   model), those still win over the proxy env pair for that turn.

If chat still fails with “no prompt metadata”, upgrade the proxy image first —
do not treat “Add custom model” as the primary fix anymore.

## Security notes

* The CA private key stays on the proxy; clients only receive the certificate.
* The managed hosts block is easy to audit and remove (`--uninstall`).
* Anyone with access to the proxy has access to the API keys configured on it —
  keep the proxy and its credentials private.
