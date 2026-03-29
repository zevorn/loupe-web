#!/usr/bin/env bash
# Review a single patch: script handles all git/network ops,
# codex only does code analysis on the resulting diff.
# Usage: review-patch.sh <message-id> <output-file> [log-file]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

UA="Mozilla/5.0 (compatible; loupe-review/1.0)"
MSGID="$1"
OUTPUT="$2"
LOG_FILE="${3:-}"
if [ -n "${LOG_FILE}" ]; then
    exec > "${LOG_FILE}" 2>&1
fi
QEMU_DIR="${QEMU_DIR:-$(pwd)/qemu}"

BARE_MSGID=$(echo "${MSGID}" | sed 's/^<//; s/>$//')
ENCODED_MSGID=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "${BARE_MSGID}")

echo "=== Reviewing: ${BARE_MSGID} ==="

# --- Step 1: Patchwork metadata ---
echo "[1/7] Querying Patchwork..."
PW_DATA=$(curl -sL --retry 2 --retry-delay 3 -A "${UA}" "https://patchwork.ozlabs.org/api/patches/?project=qemu-devel&msgid=${ENCODED_MSGID}")
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
        SERIES_DATA=$(curl -sL --retry 2 --retry-delay 3 -A "${UA}" "https://patchwork.ozlabs.org/api/series/${SERIES_ID}/")
        PATCH_COUNT=$(echo "${SERIES_DATA}" | jq '.patches | length' 2>/dev/null || echo 1)
        COVER_TITLE=$(echo "${SERIES_DATA}" | jq -r '.cover_letter.name // empty')
        [ -n "${COVER_TITLE}" ] && TITLE="${COVER_TITLE}"
    fi
fi

# --- Step 2: Fallback to lore ---
if [ -z "${TITLE}" ] || [ "${TITLE}" = "null" ]; then
    echo "[2/7] Fetching from lore..."
    LORE_HDR=$(curl -sL --retry 2 --retry-delay 3 -A "${UA}" "https://lore.kernel.org/qemu-devel/${ENCODED_MSGID}/raw" | head -80)
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
echo "  Author: ${AUTHOR_NAME}, Version: v${VERSION}, Subsystem: ${SUBSYSTEM}"

# --- Step 2.5: Fetch version history and ML context from Patchwork ---
echo "[2.5/7] Fetching version history and mailing list context..."
VH_FILE=$(mktemp)
ML_FILE=$(mktemp)

# Extract subject stem: strip [PATCH vN n/m], [RFC ...], prefixes
SUBJECT_STEM=$(echo "${TITLE}" | sed -E 's/^\[.*\] *//' | sed 's/^ *//')

# Collect R-b/A-b tags and comments for current patch
REVIEWED_BY="[]"
ACKED_BY="[]"
CI_STATUS=""
MAINTAINER_ACTIVITY=""

if [ -n "${SERIES_ID}" ]; then
    # Fetch all patches in current series for R-b / A-b tags
    SERIES_PATCHES=$(curl -sL --retry 2 --retry-delay 3 -A "${UA}" "https://patchwork.ozlabs.org/api/series/${SERIES_ID}/" | jq -r '.patches[]?.id // empty' 2>/dev/null)
    ALL_COMMENTS=""
    for PID in ${SERIES_PATCHES}; do
        PATCH_COMMENTS=$(curl -sL --retry 2 --retry-delay 3 -A "${UA}" "https://patchwork.ozlabs.org/api/patches/${PID}/comments/" 2>/dev/null)
        ALL_COMMENTS="${ALL_COMMENTS}${PATCH_COMMENTS}"
        sleep 0.5
    done
    # Extract Reviewed-by and Acked-by from comments
    REVIEWED_BY=$(echo "${ALL_COMMENTS}" | grep -oE 'Reviewed-by: [^<]*<[^>]+>' | sort -u | jq -Rn '[inputs]' 2>/dev/null || echo '[]')
    ACKED_BY=$(echo "${ALL_COMMENTS}" | grep -oE 'Acked-by: [^<]*<[^>]+>' | sort -u | jq -Rn '[inputs]' 2>/dev/null || echo '[]')
    # CI status from Patchwork checks
    FIRST_PID=$(echo "${SERIES_PATCHES}" | head -1)
    if [ -n "${FIRST_PID}" ]; then
        CI_STATUS=$(curl -sL --retry 2 --retry-delay 3 -A "${UA}" "https://patchwork.ozlabs.org/api/patches/${FIRST_PID}/checks/" | jq -r '.[0].state // empty' 2>/dev/null)
    fi
