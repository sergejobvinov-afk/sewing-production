const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

async function dashboardApi(packs, operations, { failPage = false, role = 'admin' } = {}) {
  const calls = [];
  const ctx = {
    URLSearchParams, AbortController, setTimeout, clearTimeout, performance,
    console: { info() {} }, document: { addEventListener() {} }, sessionStorage: { getItem() { return null; } },
    fetch: async (url, options) => {
      const path = new URL(url); calls.push({ path, method: options.method });
      let body = {}, ok = true, status = 200;
      if (path.pathname.endsWith('get_dashboard_data_filtered')) {
        ok = false; status = 404; body = { message: 'RPC not installed' };
      } else if (path.pathname.endsWith('get_payment_operations')) {
        body = { success: true, operations: [{ sewerName: 'Анна', acceptedQty: 3, sewerPaidQty: 1, sewerPrice: 7 }] };
      } else if (/\/(packs|pack_operations)$/.test(path.pathname)) {
        const rows = path.pathname.endsWith('/packs') ? packs : operations;
        const offset = Number(path.searchParams.get('offset') || 0);
        const limit = Math.min(Number(path.searchParams.get('limit') || 1000), 1000);
        assert.equal(path.searchParams.get('order'), 'id.asc', 'pagination must have stable ordering');
        if (failPage && offset >= 500) { ok = false; status = 503; body = { message: 'Вторая страница недоступна' }; }
        else body = rows.slice(offset, offset + limit);
      }
      return { ok, status, text: async () => JSON.stringify(body) };
    }
  };
  ctx.window = { location: { search: '?backend=supabase' }, API: {}, currentUser: { role },
    SUPABASE_CONFIG: { url: 'https://example.test', anonKey: 'test-public-key' } };
  vm.runInNewContext(fs.readFileSync(require.resolve('../supabase/pilot-api.js'), 'utf8'), ctx);
  await ctx.window.API.checkConnection();
  return { api: ctx.window.API, calls };
}

function fixture() {
  const packs = [], operations = [];
  for (let i = 0; i < 502; i++) {
    const hoodie = i >= 452, quantity = hoodie ? (i === 499 ? 1 : 15) : 1;
    packs.push({ id: 'KR-' + i, model: hoodie ? 'ХудиМарина' : 'Другая модель', cut_date: '2026-10-21', size: 'M', quantity, status: 'accepted' });
    for (let j = 0; j < 2; j++) operations.push({ id: operations.length + 1, pack_id: 'KR-' + i, issued_qty: quantity,
      accepted_qty: quantity, defect_qty: 0, paid_qty: 0, client_paid_qty: 0, sewer_price: 40, client_price: 70, sewer_name: 'Анна',
      issued_at: '2026-10-21T10:00:00Z', accepted_at: hoodie ? (i === 501 ? '2026-11-18T18:00:00Z' : '2026-10-26T09:00:00Z') : '2026-10-25T10:00:00Z', paid_at: null });
  }
  return { packs, operations };
}

test('OTK dashboard includes the last two packs after row 1000: 736 items, not 706', async () => {
  const { packs, operations } = fixture();
  // Reproduce the old, silently truncated scope before testing the fix.
  const oldPackIds = new Set(operations.slice(0, 1000).filter(op => op.accepted_at >= '2026-10-26').map(op => op.pack_id));
  assert.equal(packs.filter(p => oldPackIds.has(p.id)).reduce((sum, p) => sum + p.quantity, 0), 706);
  const { api, calls } = await dashboardApi(packs, operations);
  const result = await api.getDashboardDataFiltered('2026-10-26', '2026-11-18', 'accepted', 'ХудиМарина');
  assert.equal(result.production.totalQty, 736);
  assert.equal(result.production.totalOtk, 736, 'two operations on one pack must not double the item count');
  assert.equal(result.production.totalPacks, 50);
  assert.equal(result.models[0].items, 736);
  assert.equal(result.models[0].accepted, 736);
  assert.equal(result.sizes[0].items, 736);
  assert.equal(result.finance.zp, 736 * 2 * 40, 'wages count each operation separately');
  assert.equal(result.finance.payrollDueAllTime, 14, 'all-time debt still comes from complete Payments RPC');
  assert.deepEqual(calls.filter(c => c.path.pathname.endsWith('/pack_operations')).map(c => c.path.searchParams.get('offset')), ['0','500','1000']);
  assert.ok(calls.every(c => c.method === 'GET' || /\/rpc\/(get_dashboard_data_filtered|get_payment_operations)$/.test(c.path.pathname)));
});

test('packs are also fully paginated and date/model filtering still applies', async () => {
  const packs = Array.from({ length: 1001 }, (_, i) => ({ id: 'KR-' + i, model: i === 1000 ? 'ХудиМарина' : 'Другая модель',
    cut_date: '2026-11-18', size: 'M', quantity: 15, status: 'new' }));
  const { api, calls } = await dashboardApi(packs, []);
  const result = await api.getDashboardDataFiltered('2026-10-26', '2026-11-18', 'cut', 'ХудиМарина');
  assert.equal(result.production.totalQty, 15);
  assert.equal(result.production.totalPacks, 1);
  assert.deepEqual(calls.filter(c => c.path.pathname.endsWith('/packs')).map(c => c.path.searchParams.get('offset')), ['0','500','1000']);
  const outsidePeriod = await api.getDashboardDataFiltered('2026-11-01', '2026-11-17', 'cut', 'ХудиМарина');
  assert.equal(outsidePeriod.production.totalQty, 0);
});

test('a failed subsequent page rejects instead of returning a partial dashboard', async () => {
  const { packs, operations } = fixture();
  const { api } = await dashboardApi(packs, operations, { failPage: true });
  await assert.rejects(api.getDashboardDataFiltered('2026-10-26', '2026-11-18', 'accepted', 'ХудиМарина'), /Вторая страница недоступна/);
});

test('master fallback keeps financial data hidden and does not request finance RPC', async () => {
  const { packs, operations } = fixture();
  const { api, calls } = await dashboardApi(packs, operations, { role: 'master' });
  const result = await api.getDashboardDataFiltered('2026-10-26', '2026-11-18', 'accepted', 'ХудиМарина');
  assert.equal(result.production.totalQty, 736);
  assert.ok(Object.values(result.finance).every(value => value === 0));
  assert.equal(calls.filter(c => c.path.pathname.endsWith('get_payment_operations')).length, 0);
});
