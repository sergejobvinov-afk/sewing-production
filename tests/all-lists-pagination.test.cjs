const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

const count = 2501;
const packId = i => 'KR-2026-' + String(i + 1).padStart(6, '0');
function fixture() {
  const packs = [], operations = [], catalog = [], profiles = [];
  for (let i = 0; i < count; i++) {
    const model = 'Модель-' + String(i).padStart(4, '0');
    packs.push({ id: packId(i), cut_date: '2026-11-18', model, size: 'M', quantity: 10, passport_no: 'П-' + i, status: 'partially_accepted' });
    profiles.push({ id: i + 1, display_name: 'Швея-' + String(i).padStart(4, '0'), active: true, role: 'sewer' });
    for (let j = 0; j < 2; j++) {
      catalog.push({ id: catalog.length + 1, model, operation_name: 'Операция-' + j, sewer_price: 17.25, active: true, sequence_no: j });
      operations.push({ id: operations.length + 1, pack_id: packs[i].id, operation_name: 'Операция-' + j, sewer_name: 'Мутриба',
        issued_qty: 10, accepted_qty: 7 - j, defect_qty: 1, paid_qty: 2, client_paid_qty: 0, sewer_price: 17.25, client_price: 30,
        issued_at: '2026-11-18T09:00:00Z', accepted_at: '2026-11-18T10:00:00Z', paid_at: '2026-11-18T11:00:00Z' });
    }
  }
  return { packs, operations, catalog, profiles };
}

async function mockApi(data, { cap = 1000, fail, badRange = false, emptyPage = false, malformed = false, hideRange = false } = {}) {
  const calls = [];
  const ctx = {
    URLSearchParams, AbortController, setTimeout, clearTimeout, performance,
    console: { info() {} }, document: { addEventListener() {} }, sessionStorage: { getItem() { return null; } },
    fetch: async (url, options) => {
      const path = new URL(url), params = path.searchParams, table = path.pathname.split('/').pop();
      calls.push({ path, method: options.method });
      let body = {}, ok = true, status = 200, range = null;
      if (/\/rpc\//.test(path.pathname)) {
        assert.ok(/^get_/.test(table), 'read tests must never call mutation RPCs');
        if (table === 'get_dashboard_data_filtered' || table === 'get_sewer_period_report') {
          ok = false; status = 404; body = { message: 'RPC not installed' };
        } else if (table === 'get_payment_operations') {
          body = { success: true, operations: data.operations.map(op => {
            const pack = data.packs.find(p => p.id === op.pack_id);
            return { packId: op.pack_id, model: pack.model, operationName: op.operation_name, sewerName: op.sewer_name,
              acceptedQty: op.accepted_qty, sewerPaidQty: op.paid_qty, sewerPrice: op.sewer_price };
          }) };
        } else body = { success: true, rows: data.profiles };
      } else if (['packs', 'pack_operations', 'operation_catalog', 'profiles'].includes(table)) {
        assert.equal(options.method, 'GET');
        let rows = data[{ packs: 'packs', pack_operations: 'operations', operation_catalog: 'catalog', profiles: 'profiles' }[table]];
        for (const field of ['id', 'pack_id', 'model', 'sewer_name', 'status', 'role', 'active']) {
          const filter = params.get(field);
          if (filter?.startsWith('eq.')) rows = rows.filter(row => String(row[field]) === filter.slice(3));
          if (filter?.startsWith('neq.')) rows = rows.filter(row => String(row[field]) !== filter.slice(4));
        }
        if (params.get('select').includes('packs!inner')) rows = rows.map(row => ({ ...row, packs: data.packs.find(p => p.id === row.pack_id) }));
        const single = params.get('limit') === '1';
        if (single) {
          assert.ok(params.get('id')?.startsWith('eq.'));
          assert.equal(params.has('offset'), false, 'point lookup keeps its intentional limit');
        } else {
          assert.match(params.get('order'), /(^|,)id\.(asc|desc)(,|$)/, 'all list pages need a unique sort key');
          assert.equal(params.get('limit'), '500', 'do not rely on increasing the server cap to 2000');
          assert.ok(params.has('offset'));
        }
        const offset = Number(params.get('offset') || 0), limit = Math.min(Number(params.get('limit') || 1000), cap);
        body = rows.slice(offset, offset + limit);
        if (offset === 0 && !single) assert.equal(options.headers.Prefer, 'count=exact');
        range = body.length ? offset + '-' + (offset + body.length - 1) + '/' + (offset === 0 ? rows.length : '*') : '*/' + rows.length;
        if (fail?.table === table && offset >= fail.offset) { ok = false; status = 503; body = { message: 'Следующая страница недоступна' }; }
        if (offset > 0 && badRange) range = '0-' + (body.length - 1) + '/*';
        if (offset > 0 && emptyPage) { body = []; range = '*/' + rows.length; }
        if (offset > 0 && malformed) body = { message: 'not a list' };
      }
      return { ok, status, headers: { get: () => hideRange ? null : range }, text: async () => JSON.stringify(body) };
    }
  };
  ctx.window = { location: { search: '?backend=supabase' }, API: {}, currentUser: { role: 'admin' },
    SUPABASE_CONFIG: { url: 'https://example.test', anonKey: 'test-public-key' } };
  vm.runInNewContext(fs.readFileSync(process.env.PILOT_API_FILE || require.resolve('../supabase/pilot-api.js'), 'utf8'), ctx);
  await ctx.window.API.checkConnection();
  return { api: ctx.window.API, calls };
}

