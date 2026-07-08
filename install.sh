#!/bin/sh
# Codrift installer — installs the Codrift desktop app plus the headless CLI.
# Usage: curl -fsSL https://codrift.sh/install.sh | sh
#
# Environment overrides:
#   CODRIFT_VERSION — install a specific release tag (e.g. "0.2.0")
#
set -e

REPO="filipecabaco/codrift"
OS="$(uname -s)"
ARCH="$(uname -m)"

# Target suffix used for the CLI tarball asset name (see release.yml).
case "${OS}-${ARCH}" in
  Darwin-arm64)   CLI_TARGET="aarch64-apple-darwin" ;;
  Darwin-x86_64)  CLI_TARGET="x86_64-apple-darwin" ;;
  Linux-x86_64)   CLI_TARGET="x86_64-linux-gnu" ;;
  Linux-aarch64)  CLI_TARGET="aarch64-linux-gnu" ;;
  *)              CLI_TARGET="" ;;
esac

# ── Resolve the release to install ───────────────────────────────────────────

if [ -n "${CODRIFT_VERSION:-}" ]; then
  API="https://api.github.com/repos/${REPO}/releases/tags/v${CODRIFT_VERSION}"
else
  API="https://api.github.com/repos/${REPO}/releases/latest"
fi

printf 'Fetching release metadata...\n'
RELEASE_JSON="$(curl -fsSL "${API}")"

# Pick the download URL for an asset whose name matches a suffix/keyword.
# $1 = grep pattern applied to the asset file name.
asset_url() {
  printf '%s\n' "${RELEASE_JSON}" \
    | grep '"browser_download_url"' \
    | sed 's/.*"browser_download_url": *"\([^"]*\)".*/\1/' \
    | grep -iE "$1" \
    | grep -v '\.sha256$' \
    | head -1
}

# Verify a downloaded file against the `.sha256` asset published next to it.
# $1 = asset URL, $2 = local file path. Aborts the install on mismatch or
# when the release carries no checksum for the asset.
verify_sha() {
  SUM_EXPECTED="$(curl -fsSL "$1.sha256" 2>/dev/null | awk '{print $1}')"
  if [ -z "${SUM_EXPECTED}" ]; then
    printf 'error: no .sha256 checksum published for %s\n' "$1" >&2
    exit 1
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    SUM_ACTUAL="$(sha256sum "$2" | awk '{print $1}')"
  else
    SUM_ACTUAL="$(shasum -a 256 "$2" | awk '{print $1}')"
  fi
  if [ "${SUM_EXPECTED}" != "${SUM_ACTUAL}" ]; then
    printf 'error: checksum mismatch for %s\n  expected %s\n  got      %s\n' \
      "$2" "${SUM_EXPECTED}" "${SUM_ACTUAL}" >&2
    exit 1
  fi
}

# ── Install the desktop app ──────────────────────────────────────────────────

case "${OS}" in
  Darwin)
    case "${ARCH}" in
      arm64)  URL="$(asset_url 'aarch64.*\.dmg$|arm64.*\.dmg$')" ;;
      x86_64) URL="$(asset_url 'x64.*\.dmg$|x86_64.*\.dmg$')" ;;
    esac
    [ -z "${URL}" ] && URL="$(asset_url '\.dmg$')"
    [ -z "${URL}" ] && { printf 'error: no macOS .dmg found in the latest release.\n' >&2; exit 1; }

    TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT INT TERM
    printf 'Downloading %s\n' "${URL}"
    curl -fsSL --progress-bar "${URL}" -o "${TMP}/codrift.dmg"
    verify_sha "${URL}" "${TMP}/codrift.dmg"

    MNT="${TMP}/mnt"; mkdir -p "${MNT}"
    hdiutil attach "${TMP}/codrift.dmg" -nobrowse -quiet -mountpoint "${MNT}"
    APP="$(find "${MNT}" -maxdepth 1 -name '*.app' | head -1)"
    if [ -z "${APP}" ]; then
      hdiutil detach "${MNT}" -quiet || true
      printf 'error: no .app found inside the disk image.\n' >&2; exit 1
    fi
    printf 'Installing %s to /Applications\n' "$(basename "${APP}")"
    rm -rf "/Applications/$(basename "${APP}")"
    cp -R "${APP}" /Applications/
    hdiutil detach "${MNT}" -quiet || true
    printf 'Codrift.app installed to /Applications.\n'
    ;;

  Linux)
    URL="$(asset_url '\.AppImage$')"
    [ -z "${URL}" ] && { printf 'error: no Linux .AppImage found in the latest release.\n' >&2; exit 1; }

    APP_DIR="${HOME}/.local/bin"
    mkdir -p "${APP_DIR}"
    TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT INT TERM
    printf 'Downloading %s\n' "${URL}"
    curl -fsSL --progress-bar "${URL}" -o "${TMP}/codrift-app"
    verify_sha "${URL}" "${TMP}/codrift-app"
    mv "${TMP}/codrift-app" "${APP_DIR}/codrift-app"
    chmod +x "${APP_DIR}/codrift-app"
    printf 'Codrift app installed to %s/codrift-app\n' "${APP_DIR}"
    ;;

  *)
    printf 'error: unsupported platform: %s\n' "${OS}" >&2
    printf '  Download a bundle manually from https://github.com/%s/releases\n' "${REPO}" >&2
    exit 1
    ;;
esac

# ── Install the headless CLI ─────────────────────────────────────────────────

install_cli() {
  [ -z "${CLI_TARGET}" ] && { printf '\nSkipping CLI: no build for %s-%s.\n' "${OS}" "${ARCH}"; return; }

  CLI_URL="$(asset_url "codrift-cli-.*${CLI_TARGET}\.tar\.gz$")"
  [ -z "${CLI_URL}" ] && { printf '\nSkipping CLI: no codrift-cli tarball for %s.\n' "${CLI_TARGET}"; return; }

  CLI_DIR="${HOME}/.local/share/codrift"
  BIN_DIR="${HOME}/.local/bin"
  CTMP="$(mktemp -d)"

  printf '\nInstalling codrift CLI...\n'
  curl -fsSL --progress-bar "${CLI_URL}" -o "${CTMP}/codrift-cli.tar.gz"
  verify_sha "${CLI_URL}" "${CTMP}/codrift-cli.tar.gz"
  rm -rf "${CLI_DIR}"; mkdir -p "${CLI_DIR}" "${BIN_DIR}"
  # The mix release :tar step does not wrap files in a top-level directory, so
  # extract straight into CLI_DIR (bin/, lib/, erts-*, releases/ at the root).
  tar -xzf "${CTMP}/codrift-cli.tar.gz" -C "${CLI_DIR}"
  rm -rf "${CTMP}"
  ln -sf "${CLI_DIR}/bin/codrift" "${BIN_DIR}/codrift"
  printf 'codrift CLI installed to %s/codrift\n' "${BIN_DIR}"

  case ":${PATH}:" in
    *":${BIN_DIR}:"*) ;;
    *) printf 'Add %s to your PATH to use the `codrift` command.\n' "${BIN_DIR}" ;;
  esac
}

install_cli

printf '\nRegister the MCP server with Claude Code (optional):\n'
printf '  codrift mcp install\n'
