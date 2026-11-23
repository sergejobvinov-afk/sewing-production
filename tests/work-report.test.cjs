const {test}=require('node:test');
const assert=require('node:assert/strict');
const work=require('../work-report.js');
const now='2026-11-23T12:00:00Z';
function op(extra={}){return Object.assign({id:'1',packId:'KR-1',passport:'П-1',model:'Худи',size:'M',color:'Чёрный',cutDate:'2026-11-01',packQty:50,packStatus:'partially_accepted',operationName:'Оверлок',sewerName:'Мутриба',issuedQty:50,acceptedQty:20,defectQty:5,issuedAt:'2026-11-10T12:00:00Z',acceptedAt:'2026-11-20T12:00:00Z'},extra);}

test('one pack with two operations is counted once, remaining operations stay separate',()=>{
  const r=work.build([op(),op({id:'2',operationName:'Распошив',acceptedQty:40,defectQty:0})],{now});
  assert.equal(r.totals.packCount,1);assert.equal(r.totals.packRemaining,25);
  assert.equal(r.totals.operationCount,2);assert.equal(r.totals.operationRemaining,35);
  assert.equal(r.totals.defects,5);assert.equal(r.rows[0].remainingQty,25);
});
test('fully processed, over-accepted, cancelled and never-issued operations are excluded',()=>{
  const rows=[op({acceptedQty:45}),op({id:'2',packId:'KR-2',acceptedQty:60}),op({id:'3',packId:'KR-3',packStatus:'annulled'}),op({id:'4',packId:'KR-4',issuedQty:0})];
  const r=work.build(rows,{now});assert.equal(r.rows.length,0);assert.equal(r.totals.packCount,0);
});
test('different sewers can share one pack without doubling the overall item/pack total',()=>{
  const r=work.build([op(),op({id:'2',operationName:'Распошив',sewerName:'Анна',acceptedQty:40,defectQty:0})],{now});
  assert.equal(r.totals.packRemaining,25);assert.equal(r.groups.length,2);
  assert.equal(r.groups.reduce((n,g)=>n+g.packCount,0),2);
  assert.equal(work.build(r.rows,{now,sewer:'Анна'}).totals.packRemaining,10);
});
test('all filters apply equally to detail, sewer summary and totals; cut bounds are inclusive',()=>{
  const rows=[op(),op({id:'2',packId:'KR-2',model:'Юбка',cutDate:'2026-11-02',acceptedQty:0,defectQty:0}),op({id:'3',packId:'KR-3',cutDate:'2026-10-31'})];
  const r=work.build(rows,{now,model:'Юбка',sewer:'Мутриба',cutFrom:'2026-11-02',cutTo:'2026-11-02',kind:'none',search:'п-1'});
  assert.equal(r.rows.length,1);assert.equal(r.groups[0].operationCount,1);assert.equal(r.totals.packRemaining,50);
  assert.equal(work.build(rows,{now,kind:'partial'}).rows.length,2);
  assert.throws(()=>work.build(rows,{now,cutFrom:'2026-11-02',cutTo:'2026-11-01'}),/Проверьте период/);
});
test('age uses Moscow calendar days, not elapsed 24-hour intervals',()=>{
  const rows=[op({issuedAt:'2026-11-22T20:59:00Z'}),op({id:'2',packId:'KR-2',issuedAt:'2026-11-22T21:01:00Z'})];
  const r=work.build(rows,{now:'2026-11-23T00:10:00Z',minDays:1});
  assert.equal(r.rows.length,1);assert.equal(r.rows[0].issuedDay,'2026-11-22');assert.equal(r.rows[0].daysInWork,1);
});
test('inconsistent passport status, quantities and missing date stay visible with warnings',()=>{
  const r=work.build([op({packStatus:'accepted',packQty:51,issuedAt:null})],{now});
  assert.equal(r.rows.length,1);assert.equal(r.totals.warningCount,1);assert.equal(r.rows[0].warnings.length,3);
  assert.equal(r.rows[0].daysInWork,null);assert.equal(work.build(r.rows,{now,minDays:1}).rows.length,0);
});
test('duplicates and invalid numbers or dates block misleading totals',()=>{
  assert.throws(()=>work.build([op(),op()],{now}),/Повторная/);
  assert.throws(()=>work.build([op(),op({id:'2'})],{now}),/Повторная/);
  for(const extra of [{acceptedQty:-1},{defectQty:null},{issuedQty:1.5},{cutDate:'2026-02-30'},{acceptedQty:Number.MAX_SAFE_INTEGER,defectQty:1}])assert.throws(()=>work.build([op(extra)],{now}));
  assert.throws(()=>work.build([op()],{now,minDays:-1}),/количество дней/);
});
test('lists beyond 2000 and export preserve the complete filtered remainder',()=>{
  const rows=Array.from({length:2501},(_,i)=>op({id:String(i+1),packId:'KR-'+i}));
  const r=work.build(rows,{now});assert.equal(r.rows.length,2501);assert.equal(r.totals.packRemaining,62525);
  const text=work.csv(work.build([op({model:'=HYPERLINK("x")'})],{now,kind:'partial',minDays:7,search:'KR-1'}));
  assert.ok(text.includes("'=HYPERLINK"));assert.ok(text.includes('KR-1')&&text.includes('25'));
  assert.ok(text.includes('Принято частично')&&text.includes('"Дней с выдачи от";7')&&text.includes('"Поиск";"KR-1"'));
  assert.ok(!text.includes('расценк')&&!text.includes('зарплат'));
});

