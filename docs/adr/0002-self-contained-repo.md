# 0002. repo 자기완결 (ArgoCD 매니페스트 포함)

- Status: Accepted
- Date: 2026-06-04

## Context
ArgoCD GitOps([0001](0001-deploy-with-argocd-gitops.md)) 채택 후, ArgoCD Application/ApplicationSet CR을 어디에 둘지 선택: 중앙 GitOps repo vs 이 repo.

## Decision
이 repo를 **자기완결적**으로 둔다. ArgoCD Application/ApplicationSet/AppProject 매니페스트를 이 repo의 `argocd/` 아래에 두고, values와 함께 단일 source of truth로 관리한다.

## Consequences
- Temporal 인프라 한 덩어리가 이 repo 안에서 완결 → 추론·온보딩 쉬움.
- 중앙 app-of-apps가 있다면 이 repo의 root app/ApplicationSet 하나만 등록하면 됨.
- argocd/ 매니페스트의 `source` 형태는 chart 전략(R1) 확정 후 채운다.
