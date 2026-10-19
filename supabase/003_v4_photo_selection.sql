-- 그려봐! v4 / STEP 3: category-aware photo selection (solo, random/select).
-- Prerequisites: v3 schema.sql, 001_v4_team_blind_migration.sql,
--                002_v4_lobby_modes.sql ALREADY successfully installed.
-- Run ONLY this 003 file, once, in the existing Supabase SQL Editor.
-- Existing rooms, drawings, votes and admin accounts are NOT dropped.
BEGIN;

-- Allow authorized admins to correct legacy category assignments / disable images.
GRANT UPDATE (category, is_active) ON public.dd_photos TO authenticated;
DO $$
BEGIN
 IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public'
                AND tablename='dd_photos' AND policyname='dd_photo_admin_update') THEN
  CREATE POLICY dd_photo_admin_update ON public.dd_photos
   FOR UPDATE TO authenticated
   USING (public.dd_is_admin()) WITH CHECK (public.dd_is_admin());
 END IF;
END $$;

-- The step-2 guard excluded ALL photo-select rooms. Allow SOLO select only;
-- no team-mode transitions before team-round functions are available.
CREATE OR REPLACE FUNCTION public.dd_v4_lobby_guard() RETURNS trigger
LANGUAGE plpgsql SET search_path='' AS $$
BEGIN
 IF old.phase='lobby' AND new.phase<>'lobby'
    AND (old.match_type<>'solo' OR
         (old.photo_mode='random' AND new.phase<>'draw') OR
         (old.photo_mode='select' AND new.phase<>'photo_select')) THEN
   RAISE EXCEPTION '해당 모드의 라운드 진행은 아직 지원하지 않습니다';
 END IF;
 -- Selection must be resolved through guarded RPC before drawing.
 IF old.phase='photo_select' AND new.phase NOT IN ('photo_select','draw') THEN
   RAISE EXCEPTION '사진 선택을 먼저 완료해야 합니다';
 END IF;
 RETURN new;
END $$;

-- Existing solo/random rounds retain their original flow.
-- For solo/select, set the narrator and enter a PRIVATE selection phase.
-- The countdown starts ONLY after a valid photo is confirmed.
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
     deadline=clock_timestamp()+make_interval(secs=>v_room.duration_seconds),
     revision=revision+1 WHERE id=p_room;
 ELSE
   RAISE EXCEPTION '알 수 없는 사진 출제 방식입니다';
 END IF;
END $$;
REVOKE ALL ON FUNCTION public.dd_begin_round(uuid,int) FROM PUBLIC,anon,authenticated;

-- Private photo metadata, returned ONLY to the selected solo narrator.
-- The response contains storage paths for private signed previews; other
-- participants NEVER receive these IDs/titles/paths before reveal.
CREATE OR REPLACE FUNCTION public.dd_v4_photo_options(p_code text) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE r public.dd_rooms%rowtype; v_photos jsonb;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION '로그인이 필요합니다'; END IF;
 SELECT * INTO r FROM public.dd_rooms WHERE code=p_code;
 IF NOT FOUND OR r.match_type<>'solo' OR r.photo_mode<>'select'
    OR r.phase<>'photo_select' OR r.narrator_id IS DISTINCT FROM auth.uid()
    OR NOT EXISTS(SELECT 1 FROM public.dd_players WHERE room_id=r.id AND user_id=auth.uid())
 THEN RAISE EXCEPTION '사진 목록은 현재 설명자만 확인할 수 있습니다'; END IF;
 SELECT coalesce(jsonb_agg(jsonb_build_object(
    'id',id,'name',name,'category',category,'path',storage_path,
    'used',id=ANY(r.used_photo_ids)) ORDER BY (id=ANY(r.used_photo_ids)),name,id),'[]'::jsonb)
 INTO v_photos
 FROM public.dd_photos WHERE is_active=true AND category=ANY(r.allowed_categories);
 RETURN v_photos;
END $$;
REVOKE ALL ON FUNCTION public.dd_v4_photo_options(text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.dd_v4_photo_options(text) TO authenticated;

-- The only way to confirm a photo: locked room + authenticated narrator +
-- approved active category, no countdown manipulation by client.
CREATE OR REPLACE FUNCTION public.dd_v4_choose_photo(p_code text,p_photo_id uuid)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE r public.dd_rooms%rowtype;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION '로그인이 필요합니다'; END IF;
 SELECT * INTO r FROM public.dd_rooms WHERE code=p_code FOR UPDATE;
 IF NOT FOUND OR r.match_type<>'solo' OR r.photo_mode<>'select'
    OR r.phase<>'photo_select' OR r.narrator_id IS DISTINCT FROM auth.uid()
    OR NOT EXISTS(SELECT 1 FROM public.dd_players WHERE room_id=r.id AND user_id=auth.uid())
 THEN RAISE EXCEPTION '현재 라운드 설명자만 사진을 확정할 수 있습니다'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.dd_photos
     WHERE id=p_photo_id AND is_active=true AND category=ANY(r.allowed_categories))
 THEN RAISE EXCEPTION '선택할 수 없는 사진입니다'; END IF;
 UPDATE public.dd_rooms SET photo_id=p_photo_id,phase='draw',
   used_photo_ids=array_append(r.used_photo_ids,p_photo_id),
   deadline=clock_timestamp()+make_interval(secs=>r.duration_seconds),
   revision=revision+1 WHERE id=r.id;
 RETURN true;
END $$;
REVOKE ALL ON FUNCTION public.dd_v4_choose_photo(text,uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.dd_v4_choose_photo(text,uuid) TO authenticated;

-- Private bucket preview permission only for the current narrator DURING
-- selection, for active, allowed-category photos. Existing photo access
-- during draw/judge/result and admin access remain as in v3.
CREATE OR REPLACE FUNCTION public.dd_can_read_photo(p_path text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT public.dd_is_admin() OR EXISTS(
   SELECT 1 FROM public.dd_photos f
   JOIN public.dd_rooms r ON (
     r.photo_id=f.id OR
     (r.phase='photo_select' AND r.photo_mode='select'
      AND r.match_type='solo' AND f.is_active=true
      AND f.category=ANY(r.allowed_categories)))
   JOIN public.dd_players p ON p.room_id=r.id
   WHERE f.storage_path=p_path AND p.user_id=auth.uid()
     AND ((r.phase='photo_select' AND r.narrator_id=auth.uid())
       OR (r.phase IN ('draw','judge') AND r.photo_id=f.id AND r.narrator_id=auth.uid())
       OR (r.phase IN ('result','final') AND r.photo_id=f.id))
 )
$$;
REVOKE ALL ON FUNCTION public.dd_can_read_photo(text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.dd_can_read_photo(text) TO authenticated;
COMMIT;
