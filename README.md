# ztrx

**ztrx** runs the Xbox Series build of the game natively on Windows PCs with
NVIDIA graphics cards, from game files you supply yourself.

**This repository contains no game files or assets.** You need your own copy
of the game. Not affiliated with or endorsed by its developer or publisher.

## Status (2026-11-25)

Tested on Windows 11 with an **NVIDIA GeForce RTX 3050** (8 GB):

| | |
|---|---|
| Boot, first-boot screens, intro, opening credits | works |
| Prologue | playable from the cell to the boat chase: cell, cafeteria, robbery, police chase (wanted level, minimap), boat, binoculars |
| Stability | 1 h 30 min+ in one session without a crash |
| Frame rate | 1-3 fps in the world (the first run is slower while shaders translate; they are cached after that) |
| Known problems | anything in shadow is black and bright scenes overexpose (the game's ray-traced lighting does not run yet); some blocky artifacts; boats sit low in the water |

## Requirements

- Windows 10/11 x64, a CPU with AVX2
- A Direct3D 12 GPU with shader model 6.6 and mesh shaders (NVIDIA RTX 20 series or newer)
- Rust (the version in `rust-toolchain.toml`)
- Several GB of free Windows commit memory (raise the paging file if `crashes.log` reports error 1455)

## Build

```powershell
cargo build --release -p victory
```

## Play

```powershell
powershell -ExecutionPolicy Bypass -File scripts\play.ps1 -Game "<your game folder>\<the game's exe>"
```

`scripts\play.ps1` keeps the shader cache and saves in folders you choose
(`-Cache`, `-Data`) and presses no buttons for you. Controller: XInput pads
(a DualShock/DualSense through DS4Windows works). With no pad connected the
keyboard acts as one while the game window has focus.

## Faster settings (on by default)

These used to be opt-in. Each one can be turned back off for a comparison,
or if it shows a problem, by setting the value in the right column.

| Setting | Turn off |
|---|---|
| CPU and GPU work at the same time: submissions go ahead, what shaders wrote comes back on its own thread (`VICTORY_RELAY=2`) | `VICTORY_RELAY=0` (`=1`: first stage only) |
| Snapshots and compares, refreshes, and merges on several threads | `VICTORY_WIDE_BACK=0`, `VICTORY_WIDE_REFRESH=0`, `VICTORY_WIDE_MERGE=0` |
| Texture refreshes do not wait for the runtime's remapping (a texture may show a frame later) | `VICTORY_TEXTURE_NO_WAIT=0` |
| Title buffer copies that follow each other done as one | `VICTORY_JOIN_COPIES=0` |
| The card's re-hash passes joined into runs | `VICTORY_CARD_REHASH_RUNS=0` |
| Up to 512 MB of the title's loose memory (vertices, indices, constants) kept in the card's memory instead of read over the bus, while a fifth of the card's budget is free | `VICTORY_CARD_WINDOWS_MB=0` (or another size in MB) |

Also: the card compares its copies with a group of 256 threads per 64 KiB
piece instead of one thread; the device is made on the high-performance
adapter (the discrete card on a laptop, named as `host adapter` in the log);
release builds use fat LTO, one codegen unit and `x86-64-v3` (AVX2).

## Title memory in place (experiment, off by default)

`VICTORY_INPLACE=1`: memory the card reads outside title buffers is not
copied for it; the card reads the title's own bytes (no copy, no refresh,
no copy-back), as the console does. `VICTORY_POOL_COMMIT=1` with it also
covers the title's physical page pool: the pool is then committed whole at
the start (about 6 GB of commit, so the paging file needs room; if Windows
refuses, it is reserved as before and stays copied). The log line `title
memory in place` says how much is in place.

## Measuring the frame rate

```powershell
powershell -ExecutionPolicy Bypass -File scripts\bench.ps1 -Game "<your game folder>\<the game's exe>"
```

`scripts\bench.ps1` runs the game once per set of switches (`-Configs`; by
default the faster settings, then all of them off, then each one off on its own), for
`-Seconds` each, then prints a table of the frame-rate lines: fps, and per
frame the time preparing (copies, textures), waiting for the GPU and copying
back. Get to the same place in every run (same save, standing still), or use
the diagnostics build with `-Keys`. `-MinDraws` leaves out menu frames.

## Debugging switches

| Switch | Effect |
|---|---|
| `VICTORY_CAPTURE=<dir>` + `VICTORY_CAPTURE_FRAMES=<list>` | save those frames as PNG (diagnostics build) |
| `VICTORY_KEYS=30:Enter,35:X` | press keys at those seconds (diagnostics build) |
| `VICTORY_D3D12_DRED=1` | on a GPU failure, report the commands in flight |
| `VICTORY_PIPELINE_WAIT_MS=24` | shorter per-frame wait for pipelines still being built |

Diagnostics build: `cargo build --profile diag -p victory --features diagnostics`

## License

GPL-3.0-or-later (see `LICENSE`). Based on VIctory (Marvisak) and victory-fork (fxceless).
