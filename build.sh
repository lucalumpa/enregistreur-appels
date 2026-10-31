#!/bin/zsh
# Compile l'app (Apple Silicon + Intel) et l'installe dans ~/Applications.
# ./build.sh --release : produit aussi build/Enregistreur-d-appels.zip à publier dans les Releases GitHub.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Enregistreur d'appels.app"
VERSION="1.2"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

for ARCH in arm64 x86_64; do
  swiftc -O -swift-version 5 -target $ARCH-apple-macos15.0 \
    Sources/*.swift -o "build/EnregistreurAppels-$ARCH"
done
lipo -create build/EnregistreurAppels-arm64 build/EnregistreurAppels-x86_64 \
  -output "$APP/Contents/MacOS/EnregistreurAppels"
rm build/EnregistreurAppels-arm64 build/EnregistreurAppels-x86_64

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.lucagoudon.EnregistreurAppels</string>
  <key>CFBundleDevelopmentRegion</key><string>fr</string>
  <key>CFBundleLocalizations</key><array><string>fr</string><string>en</string></array>
  <key>CFBundleName</key><string>Enregistreur d'appels</string>
  <key>CFBundleExecutable</key><string>EnregistreurAppels</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Pour enregistrer ta voix pendant les appels.</string>
  <key>NSAudioCaptureUsageDescription</key><string>Pour enregistrer la voix de ton correspondant pendant les appels.</string>
</dict>
</plist>
PLIST

# Textes des fenêtres d'autorisation de macOS, dans la langue du Mac.
mkdir -p "$APP/Contents/Resources/en.lproj" "$APP/Contents/Resources/fr.lproj"
cat > "$APP/Contents/Resources/en.lproj/InfoPlist.strings" <<'STRINGS'
"CFBundleName" = "Call Recorder";
"NSMicrophoneUsageDescription" = "To record your voice during calls.";
"NSAudioCaptureUsageDescription" = "To record the other person's voice during calls.";
STRINGS
cat > "$APP/Contents/Resources/fr.lproj/InfoPlist.strings" <<'STRINGS'
"CFBundleName" = "Enregistreur d'appels";
"NSMicrophoneUsageDescription" = "Pour enregistrer ta voix pendant les appels.";
"NSAudioCaptureUsageDescription" = "Pour enregistrer la voix de ton correspondant pendant les appels.";
STRINGS

if [[ "${1:-}" == "--release" ]]; then
  # Signature « ad hoc » : l'app n'est liée à aucun compte développeur.
  codesign --force --sign - "$APP"
  rm -f build/Enregistreur-d-appels.zip
  ditto -c -k --keepParent "$APP" build/Enregistreur-d-appels.zip
  echo "Release : build/Enregistreur-d-appels.zip"
fi

# Pour ton Mac : une identité stable garde les autorisations (micro, audio système) d'une version à l'autre.
IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ { print $2; exit }')
codesign --force --sign "${IDENTITY:--}" "$APP"

mkdir -p ~/Applications
rm -rf ~/Applications/"Enregistreur d'appels.app"
cp -R "$APP" ~/Applications/
echo "Installé : ~/Applications/Enregistreur d'appels.app"
