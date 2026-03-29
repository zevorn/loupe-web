# loupe-web Optimization Plan

## Goal Description

Optimize loupe-web across three directions:

- **A) Review Quality**: Replace the minimal 7-line Codex prompt in `review-patch.sh` with the full loupe:patch-review Stage A-E protocol, producing structured findings with strict verdict enumeration.
- **B) Frontend Experience**: Split the 1778-line `index.html` into CSS/JS/HTML, fix verdict mapping bugs, fix stats findings counter, replace eager preloading with lazy fetch.
- **C) CI Robustness**: Per-patchset log isolation for parallel workers, 30-minute Codex timeout, Patchwork API rate-limit protection, JSON schema validation before commit.

Repositories affected:
- **loupe-web** (`~/loupe-web`): All changes land here.
- **loupe** (`~/loupe`): No changes needed (patch-review.md protocol already complete).

## Acceptance Criteria

- AC-1: Codex review uses full Stage A-E protocol
  - Positive Tests (expected to PASS):
    - `review-patch.sh` Step 5 prompt references the installed `patch-review.md` skill's Stage A-E sections and JSON schema
    - Codex receives the full untruncated diff (no `head -500`)
    - Output JSON verdict is one of `needs_revision`, `ready_to_merge`, `blocked`
    - Output JSON contains `stages.A` through `stages.E` summaries
    - Findings array entries contain `severity`, `stage`, `file`, `line`, `title`, `description`, `confidence`
  - Negative Tests (expected to FAIL):
    - Verdict values like `accept`, `reject`, `changes_requested`, `pass` are rejected by schema validation
    - Empty findings array with verdict `needs_revision` triggers a warning log

- AC-2: Frontend split into three files
  - Positive Tests (expected to PASS):
    - `docs/index.html` exists as HTML-only (no `<style>` or `<script>` blocks beyond link/src tags)
    - `docs/style.css` contains all CSS including dark mode variables
    - `docs/app.js` contains all JavaScript logic
    - Page loads correctly on GitHub Pages (all three files served)
  - Negative Tests (expected to FAIL):
    - `docs/index.html` containing inline `<style>` or `<script>` with logic (link/src tags are OK)

- AC-3: Verdict mapping covers all known variants
  - Positive Tests (expected to PASS):
    - `verdictBadge('accept')` renders green "ready to merge" badge
    - `verdictBadge('reject')` renders red "blocked" badge
    - `verdictBadge('changes_requested')` renders orange "needs revision" badge
    - `verdictBadge('changes-requested')` renders orange "needs revision" badge
    - `verdictBadge('pass')` renders green "ready to merge" badge
    - `verdictBadge('looks_good_with_nits')` renders green "ready to merge" badge
    - `verdictBadge('no_findings')` renders green "ready to merge" badge
    - `verdictBadge('needs_revision')` renders orange "needs revision" badge
    - `verdictBadge('ready_to_merge')` renders green "ready to merge" badge
    - `verdictBadge('blocked')` renders red "blocked" badge
  - Negative Tests (expected to FAIL):
    - No verdict value renders as plain text "unknown" (all values get a colored badge)

- AC-4: Stats view findings counter works correctly
  - Positive Tests (expected to PASS):
    - `renderStatsView()` reads findings from index.json `{critical, major, minor, nit}` object format
    - Severity bar chart shows correct counts matching index data
  - Negative Tests (expected to FAIL):
    - Iterating `r.findings` as an array (index.json has object, not array)

- AC-5: Lazy loading replaces eager preload
  - Positive Tests (expected to PASS):
    - Page load fetches only `reviews/index.json`, no individual review JSONs
    - Entering review detail view fetches the single review JSON on demand
    - Messages view loads diffs on demand when accessed
  - Negative Tests (expected to FAIL):
    - `preloadAllReviews()` function exists or is called

