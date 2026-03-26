#!/usr/bin/env bash
# Review a single patch series and produce a structured JSON file.
# JSON structure is built by this script; codex fills in the content.
# Usage: review-patch.sh <message-id> <output-file>
set -uo pipefail

MSGID="$1"
OUTPUT="$2"
MAILING_LIST="${MAILING_LIST:-qemu-devel}"

echo "=== Reviewing: ${MSGID} ==="

# Step 1: Fetch patch metadata from Patchwork
echo "Fetching Patchwork metadata..."
PW_DATA=$(curl -sL "https://patchwork.ozlabs.org/api/patches/?project=${MAILING_LIST}&msgid=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${MSGID}', safe=''))")" 2>/dev/null)
PW_SERIES_DATA=""

if [ "$(echo "${PW_DATA}" | jq 'length')" -gt 0 ]; then
    SERIES_ID=$(echo "${PW_DATA}" | jq -r '.[0].series[0].id // empty')
    TITLE=$(echo "${PW_DATA}" | jq -r '.[0].name // empty')
    AUTHOR_NAME=$(echo "${PW_DATA}" | jq -r '.[0].submitter.name // empty')
    AUTHOR_EMAIL=$(echo "${PW_DATA}" | jq -r '.[0].submitter.email // empty')
    PW_STATE=$(echo "${PW_DATA}" | jq -r '.[0].state // "unknown"')
    PW_DATE=$(echo "${PW_DATA}" | jq -r '.[0].date // empty' | cut -dT -f1)
    PW_URL=$(echo "${PW_DATA}" | jq -r '.[0].web_url // empty')

    if [ -n "${SERIES_ID}" ]; then
        PW_SERIES_DATA=$(curl -sL "https://patchwork.ozlabs.org/api/series/${SERIES_ID}/" 2>/dev/null)
        PATCH_COUNT=$(echo "${PW_SERIES_DATA}" | jq '.patches | length' 2>/dev/null || echo 1)
        COVER_TITLE=$(echo "${PW_SERIES_DATA}" | jq -r '.cover_letter.name // empty')
        [ -n "${COVER_TITLE}" ] && TITLE="${COVER_TITLE}"
    else
        PATCH_COUNT=1
    fi
else
    echo "Patchwork returned no results, using msgid as fallback."
    TITLE="${MSGID}"
    AUTHOR_NAME="unknown"
    AUTHOR_EMAIL=""
    PW_STATE="unknown"
    PW_DATE=$(date +%Y-%m-%d)
    PW_URL=""
    PATCH_COUNT=1
    SERIES_ID=""
fi

# Derive subsystem from title
SUBSYSTEM=$(echo "${TITLE}" | sed -n 's/.*\] *\([^:]*\):.*/\1/p' | head -1)
[ -z "${SUBSYSTEM}" ] && SUBSYSTEM=$(echo "${TITLE}" | sed -n 's/^\([^:]*\):.*/\1/p' | head -1)
[ -z "${SUBSYSTEM}" ] && SUBSYSTEM="riscv"

# Version from title
VERSION=$(echo "${TITLE}" | grep -oiE 'v[0-9]+' | head -1 | tr -d 'vV')
[ -z "${VERSION}" ] && VERSION=1

LORE_URL="https://lore.kernel.org/${MAILING_LIST}/$(python3 -c "import urllib.parse; print(urllib.parse.quote('${MSGID}', safe=''))")/"

echo "Title: ${TITLE}"
echo "Author: ${AUTHOR_NAME}"
echo "Patches: ${PATCH_COUNT}, Version: v${VERSION}"
echo "Subsystem: ${SUBSYSTEM}"

# Step 2: Fetch patch diff via b4 or curl
echo "Downloading patch..."
PATCH_DIR=$(mktemp -d)
PATCH_DIFF=""

