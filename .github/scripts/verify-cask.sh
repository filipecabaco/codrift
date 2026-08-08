#!/usr/bin/env bash
#
# Verify Casks/codrift.rb against the assets a user would actually download.
#
# A cask's sha256 is a promise about bytes living at a URL that this repo does
# not control byte-for-byte over time: a release can be deleted and re-cut, and
# the rebuilt DMG will not hash the same. When that happens the cask keeps
# pointing at a live URL and `brew install` dies with "Cask reports different
# checksum". Nothing in the release path notices, because the bump job checksums
# what it just built rather than what is published.
#
# So this fetches each per-arch DMG over the same URL Homebrew uses and compares
# it to the sha256 in the cask. Run it after bumping the cask, and on a schedule
# to catch drift introduced after the fact.
#
# Usage: verify-cask.sh [path/to/cask.rb]
set -euo pipefail

CASK="${1:-Casks/codrift.rb}"
ZEROS="0000000000000000000000000000000000000000000000000000000000000000"

[ -f "$CASK" ] || { echo "::error::no cask at ${CASK}"; exit 1; }

version="$(sed -n 's/^[[:space:]]*version "\(.*\)"/\1/p' "$CASK" | head -n1)"
[ -n "$version" ] || { echo "::error file=${CASK}::no version stanza"; exit 1; }

# Read into arrays the long way: macOS runners still ship bash 3.2, no mapfile.
shas=(); urls=()
while IFS= read -r line; do shas+=("$line"); done < <(sed -n 's/^[[:space:]]*sha256 "\([^"]*\)"/\1/p' "$CASK")
while IFS= read -r line; do urls+=("$line"); done < <(sed -n 's#^[[:space:]]*url "\([^"]*\)".*#\1#p' "$CASK")

if [ "${#shas[@]}" -ne "${#urls[@]}" ] || [ "${#shas[@]}" -eq 0 ]; then
  echo "::error file=${CASK}::expected one sha256 per url, found ${#shas[@]} and ${#urls[@]}"
  exit 1
fi

sha_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "Verifying ${CASK} at version ${version}"
failed=0

for i in "${!urls[@]}"; do
  # The cask interpolates #{version} into its URLs; expand it the same way.
  url="${urls[$i]//\#\{version\}/$version}"
  want="${shas[$i]}"
  asset="$(basename "$url")"

  if [ "$want" = "$ZEROS" ]; then
    echo "  ${asset}: placeholder checksum, skipping (a release has yet to fill it in)"
    continue
  fi

  if ! curl -fsSL --retry 3 --retry-delay 5 -o "${tmp}/${asset}" "$url"; then
    echo "::error file=${CASK}::${asset} is not downloadable at ${url}"
    failed=1
    continue
  fi

  got="$(sha_of "${tmp}/${asset}")"
  if [ "$got" != "$want" ]; then
    echo "::error file=${CASK}::${asset} checksum drifted — cask says ${want}, ${url} serves ${got}"
    failed=1
  else
    echo "  ${asset}: ok (${got})"
  fi
  rm -f "${tmp}/${asset}"
done

if [ "$failed" -ne 0 ]; then
  echo "::error::cask does not match the published release; re-run the cask bump or re-cut the release"
  exit 1
fi

echo "Cask matches every published asset."
