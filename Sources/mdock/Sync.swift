import CryptoKit
import Foundation

/// `mdock sync`: native-speed bind mounts for big source trees (what Docker Desktop calls synchronized
/// file shares, done transparently). A Mac directory is kept in two-way sync (Mutagen, built from
/// source by cli/build.sh) with a copy on the VM's ext4 data disk, and inside the VM that copy is
/// bind-mounted over the shared path itself. Every container that mounts the directory, or anything
/// under it, then gets ext4 speed without changing how it's run. Mac edits arrive through FSEvents;
/// writes made in containers go back through fanotify in the sync container.
enum Sync {
    struct Share: Codable {
        var path: String
        var id: String
        var ignores: [String]
        var vcs: Bool
    }

    static let stateURL = Paths.url("sync.json")
    /// "id path" lines; the guest agent re-applies the overlays at boot (Guest.agentScript).
    static let overlaysURL = Paths.url("sync-overlays")
    static let container = "mdock-sync"
    static let volume = "mdock-sync"
    static let replicaRoot = "/var/lib/docker/volumes/mdock-sync/_data"

    static var shares: [Share] {
        (try? Data(contentsOf: stateURL)).flatMap { try? JSONDecoder().decode([Share].self, from: $0) } ?? []
    }

    static func save(_ shares: [Share]) throws {
        try JSONEncoder().encode(shares).write(to: stateURL)
        try (shares.map { "\($0.id) \($0.path)" }.joined(separator: "\n") + "\n").write(to: overlaysURL, atomically: true, encoding: .utf8)
    }

    static func command(_ args: [String]) throws {
        let words = args.filter { !$0.hasPrefix("--") }
        let ignores = args.filter { $0.hasPrefix("--ignore=") }.map { String($0.dropFirst(9)) }
        switch words.first {
        case "add": try add(words.count > 1 ? words[1] : FileManager.default.currentDirectoryPath,
                            ignores: ignores, vcs: !args.contains("--ignore-vcs"))
        case "remove", "rm": try remove(words.count > 1 ? words[1] : FileManager.default.currentDirectoryPath)
        case nil, "list", "status": try list(json: args.contains("--json"))
        default:
            throw CommandError(description: "usage: mdock sync add [DIR] [--ignore=PATTERN]... [--ignore-vcs] | remove [DIR] | list [--json]")
        }
    }

    static func tools() throws -> (docker: String, mutagen: String) {
        guard let docker = which("docker") else { throw CommandError(description: "docker CLI not found") }
        guard let mutagen = which("mutagen") else { throw CommandError(description: "mutagen not found: run cli/build.sh") }
        return (docker, mutagen)
    }

    /// Runs mutagen with the Docker endpoint the sessions use (Mutagen captures it when a session is
    /// created): mdock's internal socket, so a live session isn't docker activity and, while the VM is
    /// stopped, its reconnect attempts find no socket rather than starting the VM.
    @discardableResult
    static func mutagen(_ args: [String], quiet: Bool = false) throws -> String {
        try run(try tools().mutagen, args, quiet: quiet, environment: ["DOCKER_HOST": "unix://\(Paths.internalSocket.path)"])
    }

