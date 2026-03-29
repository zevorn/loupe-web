/* ── State ─────────────────────────────────────────────────────────── */
const state = {
    view: 'list',
    listMode: 'patchsets',
    reviews: [],
    reviewCache: {},
    current: null,
    currentMsg: null,
    filters: { search: '', subsystem: '', verdict: '', severity: '', date: '' },
    selectedRow: -1,
    currentPage: 1,
    pageSize: 50
};

/* ── Utilities ─────────────────────────────────────────────────────── */
function $(sel) { return document.querySelector(sel); }
function $$(sel) { return document.querySelectorAll(sel); }

function esc(s) {
    const d = document.createElement('div');
    d.textContent = s;
    return d.innerHTML;
}

function escapeHtml(text, highlightDiff) {
    const escaped = esc(text || '');
    if (!highlightDiff) return escaped;
    return escaped.split('\n').map(line => {
        if (line.startsWith('+')) return '<span class="diff-add">' + line + '</span>';
        if (line.startsWith('-')) return '<span class="diff-del">' + line + '</span>';
        if (line.startsWith('@@')) return '<span class="diff-hdr">' + line + '</span>';
        if (line.startsWith('diff --git')) return '<span class="diff-hdr">' + line + '</span>';
        return line;
    }).join('\n');
}

/* ── Routing ───────────────────────────────────────────────────────── */
function parseHash() {
    const hash = location.hash || '#/';
    if (hash === '#/' || hash === '#' || hash === '') {
        return { view: 'list' };
    }
    if (hash === '#/stats') {
        return { view: 'stats' };
    }
    if (hash.startsWith('#/review/')) {
        const path = decodeURIComponent(hash.slice(9));
        return { view: 'review', path: path };
    }
    if (hash.startsWith('#/message/')) {
        const parts = hash.slice(10).split('/');
        return { view: 'message', rIdx: parseInt(parts[0], 10), mIdx: parseInt(parts[1], 10) };
    }
    return { view: 'list' };
}

function router() {
    const route = parseHash();
    const views = ['list-view', 'review-view', 'message-view', 'stats-view'];
    views.forEach(v => $('#' + v).classList.add('hidden'));

    state.selectedRow = -1;

    if (route.view === 'list') {
        state.view = 'list';
        $('#list-view').classList.remove('hidden');
        renderListView();
        updateNavToggles();
    } else if (route.view === 'stats') {
        state.view = 'stats';
        state.listMode = 'stats';
        $('#stats-view').classList.remove('hidden');
        renderStatsView();
        updateNavToggles();
    } else if (route.view === 'review') {
        state.view = 'review';
        $('#review-view').classList.remove('hidden');
        loadAndRenderReview(route.path);
        updateNavToggles();
    } else if (route.view === 'message') {
        state.view = 'message';
        $('#message-view').classList.remove('hidden');
        renderMessageView(route.rIdx, route.mIdx);
        updateNavToggles();
    }
}

function navigate(hash) {
    location.hash = hash;
}

function updateNavToggles() {
    $$('.nav-toggle').forEach(btn => {
        btn.classList.remove('active');
        const mode = btn.dataset.mode;
        if (state.view === 'list' && state.listMode === mode) btn.classList.add('active');
        if (state.view === 'stats' && mode === 'stats') btn.classList.add('active');
    });
}

/* ── Data Loading ──────────────────────────────────────────────────── */
async function loadIndex() {
    try {
        const r = await fetch('reviews/index.json');
        const d = await r.json();
        state.reviews = d.reviews || [];
        buildSubsystemDropdown();
        router();
    } catch (e) {
        $('#patchsets-body').innerHTML =
            '<tr><td colspan="7" style="text-align:center;color:var(--text-dim);padding:24px;">No review data available.</td></tr>';
    }
}

async function loadReview(path) {
    if (state.reviewCache[path]) {
        return state.reviewCache[path];
    }
    const r = await fetch(path);
    if (!r.ok) throw new Error('HTTP ' + r.status);
    const data = await r.json();
    state.reviewCache[path] = data;
    return data;
}

function parseMbox(mbox) {
    const msgs = [];
    const parts = mbox.split(/^From /m);
    for (const part of parts) {
        if (!part.trim()) continue;
        const lines = part.split('\n');
        let subject = '', author = '', date = '', body = '';
        let inHeader = true;
        let continuationField = '';
        for (let li = 0; li < lines.length; li++) {
            const line = lines[li];
            if (inHeader) {
                if (line.match(/^Subject:\s*/i)) {
                    subject = line.replace(/^Subject:\s*/i, '');
                    continuationField = 'subject';
                } else if (line.match(/^From:\s*/i)) {
                    author = line.replace(/^From:\s*/i, '').replace(/<.*>/, '').trim();
                    continuationField = '';
                } else if (line.match(/^Date:\s*/i)) {
                    const d = line.replace(/^Date:\s*/i, '');
                    const m = d.match(/\d{1,2}\s+\w+\s+\d{4}/);
                    date = m ? m[0] : d.slice(0, 16);
                    continuationField = '';
                } else if (line.match(/^\s+/) && continuationField === 'subject') {
                    subject += ' ' + line.trim();
                } else if (line === '' || line === '\r') {
                    inHeader = false;
                    continuationField = '';
                } else {
                    continuationField = '';
                }
            } else {
                body += line + '\n';
            }
        }
        if (subject || body) msgs.push({ subject, author, date, body });
    }
    return msgs;
}

