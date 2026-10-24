#!/usr/bin/env bash
set -euo pipefail

: "${REPO_URL:?set REPO_URL (e.g. git@github.com:you/repo.git)}"
: "${ZIP:?set ZIP to the portable bundle .zip}"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

git clone "$REPO_URL" "$WORKDIR/repo"
cd "$WORKDIR/repo"

unzip -q "$ZIP" -d "$WORKDIR/unpacked"
# no --delete: NOTE, WARNING, LICENSE and test/ survive untouched
rsync -a --exclude 'vendor/' "$WORKDIR/unpacked/" ./

git add -A
echo "--- staged ---"
git status --short

echo "--- files over 50 MB (GitHub warns) ---"
git ls-files -z | xargs -0 -r stat -c '%s %n' 2>/dev/null \
  | awk '$1 > 52428800 {printf "%s  (%.1f MB)\n", $2, $1/1048576}' \
  || true

read -rp "commit message: " MSG
git commit -m "$MSG"
git push

# Optional — attach the bundle as a Release asset instead of committing it:
# gh release create v0.1.0 "$ZIP" --title "v0.1.0" --notes "Portable bundle (includes vendor/)"
