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

function savedPayment() {
  return {...data([]),payments:[{batchId:'saved-1',paymentDate:'2026-11-09',recordedAt:'2026-11-23T15:00:00Z',count:2,amount:'296.60',entries:[
    {eventId:'1',packId:'KR-1',passport:'П-1',model:'Блуза',cutDate:'2026-11-01',sewerName:'Анна',operationName:'Оверлок',qty:7,price:'42.30',amount:'296.10'},
    {eventId:'2',packId:'KR-2',passport:'П-2',model:'Юбка',cutDate:'2026-11-01',sewerName:'Мутриба',operationName:'Распошив',qty:5,price:'0.10',amount:'0.50'}
  ]}]};
}
test('saved receipt retains original added quantity, price, and amount independently of current debt',()=>{
  const receipt=recovery.receipts(savedPayment());
  assert.equal(receipt.amountCents,29660);assert.equal(receipt.entries.length,2);
  const filtered=recovery.receipts(savedPayment(),{sewer:'Мутриба',model:'Юбка'});
  assert.equal(filtered.amountCents,50);assert.equal(filtered.entries[0].qty,5);
  assert.ok(recovery.receiptCsv(receipt).includes('2026-11-09'));
  assert.ok(recovery.receiptCsv(receipt).includes('2026-11-23T15:00:00Z'));
});
test('missing rows, duplicate journal entries, wrong receipt sum and date are rejected',()=>{
  let d=savedPayment();d.payments[0].count=3;assert.throws(()=>recovery.receipts(d),/Неполная/);
  d=savedPayment();d.payments[0].entries[1].eventId='1';assert.throws(()=>recovery.receipts(d),/Повторная/);
  d=savedPayment();d.payments[0].amount='297';assert.throws(()=>recovery.receipts(d),/итог/);
  d=savedPayment();d.payments[0].entries[0].amount='297';assert.throws(()=>recovery.receipts(d),/сумма/);
  d=savedPayment();d.payments[0].paymentDate='2026-11-10';assert.throws(()=>recovery.receipts(d),/Неполная/);
});

test('saved model totals reconcile with the receipt and separate cut dates, operations and historic rates',()=>{
  const d=savedPayment(),batch=d.payments[0],base=batch.entries[0];
  batch.entries.push(
    {...base,eventId:'3',packId:'KR-3',qty:'3',amount:'126.90'},
    {...base,eventId:'4',qty:2,price:'50',amount:'100'},
    {...base,eventId:'5',qty:4,cutDate:'2026-11-02',amount:'169.20'},
    {...base,eventId:'6',qty:5,operationName:'Распошив',price:'10.10',amount:'50.50'}
  );
  batch.count=6;batch.amount='743.20';
  const receipt=recovery.receipts(d),model=receipt.models.find(x=>x.model==='Блуза');
  assert.equal(model.passportCount,2);assert.equal(model.qty,21);assert.equal(model.amountCents,74270);
  assert.equal(model.calculations.length,4);
  assert.deepEqual(model.calculations[0],{cutDate:'2026-11-01',operationName:'Оверлок',priceCents:4230,qty:10,amountCents:42300});
  assert.equal(model.calculations[1].priceCents,5000);
  assert.equal(model.calculations[2].operationName,'Распошив');
  assert.equal(model.calculations[3].cutDate,'2026-11-02');
  assert.equal(receipt.models.reduce((n,m)=>n+m.amountCents,0),receipt.amountCents);
  assert.equal(model.calculations.reduce((n,r)=>n+r.amountCents,0),model.amountCents);
  const filtered=recovery.receipts(d,{sewer:'Анна',model:'Блуза'});
  assert.equal(filtered.models.length,1);assert.equal(filtered.amountCents,74270);
  assert.equal(filtered.groups[0].amountCents,74270);
  d.payments[0].entries[1].amount='999';
  assert.throws(()=>recovery.receipts(d,{sewer:'Анна'}),/сумма/,'Excluded rows must still be validated');
});

test('saved summaries combine multiple batches without losing pennies or merging sewers',()=>{
  const d=savedPayment(),base=d.payments[0].entries[1];
  d.payments.push({batchId:'saved-2',paymentDate:d.paymentDate,recordedAt:'2026-11-24T12:00:00Z',count:2,amount:'0.90',entries:[
    {...base,eventId:'3',qty:3,amount:'0.30'},
    {...base,eventId:'4',qty:6,sewerName:'Анна',amount:'0.60'}
  ]});
  const receipt=recovery.receipts(d),mutriba=receipt.models.find(x=>x.sewerName==='Мутриба');
  assert.equal(receipt.amountCents,29750);assert.equal(receipt.models.length,3);
  assert.equal(mutriba.qty,8);assert.equal(mutriba.amountCents,80);assert.equal(mutriba.passportCount,1);
  assert.equal(mutriba.calculations.length,1);assert.equal(mutriba.calculations[0].amountCents,80);
});

test('saved model summary includes every row beyond the old thousand-row limit',()=>{
  const d=savedPayment(),batch=d.payments[0],base=batch.entries[0];
  batch.entries=Array.from({length:2501},(_,i)=>({...base,eventId:String(i+1),packId:'KR-'+(i+1),qty:1,price:'0.10',amount:'0.10'}));
  batch.count=2501;batch.amount='250.10';
  const receipt=recovery.receipts(d);
  assert.equal(receipt.models[0].qty,2501);assert.equal(receipt.models[0].passportCount,2501);
  assert.equal(receipt.models[0].amountCents,25010);assert.equal(receipt.amountCents,25010);
});
