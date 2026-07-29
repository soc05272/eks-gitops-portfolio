# 작업 로그

> 날짜별 진행 내역. 무엇을 했는지보다 **왜 그렇게 했는지와 무엇이 막혔는지**를 남긴다.
> 개별 장애의 상세 분석은 [troubleshooting.md](troubleshooting.md), 설계 판단은 [adr/](adr/) 참고.

---

## 2026-07-24 — 인프라 코드 설계 및 작성

AWS 계정 생성. 코드를 먼저 다 짜고 한 번에 올리는 방식으로 진행하기로 했다.

**작성한 것**

| 파일 | 내용 |
|---|---|
| `terraform/vpc.tf` | VPC 10.0.0.0/16, 2AZ, public/private/database 3계층 서브넷, 단일 NAT |
| `terraform/eks.tf` | EKS 1.31, 관리형 노드그룹 t3.medium Spot (1~3대) |
| `terraform/rds.tf` | PostgreSQL 16, db.t3.micro, Single-AZ |
| `terraform/ecr.tf` | IMMUTABLE 태그, scan on push, 최근 10개 유지 |
| `terraform/{variables,outputs,providers,versions}.tf` | 변수·출력·프로바이더 정의 |
| `.github/workflows/ci.yaml` | 빌드 → ECR 푸시 워크플로 뼈대 (OIDC 인증) |
| `docs/adr/001~003` | ArgoCD / RDS / 단일 NAT 선택 근거 |

**설계 시 정한 원칙**

- 서브넷을 3계층으로 나눠 상태 있는 워크로드(DB)와 없는 워크로드(앱)를 네트워크 수준에서 분리
- ALB가 서브넷을 자동 탐색하도록 `kubernetes.io/role/elb` 태그를 처음부터 부여
- RDS 보안그룹은 EKS 노드 SG에서 오는 5432만 허용 (CIDR이 아닌 SG 참조 방식)
- 비용 절감은 Spot + 단일 NAT까지만. NAT Instance는 관리 포인트가 늘어 "과하지 않게" 원칙에 어긋난다고 판단 (ADR-003)

---

## 2026-07-27 — 애플리케이션 작성

| 파일 | 내용 |
|---|---|
| `app/app.py` | FastAPI. `POST/GET /summaries`, `/healthz`. Claude API로 요약 후 RDS에 이력 저장 |
| `app/Dockerfile` | python:3.12-slim, non-root 실행 |
| `app/requirements.txt` | fastapi, uvicorn, psycopg, anthropic |
| `README.md` | 프로젝트 개요, 아키텍처, 5주 계획, 비용 전략 |

앱 시작 시(`lifespan`) 테이블을 생성하도록 해서 별도 마이그레이션 도구 없이 동작하게 했다.

---

## 2026-07-28 — 원격 state 구성 및 첫 커밋

**원격 state 전환**

- state용 S3 버킷 생성 (21:59). 버킷명에 계정 ID가 들어가므로 코드에는 두지 않고
  부분 백엔드 구성(`backend.hcl`, gitignore 대상)으로 분리했다
- `versions.tf`의 주석 처리돼 있던 backend 블록 활성화
- `terraform init -backend-config=backend.hcl` → 프로바이더 5종(aws, cloudinit, null, time, tls) 설치
- `terraform plan -out=tfplan` → **64 to add, 0 to change, 0 to destroy**

**초기 커밋** (22:19) — 18파일 584줄. (당시 해시 `b365223`. 7/29 히스토리 재작성으로 현재 해시는 `ed0bf79`, 아래 참고)

이 시점까지 나흘치 작업이 커밋 0건 상태였다. 커밋 전에 `.gitignore`를 점검해 **`tfplan`을 추가**했다. plan 파일에는 `db_password`가 평문으로 들어가는데 gitignore에 없어서 `git add -A` 한 번이면 그대로 커밋될 상태였다.

---

## 2026-07-29 — 프로비저닝 시도, 실패, 원인 규명, 재시도

### 1차 apply — 63/64 성공 후 실패 (00:24 ~ 01:02)

