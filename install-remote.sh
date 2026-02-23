#!/usr/bin/env bash
# install-remote.sh - Download and install claude-warden from a GitHub release
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/johnzfitch/claude-warden/master/install-remote.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/johnzfitch/claude-warden/master/install-remote.sh | bash -s -- v0.2.0
#   curl -fsSL ... | bash -s -- v0.2.0 --dry-run

set -euo pipefail

REPO="johnzfitch/claude-warden"
TMPDIR=""

cleanup() { [[ -n "$TMPDIR" && -d "$TMPDIR" ]] && rm -rf "$TMPDIR"; }
trap cleanup EXIT

# === Colors ===
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
RESET='\033[0m'

info()  { printf "${GREEN}[+]${RESET} %s\n" "$*"; }
warn()  { printf "${YELLOW}[!]${RESET} %s\n" "$*"; }
error() { printf "${RED}[x]${RESET} %s\n" "$*" >&2; }

# === Detect download tool ===
if command -v curl &>/dev/null; then
    fetch() { curl -fsSL "$1"; }
    fetch_to() { curl -fsSL -o "$2" "$1"; }
elif command -v wget &>/dev/null; then
    fetch() { wget -qO- "$1"; }
    fetch_to() { wget -qO "$2" "$1"; }
else
    error "Either curl or wget is required."
    exit 1
fi

# === Require tar ===
if ! command -v tar &>/dev/null; then
    error "tar is required but not found."
    exit 1
fi

# === Parse arguments ===
VERSION=""
PASSTHROUGH_ARGS=()

for arg in "$@"; do
    if [[ "$arg" =~ ^v[0-9] ]]; then
        VERSION="$arg"
    else
        PASSTHROUGH_ARGS+=("$arg")
    fi
done

# === Resolve version ===
if [[ -z "$VERSION" ]]; then
    info "Detecting latest release..."
    VERSION=$(fetch "https://api.github.com/repos/$REPO/releases/latest" \
        | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')
    if [[ -z "$VERSION" ]]; then
        error "Could not determine latest release. Specify a version: bash install-remote.sh v0.2.0"
        exit 1
    fi
fi

info "Version: $VERSION"

# === Download tarball ===
TMPDIR=$(mktemp -d)
TARBALL="$TMPDIR/claude-warden-${VERSION}.tar.gz"
TARBALL_URL="https://github.com/$REPO/releases/download/$VERSION/claude-warden-${VERSION}.tar.gz"

info "Downloading $TARBALL_URL"
fetch_to "$TARBALL_URL" "$TARBALL"

if [[ ! -s "$TARBALL" ]]; then
    error "Download failed or tarball is empty."
    exit 1
fi

# === Extract ===
EXTRACT_DIR="$TMPDIR/claude-warden"
mkdir -p "$EXTRACT_DIR"
tar xzf "$TARBALL" -C "$EXTRACT_DIR"

# === Run install.sh ===
if [[ ! -f "$EXTRACT_DIR/install.sh" ]]; then
    error "install.sh not found in tarball. The release may be malformed."
    exit 1
fi

chmod +x "$EXTRACT_DIR/install.sh"
info "Running install.sh --copy ${PASSTHROUGH_ARGS[*]:-}"
bash "$EXTRACT_DIR/install.sh" --copy "${PASSTHROUGH_ARGS[@]+"${PASSTHROUGH_ARGS[@]}"}"
