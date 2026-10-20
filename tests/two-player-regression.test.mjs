import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';
const app = readFileSync(new URL('../public/app.js', import.meta.url),'utf8');
const sql = readFileSync(new URL('../supabase/003_v4_photo_selection.sql', import.meta.url),'utf8');

test('photo options and choice enforce authenticated narrator + phase',()=>{
 assert.match(sql, /r\.narrator_id IS DISTINCT FROM auth\.uid\(\)/);
 assert.match(sql,/r\.phase<>'photo_select'/);
 assert.match(sql,/category=ANY\(r\.allowed_categories\)/);
 assert.match(sql,/SELECT \* INTO r FROM public\.dd_rooms WHERE code=p_code FOR UPDATE/i);
});
test('2 players each use independent session in private browsing',()=>{
 assert.match(app,/storageKey:'dd-game-auth'/);
 assert.match(app,/signInAnonymously\(\)/);
 assert.match(app,/dd_join_room/);
});
test('photo list stays hidden from second player in the client',()=>{
 assert.match(app,/if\(!\(state\?\.isSelector\?\?state\?\.isNarrator\)\)return `<div class="container"/);
 assert.match(app,/if\(optionsLoading\|\|state\?\.phase!=='photo_select'\|\|!\(state\.isSelector\?\?state\.isNarrator\)\)return/);
});
test('submission during pending autosave is not dropped',async()=>{
 const match=app.match(/async function saveDrawing\(submitted=false\)\{[\s\S]*?\nasync function actDrawing/);
 assert.ok(match, 'saveDrawing function found');
 let release;
 const blocker=new Promise(resolve=>release=resolve);
 const calls=[];
 const box={textContent:''};
 const ctx={
 state:{phase:'draw',isNarrator:false}, saving:false,queued:false,queuedSubmit:false,
 dirty:true, strokes:[{points:[[1,2]]}],lastSaved:0,Date,JSON,
 editVersion:0,submittedLocally:false,setTimeout,
 $:()=>box,
 actDrawing:async (data, submitted)=>{calls.push({data,submitted});if(calls.length===1)await blocker;},
 };
 vm.createContext(ctx);
 vm.runInContext(match[0].replace(/\nasync function actDrawing$/,''),ctx);
 const first=vm.runInContext('saveDrawing(false)',ctx);
 await Promise.resolve();
 const second=vm.runInContext('saveDrawing(true)',ctx);
 release();
 await Promise.all([first,second]);
 await new Promise(resolve=>setTimeout(resolve,750));
 assert.equal(calls.length,2);
 assert.deepEqual(calls.map(c=>c.submitted),[false,true]);
});
test('built site requires server configured public keys, not secret keys',()=>{
 const build=readFileSync(new URL('../scripts/build.mjs',import.meta.url),'utf8');
 assert.match(build,/SUPABASE_ANON_KEY/);
 assert.doesNotMatch(build,/SERVICE_ROLE|sb_secret_/);
});
