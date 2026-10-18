<#
.SYNOPSIS
  Stop the port-forwards started by open-consoles.ps1.

.DESCRIPTION
  Closes the windows recorded in $env:TEMP\flightdeck-consoles.json, then
  kills any remaining `kubectl port-forward` for the three monitoring
  Services (e.g. if a window was started by hand or the state file is gone).
#>
$stateFile = Join-Path $env:TEMP 'flightdeck-consoles.json'
$services = 'kube-prometheus-stack-prometheus', 'kube-prometheus-stack-alertmanager', 'kube-prometheus-stack-grafana'
$stopped = @()

if (Test-Path $stateFile) {
    foreach ($s in @(Get-Content $stateFile -Raw | ConvertFrom-Json)) {
        $p = Get-Process -Id $s.Pid -ErrorAction SilentlyContinue
        if ($p -and $p.ProcessName -eq 'powershell') {
            # Child kubectl first, then the window.
            Get-CimInstance Win32_Process -Filter "ParentProcessId = $($s.Pid)" |
                ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
            Stop-Process -Id $s.Pid -Force
            $stopped += "$($s.Name) window (PID $($s.Pid))"
        }
    }
    Remove-Item $stateFile
}

# Strays: any kubectl port-forward to one of our Services.
Get-CimInstance Win32_Process -Filter "Name = 'kubectl.exe'" | Where-Object {
    $cl = $_.CommandLine
    $cl -match 'port-forward' -and ($services | Where-Object { $cl -match [regex]::Escape($_) })
} | ForEach-Object {
    Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    $stopped += "kubectl port-forward (PID $($_.ProcessId))"
}

if ($stopped) { $stopped | ForEach-Object { Write-Host "stopped: $_" } }
else { Write-Host 'Nothing to stop.' }
