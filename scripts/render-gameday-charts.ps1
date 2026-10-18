# Render game-day charts as SVG from real Prometheus range queries.
param([string]$OutDir = 'C:\Users\saich\Desktop\flightdeck\docs\img')
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force $OutDir | Out-Null
$inv = [Globalization.CultureInfo]::InvariantCulture

function Range([string]$q, [datetime]$from, [datetime]$to) {
    $s = [DateTimeOffset]::new($from).ToUnixTimeSeconds(); $e = [DateTimeOffset]::new($to).ToUnixTimeSeconds()
    $r = Invoke-RestMethod "http://localhost:9090/api/v1/query_range?query=$([uri]::EscapeDataString($q))&start=$s&end=$e&step=30"
    $r.data.result | Select-Object -First 1 | ForEach-Object { $_.values | ForEach-Object { [pscustomobject]@{ t = [double]$_[0]; v = [double]::Parse($_[1], $inv) } } } |
        Where-Object { -not [double]::IsNaN($_.v) }
}
function U([string]$s) { [DateTimeOffset]::Parse($s, $inv).UtcDateTime }
function F([double]$x) { $x.ToString('0.#', $inv) }

$bg = '#0d1117'; $grid = '#21262d'; $axis = '#30363d'; $txt = '#8b949e'; $hi = '#c9d1d9'

# Draw one panel. $series: @(@{ pts; color; label }), $lines: horizontal threshold lines, $events: vertical markers.
function Panel($x0, $y0, $w, $h, $from, $to, $ymax, $series, $lines, $events, $yunit, $title, $showEventLabels) {
    $t0 = [DateTimeOffset]::new($from).ToUnixTimeSeconds(); $t1 = [DateTimeOffset]::new($to).ToUnixTimeSeconds()
    $X = { param($t) $x0 + ($t - $t0) / ($t1 - $t0) * $w }
    $Y = { param($v) $y0 + $h - ([math]::Min($v, $ymax) / $ymax) * $h }
    $o = New-Object Text.StringBuilder
    [void]$o.Append("<text x='$x0' y='$($y0 - 10)' fill='$hi' font-size='13' font-weight='600'>$title</text>")
    foreach ($k in 0..4) { $v = $ymax * $k / 4; $yy = & $Y $v
        [void]$o.Append("<line x1='$x0' y1='$(F $yy)' x2='$($x0 + $w)' y2='$(F $yy)' stroke='$grid'/>")
        [void]$o.Append("<text x='$($x0 - 6)' y='$(F ($yy + 4))' fill='$txt' font-size='10' text-anchor='end'>$(F $v)$yunit</text>") }
    for ($t = [math]::Ceiling($t0 / 600) * 600; $t -le $t1; $t += 600) { $xx = & $X $t
        $lbl = [DateTimeOffset]::FromUnixTimeSeconds([int64]$t).ToString('HH:mm', $inv)
        [void]$o.Append("<text x='$(F $xx)' y='$($y0 + $h + 15)' fill='$txt' font-size='10' text-anchor='middle'>$lbl</text>") }
    foreach ($l in $lines) { $yy = & $Y $l.v
        [void]$o.Append("<line x1='$x0' y1='$(F $yy)' x2='$($x0 + $w)' y2='$(F $yy)' stroke='$($l.color)' stroke-dasharray='5 4' stroke-width='1.2'/>")
        [void]$o.Append("<text x='$($x0 + $w - 4)' y='$(F ($yy - 5))' fill='$($l.color)' font-size='10' text-anchor='end'>$($l.label)</text>") }
    $i = 0
    foreach ($e in $events) { $xx = & $X ([DateTimeOffset]::new($e.t).ToUnixTimeSeconds())
        [void]$o.Append("<line x1='$(F $xx)' y1='$y0' x2='$(F $xx)' y2='$($y0 + $h)' stroke='$($e.color)' stroke-width='1' opacity='0.8'/>")
        if ($showEventLabels) { $ly = $y0 + 12 + ($i % 3) * 13
            [void]$o.Append("<text x='$(F ($xx + 4))' y='$ly' fill='$($e.color)' font-size='10'>$($e.label)</text>") }
        $i++ }
    foreach ($s in $series) { if (-not $s.pts) { continue }
        $d = ($s.pts | ForEach-Object { "$(F (& $X $_.t)),$(F (& $Y $_.v))" }) -join ' '
        [void]$o.Append("<polyline points='$d' fill='none' stroke='$($s.color)' stroke-width='2' stroke-linejoin='round'/>") }
    [void]$o.Append("<rect x='$x0' y='$y0' width='$w' height='$h' fill='none' stroke='$axis'/>")
    $o.ToString()
}
function Legend($x, $y, $items) {
    ($items | ForEach-Object -Begin { $i = 0 } -Process {
        $xx = $x + $i * 190; $i++
        "<line x1='$xx' y1='$y' x2='$($xx + 18)' y2='$y' stroke='$($_.color)' stroke-width='2.5' $(if ($_.dash) { "stroke-dasharray='5 4'" })/><text x='$($xx + 24)' y='$($y + 4)' fill='$hi' font-size='11'>$($_.label)</text>"
    }) -join ''
}
function Svg($w, $h, $title, $sub, $body) {
    "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 $w $h' preserveAspectRatio='xMidYMid meet' font-family='-apple-system,Segoe UI,Helvetica,Arial,sans-serif' role='img' aria-label='$title'>" +
    "<rect width='$w' height='$h' rx='10' fill='$bg'/>" +
    "<text x='24' y='30' fill='$hi' font-size='16' font-weight='700'>$title</text>" +
    "<text x='24' y='49' fill='$txt' font-size='11'>$sub</text>" + $body + "</svg>"
}

