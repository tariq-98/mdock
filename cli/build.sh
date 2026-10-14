#!/bin/sh
# Builds the open-source Docker client tools from source, so mdock needs nothing from Docker Desktop
# or Homebrew: the docker CLI, the Compose and Buildx plugins, the macOS keychain credential helper,
# and kubectl.
#
# Installs:
#   ~/.local/bin/docker, docker-credential-osxkeychain, kubectl, docker-compose (alias of the plugin)
#   ~/.local/lib/docker/cli-plugins/docker-compose, docker-buildx
# ~/.local/bin is ahead of /usr/local/bin (Docker Desktop's symlinks) on PATH. Run configure.sh once
# afterwards to point ~/.docker/config.json at these plugins, the keychain and the mdock context.
set -eu
cd "$(dirname "$0")"
HERE=$(pwd)
SRC=$HERE/src
OUT=$HERE/out
BIN=${MDOCK_BIN_DIR:-$HOME/.local/bin}
PLUGINS=${MDOCK_PLUGIN_DIR:-$HOME/.local/lib/docker/cli-plugins}

CLI_TAG=v29.9.0
COMPOSE_TAG=v5.6.0
BUILDX_TAG=v0.38.0
CREDS_TAG=v0.9.10
# Matches the guest's k3s (Alpine k3s 1.36); kubectl supports one minor version of skew.
KUBECTL_TAG=v1.36.5
# File sync engine behind `mdock sync` (Docker Desktop's synchronized file shares use it too).
MUTAGEN_TAG=v0.18.1

# Everything here requires Go 1.26; one toolchain for all of it (the go command fetches it,
# checksum-verified, when the installed one is older, or a newer one if a project needs it).
export GOTOOLCHAIN=go1.26.8+auto
# Apple M1 and later implement ARMv8.4: LSE atomics etc. without runtime feature checks.
export GOARM64=v8.4
export GOFLAGS=-trimpath
M1_CFLAGS="-O2 -mcpu=apple-m1 -mmacosx-version-min=11.0"

fetch() { # repo tag [github org]
  if [ ! -d "$SRC/$1" ]; then
    git clone -q -c advice.detachedHead=false --depth 1 --branch "$2" "https://github.com/${3:-docker}/$1" "$SRC/$1"
  elif [ "$(git -C "$SRC/$1" describe --tags 2>/dev/null)" != "$2" ]; then
    git -C "$SRC/$1" fetch -q --depth 1 origin tag "$2"
    git -C "$SRC/$1" -c advice.detachedHead=false checkout -q "$2"
  fi
}

mkdir -p "$SRC" "$OUT"
fetch cli "$CLI_TAG"
fetch compose "$COMPOSE_TAG"
fetch buildx "$BUILDX_TAG"
fetch docker-credential-helpers "$CREDS_TAG"
fetch kubernetes "$KUBECTL_TAG" kubernetes
fetch mutagen "$MUTAGEN_TAG" mutagen-io

# docker CLI. Upstream keeps its module file as vendor.mod; expose it as go.mod for the build.
# CGO_ENABLED=0 and no netgo tag: on macOS Go then resolves names through libSystem, so VPN and
# per-domain resolvers (/etc/resolver, Tailscale MagicDNS) work. Upstream's static cgo build would
# add netgo, which reads only /etc/resolv.conf.
echo "building docker $CLI_TAG"
cd "$SRC/cli"
ln -sf vendor.mod go.mod
ln -sf vendor.sum go.sum
CGO_ENABLED=0 GO111MODULE=on go build -mod=vendor -tags grpcnotrace -ldflags "-s -w \
  -X github.com/docker/cli/cli/version.GitCommit=$(git rev-parse --short HEAD) \
  -X github.com/docker/cli/cli/version.BuildTime=$(date -u +%Y-%m-%dT%H:%M:%SZ) \
  -X github.com/docker/cli/cli/version.Version=${CLI_TAG#v} \
  -X github.com/docker/cli/cli/version.PlatformName=mdock" \
  -o "$OUT/docker" ./cmd/docker || { rm -f go.mod go.sum; exit 1; }
