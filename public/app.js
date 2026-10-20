'use strict';
const $=(q,root=document)=>root.querySelector(q), $$=(q,root=document)=>[...root.querySelectorAll(q)];
const esc=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const btn=(text,kind='btn-secondary',attrs='')=>`<button class="btn ${kind}" ${attrs}>${text}</button>`;
let state=null,roomCode=localStorage.getItem('dd_room_code'),view='home',lastSignature='',photoObject=null,photoKey='',strokes=[],stroke=null,tool='pen',color='#181827',size=5,dirty=false,saving=false,queued=false,queuedSubmit=false,lastSaved=0,localRanks=[],editVersion=0,finalFlushStarted=false,submittedLocally=false;
const cfg=window.DD_CONFIG||{};
const configured=cfg.supabaseUrl?.startsWith('https://')&&cfg.supabaseAnonKey&&!cfg.supabaseAnonKey.startsWith('REPLACE_');
const db=configured?window.supabase.createClient(cfg.supabaseUrl,cfg.supabaseAnonKey,{auth:{persistSession:true,autoRefreshToken:true,storageKey:'dd-game-auth'}}):null;
let ballot=null,ballotKey='',ballotLoading=false,voteSending=false,voteRatings={};
let liveGalleryLoading=false,liveGalleryLast=0,liveGalleryRound='',liveGalleryOpen=true;
let presenceMeta=null,lastPresencePing=0,presenceInFlight=false,syncInFlight=false;let authReady=false;let lobbyMeta=null;let metaFetchRunning=false;let lobbyLastUpdated=0,sessionGeneration=0;let photoOptions=null;let photoOptionsKey='';let optionsLoading=false;let photoChoosing=false;
function toast(msg){const t=$('#toast');t.textContent=msg;t.classList.add('show');setTimeout(()=>t.classList.remove('show'),3600)}
async function ensureAuth(){if(!configured)throw Error('config.js에 Supabase URL과 공개 키를 입력하세요');if(authReady)return;const {data:{session}}=await db.auth.getSession();if(!session){const {error}=await db.auth.signInAnonymously();if(error)throw error}authReady=true;}
async function rpc(name,args){await ensureAuth();const {data,error}=await db.rpc(name,args);if(error)throw new Error(error.message);return data;}
async function api(route,method='GET',body=null){
 if(route==='create'){const code=await rpc('dd_v5_create_room',{p_name:body.name,p_max_players:body.maxPlayers,p_rounds:body.rounds,p_duration:body.duration,p_match_type:body.matchType,p_photo_mode:body.photoMode,p_categories:body.categories,p_target:body.target??null});roomCode=code;localStorage.setItem('dd_room_code',code);return {code,state:await rpc('dd_state',{p_code:code})}}
 if(route==='join'){const code=await rpc('dd_join_room',{p_code:body.code,p_name:body.name});roomCode=code;localStorage.setItem('dd_room_code',code);return {code,state:await rpc('dd_state',{p_code:code})}}
 if(route==='state')return await rpc('dd_state',{p_code:roomCode});
 if(route==='action'){
   await rpc('dd_action',{p_code:roomCode,p_action:body.action,p_data:body});
   if(body.action==='leave')return null;
   return await rpc('dd_state',{p_code:roomCode});
 }
 throw Error('알 수 없는 요청');
}
const phaseMap={lobby:'lobby',photo_select:'photoSelect',draw:'game',judge:'judge',vote:'teamVote',result:'result',final:'final'};
function show(name){view=name;lastSignature='';render()}
function saveSession(out){sessionGeneration++;presenceMeta=null;lastPresencePing=0;lobbyLastUpdated=Date.now();roomCode=out.code;lobbyMeta=null;localStorage.setItem('dd_room_code',roomCode);state=out.state;strokes=[];show(phaseMap[state.phase]);if(state.phase==='lobby')refreshLobbyMeta();}
async function act(action,extra={}){try{const s=await api('action','POST',{action,...extra});if(action==='leave'){sessionGeneration++;roomCode=null;state=null;presenceMeta=null;lobbyMeta=null;localStorage.removeItem('dd_room_code');show('home')}else onState(s,true)}catch(e){toast(e.message)}}
function onState(s,force=false){
 // A delayed response must not replace a newer participant list or phase.
 if(state?.code===s.code&&Number.isFinite(+state.revision)&&Number.isFinite(+s.revision)&&+s.revision<+state.revision)return;
 if(s.phase==='lobby')lobbyLastUpdated=Date.now();
 if(presenceMeta?.players&&Array.isArray(s.players)){
   const online=new Map(presenceMeta.players.map(p=>[p.id,p.online]));
   s.players=s.players.map(p=>({...p,online:online.get(p.id)??p.online}));
 }
 const previous=state;state=s;$('#leave-global').hidden=!roomCode;$('#recover-global').hidden=!(roomCode&&s.host&&['photo_select','draw','judge','vote'].includes(s.phase));$('#status').textContent='● 연결됨';$('#status').className='pill connected';const next=phaseMap[s.phase];if(view==='admin')return;const signature=[s.phase,s.round,s.revision,JSON.stringify(lobbyMeta),s.players.map(p=>p.id+':'+p.ready+':'+p.online+':'+p.submitted).join(','),s.cards.length,JSON.stringify(s.ballotProgress||{}),JSON.stringify(s.roundScore||{})].join('/');if(force||next!==view){if(previous?.phase==='draw'&&s.phase!=='draw'&&dirty)dirty=false;if(previous?.phase!=='draw'&&s.phase==='draw'){liveGalleryLast=0;liveGalleryRound='';liveGalleryOpen=true;strokes=s.myStrokes||[];dirty=false;editVersion=0;finalFlushStarted=false;submittedLocally=false;queued=false;queuedSubmit=false;photoKey=''}if(previous?.phase!==s.phase&&s.phase==='photo_select'){photoOptions=null;photoOptionsKey='';photoChoosing=false;}show(next)}else if(next==='lobby'||next==='photoSelect'||next==='teamPending'||next==='judge'||next==='result'||next==='final'){if(signature!==lastSignature)render()}else if(next==='game'){
 const narrator=$('#narrator-name');if(narrator)narrator.textContent=s.narratorName;
 const indicator=$('#players-live');if(indicator)indicator.innerHTML=participants(true);const progress=$('#unlimited-progress');if(progress)progress.textContent=unlimitedProgress();
 }
lastSignature=signature;updateClock();checkCutoff();}
async function pingPresence(){
 if(!roomCode||presenceInFlight||Date.now()-lastPresencePing<6500)return;
 presenceInFlight=true;
 try{presenceMeta=await rpc('dd_v5_presence_ping',{p_code:roomCode});lastPresencePing=Date.now();}
 finally{presenceInFlight=false;}
}
async function sync(){
 if(!roomCode||syncInFlight)return;
 const requestedRoom=roomCode,requestedSession=sessionGeneration;
 syncInFlight=true;
 try{
   // Fetch the room roster first. A delayed heartbeat must not block new arrivals.
   const s=await api('state');
   if(roomCode!==requestedRoom||sessionGeneration!==requestedSession)return;
   onState(s);
   if(s.phase==='lobby')refreshLobbyMeta();
   // Never hold the roster synchronization lock for a slow heartbeat.
   pingPresence().catch(e=>console.warn('Presence heartbeat failed:',e.message));
 }catch(e){
   if(roomCode!==requestedRoom||sessionGeneration!==requestedSession)return;
   if(e.message.includes('참가자가 아닙니다')||e.message.includes('방을 찾을 수 없습니다')||e.message.includes('이 방의 참가자가 아닙니다')){
     sessionGeneration++;localStorage.removeItem('dd_room_code');roomCode=null;state=null;presenceMeta=null;lobbyMeta=null;show('home');toast('방 연결이 종료됐습니다');
   }else{$('#status').textContent='● 재연결 시도 중';$('#status').className='pill disconnected';}
 }finally{syncInFlight=false;}
}
async function recoverRound(){
 if(!roomCode||!state?.host)return;
 if(!confirm('현재 라운드를 취소하고 대기실로 돌아갈까요? 이번 라운드의 미확정 그림은 삭제되지만 이전 점수는 유지됩니다.'))return;
 try{await rpc('dd_v5_reset_stuck_round',{p_code:roomCode});await sync()}catch(e){toast(e.message)}
}
async function leaveGame(){
 if(!roomCode||!state)return;
 const warn=state.host?'방장을 나가면 남은 참가자에게 방장 권한이 넘어갑니다. 나갈까요?':'현재 게임에서 나갈까요?';
 if(!confirm(warn))return;
 await act('leave');
}
async function doCreate(){const name=$('#nickname').value.trim(),maxPlayers=+$('#people').value,rounds=+$('#rounds').value,duration=+$('.option.selected').dataset.mode;const matchType=$('#match-type').value,photoMode=$('#photo-mode').value;const categories=$$('[data-category]:checked').map(x=>x.value);const target=duration===0?+$('#completion-target').value:null;if(!categories.length)return toast('최소 한 개의 사진 카테고리를 선택하세요');if(matchType==='team'&&maxPlayers<4)return toast('팀전 정원은 최소 4명이어야 합니다');try{saveSession(await api('create','POST',{name,maxPlayers,rounds,duration,matchType,photoMode,categories,target}))}catch(e){toast(e.message)}}
async function refreshLobbyMeta(){
 if(metaFetchRunning||!roomCode)return;
 const requestedRoom=roomCode,requestedSession=sessionGeneration;
 metaFetchRunning=true;
 try{
  const meta=await rpc('dd_v4_lobby',{p_code:requestedRoom});
  if(roomCode!==requestedRoom||sessionGeneration!==requestedSession)return;
  if(JSON.stringify(meta)!==JSON.stringify(lobbyMeta)){
    lobbyMeta=meta;
    if(state?.phase==='lobby'&&view==='lobby')render();
  }
 }catch(e){if(roomCode===requestedRoom)console.warn('Lobby metadata unavailable',e.message)}
 finally{metaFetchRunning=false}
}
async function assignTeams(mode,id=null,team=null){try{await rpc('dd_v4_assign_teams',{p_code:roomCode,p_mode:mode,p_player_id:id,p_team:team});await refreshLobbyMeta();await sync()}catch(e){toast(e.message)}}
async function doJoin(){const name=$('#join-name').value.trim(),code=$('#join-code').value.trim();try{saveSession(await api('join','POST',{name,code}))}catch(e){toast(e.message)}}
function render(){if($('#leave-global'))$('#leave-global').hidden=!roomCode;if($('#recover-global'))$('#recover-global').hidden=!(roomCode&&state?.host&&['photo_select','draw','judge','vote'].includes(state?.phase));if(view!=='game'&&view!=='judge'&&view!=='result'&&view!=='teamVote'&&view!=='final'){photoObject=null;photoKey=''}const views={home,create,join,lobby,photoSelect,game,teamVote,judge,result,final};$('#view').innerHTML=(views[view]||home)();$$('[data-screen]').forEach(el=>el.onclick=()=>show(el.dataset.screen));({create:bindCreate,join:bindJoin,lobby:bindLobby,photoSelect:bindPhotoSelect,game:bindGame,teamVote:bindTeamVote,judge:bindJudge,result:bindResult,final:bindFinal})[view]?.();updateClock()}
function home(){return `<div class="container"><section class="hero"><div class="eyebrow">MULTIPLAYER DRAWING PARTY</div><h1>듣기만 해도<br><span class="gradient">그림이 그려질까?</span></h1><p class="subtitle">사진을 본 설명자가 디스코드로 묘사해요.<br>다른 사람들은 그림을 그리고, 설명자가 1·2·3등을 선정합니다.</p><div class="btn-list">${btn('✦ 방 만들기','btn-primary','data-screen="create"')}${btn('↗ 코드로 입장하기','btn-secondary','data-screen="join"')}</div><div class="feature-row"><div class="feature">👥<h3>최대 20명</h3><p>다른 기기에서도 같은 서버 주소와 방 코드로 참여할 수 있어요.</p></div><div class="feature">🎙<h3>디스코드 음성</h3><p>그림은 사이트에서, 말로 설명하는 건 디스코드에서 해요.</p></div><div class="feature">🏆<h3>설명자 직접 심사</h3><p>1~10라운드 진행, 순위는 설명자가 결정해요.</p></div></div></section></div>`}
function create(){return `<div class="container"><div class="section-heading"><span class="eyebrow">CREATE ROOM</span><h1>게임 방 만들기</h1><p>게임 설정을 선택한 후 6자리 코드를 친구들에게 공유하세요.</p></div><div class="two-col"><div class="panel form-stack"><div class="field"><label>닉네임</label><input class="input" id="nickname" maxlength="16" value="플레이어 1"/></div><div class="field"><div class="range-line"><label>최대 인원</label><strong id="people-value">10명</strong></div><input type="range" min="2" max="20" value="10" id="people"/></div><div class="field"><div class="range-line"><label>총 라운드</label><strong id="rounds-value">5라운드</strong></div><input type="range" min="1" max="10" value="5" id="rounds"/></div><div class="field"><label>그림 제한 시간</label><div class="option-group"><button data-mode="120" class="option"><strong>2분</strong><small>빠른 진행</small></button><button data-mode="180" class="option selected"><strong>3분</strong><small>기본</small></button><button data-mode="300" class="option"><strong>5분</strong><small>상세 묘사</small></button><button data-mode="0" class="option"><strong>∞ 무제한</strong><small>완성 수 기준</small></button></div><div class="field" id="unlimited-options" hidden><div class="range-line"><label>한 라운드 완성 기준</label><strong id="target-value">1명</strong></div><input type="range" min="1" max="9" value="1" id="completion-target"/><p class="small-help" id="target-help">개인전은 전체 인원, 팀전은 각 팀별 기준입니다. 실제 참가 인원을 넘게 설정하면 시작할 수 없습니다.</p></div></div><div class="field"><label>경쟁 방식</label><select class="input" id="match-type"><option value="solo">개인전</option><option value="team">팀전 (4명 이상)</option></select></div><div class="field"><label>사진 출제</label><select class="input" id="photo-mode"><option value="random">랜덤 출제</option><option value="select">설명자가 사진 직접 선택</option></select></div><div class="field"><label>허용 카테고리 (복수 선택)</label><div class="v4-categories">${[['real_person','실제인물'],['animal','동물'],['soop','SOOP'],['anime_character','애니메이션 캐릭터']].map(([v,n])=>`<label><input data-category type="checkbox" value="${v}" checked> ${n}</label>`).join('')}</div></div><div class="info-strip">개인전은 랜덤/사진선택 모두 실제 플레이 가능 · 팀전도 설명자 2명·그림 저장까지 진행 가능 (팀전 블라인드 심사 지원)</div>${btn('방 생성하기 →','btn-primary btn-wide','id="create-now"')}</div><div class="panel"><h3>진행 방식</h3><div class="notice">① 6자리 코드로 입장<br>② 방장을 제외한 참가자는 준비 버튼 누르기<br>③ 방장 시작 → 자동으로 설명자 선정<br>④ 설명자가 원본을 보고 디스코드로 설명<br>⑤ 타이머 종료 후 익명 그림 심사<br>⑥ 결과 공개 → 다음 라운드</div><p class="tip">서버는 동작 중이어야 합니다. 사진 원본은 설명자에게만 제공되고, 마감 후 전체 공개됩니다.</p></div></div></div>`}
function bindCreate(){
const refresh=()=>{const n=+$('#people').value,team=$('#match-type').value==='team',unlimited=+$('.option.selected').dataset.mode===0;
 const max=Math.max(1,team?Math.floor(n/2)-1:n-1);const sl=$('#completion-target');sl.max=max;sl.value=Math.min(+sl.value,max);$('#target-value').textContent=team?`팀당 ${sl.value}명`:`${sl.value}명`;$('#unlimited-options').hidden=!unlimited;
};
$('#match-type').onchange=()=>{if($('#match-type').value==='team'&&+$('#people').value<4){$('#people').value=4;$('#people-value').textContent='4명'}refresh()};
$('#people').oninput=e=>{$('#people-value').textContent=e.target.value+'명';refresh()};
$('#rounds').oninput=e=>$('#rounds-value').textContent=e.target.value+'라운드';
$('#completion-target').oninput=refresh;
$$('[data-mode]').forEach(el=>el.onclick=()=>{$$('[data-mode]').forEach(b=>b.classList.toggle('selected',b===el));refresh()});
$('#create-now').onclick=doCreate;refresh()}

