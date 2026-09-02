# 트러블슈팅 기록

> 형식: 증상 → 원인 분석 → 해결 → 배운 점. 삽질한 날 바로 기록할 것 (나중에 쓰려면 다 잊어버린다).
> 등급: **S** 구축·파이프라인 전면 불능 / **A** 서비스·배포 경로 중단 / **B** 부분 결손·단발 영향

---

## 템플릿

### [날짜] 제목 (한 줄 요약)

**증상**

- 어떤 명령/작업에서 어떤 에러가 났는지 (에러 메시지 원문 포함)

**원인 분석**

- 어떻게 원인을 좁혀갔는지 (확인한 로그, 시도한 가설)

**해결**

- 최종 해결 방법 (코드/명령 포함)

**배운 점**

- 다음에 같은 문제를 만나면 어디부터 볼지

---

## 한눈에 보기

| 등급 | 사례 | 한 줄 |
|---|---|---|
| **S** | EKS 노드그룹 CREATE_FAILED (7/29) | 38분 무증상 실패 — 원인은 ASG 활동 로그에 |
| **S** | GHA OIDC 인증 실패 (8/6) | sub 신형식 불일치 — CloudTrail로 실측값 확인 |
| **A** | 파드 CreateContainerConfigError (8/6) | runAsNonRoot는 이름 USER를 검증 못 한다 |
| **A** | ArgoCD 토큰 오류 재발 (8/14) | 재발은 절차를 바꾸라는 신호 |
| **B** | CloudWatch 타임스탬프 함정 (8/7) | 수집은 되는데 조회만 실패하는 시간축 문제 |
| **B** | 롤링 직후 ALB 순단 (8/14) | rollout 성공 ≠ LB 무중단 |
| **B** | Grafana OOMKilled (8/26) | 리소스 제한은 실사용 패턴으로 검증 |

---

<!-- 아래에 실제 사례를 추가 -->

## [2026-07-29] EKS 노드그룹이 CREATE_FAILED — AWS Free Plan 계정의 인스턴스 타입 제약

> **장애 등급: S** — 클러스터 구축 자체 불가, 38분간 무증상

**증상**

`terraform apply`로 인프라 64개 중 63개가 정상 생성됐으나, 마지막 EKS 관리형 노드그룹만
약 38분간 `CREATING` 상태에 머물다 실패했다.

```
Error: waiting for EKS Node Group (eks-gitops-cluster:default-...) create:
unexpected state 'CREATE_FAILED', wanted target 'ACTIVE'. last error:
AsgInstanceLaunchFailures: Could not launch Spot Instances.
InvalidParameterCombination - The specified instance type is not eligible for Free Tier.
```

주목할 점은 **실패하는 내내 `describe-nodegroup`의 `health.issues`가 계속 비어 있었다**는 것이다.
그래서 초반에는 정상 진행 중인 것과 구분이 되지 않았다.

**원인 분석**

`health.issues`가 비어 있어 노드그룹 API만으로는 원인을 알 수 없었다. 아래 순서로 좁혀갔다.

1. **설정 문제부터 배제** — 클러스터 `ACTIVE`, 노드 IAM Role 존재, 시작 템플릿 생성됨,
   프라이빗 서브넷 2개 모두 `0.0.0.0/0 → NAT` 라우팅 정상, NAT `available` 확인. 전부 이상 없음.
2. **용량 문제 배제** — `describe-spot-price-history`로 서울 t3.medium Spot 가격이
   $0.0158~0.0189로 정상 범위임을 확인. 용량 부족이면 가격이 튀거나 조회가 비어야 한다.
3. **결정적 단서** — `describe-instances`에 인스턴스가 한 대도 없었고,
   `describe-spot-instance-requests`에 요청 이력조차 없었다.
   즉 "노드가 떠서 클러스터 조인에 실패한 것"이 아니라 **인스턴스 기동 자체가 거부**된 것.
4. **원인 확정** — ASG가 생성된 뒤 `describe-scaling-activities`를 조회하니
   2분 간격으로 반복된 `Failed` 활동과 실패 사유가 그대로 남아 있었다.

```bash
# 원인이 실제로 적힌 유일한 곳
ASG=$(aws eks describe-nodegroup --cluster-name <cluster> --nodegroup-name <ng> \
      --query 'nodegroup.resources.autoScalingGroups[0].name' --output text)
aws autoscaling describe-scaling-activities --auto-scaling-group-name "$ASG" \
      --query 'Activities[].{status:StatusCode,msg:StatusMessage}'
```

