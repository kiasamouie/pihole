#!/usr/bin/env bash
# make-env.sh - Create .env (the single machine-specific file) with a strong
# random admin password.
#
# Usage: scripts/make-env.sh
#   - If .env already exists, it is NOT touched (refuses to overwrite).
#   - Copies .env.example (the generic template) to .env, generates a
#     32-char URL-safe random token for ADMIN_PASSWORD, writes mode 600.
#   - The password is printed ONCE to stdout so you can record it -
#     .env is git-ignored and must never be committed.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -f .env ]; then
    echo ".env already exists - not overwriting. Remove it first if you really want to regenerate."
    exit 1
fi
[ -f .env.example ] || { echo ".env.example missing - cannot create .env" >&2; exit 1; }

pw=$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-32)

umask 077
sed "s|^ADMIN_PASSWORD=.*|ADMIN_PASSWORD=$pw|" .env.example > .env
chmod 600 .env

echo "Created .env (mode 600) from .env.example."
echo "Your admin password (record it now, it will not be shown again):"
echo "$pw"
echo
echo "Next: fill in the blank machine values in .env (LAN interface/subnet,"
echo "box IP, upstream router, TV lists) or let bootstrap.sh fill what it can,"
echo "then: docker compose up -d   &&   python3 scripts/setup-pihole-groups.py"