function join(){return `<div class="container"><div class="panel center-panel"><span class="eyebrow">JOIN ROOM</span><h2>6자리 코드로 입장</h2><p class="muted">친구에게 받은 6자리 코드를 입력하세요.</p><div class="form-stack"><div class="field"><label>닉네임</label><input class="input" id="join-name" maxlength="16" placeholder="닉네임"/></div><div class="field"><label>방 코드</label><input class="input" id="join-code" maxlength="6" inputmode="numeric" placeholder="123456" value="${esc(new URLSearchParams(location.search).get('room')||'')}"/></div>${btn('참가하기','btn-primary btn-wide','id="join-now"')}</div></div></div>`}
function bindJoin(){$('#join-now').onclick=doJoin}
function participants(compact=false){return state.players.map((p,i)=>`<div class="user"><span class="avatar">${i+1}</span><div><strong>${esc(p.name)} ${p.id===state.me?'(나)':''}</strong><small class="${p.ready?'ready-tag':'waiting-tag'}">${p.host?'👑 방장 · ':''}${p.online===false?'오프라인':'접속 중'}${state.phase==='lobby'?p.ready?' · 준비':' · 미준비':(p.isNarrator||p.id===state.narrator)?' · 설명자':p.submitted?' · 저장됨':' · 그림 작업'}</small></div></div>`).join('')}
function lobby(){const everybody=state.players.every(p=>p.ready);const m=lobbyMeta;const isTeam=m?.matchType==='team';const readyToStart=m&&['solo','team'].includes(m.matchType)&&['random','select'].includes(m.photoMode);const teamReady=!isTeam||(state.players.length>=4&&['red','blue'].every(t=>state.players.filter(p=>(m?.teams||[]).some(x=>x.id===p.id&&x.team===t)).length>=2)&&Math.abs(state.players.filter(p=>(m?.teams||[]).some(x=>x.id===p.id&&x.team==='red')).length-state.players.filter(p=>(m?.teams||[]).some(x=>x.id===p.id&&x.team==='blue')).length)<=1);const teams=Object.fromEntries((m?.teams||[]).map(x=>[x.id,x.team]));const categories={real_person:'실제인물',animal:'동물',soop:'SOOP',anime_character:'애니메이션 캐릭터'};const teamPanel=isTeam?`<div class="panel" style="margin-top:14px"><h3>팀 배정</h3>${state.host?btn('팀 자동 배정','btn-secondary btn-sm','id="auto-teams"'):''}<div class="team-columns">${['red','blue'].map(t=>`<div class="team-col ${t}"><h3>${t==='red'?'🔴 레드팀':'🔵 블루팀'}</h3>${state.players.filter(p=>teams[p.id]===t).map(p=>`<div class="team-entry"><span>${esc(p.name)}</span>${state.host?`<button class="tool" data-switch="${p.id}" data-to="${t==='red'?'blue':'red'}">팀 이동</button>`:''}</div>`).join('')||'<small>배정된 참가자 없음</small>'}</div>`).join('')}</div><p class="tip">새 참가자는 인원이 적은 팀으로 자동 배정됩니다. 방장은 언제든 변경할 수 있습니다.</p></div>`:'';return `<div class="container"><div class="section-heading"><span class="eyebrow">WAITING ROOM</span><h1>참가자 대기실</h1><p>참가자는 준비 버튼을 누르고 방장이 게임을 시작합니다.</p></div><div class="two-col"><section class="panel"><div class="row space-between"><div class="room-code"><small>방 코드</small><strong>${state.code}</strong></div>${btn('초대 링크 복사','btn-secondary btn-sm','id="copy-link"')}</div><div class="row space-between" style="margin-top:24px;align-items:center;gap:8px"><h3 style="margin:0">참가자 ${state.players.length}/${state.maxPlayers}</h3>${btn('↻ 인원 새로고침','btn-secondary btn-sm','id="refresh-lobby" type="button"')}</div><p class="tip" id="lobby-updated">인원 목록은 약 1.4초마다 갱신됩니다.</p><div class="user-grid">${participants()}</div>${teamPanel}<div class="btn-list">${!state.host?btn(state.players.find(p=>p.id===state.me).ready?'준비 취소':'준비 완료','btn-primary','id="ready"'):''}${btn('방 나가기','btn-ghost','id="leave"')}</div></section><section class="panel"><h3>게임 설정</h3><div class="rank-summary"><div class="rank-row"><span>최대 인원</span><strong>${state.maxPlayers}명</strong></div><div class="rank-row"><span>라운드</span><strong>${state.rounds}회</strong></div><div class="rank-row"><span>그림 시간</span><strong>${state.duration===0?'무제한 · 완성 '+(m?.matchType==='team'?'팀당 ':'')+(state.completionTarget??'설정')+'명':state.duration/60+'분'}</strong></div><div class="rank-row"><span>사진 수</span><strong>${m?.eligiblePhotoCount??'확인 중'}장 (카테고리 기준)</strong></div><div class="rank-row"><span>경쟁 방식</span><strong>${isTeam?'팀전':'개인전'}</strong></div><div class="rank-row"><span>사진 방식</span><strong>${m?.photoMode==='select'?'사진 선택':'랜덤'}</strong></div><div class="rank-row"><span>카테고리</span><strong>${(m?.categories||[]).map(x=>categories[x]||x).join(', ')||'불러오는 중'}</strong></div></div>${isTeam?'<div class="notice">팀전은 각 팀 2명 이상, 인원 차이 1명 이하일 때 시작됩니다. 그림 마감 후 참가자들이 익명으로 평가하고 팀 평균 점수를 발표합니다.</div>':''}${state.host?btn('게임 시작 →','btn-primary btn-wide',`id="start-game" ${!readyToStart||!teamReady||state.players.length<2||!everybody||!m?.eligiblePhotoCount?'disabled':''}`):`<div class="notice">방장이 게임을 시작할 때까지 기다려 주세요.</div>`}<p class="tip">최소 2명 · 참가자 모두 준비 · 사진 1장 이상 필요</p></section></div></div>`}
function bindLobby(){$('#refresh-lobby')?.addEventListener('click',async()=>{await sync();if(roomCode&&state?.phase==='lobby')toast('참가자 목록 갱신 완료')});$('#copy-link').onclick=async()=>{const link=location.origin+'/?room='+state.code;try{await navigator.clipboard.writeText(link);toast('초대 링크 복사 완료')}catch{toast(link)}};$('#ready')?.addEventListener('click',()=>act('ready',{value:!state.players.find(p=>p.id===state.me).ready}));$('#start-game')?.addEventListener('click',()=>act('start'));$('#leave').onclick=leaveGame;$('#auto-teams')?.addEventListener('click',()=>assignTeams('auto'));$$('[data-switch]').forEach(el=>el.onclick=()=>assignTeams('manual',el.dataset.switch,el.dataset.to))}
const photoCategoryNames={real_person:'실제인물',animal:'동물',soop:'SOOP',anime_character:'애니메이션 캐릭터'};
async function loadPhotoOptions(){
 if(optionsLoading||state?.phase!=='photo_select'||!(state.isSelector??state.isNarrator))return;
 const key=state.code+':'+state.round+':'+state.revision;
 if(photoOptionsKey===key&&photoOptions!==null)return;
 optionsLoading=true;
 try{
  const data=await rpc('dd_v4_photo_options',{p_code:roomCode});
  if(!Array.isArray(data))throw Error('사진 목록 형식이 올바르지 않습니다');
  if(state?.phase!=='photo_select'||!(state.isSelector??state.isNarrator))return;
  photoOptions=data.map(p=>({...p,url:null}));photoOptionsKey=key;
  if(view==='photoSelect')render();
  // Batch preview signing; private bucket RLS checks narrator + selected categories.
  const paths=photoOptions.map(p=>p.path);
  if(paths.length){
   const {data:signed,error}=await db.storage.from('dd-originals').createSignedUrls(paths,120);
   if(error)throw error;
   if(state?.phase!=='photo_select'||!(state.isSelector??state.isNarrator)||photoOptionsKey!==key)return;
   photoOptions=photoOptions.map((p,i)=>({...p,url:signed?.[i]?.signedUrl||null}));
   if(view==='photoSelect')render();
  }
 }catch(e){toast('사진 목록을 불러오지 못했습니다: '+e.message)}finally{optionsLoading=false}
}
async function confirmPhoto(id){
 if(photoChoosing||state?.phase!=='photo_select'||!(state.isSelector??state.isNarrator))return;
 const p=photoOptions?.find(x=>x.id===id);
 if(!p)return toast('사진 목록을 다시 불러와 주세요');
 if(!confirm(`「${p.name}」 사진을 확정하고 ${state.duration===0?'무제한':' '+state.duration/60+'분'} 그림 그리기를 시작할까요?`))return;
 photoChoosing=true;
 try{
  await rpc('dd_v4_choose_photo',{p_code:roomCode,p_photo_id:id});
  photoOptions=null;photoOptionsKey='';
  await sync();
 }catch(e){toast(e.message)}finally{photoChoosing=false}
}
function photoSelect(){
 if(!(state?.isSelector??state?.isNarrator))return `<div class="container"><div class="panel center-panel"><span class="eyebrow">ROUND ${state.round} / ${state.rounds}</span><h2>🖼 설명자가 사진을 고르고 있어요</h2><p class="muted">설명자: ${esc(state.narratorName)} · 사진이 확정되면 그림 그리기가 시작됩니다.</p><div class="notice">원본 및 선택 가능한 사진 목록은 공개되지 않습니다. 잠시 기다려 주세요.</div></div></div>`;
 const photos=photoOptions||[];
 return `<div class="container"><div class="section-heading"><span class="eyebrow">PRIVATE PHOTO CHOICE · ROUND ${state.round} / ${state.rounds}</span><h1>🔒 설명자 전용 사진선택</h1><p>방에서 허용한 카테고리의 사진만 보여요. 사진을 확정하면 전체 참가자의 제한 시간이 동시에 시작돼요.</p></div><div class="panel"><div class="row space-between" style="margin-bottom:18px"><strong>사용 가능한 사진 ${photos.length}장</strong>${btn('새로 불러오기','btn-secondary btn-sm','id="reload-photos"')}</div>${photoOptions===null?'<div class="notice">보안 확인 후 사진을 불러오는 중...</div>':photos.length?`<div class="choice-grid">${photos.map(p=>`<article class="choice-card"><div class="choice-preview">${p.url?`<img src="${esc(p.url)}" alt="${esc(p.name)}" loading="lazy">`:'<span>썸네일을 표시할 수 없습니다</span>'}</div><div class="choice-info"><strong>${esc(p.name)}</strong><small>${esc(photoCategoryNames[p.category]||p.category)} ${p.used?'· 이번 게임에 사용됨':''}</small></div>${btn('이 사진으로 시작','btn-primary btn-wide',`data-photo-id="${esc(p.id)}" ${photoChoosing?'disabled':''}`)}</article>`).join('')}</div>`:'<div class="notice">선택할 수 있는 활성 사진이 없습니다. 관리자 사진 및 카테고리 설정을 확인해 주세요.</div>'}</div></div>`;
}
function bindPhotoSelect(){if(!(state.isSelector??state.isNarrator))return;loadPhotoOptions();$('#reload-photos')?.addEventListener('click',()=>{photoOptions=null;photoOptionsKey='';loadPhotoOptions()});$$('[data-photo-id]').forEach(b=>b.onclick=()=>confirmPhoto(b.dataset.photoId));}
function remaining(){return state?.duration===0?Infinity:Math.max(0,Math.ceil((state.deadline-Date.now())/1000))}
function clockText(n){return String(Math.floor(n/60)).padStart(2,'0')+':'+String(n%60).padStart(2,'0')}
function updateClock(){const t=$('#timer');if(t&&state?.phase==='draw')t.textContent=state.duration===0?'∞ 무제한':clockText(remaining());const vt=$('#vote-time');if(vt&&state?.phase==='vote')vt.textContent=state.voteDeadline?Math.max(0,Math.ceil((state.voteDeadline-Date.now())/1000))+'초 남음':'준비 중'}
// Team-mode clock lock: keep the UI in draw phase for the 5-second upload grace.
// Freeze edits immediately at zero and send the queued final snapshot.
function checkCutoff(){
 if(!state||state.phase!=='draw'||state.matchType!=='team'||state.duration===0||remaining()>0)return;
 if(state.isNarrator)return;
 const canvas=$('#drawing');if(canvas){canvas.style.pointerEvents='none';canvas.setAttribute('aria-disabled','true')}
 ['#undo','#clear','#submit-drawing'].forEach(id=>{const b=$(id);if(b)b.disabled=true});
 const msg=$('#save-status');if(msg&&!submittedLocally)msg.textContent='⏳ 시간 종료 · 마지막 그림 전송 중';
 if(!finalFlushStarted&&!submittedLocally){
   finalFlushStarted=true;
   if(stroke){stroke=null;editVersion++;dirty=true}
   saveDrawing(true);
 }
}