이 계정은 **AWS Free Plan** 계정이라 Free Tier 대상 인스턴스 타입만 기동할 수 있는데,
`t3.medium`은 대상이 아니었다.

**해결**

계정에서 실제로 기동 가능한 타입을 먼저 확인한다.

```bash
aws ec2 describe-instance-types --region ap-northeast-2 \
  --filters "Name=free-tier-eligible,Values=true" \
  --query 'InstanceTypes[].{type:InstanceType,vcpu:VCpuInfo.DefaultVCpus,memMiB:MemoryInfo.SizeInMiB}' \
  --output table
```

| 타입 | vCPU/메모리 | Spot 시간당 | 2대 합계 메모리 |
|---|---|---|---|
| t3.small | 2 / 2GB | ~$0.007 | 4GB |
| **c7i-flex.large** | 2 / 4GB | ~$0.018 | **8GB** |
| m7i-flex.large | 2 / 8GB | ~$0.044 | 16GB |

두 가지 대응을 검토했다.

1. **우회 — 노드 타입을 `c7i-flex.large`로 변경**: `t3.medium`과 총 메모리(8GB)·비용($0.036 →
   $0.037)이 사실상 동일한 대체재. 그러나 정책 안에서의 회피일 뿐이고, Spot + free-tier-eligible
   조합이 실제로 기동되는지 미검증이었으며, 이후 주차의 ALB·EBS에서 같은 계정 정책에 또 막힐
   위험이 남는다. (ARM `t4g.small`은 더 저렴하지만 AMI와 CI 빌드 아키텍처까지 연쇄 수정이라 제외)
2. **근본 해결 — 계정을 Paid Plan으로 전환**: 인스턴스 타입 제약 자체가 사라진다. 크레딧은
   이월되고($119.45), 12개월 프리티어가 추가로 열려 시간당 비용도 오히려 낮아진다.

**→ 2번 채택.** `aws freetier upgrade-account-plan` API가 존재하지만 결제 관련 변경이라 콘솔에서
직접 전환했고, `accountPlanType: FREE → PAID` 전환을 API로 검증했다. **코드는 한 줄도 바꾸지
않았고** `t3.medium` 그대로 재시도한 2차 apply가 성공했다(노드그룹 `ACTIVE`, 노드 2대 `Ready`).
이후 destroy/apply 재기동에서도 재현 확인.

**배운 점**

- **EKS 노드그룹 실패는 `health.issues`가 아니라 ASG의 `describe-scaling-activities`에 적힌다.**
  노드그룹 API가 조용하다고 정상인 게 아니다. 다음엔 여기부터 본다.
- 실패 지점을 "인스턴스가 떴는가"로 나눠 보면 원인 범위가 확 줄어든다.
  안 떴으면 → 기동 거부(정책/용량/타입), 떴는데 조인 실패면 → 네트워크/IAM/보안그룹.
- 신규 AWS 계정은 Free Plan일 수 있고, 이 경우 **인스턴스 타입 자체가 정책으로 막힌다.**
  인프라 코드를 짜기 전에 `free-tier-eligible` 필터로 가용 타입을 먼저 확인하는 게 순서다.
- 무증상으로 오래 걸리는 작업일수록 "정상인데 느린 것"과 "조용히 실패 중인 것"을 구분할
  판단 기준(경과 시간 임계치, 확인할 API)을 미리 정해두는 게 낫다.

---

## [2026-08-06] 파드 CreateContainerConfigError — runAsNonRoot는 이름 기반 USER를 검증하지 못한다

> **장애 등급: A** — 서비스 파드 전원 기동 불가 (첫 배포 블로커)

**증상**

2주차 첫 배포에서 파드 2개가 모두 `CreateContainerConfigError` 상태로 멈췄다.
이미지 풀은 성공했고(`Successfully pulled image`), Secret도 정상 존재했다.

```
kubectl get pods -n app
NAME                        READY   STATUS                       RESTARTS
summarizer-7d6b5b86-mzjz9   0/1     CreateContainerConfigError   0
```

**원인 분석**

`kubectl describe pod` / `kubectl get events`로 이벤트를 확인하니 원인이 그대로 적혀 있었다.

