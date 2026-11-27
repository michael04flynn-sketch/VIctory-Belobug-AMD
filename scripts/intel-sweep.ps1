# Runs the Intel launcher once per setting, unattended, and says which settings the game survives.
#   scripts\intel-sweep.ps1 -Exe <path of your own copy's executable>
# Each run gets -Seconds (default 180: the world starts about 85 s in, and every device removal so
# far came 10 to 35 s after that); a run still alive then is closed by the sweep and counts as
# "survived" when the game had got into the world (frames of 100 ms and more), else "no world":
# that run says nothing, run it again. A run that ends sooner is reported with how it ended. Every run writes its own log
# and memory timeline in logs\ (play-intel-lowmem.ps1 does that); the table is saved there too.
#   -Only base,skip-fsr4   run just those
#   -Repeat n              run each of them n times (three runs of one setting in a row)
#   -Hold                  wait for a game run that is on to end, then keep a placeholder process named victory.exe
#                          alive for the whole sweep, so that no other launcher starts a game run on the card between
#                          two of these runs
#   -List                  show the settings and stop
# Close big programs first: the launcher refuses to start under its free-RAM floor, and the sweep
# then stops. Each run may reset the GPU (a device removal): the screen can go black for a second.
param(
    [Parameter(Mandatory)][string]$Exe,
    [int]$Seconds = 180,
    [int]$PauseSeconds = 20,
    # Passed to the launcher as -MinFreeGB when given (its default is 23).
    [double]$MinFreeGB,
    [string[]]$Only,
    [int]$Repeat = 1,
    [switch]$Hold,
    [ValidateSet('diag', 'release')][string]$Build = 'diag',
    [string]$Launcher,
    [switch]$List
)

if (-not $Launcher) { $Launcher = Join-Path $PSScriptRoot 'play-intel-lowmem.ps1' }   # (not in the param block: $PSScriptRoot is empty there in Windows PowerShell 5.1)