- AC-6: Per-patchset log isolation
  - Positive Tests (expected to PASS):
    - Each parallel worker redirects stdout/stderr to `${DATE_DIR}/${SLUG}.log`
    - After all workers complete, a summary line is printed for each patchset (verdict + findings count)
    - Log files are committed alongside review JSONs
  - Negative Tests (expected to FAIL):
    - Two parallel workers writing interleaved output to the same stdout

- AC-7: Codex timeout at 30 minutes
  - Positive Tests (expected to PASS):
    - `codex exec` is wrapped with `timeout 1800`
    - On timeout, review JSON is still generated with `verdict: "unknown"` and `summary: "Review timed out"`
  - Negative Tests (expected to FAIL):
    - A hung Codex process blocks the worker indefinitely

- AC-8: Patchwork API rate-limit protection
  - Positive Tests (expected to PASS):
    - Version history Python script includes `time.sleep(0.5)` between HTTP requests
    - All `curl` invocations include `--retry 2 --retry-delay 3`
  - Negative Tests (expected to FAIL):
    - Burst of 10+ concurrent HTTP requests to Patchwork API within 1 second

- AC-9: JSON schema validation before commit
  - Positive Tests (expected to PASS):
    - After Codex review completes, verdict is validated against `needs_revision|ready_to_merge|blocked`
    - Non-conforming verdict values are normalized (e.g., `accept` → `ready_to_merge`)
    - Findings severity values are normalized to `critical|major|minor|nit`
  - Negative Tests (expected to FAIL):
    - A review JSON with `verdict: "reject"` passes through to commit without normalization

## Path Boundaries

### Upper Bound (Maximum Acceptable Scope)

All three directions fully implemented: Codex uses complete Stage A-E protocol with full diff, frontend is cleanly split into 3 files with all bugs fixed and lazy loading, CI has per-patchset logs, 30-min timeout, API protection, and schema validation. Existing review JSONs are retroactively normalized.

### Lower Bound (Minimum Acceptable Scope)

Codex prompt upgraded with strict verdict/severity enumeration (may not include full Stage A-E text inline). Frontend split into 3 files with verdict bug fixed. CI has timeout and log isolation. Schema validation normalizes verdict only.

### Allowed Choices

- Can use: vanilla HTML/CSS/JS, bash/jq/python3 for scripts, standard GitHub Actions
- Cannot use: npm/node dependencies, CSS/JS frameworks, build tools
- Fixed: JSON schema from loupe:patch-review v1.0, severity color scheme, monospace font stack

## Dependencies and Sequence

### Milestones

1. **Milestone 1: CI review quality** (Direction A)
   - Phase A: Extract Stage A-E protocol and JSON schema into a CI-specific prompt template
   - Phase B: Rewrite review-patch.sh Step 5 to use full protocol, remove diff truncation
   - Phase C: Add verdict/severity normalization in Step 6 JSON extraction

2. **Milestone 2: CI robustness** (Direction C)
   - Phase A: Per-patchset log isolation and summary
   - Phase B: Codex 30-minute timeout with fallback JSON
   - Phase C: Patchwork API rate-limit protection (sleep + curl retry)
   - Phase D: JSON schema validation gate

3. **Milestone 3: Frontend optimization** (Direction B)
   - Phase A: Split index.html into index.html + style.css + app.js
   - Phase B: Fix verdict mapping and stats findings bug
   - Phase C: Replace preloadAllReviews with lazy loading
   - Phase D: Retroactively normalize existing review JSON verdicts

Dependencies: Milestone 1 Phase C (normalization) should complete before Milestone 3 Phase D (retroactive normalization uses the same logic). Milestones 1 and 2 are independent. Milestone 3 Phase A (split) should be done first within Milestone 3 to avoid merge conflicts.

## Implementation Notes

### Code Style Requirements
- Shell scripts use `set -euo pipefail`, consistent variable naming
- JavaScript uses `var` for compatibility (no build step, no transpilation)
- All commits signed with: `Signed-off-by: Chao Liu <chao.liu.zevorn@gmail.com>`
- No AI-related co-author signatures in commits
- Comments in English, concise, only where logic is non-obvious

