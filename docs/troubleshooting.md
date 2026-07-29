# 트러블슈팅 기록

> 형식: 증상 → 원인 분석 → 해결 → 배운 점. 삽질한 날 바로 기록할 것 (나중에 쓰려면 다 잊어버린다).

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

<!-- 아래에 실제 사례를 추가 -->

## [2026-07-29] EKS 노드그룹이 CREATE_FAILED — AWS Free Plan 계정의 인스턴스 타입 제약

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

`c7i-flex.large`가 원래 쓰려던 `t3.medium`과 총 메모리(8GB)·비용($0.036 → $0.037)이
사실상 동일해 대체재로 적합하다. `variables.tf`의 `node_instance_type` 기본값만 바꾸면 된다.

ARM 타입(`t4g.small`)이 더 저렴하지만 채택하지 않았다. `ami_type`을 `AL2023_ARM_64_STANDARD`로
바꿔야 하고, GitHub Actions에서 빌드하는 앱 이미지도 arm64로 빌드해야 해서 CI까지 연쇄 수정이 필요하다.

**배운 점**

- **EKS 노드그룹 실패는 `health.issues`가 아니라 ASG의 `describe-scaling-activities`에 적힌다.**
  노드그룹 API가 조용하다고 정상인 게 아니다. 다음엔 여기부터 본다.
- 실패 지점을 "인스턴스가 떴는가"로 나눠 보면 원인 범위가 확 줄어든다.
  안 떴으면 → 기동 거부(정책/용량/타입), 떴는데 조인 실패면 → 네트워크/IAM/보안그룹.
- 신규 AWS 계정은 Free Plan일 수 있고, 이 경우 **인스턴스 타입 자체가 정책으로 막힌다.**
  인프라 코드를 짜기 전에 `free-tier-eligible` 필터로 가용 타입을 먼저 확인하는 게 순서다.
- 무증상으로 오래 걸리는 작업일수록 "정상인데 느린 것"과 "조용히 실패 중인 것"을 구분할
  판단 기준(경과 시간 임계치, 확인할 API)을 미리 정해두는 게 낫다.