# name -> what is passed to the launcher on top of -Exe and -Build. In the order of how much each
# tells: what stays when a setting is taken away says what it was.
$experiments = [ordered]@{
    # the launcher as it is: on an Intel GPU the host skips the title's mesh draws (the others below draw them)
    'default'      = @{ MeshTest = '' }
    'base'         = @{}
    # the FidelityFX FSR4 compute passes (created at world entry before every hang so far)
    'skip-fsr4'    = @{ SkipFsr4 = $true }
    # every submission waited for: no copy-back thread, nothing sent ahead
    'no-relay'     = @{ More = @{ VICTORY_RELAY = '0' } }
    # mesh draws run their shaders but rasterise one pixel / are not issued at all
    'mesh-scissor' = @{ MeshTest = 'scissor' }
    'mesh-skip'    = @{ MeshTest = 'skip' }
    # the six mesh shaders whose hashes end in 40 (scripts\intel-mesh-bisect.ps1: that bucket hung
    # alone, run of 2026-11-27 11:08), skipped: if this survives they are the cause
    'skip-40'      = @{ SkipPipelines = '0384efa1b7bcd540,0d9d1c59733d6340,15ac5676f1960a40,4332a100adad3d40,70c4f59493d78540,a56a584996afb040' }
    # only the four depth-only cascade shadow mesh shaders (MS_VS_CascadeShadows_draw, a straight-line
    # program of 628 lines that stopped the card with one group), and everything but them
    'mesh-shadows-only' = @{ MeshTest = 'only:05393503e72397a3,45ace4127ac61cfd,d42a640660651285,f507ff49d4aadd4b' }
    'mesh-no-shadows'   = @{ SkipPipelines = '05393503e72397a3,45ace4127ac61cfd,d42a640660651285,f507ff49d4aadd4b' }
    # the shadow shaders alone, with a barrier on all work after each dispatch (a hang that goes is a race
    # between draws), and with no groups in the dispatch (a hang that stays is in the pipeline's state)
    'shadows-fence'     = @{ MeshTest = 'only:05393503e72397a3,45ace4127ac61cfd,d42a640660651285,f507ff49d4aadd4b'; More = @{ VICTORY_MESH_FENCE = '1' } }
    'shadows-zero'      = @{ MeshTest = 'only:05393503e72397a3,45ace4127ac61cfd,d42a640660651285,f507ff49d4aadd4b'; More = @{ VICTORY_MESH_ZERO = '1' } }
    # nothing is ever let go (host copies of title buffers and textures stay): if the hang goes, a view in
    # the heap that a shader picks by an index reads memory the host had given back
    'no-sweep'     = @{ More = @{ VICTORY_SWEEP = '0'; VICTORY_TEXTURE_SWEEP = '0' } }
    # the debug layer with GPU-based validation (descriptor kinds and ranges of what shaders pick
    # from the heap by an index; very slow, so give it -Seconds 420 or more)
    'gbv'          = @{ D3dDebug = $true; Profile = 'Lean'; More = @{ VICTORY_D3D12_GBV = '1' } }
    # every title buffer's copy in the PC's memory (the card's own copies are copied into with
    # COPY_DEST states that the debug layer found read as shader resources without a barrier)
    'card-off'     = @{ More = @{ VICTORY_CARD_BUFFERS = '0' } }
    # a host heap of one slot bound for the sampler / view heap the title did not set (the debug
    # layer: SetComputeRootSignature before a sampler heap, 114 times in a run)
    'fallback-heaps' = @{ More = @{ VICTORY_FALLBACK_HEAPS = '1' } }
    # descriptor reads as data by plain loads instead of getDimensions on a picked handle
    'no-getdims'   = @{ More = @{ VICTORY_NO_GETDIMS = '1' } }
    # mesh draws on and the device-removed data (D3D12's auto breadcrumbs, which the launcher turns on to light by default and
    # which put a marker write after every command of every list) off
    'dred-off'     = @{ Dred = 'off' }
    # the same with the full device-removed data (a text for every command: the report names the copy or draw that
    # does not finish; slower)
    'base-dred'    = @{ Dred = 'full' }
    # the title's own counts of vertices and primitives in the mesh programs instead of the declared maxima
    # (VICTORY_MESH_COUNTS=exact: docs\intel-arc.md), mesh draws on
    'exact'        = @{ More = @{ VICTORY_MESH_COUNTS = 'exact' } }
    'exact-dred'   = @{ Dred = 'full'; More = @{ VICTORY_MESH_COUNTS = 'exact' } }
    # the one mesh program (MS_VS_Transform_4dbafe93, with its pixel shader 3711fdad456538a1) whose ExecuteIndirect was
    # the first command not finished in two runs (command 107 of a list of 160, 14 s after its pipeline's first bind):
    # its draws alone, and every draw but its own
    'only-ea2e'    = @{ MeshTest = 'only:ea2eadde55090b27' }
    'skip-ea2e'    = @{ SkipPipelines = 'ea2eadde55090b27' }
    # indirect mesh executions (most of the title's mesh draws), each issued with a count of 0 (the clamp and all state
    # as before: nothing runs), and with a barrier on all work after each / every 8th one
    'ind-zero'     = @{ More = @{ VICTORY_MESH_INDIRECT = 'zero' } }
    'ind-fence'    = @{ More = @{ VICTORY_MESH_INDIRECT = 'fence:1' } }
    'ind-fence8'   = @{ More = @{ VICTORY_MESH_INDIRECT = 'fence:8' } }
    # every mesh draw, direct and indirect, issued empty (zero groups, a count of 0): all the state of a draw and no work
    'all-zero'     = @{ More = @{ VICTORY_MESH_ZERO = '1'; VICTORY_MESH_INDIRECT = 'zero' } }
    # the three above together (if this one hangs too, none of them is the cause alone)
    'all-three'    = @{ More = @{ VICTORY_CARD_BUFFERS = '0'; VICTORY_FALLBACK_HEAPS = '1'; VICTORY_NO_GETDIMS = '1' } }
    # memory against CPU time, with the host's default (no mesh draws: the settings that stay stable); compare
    # the frame times in the logs (scripts do not average them: `ms/frame` lines of the world)
    'lean'         = @{ Profile = 'Lean'; MeshTest = '' }
    'fast'         = @{ Profile = 'Fast'; MeshTest = '' }
    # the card's budget as the system gives it
    'uma-off'      = @{ More = @{ VICTORY_UMA_HEADROOM = '0' } }
}
function Format-Setting($value) {
    if ($value -is [bool]) { return '' }
    if ($value -is [hashtable]) { return '@{' + (($value.Keys | ForEach-Object { "$_='$($value[$_])'" }) -join '; ') + '}' }
    "$value"
}
if ($List) {
    foreach ($name in $experiments.Keys) {
        $shown = ($experiments[$name].Keys | ForEach-Object { ("-$_ " + (Format-Setting $experiments[$name][$_])).Trim() }) -join ' '
        "{0,-13} {1}" -f $name, $(if ($shown) { $shown } else { '(as the launcher is)' })
    }
    return
}
$names = @($experiments.Keys)
if ($Only) {
    $Only = @($Only | ForEach-Object { $_ -split ',' } | Where-Object { $_ })   # (-File passes a comma list as one string)
    $unknown = @($Only | Where-Object { $_ -notin $names })
    if ($unknown) { Write-Host "Unknown: $($unknown -join ', '). Known: $($names -join ', ')"; exit 1 }
    $names = @($Only)   # in the order given, repeats too (-Only base-dred,exact,exact)
}
# Each setting $Repeat times, in the order given.
$seen = @{}
$plan = @(foreach ($name in $names) {
    foreach ($k in 1..$Repeat) {
        $seen[$name] = 1 + [int]$seen[$name]
        [pscustomobject]@{ Name = $name; Label = $(if ($seen[$name] -gt 1 -or $Repeat -gt 1) { "$name#$($seen[$name])" } else { $name }) }
    }
})
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$logs = Join-Path $repo 'logs'
New-Item -ItemType Directory -Force -Path $logs | Out-Null

