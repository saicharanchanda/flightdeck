<#
.SYNOPSIS
  Port-forward Prometheus, Alertmanager and Grafana, each in its own window,
  then open them in the default browser.

.DESCRIPTION
  Each `kubectl port-forward` runs in a new PowerShell window (titled
  "flightdeck: <name> :<port>") so nothing blocks this shell. Window process
  IDs are saved to $env:TEMP\flightdeck-consoles.json for close-consoles.ps1.

  Grafana login: user/password are in Secret monitoring/grafana-admin
  (scripts/grafana-password.ps1 prints them).

.EXAMPLE
  .\scripts\open-consoles.ps1
#>
[CmdletBinding()]
param(
    [int]$TimeoutSeconds = 20
)
$ErrorActionPreference = 'Stop'

$consoles = @(
    @{ Name = 'Prometheus';   Service = 'svc/kube-prometheus-stack-prometheus';   Ports = '9090:9090'; Port = 9090; Url = 'http://localhost:9090' }
    @{ Name = 'Alertmanager'; Service = 'svc/kube-prometheus-stack-alertmanager'; Ports = '9093:9093'; Port = 9093; Url = 'http://localhost:9093' }
    @{ Name = 'Grafana';      Service = 'svc/kube-prometheus-stack-grafana';      Ports = '3000:80';   Port = 3000; Url = 'http://localhost:3000/grafana/' }
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
$busy = $consoles | Where-Object { Test-LocalPort $_.Port }
if ($busy) {
    throw "Port(s) already in use: $(($busy | ForEach-Object { $_.Port }) -join ', '). Run .\scripts\close-consoles.ps1 first."
}

$started = foreach ($c in $consoles) {
    $title = "flightdeck: $($c.Name) :$($c.Port)"
    $command = "`$Host.UI.RawUI.WindowTitle = '$title'; " +
               "Write-Host '$title  (close this window to stop the forward)' -ForegroundColor Cyan; " +
               "& '$kubectl' -n monitoring port-forward $($c.Service) $($c.Ports)"
    $proc = Start-Process powershell.exe -ArgumentList '-NoExit', '-NoProfile', '-Command', $command -PassThru
    [pscustomobject]@{ Name = $c.Name; Port = $c.Port; Url = $c.Url; Pid = $proc.Id; Title = $title }
}
$started | ConvertTo-Json | Set-Content -Encoding utf8 $stateFile

Write-Host "Waiting for port-forwards (up to ${TimeoutSeconds}s each)..."
foreach ($s in $started) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while (-not (Test-LocalPort $s.Port) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
    $s | Add-Member -NotePropertyName Ready -NotePropertyValue (Test-LocalPort $s.Port)
}

foreach ($s in $started) {
    if ($s.Ready) {
        Start-Process $s.Url
        Start-Sleep -Seconds 2
    }
}

# One line per console so nothing is truncated in a narrow terminal.
Write-Host ''
foreach ($s in $started) {
    $status = if ($s.Ready) { 'opened' } else { 'NOT READY - check its window' }
    $color = if ($s.Ready) { 'Green' } else { 'Yellow' }
    Write-Host ("{0,-13} {1,-6} window PID {2,-6} title '{3}'  {4}" -f $s.Name, $status, $s.Pid, $s.Title, $s.Url) -ForegroundColor $color
}
Write-Host ''
Write-Host "Close them all with: .\scripts\close-consoles.ps1"
