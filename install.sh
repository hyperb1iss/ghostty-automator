#!/usr/bin/env bash
# Install a release, local archive, or existing build without elevated privileges.
set -euo pipefail

REPO="hyperb1iss/ghostty-automator"
INSTALL_DIR="${INSTALL_DIR:-$HOME/.local}"
SKILL_DIR="${SKILL_DIR:-$HOME/.agents/skills}"
CLAUDE_SKILL_DIR="${CLAUDE_SKILL_DIR:-$HOME/.claude/skills}"
APP_DIR="${APP_DIR:-$HOME/Applications/Ghostty Automator.app}"
VERSION="${VERSION:-latest}"
ARCHIVE=""
CHECKSUM=""
BUILD_DIR=""
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-install.sh}")" && pwd)"
SKILLS_SOURCE="${SCRIPT_DIR}/skills"
INSTALL_SKILLS=1
SKILLS_ONLY=0
TMP_DIR=""
MARKER=".ghostty-automator-install"

CYAN='' GREEN='' YELLOW='' RED='' RESET=''
if [[ -t 1 && -z "${NO_COLOR+x}" && "${TERM:-}" != dumb ]]; then
    CYAN=$'\033[38;2;128;255;234m'
    GREEN=$'\033[38;2;80;250;123m'
    YELLOW=$'\033[38;2;241;250;140m'
    RED=$'\033[38;2;255;99;99m'
    RESET=$'\033[0m'
fi
info() { printf '%s%s%s\n' "$CYAN" "$*" "$RESET"; }
ok() { printf '%s%s%s\n' "$GREEN" "$*" "$RESET"; }
warn() { printf '%s%s%s\n' "$YELLOW" "$*" "$RESET" >&2; }
error() { printf '%sError: %s%s\n' "$RED" "$*" "$RESET" >&2; exit 1; }
require() { command -v "$1" >/dev/null 2>&1 || error "Required command not found: $1"; }
cleanup() { [[ -z "$TMP_DIR" ]] || rm -rf -- "$TMP_DIR"; }
trap cleanup EXIT

