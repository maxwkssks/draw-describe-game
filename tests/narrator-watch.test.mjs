import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
const js=readFileSync(new URL('../public/app.js',import.meta.url),'utf8');
const sql=readFileSync(new URL('../supabase/010_v5_narrator_watch.sql',import.meta.url),'utf8');
test('live view only from narrator game branch',()=>{
 assert.match(js,/if\(state\.isNarrator\)\{securePhoto\(\);bindNarratorWatch\(\)\}/);
 assert.match(js,/rpc\('dd_narrator_live_gallery'/);
});
test('gallery is snapshot polled and redrawn',()=>{
 assert.match(js,/setInterval\(loadNarratorGallery,2800\)/);
 assert.match(js,/drawTo\(c\.getContext\('2d'\),a\.strokes/);
});
test('RPC restricts solo narrator and team-specific narrator',()=>{
 assert.match(sql,/r\.narrator_id IS DISTINCT FROM auth\.uid\(\)/);
 assert.match(sql,/auth\.uid\(\)=r\.red_narrator_id/);
 assert.match(sql,/auth\.uid\(\)=r\.blue_narrator_id/);
 assert.match(sql,/p\.team_code=viewer_team/);
});
test('RPC restricts viewing to active draw phase & room members',()=>{
 assert.match(sql,/r\.phase<>'draw'/);
 assert.match(sql,/user_id=auth\.uid\(\)/);
 assert.match(sql,/REVOKE ALL ON FUNCTION public\.dd_narrator_live_gallery/);
});
