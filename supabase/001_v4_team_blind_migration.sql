-- Draw & Describe v4.0 / Step 1 — additive schema + secured voting RPCs
-- Prerequisite: v3 schema.sql has been installed. Run ONCE in Supabase SQL Editor.
-- Does not change existing v3 game RPCs or activate team mode in the UI.
begin;

alter table public.dd_rooms
 add column if not exists match_type text not null default 'solo',
 add column if not exists photo_mode text not null default 'random',
 add column if not exists allowed_categories text[] not null default array['real_person','animal','soop','anime_character']::text[],
 add column if not exists team_red_name text not null default '레드팀',
 add column if not exists team_blue_name text not null default '블루팀',
 add column if not exists red_narrator_id uuid,
 add column if not exists blue_narrator_id uuid,
 add column if not exists judge_deadline timestamptz;

alter table public.dd_players
 add column if not exists team_code text;

alter table public.dd_photos
 add column if not exists category text not null default 'real_person',
 add column if not exists description text,
 add column if not exists tags text[] not null default '{}'::text[],
 add column if not exists is_active boolean not null default true;

-- Older photos are assigned a placeholder category; admins should review them.
alter table public.dd_rooms
 add constraint dd_v4_match_type_check check(match_type in ('solo','team')),
 add constraint dd_v4_photo_mode_check check(photo_mode in ('random','select')),
 add constraint dd_v4_allowed_categories_check check (
   cardinality(allowed_categories) between 1 and 4
   and allowed_categories <@ array['real_person','animal','soop','anime_character']::text[]
   and array_position(allowed_categories,null) is null
 );


alter table public.dd_players
 add constraint dd_v4_team_code_check check (team_code in ('red','blue'));
alter table public.dd_photos
 add constraint dd_v4_category_check check (category in ('real_person','animal','soop','anime_character'));
-- Include future team phases, but leave v3's existing phase transitions unchanged.
alter table public.dd_rooms drop constraint if exists dd_rooms_phase_check;
alter table public.dd_rooms add constraint dd_rooms_phase_check
 check(phase in ('lobby','photo_select','draw','judge','vote','result','final'));

create index if not exists dd_v4_photos_filter on public.dd_photos(is_active,category);
create index if not exists dd_v4_players_team on public.dd_players(room_id,team_code);

-- Keep one immutable snapshot per drawing per round. Do not rely on dd_players.strokes
-- after advancing rounds because v3 resets that column.
create table if not exists public.dd_round_drawings (
 id uuid primary key default gen_random_uuid(),
 room_id uuid not null references public.dd_rooms(id) on delete cascade,
 round_no int not null check(round_no between 1 and 10),
 artist_id uuid not null references auth.users(id),
 team_code text not null check(team_code in ('red','blue')),
 strokes jsonb not null check(jsonb_typeof(strokes)='array'),
 created_at timestamptz not null default now(),
 unique(room_id,round_no,artist_id),
 unique(id,room_id,round_no)
);
create index if not exists dd_v4_drawings_round on public.dd_round_drawings(room_id,round_no);

-- Record the actual assigned ballot. Without assignments a voter could strategically
-- choose which artworks to judge.
create table if not exists public.dd_vote_assignments (
 room_id uuid not null,
 round_no int not null,
 drawing_id uuid not null,
 voter_id uuid not null references auth.users(id),
 created_at timestamptz not null default now(),
 primary key(drawing_id,voter_id),
 foreign key(drawing_id,room_id,round_no)
  references public.dd_round_drawings(id,room_id,round_no) on delete cascade,
 foreign key(room_id,voter_id)
  references public.dd_players(room_id,user_id) on delete cascade
);
create index if not exists dd_v4_assignments_voter on public.dd_vote_assignments(room_id,round_no,voter_id);

create table if not exists public.dd_votes (
 drawing_id uuid not null,
 voter_id uuid not null,
 room_id uuid not null,
 round_no int not null,
 voter_team_code text not null check(voter_team_code in ('red','blue')),
 shape_score int not null check(shape_score between 0 and 40),
 position_score int not null check(position_score between 0 and 30),
 color_score int not null check(color_score between 0 and 20),
 detail_score int not null check(detail_score between 0 and 10),
 created_at timestamptz not null default now(),
 primary key(drawing_id,voter_id),
 foreign key(drawing_id,voter_id)
  references public.dd_vote_assignments(drawing_id,voter_id) on delete cascade,
 foreign key(drawing_id,room_id,round_no)
  references public.dd_round_drawings(id,room_id,round_no) on delete cascade
);
create index if not exists dd_v4_votes_round on public.dd_votes(room_id,round_no,drawing_id);

-- New tables are inaccessible directly to client roles. RPCs selectively return data.
alter table public.dd_round_drawings enable row level security;
alter table public.dd_vote_assignments enable row level security;
alter table public.dd_votes enable row level security;
revoke all on public.dd_round_drawings,public.dd_vote_assignments,public.dd_votes
 from public,anon,authenticated;