test('remaining cost uses every operation frozen rate, never the pack maximum multiplied by rates',()=>{
  const r=work.build([op({sewerPrice:'0.10'}),op({id:'2',operationName:'Распошив',acceptedQty:40,defectQty:0,sewerPrice:'42.35'})],{now,includeFinance:true});
  assert.equal(r.totals.packRemaining,25);assert.equal(r.totals.operationRemaining,35);
  assert.equal(r.rows[0].remainingCostCents,250);assert.equal(r.rows[1].remainingCostCents,42350);
  assert.equal(r.totals.remainingCostCents,42600);assert.equal(r.groups[0].remainingCostCents,42600);
  assert.equal(r.financeAvailable,true);
});
test('cost follows the same sewer/model/date/acceptance filters and current accepted wages are excluded',()=>{
  const rows=[op({sewerPrice:'42.30'}),op({id:'2',packId:'KR-2',model:'Юбка',sewerName:'Анна',acceptedQty:0,defectQty:0,sewerPrice:'0.10'})];
  const r=work.build(rows,{now,includeFinance:true,sewer:'Анна',model:'Юбка',cutFrom:'2026-11-01',cutTo:'2026-11-01',kind:'none'});
  assert.equal(r.rows.length,1);assert.equal(r.totals.remainingCostCents,500);assert.equal(r.groups[0].remainingCostCents,500);
  const partial=work.build([rows[0]],{now,includeFinance:true});
  assert.equal(partial.totals.remainingCostCents,105750,'only remaining 25 × 42.30, not accepted 20 or all issued 50');
});
test('non-financial view and CSV never expose a rate or cost, even if input contains rates',()=>{
  const r=work.build([op({sewerPrice:'42.30',priceCents:4230,remainingCostCents:105750})],{now});
  assert.equal(r.financeAvailable,false);assert.ok(!Object.hasOwn(r.totals,'remainingCostCents'));
  for(const key of ['sewerPrice','priceCents','remainingCostCents'])assert.ok(!Object.hasOwn(r.rows[0],key));
  assert.ok(!work.csv(r).includes('Расценка')&&!work.csv(r).includes('Стоимость'));
});
test('zero rates are explicit, invalid rates and unsafe money amounts block the calculation',()=>{
  const zero=work.build([op({sewerPrice:0})],{now,includeFinance:true});
  assert.equal(zero.totals.remainingCostCents,0);assert.equal(zero.totals.zeroPriceOperations,1);
  for(const sewerPrice of [undefined,null,'','-1','0.001'])assert.throws(()=>work.build([op({sewerPrice})],{now,includeFinance:true}),/расценку/);
  assert.throws(()=>work.build([op({issuedQty:Number.MAX_SAFE_INTEGER,packQty:Number.MAX_SAFE_INTEGER,acceptedQty:0,defectQty:0,sewerPrice:'1.00'})],{now,includeFinance:true}),/Сумма/);
});
test('financial export includes exact cents, frozen rate and remaining cost columns',()=>{
  const r=work.build([op({sewerPrice:'42.35'})],{now,includeFinance:true});
  const text=work.csv(r);
  assert.ok(text.includes('Расценка швеи, ₽')&&text.includes('Стоимость остатка, ₽'));
  assert.ok(text.includes('42,35')&&text.includes('1058,75'));
  assert.ok(text.includes('Начисление зарплаты — после приёмки ОТК'));
});
