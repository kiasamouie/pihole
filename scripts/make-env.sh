#!/usr/bin/env bash
# make-env.sh - Create .env with a strong random admin password (fresh machine setup).
#
# Usage: scripts/make-env.sh
#   - If .env already exists, it is NOT touched (refuses to overwrite).
#   - Generates a 32-char URL-safe random token for ADMIN_PASSWORD.
#   - Writes .env with mode 600. The password is printed ONCE to stdout so you
#     can record it - do not commit .env (it is git-ignored).
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -f .env ]; then
    echo ".env already exists - not overwriting. Remove it first if you really want to regenerate."
    exit 1
fi

tz="${TZ:-Europe/London}"
pw=$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-32)

umask 077
printf 'TZ=%s\nADMIN_PASSWORD=%s\n' "$tz" "$pw" > .env
chmod 600 .env

echo "Created .env (mode 600)."
echo "Your admin password (record it now, it will not be shown again):"
echo "$pw"
echo
echo "Next: docker compose up -d   then   python3 scripts/setup-pihole-groups.py"
