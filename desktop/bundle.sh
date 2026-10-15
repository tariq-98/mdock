#!/bin/sh
# Packages "mdock Desktop.app": the SwiftUI app, the mdock CLI/daemon and the
# from-source GPU stack (libkrun, virglrenderer, gvproxy), then installs it to ~/Applications.
# MoltenVK and libepoxy are loaded from Homebrew (brew install molten-vk libepoxy).
set -eu
cd "$(dirname "$0")/.."
ROOT=$(pwd)
APP="$ROOT/dist/mdock Desktop.app"

[ -f gpu/prefix/lib/libkrun.dylib ] || gpu/build.sh
[ -x accel/media/prefix/bin/ffmpeg ] || accel/media/build-ffmpeg.sh
[ -x accel/llm/prefix/bin/llama-server ] || accel/llm/build.sh
./build.sh   # also signs .build/release/mdock with its entitlements
for svc in mdock-vt mdock-ml mdock-llm; do
  swift build -c release --product "$svc" --build-path ".build-$svc"
done

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS/gpu/lib" "$APP/Contents/MacOS/gpu/bin" "$APP/Contents/Resources"
cp .build/release/MdockDesktop "$APP/Contents/MacOS/"
cp .build/release/mdock "$APP/Contents/MacOS/"
cp gpu/prefix/bin/gvproxy "$APP/Contents/MacOS/gpu/bin/"

# Accelerator bridge services (accel/CONTRACT.md) and their native helpers.
for svc in mdock-vt mdock-ml mdock-llm; do cp ".build-$svc/release/$svc" "$APP/Contents/MacOS/"; done
cp accel/llm/prefix/bin/llama-server accel/llm/prefix/bin/ggml-rpc-server "$APP/Contents/MacOS/"

# jellyfin-ffmpeg for the media-exec bridge, made relocatable (Contents/MacOS/media/{bin,lib}).
MEDIA="$APP/Contents/MacOS/media"
mkdir -p "$MEDIA/bin" "$MEDIA/lib"
OLDLIB="$ROOT/accel/media/prefix/lib"
for lib in "$OLDLIB"/lib*.dylib; do
  name=$(basename "$lib")
  case "$name" in lib*.[0-9]*.[0-9]*.dylib|lib*[!0-9].dylib) continue ;; esac   # keep libfoo.N.dylib only
  cp -L "$lib" "$MEDIA/lib/$name"
done
cp accel/media/prefix/bin/ffmpeg accel/media/prefix/bin/ffprobe "$MEDIA/bin/"
for f in "$MEDIA"/bin/* "$MEDIA"/lib/*.dylib; do
  case "$f" in *.dylib) install_name_tool -id "@loader_path/$(basename "$f")" "$f"; rel="@loader_path" ;; *) rel="@loader_path/../lib" ;; esac
  for dep in $(otool -L "$f" | awk -v old="$OLDLIB/" 'index($1, old) == 1 {print $1}'); do
    install_name_tool -change "$dep" "$rel/$(basename "$dep")" "$f"
  done
done
cp gpu/prefix/lib/libkrun.dylib gpu/prefix/lib/libvirglrenderer.1.dylib "$APP/Contents/MacOS/gpu/lib/"
[ -f desktop/AppIcon.icns ] && cp desktop/AppIcon.icns "$APP/Contents/Resources/"
# The box artwork the app shows in its windows and turns into its menu bar glyph.
cp desktop/Box.png "$APP/Contents/Resources/"
# The guest's own programs (linux/arm64 ELFs, so resources rather than signed executables): the
# bridges' guest side, FEX (x86 with hardware TSO on mdock's kernel) and QEMU user-mode (x86 without).
[ -f guest/out/mdock-guestd ] && [ -f guest/out/FEXInterpreter ] && [ -f guest/out/qemu-x86_64 ] && [ -f guest/out/qemu-i386 ] || guest/build.sh
cp guest/out/mdock-guestd guest/out/FEXInterpreter guest/out/qemu-x86_64 guest/out/qemu-i386 "$APP/Contents/Resources/"
# mdock's guest kernel (hardware TSO for x86 translators), when built (kernel/build.sh takes a while):
# `mdock kernel install` puts it in the guest.
if [ -f kernel/out/Image ]; then
  mkdir -p "$APP/Contents/Resources/kernel"
  cp kernel/out/Image kernel/out/modules.tar.gz kernel/out/release "$APP/Contents/Resources/kernel/"
fi

# Make the GPU libraries relocatable: libkrun finds virglrenderer next to itself.
LIB="$APP/Contents/MacOS/gpu/lib"
install_name_tool -id @loader_path/libvirglrenderer.1.dylib "$LIB/libvirglrenderer.1.dylib"
OLD=$(otool -L "$LIB/libkrun.dylib" | awk '/libvirglrenderer/{print $1}')
install_name_tool -change "$OLD" @loader_path/libvirglrenderer.1.dylib "$LIB/libkrun.dylib"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>dev.mdock.desktop</string>
    <key>CFBundleName</key><string>mdock Desktop</string>
    <key>CFBundleDisplayName</key><string>mdock Desktop</string>
    <key>CFBundleExecutable</key><string>MdockDesktop</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.2.0</string>
    <key>CFBundleVersion</key><string>2</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signatures, inside out. The CLI/daemon needs the virtualization + hypervisor entitlements.
for f in "$LIB"/*.dylib "$APP/Contents/MacOS/gpu/bin/gvproxy" "$MEDIA"/lib/*.dylib "$MEDIA"/bin/* \
         "$APP"/Contents/MacOS/mdock-* "$APP"/Contents/MacOS/llama-server "$APP"/Contents/MacOS/ggml-rpc-server; do
  codesign --force --sign - "$f"
done
codesign --force --sign - --entitlements mdock.entitlements "$APP/Contents/MacOS/mdock"
codesign --force --sign - "$APP"

mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/mdock Desktop.app"
# Moved, not copied: a second copy in dist/ shows up in Spotlight and Launchpad as a duplicate app.
mv "$APP" "$HOME/Applications/"
echo "Installed $HOME/Applications/mdock Desktop.app"
