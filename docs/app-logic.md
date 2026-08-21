# 애플리케이션 로직 정리 — AI 텍스트 요약 API

> `app/app.py` 하나(약 90줄), 엔드포인트 3개. 이 프로젝트에서 앱은 화려함이 아니라
> **인프라 전체를 관통하며 검증하는 최소 단위**로 설계했다.

## 전체 구조

```
[시작 시]  lifespan → RDS에 summaries 테이블 자동 생성
[운영 중]  GET  /healthz    → 생존 신고 (쿠버네티스 프로브용)
          POST /summaries  → 텍스트 수신 → Claude 요약 → RDS 저장 → 응답
          GET  /summaries  → RDS에서 최근 요약 이력 조회
```

## 1. 설정 — 전부 환경변수에서 읽는다

```python
DATABASE_URL = os.environ.get("DATABASE_URL", "")             # RDS 접속 주소
MODEL = os.environ.get("ANTHROPIC_MODEL", "claude-sonnet-5")  # 모델명 (기본값 있음)
claude = anthropic.Anthropic()  # ANTHROPIC_API_KEY 환경변수를 SDK가 자동 인식
```

- 코드에 비밀값이 하나도 없다. 실제 값은 쿠버네티스 **Secret**(`summarizer-secrets`)이
  파드 시작 시 환경변수로 주입한다 — "설정과 코드의 분리" 패턴
- 이 구조 덕분에 코드를 공개 repo에 올릴 수 있다

## 2. 시작 로직 — lifespan에서 테이블 준비

```python
@asynccontextmanager
async def lifespan(_: FastAPI):
    with psycopg.connect(DATABASE_URL) as conn:
        conn.execute(SCHEMA)   # CREATE TABLE IF NOT EXISTS summaries ...
    yield
```

- 앱 기동 시 `summaries` 테이블(id, original, summary, model, created_at)을 생성.
  `IF NOT EXISTS`라 멱등 — 여러 번 떠도 안전하고, 별도 마이그레이션 도구가 필요 없다
- **부수 효과**: 이 단계가 실패하면 앱이 안 뜨고 readiness 프로브도 실패한다.
  즉 "파드가 Ready = RDS 연결까지 정상"이라는 검증이 공짜로 따라온다

## 3. GET /healthz — 쿠버네티스와의 계약

```python
return {"status": "ok", "version": APP_VERSION}
```

- 쿠버네티스가 주기적으로 호출해 파드 생사를 판단 (liveness/readiness 프로브)
- `version` 필드는 GitOps 배포 검증용 — 새 버전 배포 후 인터넷에서 curl 한 줄로
  "실제로 새 코드가 나가고 있는지" 확인한다 (0.2.0 → 0.2.1 전환을 이걸로 실증)

## 4. POST /summaries — 핵심 로직

요청: `{"text": "요약할 글..."}` — Pydantic이 10~20,000자 검증, 벗어나면 422 자동 반환

```
① Claude API 호출
   model=MODEL, max_tokens=1024
   system="주어진 글의 핵심을 한국어 3문장 이내로 요약하라."
   실패 시 → HTTPException 502 ("Claude API error")로 변환

② RDS 저장
   INSERT INTO summaries (original, summary, model)
   VALUES (%s, %s, %s) RETURNING id, created_at

③ 응답
   {"id": 1, "summary": "...", "model": "claude-sonnet-5", "created_at": "..."}
```

네트워크 관점에서 이 한 요청이 인프라 전체를 관통한다:

```
인터넷 → ALB → 파드 → (NAT 게이트웨이) → Claude API
                 └──── (프라이빗 경로) ──→ RDS
```

그래서 **이 엔드포인트의 성공 = 시스템 E2E 검증**이다.

## 5. GET /summaries — 이력 조회

```sql
SELECT id, left(original, 100), summary, model, created_at
FROM summaries ORDER BY id DESC LIMIT %s   -- limit 파라미터, 최대 100 캡
```

- 원문은 100자 미리보기로 잘라 응답 비대화를 방지
- 모든 SQL은 `%s` 파라미터 바인딩 — SQL 인젝션 원천 차단

## 면접 대비 포인트

**Q. 왜 이렇게 단순한가?**
의도적 설계. 평가 대상은 앱이 아니라 인프라·배포·운영이고, 앱은 그것을 관통하며
검증하는 최소 단위다. 대신 클라우드 네이티브 규약은 전부 지켰다:

- **stateless** — 상태는 전부 RDS에, 파드는 언제 죽어도 되는 소모품
- **Secret 주입** — 비밀값은 코드·이미지·repo 어디에도 없음
- **프로브 계약** — healthz로 쿠버네티스의 자가 치유와 협력
- **non-root 실행** — Dockerfile USER + 매니페스트 runAsUser 1000

**Q. 알려진 한계는?** (worklog 백로그에 기록)
인증 없음 · 테스트 코드 없음(CI에 테스트 단계 없음) · 요약 프롬프트 고정.
"다음에 뭘 개선할 건가"에 대한 답을 미리 가지고 있다.
