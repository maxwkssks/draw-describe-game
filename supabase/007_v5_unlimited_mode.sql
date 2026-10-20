-- 그려봐! v5: UNLIMITED DRAW MODE. Execute AFTER 005 (and AFTER 006 if installed).
-- Existing rooms, photos, results, artwork, admin credentials are preserved.
-- Unlimited: duration_seconds=0, per-round completion_target, server-atomic transitions.
BEGIN;
ALTER TABLE public.dd_rooms ADD COLUMN IF NOT EXISTS completion_target integer;
ALTER TABLE public.dd_players ADD COLUMN IF NOT EXISTS v5_submitted_at timestamptz;
-- v3 named constraint; replace with a constraint accepting 0 as the no-clock sentinel.
ALTER TABLE public.dd_rooms DROP CONSTRAINT IF EXISTS dd_rooms_duration_seconds_check;
DO $$ BEGIN
 IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='public.dd_rooms'::regclass AND conname='dd_v5_duration_check') THEN
  ALTER TABLE public.dd_rooms ADD CONSTRAINT dd_v5_duration_check CHECK(duration_seconds IN (0,120,180,300));
 END IF;
 IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='public.dd_rooms'::regclass AND conname='dd_v5_target_check') THEN
  ALTER TABLE public.dd_rooms ADD CONSTRAINT dd_v5_target_check CHECK (completion_target IS NULL OR completion_target BETWEEN 1 AND 19);
 END IF;
END $$;

-- v5 creator wraps tested v4 create-room logic; room does not become visible before commit.
CREATE OR REPLACE FUNCTION public.dd_v5_create_room(
 p_name text,p_max_players int,p_rounds int,p_duration int,
 p_match_type text,p_photo_mode text,p_categories text[],p_target int DEFAULT NULL
) RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_code text; limit_target integer;
BEGIN
 IF p_duration NOT IN (0,120,180,300) THEN RAISE EXCEPTION '유효하지 않은 시간 설정'; END IF;
 IF p_duration=0 THEN
   limit_target := case when p_match_type='team' then floor(p_max_players::numeric/2)::integer-1 else p_max_players-1 end;
   IF p_target IS NULL OR p_target<1 OR p_target>limit_target THEN
      RAISE EXCEPTION '완성 인원은 1명 이상, 실제 그림 참가자 수 이내여야 합니다';
   END IF;
 END IF;
 v_code := public.dd_v4_create_room(p_name,p_max_players,p_rounds,
   case when p_duration=0 then 180 else p_duration end,p_match_type,p_photo_mode,p_categories);
 IF p_duration=0 THEN
   UPDATE public.dd_rooms SET duration_seconds=0,completion_target=p_target WHERE code=v_code AND host_id=auth.uid();
 END IF;
 RETURN v_code;
END $$;
REVOKE ALL ON FUNCTION public.dd_v5_create_room(text,int,int,int,text,text,text[],int) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.dd_v5_create_room(text,int,int,int,text,text,text[],int) TO authenticated;

-- Replace only the internal round helpers. Timed mode behaviour is unchanged.
CREATE OR REPLACE FUNCTION public.dd_begin_round(p_room uuid,p_round int) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_room public.dd_rooms%rowtype; v_narrator uuid; v_photo uuid; v_n int;
BEGIN
 SELECT * INTO v_room FROM public.dd_rooms WHERE id=p_room;
 IF NOT FOUND THEN RAISE EXCEPTION '방을 찾지 못했습니다'; END IF;
 IF v_room.match_type<>'solo' THEN RAISE EXCEPTION '팀전 라운드는 다음 단계에서 지원합니다'; END IF;
 SELECT count(*) INTO v_n FROM public.dd_players WHERE room_id=p_room;
 IF v_n<2 THEN RAISE EXCEPTION '최소 2명이 필요합니다'; END IF;
 SELECT user_id INTO v_narrator FROM public.dd_players WHERE room_id=p_room
 ORDER BY joined_at,user_id OFFSET ((p_round-1)%v_n) LIMIT 1;
 IF NOT EXISTS (SELECT 1 FROM public.dd_photos WHERE is_active=true
     AND category=ANY(v_room.allowed_categories)) THEN
   RAISE EXCEPTION '선택한 카테고리에 활성 사진이 없습니다';
 END IF;
 UPDATE public.dd_players SET strokes='[]'::jsonb,submitted=false,placement=null
 WHERE room_id=p_room;
 IF v_room.photo_mode='select' THEN
   UPDATE public.dd_rooms SET phase='photo_select',round_no=p_round,
     narrator_id=v_narrator,photo_id=null,deadline=null,revision=revision+1
   WHERE id=p_room;
 ELSIF v_room.photo_mode='random' THEN
   SELECT id INTO v_photo FROM public.dd_photos
    WHERE is_active=true AND category=ANY(v_room.allowed_categories)
     AND NOT (id=ANY(v_room.used_photo_ids)) ORDER BY random() LIMIT 1;
   IF v_photo IS NULL THEN
    SELECT id INTO v_photo FROM public.dd_photos
     WHERE is_active=true AND category=ANY(v_room.allowed_categories)
     ORDER BY random() LIMIT 1;
   END IF;
   UPDATE public.dd_rooms SET phase='draw',round_no=p_round,
     narrator_id=v_narrator,photo_id=v_photo,
     used_photo_ids=array_append(v_room.used_photo_ids,v_photo),
     deadline=case when v_room.duration_seconds=0 then null else clock_timestamp()+make_interval(secs=>v_room.duration_seconds) end,
     revision=revision+1 WHERE id=p_room;
 ELSE
   RAISE EXCEPTION '알 수 없는 사진 출제 방식입니다';
 END IF;
