const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

async function sewerApi(profiles, history, { failPage = false } = {}) {
  const calls = [];
  const ctx = {
    URLSearchParams, AbortController, setTimeout, clearTimeout, performance,
    console: { info() {} }, document: { addEventListener() {} }, sessionStorage: { getItem() { return null; } },
    fetch: async (url, options) => {
      const path = new URL(url); calls.push({ path, method: options.method });
      let body = {}, ok = true, status = 200;
      if (/\/(profiles|pack_operations)$/.test(path.pathname)) {
        const isProfile = path.pathname.endsWith('/profiles');
        const rows = isProfile ? profiles : history;
        const offset = Number(path.searchParams.get('offset') || 0);
        const limit = Math.min(Number(path.searchParams.get('limit') || 1000), 1000);
        assert.equal(path.searchParams.get('order'), isProfile ? 'display_name.asc,id.asc' : 'sewer_name.asc,id.asc');
        if (failPage && offset >= 500) { ok = false; status = 503; body = { message: 'Не удалось загрузить следующую страницу' }; }
        else body = rows.slice(offset, offset + limit);
      }
      return { ok, status, text: async () => JSON.stringify(body) };
    }
  };
  ctx.window = { location: { search: '?backend=supabase' }, API: {},
    SUPABASE_CONFIG: { url: 'https://example.test', anonKey: 'test-public-key' } };
  vm.runInNewContext(fs.readFileSync(require.resolve('../supabase/pilot-api.js'), 'utf8'), ctx);
  await ctx.window.API.checkConnection();
  return { api: ctx.window.API, calls };
}

test('historical sewer beyond operation 1000 remains selectable without a profile', async () => {
  const history = Array.from({ length: 1250 }, (_, i) => ({ sewer_name: i < 600 ? 'Мавлуда' : i < 1050 ? 'Мафтуна' : 'Мутриба' }));
  assert.ok(!history.slice(0, 1000).some(row => row.sewer_name === 'Мутриба'), 'old capped request omits Mutriba');
  const { api, calls } = await sewerApi([{ display_name: 'Надира', active: true }], history);
  const names = await api.getSewerList();
  assert.deepEqual(Array.from(names), ['Мавлуда','Мафтуна','Мутриба','Надира']);
  assert.deepEqual(calls.filter(c => c.path.pathname.endsWith('/pack_operations')).map(c => c.path.searchParams.get('offset')), ['0','500','1000','1250']);
  assert.ok(calls.every(c => c.method === 'GET'), 'loading names must not modify users or operations');
});

test('disabled profiles stay excluded, active profiles and duplicate names keep current behaviour', async () => {
  const { api } = await sewerApi([
    { display_name: 'Гуля', active: false }, { display_name: 'Павел', active: true }, { display_name: 'Швея без операций', active: true }
  ], [{ sewer_name: 'Гуля' }, { sewer_name: 'Мутриба' }, { sewer_name: 'Мутриба' }, { sewer_name: 'Павел' }]);
  const names = Array.from(await api.getSewerList());
  assert.deepEqual(names, ['Мутриба','Павел','Швея без операций']);
});

test('profiles beyond 1000 rows are fully loaded too', async () => {
  const profiles = Array.from({ length: 1001 }, (_, i) => ({ display_name: 'Швея-' + String(i).padStart(4, '0'), active: true }));
  const { api, calls } = await sewerApi(profiles, []);
  const names = await api.getSewerList();
  assert.equal(names.length, 1001);
  assert.ok(names.includes('Швея-1000'));
  assert.deepEqual(calls.filter(c => c.path.pathname.endsWith('/profiles')).map(c => c.path.searchParams.get('offset')), ['0','500','1000','1001']);
});

test('failure on a later page rejects instead of silently losing sewers', async () => {
  const history = Array.from({ length: 501 }, () => ({ sewer_name: 'Мутриба' }));
  const { api } = await sewerApi([], history, { failPage: true });
  await assert.rejects(api.getSewerList(), /Не удалось загрузить следующую страницу/);
});
