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

## 2026-08-05 ~ 08-06 — 2주차: 앱 배포 완료 (E2E + ALB 외부 노출)

6일 만의 재개. `terraform apply`(수동)로 인프라를 재기동하고 3계층 검증(AWS → 쿠버네티스
→ E2E 네트워크)을 재통과했다. **코드 수정 없이 20분 만에 전체 환경이 동일 품질로 재현** —
destroy/apply 운영 방식이 실제로 성립함을 두 번째로 실증한 셈이다.

### 빌드 → 푸시 → 배포

- Docker Desktop 설치 (cask 설치가 sudo를 요구해 사용자 직접 실행)
- 이미지 빌드 시 **`--platform linux/amd64` 명시** — Apple Silicon 기본값(arm64)으로
  빌드하면 x86_64 노드에서 `exec format error`로 죽는 고전적 함정
- ECR 푸시 (태그 = git SHA `1fc3d94`. IMMUTABLE이라 latest 대신 고유 태그)
- `k8s/` 매니페스트 작성 (namespace / deployment / service). 3주차 GitOps 전환 시
  별도 repo로 이관 예정. 이미지의 계정 ID는 `<AWS-ACCOUNT-ID>` 플레이스홀더로 두고
  `scripts/deploy.sh`가 치환해 적용한다 — versions.tf 부분 백엔드 구성과 같은 이유
- Secret은 `scripts/create-secret.sh`로 생성 — DB 비밀번호는 tfvars에서 자동으로 읽고
  API 키는 화면 비표시 프롬프트로 입력. 비밀값이 repo·셸 히스토리·대화에 남지 않으며,
  destroy 시 Secret도 사라지므로 재기동 때마다 재사용한다

### 트러블슈팅 2건

1. **`CreateContainerConfigError`** — Dockerfile의 이름 기반 `USER appuser`와 매니페스트의
   `runAsNonRoot: true` 조합은 kubelet이 검증 불가. `runAsUser: 1000` 명시로 해결.
   상세 분석은 [troubleshooting.md](troubleshooting.md) 참고
2. **Claude API 402성 오류** — "credit balance is too low". 이 에러가 오히려 API 키 유효성과
   파드 → NAT → api.anthropic.com 경로를 증명해줬다(키가 틀렸다면 401). Anthropic Console에서
   크레딧 $5 충전으로 해결 — **AWS와 별개 계정·별개 결제**라는 점 주의

### E2E 검증 성공

```
POST /summaries → 파드 → NAT → Claude API(claude-sonnet-5) 요약 생성 → RDS 저장 (id: 1)
GET  /summaries → RDS 조회로 방금 저장한 요약 반환 ✅
```

readiness 프로브(`/healthz`) 통과 = 앱 시작 시 RDS 연결·테이블 생성도 성공.

### ALB Ingress Controller — 외부 노출 (2주차 완료)

- **IRSA Role** (`terraform/alb-controller.tf`): 컨트롤러 파드에만 ALB 생성 권한을 부여.
  노드 Role에 얹으면 노드 위 모든 파드가 권한을 갖게 되므로, EKS OIDC provider를 신뢰하는
  전용 Role을 `kube-system:aws-load-balancer-controller` ServiceAccount에 바인딩.
  정책 본문은 IRSA 모듈 내장(`attach_load_balancer_controller_policy`)이라 별도 JSON 불필요
- **Helm**으로 컨트롤러 설치 (레플리카 2), `k8s/ingress.yaml` 적용
  (`internet-facing`, `target-type: ip` — VPC CNI 덕에 파드 IP 직접 라우팅, NodePort 홉 제거)
- Ingress 생성 후 ALB 주소 발급 ~10초, 타깃 등록·DNS 전파까지 약 4~5분
- **인터넷 경유 E2E 성공**: ALB → 파드 → Claude API → RDS 저장(id: 2) → 조회

1주차에 VPC 서브넷에 미리 태그(`kubernetes.io/role/elb`)를 달아둔 것이 여기서 효력을 발휘 —
컨트롤러가 서브넷을 자동 발견해 ALB를 퍼블릭 서브넷에 배치했다.

