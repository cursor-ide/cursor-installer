#requires -Version 5
<#
  Cursor BYOK bootstrap (Windows).

    irm https://raw.githubusercontent.com/cursor-ide/cursor-installer/main/install.ps1 | iex

  Optional:
    & ([scriptblock]::Create((irm ...))) -Ip 1.2.3.4
    & ([scriptblock]::Create((irm ...))) -Uninstall
    & ([scriptblock]::Create((irm ...))) -DryRun
#>
param(
  [string]$Ip = $(if ($env:CURSOR_PROXY_IP) { $env:CURSOR_PROXY_IP } else { "" }),
  [string]$CaUrl = "",
  [switch]$Uninstall,
  [switch]$DryRun
)

if (-not $Uninstall -and [string]::IsNullOrWhiteSpace($Ip)) {
  throw "Set -Ip <addr> or env CURSOR_PROXY_IP (no default IP in the repo)."
}

$ErrorActionPreference = "Stop"
$MarkBegin = "# BEGIN cursor-backend"
$MarkEnd = "# END cursor-backend"
$HostsPath = Join-Path $env:SystemRoot "System32\drivers\etc\hosts"
$WorkDir = Join-Path $env:ProgramData "cursor-backend"
$CaFile = Join-Path $WorkDir "ca.crt"
$CombinedPem = Join-Path $WorkDir "ca-combined.pem"
$BasePem = Join-Path $WorkDir "base-ca.pem"
$EnvOriginal = Join-Path $WorkDir "env-original.txt"

# Windows DNS client applies only the first 9 names on a single hosts line.
# api2* must hit the proxy: PrivateInferenceService AdmitRun/ReportUsage otherwise
# meters Included Usage on Cursor origin even when the model runs locally.
$HostsPerLine = 9
$Hostnames = @(
  "agent.api5.cursor.sh", "agentn.api5.cursor.sh",
  "agent-gcpp-uswest.api5.cursor.sh", "agentn-gcpp-uswest.api5.cursor.sh",
  "agentn-gcpp-eucentral.api5.cursor.sh", "agentn-gcpp-apsoutheast.api5.cursor.sh",
  "agent.global.api5.cursor.sh", "agentn.global.api5.cursor.sh",
  "agentn-gcpp-uswest.global.api5.cursor.sh", "agent-gcpp-uswest.global.api5.cursor.sh",
  "agentn-gcpp-eucentral.global.api5.cursor.sh", "agentn-gcpp-apsoutheast.global.api5.cursor.sh",
  "repo42.cursor.sh",
  # Telemetry (telemBackendUrl) — VPS nginx → telemetry-receiver local-ack.
  "api3.cursor.sh",
  # Account + private-inference metering (backendUrl / CNAME chain).
  "api2.cursor.sh", "api2geo.cursor.sh", "api2direct.cursor.sh"
)

$url = if ($CaUrl) { $CaUrl } else { "http://$Ip/ca.crt" }

function Test-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $pr = New-Object Security.Principal.WindowsPrincipal($id)
  return $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if ($DryRun) {
  Write-Host "== redirect plan"
  foreach ($h in $Hostnames) {
    Write-Host ("   {0,-42} -> {1}" -f $h, $Ip)
  }
  Write-Host ("   hosts file: " + $HostsPath)
  Write-Host ("   CA source:  " + $url)
  Write-Host ("   CA target:  " + $CaFile)
  Write-Host "   note: Windows applies only $HostsPerLine names per hosts line; the block is split."
  Write-Host "   note: api2* is redirected so PrivateInference AdmitRun/ReportUsage stay local."
  return
}

if (-not (Test-Admin)) {
  throw "Run this script from an elevated PowerShell (Run as Administrator)."
}

function Read-HostsText {
  if (-not (Test-Path $HostsPath)) { return "" }
  $raw = Get-Content -Path $HostsPath -Raw -ErrorAction SilentlyContinue
  if ($null -eq $raw) { return "" }
  return $raw
}

function Update-Hosts {
  $content = Read-HostsText
  $content = [regex]::Replace($content, "(?ms)^# BEGIN cursor-backend[^\r\n]*\r?\n.*?^# END cursor-backend[^\r\n]*\r?\n?", "")
  $content = $content.TrimEnd()
  if (-not $Uninstall) {
    $lines = @($MarkBegin, "# api2* redirected: AdmitRun/ReportUsage must not meter Cursor Included Usage.")
    for ($i = 0; $i -lt $Hostnames.Count; $i += $HostsPerLine) {
      $take = [Math]::Min($HostsPerLine, $Hostnames.Count - $i)
      $chunk = $Hostnames[$i..($i + $take - 1)]
      $lines += "$Ip $($chunk -join ' ')"
    }
    $lines += $MarkEnd
    $block = $lines -join "`r`n"
    $content = $content + "`r`n`r`n" + $block
  }
  $content = $content.TrimStart() + "`r`n"

  # Safety: never write a suspiciously short file.
  if ($content.Length -lt 50) {
    throw "refusing to write hosts: resulting content too short (" + $content.Length + " chars)"
  }

  Copy-Item $HostsPath "$HostsPath.bak-cursor-backend" -Force -ErrorAction SilentlyContinue
  $tmp = "$HostsPath.cursor-tmp"
  Set-Content -Path $tmp -Value $content -Encoding ASCII -NoNewline
  Move-Item -Path $tmp -Destination $HostsPath -Force
  ipconfig /flushdns | Out-Null
}

