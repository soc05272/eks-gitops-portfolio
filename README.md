# EKS GitOps Portfolio — 온프레미스 솔루션 운영 경험의 클라우드 네이티브 전환

> 솔루션 엔지니어로서 Docker · PostgreSQL · 모니터링을 운영하며 겪은 한계(수동 배포, 수동 장애 대응, 환경 재구축의 어려움)를
> AWS 클라우드 네이티브 방식(IaC + GitOps + 관측성)으로 직접 해결해본 프로젝트입니다.

## 1. 프로젝트 개요

| 항목 | 내용 |
|---|---|
| 목표 | Claude API를 연동한 AI 텍스트 요약 서비스를 EKS 위에 GitOps 방식으로 배포하고, 모니터링/알람까지 구축 |
| 기간 | 2026.08 ~ 2026.09 (5주) |
| 리전 | ap-northeast-2 (서울) |
| 핵심 기술 | Terraform, EKS, RDS(PostgreSQL), GitHub Actions, ArgoCD, Prometheus/Grafana, CloudWatch, Claude API |

### 왜 이 프로젝트인가

- **배포 자동화 부재** → Git push 하나로 빌드부터 배포까지 이어지는 GitOps 파이프라인 구축
- **환경 재구축의 어려움** → Terraform으로 전체 인프라를 코드화하여 20분 내 재구축 가능
- **수동 장애 대응** → Prometheus/Grafana 대시보드 + Slack 알람으로 선제적 감지

## 2. 아키텍처

```
GitHub (app repo) ──push──▶ GitHub Actions ──build/push──▶ ECR
                                   │
                                   └──image tag 업데이트──▶ GitHub (manifest repo)
                                                                │
                                                          ArgoCD (auto sync)
                                                                │
┌─ VPC (10.0.0.0/16) ───────────────────────────────────────────┼──────────┐
│  Public Subnet   : ALB, NAT Gateway(1개)                      ▼          │
│  Private Subnet  : EKS 노드그룹 (t3.medium x2, Spot)  ◀── 배포           │
│                    ├─ App Pods + ALB Ingress                             │
│                    └─ Prometheus / Grafana / ArgoCD                      │
│  DB Subnet       : RDS PostgreSQL (db.t3.micro, Single-AZ)               │
└──────────────────────────────────────────────────────────────────────────┘
        CloudWatch: RDS/NAT 지표 + AWS Budgets 비용 알람
```

### 의도적으로 제외한 것 (과하지 않게)

Istio 등 서비스 메시, 멀티 클러스터, Karpenter — 이 규모에서는 복잡도 대비 이득이 없다고 판단.
상세한 이유는 [docs/adr](docs/adr/)의 의사결정 기록 참고.

## 3. Repo 구조

```
├── terraform/          # 인프라 전체 (VPC, EKS, RDS, ECR)
├── app/                # AI 텍스트 요약 API (FastAPI + Claude API, Dockerfile 포함)
├── .github/workflows/  # CI: 빌드 → ECR 푸시 → manifest repo 태그 업데이트
└── docs/
    ├── adr/            # 의사결정 기록 (Architecture Decision Records)
    └── troubleshooting.md
```

> k8s 매니페스트(Helm/Kustomize)는 GitOps 패턴에 따라 **별도 repo**(`eks-gitops-manifests`)로 분리.
> ArgoCD는 매니페스트 repo만 바라본다.

## 4. 진행 계획

- [x] **1주차 — 인프라 프로비저닝**: Terraform으로 VPC + EKS + RDS + ECR 구축, S3 원격 state
- [x] **2주차 — 앱 배포**: 컨테이너화, kubectl 수동 배포, ALB Ingress Controller 연결
- [x] **3주차 — CI/CD**: GitHub Actions → ECR → ArgoCD auto-sync 파이프라인 완성
- [x] **4주차 — 관측성**: kube-prometheus-stack 설치, Grafana 대시보드, Slack 알람 2종(Pod 재시작, RDS CPU)
- [ ] **5주차 — 문서화**: 트러블슈팅 정리, ADR 보완, 발표자료(PPT)

## 5. 비용 전략

상시 가동 시 월 15~20만 원 예상 (EKS 컨트롤플레인 ~$73 + NAT ~$40 + 노드 + RDS).

- 작업하지 않는 날은 `terraform destroy`, 작업 시 `terraform apply` — **IaC이기에 가능한 운영 방식이며 그 자체가 검증 포인트**
- Terraform state는 S3 백엔드에 보관하여 destroy/apply 반복에도 안전
- EKS 노드는 Spot 인스턴스, NAT Gateway는 단일 AZ 1개
- AWS Budgets 월 5만 원 초과 알람 설정

## 6. 트러블슈팅 & 의사결정

- [트러블슈팅 기록](docs/troubleshooting.md)
- [ADR-001: 배포 도구로 ArgoCD를 선택한 이유](docs/adr/001-why-argocd.md)
- [ADR-002: 클러스터 내 PostgreSQL 대신 RDS를 선택한 이유](docs/adr/002-why-rds.md)
- [ADR-003: NAT Gateway를 단일 AZ 1개로 구성한 이유](docs/adr/003-single-nat.md)
