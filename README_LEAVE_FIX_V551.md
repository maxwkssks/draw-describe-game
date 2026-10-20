# 그려봐! v5.5.1 — 게임 중 방 나가기 수정

## 원인
기존 `dd_action`의 `leave` 분기에서 `phase`가 lobby/final이 아니면 퇴장을 거부했습니다.

## 적용
1. Supabase 운영 DB 백업 및 진행 중인 방 종료.
2. `supabase/011_v5_5_1_leave_during_game.sql` 전체를 SQL Editor에서 **1회 실행**.
3. 이 저장소의 **모든 내용물**을 기존 GitHub 프로젝트에 덮어쓰기.
4. GitHub Desktop → Commit to main → Push origin → Vercel Ready 확인.
5. 브라우저 강력 새로고침.

## 동작
- 어느 단계에서나 서버 RPC `dd_v551_leave_room` 호출.
- 진행 중 이탈 시 **현재 라운드를 전체 취소하고 대기실 복귀**. 방장 자동 승계.
- 완료 라운드의 `dd_team_round_results`, `dd_round_drawings`, `dd_votes`는 유지되도록 과거 투표 FK 분리.
- 이탈자 이름과 점수는 `dd_departed_players`에 보관.
- 이탈 인원의 과거 그림 **결과 카드에서 이름을 표시하는 것은 아직 미구현**(기존 dd_state가 현 참가자 테이블과 INNER JOIN하기 때문). 이탈자가 과거 개인전 점수판에 등장하지 않는 것도 별도 후속 처리 필요.
- 이탈 중이던 라운드의 그림과 평가 기록은 의도적으로 취소됨.
- 다시 참가하려면 새 방 생성/코드 입장. 새로고침만으로 자동 복귀하지 않음.

## 주의
이 SQL은 현재 v5.5 파일의 `dd_rooms`(red_narrator_id/blue_narrator_id/judge_deadline), `dd_players`(last_seen_at) 스키마 전제이며, 운영 DB에서 실행 검증하지 않았음.
