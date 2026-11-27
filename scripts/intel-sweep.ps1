# Runs the Intel launcher once per setting, unattended, and says which settings the game survives.
#   scripts\intel-sweep.ps1 -Exe <path of your own copy's executable>
# Each run gets -Seconds (default 180: the world starts about 85 s in, and every device removal so
# far came 10 to 35 s after that); a run still alive then is closed by the sweep and counts as
# "survived". A run that ends sooner is reported with how it ended. Every run writes its own log
# and memory timeline in logs\ (play-intel-lowmem.ps1 does that); the table is saved there too.
#   -Only base,skip-fsr4   run just those
#   -List                  show the settings and stop
# Close big programs first: the launcher refuses to start under its free-RAM floor, and the sweep
# then stops. Each run may reset the GPU (a device removal): the screen can go black for a second.
param(
    [Parameter(Mandatory)][string]$Exe,
    [int]$Seconds = 180,
    [int]$PauseSeconds = 20,
    [string[]]$Only,
    [ValidateSet('diag', 'release')][string]$Build = 'diag',
    [string]$Launcher,
    [switch]$List
)

if (-not $Launcher) { $Launcher = Join-Path $PSScriptRoot 'play-intel-lowmem.ps1' }   # (not in the param block: $PSScriptRoot is empty there in Windows PowerShell 5.1)

# name -> what is passed to the launcher on top of -Exe and -Build. In the order of how much each
# tells: what stays when a setting is taken away says what it was.
$experiments = [ordered]@{
    'base'         = @{}
    # the FidelityFX FSR4 compute passes (created at world entry before every hang so far)
    'skip-fsr4'    = @{ SkipFsr4 = $true }
    # every submission waited for: no copy-back thread, nothing sent ahead
    'no-relay'     = @{ More = @{ VICTORY_RELAY = '0' } }
    # mesh draws run their shaders but rasterise one pixel / are not issued at all
    'mesh-scissor' = @{ MeshTest = 'scissor' }
    'mesh-skip'    = @{ MeshTest = 'skip' }
    # least memory
    'lean'         = @{ Profile = 'Lean' }
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
    $names = @($names | Where-Object { $_ -in $Only })
}
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
    [pscustomobject]@{ How = $how; LastFrame = $last; Seconds = $secs }
}

$rows = @()
$n = 0
foreach ($name in $names) {
    $n++
    if (Get-Process -Name victory -ErrorAction SilentlyContinue) {
        Write-Host 'A victory.exe is still running; close it first.'
        break
    }
    Write-Host ("[{0}/{1}] {2}: up to {3} s" -f $n, $names.Count, $name, $Seconds)
    $splat = @{ Exe = $Exe; Build = $Build }
    foreach ($k in $experiments[$name].Keys) { $splat[$k] = $experiments[$name][$k] }
    $started = Get-Date
    $job = Start-Job -ScriptBlock { param($launcher, $splat) & $launcher @splat } -ArgumentList $Launcher, $splat
    $finished = Wait-Job $job -Timeout $Seconds
    $closed = $false
    if (-not $finished) {
        $closed = $true
        Get-Process -Name victory -ErrorAction SilentlyContinue | Stop-Process -Force
        [void](Wait-Job $job -Timeout 90)
    }
    $null = Receive-Job $job -ErrorAction SilentlyContinue
    Remove-Job $job -Force
    $log = Get-ChildItem $logs -Filter 'victory-*.log' -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -ge $started.AddSeconds(-2) } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $log) {
        Write-Host '  No log: the launcher did not start the game (probably the free-RAM floor). Stopping.'
        $rows += [pscustomobject]@{ Setting = $name; Result = 'not started'; Seconds = ''; LastFrame = ''; Log = '' }
        break
    }
    $o = Get-Outcome $log.FullName
    $result = if ($closed) { 'survived' } else { $o.How }
    $secs = if ($closed) { $Seconds } else { $o.Seconds }
    Write-Host ("  {0}, {1} s, last frame {2}" -f $result, $secs, $o.LastFrame)
    $rows += [pscustomobject]@{ Setting = $name; Result = $result; Seconds = $secs; LastFrame = $o.LastFrame; Log = $log.Name }
    if ($n -lt $names.Count) { Start-Sleep -Seconds $PauseSeconds }
}

Write-Host ''
$table = $rows | Format-Table -AutoSize | Out-String
Write-Host $table
$survivors = @($rows | Where-Object { $_.Result -eq 'survived' })
$base = $rows | Where-Object { $_.Setting -eq 'base' }
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
