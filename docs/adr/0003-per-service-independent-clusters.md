# 0003. 서비스별 독립 Temporal 클러스터 (+ dev/prod)

- Status: Accepted
- Date: 2026-06-04

## Context
서비스마다 Temporal 사용 양상이 다르고, 서비스 A/B를 각각 다르게 설계해야 한다. Temporal 멀티테넌시는 (a) 공유 클러스터 + namespace 격리, (b) 서비스별 독립 클러스터 중 선택 가능.

## Decision
**서비스별 독립 Temporal 클러스터**를 둔다. 각 서비스는 자체 클러스터(frontend/history/matching/worker + 자체 DB)를 갖고 독립적으로 설계한다. 각 서비스 내부에는 **dev / prod** 두 환경을 둔다.

→ 구조 단위: `services/<service>/<env>/`.

## Consequences
- 강한 격리, 독립 스케일/버전/persistence. "다르게 설계" 가능.
- DB·운영 비용이 서비스 수에 비례(N배) → 비용 추정 필요(R4).
- 표준화가 중요 → `services/_template/` + ArgoCD ApplicationSet.
- 배경: [../research/topology.md](../research/topology.md).