> ⚠️ **destroy 순서 주의**: 이 ALB와 보안그룹은 컨트롤러가 만든 것이라 terraform state 밖에 있다.
> `terraform destroy` 전에 반드시 `kubectl delete ingress summarizer -n app`을 먼저 실행할 것.
> 안 하면 VPC 삭제가 실패하고 ALB만 남아 과금된다. ALB 주소는 재생성 때마다 바뀐다.

---

## 2026-08-06 (밤) — 3주차: GitOps 파이프라인 구축 (E2E 검증은 다음 세션)

### 구축 완료

- **매니페스트 repo** `eks-gitops-manifests` 생성 (**private** — 계정 ID가 매니페스트에
  포함되므로. ArgoCD가 그대로 적용하는 구조라 플레이스홀더 치환을 끼울 수 없다).
  Kustomize 구조: deployment는 논리 이름 `image: app`, kustomization의 `images` 필드가
  실제 ECR URL·태그로 치환. CI는 `newTag`만 갱신한다
- **ArgoCD** Helm 설치 (dex·notifications 비활성 — 노드 리소스 절약),
  Application 적용 → 4개 리소스 **Synced/Healthy**, 기존 리소스 무중단 인수
- **GHA OIDC** provider + ECR 푸시 전용 Role (main 브랜치 한정)
- **ci.yaml TODO 4건 완성**, repo secrets(`AWS_GHA_ROLE_ARN`, `MANIFEST_REPO_TOKEN`) 등록

### 트러블슈팅 2건

1. **PAT 개행 혼입** — `echo`로 저장한 토큰 파일의 개행이 ArgoCD credential에 섞여
   `Invalid username or token`. 93자로 정리해 재등록 → 즉시 Synced.
   (CI용 GitHub secret도 같은 문제가 잠복해 있어 함께 재등록 — E2E 전에 선제 제거)
2. **GHA OIDC 인증 실패** — GitHub의 새 sub 형식(`@계정ID`/`@저장소ID` 포함)과
   Terraform 모듈의 구형식 조건 불일치. CloudTrail `userIdentity`로 실제 sub를 확인해
   해결. **이 프로젝트에서 가장 값진 디버깅 사례** — [troubleshooting.md](troubleshooting.md) 참고

### 다음 세션 시작점

수정된 신뢰 정책은 코드에만 반영된 상태(세션 종료로 destroy). **재기동 후 첫 작업**:
`app/**` 아무거나 수정 push → Actions 성공 → 매니페스트 repo 자동 커밋 → ArgoCD 동기화
→ `/healthz`의 `version: 0.2.0` 확인. 이게 되면 3주차 완료.

---

## 2026-08-07 — 3주차 완료: GitOps E2E 실증

재기동 루틴 ①~⑦을 그대로 밟아 복구 (PAT 재발급 포함, 이번엔 `pbpaste` 방식으로
개행 사고 없이 한 번에). 이후 어제 실패했던 CI run을 **같은 커밋으로 재실행** —
바뀐 것은 수정된 OIDC 신뢰 정책뿐이므로, 그 수정이 원인이었는지에 대한 대조실험이다.

**결과: 전 구간 자동 완주.**

```
git push (version 0.2.0 커밋)
  → Actions: OIDC 인증 통과(수정된 sub 조건의 첫 실전) → 빌드 → ECR 푸시
  → 매니페스트 repo 자동 커밋 c504d4f (kustomize edit, newTag = 커밋 SHA)
  → ArgoCD 자동 감지(90초) → 신규 이미지 롤링 배포
  → 인터넷 확인: {"status":"ok","version":"0.2.0"}
```

사람의 개입은 `git push` 하나 — README의 3주차 목표를 그대로 실증했다.
롤백도 이제 매니페스트 repo의 `git revert` 한 번이면 된다.

---

## 2026-08-07 (오후) — 4주차 완료: 관측성

### 스토리지 계층 (선행 조건)

- **EBS CSI 드라이버** — IRSA + EKS 관리형 애드온 (`terraform/ebs-csi.tf`).
  in-tree 프로비저너가 제거된 최신 쿠버네티스에서 PVC를 실제 EBS로 만들어주는 계층
