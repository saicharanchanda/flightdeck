<#
.SYNOPSIS
  Print the Grafana admin login, read live from Secret monitoring/grafana-admin.
  Prints to this terminal only; nothing is written to disk.
#>
$kubectl = (Get-Command kubectl -ErrorAction SilentlyContinue).Source
if (-not $kubectl) { $kubectl = 'C:\tools\kubectl.exe' }

function Get-SecretValue([string]$Key) {
    $b64 = & $kubectl -n monitoring get secret grafana-admin -o "jsonpath={.data.$Key}"
    if (-not $b64) { throw "Secret monitoring/grafana-admin has no key '$Key'" }
    [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64))
}

Write-Host "Grafana user:     $(Get-SecretValue 'admin-user')"
Write-Host "Grafana password: $(Get-SecretValue 'admin-password')"
