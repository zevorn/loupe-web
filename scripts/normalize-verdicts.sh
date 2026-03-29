#!/usr/bin/env bash
# One-time normalization of verdict and severity values in existing review JSONs.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REVIEWS_DIR="${SCRIPT_DIR}/../docs/reviews"

COUNT=0
find "${REVIEWS_DIR}" -name '*.json' -not -name 'index.json' | while IFS= read -r f; do
    python3 -c "
import sys, json
with open(sys.argv[1]) as fh:
    data = json.load(fh)
rev = data.get('review', {})
changed = False
VM = {'accept':'ready_to_merge','pass':'ready_to_merge','looks_good_with_nits':'ready_to_merge',
      'no_findings':'ready_to_merge','reject':'blocked',
      'changes_requested':'needs_revision','changes-requested':'needs_revision'}
v = rev.get('verdict','unknown')
new_v = VM.get(v, v)
if new_v not in ('needs_revision','ready_to_merge','blocked','unknown'):
    new_v = 'needs_revision'
if new_v != v:
    rev['verdict'] = new_v
    changed = True
SM = {'error':'critical','high':'major','medium':'minor','low':'nit'}
for f in rev.get('findings',[]):
    s = f.get('severity','nit')
    new_s = SM.get(s, s)
    if new_s != s:
        f['severity'] = new_s
        changed = True
if changed:
    with open(sys.argv[1],'w') as fh:
        json.dump(data, fh, indent=2, ensure_ascii=False)
    print(f'  Normalized: {sys.argv[1]}')
" "$f"
done

echo "Normalization complete. Run update-index.sh to rebuild index."