- **gp3 StorageClass** — 유령이 된 gp2 SC는 방치하고 명시적 지정 방식으로 신설
- 검증: 테스트 PVC → **10초 만에 Bound**, AWS에 실제 gp3 볼륨 in-use 확인 후 정리

### kube-prometheus-stack

- t3.medium x2에 맞춘 보수적 리소스 + Prometheus는 gp3 5Gi PV (retention 2d)
- EKS에서 수집 불가한 컨트롤플레인 컴포넌트(etcd 등)를 미리 꺼서 **가짜 DOWN 0건 — 19/19 up**
- PromQL로 우리 앱 조회 확인 (`summarizer 가용 레플리카: 2`), Grafana healthy

### Slack 알람 — README 계획 2종 완성

- Webhook은 gitignore된 `monitoring/values-secret.yaml`로 분리 (backend.hcl 패턴)
- **알람 ① AppPodRestarting** — 실전 검증: 파드 kill → FIRING → **Slack 수신 확인** (스크린샷 확보).
  `send_resolved`로 복구 통보까지. "수동 장애 대응 → 선제 감지"의 실증
- **알람 ② RDSHighCPU** — RDS 지표는 CloudWatch에만 있어 **cloudwatch-exporter**(+네 번째 IRSA)로
  Prometheus에 유입시켜 알람 경로를 단일화. 규칙 로드·지표 유입(CPU 3.8%) 확인

### 트러블슈팅 (요약)

- **CloudWatch 타임스탬프 함정** — exporter가 CW의 지연된 원본 타임스탬프를 붙이면
  Prometheus 인스턴트 쿼리(5분 룩백)에 안 잡힌다. `set_timestamp: false`로 스크레이프
  시각을 쓰게 해서 해결. exporter `/metrics`를 직접 curl해 값 끝의 타임스탬프를 보고 진단
- 대기 루프의 port-forward가 도중에 죽으면 영원히 기다리게 된다 — 진단 전에 포워드 생존부터 확인

---

## 2026-08-14 — 전체 수명주기 리허설 (5주차 발표 전 종합 점검)

지난 destroy의 완료 검증부터 시작해, **재기동 → 전 기능 검증 → 회수**를 하루에 완주했다.
목적은 "코드와 문서만으로 시스템 전체를 재현·검증·회수할 수 있다"는 이 프로젝트의
핵심 주장을 발표 전에 한 번에 실증해두는 것.

### 사전 정리

- 지난 세션 잔여물 우려로 destroy 재실행 후 **13개 항목 전수검증 → 잔여물 0** 확인
- 유지 항목은 의도된 것뿐: S3 state 버킷(무과금 수준), KMS 삭제 대기 키(무과금)

### 재기동 — 8단계 루틴 세 번째 실증

apply(64→78개로 리소스 증가: IRSA 4종·EBS CSI·GHA OIDC 추가분) 후 루틴 ②~⑧ 순서대로 복구.
특이사항 두 가지:

- **이미지 두 태그 전략**: destroy로 비워진 ECR에 한 번 빌드한 이미지를
  `1fc3d94`(deploy.sh의 수동 배포용)와 `a53441a...`(매니페스트 repo의 newTag용) 두 태그로
  푸시 — ArgoCD 인수 시점까지 양쪽 참조가 모두 유효하도록
- **PAT 클립보드 사고 재발**: 8/6 개행 사고의 대응책이던 pbpaste 방식이 오히려
  "명령 복사가 토큰을 덮어쓰는" 새 실패 모드를 만들었다. hidden prompt 방식으로 절차
  자체를 교체, ArgoCD hard refresh로 복구. [troubleshooting.md](troubleshooting.md) 5번째 사례

### 검증 결과 — 전 항목 통과

| 검증 | 결과 |
|---|---|
| 앱 E2E | ✅ 인터넷 → ALB → 파드 → Claude API 요약 → RDS 저장(id:1)/조회 |
| GitOps | ✅ 버전 0.2.1 push → CI(재발급 PAT 첫 실전) → 매니페스트 자동 커밋(c8c04b7) → ArgoCD 무중단 롤링 → 인터넷에서 `version: 0.2.1` 확인 |
| 알람 | ✅ 컨테이너 kill → `AppPodRestarting` FIRING → **Slack 실수신**(스크린샷). 셋업 중 파드 대기 구간의 기본 알람 FIRING/RESOLVED 사이클도 관찰 — 커스텀·기본 알람 모두 실전 동작 |

