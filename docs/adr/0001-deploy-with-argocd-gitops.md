# 0001. ArgoCD GitOps로 배포

- Status: Accepted
- Date: 2026-06-04

## Context
Temporal 인프라를 k8s에 Helm으로 배포한다. 배포 적용 방식(GitOps vs Helmfile vs plain Helm CLI)이 repo 전체 디렉토리 구조의 루트를 결정한다. 조직(example-org)에 ArgoCD 컨벤션이 존재.

## Decision
**ArgoCD GitOps**로 배포한다. 이 repo를 source로 ArgoCD Application이 클러스터에 sync 한다.

## Consequences
- drift 감지·자동 동기화·선언적 이력 확보.
- 디렉토리에 `argocd/`(Application 등) 자리 필요 → [0002](0002-self-contained-repo.md).
- 서비스가 늘어나는 모델이라 ApplicationSet(service × env 제너레이터) 활용을 검토.
