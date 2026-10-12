#!/usr/bin/env bash
# Exercise complete package/install boundaries with disposable app fixtures.
set -euo pipefail
REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
NATIVE_OS="$(uname -s)"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/ghostty-package-test.XXXXXX")"
trap 'rm -rf -- "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/shims" "$SANDBOX/build/bin" "$SANDBOX/build/share/ghostty" \
    "$SANDBOX/build/share/terminfo/x" "$SANDBOX/skills/ghostty-terminal-automation"
cat > "$SANDBOX/shims/uname" <<'SHIM'
#!/usr/bin/env bash
case "${1:-}" in
    -s) printf '%s\n' "${TEST_OS:-Linux}" ;;
    -m) printf '%s\n' "${TEST_ARCH:-x86_64}" ;;
    *) exit 1 ;;
esac
SHIM
cat > "$SANDBOX/build/bin/ghostty-automator" <<'BINARY'
#!/usr/bin/env bash
printf 'fixture-version-1|%s|%s\n' "$*" "${GHOSTTY_RESOURCES_DIR:-}"
BINARY
chmod +x "$SANDBOX/shims/uname" "$SANDBOX/build/bin/ghostty-automator"
printf 'fixture runtime\n' > "$SANDBOX/build/share/ghostty/config"
printf 'fixture terminfo\n' > "$SANDBOX/build/share/terminfo/x/xterm-ghostty"
printf 'fixture skill\n' > "$SANDBOX/skills/ghostty-terminal-automation/SKILL.md"
export TEST_OS=Linux TEST_ARCH=x86_64
export PATH="$SANDBOX/shims:$PATH"
TEST_HOME="$SANDBOX/home with spaces"
export INSTALL_DIR="$TEST_HOME/.local" SKILL_DIR="$TEST_HOME/.agents/skills"
export CLAUDE_SKILL_DIR="$TEST_HOME/.claude/skills" APP_DIR="$TEST_HOME/Applications/Ghostty Automator.app"
export NO_COLOR=1
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_file() { [[ -f "$1" ]] || fail "missing file: $1"; }
assert_contains() { [[ "$1" = *"$2"* ]] || fail "expected '$2' in '$1'"; }
run_install() { bash "$REPO_DIR/install.sh" "$@" > "$SANDBOX/install.log" 2>&1; }
expect_error() {
    local expected="$1"
    shift
    if run_install "$@"; then fail "installation unexpectedly succeeded: $expected"; fi
    assert_contains "$(cat "$SANDBOX/install.log")" "$expected"
}
package() {
    bash "$REPO_DIR/scripts/package.sh" --build-dir "$SANDBOX/build" \
        --skills-source "$SANDBOX/skills" --output-dir "$SANDBOX/archives" "$@" \
        > "$SANDBOX/package.log"
}

package --platform linux-amd64
LINUX_ARCHIVE="$SANDBOX/archives/ghostty-automator-linux-amd64.tar.gz"
assert_file "$LINUX_ARCHIVE.sha256"
mkdir -p "$INSTALL_DIR/bin" "$INSTALL_DIR/share/stock" "$CLAUDE_SKILL_DIR/other-skill"
printf 'stock binary\n' > "$INSTALL_DIR/bin/ghostty"
printf 'stock resources\n' > "$INSTALL_DIR/share/stock/config"
run_install --archive "$LINUX_ARCHIVE"
assert_contains "$(cat "$SANDBOX/install.log")" 'Verified SHA256 checksum'
assert_file "$INSTALL_DIR/lib/ghostty-automator/share/ghostty/config"
assert_file "$SKILL_DIR/ghostty-terminal-automation/SKILL.md"
[[ -L "$CLAUDE_SKILL_DIR/ghostty-terminal-automation" ]] || fail 'Claude skill is not linked'
assert_contains "$("$INSTALL_DIR/bin/ghostty-automator" +version)" \
    "fixture-version-1|+version|$INSTALL_DIR/lib/ghostty-automator/share/ghostty"
[[ "$(cat "$INSTALL_DIR/bin/ghostty")" = 'stock binary' ]] || fail 'stock binary replaced'
[[ "$(cat "$INSTALL_DIR/share/stock/config")" = 'stock resources' ]] || fail 'stock resources replaced'
[[ "$(cat "$SANDBOX/install.log")" != *$'\033'* ]] || fail 'noninteractive output contains color escapes'
printf 'PASS: Linux nested archive, checksums, runtime, skills, spaces, stock preservation\n'

