# ADR-002: 클러스터 내 PostgreSQL 대신 RDS를 선택한 이유

- 상태: 승인
- 날짜: 2026-07-24

## 배경

앱은 PostgreSQL 필요. EKS 안에 StatefulSet으로 띄울지, RDS 관리형 서비스를 쓸지 결정 필요.

## 선택지

1. **클러스터 내 PostgreSQL (StatefulSet + EBS PV)** — 비용이 저렴하고 노드 리소스를 재활용. 그러나 백업/패치/장애조치를 직접 구현해야 하며, `terraform destroy` 시 데이터 수명 관리가 복잡해진다.
2. **RDS PostgreSQL (db.t3.micro, Single-AZ)** — 백업·패치·모니터링(CloudWatch 지표)이 관리형으로 제공. 월 약 $15의 추가 비용.

## 결정

**RDS 선택.**

- 상태를 가진 워크로드(DB)와 상태 없는 워크로드(앱)를 분리하는 것이 프로덕션 표준 패턴
- 솔루션 엔지니어로서 온프레미스 PostgreSQL을 직접 운영(백업, 튜닝)해본 경험이 있어, 그 운영 부담이 관리형 서비스로 어떻게 흡수되는지 비교·검증하는 것이 이 프로젝트의 학습 목표 중 하나
- destroy/apply 반복 운영을 위해 스냅샷 기반 복원 절차를 함께 문서화

## 트레이드오프

- 비용 증가 (약 $15/월) → Single-AZ + micro 인스턴스로 최소화
- Multi-AZ 미적용으로 고가용성은 없음 → 포트폴리오 목적상 허용, README에 프로덕션이라면 Multi-AZ가 필요함을 명시
