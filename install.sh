#!/bin/sh

set -eu

REPO="kriol-lang/kriol"
INSTALL_DIR="$HOME/.kriol"

require() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "error: required command not found: $1" >&2
        exit 1
    }
}

require curl
require tar
require mktemp
require awk

if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
    echo "error: required command not found: sha256sum or shasum" >&2
    exit 1
fi

sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d ' ' -f 1
        return
    fi
    shasum -a 256 "$1" | cut -d ' ' -f 1
}

detect_platform() {
    OS=$(uname -s)
    ARCH=$(uname -m)

    if [ "$OS" = Darwin ] && [ "$(sysctl -in hw.optional.arm64 2>/dev/null)" = 1 ]; then
        ARCH=arm64
    fi

    case "$OS/$ARCH" in
        Linux/x86_64 | Linux/amd64)
            PLATFORM="linux-x86_64"
            ARCHIVE_EXT="tar.xz"
            TAR_FLAG="J"
            ;;
        Darwin/arm64)
            PLATFORM="macos-arm64"
            ARCHIVE_EXT="tar.gz"
            TAR_FLAG="z"
            ;;
        *)
            echo "error: no Kriol build for $OS $ARCH; supported: Linux x86_64, macOS arm64 (Apple silicon)" >&2
            exit 1
            ;;
    esac
}

detect_platform

PRE=0

while [ $# -gt 0 ]; do
    case "$1" in
        --pre)
            PRE=1
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
    shift
done

if [ "$PRE" -eq 1 ]; then
    echo "Fetching latest Kriol pre-release..."
    echo
    RELEASE_JSON=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases")
else
    echo "Fetching latest Kriol release..."
    echo
    RELEASE_JSON=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest")
fi

ASSET_URL=$(
    echo "$RELEASE_JSON" |
    grep '"browser_download_url":' |
    grep -F -e "-$PLATFORM.$ARCHIVE_EXT\"" |
    cut -d '"' -f 4 |
    head -n 1
)

if [ -z "$ASSET_URL" ]; then
    echo "error: could not find a $PLATFORM release asset" >&2
    exit 1
fi

ASSET_NAME=$(printf '%s' "${ASSET_URL##*/}" | sed 's/%2[Bb]/+/g')
SUMS_URL="${ASSET_URL%/*}/SHA256SUMS.txt"

if ! printf '%s\n' "$RELEASE_JSON" | grep -qF "\"$SUMS_URL\""; then
    echo "error: the release has no SHA256SUMS.txt, so $ASSET_NAME cannot be verified" >&2
    exit 1
fi

# Not TMPDIR: macOS exports it, so reassigning it would leak into every child process.
WORK_DIR=$(mktemp -d)

cleanup() {
    rm -rf "$WORK_DIR"
}

trap cleanup EXIT INT TERM

ARCHIVE="$WORK_DIR/kriol.$ARCHIVE_EXT"
SUMS="$WORK_DIR/SHA256SUMS.txt"

echo "Downloading..."
curl -fL "$ASSET_URL" -o "$ARCHIVE"
curl -fsSL "$SUMS_URL" -o "$SUMS"

echo "Verifying..."
EXPECTED=$(
    awk -v name="$ASSET_NAME" '{ file = $2; sub(/^\*/, "", file); if (file == name) { print $1; exit } }' "$SUMS"
)

if [ -z "$EXPECTED" ]; then
    echo "error: SHA256SUMS.txt has no entry for $ASSET_NAME" >&2
    exit 1
fi

if [ "$(sha256 "$ARCHIVE")" != "$EXPECTED" ]; then
    echo "error: the checksum of $ASSET_NAME does not match SHA256SUMS.txt; the download may be corrupted" >&2
    exit 1
fi

echo "Extracting..."
tar -x${TAR_FLAG}f "$ARCHIVE" -C "$WORK_DIR"

BINARY=$(
    find "$WORK_DIR" -type f -name kriol | head -n 1
)

if [ -z "$BINARY" ]; then
    echo "error: kriol binary not found in release archive" >&2
    exit 1
fi

mkdir -p "$INSTALL_DIR"

# Replace rather than overwrite: macOS kills a signed binary rewritten in place.
cp "$BINARY" "$INSTALL_DIR/kriol.new"
chmod +x "$INSTALL_DIR/kriol.new"
mv -f "$INSTALL_DIR/kriol.new" "$INSTALL_DIR/kriol"

echo
echo "-> Kriol installed successfully at: $INSTALL_DIR/kriol"
echo

if [ "$OS" = Darwin ] && ! xcode-select -p >/dev/null 2>&1; then
    echo "-> Kriol links programs with clang; install the Xcode Command Line Tools:"
    echo
    echo "     xcode-select --install"
    echo
fi

case ":$PATH:" in
    *":$INSTALL_DIR:"*) ;;
    *)
        echo "-> Make sure to add the Kriol your shell env:"
        echo
        echo "     export PATH=\"\$HOME/.kriol:\$PATH\""
        echo

        echo "-> Then close and reopen the shell and try:"
        echo
        echo "     kriol --help"
        echo
        ;;
esac