```
Error: container has runAsNonRoot and image has non-numeric user (appuser),
cannot verify user is non-root
```

- Dockerfile은 `USER appuser`처럼 **이름**으로 실행 사용자를 지정했다
- 매니페스트에는 보안 강화를 위해 `securityContext.runAsNonRoot: true`를 넣었다
- kubelet은 컨테이너 시작 전에 "정말 non-root인가"를 검증하는데, 이미지 메타데이터에는
  문자열 `appuser`만 있고 **UID가 없어서 root 여부를 판정할 수 없다**. 이름은 컨테이너
  안의 `/etc/passwd`를 읽어야 UID로 환원되는데, 검증 시점은 컨테이너 시작 전이다
- 그래서 kubelet은 "확인 불가 = 거부"로 처리하고 컨테이너 생성 자체를 막는다

즉 **이미지도 매니페스트도 각각은 올바른데, 조합이 검증 불가능**한 경우다.

**해결**

파드 securityContext에 UID를 명시했다 (`useradd -m appuser`는 Debian 기반 이미지에서 UID 1000).

```yaml
securityContext:
  runAsNonRoot: true
  runAsUser: 1000   # 이름 대신 숫자로 명시 → kubelet이 검증 가능
```

재빌드 없이 `kubectl apply`만으로 해결. 근본 대책은 Dockerfile에서부터 숫자 UID를 쓰는 것
(`USER 1000` 또는 `useradd -u 1000`) — 다음 이미지 빌드 때 반영 예정.

**배운 점**

- `CreateContainerConfigError`는 이미지 풀 성공 **이후**, 컨테이너 시작 **이전**의 설정
  검증 단계 실패다. Secret/ConfigMap 누락이 흔한 원인이지만 securityContext 검증 실패도
  여기에 속한다. 원인은 항상 `kubectl describe pod`의 Events에 명시된다
- `runAsNonRoot: true`를 쓸 거면 **UID는 숫자로** — Dockerfile의 `USER`가 이름이라면
  매니페스트의 `runAsUser`로 보완하거나 Dockerfile을 숫자로 바꿔야 한다
- 보안 설정은 "각자 올바름"이 아니라 "조합이 검증 가능함"까지 확인해야 한다

---

## [2026-08-06] GitHub Actions OIDC 인증 실패 — sub 클레임에 숨어 있던 @ID

> **장애 등급: S** — CI/CD 파이프라인 전면 불능, 원인이 에러에 드러나지 않음

**증상**

3주차 CI 첫 실행이 AWS 인증 단계에서 실패했다. 에러는 원인을 전혀 알려주지 않는 한 줄뿐.

```
Could not assume role with OIDC: Not authorized to perform sts:AssumeRoleWithWebIdentity
```

Role·신뢰 정책·OIDC provider(aud=sts.amazonaws.com)를 모두 확인했지만 문법상 이상이 없었고,
정책의 sub 조건과 워크플로의 기대 sub도 문자열이 일치해 보였다.

**원인 분석**

가설을 두 번 세우고 두 번 기각했다.

1. **IAM 전파 지연?** → 19분 후 재실행도 실패. 기각
2. **`ForAllValues:StringEquals` 연산자?** (단일 값 키에 set 연산자를 쓰면 AWS가 거짓으로
   평가하도록 강화된 이력이 있다) → 표준 패턴(StringEquals)으로 교체하고 전파 시간까지
   충분히 준 뒤 재실행해도 실패. 기각

결정적 단서는 **CloudTrail**이었다. 실패한 `AssumeRoleWithWebIdentity` 이벤트는
`requestParameters`를 가리지만, **`userIdentity.userName`에 GitHub가 실제 제시한 sub가
그대로 남는다**:

```
실제 sub:  repo:soc05272@107605885/eks-gitops-portfolio@1316360933:ref:refs/heads/main
정책 조건: repo:soc05272/eks-gitops-portfolio:ref:refs/heads/main   ← 영원히 불일치
```

GitHub가 sub 클레임에 **계정 ID(@107605885)와 저장소 ID(@1316360933)를 덧붙이는 새 형식**을
쓰고 있었다. 계정명/저장소명 변경·탈취 후 재생성(rename attack)에 대비한 변경인데,
Terraform 모듈(iam-github-oidc-role)이 생성하는 조건은 구형식이라 매치될 수 없었다.

