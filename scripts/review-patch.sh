#!/usr/bin/env bash
# Review a single patch and produce a structured JSON file.
# Script builds JSON structure; codex fills review content.
# Usage: review-patch.sh <message-id> <output-file>
set -uo pipefail

UA="Mozilla/5.0 (compatible; loupe-review/1.0)"
MSGID="$1"
OUTPUT="$2"

BARE_MSGID=$(echo "${MSGID}" | sed 's/^<//; s/>$//')
ENCODED_MSGID=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "${BARE_MSGID}")

echo "=== Reviewing: ${BARE_MSGID} ==="

# --- Step 1: Patchwork metadata ---
echo "[1/6] Querying Patchwork..."
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
    echo "[2/6] Patchwork empty, fetching from lore..."
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
    echo "[2/6] Metadata from Patchwork OK, skip lore."
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
echo "  Author: ${AUTHOR_NAME}"
echo "  Subsystem: ${SUBSYSTEM}, Patches: ${PATCH_COUNT}, v${VERSION}"

# --- Step 3: Download patch diff (b4 preferred, curl fallback) ---
echo "[3/6] Downloading patch series..."
DIFF_FILE=$(mktemp)
COVER_FILE=$(mktemp)
B4_DIR=$(mktemp -d)

if command -v b4 &>/dev/null; then
    echo "  Trying b4..."
    (cd "${B4_DIR}" && b4 am "${BARE_MSGID}" 2>/dev/null) || true
    B4_MBX=$(ls "${B4_DIR}"/*.mbx 2>/dev/null | head -1)
    B4_COVER=$(ls "${B4_DIR}"/*.cover 2>/dev/null | head -1)
    [ -n "${B4_MBX}" ] && cp "${B4_MBX}" "${DIFF_FILE}"
    [ -n "${B4_COVER}" ] && cp "${B4_COVER}" "${COVER_FILE}"
fi

if [ ! -s "${DIFF_FILE}" ]; then
    echo "  b4 failed or unavailable, trying curl..."
    curl -sL -A "${UA}" "https://lore.kernel.org/qemu-devel/${ENCODED_MSGID}/t.mbox.gz" \
        | gunzip > "${DIFF_FILE}" 2>/dev/null || true
    if [ ! -s "${DIFF_FILE}" ]; then
        curl -sL -A "${UA}" "https://lore.kernel.org/qemu-devel/${ENCODED_MSGID}/raw" > "${DIFF_FILE}"
    fi
    if head -5 "${DIFF_FILE}" | grep -qi '<html\|<!doctype'; then
        echo "  WARNING: lore returned HTML (anti-bot)."
        > "${DIFF_FILE}"
    fi
fi

rm -rf "${B4_DIR}"
DIFF_LINES=$(wc -l < "${DIFF_FILE}")
COVER_LINES=$(wc -l < "${COVER_FILE}" 2>/dev/null || echo 0)
echo "  Series: ${DIFF_LINES} lines, Cover: ${COVER_LINES} lines"

# Detect if this is a cover letter (title has 0/N pattern)
IS_COVER=false
if echo "${TITLE}" | grep -qE '\b0/[0-9]+'; then
    IS_COVER=true
    echo "  Detected: cover letter for multi-patch series"
fi

# Truncate for codex context limit
DIFF_TRUNC=$(mktemp)
head -500 "${DIFF_FILE}" > "${DIFF_TRUNC}"

# --- Step 4: Codex review ---
echo "[4/6] Running codex review..."
REVIEW_OUT=$(mktemp)

PROMPT_FILE=$(mktemp)
cat > "${PROMPT_FILE}" << 'PROMPTEOF'
You are a QEMU patch reviewer. Analyze the patch series below.
Output ONLY a single JSON object. No markdown fences, no explanation.
The JSON must have exactly these top-level keys:
  verdict (string: needs_revision or ready_to_merge or blocked)
  summary (string: one-sentence review summary)
  stages (object with keys A,B,C,D,E each a string summary)
  findings (array of objects, empty if no issues found)
Each finding: id, severity, file, line, title, description,
  patch_context (array of diff lines), suggestion, confidence,
  confidence_reason
Start your response with { and end with }
PROMPTEOF

# Add cover letter context if present
if [ -s "${COVER_FILE}" ]; then
    echo "" >> "${PROMPT_FILE}"
    echo "COVER LETTER:" >> "${PROMPT_FILE}"
    cat "${COVER_FILE}" >> "${PROMPT_FILE}"
fi

echo "" >> "${PROMPT_FILE}"
echo "PATCH SERIES:" >> "${PROMPT_FILE}"
cat "${DIFF_TRUNC}" >> "${PROMPT_FILE}"

codex exec --full-auto "$(cat "${PROMPT_FILE}")" > "${REVIEW_OUT}" 2>&1 || true
rm -f "${PROMPT_FILE}" "${DIFF_TRUNC}"

# --- Step 5: Extract review JSON ---
echo "[5/6] Extracting review JSON..."
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
        # Must have 'verdict', must NOT be MCP/tool output
        if 'verdict' in obj and 'thoughtNumber' not in obj and 'structuredContent' not in obj:
            result = obj
            break
    except:
        continue

if result is None:
    result = {"verdict":"unknown","summary":"AI review failed","stages":{"A":"","B":"","C":"","D":"","E":""},"findings":[]}

with open(out_path, 'w') as f:
    json.dump(result, f, ensure_ascii=False)
PYEOF

rm -f "${REVIEW_OUT}"

VERDICT=$(jq -r '.verdict' "${REVIEW_FILE}" 2>/dev/null || echo "unknown")
echo "  Verdict: ${VERDICT}"

# --- Step 6: Assemble final JSON ---
echo "[6/6] Assembling final JSON..."

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

python3 - "${META_FILE}" "${REVIEW_FILE}" "${DIFF_FILE}" "${COVER_FILE}" "${OUTPUT}" << 'PYEOF'
import sys, json

meta = json.load(open(sys.argv[1]))
review = json.load(open(sys.argv[2]))
diff_path = sys.argv[3]
cover_path = sys.argv[4]
out_path = sys.argv[5]

slug = meta["message_id"].strip("<>").replace("@","-at-")
for c in "/<>?*[]\\": slug = slug.replace(c, "-")
slug = slug[:60]

# Read cover letter
cover_text = ""
try:
    cover_text = open(cover_path).read().strip()
except:
    pass

# Read diff content
diff_text = ""
try:
    diff_text = open(diff_path).read().strip()
except:
    pass

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
    "cover_letter": cover_text if cover_text else None,
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
        "checkpatch": {"status": "not_run", "issues": []}
    },
    "diff": diff_text if diff_text else None,
    "patches": [],
    "generated_at": meta["generated_at"],
    "generator": "loupe-review v1.0",
    "disclaimer": "LLM-generated draft. Not an authoritative review."
}

with open(out_path, 'w') as f:
    json.dump(output, f, indent=2, ensure_ascii=False)
PYEOF

rm -f "${META_FILE}" "${REVIEW_FILE}" "${DIFF_FILE}" "${COVER_FILE}"

if [ -f "${OUTPUT}" ] && jq empty "${OUTPUT}" 2>/dev/null; then
    echo "=== Done ==="
    jq -r '"  \(.series.title) | \(.review.verdict) | \(.review.findings|length) findings"' "${OUTPUT}"
else
    echo "ERROR: invalid JSON output"
    rm -f "${OUTPUT}"
    exit 1
fi
