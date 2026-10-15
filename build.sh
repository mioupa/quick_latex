#!/usr/bin/env bash
# Build Quick LaTeX into build/QuickLaTeX.app (ad-hoc signed).
#   ./build.sh           build the app
#   ./build.sh install   also copy it to ~/Applications
#   ./build.sh vscode    also bundle the CLI into vscode-extension/, package build/quick-latex.vsix and
#                        install it into VS Code (native build for this Mac)
#   ./build.sh release   build a UNIVERSAL (arm64 + x86_64) CLI and package build/quick-latex.vsix for
#                        distribution (e.g. GitHub Releases). Does not build the app and does not install.
#                        NEEDS FULL XCODE (xcode-select -s /Applications/Xcode.app/Contents/Developer): a
#                        universal build is not possible with the Command Line Tools alone. The other modes
#                        work with the Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")"

MODE="${1:-}"
EXT=vscode-extension
# Unversioned name on purpose: .../releases/latest/download/quick-latex.vsix stays a stable URL.
VSIX="$PWD/build/quick-latex.vsix"

# package_vsix <binary> [require-universal]
# Bundle the CLI into the extension, re-sign it standalone (the bundle signature does not apply once the
# executable is copied out of the .app) and package build/quick-latex.vsix.
package_vsix() {
    local bin="$1" universal="${2:-}"
    mkdir -p "$EXT/bin" build
    cp "$bin" "$EXT/bin/quicklatex"
    chmod 755 "$EXT/bin/quicklatex"
    codesign --force --sign - "$EXT/bin/quicklatex"
    if [ "$universal" = "universal" ]; then
        local archs
        archs="$(lipo -archs "$EXT/bin/quicklatex")"
        echo "bundled binary architectures: $archs"
        case " $archs " in
            *" arm64 "*) ;;
            *) echo "error: the bundled binary has no arm64 slice ($archs)" >&2; return 1 ;;
        esac
        case " $archs " in
            *" x86_64 "*) ;;
            *) echo "error: the bundled binary has no x86_64 slice ($archs)" >&2; return 1 ;;
        esac
    fi
    rm -f "$VSIX"
    (cd "$EXT" && npx --yes @vscode/vsce package --allow-missing-repository --no-dependencies -o "$VSIX")
}

if [ "$MODE" = "release" ]; then
    UNIVERSAL_ARGS=(--arch arm64 --arch x86_64)
    swift build -c release "${UNIVERSAL_ARGS[@]}"
    UBIN="$(swift build -c release "${UNIVERSAL_ARGS[@]}" --show-bin-path)/QuickLaTeX"
    package_vsix "$UBIN" universal
    echo "release vsix: $VSIX ($(du -h "$VSIX" | cut -f1))"
    echo "not installed; upload it to the GitHub release as quick-latex.vsix"
    exit 0
fi

APP=build/QuickLaTeX.app

# Native (non-universal) build. Swift 6.4's default "swiftbuild" backend fails on some machines with
# "Could not initialize build system ... Unknown error parsing property list": retry once with the
# classic SwiftPM backend. The flag is only added on the retry (very old toolchains do not know it).
BUILD_SYSTEM_FLAGS=""
if ! swift build -c release; then
    echo "note: swift build failed; retrying with --build-system native" >&2
    BUILD_SYSTEM_FLAGS="--build-system native"
    swift build -c release $BUILD_SYSTEM_FLAGS
fi
BIN="$(swift build -c release $BUILD_SYSTEM_FLAGS --show-bin-path)/QuickLaTeX"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/QuickLaTeX"

# Optional app icon (generated once, skipped silently on failure).
ICON_PLIST=""
if [ ! -f build/AppIcon.icns ]; then
    rm -rf build/AppIcon.iconset
    if swift scripts/make_icon.swift build/AppIcon.iconset >/dev/null 2>&1 \
        && iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns >/dev/null 2>&1; then
        :
    else
        echo "note: icon generation skipped"
        rm -f build/AppIcon.icns
    fi
fi
if [ -f build/AppIcon.icns ]; then
    cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
    ICON_PLIST="    <key>CFBundleIconFile</key>
    <string>AppIcon</string>"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>local.quicklatex</string>
    <key>CFBundleName</key>
    <string>Quick LaTeX</string>
    <key>CFBundleDisplayName</key>
    <string>Quick LaTeX</string>
    <key>CFBundleExecutable</key>
    <string>QuickLaTeX</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleDevelopmentRegion</key>
    <string>ja</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>ja</string>
        <string>en</string>
    </array>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
${ICON_PLIST}
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "built: $APP"

if [ "$MODE" = "install" ]; then
    mkdir -p "$HOME/Applications"
    rm -rf "$HOME/Applications/QuickLaTeX.app"
    cp -R "$APP" "$HOME/Applications/QuickLaTeX.app"
    echo "installed: $HOME/Applications/QuickLaTeX.app"
fi

if [ "$MODE" = "vscode" ]; then
    if package_vsix "$APP/Contents/MacOS/QuickLaTeX"; then
        CODE_BIN="$(command -v code || true)"
        [ -z "$CODE_BIN" ] && [ -x /opt/homebrew/bin/code ] && CODE_BIN=/opt/homebrew/bin/code
        [ -z "$CODE_BIN" ] && [ -x "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code" ] \
            && CODE_BIN="/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"
        if [ -n "$CODE_BIN" ] && "$CODE_BIN" --install-extension "$VSIX" --force; then
            echo "installed VS Code extension from $VSIX (reload the VS Code window)"
        else
            echo "packaged $VSIX, but 'code --install-extension' failed: install it from VS Code (Extensions: Install from VSIX...)"
        fi
    else
        # vsce could not be fetched/run: install by copying the extension folder.
        VERSION="$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$EXT/package.json" | head -1)"
        DEST="$HOME/.vscode/extensions/local.quick-latex-$VERSION"
        echo "note: vsce unavailable; falling back to copying the extension folder to $DEST"
        rm -rf "$DEST"
        mkdir -p "$DEST"
        (cd "$EXT" && tar --exclude=./test -cf - .) | (cd "$DEST" && tar -xf -)
        echo "installed by copy (reload the VS Code window)"
    fi
fi
