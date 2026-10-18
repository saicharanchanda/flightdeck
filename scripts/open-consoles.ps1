<#
.SYNOPSIS
  Port-forward the observability stack and the flightdeck services, each in
  its own window, then open everything in the default browser.

.DESCRIPTION
  Each `kubectl port-forward` runs in a new PowerShell window (titled
  "flightdeck: <name> :<port>") so nothing blocks this shell. Window process
  IDs are saved to $env:TEMP\flightdeck-consoles.json for close-consoles.ps1.

  The gateway is opened through the public ALB (hostname read from the
  gateway Ingress, so it survives the ALB being replaced). flights and
  notifier have no public route; they are reached through port-forwards.

  Grafana login: user/password are in Secret monitoring/grafana-admin
  (scripts/grafana-password.ps1 prints them).

.EXAMPLE
  .\scripts\open-consoles.ps1
#>
[CmdletBinding()]
param(
    [int]$TimeoutSeconds = 20,
    [int]$GapSeconds = 2
)
$ErrorActionPreference = 'Stop'

$forwards = @(
    @{ Name = 'Prometheus';   Namespace = 'monitoring'; Service = 'svc/kube-prometheus-stack-prometheus';   Ports = '9090:9090'; Port = 9090 }
    @{ Name = 'Alertmanager'; Namespace = 'monitoring'; Service = 'svc/kube-prometheus-stack-alertmanager'; Ports = '9093:9093'; Port = 9093 }
    @{ Name = 'Grafana';      Namespace = 'monitoring'; Service = 'svc/kube-prometheus-stack-grafana';      Ports = '3000:80';   Port = 3000 }
    @{ Name = 'flights';      Namespace = 'flightdeck'; Service = 'svc/flightdeck-flights';                 Ports = '8081:8081'; Port = 8081 }
    @{ Name = 'notifier';     Namespace = 'flightdeck'; Service = 'svc/flightdeck-notifier';                Ports = '8082:8082'; Port = 8082 }
)
$stateFile = Join-Path $env:TEMP 'flightdeck-consoles.json'

# New windows may not see a PATH updated since login, so resolve kubectl here.
$kubectl = (Get-Command kubectl -ErrorAction SilentlyContinue).Source
if (-not $kubectl) { $kubectl = 'C:\tools\kubectl.exe' }
if (-not (Test-Path $kubectl)) { throw "kubectl not found on PATH or at C:\tools\kubectl.exe" }

function Test-LocalPort([int]$Port) {
    $client = New-Object System.Net.Sockets.TcpClient
    try { $client.ConnectAsync('127.0.0.1', $Port).Wait(500) -and $client.Connected } catch { $false } finally { $client.Dispose() }
}

# Refuse to start a second set on top of a running one.
$busy = $forwards | Where-Object { Test-LocalPort $_.Port }
if ($busy) {
    throw "Port(s) already in use: $(($busy | ForEach-Object { $_.Port }) -join ', '). Run .\scripts\close-consoles.ps1 first."
}

# The ALB is public; no forward needed. Ask the Ingress for its current hostname.
$alb = & $kubectl -n flightdeck get ingress flightdeck-gateway -o 'jsonpath={.status.loadBalancer.ingress[0].hostname}'
if (-not $alb) { Write-Warning 'Gateway Ingress has no ALB hostname yet; skipping ALB URLs.' }

$started = foreach ($f in $forwards) {
    $title = "flightdeck: $($f.Name) :$($f.Port)"
    $command = "`$Host.UI.RawUI.WindowTitle = '$title'; " +
               "Write-Host '$title  (close this window to stop the forward)' -ForegroundColor Cyan; " +
               "& '$kubectl' -n $($f.Namespace) port-forward $($f.Service) $($f.Ports)"
    $proc = Start-Process powershell.exe -ArgumentList '-NoExit', '-NoProfile', '-Command', $command -PassThru
    [pscustomobject]@{ Name = $f.Name; Namespace = $f.Namespace; Port = $f.Port; Pid = $proc.Id; Title = $title }
}
$started | ConvertTo-Json | Set-Content -Encoding utf8 $stateFile

Write-Host "Waiting for port-forwards (up to ${TimeoutSeconds}s each)..."
$ready = @{}
foreach ($s in $started) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while (-not (Test-LocalPort $s.Port) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
    $ready[$s.Port] = Test-LocalPort $s.Port
}

# What to open, in order. Via = 'ALB' needs no forward; 'forward' needs its port up.
$urls = @(
    @{ Name = 'Prometheus';                 Via = 'forward'; Port = 9090; Url = 'http://localhost:9090' }
    @{ Name = 'Alertmanager';               Via = 'forward'; Port = 9093; Url = 'http://localhost:9093' }
    @{ Name = 'Grafana';                    Via = 'forward'; Port = 3000; Url = 'http://localhost:3000/grafana/' }
)
if ($alb) {
    $urls += @(
        @{ Name = 'gateway /api/flights';   Via = 'ALB';     Port = 0;    Url = "http://$alb/api/flights" }
        @{ Name = 'gateway /healthz';       Via = 'ALB';     Port = 0;    Url = "http://$alb/healthz" }
        @{ Name = 'gateway /metrics';       Via = 'ALB';     Port = 0;    Url = "http://$alb/metrics" }
    )
}
$urls += @(
    @{ Name = 'flights /flights';           Via = 'forward'; Port = 8081; Url = 'http://localhost:8081/flights' }
    @{ Name = 'flights /metrics';           Via = 'forward'; Port = 8081; Url = 'http://localhost:8081/metrics' }
    @{ Name = 'notifier /metrics';          Via = 'forward'; Port = 8082; Url = 'http://localhost:8082/metrics' }
)

$opened = foreach ($u in $urls) {
    $ok = ($u.Via -eq 'ALB') -or $ready[$u.Port]
    if ($ok) {
        Start-Process $u.Url
        Start-Sleep -Seconds $GapSeconds
    }
    [pscustomobject]@{ Name = $u.Name; Via = $u.Via; Url = $u.Url; Opened = $ok }
}

# One line per item so nothing is truncated in a narrow terminal.
Write-Host ''
Write-Host 'Port-forward windows:'
foreach ($s in $started) {
    $status = if ($ready[$s.Port]) { 'ready' } else { 'NOT READY - check its window' }
    $color = if ($ready[$s.Port]) { 'Green' } else { 'Yellow' }
    Write-Host ("  {0,-13} {1,-6} window PID {2,-6} title '{3}'" -f $s.Name, $status, $s.Pid, $s.Title) -ForegroundColor $color
}
Write-Host ''
Write-Host 'Opened in browser:'
foreach ($o in $opened) {
    $color = if ($o.Opened) { 'Green' } else { 'Yellow' }
    $mark = if ($o.Opened) { 'opened ' } else { 'skipped' }
    Write-Host ("  {0} {1,-22} {2,-8} {3}" -f $mark, $o.Name, "[$($o.Via)]", $o.Url) -ForegroundColor $color
}
Write-Host ''
Write-Host "Close the port-forwards with: .\scripts\close-consoles.ps1"
