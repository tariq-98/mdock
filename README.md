# mdock

Docker for Apple silicon, built to use the whole machine, including the GPU from Linux containers.
It's a Swift CLI/daemon plus a SwiftUI desktop app that boots an Alpine Linux VM with Docker 29. It exposes the
standard Docker API through a `docker` context, so the docker CLI, compose and buildx work unchanged.

The design started from a study of how Docker Desktop 4.37.2 runs Linux on this Mac: it keeps
`.cached` + `.fsync` disks (mdock does too), sends all guest traffic through a userspace gVisor network
stack (mdock uses the kernel's vmnet) and defaults to 2 CPUs and 4 GiB (mdock uses the whole machine).

## The usual Docker-on-Mac problems, and what mdock does about them

| Problem | mdock | Measured (M1) |
|---|---|---|
| **Intel images need emulation** | x86 code runs in x86's memory order in hardware: mdock's guest kernel turns on Apple silicon's TSO mode for translator threads (see [below](#x86-programs-in-x86s-memory-order-in-hardware)). Rosetta for linux/amd64, with its ahead-of-time cache as an option (`mdock set aot=on`; off by default because Apple's AOT translator crashes on or miscompiles some programs, Node's Alpine builds among them); FEX (built from source) for linux/386, and for linux/amd64 on the GPU engine; `mdock port IMAGE` rebuilds an amd64-only image as native arm64 by replaying its build | Opt-in AOT cache: `gcc` 1.7–2.1× and process start 1.3–2.2× faster, Python up to 2× slower. GPU engine: a CPython loop in 0.41 s on FEX vs 3.97 s on QEMU. linux/386: 2–5× QEMU's speed. A ported Python/apt/pip/curl app: 27 s to port, identical output, 2–2.5× faster than under Rosetta with its AOT cache |
| **Local and production architectures differ** | `mdock arch-check IMAGE -- CMD` runs the arm64 and amd64 variants side by side and compares their OS/Python packages and the command's exit status and output (exit 1 on a difference) | Caught a different `grep` build in `python:3.13-slim` |
| **Bind mounts are slow** | `mdock sync add DIR`: Mutagen (built from source) keeps DIR in two-way sync with the VM's ext4 disk and mounts that copy over the shared path inside the VM, so containers need no changes | 5,000 small files: 0.23 s vs 4.85 s on virtiofs (21×). Mac edit → container 0.13 s; container write → Mac 0.7 s |
| **The VM holds memory and CPU** (Resource Saver only kicks in with no containers) | Idle CPU fixed at the source (the menu bar no longer polls dockerd). After 10 minutes with no containers and no docker clients the VM shuts down completely, and launchd starts it again on the next docker command (socket activation). VZ engine: memory the guest never uses is never charged (`init_on_alloc=0`) and a balloon caps the rest. GPU engine: memory the guest frees goes back to macOS within seconds, page cache included (patched libkrun) | 4–8% of one core at idle with Jellyfin running. Idle stop frees everything; a cold `docker ps` answers in 3.6–3.9 s. VZ: 1.2 GB charged after boot instead of 6.9 GB. GPU engine: 3.6 GB → 1.6 GB 10 s after a 2 GB job exits; 5.3 GB → 1.7 GB after reading 3.8 GB of files |
| **Networking differs from Linux** | Published TCP/UDP ports, `--network host` listeners and Kubernetes LoadBalancers all appear on the Mac's localhost (loopback-only listeners stay loopback-only, low ports too); `host.docker.internal` is the Mac's own localhost, IPv4 and IPv6 | A host-network listener shows up on the Mac in ~1 s |
| **No GPU in containers** | GPU engine: Vulkan 1.2 on the Mac's GPU (Venus), OpenGL 2.1 / ES 2.0 on Zink, OpenCL on rusticl (`mdock/gpu` image, Mesa built from source). Both engines: the media engine (VideoToolbox), Neural Engine and a Metal LLM server, over standard APIs | llama.cpp in a container as fast as native Vulkan on the same Mac |
| **The Mac's disk is case-insensitive** | `mdock workspace create`: a case-sensitive APFS volume for code at `/Volumes/Workspace` (`~/Workspace`), mounted whenever mdock starts; `mdock casecheck DIR` lists names that differ only in case | No measurable cost: the same file-heavy job took 0.84 s there vs 0.92 s on the Mac's disk, and 6.47 s vs 6.88 s from a container |

What can't be changed: Virtualization.framework keeps every page a VM has touched charged to the VM
until it stops (its balloon takes memory from the guest but never gives it to the Mac, which Apple's
own `container` tool also notes). That's why the GPU engine, which owns its memory, returns it and the
VZ engine stops when idle instead. CUDA is NVIDIA-only; Metal isn't available inside Linux.

## Two engines

| | `mdock start` (default) | `mdock start --gpu` |
|---|---|---|
| Hypervisor | Virtualization.framework | libkrun on Hypervisor.framework |
| GPU | none (media engine, Neural Engine and Metal LLMs still work) | Apple GPU: Vulkan (Venus → virglrenderer → MoltenVK → Metal), OpenGL, OpenCL |
| linux/amd64 images | Rosetta (a CPython loop: 0.56 s, native 0.25 s) | FEX (the same loop 0.41 s) |
| linux/386 images | FEX | FEX |
| x86 memory order | hardware TSO with mdock's kernel | hardware TSO with mdock's kernel |
| Networking | vmnet NAT (fastest) | gvproxy (userspace) |
| Memory | balloon caps the guest; macOS gets it back when the VM stops (idle stop) | freed guest memory returns to macOS within seconds |

Both engines share the same disks, images and containers. The choice is remembered until you switch.

## x86 programs in x86's memory order, in hardware

x86 guarantees that other cores see a core's stores in order (TSO); Arm doesn't. A translator either
puts barriers around memory accesses or, on Apple silicon, sets the core's TSO bit (ACTLR_EL1 bit 1)
so the hardware keeps x86's order, as Rosetta does on macOS. Inside a VM that needs the guest kernel
to switch the bit per thread, which stock kernels can't do. mdock builds its own:

- `kernel/build.sh`: Linux 6.18.56 from kernel.org (checksum and Greg Kroah-Hartman's signature
  checked) with Alpine's linux-virt configuration, Asahi Linux's TSO series (`PR_SET_MEM_MODEL`,
  as rebased by libkrunfw) and `0018-mdock-…`: a context switch only writes ACTLR_EL1 when the
  memory model changes. Each write traps to the hypervisor, and writing it on every switch made a
  native pipe round trip 24% slower.
- `mdock kernel install` puts it in the guest (`mdock restart` boots it); `mdock kernel remove`
  goes back to Alpine's. The desktop app ships it.
- GPU engine: `libkrun-hvf-tso.patch` lets the guest see and set the TSO bit through
  Hypervisor.framework (`HV_SYS_REG_ACTLR_EL1`, macOS 15+).
- Rosetta asks for TSO on its own. FEX (FEX-2610, built by `guest/build.sh` with
  `guest/patches/fex-mdock.patch`) runs without its FEXServer daemon, turns off Go's asynchronous
  preemption for the programs it runs (`GODEBUG=asyncpreemptoff=1`; Go's preemption signal crashed
  Go programs under FEX), and maps its 32-bit syscall page executable (32-bit musl crashed on it).
  FEX replaces QEMU wherever the kernel provides TSO; QEMU stays as the fallback.

A message-passing litmus test (3000 × 4096 rounds) shows the effect:

| | reorderings |
|---|---:|
| arm64 program, Arm's memory order | 159–215 |
| arm64 program after `prctl(PR_SET_MEM_MODEL, TSO)` | 0 |
| x86-64 program on Rosetta (default engine) | 0 |
| x86-64 program on FEX (GPU engine) | 0 |
| x86-64 program on FEX told not to keep x86's order | 123 |

What it costs and gains (M1):

| | Rosetta (default engine) | FEX (GPU engine) | QEMU | native arm64 |
|---|---:|---:|---:|---:|
| CPython loop | 0.56 s | 0.41 s | 3.97 s | 0.25 s |
| Python mix: dict / str / json / objects | 0.43 / 0.19 / 0.67 / 0.22 s | 0.35–0.47 / 0.17–0.19 / 0.58–0.66 / 0.19 s | | 0.27 / 0.11 / 0.43 / 0.12 s |
| `xz -3 -T1` / `-T4` / `pigz -p4` on a tar of /usr | 11.1 / 4.5 / 0.70 s | 9.6 / 4.0 / 0.72 s | | 6.0 / 2.8 / 0.62 s |
| Start a process (`/bin/true`, `perl -e 1`) | 11 / 33 ms | 19 / 58 ms | 13 / 38 ms | 0.3 / 1 ms |
| `docker build` running apt (curl, python3) | 40 s | 66 s | 69 s | 9 s |
| linux/386 sha256 / gzip / awk | FEX on both engines: 0.70 / 0.93 / 4.4 s | | 2.1 / 2.0 / 23.1 s | 0.77 / 0.70 / 1.5 s |

With Rosetta's AOT cache on (`mdock set aot=on`), the Rosetta column becomes: CPython loop 1.11 s,
Python mix 0.48 / 0.32 / 1.13 / 0.46 s, xz 8.3 / 3.7 / 0.64 s, process start 8 / 15 ms, apt build
38.5 s. Code translated ahead of time is faster for compiled C and starts sooner, but slower for an
interpreter's dispatch loop.

Native code doesn't pay for any of it: with patch 0018 a pipe round trip takes 24.7–24.9 µs
(Alpine's kernel: 25.2–25.5 µs). FEX compiles more code up front than QEMU, so short-lived processes
start slower; builds that run thousands of them (apt, dpkg) take about as long as on QEMU, and
everything that runs longer is 2–10× faster.

## GPU in containers

```sh
gpu/build.sh                     # one time: builds the GPU stack from source (see below)
gpu/guest/build.sh               # optional: the mdock/gpu image (OpenCL), Mesa from source
mdock stop && mdock start --gpu
mdock gpu-check                  # what containers get: Vulkan, OpenGL, OpenCL
docker run --device mdock.dev/gpu=all <image>
```

`mdock.dev/gpu=all` is a [CDI](https://github.com/cncf-tags/container-device-interface) device the guest
publishes at boot. It adds `/dev/dri` and turns off Mesa's Asahi driver, which otherwise crashes the
Vulkan loader on this device. The image brings its own Mesa:

| API | In a container | Notes |
|---|---|---|
| Vulkan 1.2 | any image with Mesa's Venus driver (Fedora or Debian/Ubuntu `mesa-vulkan-drivers`) | [examples/llama-vulkan](examples/llama-vulkan/Dockerfile) builds llama.cpp with the Vulkan backend |
| OpenGL 2.1, OpenGL ES 2.0 | the image's Mesa with `-e GALLIUM_DRIVER=zink` (Zink: OpenGL on Vulkan) | rendering checked pixel-exact. GL 3.0 needs transform feedback, which MoltenVK doesn't have; without the variable Mesa uses llvmpipe (GL 4.5 on the CPU) |
| OpenCL 3.0 | the `mdock/gpu` image: rusticl on Zink, Mesa 25.1.9 built from source with the two patches in `gpu/guest/` | a 1024² matrix multiply checks out against the CPU; 36.8 GFLOP/s with a naive kernel vs 1.6 on one CPU core |

`gpu/guest/*.patch` make Zink work on a Mac host: Venus can't export memory as fds there, which stock
Zink treats as fatal on the DRM path (so rusticl found no device), and MoltenVK can't alias a binding in
a push-descriptor set (Zink reads OpenCL kernel arguments as 32- and 64-bit), so Zink skips push
descriptors on Venus/Apple.

llama.cpp, Qwen2.5-0.5B Q4_K_M, M1 (tok/s):

| | prompt (pp512) | generation (tg128) |
|---|---:|---:|
| Container, CPU only (8 vCPUs) | 148 | 10.8 |
| **Container, mdock GPU (Venus)** | **970** | **32.6** |
| Native macOS, Vulkan on MoltenVK | 916 | 32.4 |
| Native macOS, Metal backend | 1,739 | 98.4 |

The container is as fast as native Vulkan on the same Mac, so virtualization adds no measurable cost.
The gap to the Metal row is llama.cpp's Vulkan backend on MoltenVK versus its Metal backend.

### The GPU stack, built from source

`gpu/build.sh` fetches checksum-verified sources and compiles them with `-mcpu=apple-m1` /
`target-cpu=apple-m1`, `-O3` and LTO into `gpu/prefix`:

- **virglrenderer** (krunkit branch) with Venus, linked to MoltenVK, plus
  `virglrenderer-no-pipeline-guard.patch`: MoltenVK dereferences the bound pipeline when it encodes
  a draw or dispatch, so a guest that recorded one without a pipeline (after its pipeline failed to
  compile) crashed the whole VM. Such commands are dropped instead.
- **libkrun 1.19.6** with block, net and GPU only, plus mdock patches in `gpu/patches/`:
  - `libkrun-hvf-tso.patch`: the guest sees Apple's TSO capability (AIDR_EL1) and can set the TSO bit
    in ACTLR_EL1, which Hypervisor.framework exposes from macOS 15; an x86 translator in the guest
    then runs in x86's memory order (see above). Stock libkrun panics on a system register it
    doesn't know, which would stop the VM at the guest's first access.
  - `libkrun-vsock-bursts.patch`: a deeper listen backlog and receive queue for vsock connections,
    and a full file table refuses a connection instead of aborting the VM, so 64 parallel docker
    clients × 50 requests all succeed.
  - `libkrun-hvf-4k-ipa-granule.patch`: on macOS 26 the VM maps memory at 4 KiB granularity
    (`hv_vm_config_set_ipa_granule`). With the default 16 KiB, `hv_vm_map` rejects Venus blobs at
    4 KiB-aligned guest offsets and stock Mesa fails with `VK_ERROR_OUT_OF_HOST_MEMORY`. That is the
    reason other setups need a patched Mesa or guest kernel.
  - `libkrun-free-page-reporting.patch`: free page reporting returns memory for real. A plain
    `madvise` is a no-op on pages the guest wrote while they are mapped into the VM, and `MADV_FREE`
    never lowers the footprint, so each reported range is unmapped, marked `MADV_FREE_REUSABLE` and
    mapped back.
  - `libkrun-vsock-half-close.patch`: a host EOF on a vsock↔unix connection is sent as a vsock
    `SHUTDOWN(SEND)`, not a reset. Without it, `docker run`/`attach` loses all output.
  - `libkrun-vsock-prompt-close.patch`: macOS refuses `shutdown(SHUT_RDWR)` (ENOTCONN, and shuts
    nothing) on a unix socket whose peer already half-closed, so the host end of a finished
    connection stayed open until libkrun's 5 s reaper: every attached `docker run` took 5 s longer
    (now 0.18 s). It also stops polling finished connections, which spun the event loop meanwhile.
  - `libkrun-quiet-vsock.patch`: no time-sync datagrams (only libkrunfw's kernel reads them) and no
    error line for the resets the guest answers them with.
- **gvproxy 0.8.9** for guest networking

mdock loads libkrun with `dlopen` and boots the same guest kernel directly (mdock's, else Alpine's),
without krunkit or EFI firmware. MoltenVK comes from homebrew-core, because building it needs a full Xcode.

## Mac accelerators for any container

The accelerator bridge ([accel/CONTRACT.md](accel/CONTRACT.md)) gives Linux containers the Mac's media
engine, GPU and Neural Engine. It does this through interfaces Linux software already speaks, with the
work running natively on macOS. Services start on first use. All of the following were measured from
containers on an M1:

| Accelerator | How a container uses it | Result |
|---|---|---|
| Media engine, any app | `--device mdock.dev/media=vaapi`: standard **VA-API** (H.264/HEVC Main/Main10 decode + encode, scaling) | decode bit-exact with software; 4K HEVC 10-bit → 1080p H.264 at 80 fps in stock `jellyfin/jellyfin:latest` |
| Media engine, ffmpeg-based apps | `--device mdock.dev/media=ffmpeg`: `ffmpeg`/`ffprobe` run on the Mac (VideoToolbox) | Jellyfin 10.11: 4K HDR10 → 1080p SDR at 59–70 fps, vs 31 fps in software |
| GPU (Vulkan) | `--device mdock.dev/gpu=all` on the GPU engine | llama.cpp as fast as native Vulkan |
| GPU (LLMs on Metal) | `http://llm.mdock.internal:8200` (OpenAI + Ollama API), `llm.mdock.internal:50052` (llama.cpp `--rpc`) | 96 tok/s over the API (≈ native Metal); 67 tok/s via RPC |
| Neural Engine | `http://ml.mdock.internal:8100`: CoreML runner | ResNet-50 at 2.5–4 ms on the ANE vs 12–17 ms on the CPU |
| On-device speech | `POST ml.mdock.internal:8100/v1/audio/transcriptions` (OpenAI format) | 20 s of audio in 1 s |
| Apple Intelligence | `POST ml.mdock.internal:8100/v1/chat/completions` (Foundation Models) | needs Apple Intelligence turned on in System Settings |

Details for each: [accel/media](accel/media/README.md) (Jellyfin compose file included),
[accel/vaapi](accel/vaapi/PROTOCOL.md), [accel/ml](accel/ml/README.md), [accel/llm](accel/llm/README.md).

Things to know:
- **Media files must be bind mounts from macOS** (`/Users`, `/Volumes`): the Mac reads and writes the same files.
- **Trust:** the media devices run code on the Mac as your user, and the ML/LLM endpoints are open to every
  container in the VM. Only give the devices to containers you trust.
- **VA-API limits:** glibc images only. No interlaced H.264, VP9 or AV1, and no Matroska output from the
  hardware encoders. Jellyfin 10.11's arm64 ffmpeg has no VA-API, so use `media=ffmpeg` with the patched
  image there.
- **No Metal filters:** the Mac-side ffmpeg is built without them (they need Xcode), so HDR tone mapping
  runs on the Mac's CPU.

## Desktop app

```sh
desktop/bundle.sh                # builds and installs ~/Applications/mdock Desktop.app
```

A menu-bar control and dashboard. It shows engine status, CPUs, memory and ports; a GPU page with a
Vulkan check and the `--device` snippet; containers (with a GPU badge, logs, start/stop/remove and
links to published ports); images; and settings. The bundle includes the CLI/daemon and the GPU stack.

## Use

```sh
brew install qemu e2fsprogs      # first install only: qemu-img unpacks the image, debugfs reads its kernel
./build.sh                       # swift build + ad-hoc sign; links ~/.local/bin/mdock
mdock start                      # first run downloads Alpine (~230 MB) and provisions (~30 s)
cli/build.sh                     # docker CLI, Compose, Buildx, keychain helper, from source (Go)
cli/configure.sh                 # ~/.docker/config.json: mdock context, keychain, our plugins (--revert undoes)
guest/build.sh                   # mdock-guestd (the guest side of the bridges), FEX, QEMU; built on mdock itself
kernel/build.sh && mdock kernel install   # optional: x86 memory order in hardware (above)
mdock autostart on && mdock restart
mdock doctor                     # everything checked, with the fix for anything that isn't right
```

Every command also works as a Docker CLI plugin (`docker mdock status`), and anything mdock doesn't
define runs as a docker command against mdock (`mdock ps`, `mdock run …`, `mdock logs web`).

| Command | |
|---|---|
| `mdock start [--gpu\|--no-gpu]` / `stop` / `restart` | Boot (~3 s warm) / clean poweroff over vsock |
| `mdock autostart on\|off` | Start at login and restart after a crash (launchd agent `local.mdock.daemon`) |
| `mdock upgrade` | `apk upgrade` in the guest (packages, Docker, kernel), then restart |
| `mdock status [--json]` | Engine, CPUs, memory, ports, accelerators, Kubernetes, endpoints |
| `mdock doctor [--json]` | Checks the VM, engine, CLI, plugins, sockets, guest helper, Kubernetes; exit 1 on failure |
| `mdock version [--json]` | mdock, Docker CLI and engine, Compose, Buildx, kubectl, k3s |
| `mdock kubernetes enable\|disable\|reset\|status` | Single-node Kubernetes (`mdock k8s`), see below |
| `mdock mcp` | MCP server on stdio for AI agents, see [AGENTS.md](AGENTS.md) |
| `mdock gpu-check` | Show the GPU a container sees |
| `mdock kernel install [DIR] \| remove \| status` | Install mdock's guest kernel (hardware TSO for x86 translators), go back to Alpine's, or show which runs |
| `mdock workspace create [name] \| mount \| eject \| status` / `mdock casecheck [dir]` | Case-sensitive APFS volume for code / find case collisions |
| `mdock arch-check [run options] IMAGE [-- CMD]` | Run an image on arm64 and amd64 side by side and compare |
| `mdock port IMAGE [--tag=NAME] [--replace]` | Rebuild an amd64-only image as native arm64 |
| `mdock sync add [DIR] [--ignore=PAT]… \| remove [DIR] \| list` | Native disk speed for a bind-mounted directory |
| `mdock set cpus=8 memory=10 disk=256 gpu=on balloon=on ports=on rosetta=on aot=off sync=fsync idle=10` | Edit `~/.mdock/config.json`, then restart (`idle` applies at once; 0 turns idle stop off) |
| `mdock shell` | Root shell in the VM (`nsenter` via a privileged container) |
| `mdock logs [console]` | Follow the daemon log or the guest console |
| `mdock delete` | Remove the VM, disks and context |

State lives in `~/.mdock`. The data disk is a sparse raw file; APFS only allocates what the guest writes.

## What you get

- **All cores and up to half the RAM** (8 vCPUs / 8 GiB on a 16 GB M1). An auto-balloon keeps the
  guest near what it uses plus 1.5 GiB (it grows back within 5 s under pressure, and the guest's
  deflate-on-OOM is a backstop). On the GPU engine, memory the guest frees goes back to macOS.
- **Idle stop** (under `mdock autostart on`): launchd holds `docker.sock`; after `idle` minutes (10)
  with no containers running and no docker clients the VM shuts down, and the next docker command,
  on mdock's socket or the default one, starts it again and waits for it (~3.5 s). mdock's own calls
  and Mutagen don't count as activity. `mdock stop` still means stopped.
- **Kernel vmnet networking** instead of a userspace TCP/IP stack. Published ports appear on
  `localhost` automatically, following `docker events`.
- **Rosetta** for `--platform linux/amd64` and **FEX** for linux/386 (and linux/amd64 on the GPU
  engine), both in x86's memory order in hardware on mdock's kernel. `mdock status` shows which
  translator runs what. `mdock set aot=on` adds Rosetta's ahead-of-time cache (rosettad, shared by
  every container through `mdock-runc`); see the limitations.
- **Same-path bind mounts**: `/Users`, `/Volumes`, `/private` and `/var/folders` are virtiofs-shared
  at identical paths.
- **`host.docker.internal` is the Mac's own localhost** (IPv4 and IPv6), as in Docker Desktop, and
  `--add-host x:host-gateway` resolves to it. TCP to 192.168.65.254 is redirected in the guest to
  `mdock-guestd` and carried over vsock to the Mac's loopback; a closed port resets the connection.
- **File watchers work on bind mounts**: FSEvents on the bind-mount sources of running containers;
  `mdock-guestd` re-applies each changed file's mode, which raises `IN_ATTRIB` for inotify watchers
  (vite, webpack, nodemon, watchdog). Mass changes poke directories instead of every file.
- **TCP and UDP** published ports appear on `localhost`.
- **Starts at login and restarts after a crash** (`mdock autostart on`), with a crash-loop guard and
  a watchdog that restarts the VM if the vsock bridge stays dead for two minutes.
- **Kubernetes** (`mdock kubernetes enable`, ~20 s the first time): Alpine's k3s in the VM, running on
  mdock's Docker, so images from `docker build` run in pods without a registry (`imagePullPolicy:
  IfNotPresent` or `Never`). The API is at https://127.0.0.1:6443 as kubectl context `mdock` (merged
  into `~/.kube/config`, the original kept as `config.before-mdock`), and LoadBalancer services appear
  on localhost. kubectl is built from source by `cli/build.sh`. Off by default, like Docker Desktop's.
- **Made for AI agents**: `mdock mcp` serves 19 typed tools over the Model Context Protocol (status,
  doctor, run, exec, logs, build, compose, kubectl, arch_check, accelerators, …) with structured results, and every
  status command has `--json`. See [AGENTS.md](AGENTS.md).
- **The default socket works**: Docker Desktop's helper points `/var/run/docker.sock` at
  `~/.docker/run/docker.sock`; while Desktop isn't serving it, the daemon points that at mdock, so
  the `default` and `desktop-linux` contexts and tools hard-wired to the socket reach mdock too.
- **Clean lifecycle**: vsock poweroff, then the VZ power button, and a forced stop only after 60 s.
  Disks use Docker Desktop's `.cached` + `.fsync` mode.

## Benchmarks (M1, 16 GB, macOS 26.6)

`./bench.sh <context>`. Docker Desktop 4.37.2 ran with its configured 2 CPUs / 4 GiB. The CPU rows
mostly reflect that cap; the network, container-start and boot rows are architectural.

| | Docker Desktop | mdock | |
|---|---:|---:|---:|
| Cold start to `docker info` | 6.9 s | 3.7 s | 1.9× |
| `docker run --rm` (median) | 260 ms | 170 ms | 1.5× |
| sha256, all cores | 2.92 GB/s | 8.76 GB/s | 3.0× |
| sha256, one core | 1.68 GB/s | 2.09 GB/s | 1.2× |
| sha256, one core, amd64 via Rosetta | 263 MB/s | 311 MB/s | 1.2× |
| 4k random r/w, container fs | 90k IOPS | 119k IOPS | 1.3× |
| Sequential write, container fs | 661 MB/s | 613 MB/s | 0.9× |
| 5000 small files on a bind mount | 13.0 s | 9.8 s | 1.3× |
| Bind mount sequential write / read | 479 / 690 MB/s | 630 / 631 MB/s | 1.3× / 0.9× |
| localhost → container (published port) | 468 Mbit/s | 4,733 Mbit/s | 10× |
| container → localhost (published port) | 710 Mbit/s | 16,967 Mbit/s | 24× |

## Architecture

```
docker CLI ──unix──▶ ~/.mdock/docker.sock ─┐                    ┌─ Alpine VM (VZ, direct kernel boot) ─┐
localhost:PORT ──tcp─▶ forwarder ──────────┤  mdock daemon      │ socat vsock:2375 ─▶ dockerd           │
                                           ├─(Swift, VZ)───vsock─▶ guestd vsock:2376 ─▶ 127.0.0.1:PORT   │
                           vmnet NAT ──────┘                    │ mdock-agent: ready/mem/kernel ─▶ :1024 │
                                                                │ virtiofs /Users… · rosetta · balloon  │
                                                                └───────────────────────────────────────┘
```

- `Sources/mdock/Daemon.swift`: VM config, vsock bridges, port forwarder, file events, host.docker.internal,
  auto-balloon, watchdog, control socket. `UDPForward.swift`: UDP flows. `LaunchAgent.swift`: autostart.
- `guest/guestd.c`: `mdock-guestd` (published-port relay, UDP relay, host.docker.internal, file events),
  a static binary shipped on the seed disk; the guest falls back to socat without it.
- `Sources/mdock/Guest.swift`: everything that runs in the guest, shipped on a read-only seed disk.
  cloud-init bootstraps only the first boot; later changes are applied by `mdock-guest` from the seed.
- `Sources/mdock/main.swift`: CLI, image download, daemon spawn. `Kubernetes.swift`, `Plugin.swift`
  (`docker mdock`), `Doctor.swift`, `MCP.swift` (the MCP server), `Kernel.swift` (`mdock kernel`).
- vsock: Virtualization.framework moves guest data into the Mac's sockets from one serial queue per
  VM, so one host socket left unread stalls every vsock connection: docker.sock, ports, the guest's
  reports. That caused this project's freezes (a slow ffmpeg reader; a container watcher that paused
  its event stream). Every relay (`Sockets.splice`) therefore reads continuously into a buffer with a
  separate writer, drops only the connection that falls 64 MiB behind, and the event watcher hands its
  work to a coalescing worker.

## Limitations

- Under launchd (`mdock autostart on`) published ports go over the vsock relay, roughly 0.4–0.85 GB/s
  (Virtualization.framework's vsock device is the ceiling), not vmnet's 5–6.5 GB/s: macOS's Local Network privacy blocks a launchd agent from connecting into the VM's
  subnet (an ad-hoc signed binary can't keep that permission across rebuilds). Started from a
  terminal, the daemon connects directly and falls back to the relay.
- Virtualization.framework drops a half-close made in the guest (`shutdown(SHUT_WR)` on vsock never
  reaches the Mac). The guest bridges close the vsock end outright when their side finishes, so a
  container server can't keep reading from a client after it has finished sending; a Mac server
  behind host.docker.internal doesn't see a client's half-close.
- File events arrive as `IN_ATTRIB`, not `IN_MODIFY`/`IN_CREATE`.
- GPU: Vulkan 1.2; OpenGL stops at 2.1 / ES 2.0 because MoltenVK has no transform feedback (which
  GL 3.0 requires); no CUDA or Metal inside Linux. Containers also see llvmpipe, a CPU fallback.
- Virtualization.framework never returns memory the guest has touched until the VM stops (see above):
  on the default engine the balloon bounds it and idle stop resets it.
- Kubernetes is single-node; no Docker Desktop extensions.
- Homebrew is still used for the first install (qemu-img, debugfs) and by the GPU engine (MoltenVK,
  libepoxy). Upgrades read the new kernel from the guest itself. mdock's own kernel doesn't follow
  Alpine's kernel updates: rebuild it (`kernel/build.sh`, newer `VER`) or `mdock kernel remove`.
- Rosetta only runs under Virtualization.framework, so the GPU engine uses FEX. FEX starts each
  process in ~20 ms (Rosetta ~11 ms), which is what limits apt-heavy amd64 builds there.
- Rosetta's AOT cache is off by default. Its translator (rosettad) dies on some binaries, e.g. the
  Node in `node:20-alpine` and `node:24-alpine` ("Not all x86 entry points were contained in a code
  segment"), and miscompiles others (`node:22-alpine` then crashes on start). With `aot=on`, mdock
  drops the empty cache entry a failed translation leaves (it would stop the program from starting)
  and restarts rosettad, so those programs fall back to plain Rosetta; a miscompiled one still
  crashes, and `--runtime runc` runs that container without the cache. Without
  mdock's kernel both engines fall back to QEMU for what FEX would run.
- macOS 14+ on Apple silicon; Rosetta is needed for amd64 (`softwareupdate --install-rosetta`).
  The GPU engine with stock Mesa needs macOS 26 (4 KiB IPA granule).

## Replacing Docker Desktop

`cli/build.sh` + `cli/configure.sh` (above) leave Docker Desktop installed but unused: `docker` in
`~/.local/bin` comes before Desktop's symlinks in `/usr/local/bin`, the keychain helper reads the
logins Desktop stored, and Desktop's plugin symlinks are skipped once they dangle. To remove it:
`/Applications/Docker.app/Contents/MacOS/uninstall`, then `sudo cli/default-socket.sh install` so
`/var/run/docker.sock` is recreated at boot (Desktop's privileged helper did that).
