-- v5.3 Narrator-only live viewing. Requires v5.2/009; no existing data altered.
-- Each narrator receives ONLY own-team drawings during team rounds.
BEGIN;
CREATE OR REPLACE FUNCTION public.dd_narrator_live_gallery(p_code text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE r public.dd_rooms%ROWTYPE; viewer_team text; art jsonb;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION '로그인이 필요합니다'; END IF;
 SELECT * INTO r FROM public.dd_rooms WHERE code=p_code;
 IF NOT FOUND OR r.phase<>'draw' THEN RAISE EXCEPTION '진행 중인 그림 라운드가 아닙니다'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.dd_players WHERE room_id=r.id AND user_id=auth.uid())
 THEN RAISE EXCEPTION '이 방 참가자가 아닙니다'; END IF;
 IF r.match_type='team' THEN
   IF auth.uid()=r.red_narrator_id THEN viewer_team:='red';
   ELSIF auth.uid()=r.blue_narrator_id THEN viewer_team:='blue';
   ELSE RAISE EXCEPTION '해당 팀 설명자만 그림을 볼 수 있습니다'; END IF;
 ELSE
   IF r.narrator_id IS DISTINCT FROM auth.uid() THEN
     RAISE EXCEPTION '설명자만 그림을 볼 수 있습니다';
   END IF;
 END IF;
 SELECT COALESCE(jsonb_agg(jsonb_build_object(
   'id',p.user_id::text,'name',p.name,'submitted',p.submitted,'strokes',p.strokes)
   ORDER BY p.joined_at,p.user_id),'[]'::jsonb) INTO art
 FROM public.dd_players p
 WHERE p.room_id=r.id
   AND p.user_id<>auth.uid()
   AND (
     (r.match_type='team' AND p.team_code=viewer_team
      AND p.user_id NOT IN (r.red_narrator_id,r.blue_narrator_id))
     OR
     (r.match_type<>'team' AND p.user_id<>r.narrator_id)
   );
 RETURN art;
END $$;
REVOKE ALL ON FUNCTION public.dd_narrator_live_gallery(text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.dd_narrator_live_gallery(text) TO authenticated;
COMMIT;
