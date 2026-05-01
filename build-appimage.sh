#!/bin/bash

# Tasks.org AppImage Builder
# Creates a self-contained AppImage with bundled JRE for Linux distribution
# Usage: ./create-appimage.sh
# Requires: Java (OpenJDK), appimagetool, ImageMagick

set -e

echo "=== Creating Tasks.org AppImage ==="

# Get the directory of this script
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

# Detect architecture
ARCH=$(uname -m)
case "$ARCH" in
    x86_64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="aarch64" ;;
    *) echo "Unsupported architecture: $ARCH"; exit 1 ;;
esac
echo "Detected architecture: $ARCH"

# Build the desktop fat JAR
echo "Building desktop fat JAR..."
./gradlew :composeApp:packageUberJarForCurrentOS -Prelease

# Extract version
VERSION=$(grep "versionName" gradle/libs.versions.toml | head -1 | cut -d'=' -f2 | tr -d ' "' | cut -d'#' -f1 | tr -d ' ')

# Try to find the actual JAR file that was built
JAR_FILE=$(ls composeApp/build/compose/jars/tasks-org-linux-x64-*.jar | head -1)
if [ -z "$JAR_FILE" ]; then
    echo "Error: No JAR file found in composeApp/build/compose/jars/"
    exit 1
fi

# Extract the actual version from the JAR filename
ACTUAL_VERSION=$(basename "$JAR_FILE" | sed 's/tasks-org-linux-x64-//' | sed 's/.jar//')
echo "Version from file: $ACTUAL_VERSION"

# Remove signature files from fat JAR to avoid security issues
echo "Removing signature files from JAR..."
cp "$JAR_FILE" /tmp/tasks-temp.jar
cd /tmp
zip -d tasks-temp.jar "META-INF/*.SF" "META-INF/*.RSA" "META-INF/*.DSA"
cd "$SCRIPT_DIR"
cp /tmp/tasks-temp.jar "$JAR_FILE"
VERSION="$ACTUAL_VERSION"
echo "Version: $VERSION"

# Create AppDir structure
APP_DIR="appimage/tasks-org-${VERSION}-linux-${ARCH}.AppDir"
echo "Creating AppDir: $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/usr/bin"
mkdir -p "$APP_DIR/usr/lib"
mkdir -p "$APP_DIR/usr/share/applications"
mkdir -p "$APP_DIR/usr/share/icons/hicolor/256x256/apps"
mkdir -p "$APP_DIR/usr/share/doc"

# Bundle Java runtime
echo "Bundling Java runtime..."
if [ -z "$JAVA_HOME" ]; then
    JAVA_BIN=$(which java)
    if [ -z "$JAVA_BIN" ]; then
        echo "Error: Java not found. Please install Java."
        exit 1
    fi
    JAVA_HOME=$(dirname "$(dirname "$(readlink -f "$JAVA_BIN")")")
fi

# Verify we have a valid Java installation
if [ ! -x "$JAVA_HOME/bin/java" ]; then
    echo "ERROR: Invalid Java installation at $JAVA_HOME"
    exit 1
fi

# Verify this is OpenJDK for licensing compliance
if ! "$JAVA_HOME/bin/java" -version 2>&1 | grep -qi "openjdk"; then
    echo "ERROR: Only OpenJDK is supported for distribution to avoid licensing issues."
    echo "Please install OpenJDK and ensure JAVA_HOME points to it."
    exit 1
else
    echo "Using Java: $JAVA_HOME"
fi

# Check for required tools
if ! command -v appimagetool &> /dev/null; then
    echo "ERROR: appimagetool not found."
    exit 1
fi

if ! command -v convert &> /dev/null; then
    echo "ERROR: ImageMagick not found (required for icon processing)."
    exit 1
fi

# Get Java version for version checking
JAVA_VERSION=$("$JAVA_HOME/bin/java" -version 2>&1 | grep -i version | awk '{print $3}' | tr -d '"' | cut -d'.' -f1)