소소한 발견: slim 이미지에는 `kill` 실행 파일이 없어 `sh -c 'kill 1'`(셸 내장)로 재시작을
유발해야 했다. 롤링 직후 ALB 응답 실패 1회도 관측 — 원인 분석과 표준 해법(Pod Readiness
Gate)은 [troubleshooting.md](troubleshooting.md) 6번째 사례로 기록, 백로그 등록.

### 회수 — 종료 절차 4단계

Application 삭제 → Ingress 삭제(ALB 소멸 확인) → 모니터링/PVC 삭제(**고아 EBS 0 확인**)
→ `terraform destroy`(78개, 에러 0) → 13개 항목 전수검증 **잔여물 0, 월 과금 $0.**

---

## 2026-08-26 — HPA 도입 결정 및 매니페스트 반영

백로그였던 오토스케일링을 검토해 **HPA는 도입, Cluster Autoscaler는 보너스 백로그, Karpenter는
계속 제외**로 결정했다. "과하지 않게"의 선은 Karpenter 앞에 있다고 판단 — CA는 노드그룹
max=3 여유가 이미 코드에 있어 작업량이 크지 않고, "HPA로 파드가 Pending → CA가 노드 추가"
시연은 파드/노드 계층 구분을 실증하는 좋은 서사다. 다만 우선순위는 발표자료 완성 뒤.

**반영한 것 (매니페스트 repo `70b83a9`)**

- `hpa.yaml` 신규 — CPU 평균 50% 기준 2~6 레플리카. 분모는 deployment의 `requests.cpu=100m`.
  min 2는 AZ 분산 전제, max 6(=600m)은 노드 2대 여유 내 상한
- `kustomization.yaml` resources에 등록 — 다음 apply 때 ArgoCD가 자동 배포
- **deployment의 `replicas: 2` 선언 제거** (`4ff6938`) — HPA가 관리하는 필드를 Git에 두면
  HPA가 늘릴 때마다 ArgoCD(selfHeal)가 drift로 판단해 되돌린다. GitOps + HPA 조합의
  표준 해법은 replicas를 Git에서 빼서 소유권을 HPA에 넘기는 것

**전제 조건과 주의점**

- **metrics-server 필수** — EKS 기본 미설치. 없으면 HPA TARGETS가 `<unknown>`으로 표시되며
  동작하지 않는다. 재기동 루틴에 ⑨로 추가
- 우리 앱은 Claude API 응답 대기가 대부분이라 **대기형 부하로는 CPU가 안 오른다** —
  시연 시 연산형 부하(busybox 무한루프 등)를 걸 것
- 축소는 기본 5분 안정화 창 이후 — "부하 껐는데 왜 안 줄지?"는 정상 동작

**검증은 다음 apply 때**: `kubectl get hpa -w`로 2→6→2 사이클 확인 + 캡처(발표자료 시연 재료).

### PostgreSQL 16 → 17 변경 (같은 날)

- 이유: **현업에서 운영 중인 솔루션의 DB가 PostgreSQL 17** — 운영 경험과 동일 버전으로 맞춰
  경력 연속성 확보. 서울 리전 17.5~17.11 지원과 db.t3.micro 조합 가능 여부를 CLI로 확인 후 결정
- 변경: `rds.tf`의 `engine_version = "17"` 한 줄. destroy/apply 재생성 구조라 업그레이드
  경로가 필요 없다 — 다음 apply 때 처음부터 17로 생성 (`SELECT version()`으로 확인 예정)
- 프로덕션이었다면 Blue/Green 배포 등 별도 경로가 필요 — interview-prep.md에 Q&A로 정리

### 재기동 검증 회차 (같은 날 오후) — HPA·PG17 실증 완료

9단계 루틴(⑨ metrics-server 첫 실행 포함)으로 재기동, **다섯 번째 재현**. 검증 결과:

