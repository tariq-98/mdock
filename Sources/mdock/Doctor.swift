import Foundation

/// `mdock doctor [--json]`: checks everything mdock depends on and says how to fix what's wrong.
/// Exit status 1 when a check fails (warnings don't count), so scripts and agents can gate on it.
enum Doctor {
    struct Check {
        var name: String
        var status: String  // ok, warn, fail
        var detail: String
        var fix: String?
        var json: [String: Any] {
            var o: [String: Any] = ["name": name, "status": status, "detail": detail]
            if let fix { o["fix"] = fix }
            return o
        }
    }

    static func report(json: Bool) -> Never {
        let checks = collect()
        let failed = checks.contains { $0.status == "fail" }
        if json {
            let report: [String: Any] = ["ok": !failed, "version": mdockVersion, "checks": checks.map(\.json)]
            print(String(decoding: (try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])) ?? Data(), as: UTF8.self))
        } else {
            for c in checks {
                let mark = c.status == "ok" ? "ok  " : c.status == "warn" ? "warn" : "FAIL"
                print("\(mark)  \(c.name): \(c.detail)\(c.fix.map { "\n      fix: \($0)" } ?? "")")
            }
        }
        exit(failed ? 1 : 0)
    }

    static func collect() -> [Check] {
        var checks: [Check] = []
        func add(_ name: String, _ ok: Bool, _ detail: String, fix: String? = nil, warnOnly: Bool = false) {
            checks.append(Check(name: name, status: ok ? "ok" : warnOnly ? "warn" : "fail", detail: detail, fix: ok ? nil : fix))
        }
        let exe = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0]).resolvingSymlinksInPath().path
        let entitlements = (try? run("/usr/bin/codesign", ["-d", "--entitlements", "-", exe])) ?? ""
        add("signature", entitlements.contains("com.apple.security.virtualization"), exe,
            fix: "rebuild with ~/mdock/build.sh (a plain `swift build` drops the virtualization entitlement)")

        let s = status()
        // Stopped for being idle counts as fine: launchd starts it on the next docker command.
        let idle = s == nil && LaunchAgent.idleStopped
        add("vm", s?["ready"] as? Bool == true || idle,
            idle ? "stopped while idle; the next docker command starts it" : s == nil ? "not running"
                : s?["ready"] as? Bool == true ? "running (\(s?["engine"] ?? ""), pid \(s?["pid"] ?? ""))" : "booting",
            fix: "mdock start")
        if let s {
            add("bridge", s["bridgeStalled"] as? Bool != true, s["bridgeStalled"] as? Bool == true ? "vsock bridge stalled" : "responding",
                fix: "mdock restart")
        }
        add("autostart", LaunchAgent.installed, LaunchAgent.installed ? (s?["supervised"] as? Bool == true ? "on, supervised" : "on") : "off",
            fix: "mdock autostart on", warnOnly: true)

        let docker = which("docker")
        let mine = docker?.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path + "/.local/bin/") == true
        add("docker cli", docker != nil && mine, docker ?? "not found", fix: "~/mdock/cli/build.sh", warnOnly: docker != nil)
        if let docker {
            // Asking an idle-stopped engine would start the VM; leave it asleep.
            if !idle {
                let ping = try? run(docker, ["--context", "mdock", "version", "--format", "{{.Server.Version}}"], quiet: true)
                add("docker engine", ping != nil, ping.map { "Docker \($0.trimmingCharacters(in: .whitespacesAndNewlines))" } ?? "unreachable",
                    fix: "mdock start, then mdock doctor")
            }
            let context = (try? run(docker, ["context", "show"], quiet: true))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            add("docker context", context == "mdock", "current: \(context)", fix: "docker context use mdock (or ~/mdock/cli/configure.sh)",
                warnOnly: true)
            // Client side only: a host nothing listens on keeps `docker info` from touching the VM.
            let plugins = (try? run(docker, ["-H", "unix:///var/empty/none.sock", "info", "--format",
                                             "{{range .ClientInfo.Plugins}}{{.Name}} {{end}}"], quiet: true)) ?? ""
            for plugin in ["buildx", "compose", "mdock"] {
                add("plugin \(plugin)", plugins.split(separator: " ").contains(Substring(plugin)), plugin,
                    fix: plugin == "mdock" ? "~/mdock/build.sh" : "~/mdock/cli/build.sh", warnOnly: true)
            }
        }
        let linked = (try? FileManager.default.destinationOfSymbolicLink(atPath: Paths.desktopSocket.path)) == Paths.dockerSocket.path
        add("default socket", linked, linked ? "/var/run/docker.sock -> ~/.docker/run/docker.sock -> mdock" : "not pointing at mdock",
            fix: "mdock restart (Docker Desktop must not be running)", warnOnly: true)
        add("rosetta", FileManager.default.fileExists(atPath: "/Library/Apple/usr/libexec/oah/libRosettaRuntime"),
            "linux/amd64 on the default engine", fix: "softwareupdate --install-rosetta --agree-to-license", warnOnly: true)
        add("guest helper", Guest.guestd != nil, Guest.guestd?.path ?? "mdock-guestd not built",
            fix: "~/mdock/guest/build.sh, then mdock restart", warnOnly: true)
        if let s, let tso = s["tso"] as? Bool {
            add("x86 memory order", tso, tso ? "hardware TSO (\(s["kernel"] ?? ""))" : "emulated by the translator (\(s["kernel"] ?? ""))",
                fix: Kernel.buildOutput != nil ? "mdock kernel install && mdock restart"
                    : "~/mdock/kernel/build.sh && mdock kernel install && mdock restart", warnOnly: true)
        }
        // What runs x86 programs: Rosetta (default engine, amd64), FEX (needs hardware TSO), else QEMU.
        let built = Guest.binary("FEXInterpreter") != nil && Guest.binary("qemu-x86_64") != nil && Guest.binary("qemu-i386") != nil
        if let x86 = s?["x86"] as? [String: String], !x86.isEmpty {
            let amd64 = x86["amd64"].map(translatorName), i386 = x86["386"].map(translatorName)
            add("x86 images", amd64 != nil && i386 != nil && built,
                "linux/amd64 via \(amd64 ?? "nothing"), linux/386 via \(i386 ?? "nothing")\(built ? "" : "; FEX or QEMU not built")",
                fix: "~/mdock/guest/build.sh, then mdock restart", warnOnly: true)
        } else {
            add("x86 images", built, built ? "FEX and QEMU user-mode built" : "FEX or QEMU user-mode not built",
                fix: "~/mdock/guest/build.sh, then mdock restart", warnOnly: true)
        }
        if let idle = s?["idleStop"] as? [String: Any] {
            let on = idle["enabled"] as? Bool == true
            add("idle stop", on || idle["minutes"] as? Int == 0,
                on ? "after \(idle["minutes"] ?? "") min with nothing running" : idle["minutes"] as? Int == 0 ? "off (idle=0)" : "inactive: needs autostart",
                fix: "mdock autostart on && mdock restart", warnOnly: true)
        }

        let ws = Workspace.status()
        if ws["configured"] as? Bool == true {
            add("workspace", ws["mounted"] as? Bool == true, "\(ws["mountpoint"] ?? "") (case-sensitive)", fix: "mdock workspace mount",
                warnOnly: true)
        }
        let k8s = Kubernetes.statusInfo()
        if k8s["enabled"] as? Bool == true {
            let up = k8s["state"] as? String == "up" && Kubernetes.apiReachable()
            add("kubernetes", up, "\(k8s["state"] ?? "") \(k8s["version"] ?? "")", fix: "mdock kubernetes enable")
            add("kubectl", which("kubectl")?.contains("/.local/bin/") == true, which("kubectl") ?? "not found",
                fix: "~/mdock/cli/build.sh", warnOnly: which("kubectl") != nil)
        }
        if let s, let accel = s["accel"] as? [[String: Any]] {
            let missing = accel.filter { $0["built"] as? Bool != true }.compactMap { $0["name"] as? String }
            add("accelerators", missing.isEmpty, missing.isEmpty ? "all built" : "not built: \(missing.joined(separator: ", "))",
                fix: "~/mdock/desktop/bundle.sh", warnOnly: true)
        }
        return checks
    }
}