END $$;

CREATE OR REPLACE FUNCTION public.dd_v4_team_begin(p_room uuid,p_round integer)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE r public.dd_rooms%rowtype; red_id uuid;blue_id uuid; n_red integer;n_blue integer;pick uuid;
BEGIN
 SELECT * INTO r FROM public.dd_rooms WHERE id=p_room;
 IF NOT FOUND OR r.match_type<>'team' THEN RAISE EXCEPTION '팀전 방이 아닙니다'; END IF;
 SELECT count(*) INTO n_red FROM public.dd_players WHERE room_id=r.id AND team_code='red';
 SELECT count(*) INTO n_blue FROM public.dd_players WHERE room_id=r.id AND team_code='blue';
 IF n_red<2 OR n_blue<2 THEN RAISE EXCEPTION '각 팀 최소 2명(설명자 1 + 그림 참가자 1)이 필요합니다'; END IF;
 IF abs(n_red-n_blue)>1 THEN RAISE EXCEPTION '팀 인원 차이는 최대 1명입니다. 팀을 다시 배정해 주세요'; END IF;
 SELECT user_id INTO red_id FROM public.dd_players WHERE room_id=r.id AND team_code='red'
   ORDER BY joined_at,user_id OFFSET ((p_round-1)%n_red) LIMIT 1;
 SELECT user_id INTO blue_id FROM public.dd_players WHERE room_id=r.id AND team_code='blue'
   ORDER BY joined_at,user_id OFFSET ((p_round-1)%n_blue) LIMIT 1;
 IF NOT EXISTS(SELECT 1 FROM public.dd_photos
   WHERE is_active AND category=ANY(r.allowed_categories))
 THEN RAISE EXCEPTION '허용 카테고리에 활성 사진이 없습니다'; END IF;
 UPDATE public.dd_players SET strokes='[]'::jsonb,submitted=false,placement=null WHERE room_id=r.id;
 IF r.photo_mode='random' THEN
   SELECT id INTO pick FROM public.dd_photos WHERE is_active AND category=ANY(r.allowed_categories)
      AND NOT(id=ANY(r.used_photo_ids)) ORDER BY random() LIMIT 1;
   IF pick IS NULL THEN
     SELECT id INTO pick FROM public.dd_photos WHERE is_active AND category=ANY(r.allowed_categories)
      ORDER BY random() LIMIT 1;
   END IF;
   UPDATE public.dd_rooms SET phase='draw',round_no=p_round,
     red_narrator_id=red_id,blue_narrator_id=blue_id,narrator_id=red_id,
     photo_id=pick,used_photo_ids=array_append(r.used_photo_ids,pick),
     deadline=case when r.duration_seconds=0 then null else clock_timestamp()+make_interval(secs=>r.duration_seconds) end,judge_deadline=null,
     revision=revision+1 WHERE id=r.id;
 ELSIF r.photo_mode='select' THEN
   UPDATE public.dd_rooms SET phase='photo_select',round_no=p_round,
     red_narrator_id=red_id,blue_narrator_id=blue_id,narrator_id=red_id,
     photo_id=null,deadline=null,judge_deadline=null,revision=revision+1 WHERE id=r.id;
 ELSE RAISE EXCEPTION '사진 출제 설정이 잘못됐습니다'; END IF;
END $$;

