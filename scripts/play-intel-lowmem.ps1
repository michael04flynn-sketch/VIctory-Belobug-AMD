# Low-memory profile for Intel GPUs at 1080p, aiming at 30 fps.
# Starts the title through scripts\play.ps1 with the Series S profile (1920x1080 output,
# 1280x720 rendering) and smaller caches for card memory (VRAM) and system memory (RAM).
#   scripts\play-intel-lowmem.ps1 -Exe <path of your own copy's executable>
# -Build        release (the default, faster) or diag
# Extra settings may be passed the same way as play.ps1: -More @{VICTORY_PANEL='1'}
# Measurements of this profile on Intel hardware: none yet. Check the frame time with
# VICTORY_PANEL=1 and VRAM in Task Manager before relying on it.
param(
    [Parameter(Mandatory)][string]$Exe,
    [ValidateSet('diag', 'release')][string]$Build = 'release',
    [hashtable]$More = @{}
)

# Memory knobs (values in MB unless the name says KB). Each one lowers how much is kept
# ready at once, at the cost of textures arriving a little later.
$lowMemory = @{
    # Texture queue stops filling the card at 65 % of its budget (default 90).
    VICTORY_TEXTURE_ROOM_PERCENT      = '65'
    # Cap on the texture bytes the layer may hold beyond the card's own budget logic.
    VICTORY_TEXTURE_BUDGET_MB         = '1536'
    # Title buffers copied into card memory: smaller cap, and only buffers of at least 1 MB.
    VICTORY_CARD_BUFFERS_MB           = '256'
    VICTORY_CARD_BUFFERS_MIN_KB       = '1024'
    # Card memory kept free for render targets not made yet (default 1536 on Series S).
    VICTORY_CARD_ROOM_FOR_TARGETS_MB  = '1024'
    # Window copies and in-place title memory (system memory).
    VICTORY_INPLACE_MB                = '512'
    VICTORY_KEEP_SNAPSHOTS_MB         = '64'
    VICTORY_SNAPSHOT_POOL             = '128'
    # Staging buffers for texture uploads (system memory).
    VICTORY_TEXTURE_STAGE_MB          = '256'
    # Textures are uploaded ahead of need less often (default 12 ms a frame).
    VICTORY_EARLY_TEXTURES_MS         = '6'
    # Bytes of picked views checked per frame (default 32): less CPU time and memory traffic each frame.
    VICTORY_PICKED_MB                 = '8'
    # Budgets of the smaller PC: the layer's residency logic uses its small-machine limits.
    VICTORY_RESIDENCY_LIMITED         = '1'
}

# Settings of play.ps1 that stay in force for this profile. Caller values win.
$merged = @{}
foreach ($k in $lowMemory.Keys) { $merged[$k] = $lowMemory[$k] }
foreach ($k in $More.Keys) { $merged[$k] = $More[$k] }

$victory = Join-Path $PSScriptRoot "..\target\$Build\victory.exe"
if (-not (Test-Path $victory)) { Write-Host "No $victory. Build it first (README.md)."; exit 1 }
if (-not (Test-Path $Exe)) { Write-Host "No $Exe."; exit 1 }
$Exe = (Resolve-Path $Exe).Path
foreach ($k in $merged.Keys) { Set-Item "Env:$k" $merged[$k] }
# The same launch scripts\play.ps1 makes, with the console chosen here (play.ps1 cannot choose it).
Push-Location (Join-Path $PSScriptRoot '..')   # victory.toml is looked for here
try { & $victory run $Exe --execute --console series-s } finally { Pop-Location }
