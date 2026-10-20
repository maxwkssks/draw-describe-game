import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
const html=readFileSync(new URL('../public/index.html',import.meta.url),'utf8');
const css=readFileSync(new URL('../public/styles.css',import.meta.url),'utf8');
const js=readFileSync(new URL('../public/app.js',import.meta.url),'utf8');
test('exit button exists once and is outside dynamic #view',()=>{
  assert.equal((html.match(/id="leave-global"/g)||[]).length,1);
  assert.ok(html.indexOf('id="leave-global"')<html.indexOf('id="view"'));
  assert.match(html,/leave-floating/);
});
test('exit control respects hidden and remains visible during scrolling',()=>{
  assert.match(css,/#leave-global\.leave-floating\{position:fixed/);
  assert.match(css,/#leave-global\.leave-floating\[hidden\]\{display:none!important/);
});
test('exit confirms and calls server leave action',()=>{
  assert.match(js,/async function leaveGame\(\)/);
  assert.match(js,/if\(!confirm\(warn\)\)return/);
  assert.match(js,/await act\('leave'\)/);
  assert.match(js,/\$\('#leave-global'\)\.onclick=leaveGame/);
});
