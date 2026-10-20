import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
const app=readFileSync(new URL('../public/app.js',import.meta.url),'utf8');
const sql=readFileSync(new URL('../supabase/007_v5_unlimited_mode.sql',import.meta.url),'utf8');
test('UI exposes endless mode and the one-round completion target',()=>{
 assert.match(app,/data-mode="0"/);
 assert.match(app,/completion-target/);
 assert.match(app,/dd_v5_create_room/);
});
test('timer and drawing cutoff are bypassed only for unlimited mode',()=>{
 assert.match(app,/state\?\.duration===0\?Infinity/);
 assert.match(app,/state\.duration===0\|\|remaining\(\)>0/);
});
test('server checks real player count at game start',()=>{
 assert.match(sql,/현재 참가 인원으로는 설정된 완성 기준/);
 assert.match(sql,/현재 팀 인원으로는 지정한 팀별 완성 기준/);
});
test('server counts submissions atomically and blocks repeat submissions',()=>{
 assert.match(sql,/FOR UPDATE/);
 assert.match(sql,/me\.submitted/);
 assert.match(sql,/done>=r\.completion_target/);
 assert.match(sql,/red_done>=r\.completion_target AND blue_done>=r\.completion_target/);
});
test('only completed team drawings are evaluated and cap per team applies',()=>{
 assert.match(sql,/p\.submitted/);
 assert.match(sql,/partition by p\.team_code/);
 assert.match(sql,/q\.rn<=r\.completion_target/);
});
test('manual close is host gated, solo unfinished are excluded',()=>{
 assert.match(sql,/r\.host_id<>auth\.uid\(\)/);
 assert.match(sql,/AND NOT submitted/);
 assert.match(sql,/r\.phase IN \('judge','result'\)/);
});
test('old timed modes delegate to existing tested handlers',()=>{
 assert.match(sql,/RETURN public\.dd_v4_action\(p_code,p_action,p_data\)/);
 assert.match(sql,/RETURN response/);
 assert.match(sql,/r\.duration_seconds<>0/);
});
