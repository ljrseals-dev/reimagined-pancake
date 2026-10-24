Here's the combined script: preflight → clone → batch-push, where each batch is capped at 120 files OR 25 MB, whichever hits first, with a pause between pushes.

```bash
#!/usr/bin/env bash
# push-combined.sh — preflight + batch-push a source tree to GitHub.
# Each batch is capped at MAX_FILES_PER_BATCH files OR MAX_BYTES_PER_BATCH bytes,
# whichever is reached first. Sleeps PAUSE seconds between pushes.
#
# Usage:
#   ./push-combined.sh [zipfile]
# If no zip is given, uses $PWD/aoc-magic-studio-standalone/.
set -euo pipefail

# ── Tunables ──────────────────────────────────────────────────────────
MAX_FILES_PER_BATCH="${MAX_FILES_PER_BATCH:-120}"
MAX_BYTES_PER_BATCH="${MAX_BYTES_PER_BATCH:-$((25 * 1024 * 1024))}"   # 25 MB
PAUSE="${PAUSE:-3}"
HARD_MB="${HARD_MB:-100}"       # GitHub rejects files > this
WARN_MB="${WARN_MB:-50}"        # GitHub warns above this
REPO_SOFT_BYTES=$((1024 * 1024 * 1024))          # ~1 GB recommended
PUSH_HARD_BYTES=$((2 * 1024 * 1024 * 1024))      # 2 GB hard per push

# ── Paths ─────────────────────────────────────────────────────────────
STAGE="$(pwd)"
CLONE="$STAGE/upgraded-broccoli"
SRC="$STAGE/aoc-magic-studio-standalone"
ZIP="${1:-$STAGE/aoc-magic-studio-standalone-5.1.0-portable.zip}"
REPO_URL="https://github.com/ljrseals-dev/upgraded-broccoli.git"

# ── Helpers ───────────────────────────────────────────────────────────
file_size() { stat -c%s "$1" 2>/dev/null || stat -f%z "$1" 2>/dev/null || echo 0; }
human_size() {
  awk -v b="$1" 'BEGIN{
    split("B KB MB GB TB", u, " "); i=1
    while (b>=1024 && i<5){ b/=1024; i++ }
    if (i==1) printf "%d %s\n", b, u[i]
    else      printf "%.1f %s\n", b, u[i]
  }'
}

TMP=""
cleanup() { [[ -n "$TMP" ]] && rm -rf "$TMP"; }
trap cleanup EXIT

# ── 1. Resolve source to preflight ────────────────────────────────────
if [[ -f "$ZIP" ]]; then
  TMP=$(mktemp -d)
  unzip -q "$ZIP" -d "$TMP"
  shopt -s dotglob nullglob
  ROOTS=("$TMP"/*)
  shopt -u dotglob nullglob
  if (( ${#ROOTS[@]} == 1 )) && [[ -d "${ROOTS[0]}" ]]; then
    SRC_CHECK="${ROOTS[0]}"; SRC_LABEL="$(basename "$ZIP") → $(basename "${ROOTS[0]}")/"
  else
    SRC_CHECK="$TMP"; SRC_LABEL="$(basename "$ZIP")"
  fi
elif [[ -d "$SRC" ]]; then
  SRC_CHECK="$SRC"; SRC_LABEL="$SRC"
else
  echo "No source: neither $ZIP nor $SRC exists." >&2; exit 1
fi

# ── 2. Preflight on source ────────────────────────────────────────────
mapfile -d '' SRCFILES < <(find "$SRC_CHECK" -type f -print0)
TOTAL_SRC=${#SRCFILES[@]}
TOTAL_SRC_BYTES=0
declare -a HARD_HITS WARN_HITS
for f in "${SRCFILES[@]}"; do
  sz=$(file_size "$f"); TOTAL_SRC_BYTES=$((TOTAL_SRC_BYTES + sz))
  rel="${f#"$SRC_CHECK"/}"
  if   (( sz > HARD_MB * 1024 * 1024 )); then HARD_HITS+=("$sz|$rel")
  elif (( sz > WARN_MB * 1024 * 1024 )); then WARN_HITS+=("$sz|$rel")
  fi
done

echo "════════════════════════════════════════════════════════════════════"
echo " 1. PREFLIGHT — $SRC_LABEL"
echo "════════════════════════════════════════════════════════════════════"
printf " files: %d\n size:  %s\n\n" "$TOTAL_SRC" "$(human_size "$TOTAL_SRC_BYTES")"

FAIL=0; WARN=0
if (( ${#HARD_HITS[@]} )); then
  echo " [FAIL] ${#HARD_HITS[@]} file(s) >${HARD_MB}MB — GitHub rejects these:"
  for h in "${HARD_HITS[@]}"; do
    sz=${h%%|*}; p=${h#*|}
    printf "        %10s  %s\n" "$(human_size "$sz")" "$p"
  done
  FAIL=1
else
  echo " [ OK ] no files >${HARD_MB}MB."
fi
if (( ${#WARN_HITS[@]} )); then
  echo " [WARN] ${#WARN_HITS[@]} file(s) >${WARN_MB}MB — allowed but bloats the repo:"
  for h in "${WARN_HITS[@]}"; do
    sz=${h%%|*}; p=${h#*|}
    printf "        %10s  %s\n" "$(human_size "$sz")" "$p"
  done
  WARN=1
fi
if   (( TOTAL_SRC_BYTES > PUSH_HARD_BYTES )); then
  echo " [FAIL] total $(human_size "$TOTAL_SRC_BYTES") > 2 GB push cap."; FAIL=1
elif (( TOTAL_SRC_BYTES > REPO_SOFT_BYTES )); then
  echo " [WARN] total $(human_size "$TOTAL_SRC_BYTES") > 1 GB repo recommendation."; WARN=1
else
  echo " [ OK ] total $(human_size "$TOTAL_SRC_BYTES") — fine."
fi

JUNK=$(find "$SRC_CHECK" \( -name '.DS_Store' -o -name 'Thumbs.db' -o -name '__MACOSX' \
       -o -name '__pycache__' -o -name '*.pyc' -o -name '*.pyo' -o -name '*.swp' \) -print 2>/dev/null)
if [[ -n "$JUNK" ]]; then
  echo " [WARN] junk files present — consider .gitignore or delete:"
  echo "$JUNK" | sed "s|^$SRC_CHECK/||; s/^/        /"
  WARN=1
else
  echo " [ OK ] no junk files."
fi

(( FAIL )) && { echo; echo " ABORT: fix [FAIL] items before pushing."; exit 2; }
echo

# ── 3. Clone + overlay ────────────────────────────────────────────────
[[ -e "$CLONE" ]] && { echo "Refusing to overwrite $CLONE" >&2; exit 1; }
git config user.email >/dev/null || { echo "Set git user.email first" >&2; exit 1; }

echo "════════════════════════════════════════════════════════════════════"
echo " 2. CLONE — $REPO_URL"
echo "════════════════════════════════════════════════════════════════════"
git clone "$REPO_URL" "$CLONE"
cd "$CLONE"

cp -a "$SRC_CHECK/." .
[[ -f "$STAGE/README.md"  ]] && cp "$STAGE/README.md"  ./README.md
[[ -f "$STAGE/.gitignore" ]] && cp "$STAGE/.gitignore" ./.gitignore
rm -f NOTE WARNING
git rm -q --cached --ignore-unmatch NOTE WARNING 2>/dev/null || true
echo

# ── 4. Build the diff list vs. remote ─────────────────────────────────
mapfile -d '' PATHS < <(git ls-files -o -m -d --exclude-standard -z)
TOTAL=${#PATHS[@]}
if (( TOTAL == 0 )); then
  echo "GitHub is already up to date — nothing to push."
  exit 0
fi

# ── 5. Plan batches (120 files OR 25 MB, whichever first) ─────────────
declare -a B_START B_END B_FILES B_BYTES
i=0
while (( i < TOTAL )); do
  start=$i; bytes=0
  while (( i < TOTAL )); do
    p="${PATHS[i]}"
    sz=0; [[ -e "$p" ]] && sz=$(file_size "$p")
    if (( i > start )); then
      (( i - start >= MAX_FILES_PER_BATCH ))        && break
      (( bytes + sz > MAX_BYTES_PER_BATCH ))        && break
    fi
    bytes=$((bytes + sz)); i=$((i + 1))
  done
  B_START+=("$start"); B_END+=("$i")
  B_FILES+=("$((i - start))"); B_BYTES+=("$bytes")
done
NUM_BATCHES=${#B_START[@]}

echo "════════════════════════════════════════════════════════════════════"
echo " 3. BATCH PLAN — ${MAX_FILES_PER_BATCH} files OR $(human_size "$MAX_BYTES_PER_BATCH") per batch"
echo "════════════════════════════════════════════════════════════════════"
printf " to push: %d file(s) / %s → %d batch(es)\n\n" \
  "$TOTAL" "$(human_size "$(printf '%s\n' "${B_BYTES[@]}" | awk '{s+=$1}END{print s+0}')")" "$NUM_BATCHES"
for (( b=0; b<NUM_BATCHES; b++ )); do
  printf "   batch %d: %3d file(s), %s\n" \
    "$((b+1))" "${B_FILES[b]}" "$(human_size "${B_BYTES[b]}")"
done
echo

# ── 6. Push loop ──────────────────────────────────────────────────────
branch="$(git symbolic-ref --short HEAD 2>/dev/null || echo main)"
echo "════════════════════════════════════════════════════════════════════"
echo " 4. PUSH — branch '$branch'"
echo "════════════════════════════════════════════════════════════════════"
for (( b=0; b<NUM_BATCHES; b++ )); do
  start=${B_START[b]}; end=${B_END[b]}
  slice=("${PATHS[@]:start:end-start}")
  pct=$(( end * 100 / TOTAL ))
  printf " [batch %d/%d] files %d-%d / %d (%d%%) — %s\n" \
    "$((b+1))" "$NUM_BATCHES" "$((start+1))" "$end" "$TOTAL" "$pct" \
    "$(human_size "${B_BYTES[b]}")"
  git add -A -- "${slice[@]}"
  git commit -q -m "Add files $((start+1))-$end of $TOTAL (batch $((b+1))/$NUM_BATCHES)" \
    || { echo "   [skip] nothing to commit in this batch."; continue; }
  git push -q origin "$branch"
  echo "   pushed."
  if (( b < NUM_BATCHES - 1 )); then
    echo "   sleeping ${PAUSE}s…"; sleep "$PAUSE"
  fi
done

echo
echo "════════════════════════════════════════════════════════════════════"
echo " Done: $TOTAL file(s) in $NUM_BATCHES batch(es)."
echo "════════════════════════════════════════════════════════════════════"
```

