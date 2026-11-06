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

function Update-Hosts {
  $content = Get-Content $HostsPath -Raw
  $content = [regex]::Replace($content, "(?ms)^# BEGIN cursor-byok.*?^# END cursor-byok\r?\n?", "")
  if (-not $Uninstall) {
    $block = "$MarkBegin`r`n$Ip $($Hostnames -join ' ')`r`n$MarkEnd`r`n"
    $content = $content.TrimEnd() + "`r`n`r`n" + $block
  }
  Set-Content -Path $HostsPath -Value $content -Encoding ASCII
  ipconfig /flushdns | Out-Null
}

if ($Uninstall) {
  Write-Host "== removing hosts block"
  Update-Hosts
  $certs = Get-ChildItem Cert:\LocalMachine\Root | Where-Object { $_.Subject -like "*Cursor BYOK*" }
  foreach ($c in $certs) {
    certutil -delstore Root $c.Thumbprint | Out-Null
    Write-Host ("removed certificate " + $c.Thumbprint)
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

Write-Host "== 3/4 point Cursor agent hosts to $Ip"
Update-Hosts

Write-Host "== 4/4 set NODE_EXTRA_CA_CERTS (merged with any existing bundle)"
$parts = @()
$current = [Environment]::GetEnvironmentVariable("NODE_EXTRA_CA_CERTS", "User")
if ($current -and (Test-Path $current)) {
  $parts += (Get-Content $current -Raw)
} elseif ($current) {
  Write-Host ("  existing NODE_EXTRA_CA_CERTS not found, keeping value: " + $current)
  $parts += ""
}
$parts += (Get-Content $CaFile -Raw)
Set-Content -Path $CombinedPem -Value ($parts -join "`r`n") -Encoding ASCII
[Environment]::SetEnvironmentVariable("NODE_EXTRA_CA_CERTS", $CombinedPem, "User")

Write-Host ""
Write-Host "Done."
Write-Host ("  hosts: " + $HostsPath)
Write-Host ("  CA:    " + $CaFile)
Write-Host ("  proxy: https://" + $Ip)
Write-Host "Restart Cursor (and sign out/in if it was already running) so it picks up the CA env."
Write-Host "Revert: elevated PowerShell -> irm .../install.ps1 | iex  with -Uninstall"
