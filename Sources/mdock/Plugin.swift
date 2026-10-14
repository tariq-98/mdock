import Foundation

/// `docker mdock …`: mdock is also a Docker CLI plugin, through a docker-mdock symlink in the plugin
/// directory (build.sh makes it). Docker runs a plugin with its own arguments: Docker's global
/// options, the plugin's name, then the rest.
enum DockerPlugin {
    static let name = "mdock"

    static var metadata: String {
        #"{"SchemaVersion":"0.1.0","Vendor":"mdock","Version":"\#(mdockVersion)","#
            + #""ShortDescription":"The mdock VM: start, stop, status, kubernetes, upgrade, doctor, mcp"}"#
    }

    /// The command line mdock should act on, minus Docker's part when run as a plugin.
    static func arguments(_ argv: [String]) -> [String] {
        let args = Array(argv.dropFirst())
        guard let exe = argv.first.map({ ($0 as NSString).lastPathComponent }), exe == "docker-\(name)",
              args.first != "docker-cli-plugin-metadata" else { return args }
        // Docker's global options that take a value (the rest are flags).
        let valued: Set = ["--config", "-c", "--context", "-H", "--host", "-l", "--log-level", "--tlscacert", "--tlscert", "--tlskey"]
        var i = 0
        while i < args.count, args[i].hasPrefix("-") {
            i += valued.contains(args[i]) ? 2 : 1
        }
        if i < args.count, args[i] == name { i += 1 }
        return Array(args.dropFirst(i))
    }
}