function buildSubsystemDropdown() {
    const subs = [...new Set(state.reviews.map(r => r.subsystem).filter(Boolean))].sort();
    const sel = $('#filter-subsystem');
    sel.innerHTML = '<option value="">All subsystems</option>';
    subs.forEach(s => {
        const o = document.createElement('option');
        o.value = s;
        o.textContent = s;
        sel.appendChild(o);
    });
}

/* ── Filter Logic ──────────────────────────────────────────────────── */
function getFilters() {
    return {
        search: ($('#filter-search').value || '').toLowerCase().trim(),
        subsystem: $('#filter-subsystem').value,
        verdict: $('#filter-verdict').value,
        date: $('#filter-date').value
    };
}

function applyFilters(reviews) {
    const f = getFilters();
    const now = new Date();
    const today = new Date(now.getFullYear(), now.getMonth(), now.getDate());

    return reviews.filter(r => {
        if (f.search) {
            const hay = (r.title + ' ' + r.author + ' ' + (r.id || '') + ' ' + (r.message_id || '')).toLowerCase();
            if (!hay.includes(f.search)) return false;
        }
        if (f.subsystem && r.subsystem !== f.subsystem) return false;
        if (f.verdict && r.verdict !== f.verdict) return false;
        if (f.date) {
            const rd = new Date(r.date + 'T00:00:00');
            if (f.date === 'today') {
                if (rd.toDateString() !== today.toDateString()) return false;
            }
            if (f.date === 'week') {
                const day = today.getDay() || 7;
                const weekStart = new Date(today);
                weekStart.setDate(today.getDate() - day + 1);
                if (rd < weekStart) return false;
            }
            if (f.date === 'month') {
                if (rd.getFullYear() !== now.getFullYear() || rd.getMonth() !== now.getMonth()) return false;
            }
        }
        return true;
    });
}

function paginate(items) {
    const start = (state.currentPage - 1) * state.pageSize;
    return items.slice(start, start + state.pageSize);
}

/* ── List View Rendering ───────────────────────────────────────────── */
function renderListView() {
    renderStats();
    $('#patchsets-table').classList.remove('hidden');
    $('#list-legend').classList.remove('hidden');
    renderPatchsetsList();
}

function renderStats() {
    const rs = state.reviews;
    const now = new Date();
    const today = new Date(now.getFullYear(), now.getMonth(), now.getDate());
    const day = today.getDay() || 7;
    const weekStart = new Date(today);
    weekStart.setDate(today.getDate() - day + 1);

    $('#stat-total').textContent = rs.length;
    $('#stat-week').textContent = rs.filter(r => new Date(r.date + 'T00:00:00') >= weekStart).length;
    $('#stat-critical').textContent = rs.filter(r => (r.findings || {}).critical > 0).length;
    $('#stat-ready').textContent = rs.filter(function(r) {
        var v = r.verdict || '';
        return v === 'accept' || v === 'ready_to_merge' || v === 'pass'
            || v === 'looks_good_with_nits' || v === 'no_findings';
    }).length;
}

function renderPatchsetsList() {
    const filtered = applyFilters(state.reviews);
    const totalPages = Math.max(1, Math.ceil(filtered.length / state.pageSize));
    if (state.currentPage > totalPages) state.currentPage = totalPages;
    const page = paginate(filtered);

    $('#filter-count').textContent = 'Showing ' + filtered.length + ' of ' + state.reviews.length + ' reviews';

    const tb = $('#patchsets-body');
    if (!page.length) {
        tb.innerHTML = '<tr><td colspan="7" style="text-align:center;color:var(--text-dim);padding:24px;">No reviews match filters.</td></tr>';
        $('#pagination').innerHTML = '';
        return;
    }

    const globalOffset = (state.currentPage - 1) * state.pageSize;
    tb.innerHTML = page.map((r, i) => {
        const idx = globalOffset + i;
        const sel = idx === state.selectedRow ? ' class="selected"' : '';
        return '<tr data-path="' + esc(r.path) + '" data-idx="' + idx + '"' + sel + '>' +
            '<td>' + esc((r.date || '').slice(5)) + '</td>' +
            '<td><a href="#/review/' + encodeURIComponent(r.path) + '">' + esc(r.title || '') + '</a></td>' +
            '<td>' + esc(r.author || '') + '</td>' +
            '<td>' + (r.patch_count || 0) + '</td>' +
            '<td>' + verdictBadge(r.verdict) + '</td>' +
            '<td>' + findingDots(r.findings) + '</td>' +
            '</tr>';
    }).join('');

    renderPagination(totalPages);
}

