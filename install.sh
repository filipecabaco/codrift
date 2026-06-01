#!/bin/sh
# Codrift installer
# Usage: curl -fsSL https://codrift.sh/install | sh
#
# Environment overrides:
#   CODRIFT_VERSION    — install a specific version (e.g. "0.2.0")
#   CODRIFT_INSTALL_DIR — where to extract the release (default ~/.local/share/codrift)
#
set -e

REPO="filipecabaco/codrift"
INSTALL_DIR="${CODRIFT_INSTALL_DIR:-${HOME}/.local/share/codrift}"
BIN_DIR="${HOME}/.local/bin"

# ── Detect platform ────────────────────────────────────────────────────────────

OS="$(uname -s)"
ARCH="$(uname -m)"

case "${OS}-${ARCH}" in
  Darwin-arm64)   TARGET="aarch64-apple-darwin" ;;
  Darwin-x86_64)  TARGET="x86_64-apple-darwin" ;;
  Linux-x86_64)   TARGET="x86_64-linux-gnu" ;;
  Linux-aarch64)  TARGET="aarch64-linux-gnu" ;;
  *)
    printf 'error: unsupported platform: %s on %s\n' "${ARCH}" "${OS}" >&2
    printf '  See https://github.com/%s/releases for manual download.\n' "${REPO}" >&2
    exit 1
    ;;
esac

# ── Resolve version ────────────────────────────────────────────────────────────

if [ -n "${CODRIFT_VERSION:-}" ]; then
  VERSION="${CODRIFT_VERSION}"
else
  printf 'Fetching latest release...\n'
  # Extract the tag_name value and strip an optional leading 'v' so both
  # "v1.2.3" and "1.2.3" tag formats produce a bare version number.
  VERSION="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
    | grep '"tag_name"' \
    | head -1 \
    | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/' \
    | sed 's/^v//')"
fi

[ -z "${VERSION}" ] && {
  printf 'error: could not determine latest version.\n' >&2
  printf '  Set CODRIFT_VERSION=x.y.z to install a specific release.\n' >&2
  exit 1
}

# ── Download ───────────────────────────────────────────────────────────────────

TARBALL="codrift-${VERSION}-${TARGET}.tar.gz"
URL="https://github.com/${REPO}/releases/download/v${VERSION}/${TARBALL}"

printf 'Installing codrift %s (%s)\n' "${VERSION}" "${TARGET}"
printf '  -> %s\n\n' "${INSTALL_DIR}"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT INT TERM

curl -fsSL --progress-bar "${URL}" -o "${TMP}/${TARBALL}"

# ── Extract ────────────────────────────────────────────────────────────────────

# Elixir's mix release :tar step does NOT wrap files in a top-level directory.
# The tarball root contains bin/, lib/, erts-*/, releases/ directly, so we
# extract straight into INSTALL_DIR (no --strip-components).

rm -rf "${INSTALL_DIR}"
mkdir -p "${INSTALL_DIR}"
tar -xzf "${TMP}/${TARBALL}" -C "${INSTALL_DIR}"

# ── Link into PATH ─────────────────────────────────────────────────────────────

mkdir -p "${BIN_DIR}"
ln -sf "${INSTALL_DIR}/bin/codrift" "${BIN_DIR}/codrift"

# ── Done ───────────────────────────────────────────────────────────────────────

printf '\ncodrift %s installed.\n\n' "${VERSION}"

case ":${PATH}:" in
  *":${BIN_DIR}:"*)
    ;;
  *)
    EXPORT_LINE="export PATH=\"${BIN_DIR}:\$PATH\""
    ADDED=0
    for rc in "${HOME}/.zshrc" "${HOME}/.bashrc" "${HOME}/.profile"; do
      if [ -f "${rc}" ] && ! grep -qF "${BIN_DIR}" "${rc}" 2>/dev/null; then
        printf '\n# Added by codrift installer\n%s\n' "${EXPORT_LINE}" >> "${rc}"
        printf 'Added %s to PATH in %s\n' "${BIN_DIR}" "${rc}"
        ADDED=1
      fi
    done
    if [ "${ADDED}" -eq 0 ] && [ ! -f "${HOME}/.zshrc" ] && [ ! -f "${HOME}/.bashrc" ]; then
      printf '\n# Added by codrift installer\n%s\n' "${EXPORT_LINE}" >> "${HOME}/.profile"
      printf 'Added %s to PATH in ~/.profile\n' "${BIN_DIR}"
    fi
    printf 'Run: source ~/.zshrc  (or open a new terminal)\n\n'
    ;;
esac

printf 'Quick start:\n'
printf '  codrift tui\n\n'
printf 'Register MCP server with Claude Code:\n'
printf '  codrift mcp install\n'