function unlimitedProgress(){if(!state||state.duration!==0)return '';const target=state.completionTarget??1;return state.matchType==='team'?`완성 현황 — 레드팀 ${state.completedRed??0}/${target}명 · 블루팀 ${state.completedBlue??0}/${target}명 (두 팀 모두 달성해야 심사 진행)`:`완성 현황 — ${state.completed??0}/${target}명 (기준 달성 시 심사 시작)`;}
function game(){const narrator=state.isNarrator;const team=state.matchType==='team';return `<div class="container"><div class="game-top"><div><span class="eyebrow">ROUND ${state.round} / ${state.rounds}</span><h2>🎨 ${team?'팀전 · ':''}설명 듣고 그리기</h2><span class="muted">${team?'레드 / 블루 설명자':'설명자'}: <strong id="narrator-name">${esc(state.narratorName)}</strong></span></div><div class="timer" id="timer">${state.duration===0?'∞ 무제한':clockText(remaining())}</div></div>${state.duration===0?`<div class="notice" id="unlimited-progress">${unlimitedProgress()}</div>`:''}<div class="game-layout"><section class="panel"><h3>${narrator?'🎙 설명자 전용 원본 사진':'✏ 내 그림판'}</h3>${narrator?`<div class="original-box" id="secure-photo"><div class="muted">원본 사진 불러오는 중...</div></div><p class="tip">${team?'본인 팀의 디스코드 음성 채널에서 설명하세요. 양 팀 설명자는 같은 원본을 봅니다.':'이 사진을 디스코드로 설명하세요. 다른 참가자에게 원본은 표시되지 않습니다.'}</p><div class="narrator-watch"><div class="row space-between"><h3>👀 참가자 그림 진행 상황</h3>${btn('그림 관전 숨기기','btn-secondary btn-sm','id="watch-toggle"')}</div><div class="muted-note">${team?'내 팀 참가자 그림만 표시됩니다.':'설명자를 제외한 참가자들의 그림이 표시됩니다.'} 약 3초 간격으로 서버에 저장된 내용을 갱신합니다.</div><div id="watch-status" class="muted-note">그림 불러오는 중...</div><div id="watch-grid" class="watch-grid"></div></div>`:`<div class="tools"><button class="tool active" data-tool="pen">✎ 펜</button><button class="tool" data-tool="eraser">▧ 지우개</button>${['#181827','#f43f5e','#facc15','#3b82f6','#22c55e','#a855f7'].map(c=>`<button class="colorbtn" data-color="${c}" style="background:${c}" aria-label="${c}"></button>`).join('')}<input type="range" min="2" max="30" id="brush" value="5" aria-label="굵기" style="width:85px"/><button class="tool" id="undo">↶ 되돌리기</button><button class="tool" id="clear">전체 지우기</button></div><div class="canvas-wrap"><canvas width="900" height="600" id="drawing"></canvas></div><div class="row space-between" style="margin-top:15px"><span class="submit-status" id="save-status">그리면 자동 저장됩니다</span>${btn(state.duration===0?'그림 완성 · 제출':'그림 제출','btn-primary btn-sm','id="submit-drawing"')}</div>`}</section><aside class="panel"><h3>참가자 현황</h3><div id="players-live" class="sidebar-list">${participants(true)}</div><div class="info-strip" style="margin-top:18px">${narrator?'설명만 해주세요. 직접 그리기는 불가능합니다.':'원본을 보지 않고 음성 설명을 듣고 그려주세요.'}</div>${state.host?btn('그림 조기 마감','btn-secondary btn-wide','id="end-round" style="margin-top:15px"'):''}</aside></div></div>`}
async function securePhoto(){
 const box=$('#secure-photo');if(!box||!state?.photoPath)return;
 const key=state.photoPath;
 if(photoObject&&photoKey===key){box.innerHTML=`<img alt="원본 사진" src="${photoObject}"/>`;return}
 try{
   await ensureAuth();
   const {data,error}=await db.storage.from('dd-originals').createSignedUrl(key,600);
   if(error)throw error;
   photoObject=data.signedUrl;photoKey=key;
   if($('#secure-photo'))$('#secure-photo').innerHTML=`<img alt="원본 사진" src="${esc(photoObject)}"/>`;
 }catch(e){if($('#secure-photo'))$('#secure-photo').textContent='사진 열람 불가: '+e.message}
}
// Narrator-only live canvas preview; server decides who can read every snapshot.
async function loadNarratorGallery(){
 if(!roomCode||!state||state.phase!=='draw'||!state.isNarrator||!liveGalleryOpen||liveGalleryLoading)return;
 if(Date.now()-liveGalleryLast<2400)return;
 const code=roomCode, round=state.round;
 liveGalleryLoading=true;liveGalleryLast=Date.now();
 try{
   const data=await rpc('dd_narrator_live_gallery',{p_code:code});
   if(roomCode!==code||state?.phase!=='draw'||state.round!==round||!state.isNarrator||!liveGalleryOpen)return;
   const grid=$('#watch-grid'),status=$('#watch-status');if(!grid)return;
   if(!Array.isArray(data))throw Error('관전 데이터 형식 오류');
   const signature=JSON.stringify(data);
   if(grid.dataset.snapshotSignature===signature)return;
   grid.dataset.snapshotSignature=signature;
   grid.innerHTML=data.length?data.map((a,i)=>`<article class="watch-art"><div class="row space-between"><strong>${esc(a.name)}</strong><small>${a.submitted?'✅ 제출 완료':'✏ 작성 중'}</small></div><canvas data-watch-index="${i}" width="450" height="300"></canvas></article>`).join(''):'<p class="muted">아직 관전할 그림이 없습니다.</p>';
   data.forEach((a,i)=>{const c=grid.querySelector(`[data-watch-index="${i}"]`);if(c)drawTo(c.getContext('2d'),a.strokes||[],450,300)});
   if(status)status.textContent=`${data.length}명 그림 표시 · ${data.filter(a=>a.submitted).length}명 제출 완료 · 약 3초 간격 갱신`;
 }catch(e){const status=$('#watch-status');if(status)status.textContent='관전 갱신 실패: '+e.message}
 finally{liveGalleryLoading=false}
}
function bindNarratorWatch(){
 const b=$('#watch-toggle');if(!b)return;
 b.onclick=()=>{liveGalleryOpen=!liveGalleryOpen;const grid=$('#watch-grid');grid.hidden=!liveGalleryOpen;b.textContent=liveGalleryOpen?'그림 관전 숨기기':'그림 관전 보이기';if(liveGalleryOpen){liveGalleryLast=0;loadNarratorGallery()}};
 liveGalleryLast=0;loadNarratorGallery();
}
function drawTo(ctx,ss,w=900,h=600){ctx.fillStyle='#fff';ctx.fillRect(0,0,w,h);for(const st of ss){if(!st.points?.length)continue;ctx.beginPath();ctx.lineCap='round';ctx.lineJoin='round';ctx.lineWidth=st.size*(w/900);ctx.strokeStyle=st.tool==='eraser'?'#ffffff':st.color;ctx.moveTo(st.points[0][0]*w/900,st.points[0][1]*h/600);for(const pt of st.points.slice(1))ctx.lineTo(pt[0]*w/900,pt[1]*h/600);if(st.points.length===1)ctx.lineTo(st.points[0][0]*w/900+.1,st.points[0][1]*h/600+.1);ctx.stroke()}}
function repaint(){const c=$('#drawing');if(c)drawTo(c.getContext('2d'),strokes)}
async function saveDrawing(submitted=false){
 if(!state||state.phase!=='draw'||state.isNarrator||submittedLocally)return;
 if(saving){queued=true;queuedSubmit=queuedSubmit||submitted;return}
 saving=true;
 const savedVersion=editVersion, packet=JSON.stringify(strokes);
 try{
   await actDrawing(JSON.parse(packet),submitted);
   lastSaved=Date.now();
   if(submitted){submittedLocally=true;dirty=false;queued=false;queuedSubmit=false;}
   else if(savedVersion===editVersion){dirty=false}
   else {dirty=true;queued=true}
   const t=$('#save-status');if(t)t.textContent=submitted?'✓ 최종 제출 완료':(dirty?'변경된 그림 재저장 중':'✓ 서버에 그림 저장됨');
 }catch(e){
   const t=$('#save-status');if(t)t.textContent='⚠ 저장 실패: '+e.message;
   dirty=true;
   if(submitted){queued=true;queuedSubmit=true}
 }finally{
   saving=false;
   if(queued&&!submittedLocally){
     const mustSubmit=queuedSubmit||(state?.matchType==='team'&&remaining()<=0);queued=false;queuedSubmit=false;
     // Retry a failed final submission while the team grace window remains open.
     if(!mustSubmit||state?.matchType!=='team'||Date.now()<(state.saveGraceUntil||0)){
       if(mustSubmit)setTimeout(()=>saveDrawing(true),600);else setTimeout(()=>saveDrawing(false),600);
     } else {const t=$('#save-status');if(t)t.textContent='⚠ 마감 후 최종 그림 전송 실패 · 서버 저장본이 사용됩니다'}
   }
 }
}
async function actDrawing(ss,submitted){const s=await api('action','POST',{action:'drawing',strokes:ss,submitted});if(state&&s.phase!==state.phase)onState(s,true)}
function bindGame(){if(state.isNarrator){securePhoto();bindNarratorWatch()}else{
 const canvas=$('#drawing');repaint();const point=e=>{const box=canvas.getBoundingClientRect();return [Math.max(0,Math.min(900,(e.clientX-box.left)*900/box.width)),Math.max(0,Math.min(600,(e.clientY-box.top)*600/box.height))]};canvas.onpointerdown=e=>{e.preventDefault();canvas.setPointerCapture(e.pointerId);if(remaining()<=0||submittedLocally)return;stroke={tool,color,size:tool==='eraser'?Math.max(20,size*3):size,points:[point(e)]};strokes.push(stroke);editVersion++;dirty=true;repaint()};canvas.onpointermove=e=>{if(!stroke||remaining()<=0)return;stroke.points.push(point(e));editVersion++;dirty=true;repaint()};canvas.onpointerup=()=>{stroke=null;saveDrawing()};canvas.onpointercancel=()=>{stroke=null;saveDrawing()};$$('[data-tool]').forEach(b=>b.onclick=()=>{tool=b.dataset.tool;$$('[data-tool]').forEach(x=>x.classList.toggle('active',x===b))});$$('[data-color]').forEach(b=>b.onclick=()=>{color=b.dataset.color;tool='pen';$$('[data-tool]').forEach(x=>x.classList.toggle('active',x.dataset.tool==='pen'))});$('#brush').oninput=e=>size=+e.target.value;$('#undo').onclick=()=>{if(remaining()<=0||submittedLocally)return;strokes.pop();editVersion++;dirty=true;repaint();saveDrawing()};$('#clear').onclick=()=>{if(confirm('그림을 전체 삭제할까요?')){if(remaining()<=0||submittedLocally)return;strokes=[];editVersion++;dirty=true;repaint();saveDrawing()}};$('#submit-drawing').onclick=()=>{if(remaining()<=0){checkCutoff();return}saveDrawing(true)}}$('#end-round')?.addEventListener('click',()=>{if(confirm('그림 그리기를 마감할까요? 미완성 그림은 심사에서 제외됩니다.'))act('end')});checkCutoff()}
