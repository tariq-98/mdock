import CryptoKit
import Foundation

/// Guest-side files, delivered on a read-only "cidata" seed disk (/dev/vdc).
///
/// cloud-init only bootstraps the first boot (packages + provision.sh). After that
/// cloud-init is disabled for boot speed, and mdock-guest re-runs provision.sh from
/// the seed itself whenever the host ships different guest files.
enum Guest {
    /// Vsock port where the guest agent bridges /var/run/docker.sock.
    static let dockerPort: UInt32 = 2375
    /// Vsock port the host listens on for guest notifications ("ready <ip>", "mem <totalKiB> <availKiB> <balloonKiB>").
    static let notifyPort: UInt32 = 1024
    /// Vsock port that powers the guest off cleanly when connected to.
    static let poweroffPort: UInt32 = 1025
    /// Vsock port of the relay that reaches ports bound to the guest's loopback.
    static let relayPort: UInt32 = 2376
    /// Vsock port where mdock-guestd turns Mac file-change paths into inotify events.
    static let fileEventsPort: UInt32 = 2377
    /// Vsock port of mdock-guestd's UDP relay for published UDP ports.
    static let udpPort: UInt32 = 2378
    /// Vsock port where mdock-guestd takes requests to dial back to the Mac for published TCP ports
    /// (DialBack).
    static let dialBackPort: UInt32 = 2379
    /// Vsock port where mdock-guestd sets the guest's clock to the Mac's time.
    static let clockPort: UInt32 = 2380
    /// Vsock port the host listens on for host.docker.internal: mdock-guestd sends "<port>\n" and
    /// the connection's bytes, and the host connects to its own loopback.
    static let hostForwardPort: UInt32 = 1031
    /// host.docker.internal on the VZ engine (Docker Desktop uses the same address); the guest
    /// redirects TCP to it into mdock-guestd. The GPU engine's gvproxy provides 192.168.127.254.
    static let hostLoopbackIP = "192.168.65.254"

    /// mdock-guestd (guest/build.sh): next to the mdock binary in the app bundle, or the source tree's
    /// build output in development. Optional; without it the guest falls back to socat.
    static var guestd: URL? { binary("mdock-guestd") }

    /// Static linux/arm64 programs from guest/build.sh, shipped on the seed disk: (file, install
    /// path). x86 programs run through Rosetta (default engine, x86-64), FEX (GPU engine, and 32-bit
    /// x86 everywhere) when mdock's kernel gives it hardware TSO, else QEMU.
    static let binaries = [("mdock-guestd", "/usr/local/sbin/mdock-guestd"),
                           ("qemu-x86_64", "/usr/local/libexec/mdock/qemu-x86_64"),
                           ("qemu-i386", "/usr/local/libexec/mdock/qemu-i386"),
                           ("FEXInterpreter", "/usr/local/libexec/mdock/FEXInterpreter")]

