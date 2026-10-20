import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';
const app=readFileSync(new URL('../public/app.js',import.meta.url),'utf8');
const functionSource=(from,to)=>app.slice(app.indexOf(from),app.indexOf(to));

test('lobby has manual refresh and foreground refresh triggers',()=>{
  assert.match(app,/id="refresh-lobby"/);
  assert.match(app,/\$\('#refresh-lobby'\)\?\.addEventListener/);
  for(const event of ['visibilitychange','focus','online'])assert.ok(app.includes(`'${event}'`));
});
test('stale room responses rejected and state fetch precedes heartbeat',()=>{
  assert.match(app,/\+s\.revision<\+state\.revision/);
  assert.match(app,/sessionGeneration!==requestedSession/);
  const sync=functionSource('async function sync(){','async function recoverRound(){');
  assert.ok(sync.indexOf("await api('state')")<sync.indexOf('pingPresence().catch'));
  assert.doesNotMatch(sync,/await pingPresence\(/);
});
test('newer roster rerenders lobby, older response does not roll it back',()=>{
  const src=functionSource('function onState(s,force=false){','async function pingPresence(){');
  let renders=0;
  const ui={'#leave-global':{hidden:false},'#recover-global':{hidden:false},'#status':{textContent:'',className:''}};
  const context={state:{code:'123456',phase:'lobby',revision:1,players:[{id:'a',ready:true,submitted:false}],cards:[]},presenceMeta:null,lobbyLastUpdated:0,roomCode:'123456',lastSignature:'',view:'lobby',lobbyMeta:null,phaseMap:{lobby:'lobby'},render(){renders++},show(){throw Error('should not navigate')},updateClock(){},checkCutoff(){},$:key=>ui[key],JSON,Date,Number};
  vm.createContext(context);
  vm.runInContext(src+'\nthis.onState=onState;',context);
  const make=(rev,ids)=>({code:'123456',phase:'lobby',round:0,revision:rev,players:ids.map(id=>({id,ready:true,online:true,submitted:false})),cards:[],host:true});
  context.onState(make(2,['a','b']));
  assert.equal(context.state.players.length,2);
  assert.equal(renders,1);
  context.onState(make(1,['a']));
  assert.equal(context.state.players.length,2);
  assert.equal(renders,1);
});
test('heartbeat that never responds cannot hold the state polling lock',async()=>{
  const src=functionSource('async function sync(){','async function recoverRound(){');
  let handled=0;
  const ctx={roomCode:'123456',syncInFlight:false,sessionGeneration:1,state:null,pingPresence:()=>new Promise(()=>{}),refreshLobbyMeta:()=>Promise.resolve(),onState:()=>handled++,api:()=>Promise.resolve({code:'123456',phase:'lobby',players:[],revision:1}),$:()=>({}),console,localStorage:{removeItem(){}},show(){},toast(){}};
  vm.createContext(ctx);vm.runInContext(src+'\nthis.sync=sync;',ctx);
  await Promise.race([ctx.sync(),new Promise((_,reject)=>setTimeout(()=>reject(Error('sync stuck')),400))]);
  assert.equal(handled,1);
  assert.equal(ctx.syncInFlight,false);
});
