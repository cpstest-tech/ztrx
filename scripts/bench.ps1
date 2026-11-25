# ztrx benchmark: runs the game once per set of switches, reads the frame-rate
# lines the build logs (about every 5 s, see victory-gpu host.rs "fps, ... ms/frame")
# and prints one table to compare them.
#
# Each run lasts -Seconds, then the game is closed the way the close button
# closes it (so the pipeline cache is saved), and killed if it does not end.
# Lines from the first -Skip seconds, and lines with fewer than -MinDraws draws
# a frame (menus, loading screens), are left out.
#
# A release build presses nothing: get to the same place in each run yourself
# (load the same save and stand still), or use the diagnostics build with
# -Keys (VICTORY_KEYS, e.g. "30:Enter,35:Enter").
#
# Example:
#   powershell -ExecutionPolicy Bypass -File scripts\bench.ps1 -Game "<folder>\<exe>"
#   ... -Configs "", "VICTORY_RELAY=2", "VICTORY_RELAY=2 VICTORY_WIDE_REFRESH=1"
param(
    [Parameter(Mandatory = $true)][string]$Game,
    # One entry per run: space-separated NAME=VALUE switches; "" is the default setup.
    # The faster settings are on by default: compare that with all of them off
    # (the old behaviour) and with each one off on its own.
    [string[]]$Configs = @(
        "",
        "VICTORY_RELAY=0 VICTORY_WIDE_BACK=0 VICTORY_WIDE_REFRESH=0 VICTORY_WIDE_MERGE=0 VICTORY_TEXTURE_NO_WAIT=0 VICTORY_JOIN_COPIES=0 VICTORY_CARD_REHASH_RUNS=0 VICTORY_CARD_WINDOWS_MB=0",
        "VICTORY_RELAY=0",
        "VICTORY_RELAY=1",
        "VICTORY_WIDE_BACK=0",
        "VICTORY_WIDE_REFRESH=0",
        "VICTORY_WIDE_MERGE=0",
        "VICTORY_TEXTURE_NO_WAIT=0",
        "VICTORY_JOIN_COPIES=0",
        "VICTORY_CARD_REHASH_RUNS=0",
        "VICTORY_CARD_WINDOWS_MB=0",
        # Experiments, off by default: title memory read by the card where it is.
        "VICTORY_INPLACE=1",
        "VICTORY_INPLACE=1 VICTORY_POOL_COMMIT=1",
        # More of what draws read in the card's memory: a higher cap, and windows cut to what is read.
        "VICTORY_CARD_WINDOWS_MB=1024",
        "VICTORY_WINDOW_TAILS=1 VICTORY_WINDOW_KB=1024"
    ),
    [int]$Seconds = 240,
    [int]$Skip = 90,
    [int]$MinDraws = 0,
    [string]$Keys = "",
    [string]$Cache = "$env:LOCALAPPDATA\ztrx\cache",
    [string]$Data = "$env:LOCALAPPDATA\ztrx\data",
    [string]$Exe = "$PSScriptRoot\..\target\release\victory.exe",
    [string]$Out = "$env:TEMP\ztrx-bench\$(Get-Date -Format yyyyMMdd-HHmmss)"
)
$ErrorActionPreference = "Stop"

if (-not (Test-Path $Exe)) { throw "victory.exe not found at $Exe (cargo build --release -p victory)" }
New-Item -ItemType Directory -Force $Cache, $Data, $Out | Out-Null

Add-Type -Namespace Ztrx -Name Win -MemberDefinition @'
[DllImport("user32.dll")]
public static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
'@
$WM_SYSCOMMAND = 0x0112
$SC_CLOSE = 0xF060

# Every switch any run sets is cleared before each run, so runs do not leak into each other.
$names = @("VICTORY_KEYS", "VICTORY_CAPTURE", "VICTORY_CAPTURE_FRAMES", "VICTORY_DUMP_TARGETS")
foreach ($c in $Configs) {
    foreach ($pair in ($c -split '\s+' | Where-Object { $_ })) {
        if ($pair -notmatch '^[A-Z0-9_]+=.*$') { throw "not NAME=VALUE: '$pair' in config '$c'" }
        $names += ($pair -split '=', 2)[0]
    }
}
$names = $names | Sort-Object -Unique

function Clear-Switches {
    foreach ($n in $names) { Remove-Item "Env:$n" -ErrorAction SilentlyContinue }
}

function Get-Median([double[]]$values) {
    if ($values.Count -eq 0) { return [double]::NaN }
    $s = $values | Sort-Object
    $m = [int][math]::Floor($s.Count / 2)
    if ($s.Count % 2 -eq 1) { return $s[$m] }
    return ($s[$m - 1] + $s[$m]) / 2
}

