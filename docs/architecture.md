# How mdock works

```
docker CLI ──unix──▶ ~/.mdock/docker.sock ─┐                    ┌─ Alpine VM (VZ, direct kernel boot) ─┐
localhost:PORT ──tcp─▶ forwarder ──────────┤  mdock daemon      │ guestd vsock:2375 ─▶ dockerd          │
                                           ├─(Swift, VZ)───vsock─▶ guestd vsock:2376 ─▶ 127.0.0.1:PORT   │
                           vmnet NAT ──────┘                    │ mdock-agent: ready/mem/kernel ─▶ :1024 │
                                                                │ virtiofs /Users… · rosetta · balloon  │
                                                                └───────────────────────────────────────┘
```

`mdock start` creates the VM on first run: it downloads Alpine Linux's arm64 cloud image (checksum
verified), converts it with `qemu-img`, reads its kernel with `debugfs`, and boots it directly (no
firmware) with a sparse data disk for `/var/lib/docker`. A small read-only seed disk carries
everything mdock runs in the guest; cloud-init only bootstraps the first boot, and later changes are
applied from the seed at boot. State lives in `~/.mdock`.

## Code map

- `Sources/mdock/Daemon.swift`: VM configuration, vsock bridges, port forwarder, file events,
  host.docker.internal, auto-balloon, idle stop, watchdog, control socket. `UDPForward.swift`: UDP
  flows. `LaunchAgent.swift`: autostart and socket activation. `Krun.swift`: the GPU engine's VMM.
- `Sources/mdock/Guest.swift`: everything that runs in the guest (scripts, services, Docker's
  configuration), shipped on the seed disk.
- `Sources/mdock/main.swift`: CLI, image download, daemon spawn. `Kubernetes.swift`, `Plugin.swift`
  (`docker mdock`), `Doctor.swift`, `MCP.swift` (the MCP server), `Kernel.swift` (`mdock kernel`),
  `Sync.swift`, `Workspace.swift`, `ArchCheck.swift`, `Port.swift`, `Accel.swift`.
- `Sources/MdockDesktop`: the menu-bar app. `Sources/mdock-{vt,ml,llm}`: the accelerator services
  ([accel/CONTRACT.md](../accel/CONTRACT.md)).
- `guest/guestd.c`: `mdock-guestd`, the guest side of the bridges (Docker API, published-port relay,
  UDP relay, host.docker.internal, file events, the TSO probe). A static binary on the seed disk; the
  guest falls back to socat without it.
- Build scripts: `build.sh` (mdock), `cli/` (docker CLI tools), `guest/` (mdock-guestd, FEX, QEMU),
  `kernel/` (guest kernel), `gpu/` (GPU engine), `accel/` (accelerators), `desktop/` (the app).

## What the daemon does

- **Resources**: all cores and up to half the RAM (8 vCPUs / 8 GiB on a 16 GB M1). An auto-balloon
  keeps the guest near what it uses plus 1.5 GiB (it grows back within 5 s under pressure, and the
  guest's deflate-on-OOM is a backstop). On the GPU engine, memory the guest frees goes back to macOS.
- **Idle stop** (under `mdock autostart on`): launchd holds `docker.sock`; after `idle` minutes (10)
  with no containers running and no docker clients the VM shuts down, and the next docker command,
  on mdock's socket or the default one, starts it again and waits for it (~3.5 s). mdock's own calls
  and Mutagen don't count as activity. `mdock stop` still means stopped.
- **Networking**: kernel vmnet NAT instead of a userspace TCP/IP stack. Published TCP and UDP ports
  appear on `localhost` automatically, following `docker events`.
- **`host.docker.internal` is the Mac's own localhost** (IPv4 and IPv6), and `--add-host
  x:host-gateway` resolves to it. TCP to 192.168.65.254 is redirected in the guest to `mdock-guestd`
  and carried over vsock to the Mac's loopback; a closed port resets the connection.
- **Same-path bind mounts**: `/Users`, `/Volumes`, `/private` and `/var/folders` are virtiofs-shared
  at identical paths.
- **File watchers**: FSEvents on the bind-mount sources of running containers; `mdock-guestd`
  re-applies each changed file's mode, which raises `IN_ATTRIB` for inotify watchers (vite, webpack,
  nodemon, watchdog). Mass changes poke directories instead of every file.
- **Starts at login and restarts after a crash** (`mdock autostart on`), with a crash-loop guard and a
  watchdog that restarts the VM if the vsock bridge stays dead for two minutes.
- **The default socket**: Docker Desktop's helper points `/var/run/docker.sock` at
  `~/.docker/run/docker.sock`; while Desktop isn't serving it, the daemon points that at mdock, so the
  `default` and `desktop-linux` contexts and tools hard-wired to the socket reach mdock too.
- **Clean lifecycle**: vsock poweroff, then the VZ power button, and a forced stop only after 60 s.
  Disks use `.cached` + `.fsync` caching (`.automatic` corrupted ext4).

## vsock, and why every relay buffers

Virtualization.framework moves guest data into the Mac's sockets from one serial queue per VM, so one
host socket left unread stalls every vsock connection: docker.sock, ports, the guest's reports. That
caused this project's freezes (a slow ffmpeg reader; a container watcher that paused its event
stream). Every relay (`Sockets.splice`) therefore reads continuously into a buffer with a separate
writer, drops only the connection that falls 64 MiB behind, and the event watcher hands its work to a
coalescing worker.

## Low-level limitations

- Under launchd (`mdock autostart on`) published ports go over the vsock relay, roughly 0.4–0.85 GB/s
  (Virtualization.framework's vsock device is the ceiling), not vmnet's 5–6.5 GB/s: macOS's Local
  Network privacy blocks a launchd agent from connecting into the VM's subnet (an ad-hoc signed binary
  can't keep that permission across rebuilds). Started from a terminal, the daemon connects directly
  and falls back to the relay.
- Virtualization.framework drops a half-close made in the guest (`shutdown(SHUT_WR)` on vsock never
  reaches the Mac). The guest bridges close the vsock end outright when their side finishes, so a
  container server can't keep reading from a client after it has finished sending; a Mac server
  behind host.docker.internal doesn't see a client's half-close.
- File events arrive as `IN_ATTRIB`, not `IN_MODIFY`/`IN_CREATE`.
- Virtualization.framework never returns memory the guest has touched until the VM stops: on the
  default engine the balloon bounds it and idle stop resets it.
