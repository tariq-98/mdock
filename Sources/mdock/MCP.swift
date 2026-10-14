import Foundation

/// `mdock mcp`: a Model Context Protocol server on stdio, so AI agents (Claude Code, Claude Desktop,
/// any MCP client) can drive mdock, Docker and Kubernetes through typed tools with structured
/// results instead of scraping CLI output. Newline-delimited JSON-RPC 2.0; stdout carries protocol
/// messages only. Each tool runs the docker/kubectl/mdock CLIs with a timeout and capped output.
enum MCPServer {
    static let protocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    private static let writeLock = NSLock()

    static func run() -> Never {
        signal(SIGPIPE, SIG_IGN)
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            guard let message = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else {
                send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "parse error"]])
                continue
            }
            // Concurrent: a long build must not hold up a status call.
            Thread.detachNewThread { handle(message) }
        }
        exit(0)
    }

    private static func send(_ message: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]) else { return }
        data.append(0x0A)
        writeLock.withLock { FileHandle.standardOutput.write(data) }
    }

    private static func handle(_ message: [String: Any]) {
        guard let id = message["id"] else { return }  // notifications need no answer
        let params = message["params"] as? [String: Any] ?? [:]
        func reply(_ result: [String: Any]) { send(["jsonrpc": "2.0", "id": id, "result": result]) }
        func fail(_ code: Int, _ text: String) { send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": text]]) }
        switch message["method"] as? String ?? "" {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? ""
            reply(["protocolVersion": protocolVersions.contains(requested) ? requested : protocolVersions[1],
                   "capabilities": ["tools": ["listChanged": false]],
                   "serverInfo": ["name": "mdock", "title": "mdock (Docker and Kubernetes on this Mac)", "version": mdockVersion],
                   "instructions": instructions])
        case "ping":
            reply([:])
        case "tools/list":
            reply(["tools": tools.map(\.descriptor)])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            guard let tool = tools.first(where: { $0.name == name }) else { return fail(-32602, "unknown tool: \(name)") }
            reply(tool.call(params["arguments"] as? [String: Any] ?? [:]).json)
        default:
            fail(-32601, "method not found: \(message["method"] ?? "")")
        }
    }

    static let instructions = """
        mdock runs Docker (and optional Kubernetes) in a Linux VM on this Apple silicon Mac; it replaces \
        Docker Desktop. Start with `status` (or `doctor` if something fails). Containers are linux/arm64; \
        pass platform linux/amd64 to run x86 images (Rosetta on the default engine, FEX on the GPU engine, \
        both in x86's memory order in hardware). Mac paths under /Users, /Volumes and \
        /private bind-mount at the same paths, and edits made on the Mac reach file watchers in containers. \
        Published ports appear on the Mac's localhost; inside containers, host.docker.internal is the Mac's \
        own localhost. The Mac's GPU, media engine, Neural Engine and a Metal LLM server are reachable from \
        containers: see `accelerators`. Kubernetes: `kubernetes` to enable it, then `kubectl` (context \
        "mdock"); images from `build` run in pods without a registry (imagePullPolicy IfNotPresent or Never).
        """

    // MARK: Tools

    struct Result {
        var text: String
        var structured: [String: Any]?
        var isError = false

        static func json(_ object: [String: Any], isError: Bool = false) -> Result {
            let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
            return Result(text: String(decoding: data, as: UTF8.self), structured: object, isError: isError)
        }
        static func error(_ text: String) -> Result { Result(text: text, structured: nil, isError: true) }

        var json: [String: Any] {
            var r: [String: Any] = ["content": [["type": "text", "text": text]], "isError": isError]
            if let structured { r["structuredContent"] = structured }
            return r
        }
    }

    struct Tool {
        let name: String
        let title: String
        let description: String
        let input: [String: Any]
        let readOnly: Bool
        let destructive: Bool
        let call: ([String: Any]) -> Result

        var descriptor: [String: Any] {
            ["name": name, "title": title, "description": description, "inputSchema": input,
             "annotations": ["title": title, "readOnlyHint": readOnly, "destructiveHint": destructive,
                             "idempotentHint": readOnly, "openWorldHint": false]]
        }
    }

    static let tools: [Tool] = [
        Tool(name: "status", title: "mdock status",
             description: "State of the mdock VM: running, engine (vz, or krun with GPU), CPUs, memory, ports published on localhost, Mac accelerators, Kubernetes, autostart, and the endpoints to use (docker context, sockets, Kubernetes API, accelerator URLs). Call this first.",
             input: object([:]), readOnly: true, destructive: false) { _ in
            jsonResult(mdock(["status", "--json"]))
        },
        Tool(name: "doctor", title: "Health check",
             description: "Checks the VM, Docker engine and CLI, plugins, sockets, autostart, guest helper, Kubernetes and accelerators. Each check has a status (ok, warn, fail) and, when not ok, the command that fixes it.",
             input: object([:]), readOnly: true, destructive: false) { _ in
            jsonResult(mdock(["doctor", "--json"]))
        },
        Tool(name: "vm", title: "Start, stop, restart or upgrade the VM",
             description: "Controls the mdock VM. start boots it (about 3 s). Engines: 'vz' (default; Virtualization.framework, Rosetta for linux/amd64, fastest networking; macOS keeps the memory the VM has used until it stops) or 'gpu' (libkrun: the Mac's GPU in containers through Vulkan/OpenGL/OpenCL, memory freed in the guest goes back to macOS within seconds, linux/amd64 through FEX). stop shuts it down (all containers stop). restart does both. upgrade updates the guest's packages, Docker engine and kernel, then restarts. Stopping and restarting interrupt every running container. Under autostart an idle VM (no containers for `idle` minutes) stops by itself and any docker command starts it again.",
             input: object(["action": string("What to do", values: ["start", "stop", "restart", "upgrade"]),
                            "engine": string("For start: 'vz' (default) or 'gpu'", values: ["vz", "gpu"])], required: ["action"]),
             readOnly: false, destructive: true) { a in
            guard let action = a["action"] as? String else { return .error("action is required") }
            var args = [action]
            if action == "start", let engine = a["engine"] as? String { args.append(engine == "gpu" ? "--gpu" : "--no-gpu") }
            return textResult(mdock(args, timeout: 900))
        },
        Tool(name: "containers", title: "List containers",
             description: "Containers on mdock with id, name, image, state, status and published ports.",
             input: object(["all": boolean("Include stopped containers (default false)")]), readOnly: true, destructive: false) { a in
            let out = docker(["ps", "--no-trunc", "--format", "{{json .}}"] + (a["all"] as? Bool == true ? ["-a"] : []))
            guard out.status == 0 else { return failure(out) }
            let rows = jsonLines(out.stdout).map { r -> [String: Any] in
                ["id": String((r["ID"] as? String ?? "").prefix(12)), "name": r["Names"] ?? "", "image": r["Image"] ?? "",
                 "state": r["State"] ?? "", "status": r["Status"] ?? "", "ports": r["Ports"] ?? "", "created": r["CreatedAt"] ?? ""]
            }
            return .json(["containers": rows])
        },
        Tool(name: "images", title: "List images",
             description: "Images in mdock's image store (shared with Kubernetes when it is enabled).",
             input: object([:]), readOnly: true, destructive: false) { _ in
            let out = docker(["images", "--format", "{{json .}}"])
            guard out.status == 0 else { return failure(out) }
            let rows = jsonLines(out.stdout).map { r -> [String: Any] in
                ["repository": r["Repository"] ?? "", "tag": r["Tag"] ?? "", "id": r["ID"] ?? "", "size": r["Size"] ?? "",
                 "created": r["CreatedSince"] ?? ""]
            }
            return .json(["images": rows])
        },
        Tool(name: "run", title: "Run a container",
             description: "Runs a container. By default it waits for the command and returns exit_code, stdout and stderr, then removes the container; with detach it starts a long-running service and returns its id. gpu adds the Mac GPU (Vulkan; needs the gpu engine); media adds the Mac's media engine (ffmpeg shim or VA-API).",
             input: object([
                "image": string("Image, e.g. alpine:3.22"),
                "command": list("Command and arguments (optional)"),
                "detach": boolean("Run in the background and return the container id (default false)"),
                "name": string("Container name"),
                "remove": boolean("Remove the container when it exits (default: true unless detached)"),
                "env": stringMap("Environment variables"),
                "ports": list("Published ports, e.g. 8080:80 or 127.0.0.1:5432:5432; they appear on the Mac's localhost"),
                "volumes": list("Bind mounts (Mac paths under /Users, /Volumes, /private) or named volumes, e.g. /Users/me/app:/app"),
                "workdir": string("Working directory"),
                "platform": string("linux/arm64 (default), linux/amd64 (Rosetta, or FEX on the GPU engine) or linux/386 (FEX)"),
                "network": string("Network name"),
                "stdin": string("Text written to the command's stdin"),
                "gpu": boolean("Attach the Mac GPU (--device mdock.dev/gpu=all)"),
                "media": string("Attach the Mac media engine", values: ["ffmpeg", "vaapi"]),
                "options": list("Extra `docker run` options, e.g. [\"--memory\", \"2g\"]"),
                "timeout_seconds": integer("Give up (and remove the container) after this long; default 300"),
             ], required: ["image"]), readOnly: false, destructive: false) { a in
            guard let image = a["image"] as? String, !image.isEmpty else { return .error("image is required") }
            let detach = a["detach"] as? Bool ?? false
            let name = a["name"] as? String ?? (detach ? nil : "mcp-run-\(UUID().uuidString.prefix(8).lowercased())")
            var args = ["run"]
            if detach { args.append("-d") }
            if a["remove"] as? Bool ?? !detach { args.append("--rm") }
            if a["stdin"] != nil { args.append("-i") }
            if let name { args += ["--name", name] }
            for (k, v) in (a["env"] as? [String: Any] ?? [:]).sorted(by: { $0.key < $1.key }) { args += ["-e", "\(k)=\(v)"] }
            for p in strings(a["ports"]) { args += ["-p", p] }
            for v in strings(a["volumes"]) { args += ["-v", v] }
            if let w = a["workdir"] as? String { args += ["-w", w] }
            if let p = a["platform"] as? String { args += ["--platform", p] }
            if let n = a["network"] as? String { args += ["--network", n] }
            if a["gpu"] as? Bool == true { args += ["--device", "mdock.dev/gpu=all"] }
            if let m = a["media"] as? String { args += ["--device", "mdock.dev/media=\(m)"] }
            args += strings(a["options"]) + [image] + strings(a["command"])
            let out = docker(args, stdin: a["stdin"] as? String, timeout: timeout(a, 300))
            if detach {
                return out.status == 0 ? .json(["container_id": out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)]) : failure(out)
            }
            if out.timedOut, let name { _ = docker(["rm", "-f", name], timeout: 30) }
            return processResult(out)
        },
        Tool(name: "exec", title: "Run a command in a container",
             description: "Runs a command in a running container and returns exit_code, stdout and stderr.",
             input: object(["container": string("Container name or id"), "command": list("Command and arguments"),
                            "workdir": string("Working directory"), "env": stringMap("Environment variables"),
                            "user": string("User"), "stdin": string("Text written to stdin"),
                            "timeout_seconds": integer("Default 120")], required: ["container", "command"]),
             readOnly: false, destructive: false) { a in
            guard let container = a["container"] as? String, !strings(a["command"]).isEmpty else {
                return .error("container and command are required")
            }
            var args = ["exec"]
            if a["stdin"] != nil { args.append("-i") }
            if let w = a["workdir"] as? String { args += ["-w", w] }
            if let u = a["user"] as? String { args += ["-u", u] }
            for (k, v) in (a["env"] as? [String: Any] ?? [:]).sorted(by: { $0.key < $1.key }) { args += ["-e", "\(k)=\(v)"] }
            return processResult(docker(args + [container] + strings(a["command"]), stdin: a["stdin"] as? String, timeout: timeout(a, 120)))
        },
        Tool(name: "logs", title: "Container logs",
             description: "The last lines of a container's logs (its stdout and stderr).",
             input: object(["container": string("Container name or id"), "tail": integer("Lines from the end (default 200)"),
                            "since": string("Only logs since, e.g. 10m or 2026-10-14T12:00:00")], required: ["container"]),
             readOnly: true, destructive: false) { a in
            guard let container = a["container"] as? String else { return .error("container is required") }
            var args = ["logs", "--tail", String(a["tail"] as? Int ?? 200)]
            if let since = a["since"] as? String { args += ["--since", since] }
            return processResult(docker(args + [container], timeout: 60))
        },
        Tool(name: "container", title: "Manage a container",
             description: "start, stop, restart, kill, pause, unpause, remove or inspect a container. inspect returns docker's full JSON.",
             input: object(["container": string("Container name or id"),
                            "action": string("What to do", values: ["start", "stop", "restart", "kill", "pause", "unpause", "remove", "inspect"]),
                            "force": boolean("For remove: also remove a running container")], required: ["container", "action"]),
             readOnly: false, destructive: true) { a in
            guard let container = a["container"] as? String, let action = a["action"] as? String else {
                return .error("container and action are required")
            }
            if action == "inspect" {
                let out = docker(["inspect", container], timeout: 30)
                guard out.status == 0, let list = (try? JSONSerialization.jsonObject(with: Data(out.stdout.utf8))) as? [Any],
                      let first = list.first as? [String: Any] else { return failure(out) }
                return .json(first)
            }
            let args = action == "remove" ? ["rm"] + (a["force"] as? Bool == true ? ["-f"] : []) : [action]
            return processResult(docker(args + [container], timeout: 120))
        },
        Tool(name: "build", title: "Build an image",
             description: "Builds an image with BuildKit (docker buildx build) from a directory on the Mac and loads it into mdock, where containers and Kubernetes pods can use it. Several platforms (e.g. linux/arm64 and linux/amd64) build in one go. Returns the tail of the build log.",
             input: object(["context": string("Build context directory (absolute Mac path)"), "tag": string("Image tag, e.g. myapp:dev"),
                            "dockerfile": string("Dockerfile path (default <context>/Dockerfile)"),
                            "platforms": list("Target platforms, e.g. [\"linux/arm64\", \"linux/amd64\"]"),
                            "build_args": stringMap("Build arguments"), "target": string("Stage to build"),
                            "no_cache": boolean("Ignore the build cache"), "timeout_seconds": integer("Default 1800")],
                           required: ["context"]),
             readOnly: false, destructive: false) { a in
            guard let context = a["context"] as? String else { return .error("context is required") }
            var args = ["buildx", "build", "--progress=plain", "--load"]
            if let tag = a["tag"] as? String { args += ["-t", tag] }
            if let file = a["dockerfile"] as? String { args += ["-f", file] }
            let platforms = strings(a["platforms"])
            if !platforms.isEmpty { args += ["--platform", platforms.joined(separator: ",")] }
            for (k, v) in (a["build_args"] as? [String: Any] ?? [:]).sorted(by: { $0.key < $1.key }) { args += ["--build-arg", "\(k)=\(v)"] }
            if let target = a["target"] as? String { args += ["--target", target] }
            if a["no_cache"] as? Bool == true { args.append("--no-cache") }
            let out = docker(args + [context], timeout: timeout(a, 1800))
            var result: [String: Any] = ["exit_code": out.status, "log_tail": tail(out.stderr + out.stdout, 12_000)]
            if let tag = a["tag"] as? String { result["image"] = tag }
            if out.timedOut { result["timed_out"] = true }
            return .json(result, isError: out.status != 0)
        },
        Tool(name: "compose", title: "Docker Compose",
             description: "Runs docker compose for a project directory: up (detached), down, ps, logs, restart, stop, start, pull, build or config.",
             input: object(["project_dir": string("Directory with the compose file (absolute Mac path)"),
                            "action": string("Compose command", values: ["up", "down", "ps", "logs", "restart", "stop", "start", "pull", "build", "config"]),
                            "file": string("Compose file, if not the default name"), "services": list("Only these services"),
                            "volumes": boolean("For down: also remove named volumes"),
                            "timeout_seconds": integer("Default 600")], required: ["project_dir", "action"]),
             readOnly: false, destructive: true) { a in
            guard let dir = a["project_dir"] as? String, let action = a["action"] as? String else {
                return .error("project_dir and action are required")
            }
            var args = ["compose", "--project-directory", dir]
            if let file = a["file"] as? String { args += ["-f", file] }
            switch action {
            case "up": args += ["up", "-d"]
            case "down": args += ["down"] + (a["volumes"] as? Bool == true ? ["-v"] : [])
            case "ps": args += ["ps", "-a", "--format", "json"]
            case "logs": args += ["logs", "--no-color", "--tail", "200"]
            default: args.append(action)
            }
            let out = docker(args + strings(a["services"]), timeout: timeout(a, 600))
            if action == "ps", out.status == 0 { return .json(["services": jsonLines(out.stdout)]) }
            return processResult(out)
        },
        Tool(name: "kubernetes", title: "Kubernetes on/off",
             description: "Single-node Kubernetes (k3s on mdock's Docker): status, enable (about 20-60 s the first time; adds the kubeconfig context 'mdock'), disable (stops it, keeps its state) or reset (deletes the cluster and starts a fresh one).",
             input: object(["action": string("What to do", values: ["status", "enable", "disable", "reset"])], required: ["action"]),
             readOnly: false, destructive: true) { a in
            let action = a["action"] as? String ?? "status"
            return action == "status" ? jsonResult(mdock(["kubernetes", "status", "--json"]))
                : textResult(mdock(["kubernetes", action], timeout: 600))
        },
        Tool(name: "kubectl", title: "kubectl",
             description: "Runs kubectl against mdock's cluster (context 'mdock'). Pass manifests through stdin with args [\"apply\", \"-f\", \"-\"]. Use -o json for structured output.",
             input: object(["args": list("kubectl arguments, e.g. [\"get\", \"pods\", \"-A\", \"-o\", \"json\"]"),
                            "stdin": string("Text for stdin, e.g. a YAML manifest"),
                            "timeout_seconds": integer("Default 120")], required: ["args"]),
             readOnly: false, destructive: true) { a in
            guard let kubectl = which("kubectl") else { return .error("kubectl not found; build it with ~/mdock/cli/build.sh") }
            let out = exec(kubectl, ["--context", Kubernetes.context] + strings(a["args"]), stdin: a["stdin"] as? String,
                           timeout: timeout(a, 120))
            return processResult(out)
        },
        Tool(name: "docker", title: "Any docker command",
             description: "Runs any docker CLI command against mdock (e.g. [\"system\", \"df\"], [\"network\", \"ls\"], [\"volume\", \"rm\", \"x\"]). Prefer the specific tools when one fits.",
             input: object(["args": list("docker arguments without the leading 'docker'"), "stdin": string("Text for stdin"),
                            "timeout_seconds": integer("Default 300")], required: ["args"]),
             readOnly: false, destructive: true) { a in
            processResult(docker(strings(a["args"]), stdin: a["stdin"] as? String, timeout: timeout(a, 300)))
        },
        Tool(name: "arch_check", title: "Compare arm64 and amd64",
             description: "Runs an image's linux/arm64 and linux/amd64 variants side by side (amd64 through Rosetta, or FEX on the GPU engine) and compares what each ships (OS and Python packages) and, given a command, its exit status and output. Use it to catch differences between the Mac (arm64) and an x86 production host. isError is set when the command behaves differently.",
             input: object(["image": string("Image reference"),
                            "command": list("Command to run in both, e.g. [\"python\", \"-c\", \"import numpy; print(numpy.__version__)\"]"),
                            "options": list("docker run options, e.g. [\"-e\", \"X=1\", \"-v\", \"/Users/me/app:/app\"]")], required: ["image"]),
             readOnly: false, destructive: false) { a in
            guard let image = a["image"] as? String else { return .error("image is required") }
            let command = strings(a["command"])
            let out = mdock(["arch-check"] + strings(a["options"]) + [image] + (command.isEmpty ? [] : ["--"] + command), timeout: 1800)
            return textResult(out)
        },
        Tool(name: "port_image", title: "Rebuild an amd64-only image for arm64",
             description: "Rebuilds an image that only exists for linux/amd64 as native linux/arm64 by replaying its build history on the arm64 base image, so it runs without emulation. Produces IMAGE-arm64 (or tag), or replaces IMAGE with a multi-platform image. Can take minutes.",
             input: object(["image": string("amd64-only image reference"), "tag": string("Name for the arm64 image (default IMAGE-arm64)"),
                            "replace": boolean("Retag IMAGE itself to the multi-platform result")], required: ["image"]),
             readOnly: false, destructive: false) { a in
            guard let image = a["image"] as? String else { return .error("image is required") }
            var args = ["port", image]
            if let tag = a["tag"] as? String, !tag.isEmpty { args.append("--tag=\(tag)") }
            if a["replace"] as? Bool == true { args.append("--replace") }
            return textResult(mdock(args, timeout: 3600))
        },
        Tool(name: "sync", title: "Native-speed bind mounts",
             description: "Keeps a Mac directory in two-way sync with the VM's own disk (Mutagen) and puts that copy under the shared path in the VM, so every container that bind-mounts the directory (or anything inside it) gets native disk speed (about 20x for many small files). Containers already running need a restart to use it. list shows each synced directory and its state.",
             input: object(["action": string("What to do", values: ["list", "add", "remove"]),
                            "path": string("Directory on the Mac (for add and remove)"),
                            "ignore": list("Patterns to leave out, Docker ignore syntax (for add), e.g. [\"node_modules\"]")], required: ["action"]),
             readOnly: false, destructive: false) { a in
            let action = a["action"] as? String ?? "list"
            if action == "list" { return jsonResult(mdock(["sync", "list", "--json"])) }
            guard let path = a["path"] as? String else { return .error("path is required") }
            return textResult(mdock(["sync", action, path] + strings(a["ignore"]).map { "--ignore=\($0)" }, timeout: 1800))
        },
        Tool(name: "workspace", title: "Case-sensitive workspace",
             description: "macOS disks are case-insensitive, Linux is not: files differing only in case collide on the Mac. status shows the case-sensitive APFS workspace volume for code (at /Volumes/<name>, linked from ~/<name>); create makes one; casecheck lists names in a directory that differ only in case.",
             input: object(["action": string("What to do", values: ["status", "create", "mount", "casecheck"]),
                            "name": string("Volume name for create (default Workspace)"),
                            "path": string("Directory for casecheck")], required: ["action"]),
             readOnly: false, destructive: false) { a in
            switch a["action"] as? String ?? "status" {
            case "create": return textResult(mdock(["workspace", "create"] + [a["name"] as? String].compactMap { $0 }, timeout: 300))
            case "mount": return textResult(mdock(["workspace", "mount"]))
            case "casecheck":
                guard let path = a["path"] as? String else { return .error("path is required") }
                return textResult(mdock(["casecheck", path], timeout: 300))
            default: return jsonResult(mdock(["workspace", "status", "--json"]))
            }
        },
        Tool(name: "accelerators", title: "Mac GPU, media engine and ML for containers",
             description: "How containers use this Mac's GPU, media engine (VideoToolbox), Neural Engine/Core ML, Apple Foundation Models and a Metal LLM server, and whether each is ready now.",
             input: object([:]), readOnly: true, destructive: false) { _ in
            let s = (try? JSONSerialization.jsonObject(with: Data(mdock(["status", "--json"]).stdout.utf8))) as? [String: Any] ?? [:]
            let engine = s["engine"] as? String ?? "stopped"
            let live = Dictionary(((s["accel"] as? [[String: Any]]) ?? []).compactMap { a -> (String, String)? in
                guard let name = a["name"] as? String else { return nil }
                return (name, a["running"] as? Bool == true ? "running" : a["built"] as? Bool == true ? "ready" : "not built")
            }, uniquingKeysWith: { a, _ in a })
            return .json(["engine": engine, "accelerators": [
                ["name": "gpu", "use": "docker run --device mdock.dev/gpu=all …: Vulkan 1.2 through Venus with the image's own Mesa (e.g. Fedora mesa-vulkan-drivers); OpenGL 2.1/ES 2.0 on the GPU with -e GALLIUM_DRIVER=zink; OpenCL (rusticl) and native OpenGL in the mdock/gpu image (gpu/guest/build.sh)",
                 "status": engine.contains("GPU") ? "ready" : "needs the GPU engine: vm start with engine gpu"],
                ["name": "media-ffmpeg", "use": "docker run --device mdock.dev/media=ffmpeg …: ffmpeg/ffprobe in the container run on the Mac media engine (VideoToolbox); for Jellyfin",
                 "status": live["media"] ?? "unknown"],
                ["name": "media-vaapi", "use": "docker run --device mdock.dev/media=vaapi …: VA-API (libva) decode/encode on VideoToolbox",
                 "status": live["vt"] ?? "unknown"],
                ["name": "ml", "use": "http://ml.mdock.internal:8100 from containers: OpenAI-style /v1/chat/completions on Apple Foundation Models, /v1/audio/transcriptions, Core ML models under /v1/coreml (Neural Engine); GET /v1/capabilities",
                 "status": live["ml"] ?? "unknown"],
                ["name": "llm", "use": "http://llm.mdock.internal:8200 from containers: OpenAI and Ollama APIs on llama.cpp with Metal; GGUF models from Hugging Face (owner/repo[:QUANT]); llm.mdock.internal:50052 is ggml RPC",
                 "status": live["llm"] ?? "unknown"],
            ]])
        },
    ]

    // MARK: Running commands

    struct Output {
        var status: Int32
        var stdout: String
        var stderr: String
        var timedOut: Bool
    }

    static func exec(_ tool: String, _ args: [String], stdin: String? = nil, timeout: TimeInterval = 120) -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        let out = Pipe(), err = Pipe(), inp = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = stdin == nil ? FileHandle.nullDevice : inp
        do { try process.run() } catch { return Output(status: 127, stdout: "", stderr: "\(error)", timedOut: false) }
        var outData = Data(), errData = Data()
        let readers = DispatchGroup()
        DispatchQueue.global().async(group: readers) { outData = out.fileHandleForReading.readDataToEndOfFile() }
        DispatchQueue.global().async(group: readers) { errData = err.fileHandleForReading.readDataToEndOfFile() }
        if let stdin {
            DispatchQueue.global().async {
                inp.fileHandleForWriting.write(Data(stdin.utf8))
                try? inp.fileHandleForWriting.close()
            }
        }
        let timedOut = Cancel()
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            guard process.isRunning else { return }
            timedOut.set()
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        }
        process.waitUntilExit()
        readers.wait()
        return Output(status: process.terminationStatus, stdout: tail(String(decoding: outData, as: UTF8.self), 100_000),
                      stderr: tail(String(decoding: errData, as: UTF8.self), 30_000), timedOut: timedOut.isSet)
    }

    static func docker(_ args: [String], stdin: String? = nil, timeout: TimeInterval = 120) -> Output {
        guard let docker = which("docker") else { return Output(status: 127, stdout: "", stderr: "docker CLI not found", timedOut: false) }
        return exec(docker, ["--context", "mdock"] + args, stdin: stdin, timeout: timeout)
    }

    static func mdock(_ args: [String], timeout: TimeInterval = 60) -> Output {
        let me = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0]).resolvingSymlinksInPath().path
        return exec(me, args, timeout: timeout)
    }

    // MARK: Helpers

    static func tail(_ text: String, _ limit: Int) -> String {
        guard text.utf8.count > limit else { return text }
        let kept = String(decoding: text.utf8.suffix(limit), as: UTF8.self)
        return "[… \(text.utf8.count - limit) earlier bytes omitted]\n" + kept
    }

    static func jsonLines(_ text: String) -> [[String: Any]] {
        if let array = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [[String: Any]] { return array }
        return text.split(separator: "\n").compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
    }

    static func jsonResult(_ out: Output) -> Result {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(out.stdout.utf8))) as? [String: Any] else { return failure(out) }
        return .json(object, isError: out.status != 0)
    }

    static func textResult(_ out: Output) -> Result {
        let text = [out.stdout, out.stderr].filter { !$0.isEmpty }.joined(separator: "\n")
        return Result(text: text.isEmpty ? "exit status \(out.status)" : text, structured: nil, isError: out.status != 0)
    }

    static func processResult(_ out: Output) -> Result {
        var r: [String: Any] = ["exit_code": out.status, "stdout": out.stdout, "stderr": out.stderr]
        if out.timedOut { r["timed_out"] = true }
        return .json(r, isError: out.status != 0)
    }

    static func failure(_ out: Output) -> Result {
        .error(out.timedOut ? "timed out" : [out.stderr, out.stdout].first { !$0.isEmpty } ?? "exit status \(out.status)")
    }

    static func timeout(_ a: [String: Any], _ fallback: Int) -> TimeInterval {
        TimeInterval(max(1, a["timeout_seconds"] as? Int ?? fallback))
    }

    static func strings(_ value: Any?) -> [String] {
        (value as? [Any])?.map { "\($0)" } ?? []
    }

    // JSON Schema builders.
    static func object(_ properties: [String: Any], required: [String] = []) -> [String: Any] {
        var o: [String: Any] = ["type": "object", "properties": properties, "additionalProperties": false]
        if !required.isEmpty { o["required"] = required }
        return o
    }
    static func string(_ description: String, values: [String]? = nil) -> [String: Any] {
        var o: [String: Any] = ["type": "string", "description": description]
        if let values { o["enum"] = values }
        return o
    }
    static func list(_ description: String) -> [String: Any] {
        ["type": "array", "items": ["type": "string"], "description": description]
    }
    static func stringMap(_ description: String) -> [String: Any] {
        ["type": "object", "additionalProperties": ["type": "string"], "description": description]
    }
    static func boolean(_ description: String) -> [String: Any] { ["type": "boolean", "description": description] }
    static func integer(_ description: String) -> [String: Any] { ["type": "integer", "description": description] }
}