function cards(){return state.cards.map(c=>`<div class="art-card"><canvas id="art-${c.id}" width="450" height="300"></canvas><strong>${esc(c.label)} ${c.name?`· ${esc(c.name)}`:'· 작성자 비공개'}</strong>${state.phase==='judge'&&state.isNarrator?`<div class="ranks">${[0,1,2].slice(0,state.need).map((_,i)=>`<button class="tool ${localRanks[i]===c.id?'picked':''}" data-choice="${i}" data-player="${c.id}">${i+1}등</button>`).join('')}</div>`:state.phase==='result'?`<small>${c.rank>0?['🥇 1등 +100점','🥈 2등 +70점','🥉 3등 +50점'][c.rank-1]:'0점'}</small>`:''}</div>`).join('')}
function paintCards(){for(const c of state.cards){const canvas=document.getElementById('art-'+c.id);if(canvas)drawTo(canvas.getContext('2d'),c.strokes||[],450,300)}}
// Step 5: assigned anonymous ballots are loaded through a separate restricted RPC.
const voteCriteria=[['형태 및 특징','shape',40],['구도 및 배치','position',30],['색상 일치','color',20],['세부 묘사','detail',10]];
async function loadBallot(){
 if(state?.phase!=='vote'||state.matchType!=='team'||ballotLoading)return;
 const key=state.code+':'+state.round;
 if(ballotKey===key&&ballot!==null)return;
 ballotLoading=true;
 try{
  const data=await rpc('dd_v4_my_ballot',{p_code:state.code});
  if(state?.phase!=='vote'||state.code+':'+state.round!==key)return;
  ballot=data;ballotKey=key;if(view==='teamVote')render();
 }catch(e){toast('심사 대상 불러오기 실패: '+e.message)}
 finally{ballotLoading=false}
}
function teamVote(){
 const entries=ballot?.items||[];
 const todo=entries.filter(x=>!x.submitted);
 const p=state.ballotProgress||{};
 const remainingMs=state.voteDeadline?Math.max(0,state.voteDeadline-Date.now()):null;
 return `<div class="container"><div class="section-heading"><span class="eyebrow">ROUND ${state.round} / ${state.rounds} · BLIND VOTE</span><h1>🕵️ 익명 그림 평가</h1><p>팀과 작성자를 숨긴 그림을 원본과 비교해 평가합니다. 자기 그림은 배정되지 않습니다.</p></div>
 <div class="panel"><h3>원본 사진</h3><div id="secure-photo" class="original-box">원본 불러오는 중...</div>
 <p class="tip">심사 마감: <span id="vote-time">${remainingMs===null?'준비 중':Math.ceil(remainingMs/1000)+'초 남음'}</span> · 총 평가 ${p.voted??0}/${p.assigned??0}</p></div>
 <div class="panel" style="margin-top:16px"><h3>내 평가 ${entries.length-todo.length}/${entries.length} 완료</h3>
 ${ballot===null?'<p class="muted">심사 대상 불러오는 중...</p>':todo.length===0?'<div class="notice">✅ 내 평가를 모두 완료했습니다. 다른 참가자들의 심사를 기다려 주세요.</div>':todo.map((d,i)=>{
  const score=voteRatings[d.drawingId]||{shape:30,position:23,color:15,detail:8};
  return `<div class="vote-art"><h3>익명 그림 ${i+1} / ${todo.length}</h3><canvas class="vote-canvas" data-vote-art="${esc(d.drawingId)}" width="450" height="300"></canvas>
   ${voteCriteria.map(([name,key,max])=>`<label class="vote-score-row"><span>${name}</span><input type="range" min="0" max="${max}" step="1" data-vote-range="${esc(d.drawingId)}" data-metric="${key}" value="${score[key]}"><strong data-rating="${esc(d.drawingId)}:${key}">${score[key]}/${max}</strong></label>`).join('')}
   <div class="row space-between"><strong>총점 <span data-vote-total="${esc(d.drawingId)}">${Object.values(score).reduce((a,b)=>a+b,0)}</span> / 100점</strong>
   ${btn('평가 제출','btn-primary btn-sm',`data-vote-submit="${esc(d.drawingId)}" ${voteSending?'disabled':''}`)}</div></div>`;
 }).join('')}</div></div>`;
}
function bindTeamVote(){
 securePhoto();loadBallot();
 for(const x of ballot?.items||[]){const canvas=$(`[data-vote-art="${x.drawingId}"]`);if(canvas)drawTo(canvas.getContext('2d'),x.strokes||[],450,300)}
 $$('[data-vote-range]').forEach(x=>x.oninput=()=>{
  const id=x.dataset.voteRange,k=x.dataset.metric;
  voteRatings[id]??={shape:30,position:23,color:15,detail:8};
  voteRatings[id][k]=Number(x.value);
  const label=$(`[data-rating="${id}:${k}"]`);if(label)label.textContent=x.value+'/'+voteCriteria.find(z=>z[1]===k)[2];
  const tot=$(`[data-vote-total="${id}"]`);if(tot)tot.textContent=Object.values(voteRatings[id]).reduce((a,b)=>a+b,0);
 });
 $$('[data-vote-submit]').forEach(x=>x.onclick=async()=>{
  if(voteSending)return;
  const id=x.dataset.voteSubmit,score=voteRatings[id]||{shape:30,position:23,color:15,detail:8};
  if(!confirm('이 그림의 점수를 확정할까요? 제출 후 변경할 수 없습니다.'))return;
  voteSending=true;x.disabled=true;
  try{
   await rpc('dd_v4_submit_vote',{p_code:roomCode,p_drawing_id:id,p_shape:score.shape,p_position:score.position,p_color:score.color,p_detail:score.detail});
   ballot=null;delete voteRatings[id];toast('평가 제출 완료');
   await sync();await loadBallot();
  }catch(e){toast('평가 제출 실패: '+e.message);x.disabled=false}
  finally{voteSending=false}
 });
}
function teamScoreBox(){const round=state.roundScore||{}, totals=state.teamTotals||{};
 return `<div class="team-score-grid"><div class="team-score red"><span>🔴 레드팀</span><strong>${round.red??'—'}</strong><small>이번 라운드 평균</small><div>누적 ${totals.red??0}점</div></div><div class="team-score blue"><span>🔵 블루팀</span><strong>${round.blue??'—'}</strong><small>이번 라운드 평균</small><div>누적 ${totals.blue??0}점</div></div></div>`}