    static func binary(_ name: String) -> URL? {
        let exe = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0]).resolvingSymlinksInPath()
        var candidates = [exe.deletingLastPathComponent().appendingPathComponent(name),
                          exe.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/\(name)")]
        // Development: the source tree above .build/<triple>/release.
        var dir = exe.deletingLastPathComponent()
        while dir.path != "/" {
            candidates.append(dir.appendingPathComponent("guest/out/\(name)"))
            dir = dir.deletingLastPathComponent()
        }
        return candidates.first { FileManager.default.isReadableFile(atPath: $0.path) }
    }

    static let packages = ["docker", "socat", "e2fsprogs", "util-linux", "chrony", "dnsmasq"]

    /// Runs before dockerd: applies seed updates, mounts the data disk, host shares and Rosetta.
    static let prepareScript = #"""
    #!/bin/sh
    # Prepares the mdock guest before dockerd starts.
    log() { echo "mdock-guest: $*" >/dev/kmsg 2>/dev/null; echo "mdock-guest: $*"; }

    SEED=/run/mdock-seed
    if [ -z "$MDOCK_REEXEC" ] && mkdir -p $SEED && mount -t iso9660 -o ro /dev/vdc $SEED 2>/dev/null; then
      if ! cmp -s $SEED/mdock/instance-id /etc/mdock/instance-id; then
        log "applying updated guest files"
        sh $SEED/mdock/provision.sh
        umount $SEED
        MDOCK_REEXEC=1 exec /usr/local/sbin/mdock-guest
      fi
      umount $SEED
    fi

    # (Built into mdock's kernel; modules in Alpine's. The GPU only exists on the GPU engine.)
    for m in virtiofs vsock vmw_vsock_virtio_transport virtio_balloon binfmt_misc; do
      modprobe -q "$m" 2>/dev/null || true
    done
    grep -q mdock.engine=krun /proc/cmdline && modprobe -q virtio_gpu
    # Small readahead: the default 8 MiB pulls in data nothing asked for, and on Virtualization.framework
    # every page the guest touches stays charged to the Mac (which caches the disk images anyway).
    for q in /sys/block/vd*/queue/read_ahead_kb; do echo 128 > "$q"; done

    # /var/lib/docker lives on the second virtio disk, formatted on first boot.
    DATA=/dev/vdb
    if [ -b "$DATA" ]; then
      if ! blkid "$DATA" >/dev/null 2>&1; then
        log "formatting $DATA"
        mkfs.ext4 -q -L mdock-data -E lazy_itable_init=1,lazy_journal_init=1 "$DATA"
      fi
      mkdir -p /var/lib/docker
      mountpoint -q /var/lib/docker || mount -o noatime,discard "$DATA" /var/lib/docker
      resize2fs "$DATA" >/dev/null 2>&1 || true  # picks up `mdock set disk=N`
    fi

    # Host directories appear at the same paths as on macOS, so bind mounts
    # like -v /Users/me/src:/src resolve without translation.
    while read -r tag path; do
      [ -n "$tag" ] || continue
      mkdir -p "$path"
      mountpoint -q "$path" || mount -t virtiofs "$tag" "$path" || log "mount $tag at $path failed"
    done < /etc/mdock/shares

    # Rosetta runs linux/amd64 binaries instead of QEMU emulation. The F flag pins the
    # interpreter at registration, so it works inside every container's mount namespace.
    mountpoint -q /proc/sys/fs/binfmt_misc || mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc
    x86_64_magic='\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x3e\x00'
    i386_magic='\x7fELF\x01\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x03\x00'
    x86_mask='\xff\xff\xff\xff\xff\xfe\xfe\x00\x00\x00\x00\xff\xff\xff\xff\xff\xfe\xff\xff\xff'
    lib=/usr/local/libexec/mdock
    register() { # name magic mask interpreter flags
      [ -e /proc/sys/fs/binfmt_misc/$1 ] && echo -1 > /proc/sys/fs/binfmt_misc/$1
      printf '%s' ":$1:M::$2:$3:$4:$5" > /proc/sys/fs/binfmt_misc/register
    }
    # FEX translates x86 code fast, but correctly only when the CPU runs its threads in x86's memory
    # order: Apple silicon's TSO mode, which mdock's kernel exposes (mdock kernel install).
    fex=""
    [ -x $lib/FEXInterpreter ] && [ -x /usr/local/sbin/mdock-guestd ] && /usr/local/sbin/mdock-guestd tso && fex=$lib/FEXInterpreter
    mkdir -p /mnt/rosetta
    if mountpoint -q /mnt/rosetta || mount -t virtiofs rosetta /mnt/rosetta 2>/dev/null; then
      # Apple's documented mask. Rosetta asks for TSO itself, too.
      register rosetta "$x86_64_magic" '\xff\xff\xff\xff\xff\xfe\xfe\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff' \
        /mnt/rosetta/rosetta OCF
    elif [ -n "$fex" ]; then
      register FEX-x86_64 "$x86_64_magic" "$x86_mask" $fex POCF
    elif [ -x $lib/qemu-x86_64 ]; then
      # Static, so the pinned interpreter runs in any container. P keeps argv[0], which QEMU reads
      # back from AT_FLAGS.
      register qemu-x86_64 "$x86_64_magic" "$x86_mask" $lib/qemu-x86_64 POCF
    else
      log "no x86-64 translator; amd64 images will not run"
    fi
    # linux/386: Rosetta only translates 64-bit code.
    if [ -n "$fex" ]; then
      register FEX-x86 "$i386_magic" "$x86_mask" $fex POCF
    elif [ -x $lib/qemu-i386 ]; then
      register qemu-i386 "$i386_magic" "$x86_mask" $lib/qemu-i386 POCF
    fi

    /usr/local/sbin/mdock-cdi

    sysctl -q -p /etc/sysctl.d/90-mdock.conf || true
    """#

    /// Installs the guest files from the seed and tunes the boot. Idempotent.
    static let provisionScript = #"""
    #!/bin/sh
    # Installs mdock guest files from the seed disk; runs on first boot and whenever the seed changes.
    SRC=$(dirname "$0")
    while read -r name dest mode; do
      mkdir -p "$(dirname "$dest")"
      install -m "$mode" "$SRC/$name" "$dest"
    done < "$SRC/manifest"

    grep -q '^rc_need="mdock-guest"' /etc/conf.d/docker || echo 'rc_need="mdock-guest"' >> /etc/conf.d/docker
    sed -i 's/^#\{0,1\}rc_cgroup_mode=.*/rc_cgroup_mode="unified"/' /etc/rc.conf
    # DHCP without the ARP probe or the random start delay, and in the background: waiting for the
    # lease held up the whole boot by ~2 s. mdock-agent waits for the address before reporting ready.
    sed -i '/^waitip/d' /etc/dhcpcd.conf
    for option in noarp nodelay background; do grep -q "^$option" /etc/dhcpcd.conf || echo "$option" >> /etc/dhcpcd.conf; done
    # resolv.conf belongs to mdock-agent (dnsmasq); dhcpcd must not rewrite it.
    grep -q '^nohook resolv.conf' /etc/dhcpcd.conf || echo 'nohook resolv.conf' >> /etc/dhcpcd.conf
    # Step the clock whenever it is off by >1s: the VM's clock stalls while the Mac sleeps.
    sed -i 's/^makestep .*/makestep 1 -1/' /etc/chrony/chrony.conf

    # Other services pull in hwclock via "need clock"; stop it waiting ~10s for an RTC tick
    # VZ never sends. The kernel already set the time from the RTC; chrony keeps it right.
    sed -i 's/^#\{0,1\}clock_hctosys=.*/clock_hctosys="NO"/; s/^#\{0,1\}clock_systohc=.*/clock_systohc="NO"/' /etc/conf.d/hwclock
    # No serial UARTs exist under VZ; stop init respawning gettys on them.
    sed -i -E 's/^(tty(S|AMA)[0-9]+:)/#\1/' /etc/inittab
    for s in mdock-guest docker mdock-agent chronyd; do rc-update add "$s" default >/dev/null 2>&1; done
    # Boot speed: power-off arrives over vsock, not ACPI; no SSH; cloud-init is done.
    for s in acpid cloud-init-local; do rc-update del "$s" boot >/dev/null 2>&1; done
    # hwdrivers loads a module for every device it finds (a framebuffer, a GPIO controller, crypto):
    # mdock needs none of them, and loads what it does need itself (mdock-guest).
    rc-update del hwdrivers sysinit >/dev/null 2>&1
    # Early entropy: with no initramfs or hwdrivers to load the virtio RNG, the kernel's random pool
    # filled only after ~1.5 s, and the boot waited on it (dhcpcd and dockerd read random numbers).
    grep -qx virtio_rng /etc/modules || echo virtio_rng >> /etc/modules
    for s in sshd cloud-init cloud-config cloud-final cloud-init-hotplugd; do rc-update del "$s" default >/dev/null 2>&1; done

    install -m 0644 "$SRC/instance-id" /etc/mdock/instance-id
    # On disk now, not in up to 30 s: if the VM dies first (a host crash is a power cut to the guest),
    # ext4's delayed allocation leaves every file just installed empty, and the guest can't boot.
    sync
    """#

    /// Long-running agent: docker.sock <-> vsock bridge plus readiness and memory reports.
    static let agentScript = #"""
    #!/bin/sh
    # Bridges the Docker socket to the host over vsock and reports guest state.
    trap 'kill 0' EXIT INT TERM
    notify() { echo "$*" | socat -u - VSOCK-CONNECT:2:1024 2>/dev/null; }
    # Seconds since the kernel started, per boot step: cat /run/mdock/boot
    mkdir -p /run/mdock
    mark() { echo "$(cut -d' ' -f1 /proc/uptime) $1" >> /run/mdock/boot; }
    mark agent

    guestd=/usr/local/sbin/mdock-guestd
    if [ -x $guestd ]; then
      # The Docker API, a thread per connection (socat forks a process per connection, and bursts of
      # parallel API calls overflowed its accept queue). Same semantics as the socat line below.
      $guestd unix 2375 /var/run/docker.sock &
    else
      # -t: keep streaming after the client half-closes (docker attach does this).
      # -b: 256 KiB blocks (socat's default is 8 KiB) for image loads, docker cp and published ports.
      # shut-close: Virtualization.framework never shows the host a guest-side half-close, so when the
      # guest side finishes, close the vsock end outright or the host waits for EOF forever.
      # backlog: socat's default of 5 refuses bursts of parallel API calls (compose, IDEs, buildx).
      socat -b 262144 -t 86400 VSOCK-LISTEN:2375,reuseaddr,fork,backlog=128,shut-close UNIX-CONNECT:/var/run/docker.sock &
    fi
    if [ -x $guestd ]; then
      $guestd relay 2376 &
      $guestd notify 2377 &
      $guestd udp 2378 &
      $guestd dialback 2379 &
      $guestd clock 2380 &
    else
      # nofork: mdock-relay gets the vsock connection itself as stdin/stdout (no extra hop).
      socat -t 86400 VSOCK-LISTEN:2376,reuseaddr,fork,backlog=128 EXEC:/usr/local/sbin/mdock-relay,nofork &
    fi
    socat -u VSOCK-LISTEN:1025,reuseaddr SYSTEM:'poweroff' &

    i=0
    while [ ! -S /var/run/docker.sock ] && [ $i -lt 1500 ]; do sleep 0.02; i=$((i+1)); done
    mark docker

    # Rosetta's ahead-of-time cache (`mdock set aot=on`; off by default): rosettad keeps translated
    # amd64 code on the data disk, so it is translated once rather than on every run. It has to run
    # from the Rosetta share. Rosetta finds it at /run/rosettad/rosetta.sock, in the VM and, through
    # mdock-runc, in every container. Rosetta's translator fails on some binaries (Node's Alpine
    # builds): an assertion kills rosettad and leaves an empty cache entry, which then stops that
    # program from starting at all. So empty entries are dropped and a dead rosettad is restarted.
    rcache=/var/lib/docker/mdock-rosettad
    rosettad_pid=""
    rosettad_start() {
      find $rcache -maxdepth 1 -name '*.aotcache' -size 0 -delete 2>/dev/null
      rm -f $rcache/uds/rosetta.sock
      /mnt/rosetta/rosettad daemon $rcache >/dev/null 2>&1 &
      rosettad_pid=$!
      i=0
      while [ ! -S $rcache/uds/rosetta.sock ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i+1)); done
      chmod go+w $rcache/uds/rosetta.sock 2>/dev/null
      ln -sf $rcache/uds/rosetta.sock /run/rosettad/rosetta.sock
    }
    if [ "$(cat /etc/mdock/rosetta-aot 2>/dev/null)" = on ] && [ -x /mnt/rosetta/rosettad ]; then
      mkdir -p $rcache /run/rosettad
      rosettad_start
    else
      # No socket, so Rosetta translates as it runs and mdock-runc mounts nothing.
      rm -f $rcache/uds/rosetta.sock /run/rosettad/rosetta.sock
      find $rcache -maxdepth 1 -name '*.aotcache' -size 0 -delete 2>/dev/null
    fi
    ip=""
    while [ -z "$ip" ]; do
      ip=$(ip -4 -o addr show eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
      [ -n "$ip" ] || sleep 0.02
    done
    # Packages added after first boot are installed here, once the network is up.
    mark ip

    # host.docker.internal -> the Mac. dnsmasq on the guest IP answers for the guest and, through
    # it, for every container network.
    gw=$(ip route | awk '/^default/{print $3; exit}')
    host="$gw"
    if grep -q 'mdock.engine=krun' /proc/cmdline; then
      # The GPU engine's gvproxy maps 192.168.127.254 to the Mac's 127.0.0.1.
      host=192.168.127.254
    elif [ -x $guestd ]; then
      # Reach the Mac's own localhost, as Docker Desktop does: TCP to this address is redirected to
      # mdock-guestd, which carries it over vsock to the Mac's loopback.
      host=192.168.65.254
      $guestd hostfwd 61080 1031 &
      for chain in PREROUTING OUTPUT; do
        iptables -t nat -C $chain -d $host -p tcp -j REDIRECT --to-ports 61080 2>/dev/null ||
          iptables -t nat -I $chain -d $host -p tcp -j REDIRECT --to-ports 61080
      done
    fi
    # *.mdock.internal -> this VM, where the accelerator relays below listen.
    if command -v dnsmasq >/dev/null && [ -n "$gw" ]; then
      dnsmasq -k --no-resolv --server="$gw" --listen-address="$ip" --bind-interfaces --cache-size=1000 \
        --address=/host.docker.internal/"$host" --address=/gateway.docker.internal/"$gw" \
        --address=/mdock.internal/"$ip" &
      echo "nameserver $ip" > /etc/resolv.conf
    fi

    # Accelerator bridge (accel/CONTRACT.md): unix sockets for CDI-mounted clients, TCP for HTTP/RPC.
    mkdir -p /run/mdock/accel
    socat -t 86400 UNIX-LISTEN:/run/mdock/accel/media.sock,fork,backlog=128,mode=666,unlink-early VSOCK-CONNECT:2:1026 &
    socat -t 86400 UNIX-LISTEN:/run/mdock/accel/vt.sock,fork,backlog=128,mode=666,unlink-early VSOCK-CONNECT:2:1027 &
    socat -t 86400 TCP4-LISTEN:8100,bind="$ip",reuseaddr,fork,backlog=128 VSOCK-CONNECT:2:1028 &
    socat -t 86400 TCP4-LISTEN:8200,bind="$ip",reuseaddr,fork,backlog=128 VSOCK-CONNECT:2:1029 &
    socat -t 86400 TCP4-LISTEN:50052,bind="$ip",reuseaddr,fork,backlog=128,nodelay VSOCK-CONNECT:2:1030 &

    notify "ready $ip"
    mark ready
    # Packages added to mdock after this guest was created; installed after ready, so a download never
    # holds up the boot.
    apk info -e $(cat /etc/mdock/packages) >/dev/null 2>&1 || apk add -q $(cat /etc/mdock/packages) &
    # The kernel mdock boots: its own (kernel/build.sh: TSO for x86 translators) once installed, else
    # Alpine's. The Mac re-extracts it from /boot when this stamp changes.
    kfiles="/boot/vmlinuz-virt /boot/initramfs-virt"
    [ -f /boot/vmlinuz-mdock ] && [ -f /boot/initramfs-mdock ] && kfiles="/boot/vmlinuz-mdock /boot/initramfs-mdock"
    notify "kernel $(stat -c %Y $kfiles | tr '\n' '-') $(uname -r)"
    # A removed mdock kernel's modules, once it no longer runs.
    [ -f /boot/vmlinuz-mdock ] || for d in /lib/modules/*-mdock; do [ -d "$d" ] && [ "$d" != "/lib/modules/$(uname -r)" ] && rm -rf "$d"; done
    notify "tso $([ -x $guestd ] && $guestd tso && echo 1 || echo 0)"
    # Which translator runs x86 programs (mdock-guest registered them): rosetta, FEX-x86_64, FEX-x86, qemu-*.
    notify "binfmt $(ls /proc/sys/fs/binfmt_misc 2>/dev/null | grep -vxE 'register|status' | tr '\n' ' ')"

    # mdock sync: put each synced copy (ext4, in the mdock-sync volume) over its shared path.
    overlays="$(dirname "$(cat /etc/mdock/accel-dir)")/sync-overlays"
    if [ -f "$overlays" ]; then
      while read -r id path; do
        src=/var/lib/docker/volumes/mdock-sync/_data/$id
        [ -n "$id" ] && [ -d "$src" ] && [ -d "$path" ] && ! mountpoint -q "$path" && mount --bind "$src" "$path"
      done < "$overlays"
    fi

    # GPU engine: libkrun hands memory the guest frees back to the Mac (free page reporting), but page
    # cache isn't free memory and would fill the VM over time. The Mac caches the VM's disk images
    # anyway, so keep the guest's cold cache small: every 30 s, reclaim inactive file pages past 256 MiB.
    if grep -q 'mdock.engine=krun' /proc/cmdline && [ -w /sys/fs/cgroup/memory.reclaim ]; then
      ( while sleep 30; do
          inactive=$(awk '/^Inactive\(file\):/ {print $2}' /proc/meminfo)
          excess=$((${inactive:-0} - 262144))
          [ "$excess" -gt 65536 ] && echo "${excess}K" > /sys/fs/cgroup/memory.reclaim 2>/dev/null
        done ) &
    fi

    # Kubernetes (mdock kubernetes enable): state, k3s version and LoadBalancer ports, every 10 s.
    k8s_report() {
      if [ ! -e /etc/runlevels/default/k3s ]; then echo off; return; fi
      rc-service -q k3s status 2>/dev/null || { echo down; return; }
      lb=$(KUBECONFIG=/etc/rancher/k3s/k3s.yaml timeout 5 kubectl get svc -A \
        -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{range .spec.ports[*]}{.port}/{.protocol} {end}{end}' 2>/dev/null) ||
        { echo "starting ${k3sver:--}"; return; }
      echo "up ${k3sver:--} $lb"
    }

    # Listeners of host-network containers (--network host, hostNetwork pods): in the VM's own network
    # namespace and in a container's cgroup. "proto:port:all|lo", for the Mac's localhost.
    host_ports() {
      netstat -lntu -p 2>/dev/null | awk 'NR > 2 { print $1, $4, $NF }' | while read -r proto local prog; do
        pid=${prog%%/*}
        case "$pid" in ''|*[!0-9]*) continue ;; esac
        grep -qE '^0::/(docker|kubepods)/' /proc/$pid/cgroup 2>/dev/null || continue
        case "${local%:*}" in 127.0.0.1|::1) scope=lo ;; *) scope=all ;; esac
        echo "${proto%6}:${local##*:}:$scope"
      done | sort -u | tr '\n' ' '
    }
    # Every second, so a new --network host listener shows up on the Mac almost at once.
    (
      last=""
      while true; do
        hp=$(host_ports)
        [ "$hp" != "$last" ] && notify "hostnet $hp" && last="$hp"
        sleep 1
      done
    ) &

    n=0
    while true; do
      sleep 5
      n=$((n + 1))
      if [ -n "$rosettad_pid" ] && ! kill -0 "$rosettad_pid" 2>/dev/null; then
        logger -t mdock-agent "rosettad exited (a translation failed); restarting it"
        rosettad_start
      fi
      if [ $((n % 2)) -eq 0 ]; then
        [ -n "$k3sver" ] || [ ! -e /etc/runlevels/default/k3s ] || k3sver=$(k3s --version 2>/dev/null | awk 'NR==1{print $3}')
        notify "k8s $(k8s_report)"
      fi
      [ $((n % 6)) -eq 0 ] && /usr/local/sbin/mdock-cdi
      # The balloon has DEFLATE_ON_OOM, so MemTotal never shrinks; report ballooned KiB separately.
      notify "$(awk -v ps="$(getconf PAGESIZE)" '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} /^nr_balloon_pages /{b=$2*ps/1024} END{print "mem", t, a, b+0}' /proc/meminfo /proc/vmstat)"
    done
    """#

    /// Writes CDI specs for the accelerators present (re-run by mdock-agent as files appear).
    static let cdiScript = #"""
    #!/bin/sh
    # Generates /var/run/cdi specs: mdock.dev/gpu (Venus) and mdock.dev/media (Mac media engine).
    mkdir -p /var/run/cdi
    write() { # file content: only touch the file when it changes
      if [ "$(cat "$1" 2>/dev/null)" != "$2" ]; then printf '%s\n' "$2" > "$1.tmp" && mv "$1.tmp" "$1"; fi
    }

    # Mesa's Asahi driver sees Apple's vendor ID on virtio-gpu, probes for its native context and
    # crashes the Vulkan loader, so it is disabled for GPU containers.
    if [ -e /dev/dri/renderD128 ]; then
      write /var/run/cdi/mdock-gpu.yaml 'cdiVersion: "0.6.0"
    kind: mdock.dev/gpu
    devices:
      - name: all
        containerEdits:
          deviceNodes:
            - path: /dev/dri/renderD128
            - path: /dev/dri/card0
          env:
            - VK_LOADER_DRIVERS_DISABLE=*asahi*'
    else
      rm -f /var/run/cdi/mdock-gpu.yaml
    fi

    # Media engine: ffmpeg/ffprobe run on the Mac (also replacing jellyfin-ffmpeg in Jellyfin
    # images), and the VA-API driver backed by VideoToolbox once it is built.
    ACCEL=$(cat /etc/mdock/accel-dir 2>/dev/null)
    SHARES=$(cat /etc/mdock/shares-host 2>/dev/null)
    [ -n "$ACCEL" ] || exit 0
    shim="$ACCEL/guest/mdock-media-shim"
    driver="$ACCEL/guest/mdock_drv_video.so"
    devices=""
    if [ -x "$shim" ]; then
      devices="$devices
      - name: ffmpeg
        containerEdits:
          env:
            - MDOCK_SHARES=$SHARES
            - JELLYFIN_REMOTE_VIDEOTOOLBOX=1
          mounts:
            - {hostPath: /run/mdock/accel, containerPath: /run/mdock/accel, options: [bind]}
            - {hostPath: $shim, containerPath: /usr/lib/mdock/bin/ffmpeg, options: [ro, bind]}
            - {hostPath: $shim, containerPath: /usr/lib/mdock/bin/ffprobe, options: [ro, bind]}
            - {hostPath: $shim, containerPath: /usr/lib/jellyfin-ffmpeg/ffmpeg, options: [ro, bind]}
            - {hostPath: $shim, containerPath: /usr/lib/jellyfin-ffmpeg/ffprobe, options: [ro, bind]}"
    fi
    if [ -f "$driver" ]; then
      # libva only opens displays on fds libdrm recognises as DRM. On the GPU engine the real render
      # node exists; on VZ a /dev/null stand-in plus a tiny libdrm shim (via /etc/ld.so.preload, so
      # images' own LD_PRELOAD survives; musl ignores it) answers libdrm's queries.
      if [ -e /dev/dri/renderD128 ]; then
        drm="
          deviceNodes:
            - path: /dev/dri/renderD128"
        drmmounts=""
      else
        drm="
          deviceNodes:
            - {path: /dev/dri/renderD128, hostPath: /dev/null, type: c, permissions: rw}"
        drmmounts="
            - {hostPath: $ACCEL/guest/libmdock_drm_shim.so, containerPath: /usr/lib/mdock/libmdock_drm_shim.so, options: [ro, bind]}
            - {hostPath: $ACCEL/guest/ld.so.preload, containerPath: /etc/ld.so.preload, options: [ro, bind]}"
      fi
      devices="$devices
      - name: vaapi
        containerEdits:
          env:
            - LIBVA_DRIVERS_PATH=/usr/lib/mdock/dri
            - LIBVA_DRIVER_NAME=mdock
            - MDOCK_VT_FRAMES=/run/mdock/vt-frames
            - MDOCK_SHARES=$SHARES$drm
          mounts:
            - {hostPath: /run/mdock/accel, containerPath: /run/mdock/accel, options: [bind]}
            - {hostPath: $ACCEL/frames, containerPath: /run/mdock/vt-frames, options: [rw, bind]}
            - {hostPath: $driver, containerPath: /usr/lib/mdock/dri/mdock_drv_video.so, options: [ro, bind]}
            - {hostPath: $driver, containerPath: /usr/lib/aarch64-linux-gnu/dri/mdock_drv_video.so, options: [ro, bind]}
            - {hostPath: $driver, containerPath: /usr/lib/jellyfin-ffmpeg/lib/dri/mdock_drv_video.so, options: [ro, bind]}$drmmounts"
    fi
    if [ -n "$devices" ]; then
      write /var/run/cdi/mdock-media.yaml "cdiVersion: \"0.6.0\"
    kind: mdock.dev/media
    devices:$devices"
    else
      rm -f /var/run/cdi/mdock-media.yaml
    fi
    """#

    /// Reads a port number, then splices the vsock stream (stdin/stdout, via socat nofork) to
    /// 127.0.0.1:<port>. fd 1 goes to /dev/null so fd 0 holds the only reference to the connection
    /// and shut-close really closes it when the guest side finishes (see the agent's 2375 bridge).
    static let relayScript = #"""
    #!/bin/sh
    read -r port
    exec socat -b 262144 -t 86400 FD:0,shut-close TCP:127.0.0.1:"$port",nodelay >/dev/null
    """#

    /// Docker's default runtime in mdock: runc, plus Rosetta's cache socket in every container
    /// (Rosetta looks for /run/rosettad/rosetta.sock inside the container's own filesystem). The socket's
    /// directory is mounted rather than the socket, so a restarted rosettad stays reachable.
    static let runcWrapper = #"""
    #!/bin/sh
    case " $* " in
      *" create "*|*" run "*)
        prev="" bundle=""
        for a in "$@"; do
          case "$prev" in --bundle|-b) bundle="$a" ;; esac
          prev="$a"
        done
        uds=/var/lib/docker/mdock-rosettad/uds
        cfg="$bundle/config.json"
        if [ -n "$bundle" ] && [ -S "$uds/rosetta.sock" ] && [ -f "$cfg" ] && ! grep -q '"destination":"/run/rosettad"' "$cfg"; then
          sed -i 's#"mounts":\[#"mounts":[{"destination":"/run/rosettad","type":"bind","source":"'"$uds"'","options":["rbind","ro"]},#' "$cfg"
        fi
        ;;
    esac
    exec /usr/bin/runc "$@"
    """#

    static let prepareService = #"""
    #!/sbin/openrc-run
    description="mdock guest preparation (disk, shares, rosetta)"
    depend() {
      need localmount
      before docker
    }
    start() {
      ebegin "Preparing mdock guest"
      /usr/local/sbin/mdock-guest
      eend 0
    }
    """#

    static let agentService = #"""
    #!/sbin/openrc-run
    description="mdock host bridge"
    supervisor=supervise-daemon
    command=/usr/local/sbin/mdock-agent
    respawn_delay=1
    depend() {
      need docker
    }
    """#

    /// `host-gateway` (as in `--add-host host.docker.internal:host-gateway`) resolves to the same
    /// address as host.docker.internal.
    static func daemonJSON(config: Config) -> String {
        let gateway = config.gpu ? "192.168.127.254" : guestd != nil ? hostLoopbackIP : nil
        let lines = [
            #"  "features": { "buildkit": true },"#,
            #"  "builder": { "gc": { "enabled": true, "defaultKeepStorage": "30GB" } },"#,
            #"  "runtimes": { "mdock": { "runtimeType": "io.containerd.runc.v2", "options": { "BinaryName": "/usr/local/sbin/mdock-runc" } } },"#,
            #"  "default-runtime": "mdock","#,
        ] + (gateway.map { [#"  "host-gateway-ip": "\#($0)","#] } ?? []) + [
            #"  "log-driver": "json-file","#,
            #"  "log-opts": { "max-size": "10m", "max-file": "3" }"#,
        ]
        return "{\n" + lines.joined(separator: "\n") + "\n}\n"
    }

    static let sysctl = #"""
    fs.inotify.max_user_watches = 1048576
    fs.inotify.max_user_instances = 8192
    vm.max_map_count = 262144
    net.core.somaxconn = 4096
    net.ipv4.ip_forward = 1
    # No IPv6 duplicate-address detection: the guest is alone on its NAT link, and Alpine's ifup
    # waits for it to finish (if-up.d/dad), which held up every boot by ~1.7 s.
    net.ipv6.conf.all.accept_dad = 0
    net.ipv6.conf.default.accept_dad = 0
    net.ipv6.conf.eth0.accept_dad = 0
    # No background compaction: Virtualization.framework keeps every page the guest touches charged
    # to the Mac, so moving pages around for nothing only grows the VM's footprint.
    vm.compaction_proactiveness = 0
    """#

    /// (seed file name, install path, mode, content)
    static func files(config: Config) -> [(String, String, String, String)] {
        let shares = config.shares.map { "\($0.tag) \($0.guest)" }.joined(separator: "\n") + "\n"
        return [
            ("shares", "/etc/mdock/shares", "0644", shares),
            ("mdock-guest", "/usr/local/sbin/mdock-guest", "0755", prepareScript),
            ("mdock-agent", "/usr/local/sbin/mdock-agent", "0755", agentScript),
            ("mdock-relay", "/usr/local/sbin/mdock-relay", "0755", relayScript),
            ("mdock-cdi", "/usr/local/sbin/mdock-cdi", "0755", cdiScript),
            ("mdock-runc", "/usr/local/sbin/mdock-runc", "0755", runcWrapper),
            ("accel-dir", "/etc/mdock/accel-dir", "0644", Accel.dir.path + "\n"),
            ("shares-host", "/etc/mdock/shares-host", "0644",
             config.shares.map { "\($0.tag)=\($0.host)" }.joined(separator: ",") + "\n"),
            ("init-mdock-guest", "/etc/init.d/mdock-guest", "0755", prepareService),
            ("init-mdock-agent", "/etc/init.d/mdock-agent", "0755", agentService),
            ("daemon.json", "/etc/docker/daemon.json", "0644", daemonJSON(config: config)),
            ("sysctl.conf", "/etc/sysctl.d/90-mdock.conf", "0644", sysctl),
            ("packages", "/etc/mdock/packages", "0644", packages.joined(separator: " ") + "\n"),
            ("rosetta-aot", "/etc/mdock/rosetta-aot", "0644", config.aot ? "on\n" : "off\n"),
        ]
    }

    static let userData = """
    #cloud-config
    hostname: mdock
    disable_root: true
    ssh_pwauth: false
    growpart:
      mode: auto
      devices: ['/']
    resize_rootfs: true
    package_update: true
    packages: [\(packages.joined(separator: ", "))]
    runcmd:
      - - sh
        - -c
        - |
          mkdir -p /run/mdock-seed && mount -t iso9660 -o ro /dev/vdc /run/mdock-seed
          sh /run/mdock-seed/mdock/provision.sh
          umount /run/mdock-seed
          # Start outside cloud-init: calling rc-service from inside its OpenRC job deadlocks.
          setsid sh -c 'sleep 1; rc-service mdock-agent start' >/var/log/mdock-firstboot.log 2>&1 &
    """

    /// Builds the "cidata" ISO: cloud-init user-data/meta-data plus mdock/ with the guest files.
    /// Skipped when the guest files are unchanged since the last build.
    static func writeSeed(config: Config, to iso: URL) throws {
        let files = files(config: config)
        // The guest reads the ISO's plain ISO 9660 names, which it lowercases (FEXInterpreter would
        // arrive as fexinterpreter), so seed names are lowercase.
        let binaries = try Guest.binaries.compactMap { name, dest in
            try binary(name).map { (name.lowercased(), dest, "0755", try Data(contentsOf: $0)) }
        }
        var hasher = SHA256()
        hasher.update(data: Data(userData.utf8))
        hasher.update(data: Data(provisionScript.utf8))
        for (name, dest, mode, content) in files { hasher.update(data: Data("\(name)\(dest)\(mode)\(content)".utf8)) }
        for (name, dest, mode, content) in binaries {
            hasher.update(data: Data("\(name)\(dest)\(mode)".utf8))
            hasher.update(data: content)
        }
        let digest = hasher.finalize().prefix(6).map { String(format: "%02x", $0) }.joined()
        let instanceID = "mdock-\(digest)"
        let stamp = Paths.url("seed.id")
        if FileManager.default.fileExists(atPath: iso.path),
           (try? String(contentsOf: stamp, encoding: .utf8)) == instanceID { return }

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(instanceID)
        try? FileManager.default.removeItem(at: dir)
        let mdock = dir.appendingPathComponent("mdock")
        try FileManager.default.createDirectory(at: mdock, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        func write(_ content: String, _ url: URL) throws { try content.write(to: url, atomically: true, encoding: .utf8) }
        try write(userData, dir.appendingPathComponent("user-data"))
        try write("instance-id: \(instanceID)\nlocal-hostname: mdock\n", dir.appendingPathComponent("meta-data"))
        try write(provisionScript, mdock.appendingPathComponent("provision.sh"))
        try write(instanceID + "\n", mdock.appendingPathComponent("instance-id"))
        let manifest = files.map { "\($0.0) \($0.1) \($0.2)" } + binaries.map { "\($0.0) \($0.1) \($0.2)" }
        try write(manifest.joined(separator: "\n") + "\n", mdock.appendingPathComponent("manifest"))
        for (name, _, _, content) in files { try write(content, mdock.appendingPathComponent(name)) }
        for (name, _, _, content) in binaries { try content.write(to: mdock.appendingPathComponent(name)) }

        try? FileManager.default.removeItem(at: iso)
        try run("/usr/bin/hdiutil", ["makehybrid", "-quiet", "-iso", "-joliet",
                                     "-default-volume-name", "cidata", "-o", iso.path, dir.path])
        try instanceID.write(to: stamp, atomically: true, encoding: .utf8)
    }
}
