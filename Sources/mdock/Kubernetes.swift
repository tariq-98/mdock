import Foundation

/// Opt-in single-node Kubernetes, like Docker Desktop's: Alpine's k3s in the VM, running on Docker
/// (`--docker`, cri-dockerd), so images built with `docker build` run in pods without a registry.
/// The guest agent reports the cluster's state and LoadBalancer ports; the daemon forwards the API
/// to https://127.0.0.1:6443 and LoadBalancer services to localhost. kubectl uses the "mdock" context.
enum Kubernetes {
    static let context = "mdock"
    static let api = "https://127.0.0.1:6443"
    static let options = "--docker --disable traefik --node-name mdock --tls-san localhost"

    /// The kubeconfig kubectl reads: the first file in $KUBECONFIG, else ~/.kube/config.
    static var kubeconfig: URL {
        if let first = ProcessInfo.processInfo.environment["KUBECONFIG"]?.split(separator: ":").first {
            return URL(fileURLWithPath: String(first))
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".kube/config")
    }

    static func command(_ args: [String]) throws {
        let json = args.contains("--json")
        switch args.first(where: { !$0.hasPrefix("-") }) {
        case "enable", "on": try enable()
        case "disable", "off": try disable()
        case "reset": try reset()
        case nil, "status":
            let info = statusInfo()
            if json {
                print(String(decoding: try JSONSerialization.data(withJSONObject: info, options: [.sortedKeys]), as: UTF8.self))
            } else {
                print("kubernetes: \(info["state"] ?? "")\((info["version"] as? String).map { " (\($0))" } ?? "")")
                if info["state"] as? String == "up" {
                    print("api:        \(api)  (kubectl --context \(context))")
                    let ports = info["loadBalancerPorts"] as? [String] ?? []
                    print("services:   \(ports.isEmpty ? "no LoadBalancer services" : ports.map { "localhost:\($0)" }.joined(separator: ", "))")
                }
            }
        default:
            throw CommandError(description: "usage: mdock kubernetes enable|disable|reset|status [--json]")
        }
    }

    static func statusInfo() -> [String: Any] {
        let enabled = (try? loadConfig())?.k8s ?? false
        guard let s = status() else { return ["enabled": enabled, "state": "vm-stopped"] }
        let k8s = s["kubernetes"] as? [String: Any] ?? [:]
        var info: [String: Any] = ["enabled": enabled, "state": k8s["state"] as? String ?? "off", "api": api, "context": context,
                                   "kubeconfig": kubeconfig.path, "loadBalancerPorts": k8s["ports"] as? [String] ?? []]
        if let version = k8s["version"] as? String, !version.isEmpty { info["version"] = version }
        return info
    }

