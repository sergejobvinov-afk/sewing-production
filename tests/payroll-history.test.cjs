const {test}=require('node:test');
const assert=require('node:assert/strict');
const history=require('../payroll-history.js');
const recovery=require('../payroll-recovery.js');
const op=(extra={})=>({operationId:1,packId:'KR-1',passport:'П-1',model:'Худи',cutDate:'2026-11-01',operationName:'Оверлок',sewerName:'Дильбар',paidQty:15,price:'42.30',...extra});
const event=(id,payload,extra={})=>({id,pack_id:'KR-1',event_type:'Оплата швее',created_at:'2026-11-23T12:00:00Z',payload:{operation:'Оверлок',...payload},...extra});
const data=(events,operations=[op()])=>({success:true,paymentDate:'2026-11-23',operations,paymentEvents:events,payments:[]});
const old=()=>event(1,{paid:true,qty:10,from_qty:0,to_qty:10,source:'payroll_recovery',paymentDate:'2026-11-09'}, {created_at:'2026-11-23T10:00:00Z'});

test('ordinary salary payment includes only its increment after the recovery payment, even if both recorded on 23 November',()=>{
  const d=data([old(),event(2,{paid:true,qty:15})]);
  const result=history.build(d);assert.deepEqual(result.issues,[]);
  assert.equal(result.payments[0].count,1);assert.equal(result.payments[0].amount,'211.50');
  assert.equal(result.payments[0].entries[0].qty,5);
  const receipt=recovery.receipts(d,{sewer:'Дильбар'});
  assert.equal(receipt.amountCents,21150);assert.equal(receipt.models[0].qty,5);
  assert.equal(receipt.entries[0].recordedAt,'2026-11-23T12:00:00Z');
  d.paymentDate='2026-11-09';assert.equal(history.build(d).payments.length,0,'A backdated recovery is provided only by its existing batch');
});

test('repeated paid=true logs with unchanged cumulative quantity never pay the old amount twice',()=>{
  const result=history.build(data([old(),event(2,{paid:true,qty:15}),event(3,{paid:true,qty:15})]));
  assert.equal(result.payments[0].count,1);assert.equal(result.payments[0].amount,'211.50');
});

test('payment dates use Moscow boundaries and event IDs determine cumulative transition order',()=>{
  const d=data([event(3,{paid:true,qty:15},{created_at:'2026-11-23T21:00:00Z'}),event(1,{paid:true,qty:10},{created_at:'2026-11-22T20:59:59Z'}),event(2,{paid:true,qty:12},{created_at:'2026-11-22T21:00:00Z'})]);
  assert.equal(history.build(d).payments[0].amount,'84.60');
  d.paymentDate='2026-11-24';assert.equal(history.build(d).payments[0].amount,'126.90');
});

test('a reversal and a later payment are separate signed calculations with exact net money',()=>{
  const d=data([old(),event(2,{paid:false,qty:0}),event(3,{paid:true,qty:15})]);
  const receipt=recovery.receipts(d);
  assert.equal(receipt.paidAmountCents,63450);assert.equal(receipt.reversedAmountCents,42300);assert.equal(receipt.amountCents,21150);
  assert.equal(receipt.models[0].calculations.length,2);assert.ok(receipt.models[0].calculations.some(x=>x.reversal&&x.qty===-10));
  assert.ok(recovery.receiptCsv(receipt).includes('-423'));
  const reversalOnly=data([old(),event(2,{paid:false,qty:0})],[op({paidQty:0})]);
  assert.equal(recovery.receipts(reversalOnly).amountCents,-42300);
});

test('single-operation legacy payments and their cancellations are also supported',()=>{
  const d=data([event(1,{from_qty:0,to_qty:10},{event_type:'Оплата операции'}),event(2,{}, {event_type:'Отмена оплаты операции'})],[op({paidQty:0})]);
  const receipt=recovery.receipts(d);assert.equal(receipt.amountCents,0);assert.equal(receipt.entries.length,2);
});

test('missing history or a concurrent change blocks an authoritative total instead of silently showing zero',()=>{
  const result=history.build(data([]));assert.equal(result.issues.length,1);assert.match(result.issues[0].message,/не совпадает/);
  const d=data([event(1,{paid:true,qty:10})]);assert.equal(history.build(d).issues.length,1);
  assert.equal(recovery.receipts(d,{sewer:'Другая швея'}).issues.length,0);
});

test('invalid transitions, missing operations and duplicate event IDs fail visibly',()=>{
  assert.throws(()=>history.build(data([old(),old()])),/Повторная/);
  assert.throws(()=>history.build(data([old(),event(2,{paid:true,qty:15,from_qty:4})])),/Не сходится/);
  assert.throws(()=>history.build(data([event(1,{paid:true,qty:3},{pack_id:'UNKNOWN'})])),/Не найден/);
  assert.throws(()=>history.build(data([event(1,{paid:true,qty:-1})])),/количество/);
});

test('ordinary payments are not truncated after a thousand rows and receipts retain cents',()=>{
  const operations=Array.from({length:2501},(_,i)=>op({packId:'KR-'+i,paidQty:1,price:'0.10'}));
  const events=operations.map((o,i)=>event(i+1,{paid:true,qty:1},{pack_id:o.packId}));
  const receipt=recovery.receipts(data(events,operations));assert.equal(receipt.entries.length,2501);assert.equal(receipt.amountCents,25010);
});
