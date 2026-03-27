#!/usr/bin/env bash
# Review a single patch: script handles all git/network ops,
# codex only does code analysis on the resulting diff.
# Usage: review-patch.sh <message-id> <output-file>
set -uo pipefail

UA="Mozilla/5.0 (compatible; loupe-review/1.0)"
MSGID="$1"
OUTPUT="$2"
QEMU_DIR="${QEMU_DIR:-$(pwd)/qemu}"

BARE_MSGID=$(echo "${MSGID}" | sed 's/^<//; s/>$//')
ENCODED_MSGID=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "${BARE_MSGID}")

echo "=== Reviewing: ${BARE_MSGID} ==="

# --- Step 1: Patchwork metadata ---
echo "[1/7] Querying Patchwork..."
PW_DATA=$(curl -sL -A "${UA}" "https://patchwork.ozlabs.org/api/patches/?project=qemu-devel&msgid=${ENCODED_MSGID}")
PW_COUNT=$(echo "${PW_DATA}" | jq 'length' 2>/dev/null || echo 0)

TITLE="" AUTHOR_NAME="" AUTHOR_EMAIL="" PW_STATE="unknown" PW_DATE="" PW_URL=""
PATCH_COUNT=1 SERIES_ID=""

if [ "${PW_COUNT}" -gt 0 ]; then
    echo "  Patchwork: ${PW_COUNT} result(s)"
    TITLE=$(echo "${PW_DATA}" | jq -r '.[0].name // empty')
    AUTHOR_NAME=$(echo "${PW_DATA}" | jq -r '.[0].submitter.name // empty')
    AUTHOR_EMAIL=$(echo "${PW_DATA}" | jq -r '.[0].submitter.email // empty')
    PW_STATE=$(echo "${PW_DATA}" | jq -r '.[0].state // "unknown"')
    PW_DATE=$(echo "${PW_DATA}" | jq -r '.[0].date // empty' | cut -dT -f1)
    PW_URL=$(echo "${PW_DATA}" | jq -r '.[0].web_url // empty')
    SERIES_ID=$(echo "${PW_DATA}" | jq -r '.[0].series[0].id // empty')
    if [ -n "${SERIES_ID}" ]; then
        SERIES_DATA=$(curl -sL -A "${UA}" "https://patchwork.ozlabs.org/api/series/${SERIES_ID}/")
        PATCH_COUNT=$(echo "${SERIES_DATA}" | jq '.patches | length' 2>/dev/null || echo 1)
        COVER_TITLE=$(echo "${SERIES_DATA}" | jq -r '.cover_letter.name // empty')
        [ -n "${COVER_TITLE}" ] && TITLE="${COVER_TITLE}"
    fi
fi

# --- Step 2: Fallback to lore ---
if [ -z "${TITLE}" ] || [ "${TITLE}" = "null" ]; then
    echo "[2/7] Fetching from lore..."
    LORE_HDR=$(curl -sL -A "${UA}" "https://lore.kernel.org/qemu-devel/${ENCODED_MSGID}/raw" | head -80)
    if echo "${LORE_HDR}" | grep -q '^Subject:'; then
        TITLE=$(echo "${LORE_HDR}" | grep -m1 '^Subject:' | sed 's/^Subject: *//')
        FROM_LINE=$(echo "${LORE_HDR}" | grep -m1 '^From:' | sed 's/^From: *//')
        AUTHOR_NAME=$(echo "${FROM_LINE}" | sed 's/ *<.*>//')
        AUTHOR_EMAIL=$(echo "${FROM_LINE}" | grep -oE '<[^>]+>' | tr -d '<>')
        PW_DATE=$(echo "${LORE_HDR}" | grep -m1 '^Date:' | sed 's/^Date: *//')
        PW_DATE=$(date -d "${PW_DATE}" +%Y-%m-%d 2>/dev/null || date +%Y-%m-%d)
    fi
else
    echo "[2/7] Metadata OK"
