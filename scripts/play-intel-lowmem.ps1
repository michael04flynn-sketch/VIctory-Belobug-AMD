# Low-memory profile for Intel GPUs at 1080p, aiming at 30 fps.
# Starts the title by running victory.exe directly with the Series S console profile
# (1920x1080 output, 1280x720 rendering), with smaller caches for card memory (VRAM)
# and system memory (RAM). play.ps1 has no -Console parameter, so it is not used here.
#   scripts\play-intel-lowmem.ps1 -Exe <path of your own copy's executable>
# -Build        release (the default, faster) or diag
# -InPlace      use title memory in place instead of copying it (VICTORY_INPLACE=1)
# -MinFreeGB    free RAM below which the run is not started (default 20); -Force starts anyway
# -LogDir / -NoLog   the run is logged to logs\victory-<time>.log (newest 20 kept) with a header
#               (command, git commit, GPU and driver, env values) and an exit-code summary
# Extra settings may be passed the same way as play.ps1: -More @{VICTORY_PANEL='1'}
# Measurements of this profile on Intel hardware: none yet. Check the frame time with
# VICTORY_PANEL=1 and VRAM in Task Manager before relying on it.
param(
    [Parameter(Mandatory)][string]$Exe,
    [ValidateSet('diag', 'release')][string]$Build = 'release',
    [hashtable]$More = @{},
    # Free RAM (GB) below which the run is not started (-Force: start anyway).
    # (20: the run of 2026-11-27 started with 17.9 GB free on 31 GB and ended with the card out
    # of memory in the first world frame, with 2.9 GB free at that moment.)
    [double]$MinFreeGB = 20,
    [switch]$Force,
    # Free commit (RAM + pagefile, GB) below which the run is not started.
    [double]$MinCommitGB = 20,
    # Use title memory in place instead of copying it (VICTORY_INPLACE=1, see below).
    [switch]$InPlace,
    # Where the log goes (default: logs\ in the repository). -NoLog writes none.
    [string]$LogDir,
    [switch]$NoLog
)

# Memory knobs (values in MB unless the name says KB). Each one lowers how much is kept
# ready at once, at the cost of textures arriving a little later.
$lowMemory = @{
    # Texture queue stops filling the card at 50 % of its budget (default 90; 50 is the lowest
    # the layer accepts). Measured: runs 6 to 9 closed the queue near 4.0 to 4.2 GB in use on a
    # 9.2 GB budget, little below run 5 at 65 % (4.3 GB), because the card room kept for render
    # targets counts in the same sum. It did not prevent the crash: the growth came after the
    # queue closed.
    # Only works while VICTORY_TEXTURE_BUDGET_MB is unset: that setting skips the budget check.
    VICTORY_TEXTURE_ROOM_PERCENT      = '50'
    # Title buffers copied into card memory: at most 128 MB, and only buffers of at least 1 MB.
    # The queue also keeps less card room back for these copies.
    VICTORY_CARD_BUFFERS_MB           = '128'
    VICTORY_CARD_BUFFERS_MIN_KB       = '1024'
    # Card memory kept free for render targets: left at the layer's default (3,072 MB). A lower
    # value lets textures fill more of the card.
    # Cap on title memory used in place (system memory). It only counts with -InPlace: without
    # VICTORY_INPLACE the title's memory is copied, and this value does nothing.
    VICTORY_INPLACE_MB                = '512'
    VICTORY_KEEP_SNAPSHOTS_MB         = '64'
    VICTORY_SNAPSHOT_POOL             = '128'
    # Texture bytes uploaded per frame: the layer's per-frame rate, not a total cap.
    # The default is 192 MB (96 MB under a 6 GiB budget); 256 raised it.
    VICTORY_TEXTURE_STAGE_MB          = '64'
    # Textures are uploaded ahead of need less often (default 12 ms a frame).
    VICTORY_EARLY_TEXTURES_MS         = '6'
    # Bytes of picked views checked per frame (default 32): less CPU time and memory traffic each frame.
    VICTORY_PICKED_MB                 = '8'
    # Host-memory budgets (residency.rs): texture prefetch and staging are cut back while free
    # RAM or commit is low, and on a PC with 32 GiB of RAM or less even when they are not.
    VICTORY_RESIDENCY                 = '1'
    # Smaller-PC budgets on any PC. Needs VICTORY_RESIDENCY=1, which is set above.
    VICTORY_RESIDENCY_LIMITED         = '1'
}

