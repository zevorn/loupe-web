#!/usr/bin/env bash
# Review a single patch and produce a structured JSON file.
# JSON structure is built by this script; codex fills in review content.
# Usage: review-patch.sh <message-id> <output-file>
set -uo pipefail

MSGID="$1"
OUTPUT="$2"

# Strip angle brackets for API queries
BARE_MSGID=$(echo "${MSGID}" | sed 's/^<//; s/>$//')
ENCODED_MSGID=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${BARE_MSGID}', safe=''))")

echo "=== Reviewing: ${MSGID} ==="
echo "Bare msgid: ${BARE_MSGID}"

# --- Step 1: Get metadata from Patchwork ---
echo "Querying Patchwork..."
PW_DATA=$(curl -sL "https://patchwork.ozlabs.org/api/patches/?project=qemu-devel&msgid=${ENCODED_MSGID}" 2>/dev/null)
PW_COUNT=$(echo "${PW_DATA}" | jq 'length' 2>/dev/null || echo 0)

TITLE="" AUTHOR_NAME="" AUTHOR_EMAIL="" PW_STATE="" PW_DATE="" PW_URL=""
PATCH_COUNT=1 SERIES_ID="" VERSION=1

if [ "${PW_COUNT}" -gt 0 ]; then
    echo "Patchwork found ${PW_COUNT} result(s)."
    TITLE=$(echo "${PW_DATA}" | jq -r '.[0].name // empty')
    AUTHOR_NAME=$(echo "${PW_DATA}" | jq -r '.[0].submitter.name // empty')
    AUTHOR_EMAIL=$(echo "${PW_DATA}" | jq -r '.[0].submitter.email // empty')
    PW_STATE=$(echo "${PW_DATA}" | jq -r '.[0].state // "unknown"')
    PW_DATE=$(echo "${PW_DATA}" | jq -r '.[0].date // empty' | cut -dT -f1)
    PW_URL=$(echo "${PW_DATA}" | jq -r '.[0].web_url // empty')
    SERIES_ID=$(echo "${PW_DATA}" | jq -r '.[0].series[0].id // empty')

    if [ -n "${SERIES_ID}" ]; then
        SERIES_DATA=$(curl -sL "https://patchwork.ozlabs.org/api/series/${SERIES_ID}/" 2>/dev/null)
        PATCH_COUNT=$(echo "${SERIES_DATA}" | jq '.patches | length' 2>/dev/null || echo 1)
        COVER_TITLE=$(echo "${SERIES_DATA}" | jq -r '.cover_letter.name // empty')
        [ -n "${COVER_TITLE}" ] && TITLE="${COVER_TITLE}"
    fi
else
    echo "Patchwork returned nothing."
fi

# --- Step 2: Fallback to lore for metadata ---
if [ -z "${TITLE}" ] || [ "${TITLE}" = "null" ]; then
    echo "Getting metadata from lore raw..."
    LORE_RAW=$(curl -sL "https://lore.kernel.org/qemu-devel/${ENCODED_MSGID}/raw" 2>/dev/null | head -100)

    if [ -n "${LORE_RAW}" ]; then
        TITLE=$(echo "${LORE_RAW}" | grep -m1 '^Subject:' | sed 's/^Subject: *//')
        FROM_LINE=$(echo "${LORE_RAW}" | grep -m1 '^From:' | sed 's/^From: *//')
        AUTHOR_NAME=$(echo "${FROM_LINE}" | sed 's/ *<.*>//')
        AUTHOR_EMAIL=$(echo "${FROM_LINE}" | grep -oE '<[^>]+>' | tr -d '<>')
        PW_DATE=$(echo "${LORE_RAW}" | grep -m1 '^Date:' | sed 's/^Date: *//' | cut -d' ' -f1-4)
        PW_DATE=$(date -d "${PW_DATE}" +%Y-%m-%d 2>/dev/null || date +%Y-%m-%d)
    fi
fi

[ -z "${TITLE}" ] && TITLE="Unknown patch: ${BARE_MSGID}"
[ -z "${AUTHOR_NAME}" ] && AUTHOR_NAME="unknown"
[ -z "${PW_DATE}" ] && PW_DATE=$(date +%Y-%m-%d)
[ -z "${PW_STATE}" ] && PW_STATE="unknown"

VERSION=$(echo "${TITLE}" | grep -oiE 'v[0-9]+' | head -1 | tr -d 'vV')
[ -z "${VERSION}" ] && VERSION=1

SUBSYSTEM=$(echo "${TITLE}" | sed -n 's/.*\] *\([^:]*\):.*/\1/p' | head -1)
[ -z "${SUBSYSTEM}" ] && SUBSYSTEM=$(echo "${TITLE}" | sed -n 's/^\([^:]*\):.*/\1/p' | head -1)
[ -z "${SUBSYSTEM}" ] && SUBSYSTEM="riscv"