test('passport list includes 2501 packs and progress/catalog entries beyond operation 2000', async () => {
  const { api, calls } = await mockApi(fixture());
  const result = await api.getAllPacks(), last = result.packs.find(p => p.id === packId(2500));
  assert.equal(result.count, count);
  assert.equal(last.operations.length, 2);
  assert.equal(last.acceptedQty, 6);
  assert.equal(last.processedQty, 7);
  assert.equal(last.remainingQty, 3);
  for (const name of ['packs', 'operation_catalog', 'pack_operations']) {
    assert.ok(calls.some(c => c.path.pathname.endsWith('/' + name) && Number(c.path.searchParams.get('offset')) > 2000));
  }
});

test('model list and a single model/passport include catalog records beyond 2000', async () => {
  const data = fixture();
  let { api } = await mockApi(data);
  const models = await api.getModelList();
  assert.equal(models.length, count);
  assert.ok(models.includes('Модель-2500'));
  data.catalog = Array.from({ length: count }, (_, i) => ({ id: i + 1, model: 'Модель-2500', operation_name: 'Шаг-' + i, sewer_price: 10, active: true, sequence_no: i }));
  ({ api } = await mockApi(data));
  assert.equal((await api.getModelOperations('Модель-2500')).length, count);
  const passport = await api.getPassportData(packId(2500));
  assert.equal(passport.id, packId(2500));
  assert.equal(passport.operations.length, count);
  assert.equal(passport.operations[count - 1], 'Шаг-2500');
});

test('pack status loads all operations, while pack lookup stays a unique limit=1 query', async () => {
  const data = fixture();
  data.operations = Array.from({ length: count }, (_, i) => ({ ...data.operations[0], id: i + 1, operation_name: 'Шаг-' + i }));
  const { api } = await mockApi(data);
  const result = await api.getPackStatus(packId(0) + '|QR');
  assert.equal(result.operations.length, count);
  assert.equal(result.operations[count - 1].name, 'Шаг-2500');
  assert.equal(result.operations[count - 1].price, 17.25);
});

test('outstanding work source reads every issued operation, with no financial RPC or writes', async () => {
  const {api,calls}=await mockApi(fixture());
  const result=await api.getWorkInProgress();
  assert.equal(result.operations.length,count*2);
  assert.equal(result.operations.at(-1).packId,packId(2500));
  assert.equal(result.operations.at(-1).model,'Модель-2500');
  assert.equal(result.operations.at(-1).defectQty,1);
  assert.ok(calls.every(c=>c.method==='GET'));
  const select=calls.find(c=>c.path.pathname.endsWith('/pack_operations')).path.searchParams.get('select');
  assert.ok(!/price|paid/.test(select),'no financial columns are loaded for master');
});

