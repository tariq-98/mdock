# How mdock works

```
docker CLI ──unix──▶ ~/.mdock/docker.sock ─┐                      ┌─ Alpine VM (VZ, direct kernel boot) ─────┐
localhost:PORT ──tcp─▶ forwarder ──────────┤  mdock daemon        │ guestd vsock:2379: "<id> <target>"       │
                                           ├─(Swift, VZ)──vsock───▶   connects dockerd or 127.0.0.1:PORT,    │
                                           │◀── TCP over vmnet ───┤   then dials 192.168.64.1, sends <id>    │
                                           │   (the data path)    │ guestd vsock:2375/2376: vsock fallback   │
                                           │                      │ mdock-agent: ready/mem/kernel ─▶ :1024   │
                                           │                      │ virtiofs /Users… · rosetta · balloon     │
                                           └──────────────────────┴──────────────────────────────────────────┘
```

`mdock start` creates the VM on first run: it downloads Alpine Linux's arm64 cloud image (checksum
verified), converts it with `qemu-img`, reads its kernel with `debugfs`, and boots it directly (no
firmware) with a sparse data disk for `/var/lib/docker`. A small read-only seed disk carries
everything mdock runs in the guest; cloud-init only bootstraps the first boot, and later changes are
applied from the seed at boot. State lives in `~/.mdock`.

## Code map

- `Sources/mdock/Daemon.swift`: VM configuration, vsock bridges, port forwarder, file events,
  host.docker.internal, auto-balloon, idle stop, watchdog, the guest's clock, control socket.
  `DialBack.swift`: streams the guest dials back over the VM's network. `UDPForward.swift`: UDP
  flows. `LaunchAgent.swift`: autostart and socket activation. `Krun.swift`: the GPU engine's VMM.
- `Sources/mdock/Guest.swift`: everything that runs in the guest (scripts, services, Docker's
  configuration), shipped on the seed disk.
- `Sources/mdock/main.swift`: CLI, image download, daemon spawn. `Kubernetes.swift`, `Plugin.swift`
  (`docker mdock`), `Doctor.swift`, `MCP.swift` (the MCP server), `Kernel.swift` (`mdock kernel`),
  `Sync.swift`, `Workspace.swift`, `ArchCheck.swift`, `Port.swift`, `Accel.swift`.
- `Sources/MdockDesktop`: the menu-bar app. `Sources/mdock-{vt,ml,llm}`: the accelerator services
  ([accel/CONTRACT.md](../accel/CONTRACT.md)).
- `guest/guestd.c`: `mdock-guestd`, the guest side of the bridges (dial-back, Docker API, published-port
  relay, UDP relay, host.docker.internal, file events, the clock, the TSO probe). A static binary on
  the seed disk; the guest falls back to socat without it.
- Build scripts: `build.sh` (mdock), `cli/` (docker CLI tools), `guest/` (mdock-guestd, FEX, QEMU),
  `kernel/` (guest kernel), `gpu/` (GPU engine), `accel/` (accelerators), `desktop/` (the app).

## What the daemon does