## File Map

### loupe-web repo (`~/loupe-web`)

| File | Action | Responsibility |
|------|--------|---------------|
| `scripts/review-patch.sh` | Modify | Full protocol prompt, timeout, log isolation, API protection, schema validation |
| `docs/index.html` | Rewrite | HTML structure only (no inline CSS/JS) |
| `docs/style.css` | Create | All CSS extracted from index.html |
| `docs/app.js` | Create | All JS extracted from index.html, with bug fixes and lazy loading |
| `.github/workflows/daily-review.yml` | Modify | Log file handling, summary output |
| `scripts/normalize-verdicts.sh` | Create | One-time script to normalize existing review JSONs |

---

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

---

## Task 1: Extract CI review prompt from patch-review.md

**Files:** `scripts/review-prompt.txt`

- [ ] **Step 1:** Read `~/.claude/commands/loupe/patch-review.md` and extract the following sections into `scripts/review-prompt.txt`:
  - Step 9: Multi-stage code review protocol (Stage A through E, complete text)
  - Step 12: JSON schema template (complete schema)
  - Severity classification rules from Stage E
  - Verdict enumeration: `needs_revision`, `ready_to_merge`, `blocked`

- [ ] **Step 2:** Add a CI-specific preamble to the prompt file:
  ```
  You are reviewing a QEMU patch series. The patch has already been
  downloaded, applied, and tested. Your job is ONLY code review.

  Follow the five-stage review protocol below exactly. Output a single
  JSON object conforming to the schema at the end.

  STRICT RULES:
  - verdict MUST be one of: needs_revision, ready_to_merge, blocked
  - severity MUST be one of: critical, major, minor, nit
  - Each finding MUST include: file, line, title, description, confidence
  - stages MUST include A through E summaries
  ```

- [ ] **Step 3:** Commit:
  ```
  feat: extract Stage A-E review protocol as CI prompt template

  Signed-off-by: Chao Liu <chao.liu.zevorn@gmail.com>
  ```

## Task 2: Rewrite review-patch.sh Step 5 with full protocol

**Files:** `scripts/review-patch.sh`

- [ ] **Step 1:** Replace Step 5 prompt construction (lines ~352-380):
  - Read prompt from `${SCRIPT_DIR}/review-prompt.txt`
  - Append cover letter text (if any)
  - Append checkpatch result and build/am status
  - Append the **full** diff (`${DIFF_TEXT}`, remove `head -500` truncation)
  - Write combined prompt to temp file

- [ ] **Step 2:** Update `codex exec` invocation:
  - Wrap with `timeout 1800` (30 minutes)
  - On timeout (exit code 124), generate fallback JSON:
    ```json
    {"verdict":"unknown","summary":"Review timed out after 30 minutes","stages":{},"findings":[]}
    ```
  - Run Codex in QEMU dir for source context: `(cd "${QEMU_DIR}" && timeout 1800 codex exec --full-auto "$(cat "${PROMPT_FILE}")")`

- [ ] **Step 3:** Update Step 6 JSON extraction to add normalization:
  - After extracting review JSON, normalize verdict:
    ```python
    VERDICT_MAP = {
        'accept': 'ready_to_merge', 'pass': 'ready_to_merge',
        'looks_good_with_nits': 'ready_to_merge', 'no_findings': 'ready_to_merge',
        'reject': 'blocked',
        'changes_requested': 'needs_revision', 'changes-requested': 'needs_revision',
    }
    result['verdict'] = VERDICT_MAP.get(result.get('verdict',''), result.get('verdict','unknown'))
    if result['verdict'] not in ('needs_revision', 'ready_to_merge', 'blocked', 'unknown'):
        result['verdict'] = 'needs_revision'
    ```
  - Normalize findings severity:
    ```python
    SEV_MAP = {'error': 'critical', 'high': 'major', 'medium': 'minor', 'low': 'nit'}
    for f in result.get('findings', []):
        f['severity'] = SEV_MAP.get(f.get('severity',''), f.get('severity','nit'))
    ```

