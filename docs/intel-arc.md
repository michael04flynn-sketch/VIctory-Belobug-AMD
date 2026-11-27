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

## Second run (2026-11-27, with `-Probe` and the memory timeline)

Same end, 45 s in, frame 1034: command list failed to close with E_OUTOFMEMORY, device removed.

- `victory.exe` private bytes grew from 7.3 to 14.1 GB (working set 6 to 17.9 GB) in the last
  10 s. Free RAM at the end was still 4.6 GB and free commit about 30 GB: not a RAM or pagefile
  limit. The limit is the GPU's local memory budget, which was 9,208 MB and moved between 8,092
  and 8,599 MB as free RAM fell.
- Card use went from 5.4 GB to 8.1 GB in about 2 s: shared buffer copies from 0.35 to 3.1 GB
  (the pass that makes buffer views ready for shaders that pick them by index: 77,216 views,
  4,010 copies, 1,930 MB), on top of 2.9 GB of texture blocks and 2.1 GB of title-filled textures.
- Census of title memory (`-Probe`): 42,632 views of physical pages (6,826 MB), 42,626 of them one
  64 KiB page; four reserved sections (220, 297, 185 and 3,977 MB) that the host refuses as heaps.
  Only 2 of 12 MB of private committed memory could be opened. So `-InPlace` cannot cover the
  title's memory here (77 windows, 368 MB placed, 488 turned down).

Change made for it: on a UMA GPU the always-allowed texture host copies start at 1 GiB instead of
2 GiB (`VICTORY_TEXTURE_FLOOR_MB` sets it). That is about 1 GB less before the burst; not
measured yet.

## Not known yet

- Whether the process itself or other programs took the RAM (the `.mem.csv` of the next run).
- Which title memory kinds block `-InPlace` (`-Probe` logs a census 30 s and 150 s in).
- Whether any change to the buffer-copy pass is needed or safe.
