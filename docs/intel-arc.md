# Running on an Intel Arc iGPU (shared memory)

Measured on one machine only: Intel Arc B390 (driver 32.0.101.8724), 31 GB RAM, Windows 11,
title dump 1.0.2.1, `--console series-s`, `diag` build. One run so far; treat every number as a
single data point.

## What the host reports

| Query | Value |
|---|---|
| Wave lanes (`WaveLaneCountMin` / `Max`) | 16 / 32 |
| `DedicatedVideoMemory` | 128 MB (a carve-out, not the card's memory) |
| Memory architecture | UMA true, cache-coherent UMA false, isolated MMU true |
| Local memory budget (DXGI) | about 9.2 GB at start; it follows free RAM and fell to 7.6 GB |
| Shared (non-local) budget | 0 |
| View heap | refused above 1,008,571 views; settles at 1,000,000 (`raw_twins=false`) |

The card's memory is the PC's memory. Free RAM is the real limit, not the VRAM figure.

## How to run

```powershell
cargo build --locked --profile diag -p victory --features diagnostics
target\diag\victory.exe shaders <the shader archives>
scripts\play-intel-lowmem.ps1 -Exe <path of your copy's executable> -Build diag -Probe -More @{VICTORY_PANEL='1'}
```

Close browsers, remote-desktop tools and anything large first. The launcher refuses to start
under 20 GB free RAM or 20 GB free commit (`-MinFreeGB`, `-MinCommitGB`, `-Force` overrides).

Each run writes `logs\victory-<time>.log` and `logs\victory-<time>.mem.csv` (free RAM, free
commit, `victory.exe` working set and private bytes, once a second). The newest 20 are kept.

## Known result (2026-11-27)

The run reached the first world frame (frame 1217, 54 s in) and ended there. Inside that
frame free RAM fell from 17.9 GB to 2.9 GB: about 3.2 GB of shared buffer copies (4,183
buffers), a 2 GB title-filled texture, and GPU memory use rising from 5.1 to 8.1 GB of an 8.2 GB
budget. A host command list then failed to close with E_OUTOFMEMORY (0x8007000E) and the
device was removed (exit code 0x887A0005).

- `-InPlace` placed 352 MB and turned down 237 windows (page-pool view memory, which the host
  cannot open as a heap). It did not reduce the burst.
- The FSR4 passes fall back (`DeserializeComputePipelineStateX FAILED`) and the host policy
  refuses `amd_fidelityfx_upscaler_xbox.dll`. Expected on this hardware; not a cause.
- 198 shaders do not translate: 195 containers with no vertex, pixel, compute or mesh program,
  and 3 with a lane mask exchanged where not every lane runs (cause on Intel not established).

## Not known yet

- Whether the process itself or other programs took the RAM (the `.mem.csv` of the next run).
- Which title memory kinds block `-InPlace` (`-Probe` logs a census 30 s and 150 s in).
- Whether any change to the buffer-copy pass is needed or safe.
