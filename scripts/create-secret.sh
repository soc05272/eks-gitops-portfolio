#!/usr/bin/env bash
# 앱 Secret(summarizer-secrets) 생성 스크립트.
# - DATABASE_URL : terraform.tfvars의 db_password + terraform output의 RDS 엔드포인트로 조립
# - ANTHROPIC_API_KEY : 환경변수로 받거나, 없으면 프롬프트로 입력 (화면에 표시되지 않음)
# 비밀값이 셸 히스토리나 repo에 남지 않도록 하기 위한 스크립트이며, 스크립트 자체에는 비밀값이 없다.
set -euo pipefail

cd "$(dirname "$0")/../terraform"

DB_PASSWORD=$(grep -E '^db_password' terraform.tfvars | sed 's/.*"\(.*\)"/\1/')
RDS_ENDPOINT=$(terraform output -raw rds_endpoint) # host:5432 형태

if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
  read -r -s -p "ANTHROPIC_API_KEY 입력: " ANTHROPIC_API_KEY
  echo
fi

kubectl create secret generic summarizer-secrets \
  --namespace app \
  --from-literal=DATABASE_URL="postgresql://appuser:${DB_PASSWORD}@${RDS_ENDPOINT}/app" \
  --from-literal=ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "✅ secret 'summarizer-secrets' 생성/갱신 완료 (namespace: app)"
