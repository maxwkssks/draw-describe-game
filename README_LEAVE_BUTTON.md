# v5.1 눈에 띄는 방 나가기 버튼

- 방에 입장하면 모든 단계에서 우측 하단에 빨간색 `🚪 방 나가기` 버튼 표시
- 클릭 시 확인창을 띄운 뒤 Supabase `leave` 액션 호출
- 방장이 나가면 기존 v5.1의 방장 권한 이전 규칙 적용
- 로비에서부터 결과 화면까지 같은 위치에 표시됨
- 키보드 `Ctrl + Shift + E` 기존 기능 유지

## 적용 방법
1. 기존 v5.1이 정상 설치됐다면 `public/index.html`, `public/styles.css` 두 파일만 GitHub 저장소에서 교체하세요.
2. GitHub Desktop에서 Commit -> Push Origin 후 Vercel Ready 확인.
3. 웹사이트 강력 새로고침 (`Ctrl + Shift + R`).
4. 게임 방에서 우측 하단 나가기 버튼 클릭 -> 확인창 -> 메인화면 이동을 확인하세요.

신규 SQL은 필요하지 않습니다. 단, 기존 v5.1의 `008_v5_host_presence.sql`은 별도 설치되어 있어야 합니다.
