-- Draw & Describe v5.1: host departure recovery and heartbeat presence.
-- Apply AFTER 007_v5_unlimited_mode.sql. Existing rooms, images and scores are preserved.
BEGIN;
ALTER TABLE public.dd_players ADD COLUMN IF NOT EXISTS last_seen_at timestamptz;
-- Old players are presumed connected briefly upon migration; the next heartbeat refreshes this.
UPDATE public.dd_players SET last_seen_at=clock_timestamp() WHERE last_seen_at IS NULL;
ALTER TABLE public.dd_players ALTER COLUMN last_seen_at SET DEFAULT clock_timestamp();
CREATE INDEX IF NOT EXISTS dd_players_room_presence_idx ON public.dd_players(room_id,last_seen_at DESC);

-- Called by a logged-in member every ~7 seconds; never trusts a client-provided timestamp or host ID.
CREATE OR REPLACE FUNCTION public.dd_v5_presence_ping(p_code text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE r public.dd_rooms%rowtype; v_now timestamptz:=clock_timestamp(); v_new_host uuid;
        v_players jsonb;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION '로그인이 필요합니다'; END IF;
 SELECT * INTO r FROM public.dd_rooms WHERE code=p_code FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION '방을 찾을 수 없습니다'; END IF;
 UPDATE public.dd_players SET last_seen_at=v_now
 WHERE room_id=r.id AND user_id=auth.uid();
 IF NOT FOUND THEN RAISE EXCEPTION '이 방의 참가자가 아닙니다'; END IF;

 -- Host session missing for >45 seconds: only another currently active room member can take over.
 IF NOT EXISTS (
    SELECT 1 FROM public.dd_players
    WHERE room_id=r.id AND user_id=r.host_id AND last_seen_at>v_now-interval '45 seconds'
 ) THEN
   SELECT user_id INTO v_new_host FROM public.dd_players
   WHERE room_id=r.id AND user_id<>r.host_id
     AND last_seen_at>v_now-interval '20 seconds'
   ORDER BY joined_at,user_id LIMIT 1;
   IF v_new_host IS NOT NULL THEN
      UPDATE public.dd_rooms SET host_id=v_new_host,revision=revision+1 WHERE id=r.id;
      r.host_id:=v_new_host;
      -- The new host starts ready in the waiting room.
      IF r.phase='lobby' THEN
        UPDATE public.dd_players SET ready=true WHERE room_id=r.id AND user_id=v_new_host;
      END IF;
   END IF;
 END IF;
 SELECT coalesce(jsonb_agg(jsonb_build_object(
   'id',user_id::text,'online',last_seen_at>v_now-interval '20 seconds'
 ) ORDER BY joined_at,user_id),'[]'::jsonb)
 INTO v_players FROM public.dd_players WHERE room_id=r.id;
 RETURN jsonb_build_object('hostId',r.host_id::text,'players',v_players,
    'hostOnline',EXISTS(SELECT 1 FROM public.dd_players
      WHERE room_id=r.id AND user_id=r.host_id AND last_seen_at>v_now-interval '20 seconds'),
    'hostRecoverySeconds',45);
END $$;
REVOKE ALL ON FUNCTION public.dd_v5_presence_ping(text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.dd_v5_presence_ping(text) TO authenticated;

-- Recovery exits an abandoned round and returns players to the waiting room.
-- No previously completed round scores are reset. Only the current unfinished drawings are discarded.
CREATE OR REPLACE FUNCTION public.dd_v4_lobby_guard() RETURNS trigger
LANGUAGE plpgsql SET search_path='' AS $$
BEGIN
 IF old.phase IN ('photo_select','draw','judge','vote') AND new.phase='lobby'
   AND new.narrator_id IS NULL AND new.photo_id IS NULL AND new.deadline IS NULL THEN
   RETURN new; -- only SECURITY DEFINER RPCs can write these RLS-protected rows
 END IF;
 IF old.phase='lobby' AND new.phase<>'lobby' THEN
   IF old.match_type='solo' AND
      ((old.photo_mode='random' AND new.phase<>'draw') OR
       (old.photo_mode='select' AND new.phase<>'photo_select')) THEN
      RAISE EXCEPTION '개인전 시작 단계가 올바르지 않습니다'; END IF;
   IF old.match_type='team' AND
      ((old.photo_mode='random' AND new.phase<>'draw') OR
       (old.photo_mode='select' AND new.phase<>'photo_select')) THEN
      RAISE EXCEPTION '팀전 시작 단계가 올바르지 않습니다'; END IF;
 END IF;
 IF old.phase='photo_select' AND new.phase NOT IN ('photo_select','draw') THEN
   RAISE EXCEPTION '사진 확정을 먼저 완료하세요'; END IF;
 IF old.match_type='team' AND old.phase='draw' AND new.phase NOT IN ('draw','vote') THEN
   RAISE EXCEPTION '팀전의 다음 단계는 블라인드 평가입니다'; END IF;
 RETURN new;
END $$;

CREATE OR REPLACE FUNCTION public.dd_v5_reset_stuck_round(p_code text)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE r public.dd_rooms%rowtype;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION '로그인이 필요합니다'; END IF;
 SELECT * INTO r FROM public.dd_rooms WHERE code=p_code FOR UPDATE;
 IF NOT FOUND OR r.host_id<>auth.uid() OR r.phase NOT IN ('photo_select','draw','judge','vote')
 THEN RAISE EXCEPTION '현재 방장만 진행 중인 라운드를 취소할 수 있습니다'; END IF;
 -- Drop only incomplete-round snapshots; earlier scored rounds are untouched.
 DELETE FROM public.dd_round_drawings WHERE room_id=r.id AND round_no=r.round_no;
 UPDATE public.dd_players SET submitted=false,placement=null,strokes='[]'::jsonb,
   ready=(user_id=r.host_id) WHERE room_id=r.id;
 UPDATE public.dd_rooms SET phase='lobby',round_no=greatest(0,r.round_no-1),
   narrator_id=NULL,red_narrator_id=NULL,blue_narrator_id=NULL,
   photo_id=NULL,deadline=NULL,revision=revision+1 WHERE id=r.id;
 RETURN true;
END $$;
REVOKE ALL ON FUNCTION public.dd_v5_reset_stuck_round(text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.dd_v5_reset_stuck_round(text) TO authenticated;

-- Optional manual cleanup for a verified photo administrator; not exposed to ordinary players.
-- Only deletes rooms with no heartbeat for >6h, or rooms with no participants.
CREATE OR REPLACE FUNCTION public.dd_v5_cleanup_inactive_rooms()
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_count integer;
BEGIN
 IF NOT public.dd_is_admin() THEN RAISE EXCEPTION '관리자만 실행할 수 있습니다'; END IF;
 WITH removed AS (
    DELETE FROM public.dd_rooms r
    WHERE NOT EXISTS (SELECT 1 FROM public.dd_players p
      WHERE p.room_id=r.id AND p.last_seen_at>clock_timestamp()-interval '6 hours')
    RETURNING id
 ) SELECT count(*) INTO v_count FROM removed;
 RETURN v_count;
END $$;
REVOKE ALL ON FUNCTION public.dd_v5_cleanup_inactive_rooms() FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.dd_v5_cleanup_inactive_rooms() TO authenticated;
COMMIT;
