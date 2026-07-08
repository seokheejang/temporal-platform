# 0004. 얇은 공통 base + 서비스 독립 (3-layer values)

- Status: Accepted
- Date: 2026-06-04

## Context
서비스별 독립 클러스터([0003](0003-per-service-independent-clusters.md))지만, 조직 전역값(레지스트리, 공통 labels/annotations, securityContext, 모니터링 기본)까지 서비스마다 복붙하면 N곳 수정 문제가 생긴다. 완전 독립 vs 공통 base의 균형이 필요.

## Decision
**얇은 공통 base + 서비스 독립**. 정말 전역적인 것만 `base/`에 두고, 나머지 설계는 서비스별로 자유롭게 둔다. values는 3-layer로 합성:

```
base/values-common.yaml          (조직 전역)
  └─ services/<svc>/values.yaml   (서비스 공통 = 설계 차별점)
       └─ services/<svc>/<env>/values.yaml  (dev/prod 차이만)
```

## Consequences
- 전역 변경은 base 한 곳, 서비스 설계는 자유 → DRY와 독립성 동시 확보.
- 실제 merge 메커니즘(Helm valueFiles 순서 vs kustomize 등)은 chart 전략(R1) 확정 후 결정.
- base는 "얇게" 유지하는 규율이 필요(전역 아닌 값이 새어들면 독립성 훼손).