# --- Game day 01: availability burn rate --------------------------------------
$f = U '2026-10-18T15:30:00Z'; $t = U '2026-10-18T16:20:00Z'
$b5 = Range 'slo:gateway_availability:burnrate5m' $f $t
$b1h = Range 'slo:gateway_availability:burnrate1h' $f $t
$ev1 = @(
    @{ t = U '2026-10-18T15:40:07Z'; label = 'inject 30% errors'; color = '#d29922' }
    @{ t = U '2026-10-18T15:49:33Z'; label = 'page fires'; color = '#f85149' }
    @{ t = U '2026-10-18T15:52:37Z'; label = 'fix'; color = '#3fb950' }
    @{ t = U '2026-10-18T15:58:03Z'; label = 'ticket fires (after fix)'; color = '#db61a2' }
)
$p1 = Panel 64 92 680 230 $f $t 32 @(@{ pts = $b5; color = '#58a6ff' }, @{ pts = $b1h; color = '#f0883e' }) @(@{ v = 14.4; color = '#f85149'; label = 'page: 14.4&#215;' }, @{ v = 6; color = '#db61a2'; label = 'ticket: 6&#215;' }) $ev1 '&#215;' 'Availability burn rate (&#215;)' $true
$lg1 = Legend 64 360 @(@{ color = '#58a6ff'; label = '5m window' }, @{ color = '#f0883e'; label = '1h window' })
$svg1 = Svg 780 384 'Game day 01 &#8212; error spike' 'Recorded from Prometheus (30s step). Page = both windows above 14.4&#215;. The ticket fired 5 min after the fix.' ($p1 + $lg1)
[IO.File]::WriteAllText((Join-Path $OutDir 'gameday-01-burn-rate.svg'), $svg1, (New-Object Text.UTF8Encoding $false))