| 검증 | 결과 |
|---|---|
| PostgreSQL 17 | ✅ `SELECT version()` → **17.9** (파드 안에서 SQL로 확정) |
| 앱 E2E | ✅ ALB → Claude 요약 → PG17 저장/조회 |
| **HPA 사이클** | ✅ **2 → 6 → 2 완주** — busybox 부하 3기 투입, CPU 최고 306% 감지 후 6개 증설. 부하 제거 후 CPU 2%로 떨어졌지만 **안정화 창 약 6.5분을 기다린 뒤** 2개 복귀 (축소 지연은 설계된 동작) |
| replicas 충돌 방지 | ✅ 파드 6개 상태에서도 ArgoCD **Synced** — replicas 제거 조치의 실전 검증 |
| 알람 | ✅ 파드 재시작 → FIRING → **Slack 실수신** (스크린샷 확보) |

**값진 관찰 — HPA의 한계가 실제 화면으로**: 6개째 파드가 `Pending`, 사유는
`0/2 nodes available: Too many pods` — CPU가 아니라 **노드당 파드 수 상한**(t3.medium의
ENI 제약, 노드당 17개)이었다. 모니터링 스택과 부하 생성기가 슬롯을 차지한 상태에서 한계 도달.
"HPA는 파드만 늘린다, 노드 확장은 Cluster Autoscaler의 일"이 백로그 ⑨의 실증 근거가 됐다.

부수 발견: `InfoInhibitor`(스택 내부 관리용 알람)가 Slack까지 발송됨 — null 라우팅으로
소음을 줄이는 튜닝 거리 (경미, 백로그성 메모).

**실전 장애 1건 — Grafana OOMKilled** (캡처 세션 중): 보수적으로 잡았던 메모리 제한
256Mi가 HPA 부하 테스트 직후의 대시보드 조회에서 한계 도달 → CrashLoopBackOff.
`lastState.terminated.reason=OOMKilled`로 진단, 제한 512Mi 상향으로 해결하고
values.yaml에 실측 근거 주석과 함께 반영(`bf6950c`) — 라이브 수정과 코드를 일치시킴.
알람 채널에 이 재시작이 실제 이벤트로 찍힌 것도 확인.

---

## 현재 상태

**1·2·3·4주차 완료 + 전체 리허설 통과(8/14).** 남은 것은 5주차(문서 정리·발표자료)와 백로그.

| 구분 | 상태 |
|---|---|
| 인프라 | **종료** (과금 $0 — S3 state 버킷·KMS 삭제 대기 키만 유지) |
| 계정 | AWS: Paid Plan / Anthropic: $5 충전 |
| 코드 | 앱 repo(공개) + 매니페스트 repo(비공개) 모두 GitHub 백업 |
| 앱 배포 (2주차) | ✅ 인터넷 → ALB → 파드 → Claude API → RDS 전 구간 실증 (8/14 재검증) |
| GitOps (3주차) | ✅ push → CI → ArgoCD 자동 배포 E2E 실증 (8/14 재검증, v0.2.1) |
| 관측성 (4주차) | ✅ 알람 Slack 실수신 (8/14 재검증) |
| **리허설 (8/14)** | ✅ **재기동 → 전 기능 검증 → 회수 전체 수명주기 하루 완주** |
| 5주차 | 문서 누적 완료(트러블슈팅 6건·ADR 3건·worklog) — 발표자료·README 다듬기 잔여 |

## 알려진 이슈 / 다음에 처리할 것

> ~~① EBS CSI 드라이버 없음~~ → **해결 (08-07, 4주차)** — `terraform/ebs-csi.tf` + gp3 SC, PVC 10초 Bound 검증
> ~~② CI 워크플로 미완성~~ → **해결 (08-06~07, 3주차)** — TODO 4건 전부 해소, OIDC sub 신형식 이슈까지 해결
> ~~③ 매니페스트 repo 미생성~~ → **해결 (08-06, 3주차)** — private repo + Kustomize, ArgoCD 연동 완료

**④ 예산 알람 미적용**

