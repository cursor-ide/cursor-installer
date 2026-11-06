#requires -Version 5
<#
  Cursor BYOK bootstrap (Windows).

    irm https://raw.githubusercontent.com/cursor-ide/cursor-installer/main/install.ps1 | iex

  Optional:
    & ([scriptblock]::Create((irm ...))) -Ip 1.2.3.4
    & ([scriptblock]::Create((irm ...))) -Uninstall
#>
param(
  [string]$Ip = $(if ($env:CURSOR_PROXY_IP) { $env:CURSOR_PROXY_IP } else { "203.0.113.10" }),
  [string]$CaUrl = "",
  [switch]$Uninstall
)

$ErrorActionPreference = "Stop"
$MarkBegin = "# BEGIN cursor-byok"
$MarkEnd = "# END cursor-byok"
$HostsPath = Join-Path $env:SystemRoot "System32\drivers\etc\hosts"
$WorkDir = Join-Path $env:ProgramData "cursor-byok"
$CaFile = Join-Path $WorkDir "ca.crt"
$CombinedPem = Join-Path $WorkDir "ca-combined.pem"
$BasePem = Join-Path $WorkDir "base-ca.pem"

$Hostnames = @(
  "agent.api5.cursor.sh", "agentn.api5.cursor.sh",
  "agent-gcpp-uswest.api5.cursor.sh", "agentn-gcpp-uswest.api5.cursor.sh",
  "agentn-gcpp-eucentral.api5.cursor.sh", "agentn-gcpp-apsoutheast.api5.cursor.sh",
  "agent.global.api5.cursor.sh", "agentn.global.api5.cursor.sh",
  "agentn-gcpp-uswest.global.api5.cursor.sh", "agent-gcpp-uswest.global.api5.cursor.sh",
  "agentn-gcpp-eucentral.global.api5.cursor.sh", "agentn-gcpp-apsoutheast.global.api5.cursor.sh"
)

function Test-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $pr = New-Object Security.Principal.WindowsPrincipal($id)
  return $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
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
  $content = [regex]::Replace($content, "(?ms)^# BEGIN cursor-byok[^\r\n]*\r?\n.*?^# END cursor-byok[^\r\n]*\r?\n?", "")
  $content = $content.TrimEnd()
  if (-not $Uninstall) {
    $block = "$MarkBegin`r`n$Ip $($Hostnames -join ' ')`r`n$MarkEnd"
    $content = $content + "`r`n`r`n" + $block
  }
  $content = $content.TrimStart() + "`r`n"

  # Safety: never write a suspiciously short file.
  if ($content.Length -lt 50) {
    throw "refusing to write hosts: resulting content too short (" + $content.Length + " chars)"
  }

  Copy-Item $HostsPath "$HostsPath.bak-cursor-byok" -Force -ErrorAction SilentlyContinue
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
    [Environment]::SetEnvironmentVariable("NODE_EXTRA_CA_CERTS", $null, "User")
  }
  Remove-Item $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
  Write-Host "done. restart Cursor."
  return
}

$url = if ($CaUrl) { $CaUrl } else { "http://$Ip/ca.crt" }

Write-Host "== 1/4 download CA from $url"
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
Invoke-WebRequest -Uri $url -OutFile $CaFile -UseBasicParsing

Write-Host "== 2/4 trust CA in LocalMachine\Root"
certutil -addstore -f Root $CaFile | Out-Null
$caCert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($CaFile)
Set-Content -Path (Join-Path $WorkDir "thumbprint.txt") -Value $caCert.Thumbprint -Encoding ASCII
Write-Host ("   installed thumbprint " + $caCert.Thumbprint)

Write-Host "== 3/4 point Cursor agent hosts to $Ip"
Update-Hosts

Write-Host "== 4/4 set NODE_EXTRA_CA_CERTS (merged with any existing bundle)"
$current = [Environment]::GetEnvironmentVariable("NODE_EXTRA_CA_CERTS", "User")
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
