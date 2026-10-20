import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';
const sql=readFileSync(new URL('../supabase/005_v4_save_grace.sql',import.meta.url),'utf8');
const app=readFileSync(new URL('../public/app.js',import.meta.url),'utf8');
test('team finalization delayed five seconds and snapshots are retained',()=>{
 assert.match(sql,/clock_timestamp\(\)<r\.deadline\+interval '5 seconds'/);
 assert.match(sql,/r\.deadline\+interval '5 seconds'<=clock_timestamp\(\)/);
 assert.match(sql,/INSERT INTO public\.dd_round_drawings/);
 assert.match(sql,/ON CONFLICT \(room_id,round_no,artist_id\) DO NOTHING/);
});
test('host early end starts grace instead of immediate snapshot',()=>{
 assert.match(sql,/deadline=least\(r\.deadline,clock_timestamp\(\)\)/);
 const end=sql.slice(sql.indexOf("ELSIF p_action='end'"));
 assert.doesNotMatch(end,/PERFORM public\.dd_v4_team_finish/);
});
test('after cutoff only submitted=true snapshots may arrive',()=>{
 assert.match(sql,/r\.deadline<=clock_timestamp\(\) AND coalesce\(\(p_data->>'submitted'\)::boolean,false\) IS DISTINCT FROM true/);
 assert.match(sql,/me\.submitted/);
});
test('UI disables painting and finalizes on clock cutoff',()=>{
 assert.match(app,/canvas\.style\.pointerEvents='none'/);
 assert.match(app,/saveDrawing\(true\)/);
 assert.match(app,/if\(remaining\(\)<=0\|\|submittedLocally\)return/);
 assert.match(app,/setInterval\(\(\)=>\{updateClock\(\);checkCutoff\(\)\},250\)/);
});
test('edited while save in flight is queued rather than marked clean',()=>{
 assert.match(app,/savedVersion===editVersion/);
 assert.match(app,/else \{dirty=true;queued=true\}/);
 assert.match(app,/queuedSubmit\|\|\(state\?\.matchType==='team'&&remaining\(\)<=0\)/);
});
test('migration avoids destructive data operations',()=>{
 assert.doesNotMatch(sql,/DROP TABLE|TRUNCATE|DELETE FROM public\.dd_/i);
 assert.match(sql,/CREATE OR REPLACE FUNCTION public\.dd_state/);
 assert.match(sql,/CREATE OR REPLACE FUNCTION public\.dd_action/);
});