$line = '([\d.]+) fps, ([\d.]+) ms/frame \(([\d.]+) preparing: copies ([\d.]+) ms [\d.]+ MB, textures ([\d.]+) ms [\d.]+ MB; ([\d.]+) on the GPU; ([\d.]+) copying back [\d.]+ MB\), (\d+) draws/frame'
$stamp = '^(\d{4}-\d\d-\d\dT[\d:.]+Z)'
$results = @()
$i = 0
foreach ($c in $Configs) {
    $i++
    $label = if ($c) { $c } else { "(default)" }
    Write-Host "[$i/$($Configs.Count)] $label - $Seconds s"
    Clear-Switches
    $env:VICTORY_CACHE_DIR = $Cache
    $env:VICTORY_DATA_DIR = $Data
    $env:NO_COLOR = "1"
    if ($Keys) { $env:VICTORY_KEYS = $Keys }
    foreach ($pair in ($c -split '\s+' | Where-Object { $_ })) {
        $kv = $pair -split '=', 2
        Set-Item "Env:$($kv[0])" $kv[1]
    }
    $log = Join-Path $Out "run$i.log"
    $stdout = Join-Path $Out "run$i.out"
    $p = Start-Process -FilePath $Exe -ArgumentList "run `"$Game`" --execute" -NoNewWindow -PassThru `
        -RedirectStandardError $log -RedirectStandardOutput $stdout
    if (-not $p.WaitForExit($Seconds * 1000)) {
        $p.Refresh()
        if ($p.MainWindowHandle -ne [IntPtr]::Zero) {
            [void][Ztrx.Win]::PostMessage($p.MainWindowHandle, $WM_SYSCOMMAND, [IntPtr]$SC_CLOSE, [IntPtr]::Zero)
        }
        if (-not $p.WaitForExit(30000)) {
            Write-Host "  did not end after the close; killed (pipelines made in the last 20 s are not cached)"
            Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
            $p.WaitForExit()
        }
    } else {
        Write-Host "  ended by itself after less than $Seconds s (see $log)"
    }

    $first = $null
    $rows = @()
    foreach ($l in (Get-Content $log, $stdout -ErrorAction SilentlyContinue)) {
        $l = $l -replace "\x1b\[[0-9;]*m", ""
        $t = $null
        if ($l -match $stamp) {
            $t = [DateTimeOffset]::Parse($Matches[1], [Globalization.CultureInfo]::InvariantCulture)
            if (-not $first) { $first = $t }
        }
        if ($l -notmatch $line) { continue }
        $m = $Matches
        if ($t -and $first -and ($t - $first).TotalSeconds -lt $Skip) { continue }
        if ([int]$m[8] -lt $MinDraws) { continue }
        $rows += [pscustomobject]@{
            fps = [double]$m[1]; ms = [double]$m[2]; preparing = [double]$m[3]; copies = [double]$m[4]
            textures = [double]$m[5]; gpu = [double]$m[6]; back = [double]$m[7]; draws = [int]$m[8]
        }
    }
    $ci = [Globalization.CultureInfo]::InvariantCulture
    $r = [pscustomobject]@{
        config      = $label
        lines       = $rows.Count
        fps_median  = Get-Median ($rows | ForEach-Object { $_.fps })
        fps_worst   = if ($rows.Count) { ($rows | Measure-Object fps -Minimum).Minimum } else { [double]::NaN }
        ms_frame    = Get-Median ($rows | ForEach-Object { $_.ms })
        preparing   = Get-Median ($rows | ForEach-Object { $_.preparing })
        copies      = Get-Median ($rows | ForEach-Object { $_.copies })
        textures    = Get-Median ($rows | ForEach-Object { $_.textures })
        gpu         = Get-Median ($rows | ForEach-Object { $_.gpu })
        copy_back   = Get-Median ($rows | ForEach-Object { $_.back })
        draws       = Get-Median ($rows | ForEach-Object { $_.draws })
    }
    if ($rows.Count -eq 0) { Write-Host "  no frame-rate lines kept (lower -Skip / -MinDraws, or look at $log)" }
    else { Write-Host ("  median {0} fps, {1} ms/frame over {2} lines" -f $r.fps_median.ToString("0.00", $ci), $r.ms_frame.ToString("0.0", $ci), $rows.Count) }
    $results += $r
}
Clear-Switches
Remove-Item Env:NO_COLOR -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "Medians in ms per frame; 'gpu' is the time spent waiting for the card."
$results | Sort-Object fps_median -Descending | Format-Table -AutoSize `
    config, lines, @{n = "fps"; e = { "{0:N2}" -f $_.fps_median } }, @{n = "worst"; e = { "{0:N2}" -f $_.fps_worst } },
    @{n = "ms/frame"; e = { "{0:N0}" -f $_.ms_frame } }, @{n = "prep"; e = { "{0:N0}" -f $_.preparing } },
    @{n = "copies"; e = { "{0:N0}" -f $_.copies } }, @{n = "textures"; e = { "{0:N0}" -f $_.textures } },
    @{n = "gpu"; e = { "{0:N0}" -f $_.gpu } }, @{n = "back"; e = { "{0:N0}" -f $_.copy_back } },
    @{n = "draws"; e = { "{0:N0}" -f $_.draws } }
$csv = Join-Path $Out "results.csv"
$results | Export-Csv -NoTypeInformation -Path $csv
Write-Host "Logs and $csv in $Out"
