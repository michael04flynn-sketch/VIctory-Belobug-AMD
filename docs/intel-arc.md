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

## Third run (2026-11-27, with the 1 GiB texture floor)

Ended at 36 s, frame 734, before the first world frame, so the floor change is still untested.
Cause: a panic in the performance panel (`VICTORY_PANEL=1`), `clamp(0, -156250)` in the per-core
CPU meter: a core's counters went backwards between two looks (a parked core on a hybrid CPU).
A panic there cannot unwind and aborted the process (exit 0xC0000409). Fixed: such a look counts
as an idle core, and a panel failure is caught and logged instead of ending the run.

## Fourth run (2026-11-27, panel fixed, 1 GiB texture floor)

Reached the first world frame (frame 1001, 53 s) and ended with the device removed (0x887A0005,
after 0x887A0006: a 3.4 s stall preparing one submission, with free RAM at 1.2 GB).

- This time the GPU's local budget was 14,978 MB, not 9,208 MB: on a UMA GPU it follows free
  RAM, so it is no limit worth going by. The card's own use peaked at 9.0 GB, well under it.
- The limit was physical RAM. `victory.exe` working set went from 6.4 GB to 19.8 GB (private
  bytes 7.5 to 15.6 GB) in about 15 s; free RAM from 13.6 GB to 1.2 GB, with Memory Compression
  active. Before the run there were 20.8 GB free.
- Of that growth the card's accounting explains about 3.4 GB; the rest is title memory touched
  as the world loads, which the host does not control.
- The 1 GiB floor did not hold the title-filled texture copies down (2,451 MB were made): the
  layer's rule beyond the floor goes by the budget, which was large.

Changes for it, in the launcher: `-TextureCapMB` (default 1024, sets `VICTORY_TEXTURE_BUDGET_MB`)
and `-MinFreeGB` 23. Not measured. With 31 GB of RAM this machine is at the edge: the title needs
about 20 GB of working set by the first world frame.

## Fifth run (2026-11-27, texture cap 1024 MB, 25.9 GB free before)

Reached frame ~1000 (53 s) and ended again, but this time not for memory: working set 18.3 GB,
free RAM never under 6.9 GB, no E_OUTOFMEMORY. The device was removed as HUNG (0x887A0006, then
0x887A0005) after the submitting thread spent 3.3 s preparing one submission, with 13 submissions
sent ahead. Windows' default timeout (`TdrDelay` 2 s, default here) resets a GPU that works that
long on one piece of work; whether the world's first frame is that slow on this iGPU is not
established. The log said "no breadcrumbs" because the Intel launcher did not set
`VICTORY_D3D12_DRED` (scripts\play.ps1 does).

Changes: the launcher sets `VICTORY_D3D12_DRED=light` by default (`-Dred off|light|faults`), has
`-D3dDebug`, and after a run reads its log: on 0x887A0006 it prints the `TdrDelay` registry
command (to run elevated by hand; the launcher changes no system setting) and on 0x8007000E it
points at the memory timeline. Pipeline-library notes: 40 of 61,293 pages of the 251 MB library
read as zeros and some pipelines were remade ("The parameter is incorrect", 0x80070057); not
shown to matter.

## Sixth run (2026-11-27, device-removed data on)

Ended at 64 s, frame 1252, hung device (0x887A0006) again; RAM was fine (free never under 6.2 GB
until the process died, working set 18.6 GB). `TdrDelay` is not set on this machine (2 s).

- DRED names the list: list 448 of 689 had finished 53 of its 86 commands. The commands around
  the stop are indirect mesh executions (kind 10, max 1), for example
  `[mesh 3c067b199b10fea2, pixel 3ec62ecabb36f1d2]`, `[mesh 85eaffa59a3a6ecf, pixel b352dd911b665364]`,
  `[mesh 53a2a19cf91c6088, pixel 8b901a7fb38c169b]`. The device-removed report gives the page of
  each command's view slots; those slots are placed buffers in title memory.
- Frames at that point took 0.35 to 3.1 s (frame 1244: 3.1 s); the removal came 3.6 s after frame
  1252 began, with the submitting thread 3.3 s into one list. So a single list running past the
  2 s timeout is the likeliest reading, but a bad command is not excluded: the data does not say
  which. The test that tells them apart is a larger `TdrDelay` (30): if the run then goes on, it
  was slowness.

The launcher now notes a low `TdrDelay` before the run (read-only) and prints the first command
the device-removed data names after a hang.

## Seventh run (2026-11-27, `TdrDelay` 30 read by the host)

Ended at 58 s, frame 1142, hung device (0x887A0006) again. Both runs with device-removed data
(the sixth and this one) name the same draw as the first command that did not finish:

