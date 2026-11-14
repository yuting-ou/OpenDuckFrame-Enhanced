#!/bin/bash
# Sign a locally built OpenDuckFrame with the stable self-signed identity so
# macOS TCC keeps the screen-recording grant across rebuilds. Ad-hoc builds
# (the default) pin the grant to the binary hash and re-prompt every install.
# Opt-in for local installs: create the "OpenDuckFrame-Local" code-signing
# certificate once, then run this script after build.sh.
set -euo pipefail
APP="${1:-/Applications/OpenDuckFrame.app}"
IDENTITY="${ODF_LOCAL_SIGN_ID:-OpenDuckFrame-Local}"
security find-identity -v -p codesigning | grep -q "$IDENTITY" || {
  echo "error: no signing identity '$IDENTITY' in the login keychain" >&2
  echo "       create a self-signed code-signing certificate with that name once," >&2
  echo "       or set ODF_LOCAL_SIGN_ID to an existing identity." >&2
  exit 1
}
codesign -s "$IDENTITY" --force --deep "$APP"
codesign --verify "$APP"
echo "Signed $APP with the stable '$IDENTITY' identity."