/* ── Badge / Dot Helpers ───────────────────────────────────────────── */
function verdictBadge(v) {
    var norm = {
        accept: 'ready_to_merge', pass: 'ready_to_merge',
        looks_good_with_nits: 'ready_to_merge', no_findings: 'ready_to_merge',
        reject: 'blocked',
        changes_requested: 'needs_revision'
    };
    var canonical = norm[v] || v || 'unknown';
    if (v && v.indexOf('-') !== -1) {
        var dashed = v.replace(/-/g, '_');
        canonical = norm[dashed] || canonical;
    }
    var map = {
        ready_to_merge: ['ready to merge', 'badge-ok'],
        needs_revision: ['needs revision', 'badge-revision'],
        blocked: ['blocked', 'badge-blocked'],
        unknown: ['unknown', 'badge-stage']
    };
    var entry = map[canonical] || [canonical, 'badge-stage'];
    return '<span class="badge ' + entry[1] + '">' + entry[0] + '</span>';
}

function findingDots(f) {
    if (!f) return '<span style="color:var(--text-dim);">-</span>';
    const d = function(n, cls) {
        return '<span class="finding-dot ' + cls + (n === 0 ? ' dot-zero' : '') + '">' + n + '</span>';
    };
    return '<div class="findings-dots">' +
        d(f.critical || 0, 'dot-critical') +
        d(f.major || 0, 'dot-major') +
        d(f.minor || 0, 'dot-minor') +
        d(f.nit || 0, 'dot-nit') +
        '</div>';
}

/* ── Pagination ────────────────────────────────────────────────────── */
function renderPagination(totalPages) {
    const el = $('#pagination');
    if (totalPages <= 1) {
        el.innerHTML = '';
        return;
    }
    el.innerHTML =
        '<button id="page-prev"' + (state.currentPage <= 1 ? ' disabled' : '') + '>&larr; Prev</button>' +
        '<span>Page ' + state.currentPage + ' of ' + totalPages + '</span>' +
        '<button id="page-next"' + (state.currentPage >= totalPages ? ' disabled' : '') + '>Next &rarr;</button>';

    $('#page-prev').addEventListener('click', () => {
        if (state.currentPage > 1) {
            state.currentPage--;
            state.selectedRow = -1;
            renderListView();
        }
    });
    $('#page-next').addEventListener('click', () => {
        if (state.currentPage < totalPages) {
            state.currentPage++;
            state.selectedRow = -1;
            renderListView();
        }
    });
}

/* ── Keyboard Selection ────────────────────────────────────────────── */
function moveSelection(delta) {
    const rows = $$('#patchsets-body tr[data-idx]');
    if (!rows.length) return;

    const maxIdx = rows.length - 1;
    if (state.selectedRow < 0) {
        state.selectedRow = delta > 0 ? 0 : maxIdx;
    } else {
        state.selectedRow = Math.max(0, Math.min(state.selectedRow + delta, maxIdx));
    }

    rows.forEach((r, i) => r.classList.toggle('selected', i === state.selectedRow));
    if (rows[state.selectedRow]) {
        rows[state.selectedRow].scrollIntoView({ block: 'nearest' });
    }
}

function openSelected() {
    const rows = $$('#patchsets-body tr[data-idx]');
    if (state.selectedRow < 0 || !rows[state.selectedRow]) return;

    const row = rows[state.selectedRow];
    const path = row.dataset.path;
    if (path) navigate('#/review/' + encodeURIComponent(path));
}

function navigateReview(delta) {
    if (state.view !== 'review') return;
    const filtered = applyFilters(state.reviews);
    const currentPath = parseHash().path;
    const idx = filtered.findIndex(r => r.path === currentPath);
    if (idx < 0) return;
    const newIdx = idx + delta;
    if (newIdx < 0 || newIdx >= filtered.length) return;
    navigate('#/review/' + encodeURIComponent(filtered[newIdx].path));
}

/* ── Severity Helpers ──────────────────────────────────────────────── */
function normSev(s) {
    if (!s) return 'nit';
    const m = { critical: 'critical', error: 'critical', major: 'major', high: 'major', minor: 'minor', medium: 'minor', nit: 'nit', low: 'nit' };
    return m[s.toLowerCase()] || 'nit';
}

function sevBadge(sev) {
    const n = normSev(sev);
    const cls = { critical: 'badge-blocked', major: 'badge-stage', minor: 'badge-revision', nit: '' };
    const style = n === 'nit' ? ' style="background:var(--sev-nit);color:#fff;border:1px solid var(--sev-nit);"' : '';
    return '<span class="badge ' + (cls[n] || '') + '"' + style + '>' + esc(sev || 'nit') + '</span>';
}