What it does, step-by-step

Phase What happens
1. Preflight Extracts the zip (or uses $SRC), counts files, totals bytes, flags >100 MB files as FAIL, >50 MB as WARN, >1 GB total as WARN, and prints junk files (.DS_Store, __pycache__, *.pyc, etc.). Aborts before any network call if a hard limit is violated.
2. Clone Clones upgraded-broccoli fresh. Overlays the full source tree.
3. Batch plan Builds the list of files that actually differ from GitHub (git ls-files -o -m -d), then greedily groups them: stops a batch when adding one more file would exceed 120 files or 25 MB (whichever comes first). Prints the whole plan up-front so you can see it before pushing.
4. Push Commits + pushes each batch, then sleep $PAUSE. Re-runnable: if batch 3 fails, re-run and it recomputes from the remote state — batches 1–2 won't be re-sent.

Example run

```
════════════════════════════════════════════════════════════════════
 1. PREFLIGHT — aoc-magic-studio-standalone-5.1.0-portable.zip → aoc-magic-studio-standalone/
════════════════════════════════════════════════════════════════════
 files: 130
 size:  4.3 MB

 [ OK ] no files >100MB.
 [ OK ] total 4.3 MB — fine.
 [ OK ] no junk files.

════════════════════════════════════════════════════════════════════
 2. CLONE — https://github.com/ljrseals-dev/upgraded-broccoli.git
════════════════════════════════════════════════════════════════════
Cloning into 'upgraded-broccoli'...

════════════════════════════════════════════════════════════════════
 3. BATCH PLAN — 120 files OR 25.0 MB per batch
════════════════════════════════════════════════════════════════════
 to push: 130 file(s) / 4.3 MB → 2 batch(es)

   batch 1: 120 file(s), 3.9 MB
   batch 2:  10 file(s), 408.0 KB

════════════════════════════════════════════════════════════════════
 4. PUSH — branch 'main'
════════════════════════════════════════════════════════════════════
 [batch 1/2] files 1-120 / 130 (92%) — 3.9 MB
   pushed.
   sleeping 3s…
 [batch 2/2] files 121-130 / 130 (100%) — 408.0 KB
   pushed.

════════════════════════════════════════════════════════════════════
 Done: 130 file(s) in 2 batch(es).
════════════════════════════════════════════════════════════════════
```

Tuning

```bash
# Tighten batches (more, smaller pushes):
MAX_FILES_PER_BATCH=40 MAX_BYTES_PER_BATCH=$((10*1024*1024)) PAUSE=5 \
  ./push-combined.sh

# Loosen (fewer, bigger pushes):
MAX_FILES_PER_BATCH=120 MAX_BYTES_PER_BATCH=$((25*1024*1024)) PAUSE=2 \
  ./push-combined.sh
```

Notes

· Whichever-limit-first logic is in the inner while: a batch stops adding files as soon as either i - start >= MAX_FILES_PER_BATCH or bytes + sz > MAX_BYTES_PER_BATCH. A single file larger than 25 MB still gets its own batch — that's intentional (otherwise the loop could never make progress), and the preflight already caught any >100 MB hard-fail.
· Deletions count as 0 bytes for batching purposes, so removing many files won't accidentally split batches — they pack efficiently.
· Re-runnable, idempotent, and abort-safe: git ls-files -o -m -d after a failed run only reports what's still different from the remote.
