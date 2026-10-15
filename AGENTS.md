# mdock for AI agents

mdock is this Mac's Docker: a Linux VM (Alpine, Docker Engine) on Apple's Virtualization.framework that
replaces Docker Desktop, with optional Kubernetes and access to the Mac's GPU, media engine and Neural
Engine from containers. One VM is shared by everything on the Mac, including long-running services
(a Jellyfin server).

## Using it

- **Check first.** `mdock doctor --json` lists every check with a fix for anything not ok (exit status
  1 on failure). `mdock status --json` gives the engine, resources, published ports, accelerators,
  Kubernetes state and the endpoints to use.
- **Docker is plain `docker`**: the current context is `mdock` (the CLI, Compose and Buildx are built
  from source in `~/.local/bin`). `mdock <docker command>` and `docker mdock <mdock command>` also work.
- **Images** are linux/arm64; `--platform linux/amd64` runs x86 images through Rosetta on the
  default engine and through FEX on the GPU engine; linux/386 runs
  through FEX. On mdock's kernel both keep x86's memory order in hardware (Apple silicon TSO; `mdock
  kernel status`); without it FEX's share falls back to QEMU. `mdock status --json` → `x86` names the
  translator for each architecture. FEX starts processes slower (~20 ms each), so apt-heavy amd64
  builds are quicker on the default engine. `docker buildx build --platform linux/arm64,linux/amd64
  --load` builds both.
  `mdock port IMAGE` rebuilds an amd64-only image as native arm64 (no emulation at all);
  `mdock arch-check IMAGE -- CMD` runs both architectures and reports differences (exit 1).
- **Files**: Mac paths under `/Users`, `/Volumes`, `/private` and `/var/folders` bind-mount at the same
  paths. Edits on the Mac reach inotify watchers in containers (as `IN_ATTRIB`). `mdock sync add DIR`
  gives a big source tree native disk speed (two-way Mutagen sync to the VM's disk, transparent to
  containers; restart containers that already mount it). Code that needs case-sensitive names belongs
  on the case-sensitive volume `~/Workspace` (`mdock workspace status`, `mdock casecheck DIR`).
- **Network**: published ports (TCP and UDP), `--network host` listeners and Kubernetes LoadBalancers
  appear on the Mac's localhost. Inside containers, `host.docker.internal` (and `--add-host
  x:host-gateway`) is the Mac's own localhost, IPv4 and IPv6.
- **A shell in any container**, even one without a shell (distroless): `mdock debug CONTAINER
  [IMAGE]` starts IMAGE (alpine) in its network and process namespaces, in its files (/proc/1/root).
- **Idle stop**: under autostart the VM shuts down after `idle` minutes (default 10) with no
  containers and no docker clients; any docker command starts it again and waits (~1.2 s). `mdock
  status` then says "stopped after being idle": that's normal, not a failure. `mdock set idle=0`
  turns it off.
- **Mac accelerators** (`mdock status --json` shows what's ready):
  - GPU, only on the GPU engine (`mdock stop && mdock start --gpu`): `docker run --device
    mdock.dev/gpu=all …`. Vulkan 1.2 with the image's own Mesa (Venus); OpenGL 2.1/ES 2.0 with
    `-e GALLIUM_DRIVER=zink`; OpenCL in the `mdock/gpu` image (rusticl, from `gpu/guest/build.sh`).
    No CUDA. The GPU engine also returns freed guest memory to macOS within seconds; the default
    engine keeps it until the VM stops.
  - Media engine: `--device mdock.dev/media=ffmpeg` (ffmpeg/ffprobe run on VideoToolbox) or
    `--device mdock.dev/media=vaapi` (VA-API).
  - `http://ml.mdock.internal:8100`: OpenAI-style chat on Apple Foundation Models, Whisper-style
    transcription, Core ML models on the Neural Engine (`GET /v1/capabilities`).
  - `http://llm.mdock.internal:8200`: OpenAI and Ollama APIs on llama.cpp with Metal; GGUF models from
    Hugging Face as `owner/repo[:QUANT]`. `llm.mdock.internal:50052` is ggml RPC.