| 리소스 | 소요 | 결과 |
|---|---|---|
| NAT Gateway | 1m33s | ✅ |
| RDS PostgreSQL | 6m57s | ✅ |
| EKS 컨트롤플레인 | 7m53s | ✅ |
| KMS 키 / OIDC provider / access entry | — | ✅ |
| **노드그룹 (t3.medium Spot ×2)** | **37m58s** | ❌ **CREATE_FAILED** |

```
AsgInstanceLaunchFailures: Could not launch Spot Instances.
InvalidParameterCombination - The specified instance type is not eligible for Free Tier.
```

**원인**: 계정이 **AWS Free Plan**이라 `free-tier-eligible` 인스턴스 타입만 기동 가능했고 `t3.medium`은 대상이 아니었다. 인프라 코드 문제가 아니라 계정 정책 문제.

**진단이 어려웠던 이유**: 38분 내내 `describe-nodegroup`의 `health.issues`가 **비어 있었다.** 실패 사유는 ASG의 `describe-scaling-activities`에만 기록된다. 상세 분석은 [troubleshooting.md](troubleshooting.md) 참고.

### destroy — 전량 회수 (01:05경)

`Destroy complete! Resources: 64 destroyed.` 에러 0건.

AWS API로 13개 항목을 전수 검증해 잔여물 0을 확인했다(EKS/RDS/NAT/EC2/VPC/EIP/EBS/ELB/ECR/스냅샷/ASG/ENI/시작템플릿). **고아 EBS 볼륨과 미연결 EIP가 없는지**를 특히 확인했는데, 이것들이 남으면 조용히 과금된다.

- 리소스 가동 시간: 약 35~40분
- 실제 비용: 약 $0.12~0.20 (170~280원)

### 계정 플랜 전환 — Free → Paid

우회안(노드 타입을 `c7i-flex.large`로 변경)과 근본 대응(Paid Plan 전환)을 비교했다.

| | Free Plan | Paid Plan |
|---|---|---|
| 인스턴스 타입 | 6종으로 제한 | 제한 없음 |
| 12개월 프리티어 | ❌ | ✅ |
| 시간당 비용 | $0.222 | **$0.195** |
| 지출 상한 | **크레딧 초과 시 차단** | 없음 (실제 청구) |

우회안은 `Spot + free-tier-eligible` 조합이 실제로 뜨는지 미검증이었고, 2~4주차(ALB, EBS)에서 같은 제약에 또 막힐 위험이 있었다. **Paid Plan 전환을 선택.**

`aws freetier get-account-plan-state`로 검증:

```
accountPlanType : FREE → PAID
크레딧          : $119.45 (그대로 이월)
만료일          : 2027-01-24 → 없음
```

> 전환은 되돌릴 수 없고 지출 상한이 사라진다. `terraform destroy` 습관이 이 시점부터 실제 비용에 직결된다.

### 커밋 `ad7ef0a` (21:48)

- `docs/troubleshooting.md` — 오늘 장애를 증상/원인분석/해결/배운점 형식으로 기록
- `terraform/variables.tf` — 예산 변수 2개 선언 (`monthly_budget_usd`, `budget_alert_email`)

예산 알람 리소스(`budgets.tf`)는 도입을 보류하고 **`budgets.tf.disabled`로 이름을 바꿔 두었다.** terraform은 git 추적 여부와 무관하게 디렉터리의 모든 `.tf`를 읽으므로, 커밋하지 않는 것만으로는 apply를 막을 수 없기 때문이다.

### 2차 apply — 성공

계정 전환 덕에 **코드 수정 없이** `t3.medium` 그대로 재시도해 전량 생성됐다.

### 검증 — AWS 계층

| 항목 | 결과 |
|---|---|
| EKS 클러스터 | `ACTIVE`, v1.31 |
| 노드그룹 | `ACTIVE`, SPOT, t3.medium, health.issues 비어 있음 |
| EC2 노드 | 2대 running (2a/2b **AZ 분산**), 상태검사 2/2 통과 |
| RDS | `available`, PostgreSQL 16.13 |
| ECR | `eks-gitops-app` 생성 |
| access entry | `user/hbko` + 노드 Role 등록 |

### 검증 — 쿠버네티스 계층

`kubectl` 미설치 상태였어서 설치 후(v1.36.3) 검증했다.

