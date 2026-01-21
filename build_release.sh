#!/bin/bash

# Build release APK
echo "Building release APK..."
flutter build apk --release

# Get version from pubspec.yaml
VERSION=$(grep '^version:' pubspec.yaml | sed 's/version: //' | tr -d ' ')

# Copy and rename the APK
if [ -f "build/app/outputs/flutter-apk/app-release.apk" ]; then
    cp build/app/outputs/flutter-apk/app-release.apk "megapos-v${VERSION}.apk"
    echo "✅ APK created: megapos-v${VERSION}.apk"
else
    echo "❌ APK build failed"
    exit 1
fi

# Build app bundle
echo ""
echo "Building release App Bundle..."
flutter build appbundle --release

# Copy and rename the AAB
if [ -f "build/app/outputs/bundle/release/app-release.aab" ]; then
    cp build/app/outputs/bundle/release/app-release.aab "megapos-v${VERSION}.aab"
    echo "✅ App Bundle created: megapos-v${VERSION}.aab"
else
    echo "❌ App Bundle build failed"
    exit 1
fi

echo ""
echo "🎉 Release build complete!"
echo "   APK: megapos-v${VERSION}.apk"
echo "   AAB: megapos-v${VERSION}.aab"
