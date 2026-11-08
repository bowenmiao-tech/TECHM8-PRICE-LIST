#!/bin/bash
# Saves the Crazy Parts login in this Mac user's login Keychain.
# The password is typed hidden and is never written to a file.
set -euo pipefail
source "$(dirname "$0")/crazyparts-common.sh"

read -r -p 'Crazy Parts email address: ' email
email="$(echo "$email" | xargs)"
[[ -n "$email" ]] || { echo 'An email address is required.' >&2; exit 1; }
read -r -s -p 'Crazy Parts password: ' password
echo
[[ -n "$password" ]] || { echo 'A password is required.' >&2; exit 1; }

security delete-generic-password -s "$KEYCHAIN_SERVICE" >/dev/null 2>&1 || true
security add-generic-password -s "$KEYCHAIN_SERVICE" -a "$email" -w "$password" -U \
  -T /usr/bin/security
unset password
echo "Crazy Parts login saved to the macOS Keychain (service: $KEYCHAIN_SERVICE)."