printf 'user notes\n' > "$SKILL_DIR/ghostty-terminal-automation/local-notes"
sed 's/fixture-version-1/fixture-version-2/' "$SANDBOX/build/bin/ghostty-automator" > "$SANDBOX/binary-new"
cp "$SANDBOX/binary-new" "$SANDBOX/build/bin/ghostty-automator"
package --platform linux-amd64
run_install --archive "$LINUX_ARCHIVE"
assert_contains "$("$INSTALL_DIR/bin/ghostty-automator" +version)" 'fixture-version-2'
assert_file "$SKILL_DIR/ghostty-terminal-automation/local-notes"
[[ ! -e "$INSTALL_DIR/lib/ghostty-automator/previous" ]] || fail 'old runtime retained'
printf 'PASS: repeat install updates binary and preserves unrelated skill files\n'

cp "$LINUX_ARCHIVE" "$SANDBOX/tampered.tar.gz"
# Give the tampered copy a correctly named checksum entry before changing its data.
sed 's/ghostty-automator-linux-amd64.tar.gz/tampered.tar.gz/' "$LINUX_ARCHIVE.sha256" > "$SANDBOX/tampered.tar.gz.sha256"
printf 'corrupt' >> "$SANDBOX/tampered.tar.gz"
expect_error 'SHA256 mismatch' --archive "$SANDBOX/tampered.tar.gz"
assert_contains "$("$INSTALL_DIR/bin/ghostty-automator" +version)" 'fixture-version-2'
expect_error 'Checksum file not found' --archive "$LINUX_ARCHIVE" --checksum "$SANDBOX/missing.sha256"
printf 'PASS: checksum failures stop before replacing a working installation\n'

mkdir -p "$SANDBOX/broken/ghostty-automator-linux-amd64/share/ghostty"
cp -R "$SANDBOX/skills" "$SANDBOX/broken/ghostty-automator-linux-amd64/skills"
(cd "$SANDBOX/broken" && tar czf "$SANDBOX/missing-binary.tar.gz" ghostty-automator-linux-amd64)
expect_error 'Missing executable: bin/ghostty-automator' --archive "$SANDBOX/missing-binary.tar.gz"
expect_error 'Unsupported archive format' --archive "$SANDBOX/build/share/ghostty/config"
expect_error 'Use --archive or --build-dir' --archive "$LINUX_ARCHIVE" --build-dir "$SANDBOX/build"
printf 'PASS: missing assets and invalid options report precise errors\n'

# A build installation does not use curl or release metadata.
run_install --build-dir "$SANDBOX/build" --skills-source "$SANDBOX/skills"
assert_contains "$("$INSTALL_DIR/bin/ghostty-automator" +version)" 'fixture-version-2'
rm "$CLAUDE_SKILL_DIR/ghostty-terminal-automation"
mkdir -p "$CLAUDE_SKILL_DIR/ghostty-terminal-automation"
printf 'custom Claude skill\n' > "$CLAUDE_SKILL_DIR/ghostty-terminal-automation/SKILL.md"
run_install --build-dir "$SANDBOX/build" --skills-source "$SANDBOX/skills"
[[ "$(cat "$CLAUDE_SKILL_DIR/ghostty-terminal-automation/SKILL.md")" = 'custom Claude skill' ]] \
    || fail 'existing separate Claude skill replaced'
assert_contains "$(cat "$SANDBOX/install.log")" 'Preserved existing Claude skill'
run_install --build-dir "$SANDBOX/build" --skills-source "$SANDBOX/no-skills" --no-skills
expect_error 'Missing packaged skill' --build-dir "$SANDBOX/build" --skills-source "$SANDBOX/no-skills"
printf 'PASS: offline build installation and existing Claude skill preservation\n'

mkdir -p "$SANDBOX/linked-skills"
ln -s "$SANDBOX/skills/ghostty-terminal-automation" "$SANDBOX/linked-skills/ghostty-terminal-automation"
INSTALL_DIR="$SANDBOX/skill-only-prefix" SKILL_DIR="$SANDBOX/linked-skills" \
    CLAUDE_SKILL_DIR="$SANDBOX/skill-only-claude" \
    run_install --skills-only --skills-source "$SANDBOX/skills"
[[ ! -e "$SANDBOX/skill-only-prefix" ]] || fail 'skill-only install created a binary prefix'
[[ -L "$SANDBOX/skill-only-claude/ghostty-terminal-automation" ]] || fail 'skill-only Claude link missing'
expect_error '--skills-only cannot be combined' --skills-only --no-skills
printf 'PASS: skill-only install handles source symlinks without a binary or download\n'