test('fallback sewer report loads every operation and finds pack/model beyond row 2000 for all date kinds', async () => {
  const { api, calls } = await mockApi(fixture());
  for (const kind of ['accepted', 'issued', 'paid']) {
    const report = await api.getSewerPeriodReport('Мутриба', '2026-11-01', '2026-11-23', kind);
    assert.equal(report.details.length, count * 2);
    assert.equal(report.summary.length, count);
    const last = report.summary.find(r => r.model === 'Модель-2500');
    assert.equal(last.packCount, 1);
    assert.equal(last.issuedQty, 10);
    assert.equal(last.acceptedQty, 6);
    assert.equal(last.defectQty, 2);
    assert.equal(last.remainingQty, 3);
    assert.equal(last.paidQty, 2);
    assert.ok(calls.some(c => c.path.searchParams.get('order') === kind + '_at.asc,id.asc'));
  }
});

test('sewer list, dashboard, and payroll statement remain complete beyond 2000', async () => {
  const { api } = await mockApi(fixture());
  const names = await api.getSewerList();
  assert.equal(names.length, count + 1);
  assert.ok(names.includes('Швея-2500') && names.includes('Мутриба'));
  const dashboard = await api.getDashboardDataFiltered('2026-11-01', '2026-11-23', 'cut', '');
  assert.equal(dashboard.production.totalPacks, count);
  assert.equal(dashboard.production.totalQty, count * 10);
  assert.equal(dashboard.production.totalOtk, count * 6);
  assert.equal(dashboard.finance.zp, count * (5 + 4) * 17.25);
  const statement = await api.getPayrollStatementOperations('Мутриба');
  assert.equal(statement.operations.length, count * 2);
  assert.equal(statement.operations.at(-1).packId, packId(2500));
});

test('server cap below page size does not silently truncate lists', async () => {
  const { api, calls } = await mockApi(fixture(), { cap: 73 });
  assert.equal((await api.getModelList()).length, count);
  const offsets = calls.filter(c => c.path.pathname.endsWith('/operation_catalog')).map(c => Number(c.path.searchParams.get('offset')));
  assert.equal(offsets[1], 73);
  assert.ok(offsets.at(-1) > 2000);
});

test('a proxy hiding row counts still cannot truncate a list at its own lower cap', async () => {
  const { api, calls } = await mockApi(fixture(), { cap: 73, hideRange: true });
  assert.equal((await api.getModelList()).length, count);
  const pages = calls.filter(c => c.path.pathname.endsWith('/operation_catalog'));
  assert.equal(Number(pages.at(-1).path.searchParams.get('offset')), count * 2, 'an empty final page confirms completion');
});

test('a later failure rejects every affected screen instead of returning a partial list/report', async () => {
  const scenarios = [
    ['packs', api => api.getAllPacks()],
    ['operation_catalog', api => api.getAllPacks()],
    ['pack_operations', api => api.getAllPacks()],
    ['pack_operations', api => api.getWorkInProgress()],
    ['operation_catalog', api => api.getModelList()],
    ['pack_operations', api => api.getSewerPeriodReport('Мутриба', '2026-11-01', '2026-11-23', 'accepted')],
    ['packs', api => api.getSewerPeriodReport('Мутриба', '2026-11-01', '2026-11-23', 'accepted')]
  ];
  for (const [table, load] of scenarios) {
    const { api } = await mockApi(fixture(), { fail: { table, offset: 2000 } });
    await assert.rejects(load(api), /Следующая страница недоступна/, table);
  }
});

test('unexpected range, empty intermediate page, or non-list body cannot produce a plausible partial total', async () => {
  for (const options of [{ badRange: true }, { emptyPage: true }, { malformed: true }]) {
    const { api } = await mockApi(fixture(), options);
    await assert.rejects(api.getModelList(), /неполная страница|полностью загрузить/i);
  }
});

test('scalar JSON read RPCs keep their nested arrays above 2000 intact', async () => {
  const { api } = await mockApi(fixture());
  for (const result of await Promise.all([api.getUsers(), api.getSewerPacks(), api.getCatalogAdmin(), api.getCostCalculatorData(), api.getProductionOrderReport(1)])) {
    assert.equal(result.rows.length, count);
  }
});
