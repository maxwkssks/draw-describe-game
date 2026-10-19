-- Draw & Describe online edition; run once in Supabase SQL Editor.
create extension if not exists pgcrypto;

create table if not exists public.dd_admins (
  user_id uuid primary key references auth.users(id) on delete cascade
);
create table if not exists public.dd_photos (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 1 and 120),
  storage_path text not null unique,
  created_at timestamptz not null default now()
);
create table if not exists public.dd_rooms (
  id uuid primary key default gen_random_uuid(),
  code text not null unique check (code ~ '^[0-9]{6}$'),
  host_id uuid not null references auth.users(id),
  max_players integer not null check (max_players between 2 and 20),
  total_rounds integer not null check (total_rounds between 1 and 10),
  duration_seconds integer not null check (duration_seconds in (120,180,300)),
  phase text not null default 'lobby' check (phase in ('lobby','draw','judge','result','final')),
  round_no integer not null default 0,
  narrator_id uuid,
  photo_id uuid references public.dd_photos(id) on delete set null,
  used_photo_ids uuid[] not null default '{}',
  deadline timestamptz,
  revision integer not null default 0,
  created_at timestamptz not null default now()
);
create table if not exists public.dd_players (
  room_id uuid not null references public.dd_rooms(id) on delete cascade,
  user_id uuid not null references auth.users(id),
  name text not null check (char_length(name) between 1 and 16),
  ready boolean not null default false,
  joined_at timestamptz not null default now(),
  score integer not null default 0,
  strokes jsonb not null default '[]'::jsonb,
  submitted boolean not null default false,
  placement integer,
  primary key (room_id, user_id)
);
create index if not exists dd_players_room_join on public.dd_players(room_id,joined_at,user_id);

alter table public.dd_admins enable row level security;
alter table public.dd_photos enable row level security;
alter table public.dd_rooms enable row level security;
alter table public.dd_players enable row level security;
-- No direct room/player policies. All reads/writes use authenticated SECURITY DEFINER RPCs.
revoke all on public.dd_rooms, public.dd_players, public.dd_admins from anon, authenticated;
revoke all on public.dd_photos from anon, authenticated;
grant select, insert, delete on public.dd_photos to authenticated;

create or replace function public.dd_is_admin() returns boolean
language sql stable security definer set search_path = '' as $$
 select exists(select 1 from public.dd_admins where user_id = auth.uid())
$$;
revoke all on function public.dd_is_admin() from public, anon;
grant execute on function public.dd_is_admin() to authenticated;

create policy dd_photo_admin_select on public.dd_photos for select to authenticated using (public.dd_is_admin());
create policy dd_photo_admin_insert on public.dd_photos for insert to authenticated with check (public.dd_is_admin() and storage_path like 'uploads/%');
create policy dd_photo_admin_delete on public.dd_photos for delete to authenticated using (public.dd_is_admin());

-- Private bucket: only admins or authorized participants in current room phase can request signed links.
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('dd-originals','dd-originals',false,5242880,array['image/jpeg','image/png','image/webp'])
on conflict(id) do update set public=false,file_size_limit=5242880,allowed_mime_types=array['image/jpeg','image/png','image/webp'];

create or replace function public.dd_can_read_photo(p_path text) returns boolean
language sql stable security definer set search_path = '' as $$
 select public.dd_is_admin() or exists(
   select 1 from public.dd_photos f
   join public.dd_rooms r on r.photo_id = f.id
   join public.dd_players p on p.room_id = r.id
   where f.storage_path = p_path and p.user_id = auth.uid()
     and ((r.phase in ('draw','judge') and r.narrator_id = auth.uid())
          or r.phase in ('result','final'))
 )
$$;
revoke all on function public.dd_can_read_photo(text) from public, anon;
grant execute on function public.dd_can_read_photo(text) to authenticated;
create policy dd_storage_read on storage.objects for select to authenticated
 using (bucket_id='dd-originals' and public.dd_can_read_photo(name));
create policy dd_storage_upload on storage.objects for insert to authenticated
 with check (bucket_id='dd-originals' and public.dd_is_admin() and name like 'uploads/%');
create policy dd_storage_delete on storage.objects for delete to authenticated
 using (bucket_id='dd-originals' and public.dd_is_admin());

