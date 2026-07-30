# SEMI 밸류체인 대시보드

국내 반도체 밸류체인(장비 · 소재 · 부품 · OSAT · 팹리스) peer table.
매일 장 마감(15:30) 기준 **시세 · 수익률 · Valuation · 수급**을 자동 트래킹한다.

라이브: 정적 페이지 — 화면(`index.html`/`app.js`/`styles.css`)은 `data.json` **하나만** 읽는다.
파이프라인이 매일 `data.json`을 덮어쓰면 화면은 그대로 최신 데이터를 보여준다. (HTML 재생성 없음)

---

## 파일 구조

| 파일 | 역할 |
|------|------|
| `index.html` / `app.js` / `styles.css` | 화면. `data.json`을 fetch해 밸류체인 탭별 테이블 렌더 |
| `data.json` | **단일 데이터 소스** (파이프라인이 매일 갱신) |
| `peer-config.json` | 종목 로스터 (세그먼트 · 종목코드). 종목 추가·삭제는 여기만 편집 |
| `fetch-semi.ps1` | 수집: Yahoo(시세·1W/1M/YTD) + Naver(시총·PER·PBR·선행 + 수급) → `data.json` |
| `refresh.ps1` | 수집 오케스트레이터 (fetch 스크립트 호출) |
| `deploy.ps1` | pull → refresh → `data.json` commit+push → Cloudflare 자동 배포 |
| `serve.ps1` | 로컬 정적 서버 (http://localhost:8090) |
| `wrangler.toml` | Cloudflare Pages 정적 배포 설정 |

## 컬럼

- **기본**: 시총(억) · 종가
- **수익률(%)**: 1W · 1M · YTD
- **Valuation**: PER(TTM) · PBR · fPER(선행 FY1) · fPBR
- **수급**: 외국인 지분율(%) · 외국인 5D 순매수(억) · 기관 5D 순매수(억) · 거래대금(억) · 회전율(%)

> 순매수는 최근 5거래일 누적, 종가 기준 환산(억원). 거래대금·회전율은 당일.
> EPS 성장·ROE·27F 컨센서스는 daily 소스(Naver)에 없어 **주간 보강(FnGuide)** 으로 추가 예정 → `fetch-consensus.ps1`.

---

## 로컬에서 보기

```powershell
# 1) 데이터 수집 (최초 1회 또는 수동 갱신)
powershell -ExecutionPolicy Bypass -File .\fetch-semi.ps1

# 2) 서버 실행 → 브라우저 자동 오픈
powershell -ExecutionPolicy Bypass -File .\serve.ps1
```

## 매일 자동 실행 (15:30 KST)

작업 스케줄러에 `deploy.ps1`을 매일 15:30에 등록:

```powershell
schtasks /Create /TN "SemiDashboard-Daily" /SC DAILY /ST 15:30 ^
  /TR "powershell -NoProfile -ExecutionPolicy Bypass -File \"C:\Users\배미나\code\semi-dashboard\deploy.ps1\"" /F
```

- 해제: `schtasks /Delete /TN "SemiDashboard-Daily" /F`
- PC가 켜져 있어야 실행됨.

## 외부 공유 (Cloudflare Pages)

`reverent-dashboard`와 동일 패턴 — **git push → Cloudflare 자동 빌드**.

최초 1회 설정 (사용자 계정에서):
1. 이 폴더를 GitHub 저장소로 push (`git init`은 완료됨 → remote 추가 후 push).
2. Cloudflare Pages에서 **Connect to Git** → 이 저장소 선택 → 빌드 명령 없음(정적), 출력 디렉터리 `/`.
3. 배포되면 `https://semi-dashboard.pages.dev` 형태 URL. 커스텀 도메인은 Pages 설정에서 연결.
4. 이후 `deploy.ps1`이 매일 `data.json`만 push → 1~2분 후 자동 반영.

접근 제어(팀 전용)가 필요하면 Cloudflare Access(이메일 화이트리스트)를 Pages 프로젝트에 건다.

---

## 종목 편집

`peer-config.json`의 `tickers` 배열만 편집한다 (코드 수정 불필요).
`verify: true`가 붙은 종목은 종목코드 재확인 권장. `market`은 `KS`(KOSPI)/`KQ`(KOSDAQ).
