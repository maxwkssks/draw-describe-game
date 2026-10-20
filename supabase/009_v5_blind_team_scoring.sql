-- STEP 5: BLIND TEAM BALLOTS + RESULTS, installs AFTER 008_v5_host_presence.sql.
-- REQUIRES 001 through 005, 007 and 008. Do not replay older migrations.
-- 006 was an uninstalled experimental design; its 3 helper functions are included here.
-- Preserves currently deployed v5.0 timed/unlimited solo flows and v5.1 host recovery.
-- IMPORTANT: run on backup/test project first; production Supabase SQL has not been run here.
BEGIN;
CREATE TABLE IF NOT EXISTS public.dd_team_round_results (
 room_id uuid NOT NULL REFERENCES public.dd_rooms(id) ON DELETE CASCADE,
 round_no integer NOT NULL CHECK(round_no BETWEEN 1 AND 10),
 red_score numeric(6,2), blue_score numeric(6,2),
 red_valid integer NOT NULL DEFAULT 0, blue_valid integer NOT NULL DEFAULT 0,
 counted boolean NOT NULL DEFAULT false,
 completed_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(room_id,round_no)
);
ALTER TABLE public.dd_team_round_results ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.dd_team_round_results FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION public.dd_v4_team_finish(p_room uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE r public.dd_rooms%rowtype;
BEGIN
 SELECT * INTO r FROM public.dd_rooms WHERE id=p_room FOR UPDATE;
 IF NOT FOUND OR r.match_type<>'team' OR r.phase<>'draw' THEN
   RAISE EXCEPTION '마감할 팀전 라운드가 없습니다'; END IF;
 IF r.deadline IS NULL OR clock_timestamp()<r.deadline+interval '5 seconds' THEN
   RAISE EXCEPTION '최종 저장 유예시간이 지나지 않았습니다'; END IF;
 INSERT INTO public.dd_round_drawings(room_id,round_no,artist_id,team_code,strokes)
 SELECT p.room_id,r.round_no,p.user_id,p.team_code,p.strokes
 FROM public.dd_players p WHERE p.room_id=r.id
 AND p.user_id NOT IN (r.red_narrator_id,r.blue_narrator_id)
 ON CONFLICT (room_id,round_no,artist_id) DO NOTHING;
 INSERT INTO public.dd_vote_assignments(room_id,round_no,drawing_id,voter_id)
 SELECT d.room_id,d.round_no,d.id,v.user_id
 FROM public.dd_round_drawings d
 JOIN LATERAL (
    SELECT t.user_id FROM public.dd_players t
    WHERE t.room_id=d.room_id AND t.team_code='red' AND t.user_id<>d.artist_id
    ORDER BY md5(d.id::text||t.user_id::text) LIMIT 2
 ) v ON true
 WHERE d.room_id=r.id AND d.round_no=r.round_no
 ON CONFLICT DO NOTHING;
 INSERT INTO public.dd_vote_assignments(room_id,round_no,drawing_id,voter_id)
 SELECT d.room_id,d.round_no,d.id,v.user_id
 FROM public.dd_round_drawings d
 JOIN LATERAL (
    SELECT t.user_id FROM public.dd_players t
    WHERE t.room_id=d.room_id AND t.team_code='blue' AND t.user_id<>d.artist_id
    ORDER BY md5(d.id::text||t.user_id::text) LIMIT 2
 ) v ON true
 WHERE d.room_id=r.id AND d.round_no=r.round_no
 ON CONFLICT DO NOTHING;
 UPDATE public.dd_rooms SET phase='vote',deadline=NULL,
   judge_deadline=clock_timestamp()+interval '180 seconds',revision=revision+1
 WHERE id=r.id;
END $$;
REVOKE ALL ON FUNCTION public.dd_v4_team_finish(uuid) FROM PUBLIC,anon,authenticated;

-- Complete voting ONLY after all assigned votes are submitted OR 180 seconds pass.
-- Incomplete/one-sided artwork is unscored, and a round without valid artwork
-- contributes no points for either team. Locked by dd_state/dd_action callers.
CREATE OR REPLACE FUNCTION public.dd_v4_complete_vote(p_room uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE r public.dd_rooms%rowtype; missing_count integer;
        r_score numeric(6,2); b_score numeric(6,2); r_n int; b_n int;
BEGIN
 SELECT * INTO r FROM public.dd_rooms WHERE id=p_room FOR UPDATE;
 IF NOT FOUND OR r.match_type<>'team' OR r.phase<>'vote' THEN RETURN; END IF;
 SELECT count(*) INTO missing_count FROM public.dd_vote_assignments a
 LEFT JOIN public.dd_votes v ON v.drawing_id=a.drawing_id AND v.voter_id=a.voter_id
 WHERE a.room_id=r.id AND a.round_no=r.round_no AND v.drawing_id IS NULL;
 IF missing_count>0 AND clock_timestamp()<r.judge_deadline THEN RETURN; END IF;
 SELECT round(avg(s.score) FILTER (WHERE s.team_code='red'),2),
        round(avg(s.score) FILTER (WHERE s.team_code='blue'),2),
        count(*) FILTER (WHERE s.team_code='red' AND s.score IS NOT NULL),
        count(*) FILTER (WHERE s.team_code='blue' AND s.score IS NOT NULL)
 INTO r_score,b_score,r_n,b_n
 FROM public.dd_v4_drawing_scores s
 WHERE s.room_id=r.id AND s.round_no=r.round_no;
 INSERT INTO public.dd_team_round_results
  (room_id,round_no,red_score,blue_score,red_valid,blue_valid,counted)
 VALUES(r.id,r.round_no,r_score,b_score,r_n,b_n,r_n>0 AND b_n>0)
 ON CONFLICT(room_id,round_no) DO NOTHING;
 UPDATE public.dd_rooms SET phase='result',revision=revision+1 WHERE id=r.id;
END $$;
REVOKE ALL ON FUNCTION public.dd_v4_complete_vote(uuid) FROM PUBLIC,anon,authenticated;

-- Only participant + assigned ballot in vote phase. No author/team is returned.
-- Original photograph becomes visible to judges only when voting starts.
CREATE OR REPLACE FUNCTION public.dd_can_read_photo(p_path text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT public.dd_is_admin() OR EXISTS (
  SELECT 1 FROM public.dd_photos f
  JOIN public.dd_rooms r ON (
    r.photo_id=f.id OR (r.phase='photo_select' AND r.photo_mode='select'
      AND f.is_active AND f.category=ANY(r.allowed_categories)))
  JOIN public.dd_players p ON p.room_id=r.id
  WHERE f.storage_path=p_path AND p.user_id=auth.uid() AND (
    (r.phase='photo_select' AND r.narrator_id=auth.uid()) OR
    (r.phase='draw' AND r.photo_id=f.id AND
      (r.narrator_id=auth.uid() OR
       (r.match_type='team' AND auth.uid() IN (r.red_narrator_id,r.blue_narrator_id)))) OR
    (r.phase='judge' AND r.photo_id=f.id AND r.narrator_id=auth.uid()) OR
    (r.phase IN ('vote','result','final') AND r.match_type='team' AND r.photo_id=f.id) OR
    (r.phase IN ('result','final') AND r.photo_id=f.id)
  )
 )
$$;
REVOKE ALL ON FUNCTION public.dd_can_read_photo(text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.dd_can_read_photo(text) TO authenticated;


-- Save current v5.0 entrypoints under private callable names, once, before wrapping.
-- Do not replace dd_v4_state / dd_v4_action, which v5.0 calls internally.
DO $rename$
BEGIN
 IF NOT EXISTS (
  SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND p.proname='dd_v5_before_ballot_state'
 ) THEN
  ALTER FUNCTION public.dd_state(text) RENAME TO dd_v5_before_ballot_state;
 END IF;
 IF NOT EXISTS (
  SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND p.proname='dd_v5_before_ballot_action'
 ) THEN
  ALTER FUNCTION public.dd_action(text,text,jsonb) RENAME TO dd_v5_before_ballot_action;
 END IF;
END $rename$;
REVOKE ALL ON FUNCTION public.dd_v5_before_ballot_state(text) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.dd_v5_before_ballot_action(text,text,jsonb) FROM PUBLIC,anon,authenticated;

-- Decorate the existing state response. Solo stays unchanged. We do NOT expose
-- artist / team mapping until the result stage. The original photo is shown to
-- all assigned judges only after the vote phase begins.
CREATE OR REPLACE FUNCTION public.dd_state(p_code text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE r public.dd_rooms%rowtype; response jsonb;
 v_cards jsonb := '[]'::jsonb; v_totals jsonb; v_round jsonb;
 v_assigned int:=0; v_voted int:=0; v_photo text;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION '로그인이 필요합니다'; END IF;
 SELECT * INTO r FROM public.dd_rooms WHERE code=p_code FOR UPDATE;
 IF NOT FOUND OR NOT EXISTS(SELECT 1 FROM public.dd_players
    WHERE room_id=r.id AND user_id=auth.uid()) THEN
   RAISE EXCEPTION '방 참가자가 아닙니다'; END IF;
 IF r.match_type='solo' THEN
   RETURN public.dd_v5_before_ballot_state(p_code);
 END IF;
 IF r.phase='vote' THEN
   IF r.judge_deadline IS NULL THEN
     UPDATE public.dd_rooms SET judge_deadline=clock_timestamp()+interval '180 seconds'
       WHERE id=r.id;
   END IF;
   PERFORM public.dd_v4_complete_vote(r.id);
 END IF;
 -- May finalize timed drawing with the 5-second grace; may add v5 completion counters.
 response:=public.dd_v5_before_ballot_state(p_code);
 SELECT * INTO r FROM public.dd_rooms WHERE id=r.id;
 -- The delegated function may enter vote on this state poll.
 IF r.phase='vote' AND r.judge_deadline IS NULL THEN
   UPDATE public.dd_rooms SET judge_deadline=clock_timestamp()+interval '180 seconds' WHERE id=r.id;
   SELECT * INTO r FROM public.dd_rooms WHERE id=r.id;
 END IF;
 IF r.phase='vote' THEN
   SELECT count(*),count(v.drawing_id)
   INTO v_assigned,v_voted FROM public.dd_vote_assignments a
   LEFT JOIN public.dd_votes v
     ON v.drawing_id=a.drawing_id AND v.voter_id=a.voter_id
   WHERE a.room_id=r.id AND a.round_no=r.round_no;
 END IF;
 IF r.phase IN ('vote','result','final') AND r.photo_id IS NOT NULL THEN
   SELECT storage_path INTO v_photo FROM public.dd_photos WHERE id=r.photo_id;
 END IF;
 IF r.phase IN ('result','final') THEN
   SELECT coalesce(jsonb_agg(jsonb_build_object(
       'id',d.id,'name',p.name,'team',d.team_code,'strokes',d.strokes,
       'score',s.score,'redVotes',s.red_votes,'blueVotes',s.blue_votes
     ) ORDER BY d.created_at,d.id),'[]'::jsonb)
     INTO v_cards
   FROM public.dd_round_drawings d
   JOIN public.dd_players p ON p.room_id=d.room_id AND p.user_id=d.artist_id
   JOIN public.dd_v4_drawing_scores s ON s.drawing_id=d.id
   WHERE d.room_id=r.id AND d.round_no=r.round_no;
   SELECT jsonb_build_object('red',red_score,'blue',blue_score,
      'counted',counted,'redValid',red_valid,'blueValid',blue_valid)
   INTO v_round FROM public.dd_team_round_results
   WHERE room_id=r.id AND round_no=r.round_no;
   SELECT jsonb_build_object(
      'red',coalesce(sum(red_score) FILTER (WHERE counted),0),
      'blue',coalesce(sum(blue_score) FILTER (WHERE counted),0),
      'completedRounds',count(*),'countedRounds',count(*) FILTER (WHERE counted))
   INTO v_totals FROM public.dd_team_round_results WHERE room_id=r.id;
 END IF;
 RETURN response || jsonb_build_object(
   'phase',r.phase,'revision',r.revision,
   'voteDeadline',CASE WHEN r.judge_deadline IS NULL THEN NULL
        ELSE (extract(epoch FROM r.judge_deadline)*1000)::bigint END,
   'photoPath',coalesce(v_photo,response->>'photoPath'),
   'ballotProgress',jsonb_build_object('assigned',v_assigned,'voted',v_voted),
   'cards',CASE WHEN r.phase IN ('result','final') THEN v_cards ELSE '[]'::jsonb END,
   'roundScore',v_round,'teamTotals',v_totals
 );
END $$;
REVOKE ALL ON FUNCTION public.dd_state(text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.dd_state(text) TO authenticated;

-- Only the host can move the result forward; participant vote writes use
-- dd_v4_submit_vote, already secured by the 001 migration (assignment, role,
-- scoring ranges, anti-duplicate). Keep existing v5 actions intact.
CREATE OR REPLACE FUNCTION public.dd_action(p_code text,p_action text,p_data jsonb DEFAULT '{}'::jsonb)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE r public.dd_rooms%rowtype;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION '로그인이 필요합니다'; END IF;
 SELECT * INTO r FROM public.dd_rooms WHERE code=p_code FOR UPDATE;
 IF NOT FOUND OR NOT EXISTS(SELECT 1 FROM public.dd_players
    WHERE room_id=r.id AND user_id=auth.uid()) THEN
   RAISE EXCEPTION '참가자가 아닙니다'; END IF;
 IF r.match_type='team' AND r.phase='vote' THEN
   PERFORM public.dd_v4_complete_vote(r.id);
   SELECT * INTO r FROM public.dd_rooms WHERE id=r.id;
   IF r.phase='vote' THEN RAISE EXCEPTION '블라인드 평가가 진행 중입니다'; END IF;
 END IF;
 -- Existing v5.0 action handles team start/drawing/end/next, plus solo.
 RETURN public.dd_v5_before_ballot_action(p_code,p_action,p_data);
END $$;
REVOKE ALL ON FUNCTION public.dd_action(text,text,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.dd_action(text,text,jsonb) TO authenticated;
COMMIT;
