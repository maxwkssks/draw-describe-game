-- v4 / Step 2: Lobby modes, category preferences, balanced team assignment.
-- Prerequisite: schema.sql and 001_v4_team_blind_migration.sql installed.
-- Idempotent CREATE OR REPLACE only; existing rooms and art are preserved.
begin;

-- v3 round start stays available ONLY for legacy solo/random rooms until
-- subsequent v4 phase handlers are installed. Do not activate incomplete modes.
create or replace function public.dd_v4_lobby_guard() returns trigger
language plpgsql set search_path = '' as $$
begin
 if old.phase = 'lobby' and new.phase <> 'lobby'
    and (old.match_type <> 'solo' or old.photo_mode <> 'random') then
   raise exception '이 모드의 라운드 진행은 아직 구현 중입니다';
 end if;
 return new;
end $$;
drop trigger if exists dd_v4_lobby_guard_trg on public.dd_rooms;
create trigger dd_v4_lobby_guard_trg before update on public.dd_rooms
for each row execute function public.dd_v4_lobby_guard();

-- New arrivals are assigned to the smaller team unless host changes it.
create or replace function public.dd_v4_auto_team_on_join() returns trigger
language plpgsql set search_path = '' as $$
declare v_match text; v_red integer; v_blue integer;
begin
 select match_type into v_match from public.dd_rooms where id=new.room_id;
 if v_match='team' and new.team_code is null then
   select count(*) filter (where team_code='red'), count(*) filter (where team_code='blue')
   into v_red,v_blue from public.dd_players where room_id=new.room_id;
   new.team_code := case when v_red<=v_blue then 'red' else 'blue' end;
 end if;
 return new;
end $$;
drop trigger if exists dd_v4_auto_team_join_trg on public.dd_players;
create trigger dd_v4_auto_team_join_trg before insert on public.dd_players
for each row execute function public.dd_v4_auto_team_on_join();

create or replace function public.dd_v4_create_room(
 p_name text,p_max_players int,p_rounds int,p_duration int,
 p_match_type text,p_photo_mode text,p_categories text[]
) returns text
language plpgsql security definer set search_path = '' as $$
declare v_code text; v_room uuid; v_i int;
begin
 if auth.uid() is null then raise exception '로그인이 필요합니다'; end if;
 if char_length(btrim(coalesce(p_name,''))) not between 1 and 16
   then raise exception '닉네임은 1~16자로 입력하세요'; end if;
 if p_max_players not between 2 and 20 or p_rounds not between 1 and 10 or p_duration not in (120,180,300)
   then raise exception '방 설정이 올바르지 않습니다'; end if;
 if p_match_type not in ('solo','team') or p_photo_mode not in ('random','select')
   then raise exception '모드가 올바르지 않습니다'; end if;
 if p_match_type='team' and p_max_players<4 then raise exception '팀전 정원은 최소 4명입니다'; end if;
 if p_categories is null or cardinality(p_categories) not between 1 and 4
    or not(p_categories <@ array['real_person','animal','soop','anime_character']::text[])
    or array_position(p_categories,null) is not null
    or (select count(distinct x) from unnest(p_categories) x)<>cardinality(p_categories)
   then raise exception '카테고리를 올바르게 선택하세요'; end if;
 for v_i in 1..12 loop
   v_code:=lpad((floor(random()*1000000))::int::text,6,'0');
   begin
     insert into public.dd_rooms(code,host_id,max_players,total_rounds,duration_seconds,
       match_type,photo_mode,allowed_categories)
     values(v_code,auth.uid(),p_max_players,p_rounds,p_duration,
       p_match_type,p_photo_mode,p_categories) returning id into v_room;
     exit;
   exception when unique_violation then null;
   end;
 end loop;
 if v_room is null then raise exception '방 코드 생성에 실패했습니다'; end if;
 insert into public.dd_players(room_id,user_id,name,ready,team_code)
 values(v_room,auth.uid(),btrim(p_name),true,
    case when p_match_type='team' then 'red' else null end);
 return v_code;
end $$;
revoke all on function public.dd_v4_create_room(text,int,int,int,text,text,text[]) from public,anon;
grant execute on function public.dd_v4_create_room(text,int,int,int,text,text,text[]) to authenticated;

