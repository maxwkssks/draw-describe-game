-- Draw & Describe v4 / STEP 4 : Two-team narrators + timed rounds + artwork snapshots.
-- Depends on 001, 002, 003 already applied in order.
-- No drops of user tables. Run only 004. This migration wraps the existing solo RPCs.
BEGIN;

-- Keep one copy of the currently installed individual-play functions.
DO $migrate$
BEGIN
 IF NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='public' AND p.proname='dd_v3_state') THEN
   ALTER FUNCTION public.dd_state(text) RENAME TO dd_v3_state;
 END IF;
 IF NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='public' AND p.proname='dd_v3_action') THEN
   ALTER FUNCTION public.dd_action(text,text,jsonb) RENAME TO dd_v3_action;
 END IF;
END $migrate$;
REVOKE ALL ON FUNCTION public.dd_v3_state(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.dd_v3_action(text,text,jsonb) FROM PUBLIC, anon, authenticated;

-- Protect phase moves; a team cannot enter v3's individual judge phase.
CREATE OR REPLACE FUNCTION public.dd_v4_lobby_guard() RETURNS trigger
LANGUAGE plpgsql SET search_path='' AS $$
BEGIN
 IF old.phase='lobby' AND new.phase<>'lobby' THEN
   IF old.match_type='solo' AND
     ((old.photo_mode='random' AND new.phase<>'draw') OR
      (old.photo_mode='select' AND new.phase<>'photo_select')) THEN
     RAISE EXCEPTION '개인전 시작 단계가 올바르지 않습니다';
   END IF;
   IF old.match_type='team' AND
     ((old.photo_mode='random' AND new.phase<>'draw') OR
      (old.photo_mode='select' AND new.phase<>'photo_select')) THEN
     RAISE EXCEPTION '팀전 시작 단계가 올바르지 않습니다';
   END IF;
 END IF;
 IF old.phase='photo_select' AND new.phase NOT IN ('photo_select','draw')
    THEN RAISE EXCEPTION '사진 확정을 먼저 완료하세요'; END IF;
 IF old.match_type='team' AND old.phase='draw'
    AND new.phase NOT IN ('draw','vote') THEN RAISE EXCEPTION '팀전의 다음 단계는 블라인드 평가입니다'; END IF;
 RETURN new;
END $$;

-- Internal team round setup. Lock the room before calling.
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
     deadline=clock_timestamp()+make_interval(secs=>r.duration_seconds),judge_deadline=null,
     revision=revision+1 WHERE id=r.id;
 ELSIF r.photo_mode='select' THEN
   UPDATE public.dd_rooms SET phase='photo_select',round_no=p_round,
     red_narrator_id=red_id,blue_narrator_id=blue_id,narrator_id=red_id,
     photo_id=null,deadline=null,judge_deadline=null,revision=revision+1 WHERE id=r.id;
 ELSE RAISE EXCEPTION '사진 출제 설정이 잘못됐습니다'; END IF;
END $$;
REVOKE ALL ON FUNCTION public.dd_v4_team_begin(uuid,integer) FROM PUBLIC,anon,authenticated;

-- Snapshot all team artists on the server, including unfinished drafts.
-- No public client can update the snapshots.
CREATE OR REPLACE FUNCTION public.dd_v4_team_finish(p_room uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE r public.dd_rooms%rowtype;
BEGIN
 SELECT * INTO r FROM public.dd_rooms WHERE id=p_room;
 IF NOT FOUND OR r.match_type<>'team' OR r.phase<>'draw' THEN RAISE EXCEPTION '마감할 팀전 라운드가 없습니다'; END IF;
 INSERT INTO public.dd_round_drawings(room_id,round_no,artist_id,team_code,strokes)
 SELECT p.room_id,r.round_no,p.user_id,p.team_code,p.strokes
 FROM public.dd_players p WHERE p.room_id=r.id
   AND p.user_id NOT IN (r.red_narrator_id,r.blue_narrator_id)
 ON CONFLICT (room_id,round_no,artist_id) DO NOTHING;
 UPDATE public.dd_rooms SET phase='vote',deadline=null,revision=revision+1 WHERE id=r.id;
END $$;
REVOKE ALL ON FUNCTION public.dd_v4_team_finish(uuid) FROM PUBLIC,anon,authenticated;

-- Selectors: in team/select mode the red narrator picks ONE photo for both teams.
-- Only the eligible selector can access the list, even if the client crafts requests.
CREATE OR REPLACE FUNCTION public.dd_v4_photo_options(p_code text) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE r public.dd_rooms%rowtype; photos jsonb;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION '로그인이 필요합니다'; END IF;
 SELECT * INTO r FROM public.dd_rooms WHERE code=p_code;
 IF NOT FOUND OR r.phase<>'photo_select' OR r.photo_mode<>'select'
    OR r.narrator_id IS DISTINCT FROM auth.uid()
    OR NOT EXISTS(SELECT 1 FROM public.dd_players WHERE room_id=r.id AND user_id=auth.uid())
 THEN RAISE EXCEPTION '현재 사진 선택자만 목록을 볼 수 있습니다'; END IF;
 SELECT coalesce(jsonb_agg(jsonb_build_object('id',id,'name',name,'category',category,
   'path',storage_path,'used',id=ANY(r.used_photo_ids))
   ORDER BY (id=ANY(r.used_photo_ids)),name,id),'[]'::jsonb)
 INTO photos FROM public.dd_photos WHERE is_active AND category=ANY(r.allowed_categories);
 RETURN photos;
END $$;
REVOKE ALL ON FUNCTION public.dd_v4_photo_options(text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.dd_v4_photo_options(text) TO authenticated;

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
    deadline=clock_timestamp()+make_interval(secs=>r.duration_seconds),revision=revision+1
 WHERE id=r.id;
 RETURN true;
END $$;
REVOKE ALL ON FUNCTION public.dd_v4_choose_photo(text,uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.dd_v4_choose_photo(text,uuid) TO authenticated;

-- Private storage read for selectors and narrators, and no one else before reveal.
CREATE OR REPLACE FUNCTION public.dd_can_read_photo(p_path text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT public.dd_is_admin() OR EXISTS (
  SELECT 1 FROM public.dd_photos f
  JOIN public.dd_rooms r ON (
     r.photo_id=f.id OR (r.phase='photo_select' AND r.photo_mode='select'
       AND f.is_active AND f.category=ANY(r.allowed_categories)))
  JOIN public.dd_players p ON p.room_id=r.id
  WHERE f.storage_path=p_path AND p.user_id=auth.uid() AND (
      (r.phase='photo_select' AND r.narrator_id=auth.uid()) OR
      (r.phase IN ('draw','judge') AND r.photo_id=f.id AND
        (r.narrator_id=auth.uid() OR
         (r.match_type='team' AND auth.uid() IN (r.red_narrator_id,r.blue_narrator_id)))) OR
      (r.phase IN ('result','final') AND r.photo_id=f.id)
  )
 )
$$;
REVOKE ALL ON FUNCTION public.dd_can_read_photo(text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.dd_can_read_photo(text) TO authenticated;

-- v4 team state is generated independently. v3 individual state remains untouched.
CREATE OR REPLACE FUNCTION public.dd_state(p_code text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE r public.dd_rooms%rowtype; me public.dd_players%rowtype;
        players_json jsonb; photos_count int; red_name text;blue_name text;
        narrating boolean; selector boolean; path text; saved_count int;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION '로그인이 필요합니다'; END IF;
 SELECT * INTO r FROM public.dd_rooms WHERE code=p_code FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION '방을 찾을 수 없습니다'; END IF;
 SELECT * INTO me FROM public.dd_players WHERE room_id=r.id AND user_id=auth.uid();
 IF NOT FOUND THEN RAISE EXCEPTION '이 방의 참가자가 아닙니다'; END IF;
 IF r.match_type='solo' THEN RETURN public.dd_v3_state(p_code); END IF;
 IF r.phase='draw' AND r.deadline<=clock_timestamp() THEN
   PERFORM public.dd_v4_team_finish(r.id);
   SELECT * INTO r FROM public.dd_rooms WHERE id=r.id;
 END IF;
 narrating := (auth.uid() IN (r.red_narrator_id,r.blue_narrator_id));
 selector := (r.narrator_id=auth.uid());
 SELECT name INTO red_name FROM public.dd_players WHERE room_id=r.id AND user_id=r.red_narrator_id;
 SELECT name INTO blue_name FROM public.dd_players WHERE room_id=r.id AND user_id=r.blue_narrator_id;
 SELECT coalesce(jsonb_agg(jsonb_build_object('id',user_id::text,'name',name,
   'ready',ready,'host',user_id=r.host_id,'online',true,'submitted',submitted,
   'score',score,'team',team_code,'isNarrator',user_id IN (r.red_narrator_id,r.blue_narrator_id))
   ORDER BY joined_at,user_id),'[]'::jsonb) INTO players_json
 FROM public.dd_players WHERE room_id=r.id;
 SELECT count(*) INTO photos_count FROM public.dd_photos
 WHERE is_active AND category=ANY(r.allowed_categories);
 SELECT count(*) INTO saved_count FROM public.dd_round_drawings
 WHERE room_id=r.id AND round_no=r.round_no;
 IF r.photo_id IS NOT NULL AND
   ((r.phase IN ('draw','judge') AND narrating) OR r.phase IN ('result','final')) THEN
   SELECT storage_path INTO path FROM public.dd_photos WHERE id=r.photo_id;
 END IF;
 RETURN jsonb_build_object(
   'code',r.code,'me',auth.uid()::text,'host',r.host_id=auth.uid(),
   'matchType','team','photoMode',r.photo_mode,'phase',r.phase,
   'round',r.round_no,'rounds',r.total_rounds,'revision',r.revision,
   'maxPlayers',r.max_players,'duration',r.duration_seconds,
   'deadline',CASE WHEN r.deadline IS NULL THEN NULL
      ELSE (extract(epoch FROM r.deadline)*1000)::bigint END,
   'players',players_json,'narrator',r.narrator_id::text,
   'narratorName',coalesce(red_name,'')||' / '||coalesce(blue_name,''),
   'redNarratorName',red_name,'blueNarratorName',blue_name,
   'isNarrator',narrating,'isSelector',selector,'need',0,
   'photoCount',photos_count,'photoPath',path,
   'cards','[]'::jsonb,'savedDrawings',saved_count,
   'myStrokes',CASE WHEN r.phase='draw' AND NOT narrating THEN me.strokes
      ELSE '[]'::jsonb END
 );
END $$;
REVOKE ALL ON FUNCTION public.dd_state(text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.dd_state(text) TO authenticated;

CREATE OR REPLACE FUNCTION public.dd_action(p_code text,p_action text,p_data jsonb DEFAULT '{}'::jsonb)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE r public.dd_rooms%rowtype; me public.dd_players%rowtype;
        count_all int; ready_all int; red_count int; blue_count int;
        is_narrating boolean;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION '로그인이 필요합니다'; END IF;
 SELECT * INTO r FROM public.dd_rooms WHERE code=p_code FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION '방이 없습니다'; END IF;
 SELECT * INTO me FROM public.dd_players WHERE room_id=r.id AND user_id=auth.uid();
 IF NOT FOUND THEN RAISE EXCEPTION '참가 권한이 없습니다'; END IF;
 IF r.match_type='solo' THEN RETURN public.dd_v3_action(p_code,p_action,p_data); END IF;
 IF r.phase='draw' AND r.deadline<=clock_timestamp() THEN
   PERFORM public.dd_v4_team_finish(r.id);
   SELECT * INTO r FROM public.dd_rooms WHERE id=r.id;
 END IF;
 is_narrating := auth.uid() IN (r.red_narrator_id,r.blue_narrator_id);
 IF p_action='ready' THEN
   IF r.phase<>'lobby' OR r.host_id=auth.uid() THEN
      RAISE EXCEPTION '준비 상태를 변경할 수 없습니다'; END IF;
   UPDATE public.dd_players SET ready=coalesce((p_data->>'value')::boolean,false)
    WHERE room_id=r.id AND user_id=auth.uid();
   UPDATE public.dd_rooms SET revision=revision+1 WHERE id=r.id;
 ELSIF p_action='start' THEN
   IF r.host_id<>auth.uid() OR r.phase<>'lobby' THEN RAISE EXCEPTION '방장만 시작할 수 있습니다'; END IF;
   SELECT count(*),count(*) FILTER (WHERE ready),count(*) FILTER (WHERE team_code='red'),
      count(*) FILTER (WHERE team_code='blue') INTO count_all,ready_all,red_count,blue_count
   FROM public.dd_players WHERE room_id=r.id;
   IF count_all<4 OR ready_all<>count_all THEN RAISE EXCEPTION '팀전은 4명 이상, 전원 준비가 필요합니다'; END IF;
   IF red_count<2 OR blue_count<2 OR abs(red_count-blue_count)>1 THEN
      RAISE EXCEPTION '각 팀 2명 이상, 팀 인원 차이 최대 1명으로 배정하세요'; END IF;
   PERFORM public.dd_v4_team_begin(r.id,1);
 ELSIF p_action='drawing' THEN
   IF r.phase<>'draw' OR is_narrating OR me.submitted THEN
     RAISE EXCEPTION '지금은 그림을 저장할 수 없습니다'; END IF;
   IF jsonb_typeof(p_data->'strokes')<>'array' OR
      length((p_data->'strokes')::text)>150000 THEN
     RAISE EXCEPTION '그림 데이터가 유효하지 않거나 너무 큽니다'; END IF;
   UPDATE public.dd_players SET strokes=p_data->'strokes',
     submitted=coalesce((p_data->>'submitted')::boolean,false)
   WHERE room_id=r.id AND user_id=auth.uid();
 ELSIF p_action='end' THEN
   IF r.host_id<>auth.uid() OR r.phase<>'draw' THEN
      RAISE EXCEPTION '방장만 그림을 조기 마감할 수 있습니다'; END IF;
   PERFORM public.dd_v4_team_finish(r.id);
 ELSE
   RAISE EXCEPTION '팀전 라운드 종료 후 블라인드 심사와 결과는 다음 단계에 연결합니다';
 END IF;
 RETURN true;
END $$;
REVOKE ALL ON FUNCTION public.dd_action(text,text,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.dd_action(text,text,jsonb) TO authenticated;

-- Note: old solo implementation deliberately retained and not publicly callable.
COMMIT;
