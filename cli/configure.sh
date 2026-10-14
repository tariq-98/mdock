#!/bin/sh
# Points the Docker CLI at the tools from build.sh and at mdock instead of Docker Desktop:
#   credsStore           desktop -> osxkeychain (the same login-keychain items; Desktop's helper
#                        stores credentials there too)
#   currentContext       -> mdock
#   cliPluginsExtraDirs  ~/.local/lib/docker/cli-plugins first (searched before ~/.docker/cli-plugins,
#                        where Docker Desktop's symlinks live)
#   plugins.scout/debug  removed: hooks that ran Docker Desktop's proprietary plugins after pulls/builds
# The original file is kept as config.json.before-mdock; `configure.sh --revert` restores it.
set -eu
DIR=${DOCKER_CONFIG:-$HOME/.docker}
CONFIG=$DIR/config.json
BACKUP=$CONFIG.before-mdock
PLUGINS=${MDOCK_PLUGIN_DIR:-$HOME/.local/lib/docker/cli-plugins}

if [ "${1:-}" = "--revert" ]; then
  [ -f "$BACKUP" ] || { echo "no backup at $BACKUP" >&2; exit 1; }
  cp -p "$BACKUP" "$CONFIG"
  echo "restored $CONFIG from $BACKUP"
  exit 0
fi

mkdir -p "$DIR"
[ -f "$CONFIG" ] || echo '{}' > "$CONFIG"
[ -f "$BACKUP" ] || cp -p "$CONFIG" "$BACKUP"
/usr/bin/python3 - "$CONFIG" "$PLUGINS" <<'EOF'
import json, os, sys, tempfile
path, plugins = sys.argv[1], sys.argv[2]
with open(path) as f:
    cfg = json.load(f)
cfg["credsStore"] = "osxkeychain"
cfg["currentContext"] = "mdock"
cfg["cliPluginsExtraDirs"] = [plugins] + [d for d in cfg.get("cliPluginsExtraDirs", []) if d != plugins]
for name in ("scout", "debug"):
    cfg.get("plugins", {}).pop(name, None)
mode = os.stat(path).st_mode & 0o777
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path))
with os.fdopen(fd, "w") as f:
    json.dump(cfg, f, indent="\t")
    f.write("\n")
os.chmod(tmp, mode)
os.replace(tmp, path)
EOF
echo "updated $CONFIG (original: $BACKUP)"
if ! docker context inspect mdock >/dev/null 2>&1; then
  echo "note: the mdock context doesn't exist yet; \`mdock start\` creates it" >&2
fi