| Run | List | Done / recorded | First unfinished command |
|---|---|---|---|
| sixth | 448 of 689 | 53 / 86 | 53: `[mesh 85eaffa59a3a6ecf, pixel b352dd911b665364]` |
| seventh | 485 of 735 | 48 / 90 | 48: `[mesh 85eaffa59a3a6ecf, pixel b352dd911b665364]` |

It is an indirect mesh execution (kind 10, max 1) that reads a 43 MB placed buffer (895,654
elements of 48 bytes) and a 998,400-byte one; the commands around it (`3c067b199b10fea2`,
`53a2a19cf91c6088`, `8321022826281144`) use the same views.

- The same draw in two runs points at a fault in that draw, not at load. The hang was reported
  3.2 to 3.7 s into the list in every run, including this one with `TdrDelay` 30 in the registry;
  whether that value was in force in Windows (it is read at start-up) is not known, so slowness is
  not ruled out by this alone.
- `lower.rs` marks a known gap (`mesh_prologue`): a mesh shader whose outputs pass the host's 32 KiB
  even at its lane count is emitted anyway ("drivers take them; refuse them here if one hangs").
  Whether `85eaffa59a3a6ecf` is such a shader is not established.

Experiments, both in the launcher: `-MeshStrict` is on by default (`-NoMeshStrict` turns it off;
`VICTORY_MESH_OUTPUT_STRICT=1`): such shaders are refused and their draws dropped. `-SkipPipelines
85eaffa59a3a6ecf` skips that shader's draws (diag build) to test whether it is the one. After a hang
the launcher prints the first unfinished command and its pipeline from the log.

## CPU and GPU load (from the seventh run's frame statistics)

Last statistics block before the hang (frames of roughly 0.3 s, so about 3 fps):

- The card was about 25 % busy: 241.7 ms a frame with nothing of ours queued, 163.1 ms of it while
  the submitting thread was still preparing (the card idle behind it).
- The submitting thread spent 113 ms in the lists' steps and 90.7 ms waiting for flights; texture
  refreshes took 174.5 ms across threads, 148.9 ms of it waiting for the runtime to stop remapping
  title memory.
- 2,601 MB a frame of title buffer copies were compared on the CPU (2,579 MB snapshotted), 2,567
  MB of them in copies of 1 MiB or more. The log says `VICTORY_CARD_BUFFERS_MIN_MB=1` would have the
  card look there; the real limiter is the cap the launcher set, 128 MB (`VICTORY_CARD_BUFFERS_MB`).
- The process kept its threads on 4 fast cores of 16 (`our threads' processors`); the code has an
  opt-in for exactly this part (`VICTORY_FAST_WIDE=1`: four performance cores, eight efficiency
  cores on one cache, "not measured on a title yet").

So the frame is CPU-bound and the card idles. Changes, in the launcher and not measured: 
`VICTORY_FAST_WIDE=1` by default (`-NoFastWide`) and `-CardBuffersMB` 512 instead of 128. More
buffers on the card means more system memory used (written buffers count twice), so watch
`.mem.csv`. After a run the launcher prints the last card-busy figure and the MB compared on
the CPU; those are the two numbers to compare between settings. None of this can matter until a
run gets past the hang at the mesh draw above.

## Memory against CPU time: launcher profiles

What the seventh run (128 MB card buffers, 1024 MB texture cap, no wide helpers) reached before the
hang, from its log and `.mem.csv`: lowest free RAM 6.2 GB, peak `victory.exe` working set 18.0 GB,
card use 8.3 GB at frame 1132 (budget 14,978 MB, which follows free RAM on this GPU). Of that
8.3 GB: 3.2 GB shared buffer copies (4,622 buffers), 1.8 GB texture blocks, 2.1 GB host copies
(1.0 GB of them title-filled textures, now capped), 0.7 GB upload buffers, 0.3 GB staging.
The 1024 MB cap did what it says: title-filled texture copies 2,451 MB (uncapped, fourth run)
against 1,039 MB.

CPU time and memory pull the other way. A card copy of a title buffer keeps a CPU-side copy and a
card-side copy (a third, "before", when shaders write it), all system memory on this GPU, in return
for the card comparing it instead of the CPU (2.6 GB a frame were compared on the CPU). So the
launcher has `-Profile Lean` (128 / 768 MB: least memory), `Balanced` (512 / 1024, default) and
`Fast` (1024 / 1536), setting `-CardBuffersMB` and `-TextureCapMB` unless they are passed. After a run
it prints the lowest free RAM and peak working set next to the card-busy and CPU-compare figures, so
two profiles can be compared on the same four numbers. Which profile is better on this machine is
not known: no run has lived long enough to measure frame time.

## Not known yet

- Whether the process itself or other programs took the RAM (the `.mem.csv` of the next run).
- Which title memory kinds block `-InPlace` (`-Probe` logs a census 30 s and 150 s in).
- Whether any change to the buffer-copy pass is needed or safe.
