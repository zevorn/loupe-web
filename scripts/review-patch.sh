#!/usr/bin/env bash
# Review a single patch using codex + loupe-review skill in QEMU tree.
# Codex runs loupe-review which handles: worktree, git am, checkpatch,
# five-stage review, and JSON output.
# Script handles: Patchwork metadata, codex output extraction, JSON assembly.
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
echo "[1/5] Querying Patchwork..."
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
    echo "[2/5] Patchwork empty, fetching from lore..."
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
    echo "[2/5] Metadata OK"
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
echo "  Author: ${AUTHOR_NAME}, Subsystem: ${SUBSYSTEM}, Patches: ${PATCH_COUNT}"

# --- Step 3: Run codex + loupe-review in QEMU source tree ---
echo "[3/5] Running codex loupe-review in ${QEMU_DIR}..."
REVIEW_OUT=$(mktemp)

# codex exec runs in the QEMU directory so loupe-review skill can:
# - create git worktree
# - git am the patches
# - run checkpatch.pl
# - do five-stage code review
PROMPT_FILE=$(mktemp)
cat > "${PROMPT_FILE}" << PROMPTEOF
Execute the loupe-review skill to review this patch:

loupe-review ${BARE_MSGID} --ci

After the review is complete, output ONLY a JSON object with these keys:
  verdict (needs_revision / ready_to_merge / blocked)
  summary (one sentence)
  stages (object A,B,C,D,E each a string)
  findings (array, empty if clean)
  checkpatch_status (clean / issues)
  checkpatch_issues (array of strings)
  build_status (success / failure / not_run)

Each finding: id, severity, file, line, title, description,
  patch_context (array of diff lines), suggestion, confidence,
  confidence_reason

Start response with { end with }. No markdown.
PROMPTEOF

# Run in QEMU directory
(cd "${QEMU_DIR}" && codex exec --full-auto "$(cat "${PROMPT_FILE}")") \
    > "${REVIEW_OUT}" 2>&1 || true
rm -f "${PROMPT_FILE}"

# --- Step 4: Extract review JSON ---
echo "[4/5] Extracting review..."
REVIEW_FILE=$(mktemp)

python3 - "${REVIEW_OUT}" "${REVIEW_FILE}" << 'PYEOF'
import sys, json

text = open(sys.argv[1]).read()
out_path = sys.argv[2]

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

result = None
for b in sorted(blocks, key=len, reverse=True):
    try:
        obj = json.loads(b)
        if 'verdict' in obj and 'thoughtNumber' not in obj and 'structuredContent' not in obj:
            result = obj
            break
    except:
        continue

if result is None:
    result = {"verdict":"unknown","summary":"AI review failed to produce valid output",
              "stages":{"A":"","B":"","C":"","D":"","E":""},"findings":[],
              "checkpatch_status":"not_run","checkpatch_issues":[],"build_status":"not_run"}

with open(out_path, 'w') as f:
    json.dump(result, f, ensure_ascii=False)
PYEOF

rm -f "${REVIEW_OUT}"
VERDICT=$(jq -r '.verdict' "${REVIEW_FILE}" 2>/dev/null || echo "unknown")
echo "  Verdict: ${VERDICT}"

# --- Step 5: Assemble final JSON ---
echo "[5/5] Assembling JSON..."

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
    "generated_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
METAEOF

python3 - "${META_FILE}" "${REVIEW_FILE}" "${OUTPUT}" << 'PYEOF'
import sys, json

meta = json.load(open(sys.argv[1]))
review = json.load(open(sys.argv[2]))
out_path = sys.argv[3]

slug = meta["message_id"].strip("<>").replace("@","-at-")
for c in "/<>?*[]\\": slug = slug.replace(c, "-")
slug = slug[:60]

# Extract checkpatch from review if codex provided it
cp_status = review.pop("checkpatch_status", "not_run")
cp_issues = review.pop("checkpatch_issues", [])
build_status = review.pop("build_status", "not_run")

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
        "reviewed_by": [],
        "acked_by": [],
        "ci_status": "",
        "prior_feedback": [],
        "maintainer_activity": ""
    },
    "review": {
        "verdict": review.get("verdict", "unknown"),
        "summary": review.get("summary", ""),
        "mode": "ci-single",
        "stages": review.get("stages", {}),
        "findings": review.get("findings", []),
        "checkpatch": {"status": cp_status, "issues": cp_issues},
        "build_status": build_status
    },
    "patches": [],
    "generated_at": meta["generated_at"],
    "generator": "loupe-review v1.0",
    "disclaimer": "LLM-generated draft. Not an authoritative review."
}

with open(out_path, 'w') as f:
    json.dump(output, f, indent=2, ensure_ascii=False)
PYEOF

rm -f "${META_FILE}" "${REVIEW_FILE}"

if [ -f "${OUTPUT}" ] && jq empty "${OUTPUT}" 2>/dev/null; then
    echo "=== Done ==="
    jq -r '"  \(.series.title) | \(.review.verdict) | \(.review.findings|length) findings | checkpatch: \(.review.checkpatch.status) | build: \(.review.build_status)"' "${OUTPUT}"
else
    echo "ERROR: invalid JSON output"
    rm -f "${OUTPUT}"
    exit 1
fi