# Executable validation must happen before replacing any existing runtime or skill.
mkdir -p "$SANDBOX/invalid-build/bin"
cp -R "$SANDBOX/build/share" "$SANDBOX/invalid-build/share"
cat > "$SANDBOX/invalid-build/bin/ghostty-automator" <<'INVALID'
#!/usr/bin/env bash
printf 'missing fixture dependency\n' >&2
exit 1
INVALID
chmod +x "$SANDBOX/invalid-build/bin/ghostty-automator"
expect_error 'The packaged executable cannot run; nothing installed' \
    --build-dir "$SANDBOX/invalid-build" --skills-source "$SANDBOX/skills"
assert_contains "$(cat "$SANDBOX/install.log")" 'missing fixture dependency'
assert_contains "$("$INSTALL_DIR/bin/ghostty-automator" +version)" 'fixture-version-2'
assert_file "$SKILL_DIR/ghostty-terminal-automation/local-notes"
printf 'PASS: unusable update preserves the working runtime and user skill files\n'

# Exercise main -> helper -> dependency through real ELF loader resolution.
if [[ "$NATIVE_OS" = Linux ]]; then
    command -v cc >/dev/null 2>&1 || fail 'linked-library fixture requires cc'
    LINK_BUILD="$SANDBOX/linked build"
    mkdir -p "$LINK_BUILD/bin" "$LINK_BUILD/lib" "$SANDBOX/linked-sources"
    cp -R "$SANDBOX/build/share" "$LINK_BUILD/share"
    printf 'int fixture_dependency(void) { return 42; }\n' > "$SANDBOX/linked-sources/dependency.c"
    cat > "$SANDBOX/linked-sources/helper.c" <<'HELPER'
int fixture_dependency(void);
int fixture_helper(void) { return fixture_dependency(); }
HELPER
    cat > "$SANDBOX/linked-sources/main.c" <<'MAIN'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
int fixture_helper(void);
int main(int argc, char **argv) {
    if (argc > 1 && strcmp(argv[1], "+help") == 0) {
        puts("doctor bootstrap");
    }
    const char *libraries = getenv("LD_LIBRARY_PATH");
    printf("linked-fixture:%d|%s\n", fixture_helper(), libraries ? libraries : "");
    return 0;
}
MAIN
    cc -shared -fPIC -Wl,-soname,libfixturedep.so.1 "$SANDBOX/linked-sources/dependency.c" \
        -o "$LINK_BUILD/lib/libfixturedep.so.1.0"
    ln -s libfixturedep.so.1.0 "$LINK_BUILD/lib/libfixturedep.so.1"
    ln -s libfixturedep.so.1 "$LINK_BUILD/lib/libfixturedep.so"
    cc -shared -fPIC -Wl,-soname,libfixturehelper.so.1 "$SANDBOX/linked-sources/helper.c" \
        -L"$LINK_BUILD/lib" -lfixturedep -o "$LINK_BUILD/lib/libfixturehelper.so.1.0"
    ln -s libfixturehelper.so.1.0 "$LINK_BUILD/lib/libfixturehelper.so.1"
    ln -s libfixturehelper.so.1 "$LINK_BUILD/lib/libfixturehelper.so"
    cc "$SANDBOX/linked-sources/main.c" -L"$LINK_BUILD/lib" -lfixturehelper \
        -Wl,-rpath-link,"$LINK_BUILD/lib" -o "$LINK_BUILD/bin/ghostty-automator"
    printf 'development-only archive\n' > "$LINK_BUILD/lib/libfixture.a"
    bash "$REPO_DIR/scripts/package.sh" --platform linux-amd64 --build-dir "$LINK_BUILD" \
        --skills-source "$SANDBOX/skills" --output-dir "$SANDBOX/linked-archives" > "$SANDBOX/package.log"
    mv "$LINK_BUILD" "$SANDBOX/hidden-linked-build"
    run_install --archive "$SANDBOX/linked-archives/ghostty-automator-linux-amd64.tar.gz"
    BUNDLED_LIB="$INSTALL_DIR/lib/ghostty-automator/lib"
    [[ -L "$BUNDLED_LIB/libfixturedep.so.1" ]] || fail 'packaged dependency SONAME link missing'
    [[ -L "$BUNDLED_LIB/libfixturehelper.so.1" ]] || fail 'packaged helper SONAME link missing'
    [[ ! -e "$BUNDLED_LIB/libfixture.a" ]] || fail 'development archive was packaged'
    assert_contains "$(LD_LIBRARY_PATH="$SANDBOX/custom libraries" "$INSTALL_DIR/bin/ghostty-automator" +version)" \
        "linked-fixture:42|$BUNDLED_LIB:$SANDBOX/custom libraries"
    assert_contains "$(env -u LD_LIBRARY_PATH "$INSTALL_DIR/bin/ghostty-automator" +version)" \
        "linked-fixture:42|$BUNDLED_LIB"
    if env -u LD_LIBRARY_PATH "$INSTALL_DIR/lib/ghostty-automator/bin/ghostty-automator" \
        +version > "$SANDBOX/bare-binary.log" 2>&1; then
        fail 'bare ELF unexpectedly found uninstalled libraries'
    fi
    printf 'PASS: relocated ELF loads transitive shared libraries and preserves inherited search paths\n'