function teamResult(){const cs=state.cards||[];return `<div class="container"><div class="section-heading"><span class="eyebrow">ROUND ${state.round} RESULT · TEAM</span><h1>🏆 블라인드 평가 결과</h1><p>익명 평가가 종료되어 팀과 작성자가 공개됐습니다.</p></div>
 ${teamScoreBox()}${state.roundScore?.counted===false?'<div class="notice">양 팀 유효 점수가 부족해 이 라운드는 누적 점수에 포함되지 않았습니다.</div>':''}
 <div class="panel" style="margin-top:16px"><h3>원본 사진</h3><div id="secure-photo" class="original-box">원본 불러오는 중...</div></div>
 <div class="gallery" style="margin-top:16px">${cs.map(c=>`<div class="art-card"><canvas id="art-${esc(c.id)}" width="450" height="300"></canvas><strong>${esc(c.name)} · ${c.team==='red'?'🔴 레드팀':'🔵 블루팀'}</strong><small>${c.score===null||c.score===undefined?'유효 평가 부족':c.score+'점'} · 레드 평가 ${c.redVotes}명 / 블루 평가 ${c.blueVotes}명</small></div>`).join('')}</div>
 <div class="panel" style="margin-top:16px">${state.host?btn(state.round>=state.rounds?'최종 결과 발표 →':'다음 라운드 →','btn-primary btn-wide','id="next-round"'):'<p class="tip">방장이 다음 라운드를 시작합니다.</p>'}</div></div>`}