fi

[ -z "${TITLE}" ] && TITLE="Unknown: ${BARE_MSGID}"
[ -z "${AUTHOR_NAME}" ] && AUTHOR_NAME="unknown"
[ -z "${AUTHOR_EMAIL}" ] && AUTHOR_EMAIL=""
[ -z "${PW_DATE}" ] && PW_DATE=$(date +%Y-%m-%d)
VERSION=$(echo "${TITLE}" | grep -oiE 'v[0-9]+' | head -1 | tr -d 'vV')
[ -z "${VERSION}" ] && VERSION=1
SUBSYSTEM=$(echo "${TITLE}" | sed -n 's/.*\] *\([^:]*\):.*/\1/p' | head -1)
[ -z "${SUBSYSTEM}" ] && SUBSYSTEM=$(echo "${TITLE}" | sed -n 's/^\([^:]*\):.*/\1/p' | head -1)
[ -z "${SUBSYSTEM}" ] && SUBSYSTEM="riscv"
LORE_URL="https://lore.kernel.org/qemu-devel/${ENCODED_MSGID}/"

echo "  Title: ${TITLE}"
echo "  Author: ${AUTHOR_NAME}, Subsystem: ${SUBSYSTEM}"

# --- Step 3: Download patches with b4 ---
echo "[3/7] Downloading patches with b4..."
B4_DIR=$(mktemp -d)
COVER_TEXT=""
DIFF_TEXT=""