**해결**

Role을 모듈 대신 직접 정의하고, sub 조건에 **ID까지 고정**했다. GitHub API로 ID를 교차
검증(`gh api users/<user> --jq .id`, `gh api repos/<o>/<r> --jq .id`)해 CloudTrail 값과
일치함을 확인.

```hcl
Condition = {
  StringEquals = {
    "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
    "token.actions.githubusercontent.com:sub" = "repo:soc05272@107605885/eks-gitops-portfolio@1316360933:ref:refs/heads/main"
  }
}
```

부수 효과로 보안이 오히려 강해졌다 — 계정명이 바뀌거나 동명 계정이 재생성돼도 ID가 다르면
매치되지 않는다.

**배운 점**

- **OIDC "Not authorized" 디버깅은 CloudTrail `userIdentity`부터** — 실패 이벤트에서
  requestParameters는 가려져도 상대가 제시한 sub/aud는 principalId·userName에 남는다.
  추측으로 정책을 고치는 것보다 실제 제시값을 보는 게 압도적으로 빠르다
- 신뢰 정책의 문자열은 "내가 기대하는 값"이 아니라 **"상대가 실제로 보내는 값"**과
  일치해야 한다. 형식이 문서와 다를 수 있다는 것까지 의심할 것
- 커뮤니티 모듈은 외부 서비스의 형식 변화에 뒤처질 수 있다. 인증 경계처럼 민감한 부분은
  모듈이 생성한 정책을 그대로 믿지 말고 산출물을 직접 확인하는 게 낫다

---

## [2026-08-07] RDS 알람 지표가 Prometheus에 안 잡힘 — CloudWatch 타임스탬프 함정

> **장애 등급: B** — RDS 알람 경로 무력화 (지표 미유입, 서비스 영향 없음)

**증상**

cloudwatch-exporter를 설치하고 RDS CPU 알람 규칙을 배포했는데, Prometheus에서
`aws_rds_cpuutilization_average`를 조회하면 결과가 비어 있었다. exporter 파드는 정상
Running이고 에러 로그도 없었다.

**원인 분석**

- exporter의 `/metrics`를 직접 curl해 보니 지표는 존재했고, **값 끝에 과거 타임스탬프**가
  붙어 있었다 — CloudWatch 원본 지표의 생성 시각을 그대로 전달하고 있던 것
- CloudWatch 지표는 수 분 지연되어 집계되므로, 그 원본 타임스탬프는 항상 현재보다
  과거다. Prometheus의 인스턴트 쿼리는 기본 **5분 룩백** 안의 샘플만 반환하므로,
  지연이 룩백을 넘는 순간 "지표는 수집되는데 조회는 빈" 상태가 된다
- 즉 수집(스크레이프)은 성공, 저장도 성공 — **시간축이 어긋나 조회만 실패**하는 구조

**해결**

exporter 설정에 `set_timestamp: false`를 지정 — CloudWatch 원본 시각 대신
**스크레이프 시각**을 샘플에 붙이게 했다. 적용 직후 쿼리에 값이 잡혔고(CPU 3.8%),
RDS CPU 알람 규칙까지 로드 확인.

**배운 점**

- "지표가 안 보인다"의 원인이 수집 실패가 아닐 수 있다 — **exporter의 `/metrics`를
  직접 curl해 원본을 보면** 수집/저장/조회 중 어느 단계의 문제인지 바로 갈린다
- 서로 다른 시스템을 잇는 지점에서는 **시간축(타임스탬프)의 소유권**이 암묵적 함정이
  된다 — 지연 집계형 소스(CloudWatch)는 원본 시각을 버리는 게 정답일 수 있다

---

## [2026-08-14] ArgoCD `Invalid username or token` 재발 — 클립보드 경유 등록의 구조적 함정

> **장애 등급: A** — CD(ArgoCD) 경로 불능 · 재발성 (앱 가동은 유지)

**증상**

재기동 리허설에서 PAT를 재발급·등록했는데 ArgoCD Application이 `Unknown` 상태에 머물렀다.

```
ComparisonError: failed to list refs: authentication required:
Invalid username or token. Password authentication is not supported for Git operations.
```

같은 에러를 8/6에 이미 겪었고(그때는 개행 혼입), 그 교훈으로 `pbpaste` 방식까지 도입한
상태였다. 그런데도 재발했다.

