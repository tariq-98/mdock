#!/bin/sh
# For after Docker Desktop is uninstalled. Its privileged helper recreated /var/run/docker.sock at
# every boot, pointing at ~/.docker/run/docker.sock (which the mdock daemon now serves). This installs
# a one-line root LaunchDaemon that keeps doing that, so tools hard-wired to /var/run/docker.sock keep
# working. Run it yourself:
#   sudo cli/default-socket.sh install     # or: remove
set -eu
LABEL=local.mdock.socket
PLIST=/Library/LaunchDaemons/$LABEL.plist
[ "$(id -u)" = 0 ] && [ -n "${SUDO_USER:-}" ] || { echo "usage: sudo $0 install|remove" >&2; exit 2; }
HOME_DIR=$(dscl . -read "/Users/$SUDO_USER" NFSHomeDirectory | awk '{print $2}')

case "${1:-}" in
install)
  if [ -e /Applications/Docker.app ]; then
    echo "Docker Desktop is still installed and manages /var/run/docker.sock itself; uninstall it first." >&2
    exit 1
  fi
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array>
    <string>/bin/ln</string><string>-sfh</string>
    <string>$HOME_DIR/.docker/run/docker.sock</string><string>/var/run/docker.sock</string>
  </array>
  <key>RunAtLoad</key><true/>
</dict></plist>
EOF
  chown root:wheel "$PLIST"
  chmod 644 "$PLIST"
  launchctl bootout "system/$LABEL" 2>/dev/null || true
  launchctl bootstrap system "$PLIST"
  sleep 1
  ls -l /var/run/docker.sock
  ;;
remove)
  launchctl bootout "system/$LABEL" 2>/dev/null || true
  rm -f "$PLIST"
  echo "removed $PLIST (the /var/run/docker.sock symlink stays until reboot)"
  ;;
*)
  echo "usage: sudo $0 install|remove" >&2
  exit 2
  ;;
esac
