#!/usr/bin/env bash
# Rebuild docs/reviews/index.json from individual review JSON files.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REVIEWS_DIR="${REPO_ROOT}/docs/reviews"
INDEX_FILE="${REVIEWS_DIR}/index.json"

review_files=$(find "${REVIEWS_DIR}" -name '*.json' -not -name 'index.json' | sort)

if [ -z "${review_files}" ]; then
    jq -n --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{ updated_at: $ts, reviews: [] }' > "${INDEX_FILE}"
    echo "Updated ${INDEX_FILE} with 0 reviews."
    exit 0
fi

entries=$(echo "${review_files}" | while IFS= read -r f; do
    rel_path="${f#${REPO_ROOT}/docs/}"
    jq -c --arg path "${rel_path}" '{
        id: .id,
        path: $path,
        title: .series.title,
        author: .series.author.name,
        date: .series.date,
        subsystem: .series.subsystem,
        version: .series.version,
        patch_count: .series.patch_count,
        message_id: .series.message_id,
        verdict: .review.verdict,
        findings: {
            critical: ([.review.findings[] | select(.severity == "critical" or .severity == "error")] | length),
            major: ([.review.findings[] | select(.severity == "major" or .severity == "high")] | length),
            minor: ([.review.findings[] | select(.severity == "minor" or .severity == "medium")] | length),
            nit: ([.review.findings[] | select(.severity == "nit" or .severity == "low")] | length)
        }
    }' "${f}"
done | jq -s 'sort_by(.date) | reverse')

jq -n --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson reviews "${entries}" \
    '{ updated_at: $ts, reviews: $reviews }' > "${INDEX_FILE}"

count=$(echo "${entries}" | jq length)
echo "Updated ${INDEX_FILE} with ${count} reviews."