rm -f go.mod go.sum

# Compose, as upstream builds it for macOS: cgo + fsnotify (FSEvents for `docker compose watch`).
echo "building docker-compose $COMPOSE_TAG"
cd "$SRC/compose"
CGO_ENABLED=1 CGO_CFLAGS="$M1_CFLAGS" go build -tags fsnotify,e2e \
  -ldflags "-s -w -X github.com/docker/compose/v5/internal.Version=$COMPOSE_TAG" \
  -o "$OUT/docker-compose" ./cmd

echo "building docker-buildx $BUILDX_TAG"
cd "$SRC/buildx"
CGO_ENABLED=0 go build -ldflags "-s -w \
  -X github.com/docker/buildx/version.Version=$BUILDX_TAG \
  -X github.com/docker/buildx/version.Revision=$(git rev-parse HEAD) \
  -X github.com/docker/buildx/version.Package=github.com/docker/buildx" \
  -o "$OUT/docker-buildx" ./cmd/buildx

# Keychain credential helper (cgo: Security.framework).
echo "building docker-credential-osxkeychain $CREDS_TAG"
cd "$SRC/docker-credential-helpers"
P=github.com/docker/docker-credential-helpers
MACOSX_DEPLOYMENT_TARGET=11.0 CGO_ENABLED=1 CGO_CFLAGS="$M1_CFLAGS -Wno-atomic-alignment" go build -ldflags "-s -w \
  -X $P/credentials.Version=$CREDS_TAG -X $P/credentials.Revision=$(git rev-parse HEAD) \
  -X $P/credentials.Package=$P -X $P/credentials.Name=docker-credential-osxkeychain" \
  -o "$OUT/docker-credential-osxkeychain" ./osxkeychain/cmd

# kubectl, stamped the way kubernetes' hack/lib/version.sh does it.
echo "building kubectl $KUBECTL_TAG"
cd "$SRC/kubernetes"
MINOR=${KUBECTL_TAG#v1.}
MINOR=${MINOR%%.*}
KV=""
for pkg in k8s.io/client-go/pkg/version k8s.io/component-base/version; do
  KV="$KV -X $pkg.gitVersion=$KUBECTL_TAG -X $pkg.gitMajor=1 -X $pkg.gitMinor=$MINOR"
  KV="$KV -X $pkg.gitCommit=$(git rev-parse HEAD) -X $pkg.gitTreeState=clean -X $pkg.buildDate=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
done
CGO_ENABLED=0 go build -ldflags "-s -w $KV" -o "$OUT/kubectl" ./cmd/kubectl

# Mutagen: the macOS CLI (cgo, for FSEvents) and its agent bundle with the linux/arm64 agent. --sspl
# adds the fanotify watcher (SSPL-licensed) so changes made in containers sync back immediately.
echo "building mutagen $MUTAGEN_TAG"
cd "$SRC/mutagen"
GOFLAGS= CGO_ENABLED=1 go run scripts/build.go --mode=slim --sspl  # build.go locates itself; -trimpath breaks that
cp build/mutagen "$OUT/mutagen"
cp build/mutagen-agents.tar.gz "$OUT/mutagen-agents.tar.gz"

# install(1) unlinks before copying, so running binaries keep their old inode (no code-signing kill).
mkdir -p "$BIN" "$PLUGINS"
install -m 0755 "$OUT/docker" "$OUT/docker-credential-osxkeychain" "$OUT/kubectl" "$OUT/mutagen" "$BIN/"
# mutagen looks for its agent bundle next to itself or in ../libexec.
mkdir -p "$BIN/../libexec"
install -m 0644 "$OUT/mutagen-agents.tar.gz" "$BIN/../libexec/"
install -m 0755 "$OUT/docker-compose" "$OUT/docker-buildx" "$PLUGINS/"
ln -sf "$PLUGINS/docker-compose" "$BIN/docker-compose"
echo "installed to $BIN and $PLUGINS"
"$BIN/docker" --version