# What a log says about how the run ended.
function Get-Outcome([string]$path) {
    $text = [IO.File]::ReadAllText($path)
    $how = 'ended'
    if ($text -match '0x887A0006') { $how = 'hung (0x887A0006)' }
    elseif ($text -match '0x8007000E') { $how = 'out of memory (0x8007000E)' }
    elseif ($text -match '0x887A0005') { $how = 'device removed (0x887A0005)' }
    elseif ($text -match 'panicked at') { $how = 'panic' }
    $frames = [regex]::Matches($text, 'frame=(\d+)') | ForEach-Object { [int]$_.Groups[1].Value }
    $last = if ($frames) { ($frames | Measure-Object -Maximum).Maximum } else { 0 }
    $secs = $null
    if ($text -match '# Exit code (-?\d+)[^\r\n]*? after (\d+) s') { $secs = [int]$Matches[2] }
    # Whether the game got into the world: its frames take 300 ms and more, the front end's 33 ms.
    # (A run that stays at the front end for the whole time proves nothing about the hang; 3 of 9
    # runs of one session did.)
    $slowest = 0.0
    foreach ($m in [regex]::Matches($text, '([0-9.]+) fps, ([0-9.]+) ms/frame')) {
        $slowest = [math]::Max($slowest, [double]::Parse($m.Groups[2].Value, [Globalization.CultureInfo]::InvariantCulture))
    }
    [pscustomobject]@{ How = $how; LastFrame = $last; Seconds = $secs; World = ($slowest -ge 100) }
}

$holder = $null
if ($Hold) {
    $waited = 0
    while (Get-Process -Name victory -ErrorAction SilentlyContinue | Where-Object { $_.Path -notlike '*victory-fuzz*hold*' }) {
        if ($waited -ge 900) { Write-Host 'A victory.exe is still running after 15 minutes: stopping.'; exit 1 }
        if ($waited -eq 0) { Write-Host 'A victory.exe is running; waiting for it to end.' }
        Start-Sleep -Seconds 2
        $waited += 2
    }
    $holdDir = Join-Path $env:TEMP 'victory-fuzz\hold'
    New-Item -ItemType Directory -Force -Path $holdDir | Out-Null
    Copy-Item -Force (Join-Path $env:SystemRoot 'System32\ping.exe') (Join-Path $holdDir 'victory.exe')
    $holder = Start-Process -FilePath (Join-Path $holdDir 'victory.exe') -ArgumentList @('-n', '3600', '127.0.0.1') -WindowStyle Hidden -PassThru
    Write-Host "Holding the card (placeholder process $($holder.Id), at most an hour)."
}
$others = { Get-Process -Name victory -ErrorAction SilentlyContinue | Where-Object { $_.Path -notlike '*victory-fuzz*hold*' } | Where-Object { -not $holder -or $_.Id -ne $holder.Id } }