fi

# Search for prior versions if version > 1
echo '[]' > "${VH_FILE}"
if [ "${VERSION}" -gt 1 ] && [ -n "${SUBJECT_STEM}" ]; then
    echo "  Searching for prior versions of: ${SUBJECT_STEM}"
    ENCODED_STEM=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "${SUBJECT_STEM}")
    PRIOR_PATCHES_FILE=$(mktemp)
    curl -sL --retry 2 --retry-delay 3 -A "${UA}" "https://patchwork.ozlabs.org/api/patches/?project=qemu-devel&q=${ENCODED_STEM}&order=-date&per_page=30" > "${PRIOR_PATCHES_FILE}" 2>/dev/null

    python3 - "${PRIOR_PATCHES_FILE}" "${VH_FILE}" "${VERSION}" "${BARE_MSGID}" << 'VHEOF'
import sys, json

try:
    patches = json.load(open(sys.argv[1]))
except:
    patches = []

out_path = sys.argv[2]
current_ver = int(sys.argv[3])
current_msgid = sys.argv[4]

# Group patches by version, skip current version
versions = {}
for p in (patches if isinstance(patches, list) else []):
    name = p.get("name", "")
    msgid = p.get("msgid", "")
    # Extract version from patch name
    import re
    vm = re.search(r'\bv(\d+)\b', name, re.IGNORECASE)
    ver = int(vm.group(1)) if vm else 1
    if ver >= current_ver:
        continue
    if ver not in versions:
        date = (p.get("date") or "")[:10]
        # Fetch comments for this patch to get review data
        pid = p.get("id")
        series_list = p.get("series", [])
        sid = series_list[0].get("id") if series_list else None
        versions[ver] = {
            "version": ver,
            "date": date,
            "message_id": msgid,
            "patch_id": pid,
            "series_id": sid,
            "key_change": "",
            "review_verdict": "no_review",
            "findings": {"critical": 0, "major": 0, "minor": 0, "nit": 0},
            "key_reviewers": []
        }

# For each prior version, fetch comments to determine review status
import urllib.request
import time
UA = "Mozilla/5.0 (compatible; loupe-review/1.0)"

for ver in sorted(versions.keys()):
    v = versions[ver]
    reviewers = set()
    has_change_request = False

    # Try series-level comment fetch if we have series_id
    patch_ids = []
    if v["series_id"]:
        try:
            time.sleep(0.5)
            req = urllib.request.Request(
                f"https://patchwork.ozlabs.org/api/series/{v['series_id']}/",
                headers={"User-Agent": UA})
            series_data = json.loads(urllib.request.urlopen(req, timeout=10).read())
            patch_ids = [p["id"] for p in series_data.get("patches", [])]
        except:
            pass
    if not patch_ids and v["patch_id"]:
        patch_ids = [v["patch_id"]]

    all_comment_text = ""
    for pid in patch_ids:
        try:
            time.sleep(0.5)
            req = urllib.request.Request(
                f"https://patchwork.ozlabs.org/api/patches/{pid}/comments/",
                headers={"User-Agent": UA})
            comments = json.loads(urllib.request.urlopen(req, timeout=10).read())
            for c in (comments if isinstance(comments, list) else []):
                submitter = c.get("submitter", {}).get("name", "")
                content = c.get("content", "")
                all_comment_text += content + "\n"
                if submitter:
                    reviewers.add(submitter)
        except:
            pass

    # Analyze comments
    rb_tags = re.findall(r'Reviewed-by:\s*([^<\n]+)', all_comment_text)
    ab_tags = re.findall(r'Acked-by:\s*([^<\n]+)', all_comment_text)
    nack = bool(re.search(r'(?i)\bnack\b|not acceptable', all_comment_text))

    if rb_tags or ab_tags:
        v["review_verdict"] = "ready_to_merge"
        v["key_reviewers"] = list(set(r.strip() for r in rb_tags + ab_tags))
    elif nack:
        v["review_verdict"] = "blocked"
        v["key_reviewers"] = list(reviewers)[:3]
    elif reviewers or all_comment_text.strip():
        v["review_verdict"] = "needs_revision"
        v["key_reviewers"] = list(reviewers)[:3]
    else:
        v["review_verdict"] = "no_review"