CREATE OR REPLACE FUNCTION public.dd_v4_choose_photo(p_code text,p_photo_id uuid) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE r public.dd_rooms%rowtype;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION '로그인이 필요합니다'; END IF;
 SELECT * INTO r FROM public.dd_rooms WHERE code=p_code FOR UPDATE;
 IF NOT FOUND OR r.phase<>'photo_select' OR r.photo_mode<>'select'
    OR r.narrator_id IS DISTINCT FROM auth.uid()
    OR NOT EXISTS(SELECT 1 FROM public.dd_players WHERE room_id=r.id AND user_id=auth.uid())
 THEN RAISE EXCEPTION '현재 사진 선택자만 확정할 수 있습니다'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.dd_photos WHERE id=p_photo_id AND is_active
    AND category=ANY(r.allowed_categories)) THEN RAISE EXCEPTION '선택할 수 없는 사진입니다'; END IF;
 UPDATE public.dd_rooms SET photo_id=p_photo_id,phase='draw',
    used_photo_ids=array_append(r.used_photo_ids,p_photo_id),
    deadline=case when r.duration_seconds=0 then null else clock_timestamp()+make_interval(secs=>r.duration_seconds) end,revision=revision+1
 WHERE id=r.id;
 RETURN true;
END $$;

-- The installed state/action handlers are preserved as tested v4 fallbacks.
DO $rename$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM pg_proc p JOIN pg_namespace n ON p.pronamespace=n.oid
  WHERE n.nspname='public' AND p.proname='dd_v4_state') THEN
   ALTER FUNCTION public.dd_state(text) RENAME TO dd_v4_state;
 END IF;
 IF NOT EXISTS(SELECT 1 FROM pg_proc p JOIN pg_namespace n ON p.pronamespace=n.oid
  WHERE n.nspname='public' AND p.proname='dd_v4_action') THEN
   ALTER FUNCTION public.dd_action(text,text,jsonb) RENAME TO dd_v4_action;
 END IF;
END $rename$;
REVOKE ALL ON FUNCTION public.dd_v4_state(text) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.dd_v4_action(text,text,jsonb) FROM PUBLIC,anon,authenticated;

