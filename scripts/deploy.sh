#!/usr/bin/env bash
# k8s 매니페스트의 <AWS-ACCOUNT-ID>, <ALLOWED-CIDR> 플레이스홀더를 실제 값으로 치환해 적용한다.
# versions.tf의 부분 백엔드 구성과 같은 이유 — 계정 고유 값을 공개 repo에 두지 않는다.
set -euo pipefail

cd "$(dirname "$0")/.."

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# ALB 인바운드 허용 CIDR. 지정하지 않으면 현재 공인 IP 하나만 허용한다.
#   ALLOWED_CIDR="1.2.3.4/32,5.6.7.8/32" ./scripts/deploy.sh   # 여러 개는 쉼표로
ALLOWED_CIDR="${ALLOWED_CIDR:-$(curl -fsS https://checkip.amazonaws.com)/32}"

# namespace를 먼저 적용해야 한다 — 알파벳순으로 합치면 deployment가 namespace보다
# 먼저 스트림에 실려 새 클러스터에서 "namespaces not found"로 실패한다.
# (중복 포함은 무해: kubectl apply는 멱등이라 두 번째는 unchanged로 처리)
for f in k8s/namespace.yaml k8s/*.yaml; do
  sed -e "s/<AWS-ACCOUNT-ID>/${ACCOUNT_ID}/g" -e "s#<ALLOWED-CIDR>#${ALLOWED_CIDR}#g" "$f"
  echo "---"
done | kubectl apply -f -