| 항목 | 결과 |
|---|---|
| 컨트롤플레인 | `readyz check passed` |
| 노드 | 2대 **`Ready`**, AL2023, containerd 2.2.4 |
| `aws-node`(VPC CNI) / `coredns` / `kube-proxy` | 전부 Running, **재시작 0회** |
| 노드당 여유 | CPU 1930m, 메모리 3.2Gi, 파드 17개 |

### 검증 — End-to-End (테스트 파드 기동)

| 테스트 | 결과 |
|---|---|
| 파드 스케줄링 + 이미지 Pull | ✅ |
| 내부 DNS (CoreDNS) | ✅ `kubernetes.default.svc` → 172.20.0.1 |
| 외부 DNS | ✅ RDS → 10.0.21.35 (**DB 서브넷 사설 IP** — 내부 경로 유지) |
| NAT 아웃바운드 | ✅ 공인 IP `52.78.210.252` |
| **RDS 5432 TCP** | ✅ **성공** |

파드가 나간 공인 IP가 **NAT 게이트웨이의 EIP와 정확히 일치**했다. 프라이빗 서브넷 → NAT → 외부 경로가 설계대로 동작한다는 뜻이다. RDS 연결 성공은 SG 참조 방식 규칙이 정상 작동함을 확인해준다.

### 작업 종료 — 2차 destroy 및 GitHub 공개 준비

검증을 마치고 이 작업 로그를 작성·커밋한 뒤, 2차 `terraform destroy`를 수동 실행했다(완료 검증은 7/30).

GitHub 공개 전 커밋 전체를 민감정보 스캔했다. 비밀번호·액세스 키는 없었지만
**AWS 계정 ID가 `versions.tf`의 state 버킷명에 하드코딩되어 커밋 3개 전부에 노출**되어 있었다.
공개 repo에 올리기 전, push 이전이라 히스토리를 자유롭게 고칠 수 있는 마지막 시점이었다.

- `versions.tf`에서 `bucket`을 제거하고 **부분 백엔드 구성**으로 전환 — 실제 버킷명은
  gitignore 대상인 `backend.hcl`로 분리, `backend.hcl.example`만 커밋
- `git filter-branch --tree-filter`로 **커밋 4개 전체 재작성** → 히스토리 전수 검색 결과 계정 ID 0건
- 부작용: 커밋 해시가 전부 바뀌었고(`b365223`→`ed0bf79`, `ad7ef0a`→`e6dc5f7` 등),
  이후 `terraform init`은 `-backend-config=backend.hcl` 플래그가 필요해졌다

계정 ID는 비밀값은 아니지만 정찰 단서가 되므로, 공개 직전이 제거 비용이 가장 싼 시점이었다.

---

## 2026-07-30 — destroy 검증 및 GitHub 공개

### 2차 destroy 완료 검증

terraform state 0개. AWS API로 **17개 항목**을 전수 조회해 잔여물이 없음을 확인했다.
1차 검증(13개 항목)보다 범위를 넓혀 중지된 EC2, 자동 RDS 스냅샷, EBS 스냅샷,
CloudWatch 로그 그룹까지 포함했다 — 전부 0.

| 예외 항목 | 판단 |
|---|---|
| KMS 키 2개 (1·2차 apply의 클러스터 암호화 키) | `PendingDeletion` — 8/28 자동 삭제, **삭제 대기 키는 무과금**. 조치 불필요 |
| S3 state 버킷 | 794바이트 1개 — 다음 apply에 필요해 의도적 유지, 과금 사실상 0 |

**결론: 월 과금 $0.** 백엔드 설정 변경 여파로 state 조회가 막혀 있던 것도
`terraform init -backend-config=backend.hcl -reconfigure`로 해결해뒀다.

### GitHub 공개 (Public)

**https://github.com/soc05272/eks-gitops-portfolio**

`gh` CLI 디바이스 플로우로 인증했다. 두 번 막혔다:

1. **push 거부 — `workflow` scope 부재**: 커밋에 `.github/workflows/ci.yaml`이 있으면
   기본 토큰 권한으로는 push가 거부된다. `gh auth refresh -s workflow`로 권한 추가
2. **`could not read Username`**: git이 gh 인증을 쓰도록 연결이 안 된 상태.
   `gh auth setup-git` 한 줄로 해결 — 이후 `git push`는 추가 인증 불필요