usage() {
    cat <<'HELP'
Usage: bash install.sh [options]

  --version TAG        Install a release tag (default: latest; VERSION)
  --archive PATH       Install a local .tar.gz or .zip without network access
  --checksum PATH      Verify archive against this SHA256 sidecar
  --build-dir PATH     Install an existing zig-out directory without downloading
  --skills-source PATH Use these skills with --build-dir (default: repo skills/)
  --install-dir PATH   User installation prefix (default: ~/.local; INSTALL_DIR)
  --skill-dir PATH     Agent skill directory (default: ~/.agents/skills; SKILL_DIR)
  --app-dir PATH       macOS app destination (default: ~/Applications/Ghostty Automator.app)
  --no-skills          Install only the application and runtime data
  --skills-only        Install the agent skill without building or downloading
  --help               Show this help

Claude discovers a link under ~/.claude/skills (CLAUDE_SKILL_DIR overrides it).
Existing separate Claude skills are preserved. Shell profiles are never edited.
HELP
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h) usage; exit 0 ;;
            --no-skills) INSTALL_SKILLS=0; shift ;;
            --skills-only) SKILLS_ONLY=1; shift ;;
            --version|--archive|--checksum|--build-dir|--skills-source|--install-dir|--skill-dir|--app-dir)
                [[ $# -ge 2 && -n "$2" ]] || error "$1 requires a value"
                case "$1" in
                    --version) VERSION="$2" ;;
                    --archive) ARCHIVE="$2" ;;
                    --checksum) CHECKSUM="$2" ;;
                    --build-dir) BUILD_DIR="$2" ;;
                    --skills-source) SKILLS_SOURCE="$2" ;;
                    --install-dir) INSTALL_DIR="$2" ;;
                    --skill-dir) SKILL_DIR="$2" ;;
                    --app-dir) APP_DIR="$2" ;;
                esac
                shift 2 ;;
            *) error "Unknown option: $1 (see --help)" ;;
        esac
    done
    [[ -z "$ARCHIVE" || -z "$BUILD_DIR" ]] || error "Use --archive or --build-dir, not both"
    [[ -z "$CHECKSUM" || -z "$BUILD_DIR" ]] || error "--checksum requires an archive"
    if [[ "$SKILLS_ONLY" = 1 ]]; then
        [[ "$INSTALL_SKILLS" = 1 && -z "$ARCHIVE" && -z "$BUILD_DIR" && -z "$CHECKSUM" ]] \
            || error "--skills-only cannot be combined with archive, build, checksum, or --no-skills"
    fi
    [[ "$INSTALL_DIR" = /* && "$SKILL_DIR" = /* && "$APP_DIR" = /* ]] \
        || error "Installation destinations must be absolute paths"
}

detect_platform() {
    local os arch
    os="$(uname -s)"
    arch="$(uname -m)"
    case "$os" in
        Darwin) OS=macos ;;
        Linux) OS=linux ;;
        *) error "Unsupported operating system: $os (expected Linux or macOS)" ;;
    esac
    case "$arch" in
        x86_64|amd64) ARCH=amd64 ;;
        arm64|aarch64) ARCH=arm64 ;;
        *) error "Unsupported architecture: $arch (expected x86_64 or arm64)" ;;
    esac
    if [[ "$OS-$ARCH" = macos-amd64 && -z "$BUILD_DIR" && -z "$ARCHIVE" ]]; then
        error "No macOS Intel release is published; build locally and use --build-dir zig-out"
    fi
    PLATFORM="$OS-$ARCH"
    PACKAGE="ghostty-automator-$PLATFORM"
    if [[ "$OS" = macos ]]; then EXT=zip; else EXT=tar.gz; fi
}

sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        error "Checksum verification requires sha256sum or shasum"
    fi
}

verify_archive() {
    local expected actual
    if [[ -z "$CHECKSUM" && -f "$ARCHIVE.sha256" ]]; then CHECKSUM="$ARCHIVE.sha256"; fi
    if [[ -z "$CHECKSUM" ]]; then
        warn "No SHA256 sidecar supplied; installing the archive without checksum verification"
        return
    fi
    [[ -f "$CHECKSUM" ]] || error "Checksum file not found: $CHECKSUM"
    expected="$(awk -v name="$(basename -- "$ARCHIVE")" \
        '$2 == name || $2 == "*" name {print $1; exit}' "$CHECKSUM")"
    [[ "$expected" =~ ^[[:xdigit:]]{64}$ ]] || error "Checksum file has no SHA256 entry for $(basename -- "$ARCHIVE")"
    actual="$(sha256 "$ARCHIVE")"
    [[ "$actual" = "$(printf '%s' "$expected" | tr '[:upper:]' '[:lower:]')" ]] || error "SHA256 mismatch for $(basename -- "$ARCHIVE"); nothing installed"
    ok "Verified SHA256 checksum"
}

download_archive() {
    require curl
    local url status
    if [[ "$VERSION" = latest ]]; then
        url="https://github.com/$REPO/releases/latest/download"
    else
        url="https://github.com/$REPO/releases/download/v${VERSION#v}"
    fi
    ARCHIVE="$TMP_DIR/$PACKAGE.$EXT"
    info "Downloading $PACKAGE.$EXT"
    curl -fLsS -o "$ARCHIVE" "$url/$PACKAGE.$EXT" \
        || error "Release archive unavailable: $url/$PACKAGE.$EXT"
    if [[ -z "$CHECKSUM" ]]; then
        status="$(curl -LsS -w '%{http_code}' -o "$ARCHIVE.sha256" "$url/$PACKAGE.$EXT.sha256")" \
            || error "Could not download release checksum"
        case "$status" in
            200) CHECKSUM="$ARCHIVE.sha256" ;;
            404) rm -f -- "$ARCHIVE.sha256" ;;
            *) error "Could not download release checksum (HTTP $status)" ;;
        esac
    fi
}

extract_archive() {
    [[ -f "$ARCHIVE" ]] || error "Archive not found: $ARCHIVE"
    verify_archive
    mkdir -p "$TMP_DIR/extract"
    case "$ARCHIVE" in
        *.tar.gz) require tar; tar tzf "$ARCHIVE" > "$TMP_DIR/entries" ;;
        *.zip) require unzip; unzip -Z1 "$ARCHIVE" > "$TMP_DIR/entries" ;;
        *) error "Unsupported archive format: $ARCHIVE (expected .tar.gz or .zip)" ;;
    esac
    while IFS= read -r entry; do
        case "/$entry/" in
            *'/../'*|//* ) error "Unsafe archive entry: $entry" ;;
        esac
    done < "$TMP_DIR/entries"
    case "$ARCHIVE" in
        *.tar.gz) tar xzf "$ARCHIVE" -C "$TMP_DIR/extract" ;;
        *.zip) unzip -q "$ARCHIVE" -d "$TMP_DIR/extract" ;;
    esac
    # Accept previous flat macOS packages as well as canonical nested releases.
    PAYLOAD="$TMP_DIR/extract/$PACKAGE"
    [[ -d "$PAYLOAD" ]] || PAYLOAD="$TMP_DIR/extract"
    SKILLS_SOURCE="$PAYLOAD/skills"
}

validate_payload() {
    if [[ "$OS" = macos ]]; then
        [[ -x "$PAYLOAD/Ghostty.app/Contents/MacOS/Ghostty" ]] \
            || error "Missing app executable: Ghostty.app/Contents/MacOS/Ghostty"
        [[ -d "$PAYLOAD/Ghostty.app/Contents/Resources" ]] || error "Missing app resources"
    else
        [[ -x "$PAYLOAD/bin/ghostty-automator" ]] || error "Missing executable: bin/ghostty-automator"
        [[ -d "$PAYLOAD/share/ghostty" ]] || error "Missing runtime resources: share/ghostty"
    fi
    if [[ "$INSTALL_SKILLS" = 1 ]]; then
        [[ -f "$SKILLS_SOURCE/ghostty-terminal-automation/SKILL.md" ]] \
            || error "Missing packaged skill: ghostty-terminal-automation/SKILL.md (or use --no-skills)"
    fi
    local preflight_output
    if [[ "$OS" = macos ]]; then
        if ! preflight_output="$(unset GHOSTTY_RESOURCES_DIR; "$PAYLOAD/Ghostty.app/Contents/MacOS/Ghostty" +help 2>&1)"; then
            error "The packaged executable cannot run; nothing installed: $preflight_output"
        fi
    else
        if ! preflight_output="$(GHOSTTY_RESOURCES_DIR="$PAYLOAD/share/ghostty" \
            LD_LIBRARY_PATH="$PAYLOAD/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
            "$PAYLOAD/bin/ghostty-automator" +help 2>&1)"; then
            error "The packaged executable cannot run; nothing installed: $preflight_output"
        fi
    fi
}

install_payload() {
    local runtime stage previous app_stage app_previous launcher executable
    runtime="$INSTALL_DIR/lib/ghostty-automator"
    if [[ -e "$runtime" || -L "$runtime" ]]; then
        [[ -d "$runtime" && ! -L "$runtime" && -f "$runtime/$MARKER" ]] \
            || error "Refusing to replace an unmanaged runtime directory: $runtime"
    fi
    if [[ "$OS" = macos && ( -e "$APP_DIR" || -L "$APP_DIR" ) ]]; then
        [[ -d "$APP_DIR" && ! -L "$APP_DIR" && -f "$APP_DIR.$MARKER" ]] \
            || error "Refusing to replace an unmanaged app: $APP_DIR (choose --app-dir)"
    fi
    mkdir -p "$INSTALL_DIR/lib" "$INSTALL_DIR/bin"
    stage="$(mktemp -d "$INSTALL_DIR/lib/.ghostty-automator.XXXXXX")"
    [[ ! -d "$PAYLOAD/share" ]] || cp -R "$PAYLOAD/share" "$stage/share"
    [[ ! -d "$SKILLS_SOURCE" ]] || cp -R "$SKILLS_SOURCE" "$stage/skills"
    printf '%s\n' 'ghostty-automator installer v1' > "$stage/$MARKER"
    if [[ "$OS" = macos ]]; then
        mkdir -p "$(dirname -- "$APP_DIR")"
        app_stage="$(mktemp -d "$(dirname -- "$APP_DIR")/.ghostty-automator.XXXXXX")"
        cp -R "$PAYLOAD/Ghostty.app" "$app_stage/app"
        app_previous="$app_stage/previous"
        if [[ -d "$APP_DIR" ]]; then mv "$APP_DIR" "$app_previous"; fi
        if ! mv "$app_stage/app" "$APP_DIR"; then
            [[ ! -d "$app_previous" ]] || mv "$app_previous" "$APP_DIR"
            error "Could not install app at $APP_DIR"
        fi
        printf '%s\n' 'ghostty-automator installer v1' > "$APP_DIR.$MARKER"
        rm -rf -- "$app_stage"
        executable="$APP_DIR/Contents/MacOS/Ghostty"
    else
        cp -R "$PAYLOAD/bin" "$stage/bin"
        [[ ! -d "$PAYLOAD/lib" ]] || cp -R "$PAYLOAD/lib" "$stage/lib"
        executable="$runtime/bin/ghostty-automator"
    fi
    previous="$stage/previous"
    if [[ -d "$runtime" ]]; then mv "$runtime" "$previous"; fi
    if ! mv "$stage" "$runtime"; then
        [[ ! -d "$previous" ]] || mv "$previous" "$runtime"
        error "Could not install runtime at $runtime"
    fi
    # The previous version was installer-owned and is now inside our new runtime.
    rm -rf -- "$runtime/previous"
    launcher="$(mktemp "$INSTALL_DIR/bin/.ghostty-automator.XXXXXX")"
    {
        printf '%s\n' '#!/usr/bin/env bash'
        # Avoid inheriting stock Ghostty resources in a terminal launched by it.
        if [[ "$OS" = linux ]]; then
            printf 'export GHOSTTY_RESOURCES_DIR=%q\n' "$runtime/share/ghostty"
            if [[ -d "$runtime/lib" ]]; then
                # Keep inherited library search paths after the bundled dependencies.
                # shellcheck disable=SC2016
                printf 'export LD_LIBRARY_PATH=%q"${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"\n' "$runtime/lib"
            fi
        else
            printf '%s\n' 'unset GHOSTTY_RESOURCES_DIR'
        fi
        printf 'export GHOSTTY_AUTOMATOR_SKILLS_DIR=%q\n' "$runtime/skills"
        printf 'export GHOSTTY_AUTOMATOR_LAUNCHER=%q\n' "$INSTALL_DIR/bin/ghostty-automator"
        printf 'exec %q "$@"\n' "$executable"
    } > "$launcher"
    chmod 755 "$launcher"
    mv -f -- "$launcher" "$INSTALL_DIR/bin/ghostty-automator"
    ok "Installed command: $INSTALL_DIR/bin/ghostty-automator"
    [[ "$OS" != macos ]] || ok "Installed app: $APP_DIR"
}

install_skills() {
    [[ "$INSTALL_SKILLS" = 1 ]] || return 0
    local dest claude_dest
    dest="$SKILL_DIR/ghostty-terminal-automation"
    mkdir -p "$dest"
    if [[ "$(cd -- "$SKILLS_SOURCE/ghostty-terminal-automation" && pwd -P)" != "$(cd -- "$dest" && pwd -P)" ]]; then
        cp -R "$SKILLS_SOURCE/ghostty-terminal-automation/." "$dest/"
    fi
    ok "Installed agent skill: $dest"
    claude_dest="$CLAUDE_SKILL_DIR/ghostty-terminal-automation"
    if [[ "$claude_dest" != "$dest" ]]; then
        mkdir -p "$CLAUDE_SKILL_DIR"
        if [[ -L "$claude_dest" && "$(readlink "$claude_dest")" = "$dest" ]]; then
            return
        elif [[ -e "$claude_dest" || -L "$claude_dest" ]]; then
            warn "Preserved existing Claude skill: $claude_dest"
        else
            ln -s "$dest" "$claude_dest"
            ok "Linked Claude skill: $claude_dest"
        fi
    fi
}

main() {
    parse_args "$@"
    if [[ "$SKILLS_ONLY" = 1 ]]; then
        [[ -f "$SKILLS_SOURCE/ghostty-terminal-automation/SKILL.md" ]] \
            || error "Missing agent skill in $SKILLS_SOURCE"
        install_skills
        return
    fi
    detect_platform
    TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ghostty-automator-install.XXXXXX")"
    if [[ -n "$BUILD_DIR" ]]; then
        [[ -d "$BUILD_DIR" ]] || error "Build directory not found: $BUILD_DIR"
        PAYLOAD="$(cd -- "$BUILD_DIR" && pwd)"
    else
        [[ -n "$ARCHIVE" ]] || download_archive
        extract_archive
    fi
    validate_payload
    install_payload
    install_skills
    if [[ ":$PATH:" != *":$INSTALL_DIR/bin:"* ]]; then
        warn "Add the command directory to PATH:"
        # Keep the user's PATH expression literal for the shell profile.
        # shellcheck disable=SC2016
        printf '  export PATH=%q:"$PATH"\n' "$INSTALL_DIR/bin"
    fi
    local help_output
    help_output="$("$INSTALL_DIR/bin/ghostty-automator" +help 2>&1)" \
        || error "The installed executable cannot run. Check its shared-library dependencies."
    if [[ "$help_output" = *doctor* && "$help_output" = *bootstrap* ]]; then
        printf '\nReady. Check installation with:\n  %q +doctor\n' "$INSTALL_DIR/bin/ghostty-automator"
    else
        warn "Installed release predates +doctor and +bootstrap."
        warn "Use a current source build or matching archive for automatic startup."
        printf '\nCheck this release with:\n  %q +version\n' "$INSTALL_DIR/bin/ghostty-automator"
    fi
}
main "$@"