function teamFinal(){const t=state.teamTotals||{};const red=Number(t.red||0),blue=Number(t.blue||0),title=red===blue?'🤝 공동 우승':red>blue?'🏆 레드팀 최종 우승':'🏆 블루팀 최종 우승';
 return `<div class="container"><section class="hero"><div class="eyebrow">TEAM GAME COMPLETE</div><h1>${title}</h1><p class="subtitle">전체 ${state.rounds}라운드 · 유효 ${t.countedRounds??0}라운드</p></section>${teamScoreBox()}<div class="notice">평가 미완료나 양 팀 중 한쪽 평가가 없는 그림은 점수 집계에서 제외됩니다.</div></div>`}
function judge(){if(!state.isNarrator)return `<div class="container"><div class="panel center-panel"><h2>🏅 설명자가 심사하고 있어요</h2><p class="muted">설명자: ${esc(state.narratorName)} · 결과가 확정되면 전원에게 공개됩니다.</p></div></div>`;return `<div class="container"><div class="section-heading"><span class="eyebrow">ROUND ${state.round} · JUDGING</span><h1>설명자가 1~${state.need}등을 정해주세요</h1><p>익명 그림을 보고 중복되지 않게 순위를 선정하세요.</p></div><div class="panel" style="margin-bottom:16px"><div id="secure-photo" class="original-box">원본 로딩 중...</div></div><div class="gallery">${cards()}</div><div class="panel" style="margin-top:18px"><div class="rank-summary">${Array.from({length:state.need},(_,i)=>`<div class="rank-row"><strong>${['🥇','🥈','🥉'][i]} ${i+1}등</strong><span>${localRanks[i]?esc(state.cards.find(c=>c.id===localRanks[i])?.label):'미선정'}</span></div>`).join('')}</div>${btn('순위 확정 및 결과 공개 →','btn-primary btn-wide',`id="confirm-ranks" ${localRanks.slice(0,state.need).some(x=>!x)?'disabled':''}`)}</div></div>`}
function bindJudge(){if(!state.isNarrator)return;securePhoto();paintCards();$$('[data-choice]').forEach(b=>b.onclick=()=>{const i=+b.dataset.choice,id=b.dataset.player;localRanks=localRanks.map((x,j)=>i===j?x:x===id?null:x);localRanks[i]=localRanks[i]===id?null:id;render()});$('#confirm-ranks').onclick=()=>act('judge',{ranks:localRanks.slice(0,state.need)})}
function scoreboard(){const arr=[...state.players].sort((a,b)=>b.score-a.score||a.name.localeCompare(b.name));return `<table class="board"><thead><tr><th>순위</th><th>참가자</th><th>누적 점수</th></tr></thead><tbody>${arr.map((p,i)=>`<tr><td>${['🥇','🥈','🥉'][i]||'#'+(i+1)}</td><td>${esc(p.name)}</td><td>${p.score}점</td></tr>`).join('')}</tbody></table>`}
function result(){if(state?.matchType==='team')return teamResult();return `<div class="container"><div class="section-heading"><span class="eyebrow">ROUND ${state.round} RESULT</span><h1>🎉 라운드 결과 공개!</h1><p>설명자가 선정한 순위와 작성자가 공개됐습니다.</p></div><div class="panel"><h3>원본 사진</h3><div class="original-box" id="secure-photo">사진 불러오는 중...</div></div><div class="gallery" style="margin-top:18px">${cards()}</div><div class="panel" style="margin-top:20px"><h3>누적 점수</h3>${scoreboard()}${state.host?btn(state.round>=state.rounds?'최종 결과 발표 →':'다음 라운드 →','btn-primary btn-wide','id="next-round" style="margin-top:18px"'):'<p class="tip">방장이 다음 라운드를 시작합니다.</p>'}</div></div>`}
function bindResult(){securePhoto();if(state.matchType==='team'){$$('.art-card canvas').forEach(c=>{const art=state.cards.find(a=>'art-'+a.id===c.id);if(art)drawTo(c.getContext('2d'),art.strokes||[],450,300)})}else paintCards();$('#next-round')?.addEventListener('click',()=>{localRanks=[];act('next')})}
function final(){if(state?.matchType==='team')return teamFinal();return `<div class="container"><section class="hero"><div class="eyebrow">GAME COMPLETE</div><h1>🏆 최종 순위</h1><p class="subtitle">총 ${state.rounds}라운드 종료!</p></section><div class="panel center-panel" style="max-width:750px">${scoreboard()}${state.host?btn('같은 멤버로 다시 시작','btn-primary btn-wide','id="restart" style="margin-top:20px"'):''}</div></div>`}
function bindFinal(){$('#restart')?.addEventListener('click',()=>act('restart'))}
$('#admin-open').onclick=()=>location.href='/admin.html';
$('#leave-global').onclick=leaveGame;
$('#recover-global').onclick=recoverRound;
$('#home-link').onclick=()=>{if(state){show(phaseMap[state.phase]);toast('현재 참가 중인 방으로 이동했습니다')}else show('home')};
show(new URLSearchParams(location.search).has('room')?'join':'home');
if(!configured){$('#status').textContent='설정 필요';toast('config.js에 Supabase 설정이 필요합니다')}
else {$('#status').textContent='연결 준비됨';if(roomCode)sync()}
setInterval(sync,1400);
// Background browser tabs throttle timers; refresh immediately on return.
document.addEventListener('visibilitychange',()=>{if(!document.hidden&&roomCode)sync()});
window.addEventListener('focus',()=>{if(roomCode)sync()});
window.addEventListener('online',()=>{if(roomCode)sync()});
setInterval(loadNarratorGallery,2800);
document.addEventListener('keydown',e=>{if(e.ctrlKey&&e.shiftKey&&e.code==='KeyE'&&roomCode){e.preventDefault();leaveGame()}});setInterval(()=>{updateClock();checkCutoff()},250);
setInterval(()=>{if(state?.phase==='draw'&&!state.isNarrator&&!submittedLocally&&dirty&&remaining()>0&&Date.now()-lastSaved>3000)saveDrawing()},3200);