-- Server-controlled vote submission. Requires a valid assigned ballot and vote phase.
create or replace function public.dd_v4_submit_vote(
 p_code text,p_drawing_id uuid,p_shape int,p_position int,p_color int,p_detail int
) returns boolean
language plpgsql security definer set search_path = '' as $$
declare r public.dd_rooms%rowtype; d public.dd_round_drawings%rowtype; v_team text;
begin
 if auth.uid() is null then raise exception '로그인이 필요합니다'; end if;
 select * into r from public.dd_rooms where code=p_code for update;
 if not found or r.match_type<>'team' or r.phase<>'vote' then
   raise exception '현재 팀전 평가를 제출할 수 없습니다';
 end if;
 if r.judge_deadline is not null and clock_timestamp()>=r.judge_deadline then
   raise exception '심사 시간이 종료됐습니다';
 end if;
 select team_code into v_team from public.dd_players
   where room_id=r.id and user_id=auth.uid();
 if not found or v_team is null then raise exception '이 방 심사자가 아닙니다'; end if;
 select * into d from public.dd_round_drawings
   where id=p_drawing_id and room_id=r.id and round_no=r.round_no;
 if not found or d.artist_id=auth.uid() then raise exception '자신의 그림이거나 심사 대상이 아닙니다'; end if;
 if not exists(select 1 from public.dd_vote_assignments
   where drawing_id=d.id and voter_id=auth.uid() and room_id=r.id and round_no=r.round_no)
 then raise exception '배정되지 않은 평가입니다'; end if;
 if p_shape not between 0 and 40 or p_position not between 0 and 30
   or p_color not between 0 and 20 or p_detail not between 0 and 10
 then raise exception '평가 점수 범위를 확인하세요'; end if;
 insert into public.dd_votes(
  drawing_id,voter_id,room_id,round_no,voter_team_code,
  shape_score,position_score,color_score,detail_score
 ) values(d.id,auth.uid(),r.id,r.round_no,v_team,p_shape,p_position,p_color,p_detail);
 -- Unique key blocks resubmissions: existing votes cannot be changed.
 update public.dd_rooms set revision=revision+1 where id=r.id;
 return true;
end $$;
revoke all on function public.dd_v4_submit_vote(text,uuid,int,int,int,int) from public,anon;
grant execute on function public.dd_v4_submit_vote(text,uuid,int,int,int,int) to authenticated;

-- Client sees only assigned anonymous artworks during team voting.
-- No author id, author name, or team id is returned.
create or replace function public.dd_v4_my_ballot(p_code text) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare r public.dd_rooms%rowtype; v_items jsonb;
begin
 if auth.uid() is null then raise exception '로그인이 필요합니다'; end if;
 select * into r from public.dd_rooms where code=p_code;
 if not found or r.match_type<>'team' or r.phase<>'vote' then
   raise exception '심사 화면을 볼 수 없습니다'; end if;
 if not exists(select 1 from public.dd_players
  where room_id=r.id and user_id=auth.uid()) then
   raise exception '이 방 참가자가 아닙니다'; end if;
 select coalesce(jsonb_agg(jsonb_build_object(
  'drawingId',d.id,'strokes',d.strokes,
  'submitted',v.drawing_id is not null
 ) order by md5(d.id::text || auth.uid()::text)),'[]'::jsonb)
 into v_items
 from public.dd_vote_assignments a
 join public.dd_round_drawings d on d.id=a.drawing_id
 left join public.dd_votes v on v.drawing_id=a.drawing_id and v.voter_id=a.voter_id
 where a.room_id=r.id and a.round_no=r.round_no and a.voter_id=auth.uid();
 return jsonb_build_object('round',r.round_no,'deadline',r.judge_deadline,
   'items',v_items);
end $$;
revoke all on function public.dd_v4_my_ballot(text) from public,anon;
grant execute on function public.dd_v4_my_ballot(text) to authenticated;

-- IMPORTANT: no public RPC for creating drawings, assigning ballots, changing phase,
-- or finalizing scoring in step 1. These are implemented together with the authoritative
-- team game flow in step 2/3; granting client writes here would be unsafe.
-- Both teams must contribute valid votes before a drawing can receive its balanced score.
create or replace view public.dd_v4_drawing_scores
with (security_invoker=true) as
with by_team as (
 select drawing_id,voter_team_code,
  avg((shape_score+position_score+color_score+detail_score)::numeric) as team_avg,
  count(*) as num_votes
 from public.dd_votes group by drawing_id,voter_team_code
)
select d.id as drawing_id,d.room_id,d.round_no,d.artist_id,d.team_code,
 case when coalesce(red.num_votes,0)>0 and coalesce(blue.num_votes,0)>0
  then round((red.team_avg+blue.team_avg)/2,2) else null end as score,
 coalesce(red.num_votes,0) as red_votes,
 coalesce(blue.num_votes,0) as blue_votes
from public.dd_round_drawings d
left join by_team red on red.drawing_id=d.id and red.voter_team_code='red'
left join by_team blue on blue.drawing_id=d.id and blue.voter_team_code='blue';
revoke all on public.dd_v4_drawing_scores from public,anon,authenticated;

-- Introspection/check helper for project owner, run manually in SQL Editor after install.
commit;