# --- Game day 02: latency vs the HPA's CPU signal ------------------------------
$f = U '2026-10-18T16:02:00Z'; $t = U '2026-10-18T16:46:00Z'
$api = 'namespace="flightdeck", service="gateway", route!~"/healthz|/readyz|/metrics"'
$lat = Range "1000 * sum(rate(http_request_duration_seconds_sum{$api}[1m])) / sum(rate(http_request_duration_seconds_count{$api}[1m]))" $f $t
$cpu = Range '100 * sum(rate(container_cpu_usage_seconds_total{namespace="flightdeck", container="gateway"}[2m])) / sum(kube_pod_container_resource_requests{namespace="flightdeck", container="gateway", resource="cpu"})' $f $t
$rep = Range 'kube_horizontalpodautoscaler_status_current_replicas{namespace="flightdeck", horizontalpodautoscaler="flightdeck-gateway"}' $f $t
$ev2 = @(
    @{ t = U '2026-10-18T16:09:48Z'; label = 'inject 800ms'; color = '#d29922' }
    @{ t = U '2026-10-18T16:25:39Z'; label = 'force 3rd pod'; color = '#a371f7' }
    @{ t = U '2026-10-18T16:34:11Z'; label = 'fix'; color = '#3fb950' }
    @{ t = U '2026-10-18T16:41:38Z'; label = 'ticket fires'; color = '#db61a2' }
)
$p2a = Panel 64 92 680 150 $f $t 1000 @(@{ pts = $lat; color = '#58a6ff' }) @() $ev2 'ms' 'Gateway mean latency (ms)' $true
$p2b = Panel 64 292 680 150 $f $t 100 @(@{ pts = $cpu; color = '#f0883e' }, @{ pts = ($rep | ForEach-Object { [pscustomobject]@{ t = $_.t; v = $_.v * 20 } }); color = '#8b949e' }) @(@{ v = 70; color = '#f85149'; label = 'HPA target: 70%' }) $ev2 '%' "HPA's signal: gateway CPU (% of request)" $false
$lg2 = Legend 64 482 @(@{ color = '#58a6ff'; label = 'latency (sum/count)' }, @{ color = '#f0883e'; label = 'CPU % of request' }, @{ color = '#8b949e'; label = 'replicas (&#215;20, 2 &#8594; 40)' })
$svg2 = Svg 780 506 'Game day 02 &#8212; the HPA is blind to latency' 'Recorded from Prometheus (30s step). Latency up 320&#215; for 24 min; CPU flat; the 3rd pod was forced by hand.' ($p2a + $p2b + $lg2)
[IO.File]::WriteAllText((Join-Path $OutDir 'gameday-02-hpa-blind.svg'), $svg2, (New-Object Text.UTF8Encoding $false))

# --- Game day 03: working set vs the stepped-down limit -------------------------
$f = U '2026-10-18T17:45:00Z'; $t = U '2026-10-18T18:30:00Z'
$ws = Range 'max(container_memory_working_set_bytes{namespace="flightdeck", container="flights"}) / 1048576' $f $t
$lim = Range 'min(kube_pod_container_resource_limits{namespace="flightdeck", container="flights", resource="memory"}) / 1048576' $f $t
$rst = Range 'sum(increase(kube_pod_container_status_restarts_total{namespace="flightdeck", container="flights"}[2m]))' $f $t
$ev3 = @(
    @{ t = U '2026-10-18T17:52:51Z'; label = '32Mi'; color = '#d29922' }
    @{ t = U '2026-10-18T17:59:24Z'; label = '150 req/s spike'; color = '#a371f7' }
    @{ t = U '2026-10-18T18:04:09Z'; label = '8Mi'; color = '#d29922' }
    @{ t = U '2026-10-18T18:10:37Z'; label = '6Mi'; color = '#f85149' }
    @{ t = U '2026-10-18T18:23:28Z'; label = 'CrashLoop alert'; color = '#db61a2' }
    @{ t = U '2026-10-18T18:25:47Z'; label = 'restore'; color = '#3fb950' }
)
$p3a = Panel 64 92 680 170 $f $t 40 @(@{ pts = $ws; color = '#58a6ff' }, @{ pts = $lim; color = '#f85149' }) @() $ev3 'Mi' 'flights memory: working set vs limit (Mi, limit clipped at 40)' $true
$p3b = Panel 64 312 680 110 $f $t 8 @(@{ pts = $rst; color = '#f0883e' }) @() $ev3 '' 'flights container restarts (per 2 min)' $false
$lg3 = Legend 64 462 @(@{ color = '#58a6ff'; label = 'working set (max of pods)' }, @{ color = '#f85149'; label = 'memory limit' }, @{ color = '#f0883e'; label = 'restarts' })
$svg3 = Svg 780 486 'Game day 03 &#8212; OOMKill' 'Recorded from Prometheus (30s step). 32Mi and a 7.5&#215; spike never killed it; 8Mi did once; 6Mi crash-looped.' ($p3a + $p3b + $lg3)
[IO.File]::WriteAllText((Join-Path $OutDir 'gameday-03-oom.svg'), $svg3, (New-Object Text.UTF8Encoding $false))