result = sorted(versions.values(), key=lambda x: x["version"])
# Clean up internal fields
for r in result:
    r.pop("patch_id", None)
    r.pop("series_id", None)

with open(out_path, 'w') as f:
    json.dump(result, f, ensure_ascii=False)
VHEOF

    rm -f "${PRIOR_PATCHES_FILE}"
    VH_COUNT=$(jq 'length' "${VH_FILE}" 2>/dev/null || echo 0)
    echo "  Found ${VH_COUNT} prior version(s)"
else
    echo "  v1 patch, no prior versions"
fi

# Build ml_context JSON
cat > "${ML_FILE}" << MLEOF
{
    "reviewed_by": ${REVIEWED_BY},
    "acked_by": ${ACKED_BY},
    "ci_status": "${CI_STATUS}",
    "prior_feedback": [],
    "maintainer_activity": "${MAINTAINER_ACTIVITY}"
}
MLEOF

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
    DIFF_TEXT=$(curl -sL --retry 2 --retry-delay 3 -A "${UA}" "https://lore.kernel.org/qemu-devel/${ENCODED_MSGID}/raw" 2>/dev/null)
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
WT_SLUG=$(echo "${BARE_MSGID}" | sed 's/@/-/;s/[^a-zA-Z0-9-]/-/g;s/--*/-/g;s/-$//' | cut -c1-40)
REVIEW_BRANCH="review-${WT_SLUG}"
WORKTREE_DIR="${QEMU_DIR}/../loupe-worktree-${WT_SLUG}"
WORKTREE_LOCK="${QEMU_DIR}/.loupe-worktree.lock"

if [ -d "${QEMU_DIR}" ] && [ -n "${DIFF_TEXT}" ]; then
    # Create worktree (flock serializes concurrent git worktree ops)
    (
        flock -w 120 9 || { echo "  WARNING: worktree lock timeout"; exit 1; }
        cd "${QEMU_DIR}"
        git branch -D "${REVIEW_BRANCH}" 2>/dev/null
        git worktree remove --force "${WORKTREE_DIR}" 2>/dev/null
        git worktree add -b "${REVIEW_BRANCH}" "${WORKTREE_DIR}" master 2>&1
    ) 9>"${WORKTREE_LOCK}" || true

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

        # Cleanup worktree (flock serializes concurrent git worktree ops)
        (
            flock -w 60 9 || true
            cd "${QEMU_DIR}"
            git worktree remove --force "${WORKTREE_DIR}" 2>/dev/null
            git branch -D "${REVIEW_BRANCH}" 2>/dev/null
        ) 9>"${WORKTREE_LOCK}" || true
    else
        echo "  WARNING: Could not create worktree"
    fi
else
    echo "  Skipping: no QEMU dir or no patch content"
fi
rm -rf "${B4_DIR}"

echo "  AM: ${AM_STATUS}, Checkpatch: ${CHECKPATCH_RESULT}, Build: ${BUILD_STATUS}"

