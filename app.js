'use strict';

// Column schema. group headers span consecutive same-group columns.
const COLS = [
  { key: 'n',      label: '종목',      group: '종목',       fmt: 'name' },
  { key: 'type',   label: '제품',      group: '분류',       fmt: 'type' },
  { key: 'step',   label: '세부공정',  group: '분류',       fmt: 'text' },
  { key: 'cust',   label: '고객사',    group: '분류',       fmt: 'cust' },
  { key: 'mc',     label: '시총(억)',  group: '기본',       fmt: 'int' },
  { key: 'price',  label: '종가',      group: '기본',       fmt: 'int' },
  { key: 'w',      label: '1W',       group: '수익률(%)',   fmt: 'pct' },
  { key: 'm',      label: '1M',       group: '수익률(%)',   fmt: 'pct' },
  { key: 'y',      label: 'YTD',      group: '수익률(%)',   fmt: 'pct' },
  { key: 'per',    label: 'PER',      group: 'Valuation',  fmt: 'f1' },
  { key: 'pbr',    label: 'PBR',      group: 'Valuation',  fmt: 'f1' },
  { key: 'fwPer',  label: 'fPER',     group: 'Valuation',  fmt: 'f1' },
  { key: 'fwPbr',  label: 'fPBR',     group: 'Valuation',  fmt: 'f1' },
  { key: 'fxPct',  label: '외국인%',   group: '수급',        fmt: 'f1' },
  { key: 'fxNet',  label: '외국인5D',  group: '수급',        fmt: 'flow' },
  { key: 'instNet',label: '기관5D',   group: '수급',        fmt: 'flow' },
  { key: 'tval',   label: '거래대금',  group: '수급',        fmt: 'int' },
  { key: 'turn',   label: '회전율',    group: '수급',        fmt: 'f2' },
];

const CUST_COLOR = { '삼성': 'samsung', 'SK': 'sk', '해외': 'os' };

let DATA = null;
let curStage = 'fe';
let fType = new Set();
let fStep = new Set();
let fCust = new Set();
let search = '';
let sortKey = 'mc';
let sortDir = -1;

const $ = (id) => document.getElementById(id);

function fmt(v, type) {
  if (v === null || v === undefined || (typeof v === 'number' && isNaN(v))) return '—';
  switch (type) {
    case 'name': return v;
    case 'text': return v || '—';
    case 'int':  return Math.round(v).toLocaleString('ko-KR');
    case 'pct':  return (v > 0 ? '+' : '') + v.toFixed(1);
    case 'flow': return (v > 0 ? '+' : '') + Math.round(v).toLocaleString('ko-KR');
    case 'f1':   return v.toFixed(1);
    case 'f2':   return v.toFixed(2);
    default:     return String(v);
  }
}

function cellClass(v, type) {
  if (type === 'pct')  return (v > 0 ? 'pos' : v < 0 ? 'neg' : '');
  if (type === 'flow') return (v > 0 ? 'buy' : v < 0 ? 'sell' : '');
  if (v === null || v === undefined || isNaN(v)) return (type === 'name' || type === 'type' || type === 'text' || type === 'cust') ? '' : 'muted';
  return '';
}

function renderCell(row, col) {
  const v = row[col.key];
  if (col.fmt === 'name') {
    return `<div class="nm">${row.n}<span class="code">${row.code}</span></div>`;
  }
  if (col.fmt === 'type') {
    return `<span class="typetag t-${typeSlug(v)}">${v}</span>`;
  }
  if (col.fmt === 'cust') {
    const arr = Array.isArray(v) ? v : [];
    if (!arr.length) return '<span class="muted">—</span>';
    return '<span class="custs">' + arr.map((c) => `<span class="cbadge c-${CUST_COLOR[c] || 'os'}">${c}</span>`).join('') + '</span>';
  }
  return fmt(v, col.fmt);
}

function typeSlug(t) {
  return { '장비': 'equip', '소재': 'mats', '부품': 'parts', 'OSAT': 'osat', '기판': 'sub', '팹리스': 'fab' }[t] || 'etc';
}

// ---------- taxonomy helpers ----------
function stageRows(stage) {
  return (DATA.rows || []).filter((r) => r.stage === stage);
}
function typesInStage(stage) {
  const present = new Set(stageRows(stage).map((r) => r.type));
  return (DATA.types || []).filter((t) => present.has(t));
}
function stepsInStage(stage) {
  const defined = (DATA.steps && DATA.steps[stage]) ? DATA.steps[stage] : [];
  const present = new Set(stageRows(stage).map((r) => r.step));
  const extra = [...present].filter((s) => !defined.includes(s));
  return [...defined.filter((s) => present.has(s)), ...extra];
}

