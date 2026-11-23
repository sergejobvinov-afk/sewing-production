const { test } = require('node:test');
const assert = require('node:assert/strict');
const recovery = require('../payroll-recovery.js');

function op(extra = {}) {
  return Object.assign({ operationId:1,packId:'KR-1',passport:'П-1',model:'Блуза',cutDate:'2026-11-01',
    operationName:'Оверлок',sewerName:'Анна',issuedQty:50,acceptedNow:40,acceptedBefore:25,paidQty:10,
    price:'42.30',recoveryQty:15,remainingAfter:15,needsReview:false,fingerprint:'a'.repeat(32) },extra);
}
function data(rows) { return { success:true,paymentDate:'2026-11-09',generatedAt:'2026-11-23T12:00:00Z',operations:rows }; }

test('recovery subtracts recorded pay and keeps acceptances after the cutoff unpaid', () => {
  const report=recovery.build(data([op()]));
  assert.equal(report.totals.amountCents,63450);
  assert.equal(report.rows[0].addQty,15);
  assert.equal(report.rows[0].remainingAfter,15);
  assert.equal(report.groups[0].coveredQty,10);
});

test('later acceptance and fully recorded old pay never inflate recovery totals', () => {
  const report=recovery.build(data([op(),op({ operationId:2,packId:'KR-2',acceptedBefore:0,recoveryQty:0,remainingAfter:30 }),
    op({ operationId:3,packId:'KR-3',acceptedBefore:5,recoveryQty:0,remainingAfter:30 })]));
  assert.equal(report.totals.operationCount,1);
  assert.equal(report.rows.length,1);
  const all=recovery.build(data([op({ acceptedBefore:5,recoveryQty:0,remainingAfter:30 })]),{mode:'all'});
  assert.equal(all.rows.length,1);
  assert.equal(all.groups[0].coveredQty,5);
  assert.equal(all.totals.amountCents,0);
});

test('unknown history stays visible, blocks selection, and is not guessed from current quantities', () => {
  const report=recovery.build(data([op({acceptedBefore:null,recoveryQty:null,remainingAfter:null,needsReview:true})]));
  assert.equal(report.totals.reviewCount,1);
  assert.equal(report.totals.amountCents,0);
  assert.throws(()=>recovery.selection(report,new Set(['1'])),/неподтверждённая/);
});

test('filters separate sewers and models without changing cents or historical prices', () => {
  const report=recovery.build(data([op(),op({operationId:2,packId:'KR-2',model:'Юбка',sewerName:'Мутриба',price:'0.10'})]),{sewer:'Мутриба',model:'Юбка'});
  assert.equal(report.totals.amountCents,150);
  assert.equal(report.groups[0].name,'Мутриба');
});

test('selection contains only reviewed visible IDs and fingerprints, never client-supplied amounts', () => {
  const report=recovery.build(data([op(),op({operationId:2,packId:'KR-2',price:'0.10'})]));
  const selected=recovery.selection(report,new Set(['2']));
  assert.deepEqual(selected.items,[{operationId:'2',fingerprint:'a'.repeat(32)}]);
  assert.equal(selected.amountCents,150);
  assert.throws(()=>recovery.selection(report,new Set(['999'])),/изменились/);
});

test('invalid quantities, dates, price precision, duplicates and inconsistent server results block the preview', () => {
  for(const changes of [{paidQty:41},{acceptedBefore:41},{recoveryQty:16},{remainingAfter:14},{needsReview:true},{fingerprint:'x'},{price:'42.301'},{acceptedNow:-1}]) {
    assert.throws(()=>recovery.build(data([op(changes)])));
  }
  assert.throws(()=>recovery.build(data([op(),op()])),/Неоднозначная/);
  for(const paymentDate of ['2026-02-30','2026-99-99','bad']) assert.throws(()=>recovery.build({...data([]),paymentDate}));
});

test('all rows after 2000 remain in the reconciliation and selected sum', () => {
  const rows=Array.from({length:2501},(_,i)=>op({operationId:i+1,packId:'KR-'+i,price:'0.10'}));
  const report=recovery.build(data(rows));
  assert.equal(report.totals.operationCount,2501);
  assert.equal(report.totals.amountCents,375150);
  assert.equal(recovery.selection(report,new Set(report.rows.map(r=>r.id))).items.length,2501);
});

test('export explains reconciliation, includes detail and neutralizes spreadsheet formulas', () => {
  const text=recovery.csv(recovery.build(data([op({model:'=SUM(1,2)'})])));
  assert.ok(text.includes('2026-11-09')&&text.includes('Europe/Moscow'));
  assert.ok(text.includes("'=SUM"));
  assert.ok(text.includes('KR-1')&&text.includes('634,5'));
  assert.ok(text.includes('Сохранение файла не отмечает оплату'));
});