fi

# The macOS CLI must execute inside its app bundle, with framework links intact.
mkdir -p "$SANDBOX/build/Ghostty.app/Contents/MacOS" \
    "$SANDBOX/build/Ghostty.app/Contents/Resources" \
    "$SANDBOX/build/Ghostty.app/Contents/Frameworks/Fixture.framework/Versions/A"
cp "$SANDBOX/build/bin/ghostty-automator" "$SANDBOX/build/Ghostty.app/Contents/MacOS/Ghostty"
printf 'framework\n' > "$SANDBOX/build/Ghostty.app/Contents/Frameworks/Fixture.framework/Versions/A/Fixture"
ln -s A "$SANDBOX/build/Ghostty.app/Contents/Frameworks/Fixture.framework/Versions/Current"
ln -s Versions/Current/Fixture "$SANDBOX/build/Ghostty.app/Contents/Frameworks/Fixture.framework/Fixture"
package --platform macos-arm64
export TEST_OS=Darwin TEST_ARCH=arm64
MAC_ARCHIVE="$SANDBOX/archives/ghostty-automator-macos-arm64.zip"
mkdir -p "$TEST_HOME/Applications/Ghostty.app"
printf 'stock app\n' > "$TEST_HOME/Applications/Ghostty.app/stock"
run_install --archive "$MAC_ARCHIVE"
assert_file "$APP_DIR/Contents/MacOS/Ghostty"
[[ -L "$APP_DIR/Contents/Frameworks/Fixture.framework/Fixture" ]] || fail 'framework link lost in package'
[[ "$(cat "$TEST_HOME/Applications/Ghostty.app/stock")" = 'stock app' ]] || fail 'stock app changed'
assert_contains "$(GHOSTTY_RESOURCES_DIR=/stock/resources "$INSTALL_DIR/bin/ghostty-automator" +version)" \
    'fixture-version-2|+version|'
[[ "$(head -n 1 "$INSTALL_DIR/bin/ghostty-automator")" = '#!/usr/bin/env bash' ]] || fail 'CLI was copied out of app bundle'
run_install --archive "$MAC_ARCHIVE"
assert_file "$APP_DIR/Contents/MacOS/Ghostty"
printf 'PASS: macOS app-backed CLI, framework links, repeat install, stock app preservation\n'

# Repacking must discard stale entries rather than updating an existing zip in place.
printf 'stale resource\n' > "$SANDBOX/build/Ghostty.app/Contents/Resources/stale"
package --platform macos-arm64
rm "$SANDBOX/build/Ghostty.app/Contents/Resources/stale"
package --platform macos-arm64
run_install --archive "$MAC_ARCHIVE"
[[ ! -e "$APP_DIR/Contents/Resources/stale" ]] || fail 'removed file survived repackaging'
printf 'PASS: repackaged zip removes obsolete app resources\n'

# Older flat macOS releases remain installable without misidentifying their CLI.
mkdir -p "$SANDBOX/flat-mac"
cp -R "$SANDBOX/build/Ghostty.app" "$SANDBOX/flat-mac/"
cp -R "$SANDBOX/skills" "$SANDBOX/flat-mac/skills"
(cd "$SANDBOX/flat-mac" && zip -qr --symlinks "$SANDBOX/flat-mac.zip" .)
run_install --archive "$SANDBOX/flat-mac.zip"
assert_file "$APP_DIR/Contents/MacOS/Ghostty"
mkdir -p "$TEST_HOME/Applications/Unmanaged.app"
expect_error 'Refusing to replace an unmanaged app' --archive "$MAC_ARCHIVE" \
    --app-dir "$TEST_HOME/Applications/Unmanaged.app"
export TEST_OS=FreeBSD
expect_error 'Unsupported operating system: FreeBSD' --archive "$LINUX_ARCHIVE"
export TEST_OS=Linux TEST_ARCH=riscv64
expect_error 'Unsupported architecture: riscv64' --archive "$LINUX_ARCHIVE"
export TEST_OS=Darwin TEST_ARCH=x86_64
expect_error 'No macOS Intel release is published'
printf 'PASS: legacy flat app archive, unmanaged app protection, unsupported platforms\n'