- **Kubernetes** is off by default. `mdock kubernetes enable` starts single-node k3s (on mdock's
  Docker) in about 20 s; kubectl context `mdock`, API https://127.0.0.1:6443. Images from
  `docker build` run in pods without a registry (`imagePullPolicy: IfNotPresent` or `Never`), and
  LoadBalancer services appear on localhost. `mdock kubernetes disable` stops it and keeps its state;
  `reset` deletes the cluster.
- **MCP**: `mdock mcp` is a Model Context Protocol server (stdio) with 19 typed tools: status, doctor,
  vm, containers, images, run, exec, logs, container, build, compose, kubernetes, kubectl, docker,
  arch_check, port_image, sync, workspace, accelerators. For Claude Code:
  `claude mcp add --scope user mdock -- ~/.local/bin/mdock mcp`.

Don't, unless the user asks: `mdock stop`, `restart`, `upgrade`, `start --gpu`/`--no-gpu` (they
interrupt every container), `mdock kernel install`/`remove` (they change what the VM boots), `mdock
delete` (removes every image and volume), `mdock kubernetes reset`.

## Working on the code

- How it fits together: [docs/architecture.md](docs/architecture.md); the x86 translators and guest
  kernel: [docs/x86.md](docs/x86.md); the GPU engine and its patches: [docs/gpu.md](docs/gpu.md).
- Build with `./build.sh` only. A plain `swift build` relinks `mdock` without the
  `com.apple.security.virtualization` entitlement and the VM won't start. `mdock doctor` checks this.
- The daemon runs under launchd (`mdock autostart on`, label `local.mdock.daemon`); `mdock restart`
  picks up a new build and the guest files (`Sources/mdock/Guest.swift`, shipped on a seed disk).
- Other builds: `cli/build.sh` (docker, Compose, Buildx, keychain helper, kubectl, Mutagen),
  `guest/build.sh` (`mdock-guestd`, FEX with `guest/patches/`, static QEMU user-mode; compiled in
  containers on mdock), `kernel/build.sh` (the guest kernel: kernel.org source, Alpine's config,
  `kernel/patches/`; then `mdock kernel install` and `mdock restart`),
  `desktop/bundle.sh` (the app), `gpu/build.sh` (virglrenderer + libkrun, patched; see
  `gpu/patches/`), `gpu/guest/build.sh` (the `mdock/gpu` image: Mesa from source with
  `gpu/guest/*.patch`), `accel/*` (accelerator services; see `accel/CONTRACT.md`).
- Logs: `~/.mdock/daemon.log`, `~/.mdock/console.log` (guest console, reset at boot). In the guest:
  `/var/log/messages`, `/var/log/docker.log`, `/var/log/k3s.log`.
- Run something in the guest: `docker run --rm --privileged --pid=host --net=host --cgroupns=host
  alpine:3.22 nsenter -t 1 -m -u -n -i -p sh -c '…'` (`guestScript` in main.swift). Write
  `echo $$ > /sys/fs/cgroup/cgroup.procs` first if it starts anything that must outlive the container.

Rules learned the hard way:

- **Never leave a host-side vsock socket unread.** Virtualization.framework writes guest data into
  the Mac's sockets from a single serial queue per VM; one blocked write stalls every vsock
  connection (docker.sock, ports, the guest's reports, poweroff). Use `Sockets.splice` with `vsock:`
  naming the vsock end (it buffers what comes out of it and drops only the connection that falls 64
  MiB behind; every other direction gets plain flow control) and never block a read loop on other
  vsock work. Bulk streams belong on dial-back instead (next rule).
- The framework drops a half-close made in the guest; guest bridges close outright instead (socat
  `shut-close`, `SHUT_RDWR` in `mdock-guestd`). Half-closes from the Mac arrive normally.
- macOS Local Network privacy stops the launchd-run daemon from connecting to the VM's subnet
  (192.168.64.x) but not from accepting connections from it. So the Mac never dials into the VM:
  published TCP ports and the Docker API use dial-back (`DialBack.swift`; the guest connects to the
  Mac at 192.168.64.1 per request, identified by a random id sent over vsock), and host.docker.internal
  connects to the same listener with a per-boot secret (`/run/mdock/mac` in the guest). That gives
  TCP's flow control and half-closes end to end. Measure a change to that path with `./bench.sh mdock`.
- Disks must stay `.cached` + `.fsync`; `.automatic` corrupted ext4.
- macOS refuses `shutdown(SHUT_RDWR)` (ENOTCONN, and shuts nothing) on a unix socket whose peer has
  already half-closed; shut the write side on its own (`Sockets.shutdownBoth`). libkrun hit this too
  (`gpu/patches/libkrun-vsock-prompt-close.patch`).
- Virtualization.framework never gives the Mac back memory the guest has touched; don't expect the
  balloon to lower the VM's footprint. Keep `init_on_alloc=0` on the kernel command line, or the
  guest zeroes (touches) every page it hands to the balloon.
- The guest reads the seed disk's plain ISO 9660 names, lowercased: a seed file called
  `FEXInterpreter` arrives as `fexinterpreter`. `Guest.writeSeed` lowercases names; keep it that way.
- The guest boots without an initramfs when the kernel can mount the root disk itself
  (`~/.mdock/kernel.mounts-root`, written by `installKernel`). Anything that reads random numbers at
  boot (dhcpcd, dockerd) waits for the kernel's entropy pool: keep the virtio RNG loading early, or
  the boot stalls ~1 s. `cat /run/mdock/boot` in the guest shows where boot time goes.
- crun (1.30, Alpine) starts containers ~15% faster than runc under Docker 29, but it ignores
  `--pid=host`: the container gets its own PID namespace (Docker's spec has none; runc honours it),
  which breaks mdock's own guest commands. Re-test `--pid=host` before trying crun again.
- ArcBox's FUSE spin-wait kernel patch (a virtiofs metadata call polls for its reply before sleeping)
  doesn't pay on an M1: at a 40 µs budget it halved the latency of lookups of missing names but made
  stats of existing files 25% slower (the spinning vCPU slows the Mac's side down), and shorter
  budgets were worse at both; whole workloads came out even, at the cost of burnt CPU. Re-measure on
  a newer Mac before adopting it.
- In a VM every write to ACTLR_EL1 (the TSO bit) traps to the hypervisor; the kernel writes it only
  when a switch changes the memory model (`kernel/patches/0018-…`), or every context switch pays.
- Stock libkrun panics on any system register it doesn't handle, killing the VM: a kernel feature
  that touches a new register needs a handler (`gpu/patches/libkrun-hvf-tso.patch`).
- Rosetta's ahead-of-time cache (`mdock set aot=on`) stays off by default: rosettad dies on some
  binaries (the Node in node:20/24-alpine) and leaves an empty cache entry that stops the program from
  starting, and it miscompiles others (node:22-alpine crashes). With it on, mdock-agent deletes empty
  entries and restarts rosettad; `--runtime runc` runs a container without the cache. Check a crash
  under Rosetta with `-e ROSETTA_DISABLE_AOT=1` before blaming anything else.
- Under FEX, Go's asynchronous preemption (SIGURG) crashes Go programs; FEX's patch adds
  `GODEBUG=asyncpreemptoff=1` to what it runs. FEX's own code cache is experimental and needs
  FEXServer; a cache shared between containers would let one poison another's code, so there is none.
- Nothing may poll the Docker API on a timer: each listing wakes dockerd and containerd across every
  vCPU (2 s polling from the menu bar app tripled the idle VM's CPU), and calls on `docker.sock` count
  as activity, so a poller keeps the VM from ever stopping when idle. Follow `/events`, and use
  `~/.mdock/internal.sock` for anything that isn't the user's own command. Measure idle cost with
  `top -l 2 -s 30 -stats pid,command,cpu,power` on the VM process (com.apple.Virtualization.VirtualMachine).
- After changing the desktop app, launch it (`open ~/Applications/"mdock Desktop.app"`); building
  doesn't catch a crash at launch. SwiftUI creates the app's model before `NSApp` exists, so code
  reached from `Model.init` must not assume it. Such a crash exits with status 133 and leaves no
  crash report; a debug build (`swift build --product MdockDesktop`, then run
  `.build/arm64-apple-macosx/debug/MdockDesktop`) prints the reason and the line.
- On the GPU engine a guest Vulkan program's mistake mustn't reach MoltenVK: it runs in the VM's
  process, so a crash there kills the VM (`virglrenderer-no-pipeline-guard.patch`). The VMM logs a
  backtrace to `~/.mdock/daemon.log` when it dies.
