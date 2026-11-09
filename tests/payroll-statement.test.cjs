const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const payroll = require('../payroll-statement.js');

function operation(extra = {}) {
  return Object.assign({ packId: 'KR-1', passport: 'П-1', model: 'Блуза', cutDate: '2026-11-01', operationName: 'Оверлок',
    sewerName: 'Анна', issuedQty: 50, acceptedQty: 40, sewerPaidQty: 10, sewerPrice: '42.30' }, extra);
}

test('partial payments, unaccepted packs and fully paid packs reconcile in one model/cut/operation row', () => {
  const report = payroll.build([operation(), operation({ packId: 'KR-2', issuedQty: 30, acceptedQty: 30, sewerPaidQty: 30 }),
    operation({ packId: 'KR-3', issuedQty: 20, acceptedQty: 0, sewerPaidQty: 0 })]);
  assert.equal(report.rows.length, 1);
  assert.deepEqual(report.totals, { issuedQty: 100, acceptedQty: 70, paidQty: 40, unpaidQty: 30, amountCents: 126900 });
  assert.equal(report.packCount, 3);
});

test('historical rates remain separate; cents are exact and acceptance above issue is supported', () => {
  const report = payroll.build([operation({ sewerPrice: '0.10', acceptedQty: 3, sewerPaidQty: 0 }),
    operation({ packId: 'KR-2', sewerPrice: '42.35', acceptedQty: 51, sewerPaidQty: 50 })]);
  assert.equal(report.rows.length, 2);
  assert.equal(report.totals.amountCents, 4265);
  assert.equal(report.totals.unpaidQty, 4);
});

test('cut dates are inclusive, models and sort directions preserve totals', () => {
  const rows = [operation({ model: 'Юбка', cutDate: '2026-10-31' }), operation({ packId: 'KR-2', model: 'Анорак', cutDate: '2026-11-02' }),
    operation({ packId: 'KR-3', model: 'Анорак', cutDate: '2026-11-01' }), operation({ packId: 'KR-4', cutDate: null })];
  assert.deepEqual(payroll.build(rows, { sort: 'cut_asc' }).rows.map(r => r.cutDate), ['2026-10-31','2026-11-01','2026-11-02','']);
  assert.deepEqual(payroll.build(rows, { sort: 'cut_desc' }).rows.map(r => r.cutDate), ['2026-11-02','2026-11-01','2026-10-31','']);
  assert.equal(payroll.build(rows, { sort: 'model_asc' }).rows[0].model, 'Анорак');
  assert.equal(payroll.build(rows, { sort: 'model_desc' }).rows[0].model, 'Юбка');
  assert.equal(payroll.build(rows, { model: 'Анорак', cutFrom: '2026-11-01', cutTo: '2026-11-02' }).rows.length, 2);
  assert.throws(() => payroll.build(rows, { cutFrom: '2026-11-02', cutTo: '2026-11-01' }), /Проверьте период/);
});

test('all mode exposes paid and unaccepted rows without increasing amount payable', () => {
  const ops = [operation(), operation({ packId: 'KR-2', cutDate: '2026-11-02', sewerPaidQty: 40 }),
    operation({ packId: 'KR-3', cutDate: '2026-11-03', acceptedQty: 0, sewerPaidQty: 0 })];
  const due = payroll.build(ops), all = payroll.build(ops, { mode: 'all' });
  assert.equal(due.rows.length, 1);
  assert.equal(all.rows.length, 3);
  assert.equal(due.totals.amountCents, all.totals.amountCents);
});

test('invalid financial data and duplicates block a misleading statement', () => {
  assert.throws(() => payroll.build([operation(), operation()]), /Повторная операция/);
  assert.throws(() => payroll.build([operation({ sewerPaidQty: 41 })]), /превышает/);
  for (const acceptedQty of [-1, 1.5, null]) assert.throws(() => payroll.build([operation({ acceptedQty })]), /количество/);
  assert.throws(() => payroll.build([operation({ sewerPrice: '42.123' })]), /расценка/);
});