function filteredRows() {
  return stageRows(curStage).filter((r) => {
    if (fType.size && !fType.has(r.type)) return false;
    if (fStep.size && !fStep.has(r.step)) return false;
    if (fCust.size) {
      const cs = Array.isArray(r.cust) ? r.cust : [];
      if (!cs.some((c) => fCust.has(c))) return false;
    }
    if (search) {
      const q = search.toLowerCase();
      if (!(r.n.toLowerCase().includes(q) || String(r.code).includes(q) || (r.step || '').toLowerCase().includes(q))) return false;
    }
    return true;
  });
}

// ---------- rendering ----------
function groupFlags() {
  const flags = [];
  let prev = '';
  for (const c of COLS) { flags.push(c.group !== prev); prev = c.group; }
  return flags;
}

function buildColGroups() {
  const groups = [];
  let prev = '';
  for (const c of COLS) {
    if (c.group !== prev) { groups.push({ label: c.group, span: 1 }); prev = c.group; }
    else groups[groups.length - 1].span++;
  }
  $('colGroups').innerHTML = groups.map((g, i) =>
    `<th colspan="${g.span}"${i > 0 ? ' class="grp-sep"' : ''}>${g.label}</th>`).join('');
}

function buildColHeaders() {
  const flags = groupFlags();
  $('colHeaders').innerHTML = COLS.map((c, i) => {
    const cls = [
      c.key === sortKey ? (sortDir === 1 ? 'asc' : 'desc') : '',
      flags[i] && i > 0 ? 'grp-sep' : '',
    ].filter(Boolean).join(' ');
    return `<th class="${cls}" onclick="handleSort('${c.key}')">${c.label}<span class="arr"></span></th>`;
  }).join('');
}

function sortRows(rows) {
  const stringKeys = { n: 1, type: 1, step: 1 };
  return rows.slice().sort((a, b) => {
    if (sortKey === 'cust') {
      const la = (a.cust || []).length, lb = (b.cust || []).length;
      return sortDir * (la - lb);
    }
    if (stringKeys[sortKey]) {
      return sortDir * String(a[sortKey] || '').localeCompare(String(b[sortKey] || ''), 'ko');
    }
    const va = a[sortKey], vb = b[sortKey];
    if (va == null && vb == null) return 0;
    if (va == null) return 1;
    if (vb == null) return -1;
    return sortDir * (va - vb);
  });
}

function render() {
  const rows = sortRows(filteredRows());
  const flags = groupFlags();

  if (!rows.length) {
    $('tbody').innerHTML = `<tr><td class="loading" colspan="${COLS.length}">조건에 맞는 종목이 없습니다.</td></tr>`;
  } else {
    $('tbody').innerHTML = rows.map((r) =>
      '<tr>' + COLS.map((c, i) => {
        const cc = cellClass(r[c.key], c.fmt);
        const sep = flags[i] && i > 0 ? ' grp-sep' : '';
        return `<td class="${(cc + sep).trim()}">${renderCell(r, c)}</td>`;
      }).join('') + '</tr>').join('');
  }

  buildColHeaders();
  updateSummary(rows);
  const stg = DATA.stages.find((s) => s.id === curStage);
  $('cntNote').textContent = `${stg ? stg.label : ''} · ${rows.length}개 종목`;
}

function avg(rows, key) {
  const vals = rows.map((r) => r[key]).filter((v) => v !== null && v !== undefined && !isNaN(v));
  return vals.length ? vals.reduce((s, v) => s + v, 0) / vals.length : null;
}
function median(rows, key) {
  const vals = rows.map((r) => r[key]).filter((v) => v !== null && v !== undefined && !isNaN(v)).sort((a, b) => a - b);
  if (!vals.length) return null;
  const mid = Math.floor(vals.length / 2);
  return vals.length % 2 ? vals[mid] : (vals[mid - 1] + vals[mid]) / 2;
}
function sum(rows, key) { return rows.reduce((s, r) => s + (r[key] || 0), 0); }

