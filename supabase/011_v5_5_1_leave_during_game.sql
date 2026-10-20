-- v5.5.1: voluntary leave at ANY phase; keep round history, restore lobby safely.
-- Apply AFTER 009, 010, 008; backup production before applying.
BEGIN;

-- Archive identity and earned score prior to removal (for later historical result views).
CREATE TABLE IF NOT EXISTS public.dd_departed_players (
  room_id uuid NOT NULL REFERENCES public.dd_rooms(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users(id),
  name text NOT NULL,
  team_code text,
  score integer NOT NULL DEFAULT 0,
  left_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY(room_id,user_id)
);
ALTER TABLE public.dd_departed_players ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.dd_departed_players FROM PUBLIC,anon,authenticated;

-- Earlier votes must not cascade away when a voter voluntarily leaves.
-- The existing assignment already references auth.users via voter_id; detach only
-- its redundant composite reference to the active room member list.
DO $fix$
DECLARE c record;
BEGIN
  FOR c IN SELECT conname FROM pg_constraint
    WHERE conrelid='public.dd_vote_assignments'::regclass
      AND contype='f' AND confrelid='public.dd_players'::regclass
  LOOP
    EXECUTE format('ALTER TABLE public.dd_vote_assignments DROP CONSTRAINT %I',c.conname);
  END LOOP;
END $fix$;

CREATE OR REPLACE FUNCTION public.dd_v551_leave_room(p_code text)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $fn$
DECLARE r public.dd_rooms%rowtype; me public.dd_players%rowtype;
        new_host uuid; remaining int;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION '로그인이 필요합니다'; END IF;
 SELECT * INTO r FROM public.dd_rooms WHERE code=p_code FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION '방을 찾을 수 없습니다'; END IF;
 SELECT * INTO me FROM public.dd_players WHERE room_id=r.id AND user_id=auth.uid() FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION '이미 퇴장한 참가자입니다'; END IF;

 SELECT count(*) INTO remaining FROM public.dd_players
 WHERE room_id=r.id AND user_id<>auth.uid();
 IF remaining=0 THEN
    DELETE FROM public.dd_rooms WHERE id=r.id;
    RETURN true;
 END IF;

 SELECT user_id INTO new_host FROM public.dd_players
 WHERE room_id=r.id AND user_id<>auth.uid()
 ORDER BY CASE WHEN last_seen_at>clock_timestamp()-interval '20 seconds' THEN 0 ELSE 1 END,
          joined_at,user_id LIMIT 1;

 -- Server policy: departure mid-round cancels the current unfinished round for
 -- everyone. This avoids impossible ballots / absent narrator / odd team sizes.
 -- Completed rounds and their scores remain intact.
 IF r.phase IN ('photo_select','draw','judge','vote') THEN
    DELETE FROM public.dd_round_drawings WHERE room_id=r.id AND round_no=r.round_no;
    UPDATE public.dd_players SET submitted=false,placement=null,
      strokes='[]'::jsonb,ready=(user_id=new_host) WHERE room_id=r.id;
    UPDATE public.dd_rooms SET phase='lobby',round_no=greatest(0,r.round_no-1),
      narrator_id=NULL,red_narrator_id=NULL,blue_narrator_id=NULL,
      photo_id=NULL,deadline=NULL,judge_deadline=NULL,revision=revision+1
    WHERE id=r.id;
 END IF;

 INSERT INTO public.dd_departed_players(room_id,user_id,name,team_code,score)
 VALUES(r.id,me.user_id,me.name,me.team_code,me.score)
 ON CONFLICT(room_id,user_id) DO UPDATE SET name=EXCLUDED.name,
    team_code=EXCLUDED.team_code,score=EXCLUDED.score,left_at=clock_timestamp();

 DELETE FROM public.dd_players WHERE room_id=r.id AND user_id=auth.uid();
 UPDATE public.dd_rooms SET host_id=CASE WHEN r.host_id=auth.uid() THEN new_host ELSE host_id END,
   revision=revision+1 WHERE id=r.id;
 RETURN true;
END $fn$;
REVOKE ALL ON FUNCTION public.dd_v551_leave_room(text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.dd_v551_leave_room(text) TO authenticated;
COMMIT;