# --- Step 5: Codex review (full Stage A-E protocol) ---
echo "[5/7] Running codex code review (Stage A-E protocol)..."
REVIEW_OUT=$(mktemp)

PROMPT_FILE=$(mktemp)
# Load the full review protocol
cat "${SCRIPT_DIR}/review-prompt.txt" > "${PROMPT_FILE}"

if [ -n "${COVER_TEXT}" ]; then
    echo -e "\n\nCOVER LETTER:\n${COVER_TEXT}" >> "${PROMPT_FILE}"
fi

echo -e "\nCHECKPATCH RESULT: ${CHECKPATCH_RESULT}" >> "${PROMPT_FILE}"
[ -n "${CHECKPATCH_ISSUES}" ] && echo "${CHECKPATCH_ISSUES}" >> "${PROMPT_FILE}"
echo -e "\nGIT AM STATUS: ${AM_STATUS}" >> "${PROMPT_FILE}"
echo -e "\nBUILD STATUS: ${BUILD_STATUS}" >> "${PROMPT_FILE}"

# Pass full diff (no truncation)
echo -e "\nPATCH:\n${DIFF_TEXT}" >> "${PROMPT_FILE}"

# Run codex with 30-minute timeout
CODEX_EXIT=0
(cd "${QEMU_DIR}" && timeout 1800 codex exec --full-auto "$(cat "${PROMPT_FILE}")") > "${REVIEW_OUT}" 2>&1 || CODEX_EXIT=$?
rm -f "${PROMPT_FILE}"

if [ "${CODEX_EXIT}" -eq 124 ]; then
    echo "  WARNING: Codex review timed out after 30 minutes"
    echo '{"verdict":"unknown","summary":"Review timed out after 30 minutes","stages":{},"findings":[]}' > "${REVIEW_OUT}"
fi

# --- Step 6: Extract review JSON ---
echo "[6/7] Extracting review..."
REVIEW_FILE=$(mktemp)

python3 - "${REVIEW_OUT}" "${REVIEW_FILE}" << 'PYEOF'
import sys, json

text = open(sys.argv[1]).read()

# Extract the review JSON from codex output.
# Two formats are accepted:
#   1. Full schema: {"schema_version":..., "review": {"verdict":..., ...}, ...}
#   2. Review-only: {"verdict":..., "findings":[...], ...}
# MCP tool JSON (thoughtNumber, structuredContent) is excluded.

def is_mcp(obj):
    return any(k in obj for k in ('thoughtNumber', 'structuredContent', 'nextThoughtNeeded'))

def extract_review(obj):
    """Return a review-only dict from either format, or None."""
    if is_mcp(obj):
        return None
    # Full schema: verdict lives inside obj["review"]
    if 'review' in obj and isinstance(obj['review'], dict) and 'verdict' in obj['review']:
        return obj['review']
    # Review-only: verdict at top level
    if 'verdict' in obj:
        return obj
    return None

result = None

# Pass 1: line-based extraction
for line in text.split('\n'):
    line = line.strip()
    if not line.startswith('{') or '"verdict"' not in line:
        continue
    try:
        obj = json.loads(line)
        r = extract_review(obj)
        if r is not None:
            result = r
            break
    except:
        continue

# Pass 2: block-based extraction (largest JSON objects first)
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
            r = extract_review(obj)
            if r is not None:
                result = r
                break
        except:
            continue

if result is None:
    result = {"verdict":"unknown","summary":"AI review failed","stages":{"A":"","B":"","C":"","D":"","E":""},"findings":[]}

# Normalize verdict
VERDICT_MAP = {
    'accept': 'ready_to_merge', 'pass': 'ready_to_merge',
    'looks_good_with_nits': 'ready_to_merge', 'no_findings': 'ready_to_merge',
    'reject': 'blocked',
    'changes_requested': 'needs_revision', 'changes-requested': 'needs_revision',
}
v = result.get('verdict', 'unknown')
result['verdict'] = VERDICT_MAP.get(v, v)
if result['verdict'] not in ('needs_revision', 'ready_to_merge', 'blocked', 'unknown'):
    result['verdict'] = 'needs_revision'