if ($Uninstall) {
  Write-Host "== removing hosts block"
  Update-Hosts
  $thumbFile = Join-Path $WorkDir "thumbprint.txt"
  $thumbprints = @()
  if (Test-Path $thumbFile) { $thumbprints += (Get-Content $thumbFile -Raw).Trim() }
  if ($thumbprints.Count -eq 0) {
    $thumbprints += (Get-ChildItem Cert:\LocalMachine\Root | Where-Object { $_.Subject -like "*Cursor*" } | ForEach-Object { $_.Thumbprint })
  }
  foreach ($t in $thumbprints) {
    if (-not $t) { continue }
    certutil -delstore Root $t | Out-Null
    Write-Host ("removed certificate " + $t)
  }
  $current = [Environment]::GetEnvironmentVariable("NODE_EXTRA_CA_CERTS", "User")
  if ($current -eq $CombinedPem) {
    $restore = ""
    if (Test-Path $EnvOriginal) { $restore = (Get-Content $EnvOriginal -Raw).Trim() }
    if ($restore) {
      [Environment]::SetEnvironmentVariable("NODE_EXTRA_CA_CERTS", $restore, "User")
      Write-Host ("restored NODE_EXTRA_CA_CERTS = " + $restore)
    } else {
      [Environment]::SetEnvironmentVariable("NODE_EXTRA_CA_CERTS", $null, "User")
      Write-Host "cleared NODE_EXTRA_CA_CERTS (no original value recorded)"
    }
  }
  Remove-Item $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
  Write-Host "done. restart Cursor."
  return
}

Write-Host "== 1/4 download CA from $url"
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
Invoke-WebRequest -Uri $url -OutFile $CaFile -UseBasicParsing

Write-Host "== 2/4 trust CA in LocalMachine\Root"
certutil -addstore -f Root $CaFile | Out-Null
$caCert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($CaFile)
Set-Content -Path (Join-Path $WorkDir "thumbprint.txt") -Value $caCert.Thumbprint -Encoding ASCII
Write-Host ("   installed thumbprint " + $caCert.Thumbprint)

Write-Host "== 3/4 point Cursor backend hosts to $Ip"
Update-Hosts

Write-Host "== 4/4 set NODE_EXTRA_CA_CERTS (merged with any existing bundle)"
$current = [Environment]::GetEnvironmentVariable("NODE_EXTRA_CA_CERTS", "User")
if (-not (Test-Path $EnvOriginal)) {
  Set-Content -Path $EnvOriginal -Value ([string]$current) -Encoding ASCII
}
# Keep the user's original CA bundle so re-runs never drop their own roots (e.g. Charles).
if (-not (Test-Path $BasePem) -and $current -and $current -ne $CombinedPem -and (Test-Path $current)) {
  Copy-Item $current $BasePem -Force
  Write-Host ("  saved existing bundle to " + $BasePem)
}
$sourceText = ""
if (Test-Path $BasePem) { $sourceText = Get-Content $BasePem -Raw }
$sourceText += "`r`n" + (Get-Content $CaFile -Raw)

# Dedupe certificate blocks so repeated runs do not grow the bundle.
$blocks = [regex]::Matches($sourceText, '-----BEGIN CERTIFICATE-----[\s\S]*?-----END CERTIFICATE-----') | ForEach-Object { $_.Value.Trim() }
$unique = $blocks | Select-Object -Unique
Set-Content -Path $CombinedPem -Value (($unique -join "`r`n") + "`r`n") -Encoding ASCII
[Environment]::SetEnvironmentVariable("NODE_EXTRA_CA_CERTS", $CombinedPem, "User")

Write-Host ""
Write-Host "Done."
Write-Host ("  hosts: " + $HostsPath)
Write-Host ("  CA:    " + $CaFile)
Write-Host ("  proxy: https://" + $Ip)
Write-Host "Restart Cursor (and sign out/in if it was already running) so it picks up the CA env."
Write-Host "Revert: elevated PowerShell -> irm .../install.ps1 | iex  with -Uninstall"