- **Resources**: all cores and up to half the RAM (8 vCPUs / 8 GiB on a 16 GB M1). An auto-balloon
  keeps the guest near what it uses plus 1.5 GiB (it grows back within 5 s under pressure, and the
  guest's deflate-on-OOM is a backstop). On the GPU engine, memory the guest frees goes back to macOS.
- **Idle stop** (under `mdock autostart on`): launchd holds `docker.sock`; after `idle` minutes (10)
  with no containers running and no docker clients the VM shuts down, and the next docker command,
  on mdock's socket or the default one, starts it again and waits for it (~1.2 s). mdock's own calls,
  the menu bar app and Mutagen use `~/.mdock/internal.sock`, which doesn't count as activity. `mdock
  stop` still means stopped.
- **Idle cost** (1.1% of one core for the VM with nothing running, Energy Impact ~1.2): nothing polls
  Docker. The menu bar app reads the daemon's status every 2 s (its control socket) and reloads
  containers and images when Docker's event stream reports a change; polling them every 2 s had
  dockerd and containerd waking each other ~1,000 times a second each, tripling the idle VM's CPU.
  In the guest, `mdock-guestd` reports memory every 5 s and watches `/proc/net` every second for
  host-network listeners (running the full scan, `mdock-hostports`, only when they change) without
  starting processes; the shell loops it replaced started three or four a second (~1% of a core).
  The kernel boots with `kfence.sample_interval=0` (Alpine's KFENCE woke a vCPU ten times a second)
  and `vm.stat_interval=10`.
- **Networking**: kernel vmnet NAT instead of a userspace TCP/IP stack. Published TCP and UDP ports
  appear on `localhost` automatically, following `docker events`. Published TCP ports and the Docker
  API reach the guest by dial-back over vmnet (below); UDP ports go over vsock.
- **`host.docker.internal` is the Mac's own localhost** (IPv4 and IPv6), and `--add-host
  x:host-gateway` resolves to it. TCP to 192.168.65.254 is redirected in the guest to `mdock-guestd`,
  which connects to the Mac over the VM's network (the dial-back listener, with a per-boot secret
  only it knows) or, until dial-back is up, over vsock; the daemon connects to its own loopback. A
  closed port resets the connection.
- **Same-path bind mounts**: `/Users`, `/Volumes`, `/private` and `/var/folders` are virtiofs-shared
  at identical paths.
- **File watchers**: FSEvents on the bind-mount sources of running containers; `mdock-guestd`
  re-applies each changed file's mode, which raises `IN_ATTRIB` for inotify watchers (vite, webpack,
  nodemon, watchdog). Mass changes poke directories instead of every file.
- **Starts at login and restarts after a crash** (`mdock autostart on`), with a crash-loop guard and a
  watchdog that restarts the VM if the vsock bridge stays dead for two minutes. A guest kernel panic
  reboots (`panic=10`), which stops the VM, and launchd starts it again; `~/.mdock/console.log.1`
  keeps the previous boot's console.
- **The guest's clock**: the VM's clock stops while the Mac sleeps, and chrony would only correct it at
  its next poll (minutes later, or never offline). The watchdog notices a sleep (the Mac's uptime clock
  paused while its monotonic one ran on) and sends the Mac's time; `mdock-guestd` steps the guest's
  clock if it is more than a second off.
- **The default socket**: Docker Desktop's helper points `/var/run/docker.sock` at
  `~/.docker/run/docker.sock`; while Desktop isn't serving it, the daemon points that at mdock, so the
  `default` and `desktop-linux` contexts and tools hard-wired to the socket reach mdock too.
- **Clean lifecycle**: vsock poweroff, then the VZ power button, and a forced stop only after 60 s.
  Disks use `.cached` + `.fsync` caching (`.automatic` corrupted ext4).

## Boot

mdock's kernel has the VM's devices (virtio block, net, mmio, vsock, balloon, virtiofs) and ext4
built in, so it mounts the root disk itself: when `installKernel` finds them in the image it writes
`~/.mdock/kernel.mounts-root` and the VM boots without the initramfs (Alpine's kernel keeps it; delete
the file to force it). The guest loads the virtio RNG early (`/etc/modules`), or the kernel's random
pool took ~1.5 s to fill and the boot waited on it. `/run/mdock/boot` records each step in seconds
after the kernel started; on an M1: init 0.1 s, Docker's socket 0.55 s, ready 0.6 s, and `docker ps`
answers 1.2 s after waking mdock from an idle stop (the daemon starts the VM 0.12 s after launch).

## vsock, and why the bulk goes over the VM's network

Virtualization.framework moves guest data into the Mac's sockets from one serial queue per VM, so one
host socket left unread stalls every vsock connection: docker.sock, ports, the guest's reports. That
caused this project's freezes (a slow ffmpeg reader; a container watcher that paused its event
stream). So whatever comes out of a vsock stream is read at once into a buffer with a separate writer
(`Sockets.splice`), the event watcher hands its work to a coalescing worker, and a connection whose
reader falls 64 MiB behind is dropped: on vsock, a slow reader can't slow the guest down. The other
direction, from the Mac into the guest, simply waits for vsock to take the bytes.

Dropping is a poor answer for bulk data (`docker save | gzip`, `docker logs | less`, a phone streaming
from a server in a container), so published TCP ports and the Docker API avoid vsock: **dial-back**
(`DialBack.swift`). For each connection the daemon writes "<id> <target>" on a vsock control stream to
`mdock-guestd`, which connects to the target (dockerd's socket, or 127.0.0.1:PORT, which also reaches
loopback-only listeners), dials the Mac at its vmnet address (192.168.64.1) and sends the id; the
daemon splices the client to that connection. The bytes then travel over TCP, with flow control end
to end and real half-closes, at 23–34 Gbit/s instead of vsock's 5–9 (M1). host.docker.internal goes
the other way on the same listener: `mdock-guestd` connects and sends a per-boot secret (given to it
over vsock, kept in the guest's `/run/mdock/mac`, out of containers' reach) and the port, and the
daemon connects to its own loopback (25–38 Gbit/s instead of ~4). macOS's Local Network
privacy stops a daemon run by launchd from dialing into the VM's subnet, but accepting connections
from it needs no permission. Ids are random 128-bit values that only travel over vsock, and only the
guest's address may connect, so nothing else on that network can attach itself to a client. Setting
up a connection this way takes ~0.7 ms longer than over vsock; `docker run` doesn't notice. If the
guest doesn't dial back within a second, connections use vsock for a minute and then try again; the
GPU engine's guest is behind gvproxy and always uses vsock.

## Low-level limitations

- Virtualization.framework drops a half-close made in the guest (`shutdown(SHUT_WR)` on vsock never
  reaches the Mac). The guest bridges close the vsock end outright when their side finishes, so over
  vsock (the GPU engine, the fallback) a container server can't keep reading from a client after it
  has finished sending. Connections over the VM's network pass half-closes through.
- What comes out of a vsock stream can't be slowed down: a reader on the Mac that falls 64 MiB behind
  loses the connection. That still applies to UDP, the accelerators and everything on the GPU engine.
- File events arrive as `IN_ATTRIB`, not `IN_MODIFY`/`IN_CREATE`.
- Virtualization.framework never returns memory the guest has touched until the VM stops: on the
  default engine the balloon bounds it and idle stop resets it.