- [ ] **Step 4:** Commit:
  ```
  feat: use full Stage A-E protocol for Codex review with 30min timeout

  - Replace minimal 7-line prompt with extracted review-prompt.txt
  - Remove diff truncation (head -500), pass full diff to Codex
  - Add timeout 1800 wrapper with fallback JSON on timeout
  - Normalize verdict and severity values after extraction

  Signed-off-by: Chao Liu <chao.liu.zevorn@gmail.com>
  ```

## Task 3: Per-patchset log isolation

**Files:** `scripts/review-patch.sh`, `.github/workflows/daily-review.yml`

- [ ] **Step 1:** In `review-patch.sh`, accept optional 3rd argument `LOG_FILE`:
  ```bash
  LOG_FILE="${3:-}"
  if [ -n "${LOG_FILE}" ]; then
      exec > "${LOG_FILE}" 2>&1
  fi
  ```

- [ ] **Step 2:** In `daily-review.yml`, update `review_one()` function:
  ```bash
  review_one() {
      local msgid="$1"
      local slug
      slug=$(echo "${msgid}" | sed 's/[<>]//g; s/@/-at-/; s/[^a-zA-Z0-9._-]/-/g' | cut -c1-80)
      local output="${DATE_DIR}/${slug}.json"
      local logfile="${DATE_DIR}/${slug}.log"
      bash scripts/review-patch.sh "${msgid}" "${output}" "${logfile}" || \
          echo "[FAIL] ${msgid}" >> "${DATE_DIR}/_summary.log"
  }
  ```

- [ ] **Step 3:** After `xargs` completes, print summary:
  ```bash
  echo "=== Review Summary ==="
  for f in "${DATE_DIR}"/*.json; do
      [ -f "$f" ] || continue
      jq -r '"  \(.series.title // "unknown") -> \(.review.verdict) (\(.review.findings | length) findings)"' "$f" 2>/dev/null || echo "  $(basename "$f"): invalid JSON"
  done
  ```

- [ ] **Step 4:** Update `.gitignore` to NOT ignore `.log` files in `docs/reviews/` (they should be committed for debugging).

- [ ] **Step 5:** Commit:
  ```
  feat: per-patchset log isolation for parallel workers

  Each worker redirects stdout/stderr to a dedicated .log file.
  After all workers complete, a summary is printed with verdict
  and findings count per patchset.

  Signed-off-by: Chao Liu <chao.liu.zevorn@gmail.com>
  ```

## Task 4: Patchwork API rate-limit protection

**Files:** `scripts/review-patch.sh`

- [ ] **Step 1:** Add `--retry 2 --retry-delay 3` to all `curl` invocations in the script.

- [ ] **Step 2:** In the version history Python script (Step 2.5 VHEOF block), add rate limiting:
  ```python
  import time
  # ... inside the per-version loop:
  time.sleep(0.5)  # Rate limit: max 2 requests/second
  ```

- [ ] **Step 3:** Add the same sleep between the current-patch comment fetches (the bash `for PID in ${SERIES_PATCHES}` loop):
  ```bash
  for PID in ${SERIES_PATCHES}; do
      PATCH_COMMENTS=$(curl -sL --retry 2 --retry-delay 3 -A "${UA}" "https://patchwork.ozlabs.org/api/patches/${PID}/comments/" 2>/dev/null)
      ALL_COMMENTS="${ALL_COMMENTS}${PATCH_COMMENTS}"
      sleep 0.5
  done
  ```

- [ ] **Step 4:** Commit:
  ```
  fix: add Patchwork API rate-limit protection

  - curl: --retry 2 --retry-delay 3 on all requests
  - Python urllib: 0.5s sleep between version history requests
  - Bash loop: 0.5s sleep between comment fetches

  Signed-off-by: Chao Liu <chao.liu.zevorn@gmail.com>
  ```