업로드 후 **원격 기준으로** 검증했다 (로컬 검사가 아니라 GitHub API로 실제 올라간 내용 확인):

| 검사 | 결과 |
|---|---|
| 로컬 vs 원격 HEAD SHA | 일치 (`04351fe`) |
| `backend.hcl` / `terraform.tfvars` / `tfplan` | 원격에 없음 |
| 원격 파일 내 계정 ID | 0건 |
| 커밋 4개 / 파일 20개 | 정상 업로드 |

계정 ID가 남아 있던 로컬 백업 브랜치(`backup-before-rewrite`)는 push 대상이 아니었음을
확인한 뒤 삭제했다.

> push 직후 Actions에서 CI가 1회 실패했을 수 있다 — `AWS_GHA_ROLE_ARN` 시크릿이 아직 없어서로,
> 예상된 동작이다(알려진 이슈 ② 참고). 트리거가 `paths: ["app/**"]`라 반복 실행되지는 않는다.

---

## 현재 상태

**1주차(인프라 프로비저닝) 완료.**

| 구분 | 상태 |
|---|---|
| 인프라 | **전량 destroy 완료, 월 과금 $0** (17개 항목 전수 검증) |
| 계정 | Paid Plan, 크레딧 $119.45 |
| 코드 | GitHub 공개 저장소에 백업 완료 (github.com/soc05272/eks-gitops-portfolio) |
| 앱 배포 | 미착수 (2주차) |
| ArgoCD / 매니페스트 repo | 미착수 (3주차) |
| 관측성 | 미착수 (4주차) |

## 알려진 이슈 / 다음에 처리할 것

**① EBS CSI 드라이버 없음 — 4주차 전 필수**

현재 `gp2` StorageClass는 in-tree 프로비저너(`kubernetes.io/aws-ebs`)를 쓰는데 최신 쿠버네티스에서 제거된 방식이고, 실제 볼륨을 만드는 EBS CSI 드라이버가 설치돼 있지 않다(`aws eks list-addons` → `[]`). **PVC를 만들어도 볼륨이 프로비저닝되지 않을 가능성이 높다.**

4주차 `kube-prometheus-stack`이 PV를 요구하므로 그 전에 `eks.tf`에 애드온을 추가해야 한다. IRSA용 IAM Role도 함께 필요하다. 설치 가능 버전은 `v1.63.0-eksbuild.1` 확인됨.

**② CI 워크플로 미완성 — 3주차**

`.github/workflows/ci.yaml`에 TODO 4건이 남아 있다.

- GitHub Actions용 OIDC provider와 IAM Role 미생성 (`AWS_GHA_ROLE_ARN` 비어 있음) — 클러스터의 IRSA용 OIDC와는 별개다
- 매니페스트 repo용 PAT 미등록
- clone URL이 `<YOUR-ID>` 플레이스홀더
- 이미지 태그 교체 로직(`kustomize edit set image`)이 주석 처리됨

**③ 매니페스트 repo 미생성 — 3주차**

`eks-gitops-manifests` repo 자체가 없어서 ArgoCD가 바라볼 대상이 없다.

**④ 예산 알람 미적용**

`budgets.tf.disabled` 상태. 도입 시 파일명을 `budgets.tf`로 되돌리면 된다.
Paid Plan 전환으로 지출 상한이 없어졌으므로 도입 우선순위가 이전보다 높다.

## 운영 메모

```bash
# 최초 1회 (또는 새로 clone한 경우)
cp terraform/backend.hcl.example terraform/backend.hcl   # 실제 버킷명 기입
cd terraform && terraform init -backend-config=backend.hcl

# 재개
cd terraform && terraform plan -out=tfplan && terraform apply tfplan   # 15~20분

# kubectl 연결
aws eks update-kubeconfig --region ap-northeast-2 --name eks-gitops-cluster

# 종료 (작업 후 반드시)
terraform destroy
```

destroy 전에 `kubectl delete ingress --all` / `kubectl delete pvc --all`을 먼저 실행할 것.
ALB Ingress Controller가 만든 ALB와 Prometheus의 EBS PV는 terraform state 밖에 있어서
남아 있으면 VPC 삭제를 막고, NAT와 EKS만 지워진 채 ALB만 남아 과금되는 상황이 생긴다.
