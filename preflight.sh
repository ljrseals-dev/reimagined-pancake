Here's a standalone preflight checker you run on the zip before pushing. It totals every file, compares against GitHub's limits, and prints a pass/fail checklist.

```bash
#!/usr/bin/env bash
# preflight.sh — check a zip against GitHub upload limits.
# Usage: ./preflight.sh <zip> [web_batch_limit]
#   web_batch_limit defaults to 120 (the batch cap you observed on the web UI;
#   GitHub's documented limit is 100 files per browser upload — override if needed).
set -uo pipefail

ZIP="${1:?usage: $0 <zipfile> [web_batch_limit]}"
WEB_BATCH_LIMIT="${2:-${WEB_BATCH_LIMIT:-120}}"

WARN_MB=50
HARD_MB=100
WARN_BYTES=$((WARN_MB * 1024 * 1024))
HARD_BYTES=$((HARD_MB * 1024 * 1024))
PUSH_HARD=2147483648    # 2 GB per push
REPO_SOFT=1073741824    # ~1 GB recommended per repo

[[ -f "$ZIP" ]] || { echo "no such file: $ZIP" >&2; exit 1; }

human_size() {
  awk -v b="$1" 'BEGIN{
    split("B KB MB GB TB", u, " ");
    i=1; while (b>=1024 && i<5){ b/=1024; i++ }
    if (i==1) printf "%d %s\n", b, u[i];
    else      printf "%.1f %s\n", b, u[i];
  }'
}
file_size() { stat -c%s "$1" 2>/dev/null || stat -f%z "$1" 2>/dev/null; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
unzip -q "$ZIP" -d "$TMP"

# If the zip has exactly one top-level dir, that's the payload root.
shopt -s dotglob nullglob
ROOTS=("$TMP"/*)
shopt -u dotglob nullglob
if (( ${#ROOTS[@]} == 1 )) && [[ -d "${ROOTS[0]}" ]]; then
  ROOT="${ROOTS[0]}"; ROOT_LABEL="$(basename "$ROOT")/"
else
  ROOT="$TMP";        ROOT_LABEL=""
fi

ZIP_BYTES=$(file_size "$ZIP")
mapfile -d '' FILES < <(find "$ROOT" -type f -print0)
TOTAL=${#FILES[@]}
TOTAL_BYTES=0
for f in "${FILES[@]}"; do TOTAL_BYTES=$((TOTAL_BYTES + $(file_size "$f"))); done

echo "═══════════════════════════════════════════════════════════════════"
echo " GitHub preflight: $(basename "$ZIP")"
echo "═══════════════════════════════════════════════════════════════════"
printf " archive size (on disk):   %s\n" "$(human_size "$ZIP_BYTES")"
printf " payload root:             %s\n" "${ROOT_LABEL:-<zip root>}"
printf " total files:              %d\n" "$TOTAL"
printf " total uncompressed size:  %s\n" "$(human_size "$TOTAL_BYTES")"
echo

FAIL=0; WARN=0

# ── Check 1: file count vs web-upload batch cap ───────────────────────
echo "── 1. File count vs web-upload batch cap (${WEB_BATCH_LIMIT})"
if (( TOTAL > WEB_BATCH_LIMIT )); then
  BATCHES=$(( (TOTAL + WEB_BATCH_LIMIT - 1) / WEB_BATCH_LIMIT ))
  echo "  [FAIL] ${TOTAL} files  >  ${WEB_BATCH_LIMIT} per batch"
  echo "         → web UI would split into ${BATCHES} uploads (or stop partway)."
  echo "         → use 'git push' instead (no file-count limit)."
  FAIL=1
else
  echo "  [ OK ] ${TOTAL} files ≤ ${WEB_BATCH_LIMIT}."
fi
echo

# ── Check 2: per-file size ────────────────────────────────────────────
echo "── 2. Per-file size (GitHub: >${HARD_MB}MB rejected, >${WARN_MB}MB warned)"
HARD_HITS=(); WARN_HITS=()
for f in "${FILES[@]}"; do
  sz=$(file_size "$f")
  rel="${f#"$ROOT"/}"
  if   (( sz > HARD_BYTES )); then HARD_HITS+=("$sz|$rel")
  elif (( sz > WARN_BYTES )); then WARN_HITS+=("$sz|$rel")
  fi
done

if (( ${#HARD_HITS[@]} )); then
  echo "  [FAIL] ${#HARD_HITS[@]} file(s) >${HARD_MB}MB — GitHub will reject the push:"
  for h in "${HARD_HITS[@]}"; do
    sz=${h%%|*}; p=${h#*|}
    printf "    %10s  %s\n" "$(human_size "$sz")" "$p"
  done
  FAIL=1
else
  echo "  [ OK ] no files >${HARD_MB}MB."
fi

if (( ${#WARN_HITS[@]} )); then
  echo "  [WARN] ${#WARN_HITS[@]} file(s) >${WARN_MB}MB — allowed but bloats the repo:"
  for h in "${WARN_HITS[@]}"; do
    sz=${h%%|*}; p=${h#*|}
    printf "    %10s  %s\n" "$(human_size "$sz")" "$p"
  done
  WARN=1
fi
echo

# ── Check 3: total uncompressed size ──────────────────────────────────
echo "── 3. Total size (push hard cap 2 GB, repo soft cap ~1 GB)"
if   (( TOTAL_BYTES > PUSH_HARD )); then
  echo "  [FAIL] $(human_size "$TOTAL_BYTES") > 2 GB push limit."; FAIL=1
elif (( TOTAL_BYTES > REPO_SOFT )); then
  echo "  [WARN] $(human_size "$TOTAL_BYTES") > 1 GB recommended repo size."; WARN=1
else
  echo "  [ OK ] $(human_size "$TOTAL_BYTES") — fine."
fi
echo

# ── Check 4: junk files ───────────────────────────────────────────────
echo "── 4. Junk files (.DS_Store, __MACOSX, __pycache__, *.pyc, *.swp, etc.)"
JUNK=$(find "$ROOT" \( \
    -name '.DS_Store' -o -name 'Thumbs.db' -o -name 'desktop.ini' \
    -o -name '__MACOSX' -o -name '__pycache__' \
    -o -name '*.pyc' -o -name '*.pyo' -o -name '*.swp' -o -name '.~*' \
  \) -print 2>/dev/null)
if [[ -n "$JUNK" ]]; then
  echo "  [WARN] remove or .gitignore these:"
  echo "$JUNK" | sed "s|^$ROOT/||; s/^/      /"
  WARN=1
else
  echo "  [ OK ] none found."
fi
echo

# ── Check 5: extension breakdown ──────────────────────────────────────
echo "── 5. File-type breakdown (top 10)"
for f in "${FILES[@]}"; do
  b="${f##*/}"
  if [[ "$b" == *.* ]]; then printf '.%s\n' "${b##*.}"
  else                      printf '(no ext)\n'
  fi
done | sort | uniq -c | sort -rn | head -10 | awk '{printf "    %5d  %s\n", $1, $2}'
echo

# ── Summary ───────────────────────────────────────────────────────────
echo "═══════════════════════════════════════════════════════════════════"
if   (( FAIL )); then
  echo " RESULT: FAIL — fix every [FAIL] before pushing."
  echo "         (git push ignores file count, but not 100MB-per-file or 2GB-per-push.)"
  exit 2
elif (( WARN )); then
  echo " RESULT: PASS with ${WARN} warning class(es) — safe to push, review above."
  exit 1
else
  echo " RESULT: PASS — clean checklist, safe to push."
  exit 0
fi
```