# -InPlace: title memory outside buffers is opened as a host heap and used where the title wrote
# it, with no copy. Run 9 made about 3 GB of such copies (shared buffers) in the first world frame
# and that growth filled the card's budget. The cap rises to 3072 MB so the windows fit. Not
# measured on this GPU yet: the line "title memory in place" (every 10 s) says what was placed and
# what was turned down.
if ($InPlace) {
    $lowMemory['VICTORY_INPLACE'] = '1'
    $lowMemory['VICTORY_INPLACE_MB'] = '3072'
}

# Caller values (-More) win over this profile.
$merged = @{}
foreach ($k in $lowMemory.Keys) { $merged[$k] = $lowMemory[$k] }
foreach ($k in $More.Keys) { $merged[$k] = $More[$k] }

$victory = Join-Path $PSScriptRoot "..\target\$Build\victory.exe"
if (-not (Test-Path $victory)) {
    # Fall back to the other build when only that one exists (only diag is built by default here).
    $other = if ($Build -eq 'release') { 'diag' } else { 'release' }
    $alt = Join-Path $PSScriptRoot "..\target\$other\victory.exe"
    if (Test-Path $alt) {
        Write-Host "No $victory; using the $other build instead."
        $Build = $other
        $victory = $alt
    } else {
        Write-Host "No $victory. Build it first (README.md)."; exit 1
    }
}
if (-not (Test-Path $Exe)) { Write-Host "No $Exe."; exit 1 }
$Exe = (Resolve-Path $Exe).Path

# Memory pre-flight. On this kind of PC the card's budget is system memory, and the title's
# first world frame grows the process by several GB at once (runs 6 to 8 ended with under
# 0.5 GB free). Shows what is free and what holds it, before and after the run.
function Show-MemoryState([string]$when) {
    $os = Get-CimInstance Win32_OperatingSystem
    $free = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
    Write-Host ("Memory {0}: {1} GB free of {2} GB; commit {3} of {4} GB" -f $when, $free,
        [math]::Round($os.TotalVisibleMemorySize / 1MB, 1),
        [math]::Round(($os.TotalVirtualMemorySize - $os.FreeVirtualMemory) / 1MB, 1),
        [math]::Round($os.TotalVirtualMemorySize / 1MB, 1))
    Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 5 |
        ForEach-Object { Write-Host ("  {0,-24} {1,7} MB" -f $_.Name, [math]::Round($_.WorkingSet64 / 1MB)) }
    $free
}
$freeNow = Show-MemoryState 'before the run'
# Commit headroom: on an iGPU the card's memory is system memory too, and the title's first
# world frame grows the process by several GB. Free RAM alone does not show whether the
# pagefile can take it when RAM runs out.
$osNow = Get-CimInstance Win32_OperatingSystem
$commitFree = [math]::Round($osNow.FreeVirtualMemory / 1MB, 1)
if ($commitFree -lt $MinCommitGB -and -not $Force) {
    Write-Host "Only $commitFree GB of commit left (limit $MinCommitGB GB, -MinCommitGB). Grow the pagefile (System Managed or 16 GB or more), or pass -Force."
    exit 2
}
if ($freeNow -lt $MinFreeGB -and -not $Force) {
    Write-Host "Only $freeNow GB free, under the $MinFreeGB GB limit (-MinFreeGB). Close the biggest programs above (or restart explorer.exe if it is one), or pass -Force to start anyway."
    exit 2
}

# Settings left over in this window from an earlier run (an older version of this script, or
# -InPlace last time) go; where your files are stays. Pass what you want with -More.
$paths = 'VICTORY_CONFIG', 'VICTORY_GAME_DIR', 'VICTORY_CACHE_DIR', 'VICTORY_DATA_DIR', 'VICTORY_FIDELITYFX_DIR'
$inherited = @(Get-ChildItem Env:VICTORY_* | Where-Object { $_.Name -notin $paths })
foreach ($entry in $inherited) { Remove-Item "Env:$($entry.Name)" }
$discarded = $inherited | Where-Object { $_.Name -notin $merged.Keys } | Sort-Object Name
if ($discarded) {
    Write-Host "Discarded inherited values for $($discarded.Name -join ', '). Use -More to pass them explicitly."
}
foreach ($k in $merged.Keys) { Set-Item "Env:$k" $merged[$k] }
# The same launch scripts\play.ps1 makes, with the console chosen here (play.ps1 cannot choose it).
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$victoryArgs = @('run', $Exe, '--execute', '--console', 'series-s')