# Normalize severity
SEV_MAP = {'error': 'critical', 'high': 'major', 'medium': 'minor', 'low': 'nit'}
for finding in result.get('findings', []):
    s = finding.get('severity', 'nit')
    finding['severity'] = SEV_MAP.get(s, s)
    if finding['severity'] not in ('critical', 'major', 'minor', 'nit'):
        finding['severity'] = 'nit'

# AC-1 guardrail: warn if needs_revision but no findings
if result['verdict'] == 'needs_revision' and not result.get('findings'):
    print("  WARNING: verdict is needs_revision but findings array is empty", file=sys.stderr)

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

python3 - "${META_FILE}" "${REVIEW_FILE}" "${DIFF_TMPFILE}" "${COVER_TMPFILE}" "${CP_TMPFILE}" "${VH_FILE}" "${ML_FILE}" "${OUTPUT}" << 'PYEOF'
import sys, json
meta = json.load(open(sys.argv[1]))
review = json.load(open(sys.argv[2]))
diff_text = open(sys.argv[3]).read().strip()
cover_text = open(sys.argv[4]).read().strip()
cp_text = open(sys.argv[5]).read().strip()
vh = json.load(open(sys.argv[6]))
ml = json.load(open(sys.argv[7]))
out_path = sys.argv[8]
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
    "version_history": vh,
    "ml_context": ml,
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
    "generator": "loupe:patch-review v1.0",
    "disclaimer": "LLM-generated draft. Not an authoritative review."
}
with open(out_path, 'w') as f:
    json.dump(output, f, indent=2, ensure_ascii=False)
PYEOF

rm -f "${META_FILE}" "${REVIEW_FILE}" "${DIFF_TMPFILE}" "${COVER_TMPFILE}" "${CP_TMPFILE}" "${VH_FILE}" "${ML_FILE}"

# Validate and normalize the output JSON
if [ -f "${OUTPUT}" ] && jq empty "${OUTPUT}" 2>/dev/null; then
    python3 - "${OUTPUT}" << 'VALEOF'
import sys, json

path = sys.argv[1]
with open(path) as f:
    data = json.load(f)

rev = data.get("review", {})

# Normalize verdict
VERDICT_MAP = {
    "accept": "ready_to_merge", "pass": "ready_to_merge",
    "looks_good_with_nits": "ready_to_merge", "no_findings": "ready_to_merge",
    "reject": "blocked",
    "changes_requested": "needs_revision", "changes-requested": "needs_revision",
}
v = rev.get("verdict", "unknown")
rev["verdict"] = VERDICT_MAP.get(v, v)
if rev["verdict"] not in ("needs_revision", "ready_to_merge", "blocked", "unknown"):
    rev["verdict"] = "needs_revision"

# Normalize severity
SEV_MAP = {"error": "critical", "high": "major", "medium": "minor", "low": "nit"}
for f in rev.get("findings", []):
    s = f.get("severity", "nit")
    f["severity"] = SEV_MAP.get(s, s)
    if f["severity"] not in ("critical", "major", "minor", "nit"):
        f["severity"] = "nit"

# Update generator
data["generator"] = "loupe:patch-review v1.0"

with open(path, "w") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
VALEOF
    echo "  Schema validation: normalized"
fi

if [ -f "${OUTPUT}" ] && jq empty "${OUTPUT}" 2>/dev/null; then
    echo "=== Done ==="
    jq -r '"  \(.series.title)\n  Verdict: \(.review.verdict) | Findings: \(.review.findings|length)\n  Checkpatch: \(.review.checkpatch.status) | Build: \(.review.build_status) | AM: \(.review.am_status)"' "${OUTPUT}"
else
    echo "ERROR: invalid JSON output"
    rm -f "${OUTPUT}"
    exit 1
fi