**원인 분석**

등록된 값을 노출 없이 형태만 검사했다 — 길이·앞 몇 글자·줄 수만 보면 토큰이 맞는지
판정할 수 있다.

```bash
PW=$(kubectl get secret repo-eks-gitops-manifests -n argocd \
     -o jsonpath='{.data.password}' | base64 -d)
echo "길이: ${#PW} / 앞 11자: ${PW:0:11}"
# 길이: 237 / 앞 11자: kubectl cre   ← 토큰이 아니라 명령어 텍스트
```

password에 들어간 것은 **등록 명령어 자체**였다. 진행 순서가 이랬다:

1. GitHub에서 PAT 복사 → 클립보드 = 토큰
2. 안내받은 등록 명령 블록을 **복사** → 클립보드 = 명령어 (토큰 덮어씀)
3. 명령 실행 → `$(pbpaste)`가 명령어 텍스트를 password로 등록

즉 8/6의 개행 문제를 고친 `pbpaste` 방식이 **새로운 실패 모드**를 만들었다.
"클립보드에서 읽는다"는 설계는 클립보드가 토큰 복사와 명령 복사에 공유되는 순간
실행 순서에 의존하게 되고, 이는 사람이 지키기 어려운 암묵적 전제다.

**해결**

클립보드를 데이터 경로에서 아예 제거했다 — hidden prompt로 토큰을 변수에 한 번 받아
필요한 모든 곳(ArgoCD Secret + CI용 GitHub secret)에 등록하고 즉시 폐기한다.

```bash
read -s "TOKEN?PAT 붙여넣기: "; echo
kubectl delete secret repo-eks-gitops-manifests -n argocd
kubectl create secret generic repo-eks-gitops-manifests -n argocd \
  --from-literal=type=git \
  --from-literal=url=https://github.com/soc05272/eks-gitops-manifests.git \
  --from-literal=username=x-access-token --from-literal=password="$TOKEN"
kubectl label secret repo-eks-gitops-manifests -n argocd \
  argocd.argoproj.io/secret-type=repository
printf '%s' "$TOKEN" | gh secret set MANIFEST_REPO_TOKEN --repo soc05272/eks-gitops-portfolio
unset TOKEN
```

재등록 후에도 Application은 `Unknown`에 머물렀다 — 이전 비교 실패가 캐시되어 있어서다.
`kubectl annotate application summarizer -n argocd argocd.argoproj.io/refresh=hard --overwrite`
로 강제 새로고침하자 수 초 내 `Synced/Healthy`로 전환, 매니페스트 기준 이미지로 롤링 배포까지
자동 수행됐다.

**배운 점**

- **같은 증상의 두 번째 발생은 "더 조심하기"가 아니라 절차 자체를 바꿔야 한다는 신호다.**
  1차(개행) 대응이 "복사를 더 잘하기"였다면, 2차 대응은 클립보드라는 공유 자원을
  데이터 경로에서 제거하는 것이었다
- 비밀값 등록 실패의 1차 진단은 **값을 노출하지 않고 길이·접두사·줄 수만 확인**하는 것.
  토큰류는 형식이 정해져 있어(fine-grained PAT: 93자, `github_pat_` 접두사) 이것만으로
  "무엇이 잘못 들어갔는지"까지 특정된다
- 자격증명을 고친 뒤 ArgoCD가 계속 `Unknown`이면 **hard refresh**부터 — 이전 실패 상태가
  캐시되어 재시도가 즉시 반영되지 않을 수 있다

---

## [2026-08-14] 롤링 배포 직후 ALB 응답 실패 1회 — rollout 성공이 LB 무중단을 보장하지 않는다

> **장애 등급: B** — 단발 요청 실패 (무중단 설계의 빈틈 발견)

**증상**

GitOps 리허설에서 0.2.1 롤링 배포가 `deployment successfully rolled out`으로 끝난 **직후**,
ALB 경유 `curl -f /healthz`가 1회 HTTP 에러(exit 22)로 실패했다. 15초 뒤부터는 연속 3회
모두 정상 응답. 상태코드는 미확보 — `-f`는 4xx/5xx 여부만 알려준다. 재현 시에는
`curl -sw '%{http_code}'`로 코드까지 잡을 것.