create or replace function public.dd_create_room(p_name text,p_max_players int,p_rounds int,p_duration int)
returns text language plpgsql security definer set search_path='' as $$
declare v_code text; v_room uuid; v_i int;
begin
 if auth.uid() is null then raise exception '로그인이 필요합니다'; end if;
 if char_length(btrim(coalesce(p_name,''))) not between 1 and 16 then raise exception '닉네임은 1~16자로 입력하세요'; end if;
 if p_max_players not between 2 and 20 or p_rounds not between 1 and 10 or p_duration not in (120,180,300) then raise exception '방 설정이 올바르지 않습니다'; end if;
 for v_i in 1..12 loop
   v_code:=lpad((floor(random()*1000000))::int::text,6,'0');
   begin
     insert into public.dd_rooms(code,host_id,max_players,total_rounds,duration_seconds)
     values(v_code,auth.uid(),p_max_players,p_rounds,p_duration) returning id into v_room;
     exit;
   exception when unique_violation then null;
   end;
 end loop;
 if v_room is null then raise exception '방 코드 생성에 실패했습니다. 재시도하세요'; end if;
 insert into public.dd_players(room_id,user_id,name,ready) values(v_room,auth.uid(),btrim(p_name),true);
 return v_code;
end $$;

create or replace function public.dd_join_room(p_code text,p_name text)
returns text language plpgsql security definer set search_path='' as $$
declare v_room public.dd_rooms%rowtype; v_count int;
begin
 if auth.uid() is null then raise exception '로그인이 필요합니다'; end if;
 if char_length(btrim(coalesce(p_name,''))) not between 1 and 16 then raise exception '닉네임은 1~16자로 입력하세요'; end if;
 select * into v_room from public.dd_rooms where code = p_code for update;
 if not found then raise exception '존재하지 않는 방 코드입니다'; end if;
 if exists(select 1 from public.dd_players where room_id=v_room.id and user_id=auth.uid()) then return v_room.code; end if;
 if v_room.phase <> 'lobby' then raise exception '게임 진행 중에는 새로 참가할 수 없습니다'; end if;
 select count(*) into v_count from public.dd_players where room_id=v_room.id;
 if v_count>=v_room.max_players then raise exception '방의 정원이 가득 찼습니다'; end if;
 insert into public.dd_players(room_id,user_id,name) values(v_room.id,auth.uid(),btrim(p_name));
 update public.dd_rooms set revision=revision+1 where id=v_room.id;
 return v_room.code;
end $$;

-- Internal function: caller must hold lock on the room row.
create or replace function public.dd_begin_round(p_room uuid,p_round int) returns void
language plpgsql security definer set search_path='' as $$
declare v_narrator uuid; v_photo uuid; v_used uuid[]; v_duration int; v_n int;
begin
 select used_photo_ids,duration_seconds into v_used,v_duration from public.dd_rooms where id=p_room;
 select count(*) into v_n from public.dd_players where room_id=p_room;
 select user_id into v_narrator from public.dd_players where room_id=p_room order by joined_at,user_id offset ((p_round-1)%v_n) limit 1;
 select id into v_photo from public.dd_photos where not(id=any(v_used)) order by random() limit 1;
 if v_photo is null then select id into v_photo from public.dd_photos order by random() limit 1; end if;
 if v_photo is null then raise exception '관리자가 등록한 사진이 없습니다'; end if;
 update public.dd_players set strokes='[]'::jsonb,submitted=false,placement=null where room_id=p_room;
 update public.dd_rooms set phase='draw',round_no=p_round,narrator_id=v_narrator,photo_id=v_photo,
 used_photo_ids=array_append(v_used,v_photo),deadline=clock_timestamp()+make_interval(secs=>v_duration),revision=revision+1 where id=p_room;
end $$;
revoke all on function public.dd_begin_round(uuid,int) from public,anon,authenticated;