# Extract required Java version from Gradle configuration
REQUIRED_VERSION_FILE="composeApp/build.gradle.kts"
if [ ! -f "$REQUIRED_VERSION_FILE" ]; then
    echo "ERROR: Cannot find Gradle configuration file: $REQUIRED_VERSION_FILE"
    exit 1
fi

REQUIRED_VERSION=$(grep "JavaVersion.VERSION" "$REQUIRED_VERSION_FILE" | head -1 | sed 's/.*VERSION_//' | sed 's/[^0-9].*//')
if [ -z "$REQUIRED_VERSION" ]; then
    echo "ERROR: Cannot determine required Java version from $REQUIRED_VERSION_FILE"
    exit 1
fi

echo "Detected required Java version: $REQUIRED_VERSION"

# Check minimum Java version requirement
if [ "$JAVA_VERSION" -lt "$REQUIRED_VERSION" ]; then
    echo "ERROR: Java version $JAVA_VERSION is too old. Tasks.org requires Java $REQUIRED_VERSION or higher."
    echo "Please install a newer version of OpenJDK."
    exit 1
else
    echo "Using Java: $JAVA_HOME (version $JAVA_VERSION)"
fi

# Copy Java runtime
cp -r "$JAVA_HOME" "$APP_DIR/usr/lib/jre"

# Copy license files (required for GPL compliance)
if [ -f "$JAVA_HOME/LICENSE" ]; then
    cp "$JAVA_HOME/LICENSE" "$APP_DIR/usr/share/doc/java-license.txt"
fi

if [ -f "$JAVA_HOME/ASSEMBLY_EXCEPTION" ]; then
    cp "$JAVA_HOME/ASSEMBLY_EXCEPTION" "$APP_DIR/usr/share/doc/java-assembly-exception.txt"
fi

# Copy fat JAR
cp "$JAR_FILE" "$APP_DIR/usr/lib/tasks-org.jar"

# Create wrapper script (uses bundled JRE)
cat > "$APP_DIR/usr/bin/tasks-org" << 'EOF'
#!/bin/bash

# Use the bundled JRE
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && cd .. && pwd )"
JAVA="$DIR/lib/jre/bin/java"

# Verify JRE exists
if [ ! -f "$JAVA" ]; then
    echo "Error: Bundled Java Runtime Environment not found."
    exit 1
fi

# Run the application
exec "$JAVA" -jar "$DIR/lib/tasks-org.jar" "$@"
EOF
chmod +x "$APP_DIR/usr/bin/tasks-org"

# Create desktop file
cat > "$APP_DIR/usr/share/applications/tasks-org.desktop" << EOF
[Desktop Entry]
Name=Tasks.org
Exec=tasks-org
Icon=tasks-org
Terminal=false
Type=Application
Categories=Office;
StartupWMClass=Tasks.org
Comment=Task management application
EOF

# Resize and copy icon
convert graphics/icon.png -resize 256x256 "$APP_DIR/usr/share/icons/hicolor/256x256/apps/tasks-org.png"

# Create AppRun
cat > "$APP_DIR/AppRun" << 'EOF'
#!/bin/bash
here="$(dirname "$(readlink -f "${0}")")"
exec "${here}/usr/bin/tasks-org" "$@"
EOF
chmod +x "$APP_DIR/AppRun"

# Create required symlinks for appimagetool
cd "$APP_DIR"
ln -sf usr/share/applications/tasks-org.desktop .
ln -sf usr/share/icons/hicolor/256x256/apps/tasks-org.png .
cd "$SCRIPT_DIR"

# Create AppImage
echo "Creating AppImage..."
mkdir -p appimage
OUTPUT="appimage/tasks-org-${VERSION}-linux-${ARCH}.AppImage"
appimagetool --no-appstream "$APP_DIR" "$OUTPUT"

echo "=== AppImage created: $OUTPUT ==="
ls -lh "$OUTPUT"
