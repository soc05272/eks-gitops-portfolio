# 기술스택 정리 — 무엇을, 왜, 어떻게 썼는가

> 나열이 아니라 **"이 프로젝트에서 실제로 어떻게 사용했고 무엇을 배웠는지"** 기준으로 정리.
> 면접에서 "○○ 써보셨어요?"라는 질문에 대한 답의 원본이다.

---

## 1. 클라우드 — AWS (ap-northeast-2)

| 서비스 | 이 프로젝트에서의 역할 | 핵심 포인트 |
|---|---|---|
| **VPC** | 10.0.0.0/16, 2AZ, Public/Private/DB 3계층 서브넷 | 상태(stateful)·무상태(stateless) 워크로드를 네트워크 수준에서 분리. ALB 자동 탐색용 서브넷 태그(`kubernetes.io/role/elb`)를 코드로 명시 |
| **EKS** | 쿠버네티스 1.31 관리형 컨트롤플레인 + 관리형 노드그룹(t3.medium Spot ×2) | 컨트롤플레인 운영을 AWS에 위임. Spot 노드로 비용 70%↓ — 파드가 stateless라서 가능한 선택 |
| **RDS** | PostgreSQL 17, db.t3.micro, Single-AZ | 백업·패치·장애조치를 관리형에 위임. 보안그룹은 CIDR이 아닌 **노드 SG 참조 방식**으로 5432만 허용. 버전은 현업에서 운영 중인 솔루션 DB와 동일하게 맞춤 |
| **ECR** | 컨테이너 이미지 저장소 | IMMUTABLE 태그(태그=커밋 SHA, 코드-이미지 1:1), scan on push, 수명주기 정책(최근 10개 유지) |
| **ALB** | internet-facing 진입점 | 콘솔에서 만들지 않음 — **AWS Load Balancer Controller가 Ingress 선언을 보고 자동 생성**. `target-type: ip`로 파드 IP 직접 라우팅 |
| **NAT Gateway** | 프라이빗 서브넷의 아웃바운드(ECR pull, Claude API 호출) | 비용 최적화로 단일 AZ 1개 (ADR-003). 파드의 공인 IP가 NAT EIP와 일치함을 E2E로 검증 |
| **IAM — OIDC** | GitHub Actions의 AWS 인증 | **액세스 키를 GitHub에 저장하지 않는** 키리스 인증. sub 클레임 신형식(@ID) 이슈를 CloudTrail로 디버깅한 것이 대표 트러블슈팅 |
| **IAM — IRSA** | 파드 단위 권한 부여 (4종: ALB Controller, EBS CSI, cloudwatch-exporter 등) | 노드 Role에 권한을 얹으면 모든 파드가 물려받는 문제를 회피 — **ServiceAccount 단위 최소 권한** |
| **CloudWatch** | RDS 지표 원천 | cloudwatch-exporter로 Prometheus에 유입시켜 **알람 경로를 Prometheus 하나로 단일화**. 타임스탬프 함정(`set_timestamp: false`) 트러블슈팅 |
| **S3** | Terraform 원격 state 저장 | 버전 관리 + 퍼블릭 차단. destroy/apply 반복 운영의 전제 조건 |

## 2. IaC — Terraform (v1.15)

- **리소스 78개**를 코드로 정의: VPC/EKS/RDS는 커뮤니티 모듈(terraform-aws-modules), IRSA·OIDC Role·ECR·보안그룹은 직접 작성
- **S3 원격 backend + 부분 백엔드 구성**(`backend.hcl` 분리) — 계정 ID를 공개 repo에 노출하지 않기 위한 설계
- **sensitive 변수**(`db_password`)는 tfvars(gitignore)로 주입, plan 파일에도 평문으로 들어가는 것을 인지하고 `tfplan`도 gitignore
- destroy/apply를 **7회 이상 반복**하며 재현성 실증 — "20분 내 전체 환경 복원"
- 배운 것: 커뮤니티 모듈을 그대로 믿으면 안 되는 경우(OIDC sub 형식) — 인증 경계는 산출물을 직접 확인

## 3. 컨테이너 — Docker

- python:3.12-slim 기반 멀티 아키텍처 함정 경험: **Apple Silicon(arm64)에서 `--platform linux/amd64` 명시** 없이 빌드하면 x86 노드에서 `exec format error`
- non-root 실행(`USER appuser`) — 이름 기반 USER와 `runAsNonRoot`의 검증 불가 조합 트러블슈팅 → UID 숫자 명시로 해결
- slim 이미지에는 `kill` 같은 기본 바이너리도 없다는 것을 알람 테스트에서 체감(셸 내장으로 우회)

## 4. 오케스트레이션 — Kubernetes (EKS 1.31)

실제 사용한 오브젝트/개념과 이유:

