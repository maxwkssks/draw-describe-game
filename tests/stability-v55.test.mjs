import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';
const app=readFileSync(new URL('../public/app.js',import.meta.url),'utf8');
const section=(a,b)=>app.slice(app.indexOf(a),app.indexOf(b));

test('concurrent auth calls start only one anonymous session',async()=>{
  const src=section('async function ensureAuth(){','async function rpc(');
  let sessions=0,logins=0;
  const ctx={configured:true,authReady:false,authPromise:null,
    db:{auth:{async getSession(){sessions++;await new Promise(r=>setTimeout(r,10));return {data:{session:null}}},async signInAnonymously(){logins++;return {error:null}}}},
    setTimeout,clearTimeout,Promise,Error};
  vm.createContext(ctx);vm.runInContext(src+'\nthis.ensureAuth=ensureAuth;',ctx);
  await Promise.all([ctx.ensureAuth(),ctx.ensureAuth(),ctx.ensureAuth()]);
  assert.equal(sessions,1);assert.equal(logins,1);assert.equal(ctx.authReady,true);
});

test('failed anonymous sign-in is retried instead of permanently cached',async()=>{
  const src=section('async function ensureAuth(){','async function rpc(');
  let attempts=0;
  const ctx={configured:true,authReady:false,authPromise:null,
    db:{auth:{async getSession(){return {data:{session:null}}},async signInAnonymously(){attempts++;return {error:attempts===1?new Error('temporary failure'):null}}}},
    setTimeout,clearTimeout,Promise,Error};
  vm.createContext(ctx);vm.runInContext(src+'\nthis.ensureAuth=ensureAuth;',ctx);
  await assert.rejects(ctx.ensureAuth(),/temporary failure/);
  await ctx.ensureAuth();assert.equal(attempts,2);assert.equal(ctx.authReady,true);
});

test('polling timeout releases UI lock and later request succeeds',async()=>{
  const helpers=section('function withDeadline(','async function rpc(');
  const sync=section('async function sync(){','async function recoverRound(){');
  let calls=0,handled=0;
  const ctx={roomCode:'147392',syncSequence:0,syncInFlight:false,sessionGeneration:2,
    state:null,pingPresence:async()=>{},refreshLobbyMeta:async()=>{},
    api:async()=>{calls++;if(calls===1)return new Promise(()=>{});return {code:'147392',phase:'lobby',players:[],revision:2}},
    onState:()=>{handled++},$:()=>({}),console,localStorage:{removeItem(){}},show(){},toast(){},
    setTimeout,clearTimeout,Promise,Error};
  vm.createContext(ctx);
  // Accelerate the deadline in the test while exercising the real timeout logic.
  vm.runInContext(helpers+'\n'+sync.replace("withDeadline(api('state'),10000,", "withDeadline(api('state'),20,")+'\nthis.sync=sync;',ctx);
  await ctx.sync();assert.equal(ctx.syncInFlight,false);assert.equal(handled,0);
  await ctx.sync();assert.equal(ctx.syncInFlight,false);assert.equal(handled,1);
});

test('stability patch preserves guarded drawing, voting and room recovery',()=>{
  assert.match(app,/queuedSubmit=queuedSubmit\|\|submitted/);
  assert.match(app,/dd_v5_reset_stuck_round/);
  assert.match(app,/dd_v4_submit_vote/);
  assert.match(app,/requestId!==syncSequence/);
  assert.match(app,/withDeadline\(rpc\('dd_v4_lobby'/);
});