**원인 분석**

쿠버네티스와 ALB의 **완료 판정 기준이 다르다**는 것이 핵심이다.

- `rollout status`의 성공 기준: 신규 파드가 readiness 프로브를 통과하고 구 파드 종료가
  시작됨 — **쿠버네티스 내부** 관점
- ALB의 트래픽 전환: 타깃 그룹에서 구 파드 IP의 등록 해제(draining)와 신규 파드 IP의
  헬스체크 통과가 **비동기로** 진행 — 쿠버네티스 완료 시점과 어긋난다

이 프로젝트는 `target-type: ip`로 파드 IP를 직접 타깃 등록하므로, 롤링 중에
"이미 종료됐지만 아직 draining 중인 구 파드" 또는 "떴지만 ALB 헬스체크 미통과인 신규
파드"로 요청이 가는 짧은 창이 생긴다. 관측된 실패 1회는 이 창에 들어간 요청이다.

**해결 (백로그 등록 — 발생 빈도가 낮아 5주차 이후 반영)**

ALB 컨트롤러가 제공하는 **Pod Readiness Gate**가 표준 해법이다:

```bash
kubectl label namespace app elbv2.k8s.aws/pod-readiness-gate-inject=enabled
```

이후 뜨는 파드에는 "ALB 타깃 그룹에서 healthy 판정"이 readiness 조건으로 주입되어,
**ALB가 신규 파드로 트래픽을 보낼 준비가 되기 전에는 구 파드 종료가 시작되지 않는다.**
보조 수단으로 preStop `sleep`(종료 전 draining 시간 확보)을 함께 쓰기도 한다.

**배운 점**

- `rollout status` 성공은 쿠버네티스 관점의 완료다. **LB까지 포함한 무중단은 별도 장치
  (readiness gate)가 필요하다** — "어느 계층의 완료인가"를 항상 구분할 것
- 검증 루프의 실패 1회를 "재시도하니 되네"로 넘기지 않고 원인을 특정해두면, 훗날
  프로덕션에서 배포 때마다 5xx가 튀는 문제의 답을 미리 가진 셈이 된다

---

## [2026-08-26] Grafana CrashLoopBackOff — 보수적 리소스 제한의 한계 실측

> **장애 등급: B** — 관측 구성요소 부분 장애 (자동 재시작으로 간헐 복구)

**증상**

캡처 세션 중 Grafana 접속이 끊겼다. 처음엔 포트포워딩 터널 문제로 보였으나
재연결해도 곧 다시 끊겼고, 파드를 보니 재시작이 반복되고 있었다.

```
monitoring-grafana-687f485f85-lvfnl   2/3   CrashLoopBackOff   2 (16s ago)
```

**원인 분석**

- 재시작 사유는 파드 상태에 그대로 남아 있다:
  `.status.containerStatuses[].lastState.terminated.reason` → **`OOMKilled`**
- 4주차에 t3.medium 노드 절약을 위해 Grafana 메모리 제한을 256Mi로 보수적으로
  설정해뒀는데, HPA 부하 테스트 직후의 대시보드 조회(1시간 범위 CPU 그래프 등)가
  겹치면서 한계를 넘었다
- 증상의 겉모습(터널 끊김)과 원인(컨테이너 OOM)의 계층이 달랐다 — 터널만 계속
  다시 열었다면 원인 없이 증상만 반복됐을 것

**해결**

`helm upgrade --reuse-values --set grafana.resources.limits.memory=512Mi`로 즉시 복구.
라이브 수정으로 끝내지 않고 **values.yaml에 실측 근거 주석과 함께 반영**(`bf6950c`)해
다음 재기동 때 재발하지 않게 했다 — 라이브 상태와 코드의 일치가 IaC 운영의 전제.

**배운 점**

- 리소스 제한은 추정이 아니라 **실사용 패턴으로 검증**해야 한다 — "평소엔 충분"과
  "부하 조회 시 충분"은 다르다
- 증상이 보이는 계층(네트워크 터널)과 원인이 있는 계층(컨테이너 메모리)은 다를 수
  있다 — 재발하는 증상은 한 계층 아래를 볼 신호
- 계획에 없던 실제 장애가 알람 채널에 이벤트로 찍히고, 진단·해결·코드 반영까지
  이어진 것 자체가 관측성 스택이 제 역할을 한 증거