# --- Game day 04: what clients got while Postgres was at zero -------------------
$f = U '2026-10-18T18:30:00Z'; $t = U '2026-10-18T18:53:00Z'
$api = 'namespace="flightdeck", service="gateway", route!~"/healthz|/readyz|/metrics"'
$ok = Range "sum(rate(http_requests_total{$api, status=~`"2..`"}[1m])) or vector(0)" $f $t
$e504 = Range "sum(rate(http_requests_total{$api, status=`"504`"}[1m])) or vector(0)" $f $t
$e502 = Range "sum(rate(http_requests_total{$api, status=`"502`"}[1m])) or vector(0)" $f $t
$rdy = Range 'sum(kube_pod_container_status_ready{namespace="flightdeck", container="flights"})' $f $t
$ev4 = @(
    @{ t = U '2026-10-18T18:34:15Z'; label = 'Postgres &#8594; 0'; color = '#f85149' }
    @{ t = U '2026-10-18T18:38:39Z'; label = 'page fires'; color = '#db61a2' }
    @{ t = U '2026-10-18T18:47:33Z'; label = 'Postgres &#8594; 1'; color = '#3fb950' }
)
$p4a = Panel 64 92 680 170 $f $t 24 @(@{ pts = $ok; color = '#3fb950' }, @{ pts = $e504; color = '#f85149' }, @{ pts = $e502; color = '#d29922' }) @() $ev4 '/s' 'Gateway responses per second' $true
$p4b = Panel 64 312 680 110 $f $t 3 @(@{ pts = $rdy; color = '#58a6ff' }) @() $ev4 '' 'flights pods Ready (honest probe: 2 &#8594; 0)' $false
$lg4 = Legend 64 462 @(@{ color = '#3fb950'; label = '2xx' }, @{ color = '#f85149'; label = '504 (5s timeout)' }, @{ color = '#d29922'; label = '502' })
$svg4 = Svg 780 486 'Game day 04 &#8212; Postgres at zero' 'Recorded from Prometheus (30s step). 100% errors for 12 min, mostly 5s hangs; recovery 30.5s after scale-up.' ($p4a + $p4b + $lg4)
[IO.File]::WriteAllText((Join-Path $OutDir 'gameday-04-postgres-down.svg'), $svg4, (New-Object Text.UTF8Encoding $false))
"gd3 points: ws=$(@($ws).Count) limit=$(@($lim).Count) restarts=$(@($rst).Count)   gd4 points: ok=$(@($ok).Count) 504=$(@($e504).Count) 502=$(@($e502).Count) ready=$(@($rdy).Count)"

"gd1 points: 5m=$(@($b5).Count) 1h=$(@($b1h).Count)   gd2 points: latency=$(@($lat).Count) cpu=$(@($cpu).Count) replicas=$(@($rep).Count)"
"gd1 max burn5m=$(F (($b5 | Measure-Object v -Maximum).Maximum)) max burn1h=$(F (($b1h | Measure-Object v -Maximum).Maximum))"
"gd2 max latency=$(F (($lat | Measure-Object v -Maximum).Maximum))ms  cpu range=$(F (($cpu | Measure-Object v -Minimum).Minimum))-$(F (($cpu | Measure-Object v -Maximum).Maximum))%  replicas=$((($rep | Select-Object -ExpandProperty v | Sort-Object -Unique) -join ','))"
Get-ChildItem $OutDir | Select-Object Name, Length