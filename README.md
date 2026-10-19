# 그려봐! — 온라인 웹사이트 v3.0

**사용자 설치 불필요.** Vercel에서 정적 웹사이트를 호스팅하고 Supabase Auth / PostgreSQL / Storage로 실제 멀티플레이를 운영합니다. Discord는 음성 설명 용도로 따로 사용합니다.

## 확정 규칙

- 방 생성 및 6자리 코드 입장, 2~20명, 1~10라운드
- 2분 / 3분 / 5분, 설명자 중복 최소화 순환 (각 라운드 한 명)
- 설명자에게만 원본 사진 공개, 참가자 개인 그림판, 약 1.4초 상태 폴링
- 설명자가 익명 그림 1등(100점) / 2등(70점) / 3등(50점)을 직접 선정
- 참가자 수가 2명 또는 3명일 때는 가능한 순위 수만 선정
- 게임 최종 결과 및 누적 점수
- 관리자 이메일 로그인 후 사진 업로드 (5MB 이하 JPG/PNG/WEBP), 비공개 사진 버킷

## 필수 1 — Supabase 프로젝트 준비

1. https://supabase.com 에서 새 프로젝트를 만듭니다.
2. **Authentication → Providers → Anonymous Sign-ins**를 켭니다. 참가자는 로그인 화면 없이 익명 인증됩니다.
3. **SQL Editor → New Query**에서 `supabase/schema.sql` 전체를 실행합니다. **새 프로젝트에 한 번 실행**하는 용도입니다. 이미 같은 이름의 정책이 있으면 중복 실행 시 오류가 날 수 있습니다.
4. **Authentication → Users → Add user**에서 관리자의 이메일 계정과 비밀번호를 만듭니다.
5. 관리자 계정이 생성되면 SQL Editor에서 다음 명령을 실행해 관리자 권한을 부여합니다. 아래 이메일을 반드시 본인 이메일로 바꾸세요.

   ```sql
   insert into public.dd_admins(user_id)
   select id from auth.users where email = 'YOUR_ADMIN_EMAIL@example.com'
   on conflict do nothing;
   ```

6. **Project Settings → API** (화면 구성에 따라 `Connect` 또는 `API Keys`)에서 Project URL과 **publishable/anon 키**를 확인합니다.

> `service_role` / `secret` 키를 브라우저나 Vercel 공개 변수에 절대로 넣지 마세요. 공개용 anon/publishable 키만 씁니다. 표준 RLS 정책과 서버측 RPC가 데이터 접근을 제한합니다.

## 필수 2 — Vercel에 웹사이트 배포

1. 이 프로젝트의 파일들을 GitHub 새 저장소에 올립니다. (프로젝트 루트에 package.json, public/, supabase/가 있어야 합니다.)
2. https://vercel.com 에서 **Add New → Project → Import**로 저장소를 선택합니다.
3. **Environment Variables**에 다음 두 항목을 등록합니다.

   - `SUPABASE_URL` = `https://xxxx.supabase.co`
   - `SUPABASE_ANON_KEY` = Supabase `publishable` 또는 `anon` 키

4. **Deploy**를 누르면 Vercel이 `npm run build`를 실행해서 `dist/`를 만들고 사이트를 배포합니다.
5. 발급된 `https://프로젝트이름.vercel.app` 사이트에서 **방 만들기**와 **코드로 입장하기**를 사용합니다.
6. 사진을 올리려면 `https://프로젝트이름.vercel.app/admin.html`에 접속해 관리자 이메일로 로그인합니다.

## 로컬 테스트 (Node.js 20 이상)

```bash
# Windows PowerShell
$env:SUPABASE_URL="https://YOUR-PROJECT.supabase.co"
$env:SUPABASE_ANON_KEY="YOUR-PUBLISHABLE-OR-ANON-KEY"
npm run build
npm run preview
```

브라우저 `http://localhost:3000` 접속. 서로 다른 유저를 시뮬레이션하려면 일반 창과 시크릿 창을 이용합니다. 같은 브라우저 프로필의 두 탭은 익명 인증 ID를 공유하므로 **두 명으로 인식되지 않습니다**.

## 진행 중 유의점

- 인터넷 실서비스 주소는 이 ZIP만으로 만들어지지 않습니다. 반드시 본인 Supabase 및 Vercel 프로젝트 연결/배포가 필요합니다.
- 방·점수·그림 데이터는 PostgreSQL에 보존됩니다. 파일 서버를 켜둘 필요는 없습니다.
- 저장 상태는 약 1.4초 간격으로 확인하며, Canvas 그림은 선을 그릴 때마다 서버에 저장합니다. 매우 많은 선을 그리면 그림 데이터 150KB 제한에 도달할 수 있습니다.
- 사진 링크는 private Storage의 제한시간이 있는 signed URL을 사용하며, 원본 경로는 설명자에게만 공개됩니다(심사 이후 결과 화면에서는 참가자 모두 볼 수 있습니다). 화면 공유/개발자 도구를 사용하는 설명자가 원본을 유출하는 것까지 기술적으로 막을 수는 없습니다.
- 게임 도중 신규 참가·임의 퇴장은 지원하지 않습니다. 새로고침으로 동일한 브라우저에 복귀할 수 있습니다.
- 참가자 접속 상태는 별도의 Presence/WebSocket이 아니라 현재 등록 인원 기반입니다. 플레이어별 실시간 온라인/오프라인 감지는 후속 작업입니다.
- 첫 버전에서는 매 라운드 작성자 익명 심사를 지원하지만, 친구들 사이에서 그림 스타일로 작성자를 추측할 수는 있습니다.
- 개인정보 및 장기 운영을 위해 **휴면 방 자동 삭제, 오래된 그림 정리, 악용 방지 속도 제한, 운영자 신고/차단** 기능을 배포 뒤 추가하는 것이 권장됩니다.
- **20명 부하 테스트는 아직 진행하지 않았습니다.** 소규모 실제 접속 검증을 먼저 하고 확대하세요.

## 파일 구성

```text
public/index.html      게임 화면
public/app.js          게임 UI + Supabase 연결
public/styles.css      스타일
public/admin.html      관리자 전용 사진 관리 화면
public/admin.js        사진 업로드 및 관리자 인증
public/config.js       개발용 공개 환경설정 자리표시자
supabase/schema.sql    테이블, 권한, RPC, private Storage 정책
scripts/build.mjs      Vercel 빌드, 환경변수 주입
scripts/preview.mjs    로컬 미리보기 서버
vercel.json            Vercel 설정
```

## 검증 범위

`npm test` = 정적 프로젝트 검사. `node --check public/app.js`는 JS 문법 검사입니다. 실제 Supabase API 접근 및 여러 사용자 실접속 테스트는 **본인 프로젝트 키를 연결한 이후**에 실행해야 합니다.
