#!/usr/bin/env bash
# Keep release filenames and payload layout in one place for local builds and CI.
set -euo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$REPO_DIR/zig-out"
OUTPUT_DIR="$BUILD_DIR/packages"
SKILLS_SOURCE="$REPO_DIR/skills"
PLATFORM=""
TMP_DIR=""
cleanup() { [[ -z "$TMP_DIR" ]] || rm -rf -- "$TMP_DIR"; }
trap cleanup EXIT
error() { printf 'Error: %s\n' "$*" >&2; exit 1; }
require() { command -v "$1" >/dev/null 2>&1 || error "Required command not found: $1"; }

usage() {
    cat <<'HELP'
Usage: scripts/package.sh [options]

  --platform TARGET    linux-amd64, linux-arm64, macos-arm64, or macos-amd64
                       (default: current host)
  --build-dir PATH     Existing build output (default: zig-out)
  --output-dir PATH    Archive destination (default: zig-out/packages)
  --skills-source PATH Packaged agent skills (default: repo skills/)
  --help               Show this help

Produces a platform archive and adjacent .sha256 checksum. Archives contain
an app bundle or binary, all runtime share data, skills, and install.sh.
HELP
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h) usage; exit 0 ;;
        --platform|--build-dir|--output-dir|--skills-source)
            [[ $# -ge 2 && -n "$2" ]] || error "$1 requires a value"
            case "$1" in
                --platform) PLATFORM="$2" ;;
                --build-dir) BUILD_DIR="$2" ;;
                --output-dir) OUTPUT_DIR="$2" ;;
                --skills-source) SKILLS_SOURCE="$2" ;;
            esac
            shift 2 ;;
        *) error "Unknown option: $1 (see --help)" ;;
    esac
done
if [[ -z "$PLATFORM" ]]; then
    case "$(uname -s)" in
        Darwin) PLATFORM=macos ;;
        Linux) PLATFORM=linux ;;
        *) error "Unsupported operating system: $(uname -s)" ;;
    esac
    case "$(uname -m)" in
        x86_64|amd64) PLATFORM="$PLATFORM-amd64" ;;
        arm64|aarch64) PLATFORM="$PLATFORM-arm64" ;;
        *) error "Unsupported architecture: $(uname -m)" ;;
    esac
fi
case "$PLATFORM" in
    linux-amd64|linux-arm64) EXT=tar.gz ;;
    macos-arm64|macos-amd64) EXT=zip ;;
    *) error "Unsupported platform: $PLATFORM" ;;
esac
[[ -d "$BUILD_DIR" ]] || error "Build directory not found: $BUILD_DIR"
BUILD_DIR="$(cd -- "$BUILD_DIR" && pwd)"
[[ -f "$SKILLS_SOURCE/ghostty-terminal-automation/SKILL.md" ]] || error "Missing agent skill in $SKILLS_SOURCE"
case "$PLATFORM" in
    macos-*)
        [[ -x "$BUILD_DIR/Ghostty.app/Contents/MacOS/Ghostty" ]] || error "Missing macOS app executable in $BUILD_DIR/Ghostty.app"
        [[ -d "$BUILD_DIR/Ghostty.app/Contents/Resources" ]] || error "Missing macOS app resources"
        require zip ;;
    linux-*)
        [[ -x "$BUILD_DIR/bin/ghostty-automator" ]] || error "Missing executable in $BUILD_DIR/bin/ghostty-automator"
        [[ -d "$BUILD_DIR/share/ghostty" ]] || error "Missing runtime resources in $BUILD_DIR/share/ghostty"
        require tar ;;
esac
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd -- "$OUTPUT_DIR" && pwd)"
TMP_DIR="$(mktemp -d "$OUTPUT_DIR/.staging.XXXXXX")"
PACKAGE="ghostty-automator-$PLATFORM"
PAYLOAD="$TMP_DIR/$PACKAGE"
mkdir -p "$PAYLOAD"
case "$PLATFORM" in
    macos-*) cp -R "$BUILD_DIR/Ghostty.app" "$PAYLOAD/Ghostty.app" ;;
    linux-*)
        mkdir -p "$PAYLOAD/bin"
        cp "$BUILD_DIR/bin/ghostty-automator" "$PAYLOAD/bin/"
        # Bundled dependencies such as gtk4-layer-shell remain dynamically linked.
        # Preserve SONAME links while leaving development-only static archives out.
        for library in "$BUILD_DIR/lib/"*.so "$BUILD_DIR/lib/"*.so.*; do
            [[ -e "$library" || -L "$library" ]] || continue
            mkdir -p "$PAYLOAD/lib"
            cp -P "$library" "$PAYLOAD/lib/"
        done ;;
esac
[[ ! -d "$BUILD_DIR/share" ]] || cp -R "$BUILD_DIR/share" "$PAYLOAD/share"
cp -R "$SKILLS_SOURCE" "$PAYLOAD/skills"
cp "$REPO_DIR/install.sh" "$PAYLOAD/install.sh"
[[ ! -f "$REPO_DIR/LICENSE" ]] || cp "$REPO_DIR/LICENSE" "$PAYLOAD/LICENSE"
ARCHIVE="$PACKAGE.$EXT"
case "$EXT" in
    zip) (cd "$TMP_DIR" && zip -qr --symlinks "$ARCHIVE" "$PACKAGE") ;;
    tar.gz) (cd "$TMP_DIR" && tar czf "$ARCHIVE" "$PACKAGE") ;;
esac
mv -f -- "$TMP_DIR/$ARCHIVE" "$OUTPUT_DIR/$ARCHIVE"
if command -v sha256sum >/dev/null 2>&1; then
    DIGEST="$(sha256sum "$OUTPUT_DIR/$ARCHIVE" | awk '{print $1}')"
elif command -v shasum >/dev/null 2>&1; then
    DIGEST="$(shasum -a 256 "$OUTPUT_DIR/$ARCHIVE" | awk '{print $1}')"
else
    error "Checksum creation requires sha256sum or shasum"
fi
printf '%s  %s\n' "$DIGEST" "$ARCHIVE" > "$OUTPUT_DIR/$ARCHIVE.sha256"
printf 'Packaged %s\nChecksum %s\n' "$OUTPUT_DIR/$ARCHIVE" "$OUTPUT_DIR/$ARCHIVE.sha256"