function updateSummary(rows) {
  const mc = sum(rows, 'mc');
  const w = avg(rows, 'w');
  const fxNet = sum(rows, 'fxNet');
  const mfPer = median(rows, 'fwPer');
  const mfPbr = median(rows, 'fwPbr');

  const tiles = [
    { label: '합산 시총', value: mc ? (mc / 10000).toFixed(1) + '조' : '—' },
    { label: '종목 수', value: rows.length + '개' },
    { label: '평균 1W', value: w != null ? fmt(w, 'pct') + '%' : '—', cls: w > 0 ? 'pos' : w < 0 ? 'neg' : '' },
    { label: '외국인 5D 순매수', value: fxNet ? (fxNet > 0 ? '+' : '') + Math.round(fxNet).toLocaleString('ko-KR') + '억' : '—', cls: fxNet > 0 ? 'pos' : fxNet < 0 ? 'neg' : '' },
    { label: 'fPER 중앙값', value: mfPer != null ? mfPer.toFixed(1) + 'x' : '—' },
    { label: 'fPBR 중앙값', value: mfPbr != null ? mfPbr.toFixed(1) + 'x' : '—' },
  ];
  $('summary').innerHTML = tiles.map((t) =>
    `<div class="stat-tile"><div class="stat-label">${t.label}</div><div class="stat-value ${t.cls || ''}">${t.value}</div></div>`).join('');
}

// ---------- filters ----------
function pill(label, active, onclick, extraCls) {
  return `<button class="fpill${active ? ' on' : ''}${extraCls ? ' ' + extraCls : ''}" onclick="${onclick}">${label}</button>`;
}

function buildFilters() {
  const types = typesInStage(curStage);
  const steps = stepsInStage(curStage);
  const custs = DATA.custs || [];

  let html = '';
  html += `<div class="frow"><span class="flabel">제품</span>`
    + pill('전체', fType.size === 0, "clearFilter('type')")
    + types.map((t) => pill(t, fType.has(t), `toggleFilter('type','${t}')`)).join('')
    + `</div>`;
  html += `<div class="frow"><span class="flabel">세부공정</span>`
    + pill('전체', fStep.size === 0, "clearFilter('step')")
    + steps.map((s) => pill(s, fStep.has(s), `toggleFilter('step','${s}')`)).join('')
    + `</div>`;
  html += `<div class="frow"><span class="flabel">고객사</span>`
    + pill('전체', fCust.size === 0, "clearFilter('cust')")
    + custs.map((c) => pill(c, fCust.has(c), `toggleFilter('cust','${c}')`, 'c-' + (CUST_COLOR[c] || 'os'))).join('')
    + `<input class="fsearch" id="searchBox" type="text" placeholder="종목·공정 검색" value="${search}" oninput="onSearch(this.value)">`
    + `</div>`;
  $('filters').innerHTML = html;
}

function setOf(name) { return name === 'type' ? fType : name === 'step' ? fStep : fCust; }
window.toggleFilter = function (name, val) {
  const s = setOf(name);
  if (s.has(val)) s.delete(val); else s.add(val);
  buildFilters(); render();
};
window.clearFilter = function (name) { setOf(name).clear(); buildFilters(); render(); };
window.onSearch = function (v) {
  search = v;
  render();
  const el = $('searchBox'); if (el) { el.focus(); const p = el.value.length; el.setSelectionRange(p, p); }
};

window.handleSort = function (key) {
  if (sortKey === key) sortDir *= -1;
  else { sortKey = key; sortDir = (key === 'n' || key === 'type' || key === 'step') ? 1 : -1; }
  render();
};

function switchStage(id) {
  curStage = id;
  fType.clear(); fStep.clear(); fCust.clear(); search = '';
  sortKey = 'mc'; sortDir = -1;
  document.querySelectorAll('.tab').forEach((t) => t.classList.toggle('active', t.dataset.stage === id));
  buildFilters(); render();
}
window.switchStage = switchStage;

function buildTabs() {
  $('tabs').innerHTML = DATA.stages.map((s) => {
    const cnt = stageRows(s.id).length;
    return `<button class="tab${s.id === curStage ? ' active' : ''}" data-stage="${s.id}" onclick="switchStage('${s.id}')">${s.label}<span class="cnt">${cnt}</span></button>`;
  }).join('');
}

// ---------- boot ----------
async function boot() {
  try {
    const res = await fetch('data.json?_=' + Date.now());
    if (!res.ok) throw new Error('data.json ' + res.status);
    DATA = await res.json();

    const m = DATA.meta || {};
    $('updatedLine').innerHTML = `기준일 <b>${m.refDate || '—'}</b> · 최종 갱신 <b>${m.updatedKr || '—'}</b>`;
    $('srcNote').textContent = m.source || '';

    buildTabs();
    buildColGroups();
    buildFilters();
    render();
  } catch (e) {
    $('tbody').innerHTML = `<tr><td class="errbox" colspan="${COLS.length}">데이터 로드 실패: ${e.message}</td></tr>`;
  }
}
boot();