-- Respect category filters in the existing v3 solo/random round engine.
create or replace function public.dd_begin_round(p_room uuid,p_round int) returns void
language plpgsql security definer set search_path='' as $$
declare v_narrator uuid; v_photo uuid; v_used uuid[]; v_duration int; v_n int; v_categories text[];
begin
 select used_photo_ids,duration_seconds,allowed_categories into v_used,v_duration,v_categories from public.dd_rooms where id=p_room;
 select count(*) into v_n from public.dd_players where room_id=p_room;
 select user_id into v_narrator from public.dd_players where room_id=p_room order by joined_at,user_id offset ((p_round-1)%v_n) limit 1;
 select id into v_photo from public.dd_photos where is_active and category=any(v_categories) and not(id=any(v_used)) order by random() limit 1;
 if v_photo is null then select id into v_photo from public.dd_photos where is_active and category=any(v_categories) order by random() limit 1; end if;
 if v_photo is null then raise exception '선택한 카테고리에 등록된 사진이 없습니다'; end if;
 update public.dd_players set strokes='[]'::jsonb,submitted=false,placement=null where room_id=p_room;
 update public.dd_rooms set phase='draw',round_no=p_round,narrator_id=v_narrator,photo_id=v_photo,
 used_photo_ids=array_append(v_used,v_photo),deadline=clock_timestamp()+make_interval(secs=>v_duration),revision=revision+1 where id=p_room;
end $$;
revoke all on function public.dd_begin_round(uuid,int) from public,anon,authenticated;

-- A player may fetch lobby metadata only after joining. No picture paths are exposed.
create or replace function public.dd_v4_lobby(p_code text) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare r public.dd_rooms%rowtype; p jsonb; photo_total int;
begin
 if auth.uid() is null then raise exception '로그인이 필요합니다'; end if;
 select * into r from public.dd_rooms where code=p_code;
 if not found then raise exception '방이 없습니다'; end if;
 if not exists(select 1 from public.dd_players where room_id=r.id and user_id=auth.uid())
    then raise exception '이 방 참가자가 아닙니다'; end if;
 select coalesce(jsonb_agg(jsonb_build_object('id',user_id,'team',team_code)
   order by joined_at,user_id),'[]'::jsonb) into p
 from public.dd_players where room_id=r.id;
 select count(*) into photo_total from public.dd_photos
 where is_active and category=any(r.allowed_categories);
 return jsonb_build_object('matchType',r.match_type,'photoMode',r.photo_mode,
   'categories',to_jsonb(r.allowed_categories),'teams',p,'redName',r.team_red_name,
   'blueName',r.team_blue_name,'eligiblePhotoCount',photo_total);
end $$;
revoke all on function public.dd_v4_lobby(text) from public,anon;
grant execute on function public.dd_v4_lobby(text) to authenticated;

-- Host-only team organizer. No scoring or narrator privileges can be set here.
create or replace function public.dd_v4_assign_teams(p_code text,p_mode text,
 p_player_id uuid default null,p_team text default null) returns boolean
language plpgsql security definer set search_path = '' as $$
declare r public.dd_rooms%rowtype; members int;
begin
 if auth.uid() is null then raise exception '로그인이 필요합니다'; end if;
 select * into r from public.dd_rooms where code=p_code for update;
 if not found or r.host_id<>auth.uid() or r.phase<>'lobby' or r.match_type<>'team'
  then raise exception '팀전 대기실의 방장만 팀을 배정할 수 있습니다'; end if;
 if p_mode='auto' then
   with shuf as (
      select user_id,row_number() over (order by random(),user_id) as rn
      from public.dd_players where room_id=r.id
   )
   update public.dd_players p set team_code=case when shuf.rn%2=1 then 'red' else 'blue' end
   from shuf where p.room_id=r.id and p.user_id=shuf.user_id;
 elsif p_mode='manual' then
   if p_team not in ('red','blue') or p_player_id is null then raise exception '팀 설정값을 확인하세요'; end if;
   update public.dd_players set team_code=p_team
   where room_id=r.id and user_id=p_player_id;
   if not found then raise exception '방 참가자가 아닙니다'; end if;
 else raise exception '허용되지 않은 팀 배정 동작입니다'; end if;
 update public.dd_rooms set revision=revision+1 where id=r.id;
 return true;
end $$;
revoke all on function public.dd_v4_assign_teams(text,text,uuid,text) from public,anon;
grant execute on function public.dd_v4_assign_teams(text,text,uuid,text) to authenticated;
commit;
