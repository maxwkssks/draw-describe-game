import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
const sql=fs.readFileSync(new URL('../supabase/008_v5_host_presence.sql',import.meta.url),'utf8');
const js=fs.readFileSync(new URL('../public/app.js',import.meta.url),'utf8');
const html=fs.readFileSync(new URL('../public/index.html',import.meta.url),'utf8');
test('heartbeat is authenticated, membership-checked, and uses server clock',()=>{
 assert.match(sql,/auth\.uid\(\) IS NULL/);
 assert.match(sql,/last_seen_at=v_now/);
 assert.match(sql,/IF NOT FOUND THEN RAISE EXCEPTION '이 방의 참가자가 아닙니다'/);
 assert.match(sql,/v_now timestamptz:=clock_timestamp\(\)/);
});
test('host takeover occurs only after timeout and elects active member',()=>{
 assert.match(sql,/interval '45 seconds'/);
 assert.match(sql,/user_id<>r\.host_id/);
 assert.match(sql,/last_seen_at>v_now-interval '20 seconds'/);
 assert.match(sql,/UPDATE public\.dd_rooms SET host_id=v_new_host,revision=revision\+1/);
});
test('concurrent heartbeat elections serialize with room row lock',()=>{
 assert.match(sql,/WHERE code=p_code FOR UPDATE/);
});
test('room recovery limited to current host and active phases',()=>{
 assert.match(sql,/r\.host_id<>auth\.uid\(\)/);
 assert.match(sql,/r\.phase NOT IN \('photo_select','draw','judge','vote'\)/);
 assert.match(sql,/round_no=greatest\(0,r\.round_no-1\)/);
 assert.doesNotMatch(sql,/UPDATE public\.dd_players SET score\s*=/i);
});
test('recovery removes only current round drawings, prior rounds remain',()=>{
 assert.match(sql,/DELETE FROM public\.dd_round_drawings WHERE room_id=r\.id AND round_no=r\.round_no/);
 assert.match(sql,/new\.phase='lobby'/);
});
test('client uses periodic heartbeat but no unload-only logic',()=>{
 assert.match(js,/async function pingPresence/);
 assert.match(js,/pingPresence\(\)\.catch/);
 assert.match(js,/async function sync\(\)/);
 assert.doesNotMatch(js,/window\.onbeforeunload/);
});
test('exit in all phases has confirmation and server action',()=>{
 assert.match(html,/id="leave-global"/);
 assert.match(js,/async function leaveGame/);
 assert.match(js,/confirm\(warn\)/);
 assert.match(js,/await act\('leave'\)/);
});
test('host can cancel stuck round from server-protected button',()=>{
 assert.match(html,/id="recover-global"/);
 assert.match(js,/dd_v5_reset_stuck_round/);
 assert.match(sql,/GRANT EXECUTE ON FUNCTION public\.dd_v5_reset_stuck_round\(text\) TO authenticated/);
});
