import {test} from 'node:test';import assert from 'node:assert/strict';import {readFileSync} from 'node:fs';
const sql=readFileSync(new URL('../supabase/004_v4_team_rounds.sql',import.meta.url),'utf8');
const js=readFileSync(new URL('../public/app.js',import.meta.url),'utf8');
test('team narrators selected individually',()=>{assert.match(sql,/red_narrator_id=red_id,blue_narrator_id=blue_id/);assert.match(sql,/n_red<2 OR n_blue<2/)});
test('team same photo used and hidden from artists',()=>{assert.match(sql,/r\.photo_id=f\.id/);assert.match(sql,/r\.blue_narrator_id/);assert.match(sql,/IF r\.photo_id IS NOT NULL/)});
test('snapshots and no premature scoring',()=>{assert.match(sql,/INSERT INTO public\.dd_round_drawings/);assert.match(sql,/phase='vote'/);assert.doesNotMatch(sql,/INSERT INTO public\.dd_votes/)});
test('legacy solo funcs preserved behind wrapper',()=>{assert.match(sql,/RENAME TO dd_v3_state/);assert.match(sql,/RENAME TO dd_v3_action/);assert.match(sql,/RETURN public\.dd_v3_state/);assert.match(sql,/RETURN public\.dd_v3_action/)});
test('team lobby start and vote phase have UI',()=>{assert.match(js,/vote:'teamVote'/);assert.match(js,/function teamVote/);assert.match(js,/teamReady/)});
test('step 4 does not drop data',()=>{assert.doesNotMatch(sql,/DROP TABLE|TRUNCATE|DELETE FROM public\.dd_/i)});