`budgets.tf.disabled` 상태. 도입 시 파일명을 `budgets.tf`로 되돌리면 된다.
Paid Plan 전환으로 지출 상한이 없어졌으므로 도입 우선순위가 이전보다 높다.

**⑥ 배포 무중단 보강 — Pod Readiness Gate (2026-08-14 등록)**

리허설에서 롤링 직후 ALB 응답 실패 1회 관측. `kubectl label namespace app
elbv2.k8s.aws/pod-readiness-gate-inject=enabled` 한 줄로 도입 가능 — 상세는
troubleshooting.md 6번째 사례.

**⑦ Dockerfile 숫자 UID (runAsNonRoot 근본 대책, 2026-08-06 등록)**

현재는 매니페스트의 `runAsUser: 1000`으로 보완 중. 다음 이미지 변경 때 `USER 1000` 반영.

> ~~⑧ HPA 실동작 검증~~ → **해결 (08-26 오후)** — 2→6→2 사이클 완주, Pending 관찰까지.
> 위 "재기동 검증 회차" 참고

**⑨ Cluster Autoscaler — 보너스 백로그 (2026-08-26 등록)**

노드그룹 max=3 여유가 코드에 이미 있어 IRSA 1개 + Helm 설치면 됨. "HPA 증설 → 파드
Pending → CA 노드 추가 → 해소" 시연으로 파드/노드 계층 구분을 실증 가능.
우선순위는 발표자료 완성 뒤. Karpenter는 규모 대비 과잉으로 계속 제외.

CA 작업 시 확보할 캡처 3종 (발표자료 보강용):
① `kubectl get hpa -w` — REPLICAS 2→4→6 변화가 여러 줄로 남은 화면 (증설 순간)
② `kubectl get pods` — 6개 중 1개 Pending("Too many pods") 실물
③ CA 도입 후 Pending이 노드 추가로 해소되는 before/after

**⑤ 앱 개선 백로그 — 요청사항 접수 예정 (2026-08-06 결정)**

2주차 E2E 검증 후 "애플리케이션의 질과 내용은 추후 변경이 필요하다"고 판단.
구체 요청사항은 추후 전달 예정이며, 참고용으로 현재 앱의 상태를 기록해둔다:

- 단일 파일 FastAPI (`app/app.py`) — 엔드포인트 3개 (`POST/GET /summaries`, `/healthz`)
- 요약 프롬프트 고정 ("한국어 3문장 이내"), 모델은 `ANTHROPIC_MODEL` 환경변수로 교체 가능
- UI 없음 (JSON API만), 인증 없음, 요청 검증은 텍스트 길이(10~20,000자)뿐
- 테스트 코드 없음 — CI가 빌드만 하고 테스트 단계가 없는 것과 연결됨

앱 코드를 변경하면 이미지 태그가 바뀌므로, 3주차 CI/CD(자동 빌드→태그 교체→ArgoCD 동기화)가
완성된 뒤에 개선 작업을 하면 배포 파이프라인 검증을 겸할 수 있다 — 순서상 시너지 있음.

## 운영 메모

### 재기동 루틴 (2026-08-06 실전 검증 — 순서대로)

destroy는 클러스터 안(Secret·컨트롤러)과 ECR 이미지까지 지운다. 아래 ②~⑥이 전부 필요하다.

