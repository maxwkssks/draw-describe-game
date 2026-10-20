import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
const sql=readFileSync(new URL('../supabase/009_v5_blind_team_scoring.sql',import.meta.url),'utf8');
const ui=readFileSync(new URL('../public/app.js',import.meta.url),'utf8');
const style=readFileSync(new URL('../public/styles.css',import.meta.url),'utf8');
test('prior v5 state and action wrappers retained',()=>{
 assert.match(sql,/RENAME TO dd_v5_before_ballot_state/);
 assert.match(sql,/RENAME TO dd_v5_before_ballot_action/);
 assert.match(sql,/RETURN public\.dd_v5_before_ballot_state\(p_code\)/);
 assert.match(sql,/RETURN public\.dd_v5_before_ballot_action\(p_code,p_action,p_data\)/);
});
test('vote assignments explicitly exclude own art and balance judge teams',()=>{
 assert.match(sql,/t\.user_id<>d\.artist_id/g);
 assert.match(sql,/t\.team_code='red'/);
 assert.match(sql,/t\.team_code='blue'/);
 assert.match(sql,/LIMIT 2/g);
});
test('scoring only proceeds when votes complete or deadline reached',()=>{
 assert.match(sql,/missing_count>0 AND clock_timestamp\(\)<r\.judge_deadline/);
 assert.match(sql,/r_n>0 AND b_n>0/);
});
test('ballot hides team and author identities, uses existing protected RPC',()=>{
 const source=readFileSync(new URL('../supabase/001_v4_team_blind_migration.sql',import.meta.url),'utf8');
 const sub=source.slice(source.indexOf('CREATE OR REPLACE FUNCTION public.dd_v4_my_ballot'),source.indexOf('-- IMPORTANT: no public RPC'));
 assert.doesNotMatch(sub,/jsonb_build_object\([^]*'artist_id'/);
 assert.match(source,/d\.artist_id=auth\.uid\(\)/);
 assert.match(source,/primary key\(drawing_id,voter_id\)/);
 assert.match(ui,/dd_v4_submit_vote/);
});
test('room state exposes results only at result or final',()=>{
 assert.match(sql,/IF r\.phase IN \('result','final'\) THEN/);
 assert.match(sql,/CASE WHEN r\.phase IN \('result','final'\) THEN v_cards ELSE '\[\]'::jsonb END/);
});
test('private photo visibility becomes authorized to game members at vote',()=>{
 assert.match(sql,/r\.phase IN \('vote','result','final'\) AND r\.match_type='team'/);
 assert.match(sql,/p\.user_id=auth\.uid\(\)/);
});
test('client team judge and result UIs exist',()=>{
 assert.match(ui,/vote:'teamVote'/);
 assert.match(ui,/function teamVote\(/);
 assert.match(ui,/function bindTeamVote\(/);
 assert.match(ui,/function teamResult\(/);
 assert.match(ui,/function teamFinal\(/);
 assert.match(ui,/p_shape:score\.shape/);
 assert.match(style,/\.vote-art/);
});
test('migration does not erase source tables',()=>{
 assert.doesNotMatch(sql,/DROP TABLE|TRUNCATE|DELETE FROM public\.dd_/i);
});