- **Deployment + 롤링 업데이트**: 무중단 배포. `rollout 성공 ≠ LB 무중단`(readiness gate 필요)까지 검증에서 확인
- **Secret / ConfigMap**: 비밀값(DB 접속정보·API 키)은 Secret으로 환경변수 주입 — 코드·이미지·repo에 비밀값 0. base64는 암호화가 아니라는 한계 인지
- **liveness/readiness 프로브**: `/healthz` 계약. 앱 시작 시 DB 연결·테이블 생성이 성공해야 Ready가 되도록 설계해 "Ready = RDS까지 정상"을 공짜로 검증
- **Ingress**: ALB Controller가 선언을 읽어 실제 ALB 프로비저닝. terraform state 밖 리소스라 destroy 전 선삭제 필요 — 종료 절차 4단계의 이유
- **securityContext**: `runAsNonRoot` + `runAsUser: 1000`
- **StorageClass(gp3) + PVC + EBS CSI**: Prometheus 영구 볼륨. PVC 방치 시 고아 EBS가 조용히 과금되는 것까지 종료 절차에 반영
- **HPA**: CPU 평균 50% 기준 2~6 레플리카 자동 증감 (매니페스트 반영 완료, 실동작 검증은 다음 apply 예정). 분모는 `requests.cpu` — metrics-server가 전제 조건이며 EKS에는 기본 미설치라는 함정까지 문서화
- **네임스페이스 분리**: app / argocd / monitoring

## 5. CI/CD — GitHub Actions + ArgoCD + Kustomize (GitOps)

- **CI (GitHub Actions)**: push → OIDC 인증 → 이미지 빌드 → ECR 푸시 → 매니페스트 repo의 `newTag`를 커밋 SHA로 자동 커밋
- **CD (ArgoCD, pull 방식)**: 매니페스트 repo(비공개)를 감시, drift 감지·자동 복구. 자격증명이 클러스터 밖으로 나가지 않음 (ADR-001)
- **Kustomize**: 매니페스트는 논리 이름 `image: app`, `images.newTag`만 CI가 갱신 — 코드와 배포 상태의 분리
- **repo 2개 구조**: 앱 repo(공개, 코드+CI) / 매니페스트 repo(비공개, 배포 상태) — Git이 단일 진실 공급원
- 실증: `git push` 하나로 v0.2.0 → v0.2.1 자동 배포, 롤백은 `git revert` 한 번
- **Helm**: ALB Controller·ArgoCD·kube-prometheus-stack·cloudwatch-exporter 설치에 사용 (values 파일로 리소스 제한·비밀값 분리)

## 6. 관측성 — Prometheus · Grafana · Alertmanager

- **kube-prometheus-stack**을 t3.medium 2대에 맞게 보수적 리소스로 설치, Prometheus는 gp3 5Gi PV(retention 2d)
- EKS에서 수집 불가한 컨트롤플레인 타깃(etcd 등)을 미리 꺼서 가짜 DOWN 0건 — **19/19 up**
- **알람 2종 (PrometheusRule)**: 파드 재시작(kube-state-metrics 지표), RDS CPU(cloudwatch-exporter 경유)
- **Slack 전달 실증**: 파드를 실제로 죽여 FIRING → Slack 수신 → RESOLVED 복구 통보까지 왕복 확인
- Webhook 등 비밀값은 `values-secret.yaml`(gitignore)로 분리

## 7. 애플리케이션 — Python (FastAPI)

- FastAPI + psycopg3 + anthropic SDK, 단일 파일 90줄 — 인프라를 관통하는 최소 검증 단위로 의도적 설계
- lifespan에서 `CREATE TABLE IF NOT EXISTS` (멱등 초기화), 파라미터 바인딩으로 SQL 인젝션 차단
- **Claude API 연동**: 모델·API 키 전부 환경변수 주입, 요약 프롬프트는 system 메시지로 제어

## 8. 협업·운영 도구

- **git / GitHub / gh CLI**: filter-branch로 커밋 히스토리에서 계정 ID 제거(공개 전 세탁), fine-grained PAT 운영, gh secret 관리
- **kubectl / helm / aws CLI**: 재기동 루틴 8단계·종료 절차 4단계를 문서화된 명령으로 표준화
- **AWS CloudTrail**: OIDC 인증 실패 디버깅의 결정적 도구 — "상대가 실제 보낸 값"을 보는 곳

---

## 스택 선택에서 의도적으로 뺀 것 (질문 대비)

| 안 쓴 것 | 이유 |
|---|---|
| Istio 등 서비스 메시 | 서비스 1개 규모에서 복잡도 대비 이득 없음 |
| Karpenter | 노드 2대 고정 규모 — 관리형 노드그룹으로 충분 |
| Secrets Manager | 월 요금·운영 부담이 규모 대비 과잉, K8s Secret으로 "코드에 비밀값 0" 조건은 충족 |
| Multi-AZ RDS | 비용 2배 — 포트폴리오 환경에서 인지하고 제외, 프로덕션 기준은 문서에 명시 |
| Cluster Autoscaler | 보너스 백로그 — HPA와 세트로 "파드 Pending → 노드 추가" 시연 가치가 있으나, 발표자료 완성이 우선 |