# Log file: everything victory.exe prints (stdout and stderr) goes to the console and to a
# file, with a header saying exactly what was run. -NoLog turns it off.
$writer = $null
$logPath = $null
if (-not $NoLog) {
    if (-not $LogDir) { $LogDir = Join-Path $repo 'logs' }
    New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
    $logPath = Join-Path $LogDir ("victory-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))
    $writer = New-Object System.IO.StreamWriter($logPath, $false, (New-Object System.Text.UTF8Encoding($false)))
    $writer.AutoFlush = $true   # a crash or a kill still leaves the lines printed so far
    $commit = (& git -C $repo rev-parse --short HEAD 2>$null)
    $gpu = (Get-CimInstance Win32_VideoController | ForEach-Object { "$($_.Name) (driver $($_.DriverVersion))" }) -join '; '
    $writer.WriteLine("# started   $(Get-Date -Format o)")
    $writer.WriteLine("# command   $victory $($victoryArgs -join ' ')")
    $writer.WriteLine("# build     $Build, git $commit")
    $writer.WriteLine("# host      $gpu")
    $writer.WriteLine("# inplace   $InPlace, free RAM before: $freeNow GB")
    foreach ($k in ($merged.Keys | Sort-Object)) { $writer.WriteLine("# env       $k=$($merged[$k])") }
    $writer.WriteLine('# ----')
    Write-Host "Log: $logPath"
}

# Memory timeline next to the log (see memlog.ps1): free RAM and commit, and victory.exe's size.
$sampler = $null
if ($logPath) {
    $memPath = [IO.Path]::ChangeExtension($logPath, '.mem.csv')
    $sampler = Start-Process powershell -WindowStyle Hidden -PassThru -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'memlog.ps1'), '-Out', $memPath)
    Write-Host "Memory timeline: $memPath"
}

$clock = [Diagnostics.Stopwatch]::StartNew()
Push-Location $repo   # victory.toml is looked for here
try {
    # 2>&1 merges stderr; each item is turned into a plain string so PowerShell 5.1 does not
    # print stderr lines as error records.
    & $victory @victoryArgs 2>&1 | ForEach-Object {
        $line = if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { "$_" }
        Write-Host $line
        if ($writer) { $writer.WriteLine($line) }
    }
} finally {
    Pop-Location
    if ($sampler -and -not $sampler.HasExited) { Stop-Process -Id $sampler.Id -Force -ErrorAction SilentlyContinue }
}
$exitCode = $LASTEXITCODE
$clock.Stop()

# Exit code 0 is a clean exit. A large unsigned code is a Windows crash status.
$meaning = switch ($exitCode) {
    0 { 'clean exit' }
    -2005270523 { 'DXGI_ERROR_DEVICE_REMOVED (0x887A0005): the GPU device was lost, look for "out of memory" or "removed" just above' }
    -1073741819 { 'access violation (0xC0000005)' }
    -1073740791 { 'stack buffer overrun (0xC0000409)' }
    -1073741571 { 'stack overflow (0xC00000FD)' }
    -1073740940 { 'heap corruption (0xC0000374)' }
    default { '' }
}
$summary = "Exit code $exitCode $(if ($meaning) { "($meaning) " })after {0:N0} s." -f $clock.Elapsed.TotalSeconds
Write-Host $summary
$after = Show-MemoryState 'after the run'
if ($writer) {
    $writer.WriteLine('# ----')
    $writer.WriteLine("# $summary")
    $writer.WriteLine("# free RAM after: $after GB")
    $writer.Close()
    # Keep the newest 20 logs.
    Get-ChildItem $LogDir -Filter 'victory-*.log' | Sort-Object LastWriteTime -Descending |
        Select-Object -Skip 20 | Remove-Item -ErrorAction SilentlyContinue
    Write-Host "Log saved: $logPath"
}
exit $exitCode
