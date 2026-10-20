import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync,existsSync} from 'node:fs';
const root=new URL('../',import.meta.url);
const read=p=>readFileSync(new URL(p,root),'utf8');
test('core website files exist',()=>{for(const p of ['public/index.html','public/app.js','public/admin.html','public/admin.js','supabase/schema.sql','vercel.json'])assert.ok(existsSync(new URL(p,root)),p)});
test('game UI uses Supabase RPC instead of local Node API',()=>{const s=read('public/app.js');assert.match(s,/db\.rpc\(name,args\)/);assert.match(s,/dd_v5_create_room/);assert.match(s,/dd_state/);assert.doesNotMatch(s,/fetch\('\/api\//)});
test('auth and storage policies present',()=>{const s=read('supabase/schema.sql');assert.match(s,/enable row level security/);assert.match(s,/dd_can_read_photo/);assert.match(s,/dd_is_admin/);assert.match(s,/dd_action/);assert.match(s,/phase='judge'/)});
test('admin uses separate authentication storage',()=>assert.match(read('public/admin.js'),/storageKey:'dd-admin-auth'/));
test('Vercel output matches generated dist',()=>assert.equal(JSON.parse(read('vercel.json')).outputDirectory,'dist'));

test('step 3 exposes a guarded narrator-only photo choice screen',()=>{
 const app=read('public/app.js');
 assert.match(app,/photo_select:'photoSelect'/);
 assert.match(app,/dd_v4_photo_options/);
 assert.match(app,/dd_v4_choose_photo/);
 assert.match(app,/createSignedUrls/);
 assert.match(app,/사진을 고르고 있어요/);
 assert.match(app,/const readyToStart=m&&\['solo','team'\]\.includes\(m.matchType\)/);
});
test('step 3 migration preserves existing data and guards selections',()=>{
 const sql=read('supabase/003_v4_photo_selection.sql');
 for(const frag of ['CREATE OR REPLACE FUNCTION public.dd_begin_round','CREATE OR REPLACE FUNCTION public.dd_v4_photo_options','CREATE OR REPLACE FUNCTION public.dd_v4_choose_photo','CREATE OR REPLACE FUNCTION public.dd_can_read_photo','r.narrator_id IS DISTINCT FROM auth.uid()','r.phase=\'photo_select\'','category=ANY(r.allowed_categories)','r.match_type<>\'solo\'','p_photo_id'])assert.ok(sql.includes(frag),frag);
 assert.doesNotMatch(sql,/\bDROP\s+TABLE\b/i);
 assert.doesNotMatch(sql,/\bTRUNCATE\b/i);
 assert.doesNotMatch(sql,/\bDELETE\s+FROM\s+public\./i);
});
test('step 3 admin supports four categories and disabling photos',()=>{
 const admin=read('public/admin.js');
 for(const v of ['real_person','animal','soop','anime_character'])assert.ok(admin.includes(v));
 assert.match(admin,/is_active/);assert.match(admin,/async function updatePhoto/);
});
