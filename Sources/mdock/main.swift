import Foundation
import Virtualization

let usage = """
mdock — Docker on Apple Virtualization.framework, tuned for Apple silicon.

Usage (also as `docker mdock …`):
  mdock start [--gpu|--no-gpu]
                         Create (first run) and boot the VM, then wire up the docker context.
                         --gpu boots on libkrun with a Venus GPU (Vulkan in containers via
                         --device mdock.dev/gpu=all); the choice is remembered
  mdock stop | restart   Shut the VM down gracefully | stop, then start. Under autostart an idle VM
                         (nothing running for `idle` minutes) stops by itself and the next docker
                         command starts it again
  mdock status [--json]  VM state, engine, memory, ports, accelerators, Kubernetes, endpoints
  mdock doctor [--json]  Check everything mdock needs, with fixes; exit status 1 on failure
  mdock version [--json] Versions of mdock, Docker, kubectl and k3s
  mdock autostart on|off Start mdock at login and restart it if it crashes (launchd agent)
  mdock upgrade          Update the guest (Alpine packages, Docker engine, kernel), then restart
  mdock kubernetes enable|disable|reset|status [--json]
                         Single-node Kubernetes (k3s on Docker) at https://127.0.0.1:6443,
                         kubectl context "mdock"; `mdock k8s` for short
  mdock kernel install [DIR] | remove | status
                         mdock's guest kernel (kernel/build.sh): hardware TSO for Rosetta and FEX
  mdock mcp              Model Context Protocol server on stdio, for AI agents
  mdock workspace create [name] [--size=500g] | mount | eject | status
                         Case-sensitive APFS volume for code at /Volumes/<name> (~/<name>)
  mdock casecheck [dir]  Find names that differ only in case (they collide on the Mac's disk)
  mdock arch-check [run options] IMAGE [-- COMMAND...]
                         Run an image on arm64 and amd64 side by side; compare packages and results
  mdock sync add [DIR] [--ignore=PATTERN].. | remove [DIR] | list
                         Keep DIR in two-way sync with the VM's disk: native speed for its bind mounts
  mdock port IMAGE [--tag=NAME] [--replace]
                         Rebuild an amd64-only image as native arm64 by replaying its build
  mdock gpu-check        Verify Vulkan inside a container (GPU engine)
  mdock set KEY=VALUE..  Change cpus, memory (GiB), disk (GiB), gpu, rosetta, aot (Rosetta's
                         ahead-of-time cache; off: it breaks some programs), ports, balloon, sync,
                         idle (minutes with nothing running before the VM stops; 0 = never)
  mdock shell            Root shell in the VM
  mdock logs [console]   Follow the daemon log (or the guest console)
  mdock delete           Stop and remove the VM and all its images and volumes
  mdock <docker command> Anything else runs as `docker --context mdock …` (mdock ps, mdock run …)
"""

func control(_ command: String) -> String? {
    guard let fd = Sockets.unixConnect(Paths.controlSocket.path) else { return nil }
    defer { close(fd) }
    Sockets.writeAll(fd, command + "\n")
    return Sockets.readLine(fd, limit: 1 << 20)
}

