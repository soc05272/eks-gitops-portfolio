"""AI 텍스트 요약 API — Claude API 연동 + RDS 이력 저장.

- POST /summaries : 텍스트를 Claude API로 요약하고 이력을 RDS에 저장
- GET  /summaries : 최근 요약 이력 조회
- GET  /healthz   : 쿠버네티스 liveness/readiness 프로브용
"""
import os
from contextlib import asynccontextmanager

import anthropic
import psycopg
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field

DATABASE_URL = os.environ.get("DATABASE_URL", "")
MODEL = os.environ.get("ANTHROPIC_MODEL", "claude-sonnet-5")

SCHEMA = """
CREATE TABLE IF NOT EXISTS summaries (
    id         SERIAL PRIMARY KEY,
    original   TEXT NOT NULL,
    summary    TEXT NOT NULL,
    model      TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
)
"""


@asynccontextmanager
async def lifespan(_: FastAPI):
    with psycopg.connect(DATABASE_URL) as conn:  # 앱 시작 시 테이블 준비
        conn.execute(SCHEMA)
    yield


app = FastAPI(title="AI Text Summarizer", lifespan=lifespan)

# API 키는 ANTHROPIC_API_KEY 환경변수로 주입 (쿠버네티스 Secret → env)
claude = anthropic.Anthropic()


class SummarizeRequest(BaseModel):
    text: str = Field(min_length=10, max_length=20000)


APP_VERSION = "0.2.0"  # GitOps 파이프라인 E2E 검증용 — 배포 확인의 기준값


@app.get("/healthz")
def healthz():
    return {"status": "ok", "version": APP_VERSION}


@app.post("/summaries", status_code=201)
def create_summary(req: SummarizeRequest):
    try:
        message = claude.messages.create(
            model=MODEL,
            max_tokens=1024,
            system="주어진 글의 핵심을 한국어 3문장 이내로 요약하라.",
            messages=[{"role": "user", "content": req.text}],
        )
    except anthropic.APIError as e:
        raise HTTPException(status_code=502, detail=f"Claude API error: {e}")
    summary = message.content[0].text

    with psycopg.connect(DATABASE_URL) as conn:
        row = conn.execute(
            "INSERT INTO summaries (original, summary, model)"
            " VALUES (%s, %s, %s) RETURNING id, created_at",
            (req.text, summary, MODEL),
        ).fetchone()
    return {"id": row[0], "summary": summary, "model": MODEL, "created_at": row[1]}


@app.get("/summaries")
def list_summaries(limit: int = 20):
    with psycopg.connect(DATABASE_URL) as conn:
        rows = conn.execute(
            "SELECT id, left(original, 100), summary, model, created_at"
            " FROM summaries ORDER BY id DESC LIMIT %s",
            (min(limit, 100),),
        ).fetchall()
    return [
        {"id": r[0], "original_preview": r[1], "summary": r[2],
         "model": r[3], "created_at": r[4]}
        for r in rows
    ]
