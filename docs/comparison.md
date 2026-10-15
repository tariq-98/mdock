# mdock compared with Docker Desktop

Measured on an M1 with 16 GB of RAM, macOS 26.6, against Docker Desktop 4.37.2.

mdock's design started from a study of how Docker Desktop runs Linux on this Mac: it keeps `.cached` +
`.fsync` disks (mdock does too), sends all guest traffic through a userspace gVisor network stack
(mdock uses the kernel's vmnet) and defaults to 2 CPUs and 4 GiB (mdock uses the whole machine).

## The usual Docker-on-Mac problems, and what mdock does about them

| Problem | mdock | Measured (M1) |
|---|---|---|
| **Intel images need emulation** | Rosetta for linux/amd64 and FEX for linux/386 (and linux/amd64 on the GPU engine), both keeping x86's memory order in hardware on mdock's guest kernel ([x86.md](x86.md)). Rosetta's ahead-of-time cache is an option (`mdock set aot=on`); it's off by default because Apple's AOT translator crashes on or miscompiles some programs, Node's Alpine builds among them. `mdock port IMAGE` rebuilds an amd64-only image as native arm64 by replaying its build | GPU engine: a CPython loop in 0.41 s on FEX vs 3.97 s on QEMU. linux/386: 2–5× QEMU's speed. Opt-in AOT cache: `gcc` 1.7–2.1× and process start 1.3–2.2× faster, Python up to 2× slower. A ported Python/apt/pip/curl app: 27 s to port, identical output, 2–2.5× faster than under Rosetta with its AOT cache |
| **Local and production architectures differ** | `mdock arch-check IMAGE -- CMD` runs the arm64 and amd64 variants side by side and compares their OS/Python packages and the command's exit status and output (exit 1 on a difference) | Caught a different `grep` build in `python:3.13-slim` |
| **Bind mounts are slow** | `mdock sync add DIR`: Mutagen (built from source) keeps DIR in two-way sync with the VM's ext4 disk and mounts that copy over the shared path inside the VM, so containers need no changes | 5,000 small files: 0.23 s vs 4.85 s on virtiofs (21×). Mac edit → container 0.13 s; container write → Mac 0.7 s |
| **The VM holds memory and CPU** (Resource Saver only kicks in with no containers) | Idle CPU fixed at the source: the menu bar app follows Docker's event stream instead of polling, and the VM's agent rescans for host-network listeners only when its sockets change. After 10 minutes with no containers and no docker clients the VM shuts down completely, and launchd starts it again on the next docker command (socket activation). Default engine: memory the guest never uses is never charged (`init_on_alloc=0`) and a balloon caps the rest. GPU engine: memory the guest frees goes back to macOS within seconds, page cache included (patched libkrun) | With nothing running, the VM uses 1.1% of one core, Energy Impact ~1.2 (was 17% for mdock while the app polled every 2 s). Idle stop frees everything; a cold `docker info` answers in 1.2–1.4 s. Default engine: 1.2 GB charged after boot instead of 6.9 GB. GPU engine: 3.6 GB → 1.6 GB 10 s after a 2 GB job exits; 5.3 GB → 1.7 GB after reading 3.8 GB of files |
| **Networking differs from Linux** | Published TCP/UDP ports, `--network host` listeners and Kubernetes LoadBalancers all appear on the Mac's localhost (loopback-only listeners stay loopback-only, low ports too); `host.docker.internal` is the Mac's own localhost, IPv4 and IPv6 | A host-network listener shows up on the Mac in ~1 s |
| **No GPU in containers** | GPU engine: Vulkan 1.2 on the Mac's GPU (Venus), OpenGL 2.1 / ES 2.0 on Zink, OpenCL on rusticl ([gpu.md](gpu.md)). Both engines: the media engine (VideoToolbox), Neural Engine and a Metal LLM server, over standard APIs | llama.cpp in a container as fast as native Vulkan on the same Mac |
| **The Mac's disk is case-insensitive** | `mdock workspace create`: a case-sensitive APFS volume for code at `/Volumes/Workspace` (`~/Workspace`), mounted whenever mdock starts; `mdock casecheck DIR` lists names that differ only in case | No measurable cost: the same file-heavy job took 0.84 s there vs 0.92 s on the Mac's disk, and 6.47 s vs 6.88 s from a container |

What can't be changed: Virtualization.framework keeps every page a VM has touched charged to the VM
until it stops (its balloon takes memory from the guest but never gives it to the Mac, which Apple's
own `container` tool also notes). That's why the GPU engine, which owns its memory, returns it and the
default engine stops when idle instead. CUDA is NVIDIA-only; Metal isn't available inside Linux.

## Benchmarks

`./bench.sh <docker context>` runs these. The Docker Desktop column is 4.37.2 (January 2025), with its
configured 2 CPUs / 4 GiB, so the CPU rows mostly reflect that cap (Docker Desktop can be given more).
Docker Desktop's networking has changed since, so treat the network ratios as out of date until it is
measured again. The mdock column is from 2026-10-15, under `mdock autostart on`.

| | Docker Desktop 4.37.2 | mdock | |
|---|---:|---:|---:|
| Cold start to `docker info` | 6.9 s | 1.3 s | 5.3× |
| `docker run --rm` (median) | 260 ms | 134 ms | 1.9× |
| sha256, all cores | 2.92 GB/s | 13.7 GB/s | 4.7× |
| sha256, one core | 1.68 GB/s | 2.35 GB/s | 1.4× |
| sha256, one core, amd64 via Rosetta | 263 MB/s | 464 MB/s | 1.8× |
| 4k random r/w, container fs | 90k IOPS | 211k IOPS | 2.3× |
| Sequential write, container fs | 661 MB/s | 1,481 MB/s | 2.2× |
| 5000 small files on a bind mount | 13.0 s | 4.3 s | 3.0× |
| Bind mount sequential write / read | 479 / 690 MB/s | 1,025 / 1,855 MB/s | 2.1× / 2.7× |
| localhost → container (published port) | 468 Mbit/s | 23,165 Mbit/s | 49× |
| container → localhost (published port) | 710 Mbit/s | 34,394 Mbit/s | 48× |

mdock alone, from the same run:

| | mdock |
|---|---:|
| `docker run --rm` (hyperfine, median of 12) | 123 ms |
| localhost → container, 4 streams | 21,001 Mbit/s |
| container → the Mac (`host.docker.internal`) | 37,903 Mbit/s |
| container → container | 88,836 Mbit/s |
| Named volume sequential write | 1,214 MB/s |
| `docker cp` 1 GiB into / out of a container | 288 / 391 MB/s |
| Extract 4,000 files onto a bind mount | 2.6 s |
| `docker build` from scratch / fully cached | 2.6 s / 0.22 s |
| Waking from idle stop to a `docker ps` answer | 1.2 s |
| Idle, nothing running: VM / daemon / menu bar app | 1.1% / 0.0% / 0.0% of a core |

## Where Docker Desktop is still ahead

- It is mature and widely used; mdock is young and has been tested on one Mac.
- It updates itself. With mdock you rebuild from source and maintain its patches (the guest kernel,
  libkrun, virglrenderer, Mesa, FEX), and mdock's guest kernel doesn't follow Alpine's kernel updates.
- It is signed and notarized, runs on Intel Macs and older macOS, and has extensions, Scout, Debug and
  vendor support.
