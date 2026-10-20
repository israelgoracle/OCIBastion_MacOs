#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .build/clang-cache .build/cache
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
if [[ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]]; then
  export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
fi
swift build --disable-sandbox --scratch-path .build --cache-path .build/cache
app="dist/OCI Bastion.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp .build/debug/OCIBastion "$app/Contents/MacOS/OCIBastion"
mkdir -p "$app/Contents/Resources"
cp Assets/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp Assets/LaunchITerm.applescript "$app/Contents/Resources/LaunchITerm.applescript"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.local.ocibastion</string>
<key>CFBundleName</key><string>OCI Bastion</string>
<key>CFBundleDisplayName</key><string>OCI Bastion</string>
<key>CFBundleExecutable</key><string>OCIBastion</string>
<key>CFBundleIconFile</key><string>AppIcon.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>2</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSAppleEventsUsageDescription</key><string>OCI Bastion abre conexiones SSH en la aplicación de terminal seleccionada.</string>
</dict></plist>
PLIST
codesign --force --sign - "$app"
touch "$app"
echo "$PWD/$app"