$rows = @()
$n = 0
try {
foreach ($item in $plan) {
    $n++
    $name = $item.Name
    if (& $others) {
        Write-Host 'A victory.exe is still running; close it first.'
        break
    }
    Write-Host ("[{0}/{1}] {2}: up to {3} s" -f $n, $plan.Count, $item.Label, $Seconds)
    # Mesh draws on, unless the setting says otherwise: the host skips them on an Intel GPU by default.
    $splat = @{ Exe = $Exe; Build = $Build; MeshTest = 'off' }
    if ($PSBoundParameters.ContainsKey('MinFreeGB')) { $splat['MinFreeGB'] = $MinFreeGB }
    foreach ($k in $experiments[$name].Keys) { $splat[$k] = $experiments[$name][$k] }
    $started = Get-Date
    $job = Start-Job -ScriptBlock { param($launcher, $splat) & $launcher @splat } -ArgumentList $Launcher, $splat
    $finished = Wait-Job $job -Timeout $Seconds
    $closed = $false
    if (-not $finished) {
        $closed = $true
        Get-Process -Name victory -ErrorAction SilentlyContinue | Where-Object { $_.Path -notlike '*victory-fuzz*hold*' } | Stop-Process -Force
        [void](Wait-Job $job -Timeout 90)
    }
    $null = Receive-Job $job -ErrorAction SilentlyContinue
    Remove-Job $job -Force
    $log = Get-ChildItem $logs -Filter 'victory-*.log' -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -ge $started.AddSeconds(-2) } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $log) {
        Write-Host '  No log: the launcher did not start the game (probably the free-RAM floor). Stopping.'
        $rows += [pscustomobject]@{ Setting = $item.Label; Result = 'not started'; Seconds = ''; LastFrame = ''; Log = '' }
        break
    }
    $o = Get-Outcome $log.FullName
    $result = if ($closed -and -not $o.World) { 'no world' } elseif ($closed) { 'survived' } else { $o.How }
    $secs = if ($closed) { $Seconds } else { $o.Seconds }
    Write-Host ("  {0}, {1} s, last frame {2}" -f $result, $secs, $o.LastFrame)
    $rows += [pscustomobject]@{ Setting = $item.Label; Result = $result; Seconds = $secs; LastFrame = $o.LastFrame; Log = $log.Name }
    if ($n -lt $plan.Count) { Start-Sleep -Seconds $PauseSeconds }
}
} finally {
    if ($holder -and -not $holder.HasExited) { $holder.Kill() }
}

Write-Host ''
$table = $rows | Format-Table -AutoSize | Out-String
Write-Host $table
$survivors = @($rows | Where-Object { $_.Result -eq 'survived' })
$base = $rows | Where-Object { $_.Setting -eq 'base' -or $_.Setting -like 'base#*' }
if ($survivors.Count -eq 0) {
    Write-Host 'No setting survived. The hang does not depend on any of them; the logs name the command it stops at.'
} elseif ($base -and $base.Result -eq 'survived') {
    Write-Host 'The base setting survived: nothing to bisect (try a longer -Seconds).'
} else {
    Write-Host ("Survived: {0}. What those settings take away is where to look." -f (($survivors | ForEach-Object { $_.Setting }) -join ', '))
}
$saved = Join-Path $logs ("sweep-{0:yyyyMMdd-HHmmss}.txt" -f (Get-Date))
$table | Out-File -FilePath $saved -Encoding utf8
Write-Host "Saved: $saved"