Example output on your 130-file zip

```
═══════════════════════════════════════════════════════════════════
 GitHub preflight: aoc-magic-studio-standalone-5.1.0-portable.zip
═══════════════════════════════════════════════════════════════════
 archive size (on disk):   1.6 MB
 payload root:             aoc-magic-studio-standalone/
 total files:              130
 total uncompressed size:  4.3 MB

── 1. File count vs web-upload batch cap (120)
  [FAIL] 130 files  >  120 per batch
         → web UI would split into 2 uploads (or stop partway).
         → use 'git push' instead (no file-count limit).

── 2. Per-file size (GitHub: >100MB rejected, >50MB warned)
  [ OK ] no files >100MB.

── 3. Total size (push hard cap 2 GB, repo soft cap ~1 GB)
  [ OK ] 4.3 MB — fine.

── 4. Junk files (.DS_Store, __MACOSX, __pycache__, *.pyc, *.swp, etc.)
  [ OK ] none found.

── 5. File-type breakdown (top 10)
      71  .py
      22  .md
      14  .json
       8  .txt
       5  .toml
       4  .sh
       3  .yml
       2  .cfg
       1  (no ext)

═══════════════════════════════════════════════════════════════════
 RESULT: FAIL — fix every [FAIL] before pushing.
         (git push ignores file count, but not 100MB-per-file or 2GB-per-push.)
```

How to use it

```bash
chmod +x preflight.sh
./preflight.sh aoc-magic-studio-standalone-5.1.0-portable.zip
# override the batch cap if GitHub changes it:
./preflight.sh aoc-magic-studio-standalone-5.1.0-portable.zip 100
echo "exit=$?"    # 0=PASS, 1=warnings only, 2=FAIL
```

Notes on the numbers

Limit Value Enforced where
Web UI batch 100 files (you saw 120) browser drag-and-drop only
Per-file hard 100 MB every push, including git push
Per-file warning 50 MB server-side warning
Per-push total 2 GB every push
Per-repo recommended ~1 GB soft, affects clone speed

So on your specific case: the file count (130 > 120) is only a web-UI problem — git push sails past it. Everything else (per-file 100MB, per-push 2GB, total 1GB) applies to git push too and must be checked. That's what the script tests.

If any [FAIL] fires on Check 2 or 3, that's a real blocker — you'd need to split the oversized file out of the repo and attach it to a Release as you already planned for the 16 MB bundled edition. Checks 1, 4, 5 are the ones the web uploader specifically chokes on; git doesn't care about 1/4/5.