LORE_URL="https://lore.kernel.org/qemu-devel/${ENCODED_MSGID}/"

echo "Title: ${TITLE}"
echo "Author: ${AUTHOR_NAME} <${AUTHOR_EMAIL}>"
echo "Patches: ${PATCH_COUNT}, Version: v${VERSION}, Subsystem: ${SUBSYSTEM}"

# --- Step 3: Download patch diff ---
echo "Downloading patch diff..."
PATCH_DIFF=$(curl -sL "https://lore.kernel.org/qemu-devel/${ENCODED_MSGID}/raw" 2>/dev/null)

[ -z "${PATCH_DIFF}" ] && PATCH_DIFF="(patch content unavailable)"

DIFF_FOR_REVIEW=$(echo "${PATCH_DIFF}" | head -300)

# --- Step 4: Ask codex for review ---
echo "Running codex review..."
REVIEW_OUT=$(mktemp)

codex exec --full-auto \
    "Analyze this QEMU patch and output ONLY a JSON object. No markdown fences, no explanation. Start with { end with }.

Required fields:
- verdict: needs_revision or ready_to_merge or blocked
- summary: one sentence
- stages: {A:concept, B:correctness, C:resources, D:security, E:final}
- findings: array (empty if no issues), each with: id, severity, file, line, title, description, patch_context(diff lines array), suggestion, confidence, confidence_reason

PATCH SUBJECT: ${TITLE}
PATCH CONTENT:
${DIFF_FOR_REVIEW}" > "${REVIEW_OUT}" 2>&1 || true

# --- Step 5: Extract review JSON ---
echo "Extracting review..."
REVIEW_JSON=$(python3 - "${REVIEW_OUT}" << 'PYEOF'
import sys, json

text = open(sys.argv[1]).read()
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
        if 'verdict' in obj:
            print(json.dumps(obj))
            sys.exit(0)
    except:
        continue

print('{"verdict":"unknown","summary":"AI review could not produce valid output","stages":{"A":"","B":"","C":"","D":"","E":""},"findings":[]}')
PYEOF
)

rm -f "${REVIEW_OUT}"
echo "Review verdict: $(echo "${REVIEW_JSON}" | jq -r '.verdict' 2>/dev/null)"

# --- Step 6: Build final JSON ---
echo "Assembling JSON..."
GENERATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Use python to build JSON (more reliable than jq for complex merges)
python3 - "${OUTPUT}" << PYEOF
import json, sys

review_data = json.loads('''${REVIEW_JSON}''')

output = {
    "schema_version": "1",
    "id": "$(date +%Y%m%d)-$(echo "${BARE_MSGID}" | sed 's/@/-at-/; s/[^a-zA-Z0-9._-]/-/g' | cut -c1-60)",
    "series": {
        "title": $(python3 -c "import json; print(json.dumps('${TITLE}'))"),
        "version": ${VERSION},
        "patch_count": ${PATCH_COUNT},
        "author": {"name": $(python3 -c "import json; print(json.dumps('${AUTHOR_NAME}'))"), "email": $(python3 -c "import json; print(json.dumps('${AUTHOR_EMAIL:-}'))")},
        "date": "${PW_DATE}",
        "subsystem": "${SUBSYSTEM}",
        "message_id": $(python3 -c "import json; print(json.dumps('${MSGID}'))"),
        "lore_url": "${LORE_URL}",
        "patchwork_url": "${PW_URL:-}",
        "base_branch": "master"
    },
    "version_history": [],
    "ml_context": {
        "patchwork_state": "${PW_STATE}",
        "reviewed_by": [],
        "acked_by": [],
        "ci_status": "",
        "prior_feedback": [],
        "maintainer_activity": ""
    },
    "review": {
        "verdict": review_data.get("verdict", "unknown"),
        "summary": review_data.get("summary", ""),
        "mode": "ci-single",
        "stages": review_data.get("stages", {}),
        "findings": review_data.get("findings", []),
        "checkpatch": {"status": "not_run", "issues": []}
    },
    "patches": [],
    "generated_at": "${GENERATED_AT}",
    "generator": "loupe-review v1.0",
    "disclaimer": "LLM-generated draft. Not an authoritative review."
}

with open(sys.argv[1], 'w') as f:
    json.dump(output, f, indent=2, ensure_ascii=False)
PYEOF

if [ -f "${OUTPUT}" ] && jq empty "${OUTPUT}" 2>/dev/null; then
    echo "=== Review complete ==="
    jq -r '"  Title: \(.series.title)\n  Verdict: \(.review.verdict)\n  Findings: \(.review.findings | length)"' "${OUTPUT}"
else
    echo "ERROR: Failed to produce valid JSON"
    rm -f "${OUTPUT}"
    exit 1
fi