    static func enable() throws {
        guard status()?["ready"] as? Bool == true else { throw CommandError(description: "mdock is not running: mdock start") }
        guard which("kubectl") != nil else { throw CommandError(description: "kubectl not found: run cli/build.sh") }
        var config = try loadConfig()
        config.k8s = true
        try saveConfig(config)
        print("Starting Kubernetes (k3s on Docker)…")
        _ = try guestScript(#"""
            set -e
            apk info -e k3s >/dev/null || apk add -q k3s
            cat > /etc/conf.d/k3s <<EOF
            # Written by mdock (mdock kubernetes enable).
            export PATH="/usr/libexec/cni/:\$PATH"
            K3S_EXEC="server"
            K3S_OPTS="$1"
            rc_need="docker"
            EOF
            rc-update add k3s default >/dev/null 2>&1
            rc-service k3s status >/dev/null 2>&1 || rc-service k3s start >/dev/null
            export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
            i=0
            until kubectl get --raw=/readyz >/dev/null 2>&1; do
              i=$((i + 1)); [ $i -lt 180 ] || { echo "the API server did not come up; see /var/log/k3s.log" >&2; exit 1; }; sleep 1
            done
            until kubectl get node mdock -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q True; do
              i=$((i + 1)); [ $i -lt 240 ] || { echo "the node did not become Ready; see /var/log/k3s.log" >&2; exit 1; }; sleep 1
            done
            """#, [options])
        try mergeKubeconfig(try guestScript("cat /etc/rancher/k3s/k3s.yaml", quiet: true))
        // The daemon starts forwarding the API once the guest agent reports the cluster (every 10 s).
        for _ in 0..<30 where !apiReachable() { usleep(500_000) }
        print("Kubernetes is ready: kubectl get nodes (context \"\(context)\", API \(api))")
    }

    static func disable() throws {
        var config = try loadConfig()
        config.k8s = false
        try saveConfig(config)
        guard status()?["ready"] as? Bool == true else {
            print("Kubernetes will stay off.")
            return
        }
        print("Stopping Kubernetes…")
        _ = try guestScript(#"""
            rc-update del k3s default >/dev/null 2>&1
            rc-service k3s stop >/dev/null 2>&1
            # cri-dockerd's pod containers outlive k3s.
            ids=$(docker ps -aq --filter label=io.kubernetes.pod.name)
            [ -z "$ids" ] || docker rm -f $ids >/dev/null
            true
            """#)
        print("Kubernetes is off. Its state is kept; `mdock kubernetes reset` deletes it.")
    }

    /// Deletes the cluster (workloads, volumes, certificates) and starts a fresh one.
    static func reset() throws {
        try disable()
        print("Deleting the cluster…")
        _ = try guestScript(#"""
            grep -o ' /var/lib/kubelet[^ ]*' /proc/mounts | sort -r | xargs -r -n1 umount 2>/dev/null
            rm -rf /var/lib/rancher/k3s /etc/rancher/k3s /var/lib/kubelet
            true
            """#)
        try enable()
    }

    static func apiReachable() -> Bool {
        guard let fd = Sockets.tcpConnect(host: "127.0.0.1", port: 6443) else { return false }
        close(fd)
        return true
    }

    /// Adds the cluster to the user's kubeconfig as "mdock" (replacing an older mdock entry). The
    /// current context switches to mdock unless it was set to something other than Docker Desktop's.
    static func mergeKubeconfig(_ yaml: String) throws {
        guard let kubectl = which("kubectl") else { throw CommandError(description: "kubectl not found") }
        // k3s calls the cluster, user and context "default".
        var renamed = yaml
        for (pattern, replacement) in [(#"(?m)^(\s*(?:- )?name:) default$"#, "$1 mdock"), (#"(?m)^(\s*cluster:) default$"#, "$1 mdock"),
                                       (#"(?m)^(\s*user:) default$"#, "$1 mdock"), (#"(?m)^current-context: default$"#, "current-context: mdock")] {
            renamed = renamed.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        guard renamed.contains("server: https://127.0.0.1:6443"), renamed.contains("current-context: mdock") else {
            throw CommandError(description: "unexpected kubeconfig from k3s")
        }
        let target = kubeconfig
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let fresh = target.deletingLastPathComponent().appendingPathComponent(".mdock-kubeconfig-\(getpid())")
        FileManager.default.createFile(atPath: fresh.path, contents: Data(renamed.utf8), attributes: [.posixPermissions: 0o600])
        defer { try? FileManager.default.removeItem(at: fresh) }

        let exists = FileManager.default.fileExists(atPath: target.path)
        var keep: String?
        if exists, let current = try? run(kubectl, ["config", "current-context", "--kubeconfig", target.path], quiet: true)
            .trimmingCharacters(in: .whitespacesAndNewlines), !current.isEmpty, current != "docker-desktop", current != context {
            keep = current
        }
        let backup = URL(fileURLWithPath: target.path + ".before-mdock")
        if exists, !FileManager.default.fileExists(atPath: backup.path) { try FileManager.default.copyItem(at: target, to: backup) }
        // Ours first: for clashing names the first file wins, so a re-created cluster's certificates replace old ones.
        let merged = try run(kubectl, ["config", "view", "--flatten", "--raw"], quiet: true,
                             environment: ["KUBECONFIG": exists ? "\(fresh.path):\(target.path)" : fresh.path])
        let staging = target.deletingLastPathComponent().appendingPathComponent(".mdock-kubeconfig-merged-\(getpid())")
        FileManager.default.createFile(atPath: staging.path, contents: Data(merged.utf8), attributes: [.posixPermissions: 0o600])
        guard rename(staging.path, target.path) == 0 else {
            try? FileManager.default.removeItem(at: staging)
            throw CommandError(description: "writing \(target.path): \(String(cString: strerror(errno)))")
        }
        if let keep { _ = try? run(kubectl, ["config", "use-context", keep, "--kubeconfig", target.path], quiet: true) }
    }
}