-- Call only while the room row is locked by dd_action. No unfinished art is included.
CREATE OR REPLACE FUNCTION public.dd_v5_finish_unlimited(p_room uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE r public.dd_rooms%rowtype; red_done int; blue_done int; done int;
BEGIN
 SELECT * INTO r FROM public.dd_rooms WHERE id=p_room FOR UPDATE;
 IF NOT FOUND OR r.duration_seconds<>0 OR r.phase<>'draw' THEN RETURN; END IF;
 IF r.match_type='solo' THEN
   UPDATE public.dd_players SET strokes='[]'::jsonb WHERE room_id=r.id
      AND user_id<>r.narrator_id AND NOT submitted;
   UPDATE public.dd_rooms SET phase='judge',deadline=NULL,revision=revision+1 WHERE id=r.id;
 ELSE
   -- First target artwork from EACH team only. Never give a larger team more scoring slots.
   INSERT INTO public.dd_round_drawings(room_id,round_no,artist_id,team_code,strokes)
   SELECT q.room_id,r.round_no,q.user_id,q.team_code,q.strokes
   FROM (SELECT p.*,row_number() over(partition by p.team_code ORDER BY p.v5_submitted_at,p.joined_at,p.user_id) AS rn
     FROM public.dd_players p WHERE p.room_id=r.id AND p.submitted
       AND p.user_id NOT IN (r.red_narrator_id,r.blue_narrator_id)) q
   WHERE q.rn<=r.completion_target
   ON CONFLICT(room_id,round_no,artist_id) DO NOTHING;
   -- Assign blinded ballots now. The scoring UI is supplied by the separate v4 voting stage.
   INSERT INTO public.dd_vote_assignments(room_id,round_no,drawing_id,voter_id)
   SELECT d.room_id,d.round_no,d.id,v.user_id
   FROM public.dd_round_drawings d
   JOIN LATERAL (
      SELECT p.user_id FROM public.dd_players p
      WHERE p.room_id=d.room_id AND p.team_code='red' AND p.user_id<>d.artist_id
      ORDER BY md5(d.id::text||p.user_id::text) LIMIT 2
   ) v ON true WHERE d.room_id=r.id AND d.round_no=r.round_no
   ON CONFLICT DO NOTHING;
   INSERT INTO public.dd_vote_assignments(room_id,round_no,drawing_id,voter_id)
   SELECT d.room_id,d.round_no,d.id,v.user_id
   FROM public.dd_round_drawings d
   JOIN LATERAL (
      SELECT p.user_id FROM public.dd_players p
      WHERE p.room_id=d.room_id AND p.team_code='blue' AND p.user_id<>d.artist_id
      ORDER BY md5(d.id::text||p.user_id::text) LIMIT 2
   ) v ON true WHERE d.room_id=r.id AND d.round_no=r.round_no
   ON CONFLICT DO NOTHING;
   UPDATE public.dd_rooms SET phase='vote',deadline=NULL,
     judge_deadline=case when to_regprocedure('public.dd_v4_complete_vote(uuid)') is null
       then null else clock_timestamp()+interval '180 seconds' end,
     revision=revision+1 WHERE id=r.id;
 END IF;
END $$;
REVOKE ALL ON FUNCTION public.dd_v5_finish_unlimited(uuid) FROM PUBLIC,anon,authenticated;

-- Add completion progress without exposing photographs or submitted drawing content.
CREATE OR REPLACE FUNCTION public.dd_state(p_code text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE r public.dd_rooms%rowtype; response jsonb; done int; red_done int; blue_done int;
  n_needed int; finished jsonb;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION '로그인이 필요합니다'; END IF;
 SELECT * INTO r FROM public.dd_rooms WHERE code=p_code;
 IF NOT FOUND OR NOT EXISTS(SELECT 1 FROM public.dd_players
     WHERE room_id=r.id AND user_id=auth.uid()) THEN
   RAISE EXCEPTION '방 참가자가 아닙니다'; END IF;
 response:=public.dd_v4_state(p_code);
 IF r.duration_seconds<>0 THEN RETURN response; END IF;
 SELECT count(*) FILTER (WHERE submitted AND user_id NOT IN (r.red_narrator_id,r.blue_narrator_id)),
        count(*) FILTER (WHERE submitted AND team_code='red' AND user_id NOT IN (r.red_narrator_id,r.blue_narrator_id)),
        count(*) FILTER (WHERE submitted AND team_code='blue' AND user_id NOT IN (r.red_narrator_id,r.blue_narrator_id))
 INTO done,red_done,blue_done FROM public.dd_players WHERE room_id=r.id;
 IF r.match_type='solo' THEN
   SELECT count(*) INTO done FROM public.dd_players
     WHERE room_id=r.id AND submitted AND user_id<>r.narrator_id;
 END IF;
 response:=response || jsonb_build_object('unlimited',true,'completionTarget',r.completion_target,
    'completed',done,'completedRed',red_done,'completedBlue',blue_done);
 IF r.match_type='solo' AND r.phase IN ('judge','result') THEN
   SELECT coalesce(jsonb_agg(c), '[]'::jsonb) INTO finished
   FROM jsonb_array_elements(coalesce(response->'cards','[]'::jsonb)) c
   WHERE EXISTS (SELECT 1 FROM public.dd_players p
      WHERE p.room_id=r.id AND p.user_id=(c->>'id')::uuid AND p.submitted);
   response:=jsonb_set(response,'{cards}',finished);
   IF r.phase='judge' THEN response:=jsonb_set(response,'{need}',to_jsonb(least(3,done))); END IF;
 END IF;
 RETURN response;
END $$;
REVOKE ALL ON FUNCTION public.dd_state(text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.dd_state(text) TO authenticated;

CREATE OR REPLACE FUNCTION public.dd_action(p_code text,p_action text,p_data jsonb DEFAULT '{}'::jsonb)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE r public.dd_rooms%rowtype; me public.dd_players%rowtype;
  red_done int;blue_done int;done int; rank_list jsonb; v_rank uuid;
  seen uuid[]:='{}'::uuid[]; i int; require_ranks int;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION '로그인이 필요합니다'; END IF;
 SELECT * INTO r FROM public.dd_rooms WHERE code=p_code FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION '방이 없습니다'; END IF;
 SELECT * INTO me FROM public.dd_players WHERE room_id=r.id AND user_id=auth.uid();
 IF NOT FOUND THEN RAISE EXCEPTION '참가자가 아닙니다'; END IF;
 IF r.duration_seconds<>0 THEN RETURN public.dd_v4_action(p_code,p_action,p_data); END IF;
 IF p_action='start' THEN
   IF r.match_type='solo' THEN
     SELECT count(*)-1 INTO done FROM public.dd_players WHERE room_id=r.id;
     IF done<r.completion_target THEN RAISE EXCEPTION '현재 참가 인원으로는 설정된 완성 기준에 도달할 수 없습니다'; END IF;
   ELSE
     SELECT count(*) FILTER(WHERE team_code='red')-1,count(*) FILTER(WHERE team_code='blue')-1
       INTO red_done,blue_done FROM public.dd_players WHERE room_id=r.id;
     IF least(red_done,blue_done)<r.completion_target THEN
       RAISE EXCEPTION '현재 팀 인원으로는 지정한 팀별 완성 기준에 도달할 수 없습니다';
     END IF;
   END IF;
   RETURN public.dd_v4_action(p_code,p_action,p_data);
 ELSIF p_action='drawing' THEN
   IF r.phase<>'draw' OR me.submitted OR (r.match_type='solo' AND auth.uid()=r.narrator_id)
      OR (r.match_type='team' AND auth.uid() IN (r.red_narrator_id,r.blue_narrator_id)) THEN
     RAISE EXCEPTION '그림을 저장할 수 없습니다'; END IF;
   IF jsonb_typeof(p_data->'strokes')<>'array' OR length((p_data->'strokes')::text)>150000 THEN
     RAISE EXCEPTION '그림 데이터 크기 또는 형식 오류'; END IF;
   UPDATE public.dd_players SET strokes=p_data->'strokes',
     submitted=coalesce((p_data->>'submitted')::boolean,false),
     v5_submitted_at=case when coalesce((p_data->>'submitted')::boolean,false)
       then clock_timestamp() else null end
     WHERE room_id=r.id AND user_id=auth.uid();
   IF r.match_type='solo' THEN
     SELECT count(*) INTO done FROM public.dd_players WHERE room_id=r.id
       AND user_id<>r.narrator_id AND submitted;
     IF done>=r.completion_target THEN PERFORM public.dd_v5_finish_unlimited(r.id); END IF;
   ELSE
     SELECT count(*) FILTER (WHERE team_code='red'),count(*) FILTER (WHERE team_code='blue')
     INTO red_done,blue_done FROM public.dd_players WHERE room_id=r.id AND submitted
       AND user_id NOT IN (r.red_narrator_id,r.blue_narrator_id);
     IF red_done>=r.completion_target AND blue_done>=r.completion_target THEN
       PERFORM public.dd_v5_finish_unlimited(r.id);
     END IF;
   END IF;
   RETURN true;
 ELSIF p_action='end' THEN
   IF r.host_id<>auth.uid() OR r.phase<>'draw' THEN RAISE EXCEPTION '방장만 조기 마감할 수 있습니다'; END IF;
   PERFORM public.dd_v5_finish_unlimited(r.id);
   RETURN true;
 ELSIF p_action='judge' AND r.match_type='solo' THEN
   IF r.phase<>'judge' OR r.narrator_id<>auth.uid() THEN RAISE EXCEPTION '설명자만 심사 가능'; END IF;
   SELECT least(3,count(*)) INTO require_ranks FROM public.dd_players
      WHERE room_id=r.id AND submitted AND user_id<>r.narrator_id;
   rank_list:=p_data->'ranks';
   IF jsonb_typeof(rank_list)<>'array' OR jsonb_array_length(rank_list)<>require_ranks
      THEN RAISE EXCEPTION '완성 그림의 순위를 정해 주세요'; END IF;
   IF require_ranks>0 THEN
    FOR i IN 0..require_ranks-1 LOOP
      BEGIN v_rank:=(rank_list->>i)::uuid;
      EXCEPTION WHEN others THEN RAISE EXCEPTION '잘못된 참가자 ID'; END;
      IF v_rank=any(seen) OR NOT EXISTS (
        SELECT 1 FROM public.dd_players WHERE room_id=r.id AND user_id=v_rank
          AND submitted AND user_id<>r.narrator_id) THEN
        RAISE EXCEPTION '완성 그림만 한 번씩 심사할 수 있습니다'; END IF;
      seen:=array_append(seen,v_rank);
      UPDATE public.dd_players SET placement=i+1,
        score=score+(case i when 0 then 100 when 1 then 70 else 50 end)
        WHERE room_id=r.id AND user_id=v_rank;
    END LOOP;
   END IF;
   UPDATE public.dd_rooms SET phase='result',revision=revision+1 WHERE id=r.id;
   RETURN true;
 ELSE
   -- v4 handling for ready/start/photo selection/next/restart/leave, authorized there.
   RETURN public.dd_v4_action(p_code,p_action,p_data);
 END IF;
END $$;
REVOKE ALL ON FUNCTION public.dd_action(text,text,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.dd_action(text,text,jsonb) TO authenticated;
COMMIT;