func status() -> [String: Any]? {
    guard let line = control("status"), let data = line.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

/// Display name of an x86 translator as the status reports it (rosetta, fex, qemu).
func translatorName(_ id: String) -> String {
    ["rosetta": "Rosetta", "fex": "FEX", "qemu": "QEMU"][id] ?? id
}

func ensureInitialized() throws -> Config {
    try FileManager.default.createDirectory(at: Paths.state, withIntermediateDirectories: true)
    if !FileManager.default.fileExists(atPath: Paths.config.path) {
        try saveConfig(.defaults())
    }
    let config = try loadConfig()

    if !FileManager.default.fileExists(atPath: Paths.bootDisk.path) {
        guard let qemuImg = which("qemu-img") else {
            throw CommandError(description: "qemu-img is needed once to unpack the Alpine image: brew install qemu")
        }
        let qcow = Paths.url("alpine.qcow2")
        if !FileManager.default.fileExists(atPath: qcow.path) {
            print("Downloading Alpine Linux arm64 cloud image…")
            try run("/usr/bin/curl", ["-fL#", "-o", qcow.path, imageURL])
            let expected = try run("/usr/bin/curl", ["-fsL", imageURL + ".sha512"])
                .trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").first.map(String.init) ?? ""
            let actual = try run("/usr/bin/shasum", ["-a", "512", qcow.path]).split(separator: " ").first.map(String.init)
            guard actual == expected else {
                try? FileManager.default.removeItem(at: qcow)
                throw CommandError(description: "image checksum mismatch")
            }
        }
        try run(qemuImg, ["convert", "-O", "raw", qcow.path, Paths.bootDisk.path])
        try run(qemuImg, ["resize", "-f", "raw", Paths.bootDisk.path, "8G"], quiet: true)
        try? FileManager.default.removeItem(at: qcow)
    }
    try extractKernel()
    try resizeSparse(Paths.dataDisk, gib: config.diskGiB)
    try Guest.writeSeed(config: config, to: Paths.seed)
    return config
}

/// Creates or grows a sparse raw disk; APFS only allocates blocks the guest writes.
func resizeSparse(_ url: URL, gib: Int) throws {
    if !FileManager.default.fileExists(atPath: url.path) {
        FileManager.default.createFile(atPath: url.path, contents: nil)
    }
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    let size = UInt64(gib) << 30
    if try handle.seekToEnd() < size { try handle.truncate(atOffset: size) }
}

func spawnDaemon() throws -> pid_t {
    let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
    let logFD = open(Paths.daemonLog.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
    let nullFD = open("/dev/null", O_RDONLY)
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    posix_spawn_file_actions_adddup2(&actions, nullFD, 0)
    posix_spawn_file_actions_adddup2(&actions, logFD, 1)
    posix_spawn_file_actions_adddup2(&actions, logFD, 2)
    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
    var pid: pid_t = 0
    let args = [exe, "daemon"]
    let cArgs: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
    defer { cArgs.forEach { free($0) } }
    let rc = posix_spawn(&pid, exe, &actions, &attr, cArgs, environ)
    posix_spawn_file_actions_destroy(&actions)
    posix_spawnattr_destroy(&attr)
    close(logFD)
    close(nullFD)
    guard rc == 0 else { throw CommandError(description: "failed to start daemon: \(String(cString: strerror(rc)))") }
    return pid
}

func ensureDockerContext() {
    guard let docker = which("docker") else { return }
    if (try? run(docker, ["context", "inspect", "mdock"], quiet: true)) == nil {
        _ = try? run(docker, ["context", "create", "mdock", "--description", "mdock (Virtualization.framework)",
                              "--docker", "host=unix://\(Paths.dockerSocket.path)"])
        print("Created docker context \"mdock\". Switch with: docker context use mdock")
    }
}

func start() throws {
    if let s = status(), s["ready"] as? Bool == true {
        print("mdock is already running (\(s["ip"] ?? ""))")
        return
    }
    let config = try ensureInitialized()
    var daemonPID: pid_t?
    if status() == nil {
        if LaunchAgent.installed {
            try LaunchAgent.start()
        } else {
            daemonPID = try spawnDaemon()
        }
        print("Booting VM (\(config.gpu ? "libkrun + Venus GPU" : "Virtualization.framework")): \(config.cpus) vCPUs, \(config.memoryGiB) GiB RAM, \(config.diskGiB) GiB disk")
    }
    let firstBoot = !FileManager.default.fileExists(atPath: Paths.url(".provisioned").path)
    if firstBoot { print("First boot installs Docker in the guest; this takes a minute or two.") }
    let deadline = Date().addingTimeInterval(firstBoot ? 900 : 180)
    while Date() < deadline {
        if let s = status(), s["ready"] as? Bool == true {
            FileManager.default.createFile(atPath: Paths.url(".provisioned").path, contents: nil)
            ensureDockerContext()
            print(String(format: "mdock is ready in %.1fs (guest %@)", s["bootSeconds"] as? Double ?? 0, s["ip"] as? String ?? ""))
            return
        }
        if let pid = daemonPID, waitpid(pid, nil, WNOHANG) == pid {
            let tail = (try? String(contentsOf: Paths.daemonLog, encoding: .utf8))?.split(separator: "\n").suffix(5).joined(separator: "\n") ?? ""
            throw CommandError(description: "daemon exited during boot:\n\(tail)")
        }
        usleep(50_000)
    }
    throw CommandError(description: "timed out waiting for the guest; see `mdock logs console`")
}

func stopVM() {
    let running = status() != nil
    // Unload the launchd job first: that closes its docker.sock, so no client can start mdock again
    // while it shuts down, and a supervised daemon gets SIGTERM (a clean stop).
    LaunchAgent.unload()
    if running {
        _ = control("stop")
        while status() != nil { usleep(200_000) }
    }
    print(running ? "mdock stopped" : "mdock is not running")
}

func printStatus() {
    guard let s = status() else {
        print(LaunchAgent.idleStopped ? "mdock is stopped after being idle: the next docker command starts it again (about 3 s), or mdock start"
                                      : "mdock is not running")
        return
    }
    let ready = s["ready"] as? Bool == true
    print("state:     \(ready ? "running" : "booting") (pid \(s["pid"] ?? ""))")
    if s["bridgeStalled"] as? Bool == true {
        print("WARNING:   guest bridge unresponsive (vsock stalled); restart with: mdock stop && mdock start")
    }
    print("guest ip:  \(s["ip"] ?? "")")
    print("engine:    \(s["engine"] ?? "")")
    print("cpus:      \(s["cpus"] ?? "")")
    print("memory:    \(s["balloonMiB"] ?? "") MiB assigned of \(s["memoryGiB"] ?? "") GiB max; guest available \(s["guestMemAvailableMiB"] ?? "") MiB")
    if let boot = s["bootSeconds"] as? Double, boot >= 0 { print(String(format: "boot time: %.1fs", boot)) }
    if let accel = s["accel"] as? [[String: Any]] {
        let parts = accel.map { a -> String in
            let state = a["running"] as? Bool == true ? "running" : a["built"] as? Bool == true ? "ready" : "not built"
            return "\(a["name"] ?? "")=\(state)"
        }
        print("accel:     \(parts.joined(separator: ", "))")
    }
    let forwards = s["forwards"] as? [String] ?? []
    print("ports:     \(forwards.isEmpty ? "none" : forwards.joined(separator: ", "))")
    if let k8s = s["kubernetes"] as? [String: Any], let state = k8s["state"] as? String, state != "off" {
        let version = (k8s["version"] as? String).flatMap { $0.isEmpty ? nil : " \($0)" } ?? ""
        print("k8s:       \(state)\(version)\(state == "up" ? ", API \(Kubernetes.api) (context \(Kubernetes.context))" : "")")
    }
    print("autostart: \(autostartDescription(supervised: s["supervised"] as? Bool == true))")
    if let kernel = s["kernel"] as? String, !kernel.isEmpty {
        let tso = s["tso"] as? Bool == true ? ", hardware TSO for x86 translators" : ""
        print("kernel:    \(kernel)\(tso)")
    }
    if let x86 = s["x86"] as? [String: String], !x86.isEmpty {
        let aot = s["rosettaAOT"] as? Bool == true ? " (AOT cache)" : ""
        print("x86:       \(["amd64", "386"].compactMap { arch in x86[arch].map { "linux/\(arch) via \(translatorName($0))\($0 == "rosetta" ? aot : "")" } }.joined(separator: ", "))")
    }
    if let idle = s["idleStop"] as? [String: Any] {
        let minutes = idle["minutes"] as? Int ?? 0
        if idle["enabled"] as? Bool == true {
            let busy = idle["containers"] as? Int ?? 0
            print("idle stop: after \(minutes) min with no containers or docker clients\(busy > 0 ? " (\(busy) running now)" : "")")
        } else {
            print("idle stop: off\(minutes > 0 ? " (needs autostart: mdock autostart on && mdock restart)" : "")")
        }
    }
}

func autostartDescription(supervised: Bool) -> String {
    switch (LaunchAgent.installed, supervised) {
    case (true, true): "on (supervised by launchd)"
    case (true, false): "on (this run isn't supervised yet: mdock restart)"
    case (false, true): "off (launchd lets go when mdock stops)"
    case (false, false): "off"
    }
}

func autostart(_ mode: String?) throws {
    switch mode {
    case "on":
        try ensureInitializedConfigOnly()
        try LaunchAgent.install()
        print("mdock will start at login and restart if it crashes (\(LaunchAgent.plist.path)).")
        if let s = status(), s["supervised"] as? Bool != true {
            print("The running VM isn't supervised yet; `mdock restart` hands it to launchd.")
        }
    case "off":
        LaunchAgent.remove()
        print("mdock will no longer start at login.")
    case nil, "status":
        print(autostartDescription(supervised: status()?["supervised"] as? Bool == true))
    default:
        throw CommandError(description: "usage: mdock autostart on|off")
    }
}

func set(_ assignments: [String]) throws {
    _ = try ensureInitializedConfigOnly()
    var config = try loadConfig()
    for assignment in assignments {
        let parts = assignment.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { throw CommandError(description: "expected KEY=VALUE, got \(assignment)") }
        let (key, value) = (parts[0], parts[1])
        func int() throws -> Int {
            guard let n = Int(value), n > 0 else { throw CommandError(description: "\(key) needs a positive number") }
            return n
        }
        func bool() -> Bool { ["1", "true", "on", "yes"].contains(value.lowercased()) }
        switch key {
        case "cpus": config.cpus = try int()
        case "memory": config.memoryGiB = try int()
        case "disk":
            let n = try int()
            guard n >= config.diskGiB else { throw CommandError(description: "disk can only grow") }
            config.diskGiB = n
        case "gpu": config.gpu = bool()
        case "rosetta": config.rosetta = bool()
        case "aot": config.aot = bool()
        case "ports": config.forwardPorts = bool()
        case "balloon": config.autoBalloon = bool()
        case "idle":
            guard let n = Int(value), n >= 0 else { throw CommandError(description: "idle is minutes (0 turns idle stop off)") }
            config.idleMinutes = n
        case "sync":
            guard ["fsync", "full", "none"].contains(value) else { throw CommandError(description: "sync is fsync, full or none") }
            config.diskSync = value
        default: throw CommandError(description: "unknown setting \(key)")
        }
    }
    try saveConfig(config)
    if assignments.allSatisfy({ $0.hasPrefix("idle=") }) {
        print("Saved; the running daemon picks it up within seconds.")
    } else {
        print("Saved. Restart to apply: mdock stop && mdock start")
    }
}

func ensureInitializedConfigOnly() throws {
    try FileManager.default.createDirectory(at: Paths.state, withIntermediateDirectories: true)
    if !FileManager.default.fileExists(atPath: Paths.config.path) { try saveConfig(.defaults()) }
}

/// Builds a small probe image on first use and prints what containers get on the GPU: Vulkan (the
/// image's own Mesa, Venus), OpenGL through Zink, and OpenCL when the mdock/gpu image is built.
func gpuCheck() throws {
    guard let docker = which("docker") else { throw CommandError(description: "docker CLI not found") }
    guard let s = status(), s["ready"] as? Bool == true else { throw CommandError(description: "mdock is not running") }
    guard (s["engine"] as? String ?? "").contains("GPU") else {
        throw CommandError(description: "the GPU is only available on the GPU engine: mdock stop && mdock start --gpu")
    }
    let image = "mdock/gpu-check:2"
    if (try? run(docker, ["--context", "mdock", "image", "inspect", image], quiet: true)) == nil {
        print("Building \(image) (one time)…")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mdock-gpu-check")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "FROM fedora:42\nRUN dnf install -y -q mesa-vulkan-drivers vulkan-tools mesa-dri-drivers egl-utils && dnf clean all\n"
            .write(to: dir.appendingPathComponent("Dockerfile"), atomically: true, encoding: .utf8)
        try run(docker, ["--context", "mdock", "build", "-q", "-t", image, dir.path])
    }
    func probe(_ env: [String], _ image: String, _ command: [String]) -> String {
        (try? run(docker, ["--context", "mdock", "run", "--rm", "--device", "mdock.dev/gpu=all"] + env.flatMap { ["-e", $0] }
                  + [image] + command, quiet: true)) ?? ""
    }
    let out = probe([], image, ["vulkaninfo", "--summary"])
    let fields = ["deviceName", "driverName", "apiVersion", "driverInfo", "deviceType"]
    // vulkaninfo --summary lists devices as "GPU0:", "GPU1:", ... blocks; pick the Venus one.
    var blocks: [[Substring]] = []
    for line in out.split(separator: "\n") {
        if line.range(of: #"^GPU\d+:"#, options: .regularExpression) != nil { blocks.append([]) } else if !blocks.isEmpty { blocks[blocks.count - 1].append(line) }
    }
    let venus = blocks.first { $0.contains { $0.contains("venus") } } ?? []
    let lines = venus.filter { line in fields.contains { line.contains($0 + " ") } }
    guard !lines.isEmpty else { throw CommandError(description: "no Venus GPU visible:\n\(out)") }
    print("Vulkan:")
    print(lines.map { "  " + $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n"))

    let gl = probe(["GALLIUM_DRIVER=zink"], image, ["eglinfo", "-B", "-p", "surfaceless"])
    let glLines = gl.split(separator: "\n").filter { $0.contains("profile renderer") || $0.contains("profile version") }
        .filter { !$0.contains("shading") }.prefix(4)
    print("OpenGL (-e GALLIUM_DRIVER=zink):")
    print(glLines.isEmpty ? "  not available" : glLines.map { "  " + $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n"))

    print("OpenCL (mdock/gpu image):")
    if (try? run(docker, ["--context", "mdock", "image", "inspect", "mdock/gpu"], quiet: true)) == nil {
        print("  not built: ~/mdock/gpu/guest/build.sh")
    } else {
        let cl = probe([], "mdock/gpu", ["clinfo", "-l"])
        let devices = cl.split(separator: "\n").filter { $0.contains("Device #") }
        print(devices.isEmpty ? "  no device:\n\(cl)" : devices.map { "  " + $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n"))
    }
}

/// Runs a shell script as root in the guest's own namespaces (the `mdock shell` mechanism). It first
/// leaves the helper container's cgroup, so services it starts outlive the container. `quiet` drops
/// stderr (for output that must stay clean, like a kubeconfig).
func guestScript(_ script: String, _ args: [String] = [], quiet: Bool = false) throws -> String {
    guard let docker = which("docker") else { throw CommandError(description: "docker CLI not found") }
    return try run(docker, ["--context", "mdock", "run", "--rm", "--privileged", "--pid=host", "--net=host", "--cgroupns=host",
                            "alpine:3.22", "nsenter", "-t", "1", "-m", "-u", "-n", "-i", "-p", "sh", "-c",
                            "echo $$ > /sys/fs/cgroup/cgroup.procs\n" + script, "sh"] + args, quiet: quiet)
}

/// apk upgrade in the guest. A new kernel is copied out to kernelStaging (the guest sees ~/.mdock at
/// the same path), so the restart boots it without reading the boot disk.
func upgrade() throws {
    guard status()?["ready"] as? Bool == true else { throw CommandError(description: "mdock is not running") }
    try? FileManager.default.removeItem(at: Paths.kernelStaging)
    print("Updating the guest…")
    let out = try guestScript(#"""
        set -e
        apk update -q
        apk upgrade --no-progress | grep -E '^\([0-9]+/[0-9]+\) (Upgrading|Installing|Replacing)' || true
        running=$(uname -r)
        if [ ! -d "/lib/modules/$running" ]; then
          mkdir -p "$1"
          cp /boot/vmlinuz-virt /boot/initramfs-virt "$1/"
          stat -c %Y /boot/vmlinuz-virt /boot/initramfs-virt | tr '\n' '-' > "$1/stamp"
          echo "kernel $running -> $(ls /lib/modules | grep -vx "$running" | head -1)"
        fi
        """#, [Paths.kernelStaging.path])
    let changes = out.split(separator: "\n").filter { !$0.isEmpty }
    guard !changes.isEmpty else {
        print("Already up to date.")
        return
    }
    changes.forEach { print("  \($0)") }
    print("Restarting to apply…")
    stopVM()
    try start()
}

/// `status --json` with what clients need to use mdock, beyond the daemon's own state.
func statusJSON() -> String {
    var s: [String: Any] = status() ?? ["running": false, "idleStopped": LaunchAgent.idleStopped]
    if s["running"] == nil { s["running"] = true }
    s["version"] = mdockVersion
    s["autostart"] = LaunchAgent.installed
    var endpoints: [String: Any] = ["dockerContext": "mdock", "dockerSocket": Paths.dockerSocket.path,
                                    "defaultSocket": "/var/run/docker.sock",
                                    "hostFromContainers": "host.docker.internal (the Mac's localhost)",
                                    "ml": "http://ml.mdock.internal:8100", "llm": "http://llm.mdock.internal:8200",
                                    "llmRPC": "llm.mdock.internal:50052"]
    if let k8s = s["kubernetes"] as? [String: Any], k8s["state"] as? String != "off" {
        endpoints["kubernetesAPI"] = Kubernetes.api
        endpoints["kubeContext"] = Kubernetes.context
    }
    s["endpoints"] = endpoints
    let data = (try? JSONSerialization.data(withJSONObject: s, options: [.sortedKeys])) ?? Data("{}".utf8)
    return String(decoding: data, as: UTF8.self)
}

func version(json: Bool) {
    func tool(_ name: String, _ args: [String]) -> String? {
        guard let path = which(name), let out = try? run(path, args, quiet: true) else { return nil }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let k8s = status()?["kubernetes"] as? [String: Any]
    var v: [String: String] = ["mdock": mdockVersion]
    v["docker"] = tool("docker", ["version", "--format", "{{.Client.Version}}"])
    v["engine"] = tool("docker", ["--context", "mdock", "version", "--format", "{{.Server.Version}}"])
    v["compose"] = tool("docker", ["compose", "version", "--short"])
    v["buildx"] = tool("docker", ["buildx", "version"])?.split(separator: " ").dropFirst().first.map(String.init)
    v["kubectl"] = tool("kubectl", ["version", "--client", "-o", "json"]).flatMap {
        ((try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any])
            .flatMap { ($0["clientVersion"] as? [String: Any])?["gitVersion"] as? String }
    }
    if let k3s = k8s?["version"] as? String, !k3s.isEmpty { v["k3s"] = k3s }
    if json {
        print(String(decoding: (try? JSONSerialization.data(withJSONObject: v, options: [.sortedKeys])) ?? Data(), as: UTF8.self))
    } else {
        for key in ["mdock", "docker", "engine", "compose", "buildx", "kubectl", "k3s"] {
            if let value = v[key] { print("\(key.padding(toLength: 8, withPad: " ", startingAt: 0)) \(value)") }
        }
    }
}

/// start/stop/restart mean the VM. Given a container, say what to run instead of guessing.
func vmOnly(_ args: [String], allowed: Set<String> = []) throws {
    let extra = args.dropFirst().filter { !allowed.contains($0) }
    guard extra.isEmpty else {
        throw CommandError(description: "`mdock \(args[0])` acts on the VM and takes no arguments; for containers: docker \(args.joined(separator: " "))")
    }
}

func execDocker(_ args: [String]) -> Never {
    guard let docker = which("docker") else {
        fputs("docker CLI not found\n", stderr)
        exit(1)
    }
    let argv: [UnsafeMutablePointer<CChar>?] = ([docker, "--context", "mdock"] + args).map { strdup($0) } + [nil]
    execv(docker, argv)
    perror("execv")
    exit(1)
}

func follow(_ url: URL) -> Never {
    let words = ["/usr/bin/tail", "-n", "100", "-f", url.path]
    let argv: [UnsafeMutablePointer<CChar>?] = words.map { strdup($0) } + [nil]
    execv("/usr/bin/tail", argv)
    exit(1)
}

do {
    let args = DockerPlugin.arguments(CommandLine.arguments)
    switch args.first {
    case "docker-cli-plugin-metadata":
        print(DockerPlugin.metadata)
    case nil, "help", "-h", "--help":
        print(usage)
    case "start":
        try vmOnly(args, allowed: ["--gpu", "--no-gpu"])
        if args.contains("--gpu") || args.contains("--no-gpu") {
            try ensureInitializedConfigOnly()
            var config = try loadConfig()
            let want = args.contains("--gpu")
            if config.gpu != want, status() != nil {
                throw CommandError(description: "mdock is running on the \(config.gpu ? "GPU" : "VZ") engine; run `mdock stop` first")
            }
            config.gpu = want
            if want, Krun.prefix == nil { throw CommandError(description: "GPU stack not built; run gpu/build.sh") }
            try saveConfig(config)
        }
        try start()
    case "stop":
        try vmOnly(args)
        stopVM()
    case "restart":
        try vmOnly(args)
        stopVM()
        try start()
    case "autostart": try autostart(args.dropFirst().first)
    case "upgrade": try upgrade()
    case "status":
        if args.contains("--json") {
            print(statusJSON())
        } else {
            printStatus()
        }
    case "gpu-check": try gpuCheck()
    case "set": try set(Array(args.dropFirst()))
    case "shell":
        execDocker(["run", "--rm", "-it", "--privileged", "--pid=host", "--net=host", "alpine",
                    "nsenter", "-t", "1", "-m", "-u", "-n", "-i", "-p", "sh", "-l"])
    case "logs" where args.count == 1 || ["console", "daemon"].contains(args[1]):
        follow(args.count > 1 && args[1] == "console" ? Paths.console : Paths.daemonLog)
    case "kubernetes", "k8s": try Kubernetes.command(Array(args.dropFirst()))
    case "kernel": try Kernel.command(Array(args.dropFirst()))
    case "doctor": Doctor.report(json: args.contains("--json"))
    case "version", "--version": version(json: args.contains("--json"))
    case "mcp": MCPServer.run()
    case "workspace": try Workspace.command(Array(args.dropFirst()))
    case "arch-check": try ArchCheck.command(Array(args.dropFirst()))
    case "port": try Port.command(Array(args.dropFirst()))
    case "sync": try Sync.command(Array(args.dropFirst()))
    case "casecheck": try CaseCheck.report(args.count > 1 ? args[1] : FileManager.default.currentDirectoryPath)
    case "delete":
        stopVM()
        LaunchAgent.remove()
        try FileManager.default.removeItem(at: Paths.state)
        if let docker = which("docker") { _ = try? run(docker, ["context", "rm", "-f", "mdock"], quiet: true) }
        print("Removed \(Paths.state.path)")
    case "krun-vmm":
        Krun.runVMM(config: try loadConfig())
    case "daemon":
        guard FileManager.default.fileExists(atPath: Paths.config.path) else {
            log("no mdock VM here (\(Paths.state.path)); run `mdock start` first")
            exit(0)
        }
        let daemon = Daemon(config: try loadConfig())
        try daemon.run()
    default:
        // Everything else is a docker command against mdock: mdock ps, mdock run …, mdock logs web.
        execDocker(args)
    }
} catch {
    fputs("mdock: \(error)\n", stderr)
    exit(1)
}