    static func add(_ dir: String, ignores: [String], vcs: Bool) throws {
        guard status()?["ready"] as? Bool == true else { throw CommandError(description: "mdock is not running") }
        let (docker, _) = try tools()
        let path = realPath(dir)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            throw CommandError(description: "\(path) is not a directory")
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard path != home, !home.hasPrefix(path + "/"), path != "/" else {
            throw CommandError(description: "sync a project directory, not \(path)")
        }
        let config = try loadConfig()
        guard config.shares.contains(where: { path.hasPrefix($0.host + "/") }) else {
            throw CommandError(description: "\(path) is outside the directories mdock shares (\(config.shares.map(\.host).joined(separator: ", ")))")
        }
        var current = shares
        if current.contains(where: { $0.path == path }) { print("\(path) is already synced"); return }
        if let overlap = current.first(where: { path.hasPrefix($0.path + "/") || $0.path.hasPrefix(path + "/") }) {
            throw CommandError(description: "\(path) overlaps the synced \(overlap.path)")
        }
        let id = SHA256.hash(data: Data(path.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()

        // The sync container: Mutagen's agent runs here, next to the copies (fanotify needs these
        // capabilities; MUTAGEN_SIDECAR turns on its whole-filesystem watching).
        let running = (try? run(docker, ["--context", "mdock", "inspect", "-f", "{{.State.Running}}", container], quiet: true))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if running == nil {
            // --init: `sleep` as PID 1 would ignore SIGTERM and hold every VM shutdown for 10 s.
            try run(docker, ["--context", "mdock", "run", "-d", "--init", "--name", container, "--restart", "unless-stopped",
                             "--cap-add", "SYS_ADMIN", "--cap-add", "DAC_READ_SEARCH", "--label", "com.mdock.internal=sync",
                             "-e", "MUTAGEN_SIDECAR=1", "-e", "HOME=/root", "-v", "\(volume):/sync", "alpine:3.22", "sleep", "infinity"], quiet: true)
        } else if running != "true" {
            try run(docker, ["--context", "mdock", "start", container], quiet: true)
        }
        try mutagen(["daemon", "start"], quiet: true)

        print("Syncing \(path) to the VM's disk…")
        var args = ["sync", "create", "--name", "mdock-\(id)", "--label", "mdock=sync", "--sync-mode", "two-way-safe",
                    "--symlink-mode", "posix-raw",
                    "--default-file-mode-alpha", "0644", "--default-directory-mode-alpha", "0755",
                    // In containers, shared Mac files look root-owned and any user may write them; match that.
                    "--default-file-mode-beta", "0666", "--default-directory-mode-beta", "0777",
                    "--ignore-syntax", "docker"]
        if !vcs { args.append("--ignore-vcs") }
        for pattern in ignores { args += ["--ignore", pattern] }
        args += [path, "docker://\(container)/sync/\(id)"]
        try mutagen(args, quiet: true)
        let start = Date()
        try mutagen(["sync", "flush", "mdock-\(id)"])
        print(String(format: "Initial sync done in %.1fs.", Date().timeIntervalSince(start)))

        // Put the copy over the shared path, for every container started from now on.
        _ = try guestScript(#"""
            set -e
            mountpoint -q "$2" || mount --bind "\#(replicaRoot)/$1" "$2"
            """#, [id, path])
        current.append(Share(path: path, id: id, ignores: ignores, vcs: vcs))
        try save(current)
        print("\(path) is synced: containers that bind-mount it (or anything inside it) now get native disk speed.")
        let users = (try? run(docker, ["--context", "mdock", "ps", "--format", "{{.Names}}\t{{.Mounts}}"], quiet: true)) ?? ""
        let affected = users.split(separator: "\n").filter { $0.contains(path) }.map { String($0.split(separator: "\t")[0]) }
        if !affected.isEmpty { print("Restart these to use it: \(affected.joined(separator: ", "))") }
    }

    static func remove(_ dir: String) throws {
        let path = realPath(dir)
        var current = shares
        guard let share = current.first(where: { $0.path == path }) else { throw CommandError(description: "\(path) isn't synced") }
        if status()?["ready"] as? Bool == true {
            _ = try? guestScript(#"""
                umount "$2" 2>/dev/null || umount -l "$2" 2>/dev/null
                rm -rf "\#(replicaRoot)/$1"
                true
                """#, [share.id, path])
        }
        _ = try? mutagen(["sync", "terminate", "mdock-\(share.id)"], quiet: true)
        current.removeAll { $0.path == path }
        try save(current)
        // The last share gone: the sync container has nothing left to do.
        if current.isEmpty, let docker = which("docker") {
            _ = try? run(docker, ["--context", "mdock", "rm", "-f", container], quiet: true)
            _ = try? run(docker, ["--context", "mdock", "volume", "rm", volume], quiet: true)
        }
        print("\(path) is no longer synced; containers started from now on use the shared directory directly.")
    }

    static func list(json: Bool) throws {
        let current = shares
        var sessions: [[String: Any]] = []
        if !current.isEmpty, let out = try? mutagen(["sync", "list", "--label-selector", "mdock=sync", "--template", "{{json .}}"], quiet: true),
           let parsed = (try? JSONSerialization.jsonObject(with: Data(out.utf8))) as? [[String: Any]] {
            sessions = parsed
        }
        let rows: [[String: Any]] = current.map { share in
            let session = sessions.first { $0["name"] as? String == "mdock-\(share.id)" }
            let conflicts = (session?["conflicts"] as? [Any])?.count ?? 0
            let problems = ((session?["alpha"] as? [String: Any])?["scanProblems"] as? [Any])?.count ?? 0
            let state = session?["paused"] as? Bool == true ? "paused (resumes when the VM starts)"
                : session?["status"] as? String ?? "not running"
            return ["path": share.path, "status": state,
                    "conflicts": conflicts, "problems": problems]
        }
        if json {
            print(String(decoding: try JSONSerialization.data(withJSONObject: ["shares": rows], options: [.sortedKeys]), as: UTF8.self))
        } else if rows.isEmpty {
            print("Nothing synced. mdock sync add DIR gives containers native disk speed for DIR.")
        } else {
            for r in rows {
                print("\(r["path"] ?? "")  \(r["status"] ?? "")\((r["conflicts"] as? Int ?? 0) > 0 ? "  \(r["conflicts"]!) conflict(s): mutagen sync list" : "")")
            }
        }
    }

    /// After the VM boots, Mutagen would only retry the VM side on its own backoff (~15 s, with
    /// containers seeing a stale copy meanwhile); once the sync container runs, reconnect right away.
    static func reconnect(containerRunning: () -> Bool) {
        guard !shares.isEmpty else { return }
        for _ in 0..<60 where !containerRunning() { usleep(500_000) }
        do { try mutagen(["sync", "resume", "--label-selector", "mdock=sync"], quiet: true) } catch { log("mutagen resume: \(error)") }
    }

    /// Idle stop: Mutagen would keep retrying the VM through docker.sock, and every retry would start
    /// mdock again. reconnect() resumes the sessions after the next boot.
    static func pause() {
        guard !shares.isEmpty else { return }
        do { try mutagen(["sync", "pause", "--label-selector", "mdock=sync"], quiet: true) } catch { log("mutagen pause: \(error)") }
    }

    /// Daemon start: the sessions need Mutagen's daemon on the Mac (the guest re-applies the overlays).
    static func resume() {
        guard !shares.isEmpty else { return }
        do { try mutagen(["daemon", "start"], quiet: true) } catch { log("mutagen daemon: \(error)") }
    }
}
