#!/bin/bash
set -euo pipefail

echo "Building release APK..."
flutter build apk --release

# Read app version from pubspec.yaml
VERSION="$(awk '/^version:/{gsub(/[[:space:]]/, "", $2); print $2; exit}' pubspec.yaml)"
if [ -z "${VERSION}" ]; then
  echo "❌ Could not read version from pubspec.yaml"
  exit 1
fi

APK_SOURCE="build/app/outputs/flutter-apk/app-release.apk"
APK_TARGET="megapos-v${VERSION}.apk"

if [ ! -f "${APK_SOURCE}" ]; then
  echo "❌ APK build output not found at ${APK_SOURCE}"
  exit 1
fi

cp "${APK_SOURCE}" "${APK_TARGET}"

echo ""
echo "✅ Release build complete"
echo "   APK: ${APK_TARGET}"
