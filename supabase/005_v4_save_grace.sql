-- v4 step 4.1 / final-save grace period (TEAM ONLY).
-- Prerequisite: 004_v4_team_rounds.sql. Run only 005, once.
-- The 5s grace accepts a final submitted drawing after the deadline.
-- New drawing edits after the deadline are rejected. The room advances
-- only after that grace period; an early end also respects the grace.
BEGIN;
CREATE OR REPLACE FUNCTION public.dd_v4_team_finish(p_room uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE r public.dd_rooms%rowtype;
BEGIN
 SELECT * INTO r FROM public.dd_rooms WHERE id=p_room;
 IF NOT FOUND OR r.match_type<>'team' OR r.phase<>'draw' THEN RAISE EXCEPTION '마감할 팀전 라운드가 없습니다'; END IF;
 IF r.deadline IS NULL OR clock_timestamp()<r.deadline+interval '5 seconds' THEN
   RAISE EXCEPTION '최종 저장 유예시간이 지나지 않았습니다';
 END IF;
 INSERT INTO public.dd_round_drawings(room_id,round_no,artist_id,team_code,strokes)
 SELECT p.room_id,r.round_no,p.user_id,p.team_code,p.strokes
 FROM public.dd_players p WHERE p.room_id=r.id
   AND p.user_id NOT IN (r.red_narrator_id,r.blue_narrator_id)
 ON CONFLICT (room_id,round_no,artist_id) DO NOTHING;
 UPDATE public.dd_rooms SET phase='vote',deadline=null,revision=revision+1 WHERE id=r.id;
END $$;

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
 IF r.phase='draw' AND r.deadline+interval '5 seconds'<=clock_timestamp() THEN
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
   'saveGraceUntil',CASE WHEN r.deadline IS NULL THEN NULL ELSE (extract(epoch FROM r.deadline+interval '5 seconds')*1000)::bigint END,
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
 IF r.phase='draw' AND r.deadline+interval '5 seconds'<=clock_timestamp() THEN
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
   -- After cutoff we allow ONLY the final submission for 5 seconds, not continuing edits.
   IF r.deadline<=clock_timestamp() AND coalesce((p_data->>'submitted')::boolean,false) IS DISTINCT FROM true THEN
     RAISE EXCEPTION '제한시간 종료 후에는 마지막 그림만 제출할 수 있습니다';
   END IF;
   IF jsonb_typeof(p_data->'strokes')<>'array' OR
      length((p_data->'strokes')::text)>150000 THEN
     RAISE EXCEPTION '그림 데이터가 유효하지 않거나 너무 큽니다'; END IF;
   UPDATE public.dd_players SET strokes=p_data->'strokes',
     submitted=coalesce((p_data->>'submitted')::boolean,false)
   WHERE room_id=r.id AND user_id=auth.uid();
 ELSIF p_action='end' THEN
   IF r.host_id<>auth.uid() OR r.phase<>'draw' THEN
      RAISE EXCEPTION '방장만 그림을 조기 마감할 수 있습니다'; END IF;
   -- Freeze the clock now, then wait five seconds for in-flight final saves.
   UPDATE public.dd_rooms SET deadline=least(r.deadline,clock_timestamp()),revision=revision+1 WHERE id=r.id;
 ELSE
   RAISE EXCEPTION '팀전 라운드 종료 후 블라인드 심사와 결과는 다음 단계에 연결합니다';
 END IF;
 RETURN true;
END $$;
COMMIT;