```bash
# 최초 1회 (또는 새로 clone한 경우)
cp terraform/backend.hcl.example terraform/backend.hcl   # 실제 버킷명 기입
cd terraform && terraform init -backend-config=backend.hcl

# ① 인프라 (15~20분)
cd terraform && terraform plan -out=tfplan && terraform apply tfplan

# ② kubectl 주소록 갱신 — EKS API 주소는 재생성마다 바뀐다. 빼먹으면 "no such host"
aws eks update-kubeconfig --region ap-northeast-2 --name eks-gitops-cluster

# ③ 이미지 재푸시 — ECR도 destroy로 비워진다(force_delete). 로컬 캐시가 있으면 푸시만
REG=$(cd terraform && terraform output -raw ecr_repository_url | cut -d/ -f1)
aws ecr get-login-password --region ap-northeast-2 | docker login --username AWS --password-stdin $REG
docker push $REG/eks-gitops-app:<태그>

# ④ 매니페스트 + ⑤ Secret
./scripts/deploy.sh
./scripts/create-secret.sh

# ⑥ ALB 컨트롤러 재설치 (클러스터와 함께 사라짐)
VPC=$(cd terraform && terraform output -raw vpc_id)
ROLE=$(cd terraform && terraform output -raw alb_controller_role_arn)
helm repo add eks https://aws.github.io/eks-charts 2>/dev/null
helm install aws-load-balancer-controller eks/aws-load-balancer-controller -n kube-system \
  --set clusterName=eks-gitops-cluster --set region=ap-northeast-2 --set vpcId=$VPC \
  --set serviceAccount.create=true --set serviceAccount.name=aws-load-balancer-controller \
  --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=$ROLE"
# ALB 주소는 매번 바뀐다: kubectl get ingress summarizer -n app

# ⑦ ArgoCD 재설치 (3주차부터 — 클러스터와 함께 사라짐)
helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null
helm install argocd argo/argo-cd -n argocd --create-namespace \
  --set dex.enabled=false --set notifications.enabled=false
# repo credential: PAT는 평문 보관하지 않으므로 GitHub에서 Regenerate 후 등록
#   kubectl create secret generic repo-eks-gitops-manifests -n argocd \
#     --from-literal=type=git --from-literal=url=https://github.com/soc05272/eks-gitops-manifests.git \
#     --from-literal=username=x-access-token --from-literal=password=<PAT(개행 없이!)>
#   kubectl label secret repo-eks-gitops-manifests -n argocd argocd.argoproj.io/secret-type=repository
#   (gh secret set MANIFEST_REPO_TOKEN 도 새 값으로 갱신)
kubectl apply -f argocd/application.yaml

# ⑧ 모니터링 재설치 (4주차부터)
kubectl apply -f monitoring/storageclass-gp3.yaml
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null
helm install monitoring prometheus-community/kube-prometheus-stack -n monitoring --create-namespace \
  -f monitoring/values.yaml -f monitoring/values-secret.yaml   # values-secret은 로컬 보관 (Slack Webhook)
kubectl apply -f monitoring/alert-rules.yaml
helm install cloudwatch-exporter prometheus-community/prometheus-cloudwatch-exporter \
  -n monitoring -f monitoring/values-cloudwatch.yaml \
  --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=$(cd terraform && terraform output -raw cloudwatch_exporter_role_arn)"

# ⑨ metrics-server (HPA 전제 — 2026-08-26부터. 없으면 HPA TARGETS가 <unknown>)
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ 2>/dev/null
helm install metrics-server metrics-server/metrics-server -n kube-system
# 검증: kubectl top nodes 응답 확인 → kubectl get hpa -n app 의 TARGETS에 수치 표시

# 종료 (작업 후 반드시 — 순서 주의. 4주차부터 4단계)
kubectl delete application summarizer -n argocd  # ① selfHeal이 Ingress를 되살리므로 먼저
kubectl delete ingress summarizer -n app         # ② ALB 제거 (1~2분 대기)
helm uninstall monitoring cloudwatch-exporter -n monitoring  # ③-1 스택을 먼저 내려야
kubectl delete pvc --all -n monitoring                       # ③-2 PVC가 삭제된다 (사용 중이면
                                                 #    멈춤). 안 지우면 클러스터 삭제 후 EBS만
                                                 #    고아로 남아 계속 과금! CSI 볼륨 0 확인:
                                                 #    aws ec2 describe-volumes --filters \
                                                 #      Name=tag-key,Values=kubernetes.io/created-for/pvc/name
terraform destroy                                # ④
```

destroy 전에 Ingress(4주차부터는 PVC도)를 먼저 삭제할 것. 컨트롤러가 만든 ALB와
Prometheus의 EBS PV는 terraform state 밖에 있어서 남아 있으면 VPC 삭제를 막고,
NAT와 EKS만 지워진 채 ALB만 남아 과금되는 상황이 생긴다.
RDS 데이터도 destroy마다 초기화된다(skip_final_snapshot) — 시연 데이터는 재기동 후 재생성.