test('export keeps financial totals and passport detail; user text cannot become an Excel formula', () => {
  const report = payroll.build([operation({ model: '=HYPERLINK("x")' })]);
  Object.assign(report, { sewerName: 'Анна', statementDate: '2026-11-09', generatedAt: '2026-11-09T12:00:00Z' });
  const csv = payroll.delimited(report, ';');
  assert.ok(csv.includes("'=HYPERLINK"));
  assert.ok(csv.includes('1269'));
  assert.ok(csv.includes('KR-1'));
  assert.ok(csv.includes('Расшифровка по паспортам'));
});

async function apiFixture(count, { mismatch = false, denied = false } = {}) {
  const calls = [], rows = Array.from({ length: count }, (_, i) => ({ id: i + 1, pack_id: 'KR-' + i, operation_name: 'Оверлок', sewer_name: 'Анна',
    issued_qty: 50, accepted_qty: 40, paid_qty: 10, sewer_price: '42.30', packs: { cut_date: '2026-11-01', model: 'Блуза', passport_no: 'П-' + i, status: 'partially_accepted' } }));
  const context = { URLSearchParams, AbortController, setTimeout, clearTimeout, performance, console: { info() {} },
    document: { addEventListener() {} }, sessionStorage: { getItem() { return null; } },
    fetch: async (url, options) => {
      const path = new URL(url); calls.push({ path, method: options.method });
      let body = {}, ok = true, status = 200;
      if (path.pathname.endsWith('get_payment_operations')) {
        if (denied) { ok = false; status = 403; body = { message: 'Недостаточно прав для учёта оплаты' }; }
        else body = { success: true, operations: rows.map(row => ({ packId: row.pack_id, operationName: row.operation_name, sewerName: 'Анна',
          acceptedQty: mismatch ? 39 : 40, sewerPaidQty: 10, sewerPrice: '42.30', model: 'Блуза' })) };
      } else if (path.pathname.endsWith('pack_operations')) {
        const offset = Number(path.searchParams.get('offset')), limit = Number(path.searchParams.get('limit'));
        body = rows.slice(offset, offset + limit);
      }
      return { ok, status, text: async () => JSON.stringify(body) };
    }
  };
  context.window = { location: { search: '?backend=supabase' }, API: {}, SUPABASE_CONFIG: { url: 'https://example.test', anonKey: 'test-public-key' } };
  vm.runInNewContext(fs.readFileSync(require.resolve('../supabase/pilot-api.js'), 'utf8'), context);
  await context.window.API.checkConnection();
  return { api: context.window.API, calls };
}

test('API loads more than 1000 rows, reconciles Payments and never calls a write RPC', async () => {
  const fixture = await apiFixture(1250);
  const report = await fixture.api.getPayrollStatementOperations('Анна');
  assert.equal(report.operations.length, 1250);
  assert.equal(payroll.build(report.operations).totals.amountCents, 158625000);
  assert.deepEqual(fixture.calls.filter(c => c.path.pathname.endsWith('pack_operations')).map(c => c.path.searchParams.get('offset')), ['0','500','1000']);
  assert.ok(fixture.calls.every(c => c.method === 'GET' || c.path.pathname.endsWith('/rpc/get_payment_operations')));
});

test('API blocks the statement when the finance snapshot changed or finance access is denied', async () => {
  const fixture = await apiFixture(1, { mismatch: true });
  await assert.rejects(fixture.api.getPayrollStatementOperations('Анна'), /изменились/);
  const restricted = await apiFixture(1, { denied: true });
  await assert.rejects(restricted.api.getPayrollStatementOperations('Анна'), /Недостаточно прав/);
  assert.equal(restricted.calls.filter(c => c.path.pathname.endsWith('pack_operations')).length, 0);
});