if command -v b4 &>/dev/null; then
    cd "${PATCH_DIR}" && b4 am "${MSGID}" 2>/dev/null && cd - >/dev/null
    PATCH_FILE=$(ls "${PATCH_DIR}"/*.mbx 2>/dev/null | head -1)
    [ -n "${PATCH_FILE}" ] && PATCH_DIFF=$(cat "${PATCH_FILE}")
fi

if [ -z "${PATCH_DIFF}" ]; then
    ENCODED_MSGID=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${MSGID}', safe=''))")
    PATCH_DIFF=$(curl -sL "https://lore.kernel.org/${MAILING_LIST}/${ENCODED_MSGID}/raw" 2>/dev/null)
fi

# Step 3: Ask codex for review analysis (short focused prompt)
echo "Running AI review analysis..."
REVIEW_OUT=$(mktemp)

codex exec --full-auto "You are reviewing a QEMU patch. Analyze the patch below and output ONLY a JSON object with these exact fields (nothing else):

{
  \"verdict\": \"needs_revision or ready_to_merge or blocked\",
  \"summary\": \"one-line summary of the review\",
  \"stages\": {
    \"A\": \"conceptual verification summary\",
    \"B\": \"correctness analysis summary\",
    \"C\": \"resource management summary\",
    \"D\": \"security review summary\",
    \"E\": \"dedup and final summary\"
  },
  \"findings\": [
    {
      \"id\": 1,
      \"severity\": \"critical or major or minor or nit\",
      \"stage\": \"A or B or C or D\",
      \"file\": \"path/to/file.c\",
      \"line\": \"line range\",
      \"patch_context\": [\"relevant diff lines\"],
      \"title\": \"short title\",
      \"description\": \"detailed explanation\",
      \"suggestion\": \"fix suggestion or null\",
      \"confidence\": \"high or medium or low\",
      \"confidence_reason\": \"why this confidence\"
    }
  ]
}

Start with { and end with }. No markdown, no explanation.

PATCH:
${PATCH_DIFF}" > "${REVIEW_OUT}" 2>&1 || true

# Extract JSON from codex output
REVIEW_JSON=$(python3 -c "
import sys
text = open('${REVIEW_OUT}').read()
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
if blocks:
    print(max(blocks, key=len))
" 2>/dev/null)

# Validate review JSON
if ! echo "${REVIEW_JSON}" | jq empty 2>/dev/null; then
    echo "WARNING: AI review output invalid, using empty review."
    REVIEW_JSON='{"verdict":"unknown","summary":"AI review failed to produce valid output","stages":{"A":"","B":"","C":"","D":"","E":""},"findings":[]}'
fi

# Step 4: Assemble final JSON using jq (script controls structure)
echo "Assembling review JSON..."
GENERATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)

jq -n \
    --arg schema "1" \
    --arg id "$(date +%Y%m%d)-$(echo "${MSGID}" | sed 's/[<>@]//g; s/[^a-zA-Z0-9.-]/-/g' | cut -c1-60)" \
    --arg title "${TITLE}" \
    --argjson version "${VERSION}" \
    --argjson patch_count "${PATCH_COUNT}" \
    --arg author_name "${AUTHOR_NAME}" \
    --arg author_email "${AUTHOR_EMAIL}" \
    --arg date "${PW_DATE}" \
    --arg subsystem "${SUBSYSTEM}" \
    --arg msgid "${MSGID}" \
    --arg lore_url "${LORE_URL}" \
    --arg pw_url "${PW_URL}" \
    --arg pw_state "${PW_STATE}" \
    --arg generated_at "${GENERATED_AT}" \
    --argjson review "${REVIEW_JSON}" \
    '{
        schema_version: $schema,
        id: $id,
        series: {
            title: $title,
            version: $version,
            patch_count: $patch_count,
            author: { name: $author_name, email: $author_email },
            date: $date,
            subsystem: $subsystem,
            message_id: $msgid,
            lore_url: $lore_url,
            patchwork_url: $pw_url,
            base_branch: "master"
        },
        version_history: [],
        ml_context: {
            patchwork_state: $pw_state,
            reviewed_by: [],
            acked_by: [],
            ci_status: "",
            prior_feedback: [],
            maintainer_activity: ""
        },
        review: ($review + { mode: "ci-single", checkpatch: { status: "not_run", issues: [] } }),
        patches: [],
        generated_at: $generated_at,
        generator: "loupe-review v1.0",
        disclaimer: "LLM-generated draft. Not an authoritative review."
    }' > "${OUTPUT}"

rm -rf "${PATCH_DIR}" "${REVIEW_OUT}"

if jq empty "${OUTPUT}" 2>/dev/null; then
    echo "Review saved: ${OUTPUT}"
    jq -r '.series.title' "${OUTPUT}"
else
    echo "ERROR: Failed to produce valid JSON for ${MSGID}"
    rm -f "${OUTPUT}"
    exit 1
fi
