#!/usr/bin/env bash
# Query Patchwork API for new QEMU RISC-V patches in the last 24 hours.
# Filters out already-reviewed patches by matching message_id and series
# subject stem. Outputs: /tmp/new-patches.json (JSON array of message-ids)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REVIEWS_DIR="${REPO_ROOT}/docs/reviews"

# Configurable time window (default 48h)
HOURS_AGO="${LOUPE_FETCH_HOURS:-48}"
SINCE=$(date -u -d "${HOURS_AGO} hours ago" +%Y-%m-%dT%H:%M:%S 2>/dev/null \
    || date -u -v-${HOURS_AGO}H +%Y-%m-%dT%H:%M:%S)

API_URL="https://patchwork.ozlabs.org/api/patches/"
PARAMS="project=qemu-devel&q=riscv&since=${SINCE}&order=-date&per_page=50"

echo "Fetching QEMU RISC-V patches since ${SINCE}..."

curl -sL "${API_URL}?${PARAMS}" -o /tmp/patchwork-response.json

PATCH_COUNT=$(jq length /tmp/patchwork-response.json 2>/dev/null || echo 0)
echo "Patchwork returned ${PATCH_COUNT} patches."

# Build dedup sets from existing review JSON files:
# 1. Existing message_ids (exact match)
# 2. Existing series titles stripped of version (subject stem match)
EXISTING_MSGIDS=$(mktemp)
EXISTING_STEMS=$(mktemp)

find "${REVIEWS_DIR}" -name '*.json' -not -name 'index.json' -print0 2>/dev/null \
    | xargs -0 -I{} jq -r '.series.message_id // empty' {} \
    > "${EXISTING_MSGIDS}" 2>/dev/null || true

find "${REVIEWS_DIR}" -name '*.json' -not -name 'index.json' -print0 2>/dev/null \
    | xargs -0 -I{} jq -r '
        .series.title // empty
        | gsub("\\[PATCH[^]]*\\]\\s*"; "")
        | gsub("\\[RFC[^]]*\\]\\s*"; "")
        | ltrimstr(" ") | rtrimstr(" ")
        | ascii_downcase
    ' {} \
    > "${EXISTING_STEMS}" 2>/dev/null || true

echo "Existing reviews: $(wc -l < "${EXISTING_MSGIDS}" | tr -d ' ') by msgid, $(wc -l < "${EXISTING_STEMS}" | tr -d ' ') by stem."

# Extract candidate message-ids grouped by series
# Standalone patches (no series): keep each individually
# Series patches: group by series_id, prefer cover letter
CANDIDATES=$(jq -r '
    [.[] | {
        msgid: .msgid,
        name: .name,
        series_id: (.series[0].id // null),
        is_cover: (.name | test("[[:space:]]0/[0-9]") // false)
    }]
    | (
        [.[] | select(.series_id == null) | .msgid]
    ) + (
        [.[] | select(.series_id != null)]
        | group_by(.series_id)
        | map(
            (map(select(.is_cover)) | first // null)
            // .[0]
            | .msgid
        )
    )
    | .[]
' /tmp/patchwork-response.json 2>/dev/null || echo "")

if [ -z "${CANDIDATES}" ]; then
    echo "No candidate patches found."
    echo '[]' > /tmp/new-patches.json
    rm -f "${EXISTING_MSGIDS}" "${EXISTING_STEMS}"
    exit 0
fi

# Filter step 1: remove exact message_id matches
if [ -s "${EXISTING_MSGIDS}" ]; then
    AFTER_MSGID=$(echo "${CANDIDATES}" | grep -v -F -f "${EXISTING_MSGIDS}" || true)
else
    AFTER_MSGID="${CANDIDATES}"
fi

# Filter step 2: remove patches whose subject stem already reviewed
# (catches re-submissions with new message_id but same series title)
FINAL=""
while IFS= read -r msgid; do
    [ -z "${msgid}" ] && continue
    # Get the name/subject for this msgid from the patchwork response
    STEM=$(jq -r --arg mid "${msgid}" '
        .[] | select(.msgid == $mid) | .name // ""
        | gsub("\\[PATCH[^]]*\\]\\s*"; "")
        | gsub("\\[RFC[^]]*\\]\\s*"; "")
        | ltrimstr(" ") | rtrimstr(" ")
        | ascii_downcase
    ' /tmp/patchwork-response.json 2>/dev/null)

    if [ -n "${STEM}" ] && [ -s "${EXISTING_STEMS}" ] && grep -qxF "${STEM}" "${EXISTING_STEMS}"; then
        echo "Skipping (stem match): ${msgid}"
        continue
    fi
    FINAL="${FINAL}${msgid}\n"
done <<< "${AFTER_MSGID}"

# Output as JSON array
printf '%b' "${FINAL}" | sed '/^$/d' | jq -R -s 'split("\n") | map(select(. != ""))' \
    > /tmp/new-patches.json

rm -f "${EXISTING_MSGIDS}" "${EXISTING_STEMS}"

COUNT=$(jq length /tmp/new-patches.json)
echo "Found ${COUNT} new patch series to review."