if command -v b4 &>/dev/null; then
    (cd "${B4_DIR}" && b4 am "${BARE_MSGID}" 2>&1) || true
    B4_MBX=$(ls "${B4_DIR}"/*.mbx 2>/dev/null | head -1)
    B4_COVER=$(ls "${B4_DIR}"/*.cover 2>/dev/null | head -1)
    [ -n "${B4_MBX}" ] && DIFF_TEXT=$(cat "${B4_MBX}")
    [ -n "${B4_COVER}" ] && COVER_TEXT=$(cat "${B4_COVER}")
    echo "  b4: mbx=$(wc -l <<< "${DIFF_TEXT}" 2>/dev/null) lines"
fi

if [ -z "${DIFF_TEXT}" ]; then
    echo "  b4 failed, trying curl..."
    DIFF_TEXT=$(curl -sL -A "${UA}" "https://lore.kernel.org/qemu-devel/${ENCODED_MSGID}/raw" 2>/dev/null)
    if echo "${DIFF_TEXT}" | head -3 | grep -qi '<html'; then
        DIFF_TEXT=""
        echo "  WARNING: lore returned anti-bot page"
    fi
fi

# Override title with original Subject from mbox (Patchwork strips [PATCH] prefix)
if [ -n "${DIFF_TEXT}" ]; then
    MBOX_SUBJECT=$(echo "${DIFF_TEXT}" | grep -m1 '^Subject:' | sed 's/^Subject: *//')
    if [ -n "${COVER_TEXT}" ]; then
        COVER_SUBJECT=$(echo "${COVER_TEXT}" | grep -m1 '^Subject:' | sed 's/^Subject: *//')
        [ -n "${COVER_SUBJECT}" ] && MBOX_SUBJECT="${COVER_SUBJECT}"
    fi
    [ -n "${MBOX_SUBJECT}" ] && TITLE="${MBOX_SUBJECT}"
    echo "  Title (from mbox): ${TITLE}"
fi

# --- Step 4: Apply patches in QEMU worktree + checkpatch ---
echo "[4/7] Applying patches in QEMU worktree..."
CHECKPATCH_RESULT="not_run"
CHECKPATCH_ISSUES=""
BUILD_STATUS="not_run"
AM_STATUS="not_run"
REVIEW_BRANCH="review-$(echo "${BARE_MSGID}" | sed 's/@/-/;s/[^a-zA-Z0-9-]/-/g;s/--*/-/g;s/-$//' | cut -c1-40)"
WORKTREE_DIR="${QEMU_DIR}/../loupe-worktree-$$"

if [ -d "${QEMU_DIR}" ] && [ -n "${DIFF_TEXT}" ]; then
    # Create worktree (clean up stale branch first)
    (cd "${QEMU_DIR}" && git branch -D "${REVIEW_BRANCH}" 2>/dev/null; git worktree remove --force "${WORKTREE_DIR}" 2>/dev/null; git worktree add -b "${REVIEW_BRANCH}" "${WORKTREE_DIR}" master 2>&1) || true

    if [ -d "${WORKTREE_DIR}" ]; then
        # Configure git identity for am
        cd "${WORKTREE_DIR}"
        git config user.email "chao.liu.zevorn@gmail.com"
        git config user.name "Chao Liu"
        # Save mbox and apply
        echo "${DIFF_TEXT}" > patch.mbox

        # Try git am, fall back to --3way on conflict
        AM_OUTPUT=""
        if git am patch.mbox 2>&1; then
            AM_STATUS="success"
            echo "  git am: success"
        else
            echo "  git am failed, retrying with --3way..."
            git am --abort 2>/dev/null || true
            if git am --3way patch.mbox 2>&1; then
                AM_STATUS="success_3way"
                echo "  git am --3way: success"
            else
                AM_STATUS="failed"
                git am --abort 2>/dev/null || true
                echo "  git am --3way: FAILED"
            fi
        fi

        # Run checkpatch regardless of am status (runs on the mbox file)
        if [ -x scripts/checkpatch.pl ]; then
            echo "  Running checkpatch..."
            CHECKPATCH_OUT=$(perl scripts/checkpatch.pl patch.mbox 2>&1 || true)
            if echo "${CHECKPATCH_OUT}" | grep -q "total: 0 errors, 0 warnings"; then
                CHECKPATCH_RESULT="clean"
            else
                CHECKPATCH_RESULT="issues"
                CHECKPATCH_ISSUES=$(echo "${CHECKPATCH_OUT}" | grep -E "^(ERROR|WARNING|CHECK):" | head -10)
            fi
            echo "  checkpatch: ${CHECKPATCH_RESULT}"
        fi

        # Build test only if am succeeded
        if [ "${AM_STATUS}" = "success" ] || [ "${AM_STATUS}" = "success_3way" ]; then
            echo "  Quick build check..."
            if ./configure --target-list=riscv64-softmmu 2>&1 | tail -3; then
                BUILD_STATUS="configure_ok"
                echo "  configure: success"
            else
                BUILD_STATUS="configure_fail"
                echo "  configure: failed"
            fi
        else
            echo "  Skipping build (am failed)"
        fi
        rm -f patch.mbox
        cd - >/dev/null

        # Cleanup worktree
        (cd "${QEMU_DIR}" && git worktree remove --force "${WORKTREE_DIR}" 2>/dev/null && git branch -D "${REVIEW_BRANCH}" 2>/dev/null) || true
    else
        echo "  WARNING: Could not create worktree"
    fi
else
    echo "  Skipping: no QEMU dir or no patch content"
fi
rm -rf "${B4_DIR}"

echo "  AM: ${AM_STATUS}, Checkpatch: ${CHECKPATCH_RESULT}, Build: ${BUILD_STATUS}"

# --- Step 5: Codex review (code analysis only, no network needed) ---
echo "[5/7] Running codex code review..."
REVIEW_OUT=$(mktemp)

# Prepare diff for codex (truncate for context limit)
DIFF_FOR_REVIEW=$(echo "${DIFF_TEXT}" | head -500)

PROMPT_FILE=$(mktemp)
cat > "${PROMPT_FILE}" << 'PROMPTEOF'
You are a QEMU patch reviewer. Analyze this patch series.
Output ONLY a single JSON object. No markdown, no explanation.
Keys: verdict, summary, stages(A,B,C,D,E), findings(array)
Each finding: id, severity, file, line, title, description,
  patch_context(diff lines array), suggestion, confidence, confidence_reason
Start with { end with }
PROMPTEOF

if [ -n "${COVER_TEXT}" ]; then
    echo -e "\nCOVER LETTER:\n${COVER_TEXT}" >> "${PROMPT_FILE}"
fi

echo -e "\nCHECKPATCH RESULT: ${CHECKPATCH_RESULT}" >> "${PROMPT_FILE}"
[ -n "${CHECKPATCH_ISSUES}" ] && echo "${CHECKPATCH_ISSUES}" >> "${PROMPT_FILE}"
echo -e "\nGIT AM STATUS: ${AM_STATUS}" >> "${PROMPT_FILE}"
echo -e "\nBUILD STATUS: ${BUILD_STATUS}" >> "${PROMPT_FILE}"
echo -e "\nPATCH:\n${DIFF_FOR_REVIEW}" >> "${PROMPT_FILE}"

# Run codex in QEMU dir so it can read source files for deeper analysis
(cd "${QEMU_DIR}" && codex exec --full-auto "$(cat "${PROMPT_FILE}")") > "${REVIEW_OUT}" 2>&1 || true
rm -f "${PROMPT_FILE}"

# --- Step 6: Extract review JSON ---
echo "[6/7] Extracting review..."
REVIEW_FILE=$(mktemp)

python3 - "${REVIEW_OUT}" "${REVIEW_FILE}" << 'PYEOF'
import sys, json

text = open(sys.argv[1]).read()

# Strategy: codex outputs the review JSON as a single line containing "verdict".
# Find all lines that are valid JSON and contain "verdict".
# This avoids MCP tool JSON (which contains thoughtNumber, structuredContent, etc.)
result = None

for line in text.split('\n'):
    line = line.strip()
    if not line.startswith('{') or '"verdict"' not in line:
        continue
    try:
        obj = json.loads(line)
        if 'verdict' in obj and 'thoughtNumber' not in obj:
            result = obj
            break
    except:
        continue

# Fallback: try block-based extraction if line-based failed
if result is None:
    blocks = []
    depth = 0
    start = -1
    for i, c in enumerate(text):
        if c == '{':
            if depth == 0: start = i
            depth += 1
        elif c == '}':
            depth -= 1
            if depth == 0 and start >= 0:
                blocks.append(text[start:i+1])
                start = -1
    for b in sorted(blocks, key=len, reverse=True):
        try:
            obj = json.loads(b)
            if 'verdict' in obj and 'thoughtNumber' not in obj \
               and 'structuredContent' not in obj and 'nextThoughtNeeded' not in obj:
                result = obj
                break
        except:
            continue

if result is None:
    result = {"verdict":"unknown","summary":"AI review failed","stages":{"A":"","B":"","C":"","D":"","E":""},"findings":[]}

with open(sys.argv[2], 'w') as f:
    json.dump(result, f, ensure_ascii=False)
PYEOF

rm -f "${REVIEW_OUT}"
VERDICT=$(jq -r '.verdict' "${REVIEW_FILE}" 2>/dev/null || echo "unknown")
echo "  Verdict: ${VERDICT}"

# --- Step 7: Assemble final JSON ---
echo "[7/7] Assembling JSON..."
mkdir -p "$(dirname "${OUTPUT}")"
META_FILE=$(mktemp)
cat > "${META_FILE}" << METAEOF
{
    "title": $(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "${TITLE}"),
    "version": ${VERSION},
    "patch_count": ${PATCH_COUNT},
    "author_name": $(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "${AUTHOR_NAME}"),
    "author_email": $(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "${AUTHOR_EMAIL}"),
    "date": "${PW_DATE}",
    "subsystem": "${SUBSYSTEM}",
    "message_id": $(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "${MSGID}"),
    "lore_url": "${LORE_URL}",
    "patchwork_url": "${PW_URL:-}",
    "patchwork_state": "${PW_STATE}",
    "checkpatch_status": "${CHECKPATCH_RESULT}",
    "build_status": "${BUILD_STATUS}",
    "am_status": "${AM_STATUS}",
    "generated_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
METAEOF

# Save diff, cover, checkpatch issues to temp files for python
DIFF_TMPFILE=$(mktemp)
COVER_TMPFILE=$(mktemp)
CP_TMPFILE=$(mktemp)
echo "${DIFF_TEXT}" > "${DIFF_TMPFILE}"
echo "${COVER_TEXT}" > "${COVER_TMPFILE}"
echo "${CHECKPATCH_ISSUES}" > "${CP_TMPFILE}"

python3 - "${META_FILE}" "${REVIEW_FILE}" "${DIFF_TMPFILE}" "${COVER_TMPFILE}" "${CP_TMPFILE}" "${OUTPUT}" << 'PYEOF'
import sys, json
meta = json.load(open(sys.argv[1]))
review = json.load(open(sys.argv[2]))
diff_text = open(sys.argv[3]).read().strip()
cover_text = open(sys.argv[4]).read().strip()
cp_text = open(sys.argv[5]).read().strip()
out_path = sys.argv[6]
slug = meta["message_id"].strip("<>").replace("@","-at-")
for c in "/<>?*[]\\": slug = slug.replace(c, "-")
slug = slug[:60]

# Parse checkpatch issues from file
cp_issues_list = [line for line in cp_text.split('\n') if line.strip()] if cp_text else []

# Merge checkpatch issues from codex review if present
cp_issues = review.pop("checkpatch_issues", [])

output = {
    "schema_version": "1",
    "id": meta["date"].replace("-","") + "-" + slug,
    "series": {
        "title": meta["title"],
        "version": meta["version"],
        "patch_count": meta["patch_count"],
        "author": {"name": meta["author_name"], "email": meta["author_email"]},
        "date": meta["date"],
        "subsystem": meta["subsystem"],
        "message_id": meta["message_id"],
        "lore_url": meta["lore_url"],
        "patchwork_url": meta["patchwork_url"],
        "base_branch": "master"
    },
    "version_history": [],
    "ml_context": {
        "patchwork_state": meta["patchwork_state"],
        "reviewed_by": [], "acked_by": [],
        "ci_status": "", "prior_feedback": [],
        "maintainer_activity": ""
    },
    "review": {
        "verdict": review.get("verdict", "unknown"),
        "summary": review.get("summary", ""),
        "mode": "ci-single",
        "stages": review.get("stages", {}),
        "findings": review.get("findings", []),
        "checkpatch": {"status": meta["checkpatch_status"], "issues": cp_issues_list if cp_issues_list else cp_issues},
        "build_status": meta["build_status"],
        "am_status": meta["am_status"]
    },
    "cover_letter": cover_text if cover_text else None,
    "diff": diff_text if diff_text else None,
    "patches": [],
    "generated_at": meta["generated_at"],
    "generator": "loupe-review v1.0",
    "disclaimer": "LLM-generated draft. Not an authoritative review."
}
with open(out_path, 'w') as f:
    json.dump(output, f, indent=2, ensure_ascii=False)
PYEOF

rm -f "${META_FILE}" "${REVIEW_FILE}" "${DIFF_TMPFILE}" "${COVER_TMPFILE}" "${CP_TMPFILE}"

if [ -f "${OUTPUT}" ] && jq empty "${OUTPUT}" 2>/dev/null; then
    echo "=== Done ==="
    jq -r '"  \(.series.title)\n  Verdict: \(.review.verdict) | Findings: \(.review.findings|length)\n  Checkpatch: \(.review.checkpatch.status) | Build: \(.review.build_status) | AM: \(.review.am_status)"' "${OUTPUT}"
else
    echo "ERROR: invalid JSON output"
    rm -f "${OUTPUT}"
    exit 1
fi