create or replace function public.dd_state(p_code text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare v_room public.dd_rooms%rowtype; v_me public.dd_players%rowtype; v_players jsonb; v_cards jsonb:='[]'::jsonb; v_photo_path text; v_narrator_name text; v_need int; v_photo_count int;
begin
 if auth.uid() is null then raise exception '로그인이 필요합니다'; end if;
 select * into v_room from public.dd_rooms where code=p_code for update;
 if not found then raise exception '방을 찾을 수 없습니다'; end if;
 select * into v_me from public.dd_players where room_id=v_room.id and user_id=auth.uid();
 if not found then raise exception '이 방의 참가자가 아닙니다'; end if;
 if v_room.phase='draw' and v_room.deadline<=clock_timestamp() then
  update public.dd_rooms set phase='judge',revision=revision+1 where id=v_room.id;
  v_room.phase:='judge';v_room.revision:=v_room.revision+1;
 end if;
 select count(*) into v_photo_count from public.dd_photos;
 select name into v_narrator_name from public.dd_players where room_id=v_room.id and user_id=v_room.narrator_id;
 select greatest(0,least(3,count(*)::int-1)) into v_need from public.dd_players where room_id=v_room.id;
 select coalesce(jsonb_agg(jsonb_build_object('id',user_id::text,'name',name,'ready',ready,
  'host',user_id=v_room.host_id,'online',true,'submitted',submitted,'score',score)
  order by joined_at,user_id),'[]'::jsonb) into v_players from public.dd_players where room_id=v_room.id;
 if (v_room.phase='judge' and v_room.narrator_id=auth.uid()) or v_room.phase='result' then
  select coalesce(jsonb_agg(jsonb_build_object('id',user_id::text,'name',case when v_room.phase='result' then name else null end,
   'label','그림 #'|| rownum,'strokes',strokes,'rank',placement) order by rownum),'[]'::jsonb)
  into v_cards from (select user_id,name,strokes,placement,row_number() over(order by joined_at,user_id) as rownum
    from public.dd_players where room_id=v_room.id and user_id<>v_room.narrator_id) q;
 end if;
 if v_room.photo_id is not null and ((v_room.phase in ('draw','judge') and v_room.narrator_id=auth.uid()) or v_room.phase='result') then
  select storage_path into v_photo_path from public.dd_photos where id=v_room.photo_id;
 end if;
 return jsonb_build_object(
  'code',v_room.code,'me',auth.uid()::text,'host',v_room.host_id=auth.uid(),
  'phase',v_room.phase,'round',v_room.round_no,'rounds',v_room.total_rounds,'revision',v_room.revision,
  'maxPlayers',v_room.max_players,'duration',v_room.duration_seconds,
  'deadline',case when v_room.deadline is null then null else (extract(epoch from v_room.deadline)*1000)::bigint end,
  'players',v_players,'narrator',v_room.narrator_id::text,'narratorName',v_narrator_name,
  'isNarrator',v_room.narrator_id=auth.uid(),'need',v_need,'photoCount',v_photo_count,
  'photoPath',v_photo_path,'cards',v_cards,
  'myStrokes',case when v_room.phase='draw' and v_room.narrator_id<>auth.uid() then v_me.strokes else '[]'::jsonb end
 );
end $$;

create or replace function public.dd_action(p_code text,p_action text,p_data jsonb default '{}'::jsonb)
returns boolean language plpgsql security definer set search_path='' as $$
declare v_room public.dd_rooms%rowtype;v_me public.dd_players%rowtype;v_count int;v_ready int;v_need int;v_ranks jsonb;v_rank_id uuid;v_i int;v_ids uuid[]:='{}';v_score int;
begin
 if auth.uid() is null then raise exception '로그인이 필요합니다'; end if;
 select * into v_room from public.dd_rooms where code=p_code for update;
 if not found then raise exception '방이 없습니다'; end if;
 select * into v_me from public.dd_players where room_id=v_room.id and user_id=auth.uid();
 if not found then raise exception '참가 권한이 없습니다'; end if;
 if v_room.phase='draw' and v_room.deadline<=clock_timestamp() then
   update public.dd_rooms set phase='judge',revision=revision+1 where id=v_room.id;
   v_room.phase:='judge';
 end if;
 if p_action='ready' then
  if v_room.phase<>'lobby' or v_room.host_id=auth.uid() then raise exception '준비 상태를 변경할 수 없습니다'; end if;
  update public.dd_players set ready=coalesce((p_data->>'value')::boolean,false) where room_id=v_room.id and user_id=auth.uid();
  update public.dd_rooms set revision=revision+1 where id=v_room.id;
 elsif p_action='start' then
  if v_room.host_id<>auth.uid() or v_room.phase<>'lobby' then raise exception '방장만 대기실에서 시작할 수 있습니다'; end if;
  select count(*),count(*) filter(where ready) into v_count,v_ready from public.dd_players where room_id=v_room.id;
  if v_count<2 or v_count<>v_ready then raise exception '최소 2명과 전원 준비가 필요합니다'; end if;
  perform public.dd_begin_round(v_room.id,1);
 elsif p_action='drawing' then
  if v_room.phase<>'draw' or v_room.narrator_id=auth.uid() or v_me.submitted then raise exception '그림을 저장할 수 없습니다'; end if;
  if jsonb_typeof(p_data->'strokes')<>'array' or length((p_data->'strokes')::text)>150000 then raise exception '그림 데이터가 유효하지 않거나 너무 큽니다'; end if;
  update public.dd_players set strokes=p_data->'strokes',submitted=coalesce((p_data->>'submitted')::boolean,false)
   where room_id=v_room.id and user_id=auth.uid();
 elsif p_action='end' then
  if v_room.host_id<>auth.uid() or v_room.phase<>'draw' then raise exception '방장만 조기 마감할 수 있습니다'; end if;
  update public.dd_rooms set phase='judge',revision=revision+1 where id=v_room.id;
 elsif p_action='judge' then
  if v_room.narrator_id<>auth.uid() or v_room.phase<>'judge' then raise exception '설명자만 심사할 수 있습니다'; end if;
  select least(3,count(*)::int-1) into v_need from public.dd_players where room_id=v_room.id;
  v_ranks:=p_data->'ranks';
  if jsonb_typeof(v_ranks)<>'array' or jsonb_array_length(v_ranks)<>v_need then raise exception '필요한 순위를 모두 정해주세요'; end if;
  for v_i in 0..v_need-1 loop
   begin v_rank_id:=(v_ranks->>v_i)::uuid;
   exception when others then raise exception '심사 대상이 올바르지 않습니다'; end;
   if v_rank_id=any(v_ids) or v_rank_id=v_room.narrator_id or not exists(select 1 from public.dd_players where room_id=v_room.id and user_id=v_rank_id) then
     raise exception '중복된 순위이거나 다른 방 참가자입니다';
   end if;
   v_ids:=array_append(v_ids,v_rank_id);
   v_score:=case v_i when 0 then 100 when 1 then 70 else 50 end;
   update public.dd_players set placement=v_i+1,score=score+v_score where room_id=v_room.id and user_id=v_rank_id;
  end loop;
  update public.dd_rooms set phase='result',revision=revision+1 where id=v_room.id;
 elsif p_action='next' then
  if v_room.host_id<>auth.uid() or v_room.phase<>'result' then raise exception '방장만 다음 라운드를 진행할 수 있습니다'; end if;
  if v_room.round_no>=v_room.total_rounds then
   update public.dd_rooms set phase='final',revision=revision+1 where id=v_room.id;
  else
   perform public.dd_begin_round(v_room.id,v_room.round_no+1);
  end if;
 elsif p_action='restart' then
  if v_room.host_id<>auth.uid() or v_room.phase<>'final' then raise exception '방장만 다시 시작할 수 있습니다'; end if;
  update public.dd_players set score=0,placement=null,strokes='[]'::jsonb,submitted=false,ready=(user_id=v_room.host_id) where room_id=v_room.id;
  update public.dd_rooms set phase='lobby',round_no=0,narrator_id=null,photo_id=null,deadline=null,used_photo_ids='{}',revision=revision+1 where id=v_room.id;
 elsif p_action='leave' then
  if v_room.phase<>'lobby' and v_room.phase<>'final' then raise exception '진행 중인 게임에서는 새로고침 후 복귀할 수 있습니다'; end if;
  delete from public.dd_players where room_id=v_room.id and user_id=auth.uid();
  select count(*) into v_count from public.dd_players where room_id=v_room.id;
  if v_count=0 then delete from public.dd_rooms where id=v_room.id;
  elsif v_room.host_id=auth.uid() then
   update public.dd_rooms set host_id=(select user_id from public.dd_players where room_id=v_room.id order by joined_at,user_id limit 1),revision=revision+1 where id=v_room.id;
  else update public.dd_rooms set revision=revision+1 where id=v_room.id;
  end if;
 else raise exception '허용되지 않은 동작입니다';
 end if;
 return true;
end $$;

-- Internal helper is executable only by its parent SECURITY DEFINER function.
revoke all on function public.dd_create_room(text,int,int,int) from public,anon;
revoke all on function public.dd_join_room(text,text) from public,anon;
revoke all on function public.dd_state(text) from public,anon;
revoke all on function public.dd_action(text,text,jsonb) from public,anon;
grant execute on function public.dd_create_room(text,int,int,int),public.dd_join_room(text,text),public.dd_state(text),public.dd_action(text,text,jsonb) to authenticated;
