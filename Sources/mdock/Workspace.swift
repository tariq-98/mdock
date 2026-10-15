import Foundation

/// `mdock workspace`: a case-sensitive APFS volume for source code, so a repository behaves the same on
/// the Mac and in Linux containers (`Readme` and `README` can coexist, case-only renames work). It is a
/// sparse bundle in the home folder (it grows as used; Time Machine backs up only changed bands),
/// mounted at /Volumes/<name> with ~/<name> pointing there; when it isn't mounted the link dangles, so
/// nothing lands on the case-insensitive disk by mistake. VZ's file sharing shows it to containers at
/// the same path, and the daemon mounts it at login. Its settings live outside ~/.mdock: `mdock delete`
/// never touches the code.
enum Workspace {
    struct Settings: Codable {
        var name: String
        var image: String
    }

    static let settingsURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/mdock/workspace.json")
    static var settings: Settings? { (try? Data(contentsOf: settingsURL)).flatMap { try? JSONDecoder().decode(Settings.self, from: $0) } }
    static func mountpoint(_ s: Settings) -> String { "/Volumes/\(s.name)" }
    /// The volume is mounted there: a statfs, not a run of mount(8) (70 ms of every start).
    static func isMounted(_ s: Settings) -> Bool {
        var info = statfs()
        guard statfs(mountpoint(s), &info) == 0 else { return false }
        let on = withUnsafeBytes(of: info.f_mntonname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let type = withUnsafeBytes(of: info.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return on == mountpoint(s) && type == "apfs"
    }

    static func command(_ args: [String]) throws {
        let flags = args.filter { $0.hasPrefix("--") }
        let words = args.filter { !$0.hasPrefix("--") }
        switch words.first {
        case "create":
            let size = flags.first { $0.hasPrefix("--size=") }.flatMap { Int($0.dropFirst(7).replacingOccurrences(of: "g", with: "")) } ?? 500
            try create(name: words.count > 1 ? words[1] : "Workspace", sizeGiB: size)
        case "mount": try mount(quiet: false)
        case "eject": try eject(force: flags.contains("--force"))
        case nil, "status":
            let s = status()
            if flags.contains("--json") {
                print(String(decoding: try JSONSerialization.data(withJSONObject: s, options: [.sortedKeys]), as: UTF8.self))
            } else if s["configured"] as? Bool != true {
                print("No workspace yet: mdock workspace create [name] [--size=500g]")
            } else {
                print("workspace: \(s["mountpoint"] ?? "") (\(s["mounted"] as? Bool == true ? "mounted" : "not mounted"), case-sensitive APFS)")
                print("image:     \(s["image"] ?? "")\(s["used"].map { " (\($0) used)" } ?? "")")
                print("shortcut:  \(s["link"] ?? "")")
            }
        default:
            throw CommandError(description: "usage: mdock workspace create [name] [--size=500g] | mount | eject [--force] | status [--json]")
        }
    }

    static func create(name: String, sizeGiB: Int) throws {
        guard name.range(of: #"^[A-Za-z0-9][A-Za-z0-9 _.-]*$"#, options: .regularExpression) != nil else {
            throw CommandError(description: "use letters, digits, space, '.', '_' or '-' for the name")
        }
        if let existing = settings {
            throw CommandError(description: "a workspace already exists: \(existing.image) (mdock workspace mount)")
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let image = home.appendingPathComponent("\(name).sparsebundle")
        guard !FileManager.default.fileExists(atPath: image.path) else { throw CommandError(description: "\(image.path) already exists") }
        guard !FileManager.default.fileExists(atPath: "/Volumes/\(name)") else { throw CommandError(description: "/Volumes/\(name) is taken") }
        print("Creating \(image.path): case-sensitive APFS, up to \(sizeGiB) GB, grows as used…")
        try run("/usr/bin/hdiutil", ["create", "-quiet", "-size", "\(sizeGiB)g", "-type", "SPARSEBUNDLE",
                                     "-fs", "Case-sensitive APFS", "-volname", name, image.path])
        let s = Settings(name: name, image: image.path)
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(s).write(to: settingsURL)
        try mount(quiet: true)
        // Prove it: two names that differ only in case.
        let probe = URL(fileURLWithPath: mountpoint(s))
        for n in [".mdock-case-probe", ".MDOCK-CASE-PROBE"] { FileManager.default.createFile(atPath: probe.appendingPathComponent(n).path, contents: nil) }
        let both = (try? FileManager.default.contentsOfDirectory(atPath: probe.path))?.filter { $0.lowercased() == ".mdock-case-probe" }.count == 2
        for n in [".mdock-case-probe", ".MDOCK-CASE-PROBE"] { try? FileManager.default.removeItem(at: probe.appendingPathComponent(n)) }
        guard both else { throw CommandError(description: "the new volume is not case-sensitive") }
        print("Workspace ready at \(mountpoint(s)) (case-sensitive; ~/\(name) points there). Keep repositories here;")
        print("containers see it at the same path, and mdock mounts it at login.")
    }

    /// Attaches the workspace if it isn't mounted. Called by the daemon at start (so at login).
    static func mount(quiet: Bool) throws {
        guard let s = settings else {
            if quiet { return }
            throw CommandError(description: "no workspace: mdock workspace create")
        }
        if !isMounted(s) {
            guard FileManager.default.fileExists(atPath: s.image) else { throw CommandError(description: "\(s.image) is missing") }
            try run("/usr/bin/hdiutil", ["attach", "-quiet", "-mountpoint", mountpoint(s), s.image])
        }
        // ~/<name> -> /Volumes/<name>, unless the user put something else there.
        let link = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(s.name).path
        if (try? FileManager.default.attributesOfItem(atPath: link)) == nil && (try? FileManager.default.destinationOfSymbolicLink(atPath: link)) == nil {
            try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: mountpoint(s))
        }
        if !quiet { print("\(mountpoint(s)) mounted") }
    }

    static func eject(force: Bool) throws {
        guard let s = settings, isMounted(s) else { print("not mounted"); return }
        do {
            try run("/usr/bin/hdiutil", ["detach", mountpoint(s)] + (force ? ["-force"] : []), quiet: true)
            print("\(mountpoint(s)) ejected")
        } catch {
            throw CommandError(description: "\(mountpoint(s)) is in use (containers or the VM's file sharing may hold files open); "
                               + "stop those containers or use --force")
        }
    }

    static func status() -> [String: Any] {
        guard let s = settings else { return ["configured": false] }
        var o: [String: Any] = ["configured": true, "name": s.name, "image": s.image, "mountpoint": mountpoint(s),
                                "mounted": isMounted(s), "caseSensitive": true,
                                "link": FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(s.name).path]
        if let du = try? run("/usr/bin/du", ["-sh", s.image], quiet: true).split(separator: "\t").first { o["used"] = String(du) }
        return o
    }
}

/// `mdock casecheck [dir]`: names that differ only in case, which a case-insensitive Mac disk can't
/// hold apart (one silently replaces the other on checkout). Uses git's file list when it's a repo.
enum CaseCheck {
    static func report(_ dir: String) throws {
        let root = URL(fileURLWithPath: dir).standardizedFileURL.path
        var paths: [String] = []
        if let git = which("git"), let out = try? run(git, ["-C", root, "ls-tree", "-r", "--name-only", "HEAD"], quiet: true) {
            paths = out.split(separator: "\n").map(String.init)
        } else if let e = FileManager.default.enumerator(atPath: root) {
            while let p = e.nextObject() as? String { paths.append(p) }
        }
        var seen: [String: [String]] = [:]
        for p in paths {
            // Every directory prefix counts too: src/App/x and src/app/y collide at src/app.
            var prefix = ""
            for part in p.split(separator: "/") {
                prefix = prefix.isEmpty ? String(part) : prefix + "/" + part
                let key = prefix.lowercased()
                if !(seen[key]?.contains(prefix) ?? false) { seen[key, default: []].append(prefix) }
            }
        }
        let clashes = seen.values.filter { $0.count > 1 }.map { $0.sorted() }.sorted { $0[0] < $1[0] }
        if clashes.isEmpty {
            print("No names in \(root) differ only in case (\(paths.count) paths checked).")
        } else {
            print("\(clashes.count) name(s) in \(root) differ only in case; a case-insensitive disk keeps one of each:")
            clashes.forEach { print("  " + $0.joined(separator: "  |  ")) }
            print("Check the repository out in a case-sensitive workspace instead: mdock workspace create")
            exit(1)
        }
    }
}
