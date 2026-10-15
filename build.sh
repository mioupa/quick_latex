#!/usr/bin/env bash
# Build Quick LaTeX into build/QuickLaTeX.app (ad-hoc signed).
#   ./build.sh           build the app
#   ./build.sh install   also copy it to ~/Applications
#   ./build.sh vscode    also bundle the CLI into vscode-extension/, package a vsix and install it into VS Code
set -euo pipefail
cd "$(dirname "$0")"

APP=build/QuickLaTeX.app
swift build -c release
BIN="$(swift build -c release --show-bin-path)/QuickLaTeX"

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

if [ "${1:-}" = "install" ]; then
    mkdir -p "$HOME/Applications"
    rm -rf "$HOME/Applications/QuickLaTeX.app"
    cp -R "$APP" "$HOME/Applications/QuickLaTeX.app"
    echo "installed: $HOME/Applications/QuickLaTeX.app"
fi

if [ "${1:-}" = "vscode" ]; then
    ROOT="$PWD"
    EXT=vscode-extension
    VSIX="$ROOT/build/quick-latex.vsix"

    # Bundle the CLI (the app's own binary) and re-sign it standalone: the bundle signature does not apply
    # once the executable is copied out of the .app.
    mkdir -p "$EXT/bin"
    cp "$APP/Contents/MacOS/QuickLaTeX" "$EXT/bin/quicklatex"
    chmod 755 "$EXT/bin/quicklatex"
    codesign --force --sign - "$EXT/bin/quicklatex"

    rm -f "$VSIX"
    if (cd "$EXT" && npx --yes @vscode/vsce package --allow-missing-repository --no-dependencies -o "$VSIX"); then
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