## Task 5: JSON schema validation gate

**Files:** `scripts/review-patch.sh`

- [ ] **Step 1:** After the Python assembly script (Step 7), add validation before the final success check:
  ```bash
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

  with open(path, "w") as f:
      json.dump(data, f, indent=2, ensure_ascii=False)
  VALEOF
  fi
  ```

- [ ] **Step 2:** Commit:
  ```
  feat: add JSON schema validation and normalization gate

  After Codex review, normalize verdict and severity values to
  conform to the loupe:patch-review v1.0 schema before committing.

  Signed-off-by: Chao Liu <chao.liu.zevorn@gmail.com>
  ```

## Task 6: Split index.html into HTML + CSS + JS

**Files:** `docs/index.html`, `docs/style.css`, `docs/app.js`

- [ ] **Step 1:** Extract all content between `<style>` tags (lines 8-634) into `docs/style.css`. Remove the `<style>` block from index.html and add:
  ```html
  <link rel="stylesheet" href="style.css">
  ```

- [ ] **Step 2:** Extract all content between `<script>` tags (lines 738-1776) into `docs/app.js`. Remove the `<script>` block from index.html and add before `</body>`:
  ```html
  <script src="app.js"></script>
  ```

- [ ] **Step 3:** Keep the ECharts CDN `<script>` tag in index.html `<head>`.

- [ ] **Step 4:** Verify the split by checking that index.html contains no `<style>` blocks and no `<script>` blocks with logic (only src/link references).

- [ ] **Step 5:** Commit:
  ```
  refactor: split index.html into HTML + CSS + JS

  Extract style.css (all CSS including dark mode) and app.js (all
  JavaScript logic) from the monolithic index.html. ECharts CDN
  reference stays in the HTML head.

  Signed-off-by: Chao Liu <chao.liu.zevorn@gmail.com>
  ```

## Task 7: Fix verdict mapping and stats bugs in app.js

**Files:** `docs/app.js`

- [ ] **Step 1:** Update `verdictBadge()` to cover all known verdict variants:
  ```javascript
  function verdictBadge(v) {
      // Normalize to canonical values
      var norm = {
          accept: 'ready_to_merge', pass: 'ready_to_merge',
          looks_good_with_nits: 'ready_to_merge', no_findings: 'ready_to_merge',
          reject: 'blocked',
          changes_requested: 'needs_revision', 'changes-requested': 'needs_revision'
      };
      var canonical = norm[v] || v || 'unknown';
      var map = {
          ready_to_merge: ['ready to merge', 'badge-ok'],
          needs_revision: ['needs revision', 'badge-revision'],
          blocked: ['blocked', 'badge-blocked'],
          unknown: ['unknown', 'badge-stage']
      };
      var entry = map[canonical] || [canonical, 'badge-stage'];
      return '<span class="badge ' + entry[1] + '">' + entry[0] + '</span>';
  }
  ```

- [ ] **Step 2:** Fix `renderStatsView()` findings counting — read from index object instead of array:
  ```javascript
  // OLD (broken): findings.forEach(f => { ... })
  // NEW: read directly from the pre-computed object
  var fc = r.findings || {};
  severityCount.Critical += fc.critical || 0;
  severityCount.Major += fc.major || 0;
  severityCount.Minor += fc.minor || 0;
  severityCount.Nit += fc.nit || 0;
  totalFindings += (fc.critical || 0) + (fc.major || 0) + (fc.minor || 0) + (fc.nit || 0);
  ```

- [ ] **Step 3:** Update `renderStats()` top bar to also normalize verdict for counting:
  ```javascript
  $('#stat-ready').textContent = rs.filter(function(r) {
      var v = r.verdict || '';
      return v === 'accept' || v === 'ready_to_merge' || v === 'pass'
          || v === 'looks_good_with_nits' || v === 'no_findings';
  }).length;
  ```

