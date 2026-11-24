const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const vm=require('node:vm');
const payroll=require('../payroll-statement.js');

class Element {
  constructor(tag='div'){this.tag=tag;this.children=[];this._value='';this._html='';this.disabled=false;this.hidden=false;this.textContent='';}
  get value(){return this._value;}
  set value(v){this._value=this.tag==='select'&&!this.children.some(x=>x.value===String(v))?'':String(v);}
  get innerHTML(){return this._html;}
  set innerHTML(v){this._html=v;if(this.tag==='select'){this.children=[];for(const match of v.matchAll(/<option value="([^"]*)">([^<]*)<\/option>/g)){const e=new Element('option');e.value=match[1];e.textContent=match[2];this.children.push(e);}this._value=this.children[0]?.value||'';}}
  appendChild(e){this.children.push(e);}
  querySelectorAll(){return[];}
}
function operation(id,name){return{operationId:id,packId:'KR-'+id,passport:'П-'+id,model:'Блуза',cutDate:'2026-11-01',operationName:'Оверлок',sewerName:name,issuedQty:50,acceptedNow:40,acceptedBefore:25,paidQty:10,price:'42.30',recoveryQty:15,remainingAfter:15,needsReview:false,fingerprint:'a'.repeat(32)};}
function preview(date,names=['Анна','Мутриба']){return{success:true,paymentDate:date,operations:names.map((n,i)=>operation(i+1,n)),payments:[]};}
function deferred(){let resolve,reject;const promise=new Promise((yes,no)=>{resolve=yes;reject=no;});return{promise,resolve,reject};}
function ui(getPreview){
  const fields=new Map(),reads=[],writes=[],loading=[],toasts=[];
  for(const id of ['date','sewer','model','mode','filter-status','result','history','notice','actions','exports','selection','record','select-all'])fields.set('recovery-'+id,new Element(['sewer','model','mode'].includes(id)?'select':'div'));
  fields.get('recovery-mode').innerHTML='<option value="due">Не отмечено</option><option value="all">Всё</option>';
  const root={location:{search:'?payrollDate=2026-11-09'},currentUser:{role:'admin'},PayrollStatement:payroll,
    document:{getElementById:id=>fields.get(id),createElement:tag=>new Element(tag)},
    showScreen(){},showLoading:(id,value)=>loading.push(value),showToast:message=>toasts.push(message),
    API:{getPayrollRecovery:date=>{reads.push(date);return getPreview(date);},recordPayrollRecovery:()=>{writes.push(true);throw new Error('Unexpected payment write');}}};
  vm.runInNewContext(fs.readFileSync(process.env.RECOVERY_FILE||require.resolve('../payroll-recovery.js'),'utf8'),{window:root,URLSearchParams});
  return{api:root.PayrollRecovery,fields,reads,writes,loading,toasts,el:id=>fields.get('recovery-'+id)};
}

test('entering Past payment automatically loads selectable sewers without clicking Update',async()=>{
  const response=deferred(),app=ui(()=>response.promise),pending=app.api.open();
  assert.deepEqual(app.reads,['2026-11-09']);assert.equal(app.el('sewer').disabled,true);assert.match(app.el('filter-status').textContent,/Загружаю/);
  response.resolve(preview('2026-11-09'));await pending;
  assert.deepEqual(app.el('sewer').children.map(x=>x.value),['','Анна','Мутриба']);
  assert.equal(app.el('sewer').disabled,false);
  app.el('sewer').value='Мутриба';app.api.filter();
  assert.match(app.el('result').innerHTML,/Мутриба/);assert.ok(!app.el('result').innerHTML.includes('Анна'));
  assert.equal(app.el('record').disabled,true);assert.equal(app.writes.length,0);
});

test('saved-receipt-only sewer remains selectable and filters the saved statement',async()=>{
  const saved={success:true,paymentDate:'2026-11-09',operations:[],payments:[{batchId:'saved',paymentDate:'2026-11-09',recordedAt:'2026-11-23T12:00:00Z',count:1,amount:'190',entries:[{eventId:'1',packId:'KR-498',passport:'П-498',model:'ЛонгКрючки',cutDate:'2026-10-29',sewerName:'Мутриба',operationName:'Оверлок',qty:2,price:'95',amount:'190'}]}]};
  const app=ui(()=>Promise.resolve(saved));await app.api.open();
  assert.deepEqual(app.el('sewer').children.map(x=>x.value),['','Мутриба']);
  assert.deepEqual(app.el('model').children.map(x=>x.value),['','ЛонгКрючки']);
  app.el('sewer').value='Мутриба';app.api.filter();
  assert.match(app.el('history').innerHTML,/Мутриба/);assert.match(app.el('history').innerHTML,/190 ₽/);
  assert.match(app.el('history').innerHTML,/Сводная по моделям/);
  assert.match(app.el('history').innerHTML,/ЛонгКрючки/);
  assert.match(app.el('history').innerHTML,/Оверлок/);
  assert.match(app.el('history').innerHTML,/29\.10\.2026/);
  assert.match(app.el('history').innerHTML,/2 × 95/);
  assert.match(app.el('history').innerHTML,/<details open>/);
  assert.equal(app.el('actions').hidden,true);assert.equal(app.writes.length,0);
});

test('saved model totals and calculations follow both filters and escape names without payment writes',async()=>{
  const saved={...preview('2026-11-09',[]),payments:[{batchId:'saved',paymentDate:'2026-11-09',recordedAt:'2026-11-23T12:00:00Z',count:3,amount:'310',entries:[
    {eventId:'1',packId:'KR-1',passport:'П-1',model:'Блуза',cutDate:'2026-11-01',sewerName:'Анна',operationName:'Оверлок',qty:2,price:'95',amount:'190'},
    {eventId:'2',packId:'KR-2',passport:'П-2',model:'Юбка',cutDate:'2026-11-02',sewerName:'Мутриба',operationName:'Распошив',qty:3,price:'30',amount:'90'},
    {eventId:'3',packId:'KR-3',passport:'П-3',model:'<Топ>',cutDate:'2026-11-03',sewerName:'Мутриба',operationName:'<Оверлок>',qty:2,price:'15',amount:'30'}
  ]}]};
  const app=ui(()=>Promise.resolve(saved));await app.api.open();
  assert.match(app.el('history').innerHTML,/ведомости: 310 ₽/);
  assert.match(app.el('history').innerHTML,/&lt;Топ&gt;/);assert.ok(!app.el('history').innerHTML.includes('<Топ>'));
  app.el('sewer').value='Мутриба';app.api.filter();
  assert.match(app.el('history').innerHTML,/ведомости: 120 ₽/);assert.ok(!app.el('history').innerHTML.includes('Блуза'));
  app.el('model').value='Юбка';app.api.filter();
  assert.match(app.el('history').innerHTML,/ведомости: 90 ₽/);assert.match(app.el('history').innerHTML,/3 × 30/);
  assert.ok(!app.el('history').innerHTML.includes('&lt;Топ&gt;'));assert.equal(app.writes.length,0);
});

test('changing date reloads read-only data and preserves the chosen sewer if available',async()=>{
  const app=ui(date=>Promise.resolve(preview(date)));await app.api.open();app.el('sewer').value='Мутриба';
  app.el('date').value='2026-11-10';await app.api.load();
  assert.deepEqual(app.reads,['2026-11-09','2026-11-10']);assert.equal(app.el('sewer').value,'Мутриба');
  assert.match(app.el('result').innerHTML,/10\.11\.2026/);assert.equal(app.writes.length,0);
});

test('late result from the old date cannot replace the newer sewer list',async()=>{
  const first=deferred(),second=deferred(),app=ui(date=>date==='2026-11-09'?first.promise:second.promise);
  const old=app.api.open();app.el('date').value='2026-11-10';const fresh=app.api.load();
  second.resolve(preview('2026-11-10',['Светлана']));await fresh;first.resolve(preview('2026-11-09',['Анна']));await old;
  assert.deepEqual(app.el('sewer').children.map(x=>x.value),['','Светлана']);assert.equal(app.el('sewer').disabled,false);assert.equal(app.writes.length,0);
});

test('failed load releases selectors and can be retried without any payment calls',async()=>{
  let failed=true;const app=ui(date=>failed?Promise.reject(new Error('Сервер недоступен')):Promise.resolve(preview(date)));
  await app.api.open();assert.equal(app.el('sewer').disabled,false);assert.match(app.el('filter-status').textContent,/не загружен/);
  failed=false;await app.api.load();assert.ok(app.el('sewer').children.some(x=>x.value==='Мутриба'));assert.equal(app.writes.length,0);
});

test('clearing the date during load cancels the old result and never leaves filters locked',async()=>{
  const response=deferred(),app=ui(()=>response.promise),pending=app.api.open();
  app.el('date').value='';app.api.load();response.resolve(preview('2026-11-09'));await pending;
  assert.equal(app.el('sewer').disabled,false);assert.match(app.el('filter-status').textContent,/корректную дату/);
  assert.deepEqual(app.el('sewer').children.map(x=>x.value),['']);assert.equal(app.writes.length,0);
});