function stageStatusBadge(status) {
    const m = { ok: 'badge-ok', warning: 'badge-revision', fail: 'badge-blocked' };
    return '<span class="badge ' + (m[status] || '') + '">' + esc(status) + '</span>';
}

function confClass(c) {
    if (!c) return 'conf-low';
    const m = { high: 'conf-high', medium: 'conf-medium', low: 'conf-low' };
    return m[c.toLowerCase()] || 'conf-low';
}

function statusBadge(label, val) {
    if (!val) return '';
    const v = String(val).toLowerCase();
    var cls = '';
    if (v === 'pass' || v === 'ok' || v === 'clean' || v === 'success') cls = 'badge-ok';
    else if (v === 'warning' || v === 'warn') cls = 'badge-revision';
    else if (v === 'fail' || v === 'error') cls = 'badge-blocked';
    else cls = 'badge-stage';
    return '<span style="margin-right:4px;font-size:11px;color:var(--text-muted);">' + esc(label) + ':</span><span class="badge ' + cls + '">' + esc(val) + '</span>';
}

/* ── Review Detail View ───────────────────────────────────────────── */
function renderReviewView() {
    var r = state.current;
    if (!r) { $('#review-view').innerHTML = ''; return; }
    var s = r.series || {};
    var rev = r.review || {};
    var html = '';

    /* 1. Header */
    html += '<a class="nav-back" href="#/">&larr; Back to reviews</a>';
    html += '<h1>' + esc(s.title || '(untitled)') + '</h1>';
    html += '<div class="meta-row">';
    if (s.author) html += '<span>' + esc(s.author.name || '') + ' &lt;' + esc(s.author.email || '') + '&gt;</span><span class="meta-sep">|</span>';
    if (s.date) html += '<span>' + esc(s.date) + '</span><span class="meta-sep">|</span>';
    html += '<span>' + (s.patch_count || 0) + ' patch(es)</span>';
    if (s.base_branch) html += '<span class="meta-sep">|</span><span>base: ' + esc(s.base_branch) + '</span>';
    if (s.lore_url) html += '<span class="meta-sep">|</span><a href="' + esc(s.lore_url) + '" target="_blank">lore</a>';
    if (s.patchwork_url) html += '<span class="meta-sep">|</span><a href="' + esc(s.patchwork_url) + '" target="_blank">patchwork</a>';
    html += '</div>';
    html += '<div style="margin:8px 0;">' + verdictBadge(rev.verdict) + '</div>';
    if (rev.summary) html += '<p style="margin:4px 0 12px;color:var(--text-muted);font-size:12px;">' + esc(rev.summary) + '</p>';

    /* 2. Version History Table */
    var vh = r.version_history;
    if (vh && vh.length) {
        html += '<h2>Version History</h2>';
        html += '<table class="data-table"><thead><tr><th>Version</th><th>Date</th><th>Verdict</th><th>Findings (C/M/m/n)</th><th>Reviewers</th><th>Key Change</th></tr></thead><tbody>';
        vh.forEach(function(v) {
            var isCurrent = s.version && String(v.version) === String(s.version);
            var f = v.findings || {};
            var findingsStr = isCurrent ? '(current)' :
                (f.critical !== undefined ? f.critical + '/' + f.major + '/' + f.minor + '/' + f.nit : '—');
            var verdictStr = isCurrent ? '—' : esc(v.review_verdict || 'no_review');
            var reviewers = Array.isArray(v.key_reviewers) && v.key_reviewers.length ? v.key_reviewers.join(', ') : '—';
            html += '<tr' + (isCurrent ? ' style="background:#fff8e1;"' : '') + '>';
            html += '<td>' + esc(String(v.version || '')) + (isCurrent ? ' (current)' : '') + '</td>';
            html += '<td>' + esc(v.date || '') + '</td>';
            html += '<td>' + verdictStr + '</td>';
            html += '<td>' + findingsStr + '</td>';
            html += '<td>' + esc(reviewers) + '</td>';
            html += '<td>' + esc(v.key_change || '') + '</td>';
            html += '</tr>';
        });
        html += '</tbody></table>';
    }

    /* 3. Mailing List Context */
    var ml = r.ml_context || {};
    html += '<h2>Mailing List Context</h2>';
    html += '<div class="stages">';
    var mlRows = [
        ['Reviewed-by', Array.isArray(ml.reviewed_by) ? ml.reviewed_by.join(', ') : ml.reviewed_by],
        ['Acked-by', Array.isArray(ml.acked_by) ? ml.acked_by.join(', ') : ml.acked_by],
        ['CI Status', ml.ci_status],
        ['Maintainer', ml.maintainer_activity]
    ];
    var hasML = false;
    mlRows.forEach(function(pair) {
        if (pair[1] !== undefined && pair[1] !== null && pair[1] !== '') {
            hasML = true;
            html += '<div class="stage-row"><span class="stage-label">' + esc(pair[0]) + '</span><span class="stage-text">' + esc(String(pair[1])) + '</span></div>';
        }
    });

    /* Prior version reviews */
    var priorVersions = (vh || []).filter(function(v) {
        return !(s.version && String(v.version) === String(s.version));
    });
    if (priorVersions.length) {
        hasML = true;
        var fb = Array.isArray(ml.prior_feedback) ? ml.prior_feedback.join('; ') : (ml.prior_feedback || '');
        if (fb) {
            html += '<div class="stage-row"><span class="stage-label">Prior Feedback</span><span class="stage-text">' + esc(fb) + '</span></div>';
        }
        html += '</div>';
        html += '<h3 style="margin:12px 0 4px;font-size:13px;">Prior Version Reviews</h3>';
        html += '<table class="data-table"><thead><tr><th>Ver</th><th>Verdict</th><th>Findings (C/M/m/n)</th><th>Reviewers</th></tr></thead><tbody>';
        priorVersions.forEach(function(v) {
            var f = v.findings || {};
            var findingsStr = f.critical !== undefined ? f.critical + '/' + f.major + '/' + f.minor + '/' + f.nit : '—';
            var reviewers = Array.isArray(v.key_reviewers) && v.key_reviewers.length ? v.key_reviewers.join(', ') : '—';
            html += '<tr>';
            html += '<td>v' + esc(String(v.version || '')) + '</td>';
            html += '<td>' + esc(v.review_verdict || 'no_review') + '</td>';
            html += '<td>' + findingsStr + '</td>';
            html += '<td>' + esc(reviewers) + '</td>';
            html += '</tr>';
        });
        html += '</tbody></table>';
    } else {
        html += '<div class="stage-row"><span class="stage-label">Prior Versions</span><span class="stage-text">none</span></div>';
        if (!hasML) {
            html += '<div class="stage-row"><span class="stage-label"></span><span class="stage-text" style="color:var(--text-muted);font-style:italic;">No mailing list context available</span></div>';
        }
        html += '</div>';
    }

    /* 4. Review Stages A-E */
    var stages = rev.stages;
    if (stages && typeof stages === 'object') {
        html += '<h2>Review Stages</h2>';
        html += '<div class="stages">';
        ['A', 'B', 'C', 'D', 'E'].forEach(function(key) {
            var st = stages[key];
            if (!st) return;
            html += '<div class="stage-row"><span class="stage-label">Stage ' + key + '</span><span class="stage-text">';
            if (typeof st === 'string') {
                html += esc(st);
            } else if (typeof st === 'object') {
                html += stageStatusBadge(st.status || '') + ' ' + esc(st.summary || '');
            }
            html += '</span></div>';
        });
        html += '</div>';
    }

    /* 5. Thread Tree */
    var reviewIdx = state.reviews.findIndex(function(ri) { return ri.path === parseHash().path; });

    if (r.cover_letter) {
        html += '<h2>Cover Letter</h2>';
        html += '<div class="msg-body"><div class="msg-body-content"><pre>' + escapeHtml(r.cover_letter) + '</pre></div></div>';
    }

    if (r.diff) {
        var msgs = parseMbox(r.diff);
        if (msgs.length) {
            html += '<h2>Thread</h2>';
            html += '<ul class="thread-tree">';
            msgs.forEach(function(m, mIdx) {
                var subj = m.subject || '(no subject)';
                var isPatch = /^\[.*PATCH/.test(subj) || mIdx === 0;
                var isReply = !isPatch && mIdx > 0;
                var hasRb = /Reviewed-by:|Acked-by:/i.test(m.body || '');
                var tags = '';
                if (hasRb) tags += ' <span class="thread-tag-rb">R-b</span>';
                if (isReply) tags += ' <span class="thread-tag-reply">reply</span>';

                var link = '#/message/' + reviewIdx + '/' + mIdx;
                var arrow = isReply ? '<span class="thread-arrow">&crarr;</span>' : '';
                var indent = isReply ? ' style="margin-left:16px;"' : '';

                html += '<li' + indent + '>';
                html += '<span class="thread-entry">';
                if (m.date) html += '<span class="thread-date">' + esc(m.date) + '</span>';
                if (m.author) html += '<span class="thread-author">' + esc(m.author) + '</span>';
                html += arrow + '<span class="thread-subject"><a href="' + link + '">' + esc(subj) + '</a></span>';
                html += tags;
                html += '</span>';
                html += '</li>';
            });
            html += '</ul>';
        }
    }

    /* 6. Findings Summary Bar */
    var findings = rev.findings || [];
    var sevCount = { critical: 0, major: 0, minor: 0, nit: 0 };
    findings.forEach(function(f) { sevCount[normSev(f.severity)]++; });
    html += '<h2>Findings</h2>';
    html += '<div class="findings-summary">';
    html += '<span style="font-weight:600;">' + findings.length + ' finding(s)</span>';
    html += '<span class="finding-dot dot-critical">' + sevCount.critical + '</span>';
    html += '<span class="finding-dot dot-major">' + sevCount.major + '</span>';
    html += '<span class="finding-dot dot-minor">' + sevCount.minor + '</span>';
    html += '<span class="finding-dot dot-nit">' + sevCount.nit + '</span>';
    var cp = rev.checkpatch;
    if (cp && cp.status) html += statusBadge('checkpatch', cp.status);
    if (rev.build_status) html += statusBadge('build', rev.build_status);
    if (rev.am_status) html += statusBadge('am', rev.am_status);
    html += '</div>';

    /* 7. Finding Cards */
    findings.forEach(function(f) {
        html += '<div class="finding">';

        /* Header */
        html += '<div class="finding-header">';
        html += sevBadge(f.severity);
        if (f.stage) html += '<span class="badge badge-stage">' + esc(f.stage) + '</span>';
        if (f.source) html += '<span class="badge badge-source">' + esc(f.source) + '</span>';
        var loc = '';
        if (f.file) {
            loc = f.file;
            if (f.line) loc += ':' + f.line;
        } else if (f.location) {
            loc = f.location;
        }
        if (loc) html += '<span class="file">' + esc(loc) + '</span>';
        if (f.patch_index !== undefined && f.patch_index !== null) html += '<span class="line">patch #' + esc(String(f.patch_index)) + '</span>';
        html += '</div>';

        /* Patch context */
        var ctx = f.patch_context;
        if (ctx && ctx.length) {
            html += '<div class="patch-context">';
            ctx.forEach(function(line) {
                var cls = 'diff-line';
                if (typeof line === 'string') {
                    if (line.startsWith('+')) cls += ' diff-add';
                    else if (line.startsWith('-')) cls += ' diff-del';
                    else if (line.startsWith('@@') || line.startsWith('diff --git')) cls += ' diff-hdr';
                    else cls += ' diff-ctx';
                    html += '<div class="' + cls + '">' + esc(line) + '</div>';
                }
            });
            html += '</div>';
        }

        /* Body */
        html += '<div class="finding-body">';
        if (f.title) html += '<div class="finding-title">' + esc(f.title) + '</div>';
        var desc = f.description || f.detail || '';
        if (desc) html += '<div class="finding-desc">' + esc(desc) + '</div>';
        if (f.suggestion) html += '<pre class="finding-suggestion">' + esc(f.suggestion) + '</pre>';
        html += '</div>';

        /* Footer */
        html += '<div class="finding-footer">';
        if (f.confidence) html += '<span class="confidence ' + confClass(f.confidence) + '">' + esc(f.confidence) + '</span>';
        if (f.confidence_reason) html += '<span style="color:var(--text-dim);">' + esc(f.confidence_reason) + '</span>';
        html += '</div>';

        html += '</div>';
    });

    /* 8. Footer */
    html += '<div style="margin:24px 0 8px;font-size:11px;color:var(--text-dim);text-align:center;">';
    if (r.generator) html += 'Generated by ' + esc(r.generator);
    if (r.generated_at) html += ' at ' + esc(r.generated_at);
    html += '</div>';
    if (r.disclaimer) html += '<div class="disclaimer">' + esc(r.disclaimer) + '</div>';

    $('#review-view').innerHTML = html;
}

async function loadAndRenderReview(path) {
    try {
        state.current = await loadReview(path);
        renderReviewView();
        window.scrollTo(0, 0);
    } catch (e) {
        $('#review-view').innerHTML = '<div class="disclaimer">Review not found.</div><p><a href="#/">&larr; Back</a></p>';
    }
}

function renderMessageView(rIdx, mIdx) {
    const review = state.reviews[rIdx];
    if (!review) { $('#message-view').innerHTML = '<p>Message not found. <a href="#/">Back</a></p>'; return; }
    const cached = state.reviewCache[review.path];
    if (!cached || !cached.diff) {
        // Try to load it
        loadReview(review.path).then(data => {
            state.reviewCache[review.path] = data;
            renderMessageView(rIdx, mIdx);
        }).catch(() => {
            $('#message-view').innerHTML = '<p>Could not load message. <a href="#/">Back</a></p>';
        });
        $('#message-view').innerHTML = '<p>Loading...</p>';
        return;
    }
    const msgs = parseMbox(cached.diff);
    const msg = msgs[mIdx];
    if (!msg) { $('#message-view').innerHTML = '<p>Message not found. <a href="#/">Back</a></p>'; return; }

    // Thread tree (mini, showing position in thread)
    const threadHtml = msgs.map((m, i) => {
        const isCurrent = i === mIdx;
        const isReply = !/\[PATCH/i.test(m.subject) && i > 0;
        const indent = isReply ? ' style="margin-left:16px"' : '';
        const arrow = isReply ? '<span class="thread-arrow">↳</span>' : '';
        const cls = isCurrent ? ' class="thread-current"' : '';
        return `<li${indent}>${arrow}<a href="#/message/${rIdx}/${i}"${cls}>${esc(m.subject || '(no subject)')}</a></li>`;
    }).join('');

    $('#message-view').innerHTML = `
        <p class="nav-back"><a href="#/review/${encodeURIComponent(review.path)}">← Back to review</a></p>
        <h2>${esc(msg.subject || '(no subject)')}</h2>
        <div class="kv"><span class="kv-label">From:</span> ${esc(msg.author || '')}</div>
        <div class="kv"><span class="kv-label">Date:</span> ${esc(msg.date || '')}</div>
        <h3>Thread</h3>
        <ul class="thread-tree">${threadHtml}</ul>
        <h3>Body</h3>
        <div class="msg-body"><pre class="body">${escapeHtml(msg.body || '', true)}</pre></div>`;
}

function renderStatsView() {
    const reviews = state.reviews;
    if (!reviews || reviews.length === 0) {
        $('#stats-view').innerHTML = '<p>No data available.</p>';
        return;
    }

    // Compute summary stats
    const totalReviews = reviews.length;
    let totalFindings = 0;
    const verdictCount = {};
    const severityCount = { Critical: 0, Major: 0, Minor: 0, Nit: 0 };
    const subsystemCount = {};
    const dailyCount = {};

    reviews.forEach(r => {
        var fc = r.findings || {};
        var fcTotal = (fc.critical || 0) + (fc.major || 0) + (fc.minor || 0) + (fc.nit || 0);
        totalFindings += fcTotal;

        // Verdict
        const v = r.verdict || 'Unknown';
        verdictCount[v] = (verdictCount[v] || 0) + 1;

        // Severity
        severityCount.Critical += fc.critical || 0;
        severityCount.Major += fc.major || 0;
        severityCount.Minor += fc.minor || 0;
        severityCount.Nit += fc.nit || 0;

        // Subsystem
        const sub = r.subsystem || 'Unknown';
        subsystemCount[sub] = (subsystemCount[sub] || 0) + 1;

        // Daily timeline
        const day = r.date ? r.date.split(' ')[0] : 'Unknown';
        dailyCount[day] = (dailyCount[day] || 0) + 1;
    });

    const avgFindings = totalFindings > 0 ? (totalFindings / totalReviews).toFixed(1) : '0';
    const topSubsystem = Object.entries(subsystemCount).sort((a, b) => b[1] - a[1])[0];
    const topSubName = topSubsystem ? topSubsystem[0] : 'N/A';

    // Summary cards
    const summaryHtml = `
        <div class="stat-grid">
            <div class="stat-card">
                <div class="stat-label">Total Reviews</div>
                <div class="stat-value">${totalReviews}</div>
            </div>
            <div class="stat-card">
                <div class="stat-label">Total Findings</div>
                <div class="stat-value">${totalFindings}</div>
            </div>
            <div class="stat-card">
                <div class="stat-label">Avg Findings/Review</div>
                <div class="stat-value">${avgFindings}</div>
            </div>
            <div class="stat-card">
                <div class="stat-label">Top Subsystem</div>
                <div class="stat-value" style="font-size:1.2rem;">${esc(topSubName)}</div>
            </div>
        </div>
    `;

    // Chart containers
    const chartsHtml = `
        <div class="chart-row">
            <div class="chart-container" id="chart-timeline"></div>
            <div class="chart-container" id="chart-verdicts"></div>
        </div>
        <div class="chart-row">
            <div class="chart-container" id="chart-severity"></div>
            <div class="chart-container" id="chart-subsystems"></div>
        </div>
    `;

    $('#stats-view').innerHTML = `<h2>Dashboard</h2>${summaryHtml}${chartsHtml}`;

    // Render charts if ECharts is available
    if (typeof echarts === 'undefined') {
        $('#chart-timeline').innerHTML = '<p style="padding:20px;">ECharts not loaded.</p>';
        return;
    }

    const isDark = window.matchMedia('(prefers-color-scheme: dark)').matches;
    const theme = isDark ? 'dark' : null;

    // 1. Timeline chart (daily review count)
    const sortedDays = Object.keys(dailyCount).sort();
    const timelineData = sortedDays.map(d => dailyCount[d]);
    const chartTimeline = echarts.init(document.getElementById('chart-timeline'), theme);
    chartTimeline.setOption({
        title: { text: 'Review Timeline', left: 'center' },
        tooltip: { trigger: 'axis' },
        xAxis: { type: 'category', data: sortedDays, axisLabel: { rotate: 45 } },
        yAxis: { type: 'value' },
        series: [{ name: 'Reviews', type: 'line', data: timelineData, smooth: true }]
    });

    // 2. Verdicts pie chart
    const verdictData = Object.entries(verdictCount).map(([name, value]) => ({ name, value }));
    const chartVerdicts = echarts.init(document.getElementById('chart-verdicts'), theme);
    chartVerdicts.setOption({
        title: { text: 'Verdicts', left: 'center' },
        tooltip: { trigger: 'item' },
        legend: { bottom: 0 },
        series: [{
            name: 'Verdict',
            type: 'pie',
            radius: '50%',
            data: verdictData,
            emphasis: { itemStyle: { shadowBlur: 10, shadowOffsetX: 0, shadowColor: 'rgba(0,0,0,0.5)' } }
        }]
    });

    // 3. Severity bar chart
    const severityData = [
        { name: 'Critical', value: severityCount.Critical, color: '#d32f2f' },
        { name: 'Major', value: severityCount.Major, color: '#1565c0' },
        { name: 'Minor', value: severityCount.Minor, color: '#f59e0b' },
        { name: 'Nit', value: severityCount.Nit, color: '#94a3b8' }
    ];
    const chartSeverity = echarts.init(document.getElementById('chart-severity'), theme);
    chartSeverity.setOption({
        title: { text: 'Findings by Severity', left: 'center' },
        tooltip: { trigger: 'axis', axisPointer: { type: 'shadow' } },
        xAxis: { type: 'category', data: severityData.map(s => s.name) },
        yAxis: { type: 'value' },
        series: [{
            name: 'Count',
            type: 'bar',
            data: severityData.map(s => ({ value: s.value, itemStyle: { color: s.color } }))
        }]
    });

    // 4. Subsystems horizontal bar (top 10)
    const topSubsystems = Object.entries(subsystemCount).sort((a, b) => b[1] - a[1]).slice(0, 10);
    const chartSubsystems = echarts.init(document.getElementById('chart-subsystems'), theme);
    chartSubsystems.setOption({
        title: { text: 'Top 10 Subsystems', left: 'center' },
        tooltip: { trigger: 'axis', axisPointer: { type: 'shadow' } },
        xAxis: { type: 'value' },
        yAxis: { type: 'category', data: topSubsystems.map(s => s[0]).reverse() },
        series: [{ name: 'Reviews', type: 'bar', data: topSubsystems.map(s => s[1]).reverse() }]
    });

    // Responsive resize
    const allCharts = [chartTimeline, chartVerdicts, chartSeverity, chartSubsystems];
    window.addEventListener('resize', () => {
        allCharts.forEach(c => c.resize());
    });
}

/* ── Event Binding ─────────────────────────────────────────────────── */
document.addEventListener('DOMContentLoaded', function() {
    loadIndex();
    window.addEventListener('hashchange', router);

    /* Filter listeners */
    $('#filter-search').addEventListener('input', function() {
        state.currentPage = 1;
        state.selectedRow = -1;
        renderListView();
    });
    $$('.filter-select').forEach(function(el) {
        el.addEventListener('change', function() {
            state.currentPage = 1;
            state.selectedRow = -1;
            renderListView();
        });
    });

    /* Row click delegation — patchsets */
    $('#patchsets-body').addEventListener('click', function(e) {
        const row = e.target.closest('tr[data-path]');
        if (row) {
            navigate('#/review/' + encodeURIComponent(row.dataset.path));
        }
    });

    /* Keyboard navigation */
    document.addEventListener('keydown', function(e) {
        if (e.target.tagName === 'INPUT' || e.target.tagName === 'SELECT') {
            if (e.key === 'Escape') {
                e.target.blur();
                e.preventDefault();
            }
            return;
        }

        switch (e.key) {
            case '/':
                e.preventDefault();
                $('#filter-search').focus();
                break;
            case 'j':
                e.preventDefault();
                if (state.view === 'list') moveSelection(1);
                break;
            case 'k':
                e.preventDefault();
                if (state.view === 'list') moveSelection(-1);
                break;
            case 'Enter':
                e.preventDefault();
                if (state.view === 'list') openSelected();
                break;
            case 'q':
                e.preventDefault();
                if (state.view === 'review' || state.view === 'message') {
                    navigate('#/');
                }
                break;
            case 'h':
                e.preventDefault();
                if (state.view === 'review') navigateReview(-1);
                break;
            case 'l':
                e.preventDefault();
                if (state.view === 'review') navigateReview(1);
                break;
            case 'Escape':
                e.preventDefault();
                if (state.view === 'review' || state.view === 'message' || state.view === 'stats') {
                    navigate('#/');
                }
                break;
        }
    });
});