- [ ] **Step 4:** Commit:
  ```
  fix: verdict badge mapping and stats findings counter

  - verdictBadge() now normalizes all known verdict variants to
    canonical values with correct colored badges
  - renderStatsView() reads findings from index object format
    instead of trying to iterate non-existent array
  - renderStats() counts ready reviews across all accept-like verdicts

  Signed-off-by: Chao Liu <chao.liu.zevorn@gmail.com>
  ```

## Task 8: Replace preloadAllReviews with lazy loading

**Files:** `docs/app.js`

- [ ] **Step 1:** Remove the `preloadAllReviews()` function entirely.

- [ ] **Step 2:** Remove the `preloadAllReviews()` call from `loadIndex()`.

- [ ] **Step 3:** Remove `state.messages` array and `state.loading` object from state. Remove `renderMessagesList()` and the messages table/view from the list view (or convert to on-demand loading when the user clicks into a review).

- [ ] **Step 4:** Update `loadAndRenderReview()` — this already fetches on demand via `loadReview()`, no changes needed.

- [ ] **Step 5:** Update `renderMessageView()` — it already handles the case where the review isn't cached and fetches on demand. No changes needed.

- [ ] **Step 6:** The Messages tab in the nav can either:
  - Be removed (simplest, since it required preloading all reviews to build the message list)
  - Or be converted to show messages from only the currently loaded reviews in cache

  Recommend removal to match the lazy loading model. Remove the Messages nav toggle and related DOM elements.

- [ ] **Step 7:** Commit:
  ```
  perf: replace eager preload with lazy review loading

  Remove preloadAllReviews() which fetched all review JSONs on page
  load. Reviews are now loaded on demand when the user opens a detail
  view. Remove the Messages tab which depended on preloading all diffs.

  Signed-off-by: Chao Liu <chao.liu.zevorn@gmail.com>
  ```

## Task 9: Normalize existing review JSONs

**Files:** `scripts/normalize-verdicts.sh`

- [ ] **Step 1:** Create `scripts/normalize-verdicts.sh`:
  ```bash
  #!/usr/bin/env bash
  # One-time normalization of verdict and severity values in existing review JSONs.
  set -euo pipefail
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  REVIEWS_DIR="${SCRIPT_DIR}/../docs/reviews"

  find "${REVIEWS_DIR}" -name '*.json' -not -name 'index.json' | while IFS= read -r f; do
      python3 -c "
  import sys, json
  with open(sys.argv[1]) as fh:
      data = json.load(fh)
  rev = data.get('review', {})
  VM = {'accept':'ready_to_merge','pass':'ready_to_merge','looks_good_with_nits':'ready_to_merge',
        'no_findings':'ready_to_merge','reject':'blocked',
        'changes_requested':'needs_revision','changes-requested':'needs_revision'}
  v = rev.get('verdict','unknown')
  rev['verdict'] = VM.get(v, v)
  if rev['verdict'] not in ('needs_revision','ready_to_merge','blocked','unknown'):
      rev['verdict'] = 'needs_revision'
  SM = {'error':'critical','high':'major','medium':'minor','low':'nit'}
  for f in rev.get('findings',[]):
      s = f.get('severity','nit')
      f['severity'] = SM.get(s, s)
  with open(sys.argv[1],'w') as fh:
      json.dump(data, fh, indent=2, ensure_ascii=False)
  " "$f"
  done

  echo "Normalization complete. Run update-index.sh to rebuild index."
  ```

- [ ] **Step 2:** Run the script: `bash scripts/normalize-verdicts.sh && bash scripts/update-index.sh`

- [ ] **Step 3:** Commit:
  ```
  fix: normalize verdict and severity in existing review JSONs

  Run one-time normalization to map legacy verdict values (accept,
  reject, changes_requested, etc.) to canonical schema values
  (ready_to_merge, blocked, needs_revision). Rebuild index.json.

  Signed-off-by: Chao Liu <chao.liu.zevorn@gmail.com>
  ```
