const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const vm=require('node:vm');
async function fixture({cap=1000,denied=false,failPage=false,hideRange=false}={}){
  const calls=[],events=Array.from({length:2501},(_,i)=>({id:i+1,pack_id:'KR-'+i,event_type:'Оплата швее',payload:{operation:'Оверлок',paid:true,qty:1},created_at:'2026-11-23T12:00:00Z'}));
  const context={URLSearchParams,AbortController,setTimeout,clearTimeout,performance,console:{info(){}},document:{addEventListener(){}},sessionStorage:{getItem(){return null;}},
    fetch:async(url,options)=>{
      const path=new URL(url),name=path.pathname.split('/').pop();calls.push({path,method:options.method});
      let body={},ok=true,status=200,range=null;
      if(name==='get_payroll_recovery'){
        assert.equal(options.method,'POST');
        if(denied){ok=false;status=403;body={message:'Недостаточно прав для сверки выплаты'};}
        else body={success:true,paymentDate:'2026-11-23',operations:[],payments:[]};
      }else if(name==='pack_events'){
        assert.equal(options.method,'GET');assert.equal(path.searchParams.get('order'),'id.asc');
        assert.match(path.searchParams.get('event_type'),/Оплата швее/);assert.ok(!path.searchParams.has('created_at'),'Earlier cumulative transitions must be included');
        const offset=Number(path.searchParams.get('offset')),limit=Math.min(Number(path.searchParams.get('limit')),cap);
        body=events.slice(offset,offset+limit);range=body.length?offset+'-'+(offset+body.length-1)+'/'+events.length:'*/'+events.length;
        if(failPage&&offset>0){ok=false;status=503;body={message:'Журнал недоступен'};}
      }else assert.equal(options.method,'GET','No payment mutation is allowed');
      return{ok,status,headers:{get:()=>hideRange?null:range},text:async()=>JSON.stringify(body)};
    }};
  context.window={location:{search:'?backend=supabase'},API:{},SUPABASE_CONFIG:{url:'https://example.test',anonKey:'public-test-key'}};
  vm.runInNewContext(fs.readFileSync(process.env.PILOT_API_FILE||require.resolve('../supabase/pilot-api.js'),'utf8'),context);
  await context.window.API.checkConnection();return{api:context.window.API,calls};
}
test('payroll history loads all 2501 events with small server caps and no writes',async()=>{
  const {api,calls}=await fixture({cap:100});
  assert.equal((await api.getPayrollRecovery('2026-11-23')).paymentEvents.length,2501);
  assert.equal(calls.filter(c=>c.path.pathname.endsWith('/pack_events')).length,26);
  assert.ok(calls.every(c=>c.method==='GET'||c.path.pathname.endsWith('/rpc/get_payroll_recovery')));
});
test('an unavailable later event page blocks a misleading partial payment receipt',async()=>{
  const {api}=await fixture({failPage:true});await assert.rejects(api.getPayrollRecovery('2026-11-23'),/Журнал недоступен/);
});
test('hidden proxy count headers do not truncate the journal',async()=>{
  const {api}=await fixture({cap:100,hideRange:true});assert.equal((await api.getPayrollRecovery('2026-11-23')).paymentEvents.length,2501);
});
test('finance permission denial never falls back to directly reading the ledger',async()=>{
  const {api,calls}=await fixture({denied:true});await assert.rejects(api.getPayrollRecovery('2026-11-23'),/Недостаточно прав/);
  assert.equal(calls.filter(c=>c.path.pathname.endsWith('/pack_events')).length,0);
});
