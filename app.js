'use strict';

// Column schema. group headers span consecutive same-group columns.
const COLS = [
  { key: 'n',      label: '종목',      group: '기본',       fmt: 'name' },
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

let DATA = null;
let cur = null;
let sortKey = 'mc';
let sortDir = -1;

const $ = (id) => document.getElementById(id);

function fmt(v, type) {
  if (v === null || v === undefined || (typeof v === 'number' && isNaN(v))) return '—';
  switch (type) {
    case 'name': return v;
    case 'int':  return Math.round(v).toLocaleString('ko-KR');
    case 'pct':  return (v > 0 ? '+' : '') + v.toFixed(1);
    case 'flow': return (v > 0 ? '+' : '') + Math.round(v).toLocaleString('ko-KR');
    case 'f1':   return v.toFixed(1);
    case 'f2':   return v.toFixed(2);
    default:     return String(v);
  }
}

function cellClass(v, type) {
  if (v === null || v === undefined || isNaN(v)) return type === 'name' ? '' : 'muted';
  if (type === 'pct')  return v > 0 ? 'pos' : v < 0 ? 'neg' : '';
  if (type === 'flow') return v > 0 ? 'buy' : v < 0 ? 'sell' : '';
  return '';
}

function groupFlags() {
  const flags = [];
  let prev = '';
  COLS.forEach((c) => { flags.push(c.group !== prev); prev = c.group; });
  return flags;
}

function buildColGroups() {
  const groups = [];
  let prev = '';
  COLS.forEach((c) => {
    if (c.group !== prev) { groups.push({ label: c.group, span: 1 }); prev = c.group; }
    else groups[groups.length - 1].span++;
  });
  $('colGroups').innerHTML = groups.map((g, i) =>
    `<th colspan="${g.span}"${i > 0 ? ' class="grp-sep"' : ''}>${g.label}</th>`).join('');
}

function buildColHeaders() {
  const flags = groupFlags();
  $('colHeaders').innerHTML = COLS.map((c, i) => {
    const sortCls = c.key === sortKey ? (sortDir === 1 ? 'asc' : 'desc') : '';
    const sepCls = flags[i] && i > 0 ? 'grp-sep' : '';
    const cls = [sortCls, sepCls].filter(Boolean).join(' ');
    return `<th class="${cls}" data-key="${c.key}">${c.label}<span class="arr"></span></th>`;
  }).join('');
  $('colHeaders').querySelectorAll('th').forEach((th) =>
    th.addEventListener('click', () => handleSort(th.dataset.key)));
}

function sortedRows() {
  const rows = [...(DATA.rows[cur] || [])];
  const col = COLS.find((c) => c.key === sortKey);
  if (col && col.fmt === 'name') {
    rows.sort((a, b) => sortDir * String(a.n).localeCompare(String(b.n), 'ko'));
  } else {
    rows.sort((a, b) => {
      const va = a[sortKey], vb = b[sortKey];
      const na = va === null || va === undefined || isNaN(va);
      const nb = vb === null || vb === undefined || isNaN(vb);
      if (na && nb) return 0;
      if (na) return 1;
      if (nb) return -1;
      return sortDir * (va - vb);
    });
  }
  return rows;
}

function render() {
  const rows = sortedRows();
  const flags = groupFlags();

  $('tbody').innerHTML = rows.map((r) =>
    '<tr>' + COLS.map((c, i) => {
      const v = r[c.key];
      const sep = flags[i] && i > 0 ? ' grp-sep' : '';
      if (c.fmt === 'name') {
        return `<td class="${sep}">${r.n}<span class="code">${r.code}</span></td>`;
      }
      const cc = cellClass(v, c.fmt);
      return `<td class="${cc}${sep}">${fmt(v, c.fmt)}</td>`;
    }).join('') + '</tr>').join('');

  buildColHeaders();
  updateSummary(rows);
  const seg = DATA.segments.find((s) => s.id === cur);
  $('cntNote').textContent = `${seg.label} ${rows.length}개 종목`;
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
function sum(rows, key) {
  return rows.reduce((s, r) => s + (r[key] || 0), 0);
}

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

function handleSort(key) {
  if (sortKey === key) sortDir *= -1;
  else { sortKey = key; sortDir = key === 'n' ? 1 : -1; }
  render();
}

function switchTab(id) {
  cur = id;
  sortKey = 'mc'; sortDir = -1;
  document.querySelectorAll('.tab').forEach((t) => t.classList.toggle('active', t.dataset.seg === id));
  render();
}

function initTabs() {
  $('tabs').innerHTML = DATA.segments.map((s, i) => {
    const cnt = (DATA.rows[s.id] || []).length;
    return `<button class="tab${i === 0 ? ' active' : ''}" data-seg="${s.id}">${s.label}<span class="cnt">${cnt}</span></button>`;
  }).join('');
  $('tabs').querySelectorAll('.tab').forEach((t) =>
    t.addEventListener('click', () => switchTab(t.dataset.seg)));
}

function initMeta() {
  const m = DATA.meta || {};
  $('updatedLine').innerHTML = `기준일 <b>${m.refDate || '—'}</b> · 최종 갱신 <b>${m.updatedKr || '—'}</b>`;
  $('srcNote').textContent = (m.source || '') + (m.note ? ' · ' + m.note : '');
}

async function boot() {
  try {
    const res = await fetch('data.json?_=' + Date.now());
    if (!res.ok) throw new Error('HTTP ' + res.status);
    DATA = await res.json();
    cur = DATA.segments[0].id;
    buildColGroups();
    initMeta();
    initTabs();
    render();
  } catch (e) {
    $('tbody').innerHTML = `<tr><td class="errbox">data.json 로드 실패: ${e.message}<br>로컬에서 열 땐 serve.ps1로 서버를 띄워주세요.</td></tr>`;
  }
}

boot();
