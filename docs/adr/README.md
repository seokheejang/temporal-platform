# Architecture Decision Records (ADR)

중요한 아키텍처 결정을 한 파일 = 한 결정으로 기록한다. 번호는 단조 증가.

## 포맷
```
# NNNN. <결정 제목>
- Status: Accepted | Proposed | Superseded by NNNN
- Date: YYYY-MM-DD
- Context: 왜 이 결정이 필요했나
- Decision: 무엇을 결정했나
- Consequences: 결과 / 트레이드오프
```

## 목록
| # | 결정 | 상태 |
|---|------|------|
| [0001](0001-deploy-with-argocd-gitops.md) | ArgoCD GitOps로 배포 | Accepted |
| [0002](0002-self-contained-repo.md) | repo 자기완결 (ArgoCD 매니페스트 포함) | Accepted |
| [0003](0003-per-service-independent-clusters.md) | 서비스별 독립 Temporal 클러스터 (+ dev/prod) | Accepted |
| [0004](0004-thin-shared-base.md) | 얇은 공통 base + 서비스 독립 (3-layer values) | Accepted |
| [0005](0005-umbrella-wrapper-per-service.md) | 서버 chart = 서비스별 umbrella wrapper + 같은 repo 2-source | Accepted |
| [0006](0006-shared-generic-worker-chart.md) | SDK worker = 공용 generic 차트 (서버는 서비스별, worker는 공용) | Accepted |

> 보류 중인 결정(persistence 등)은 확정되면 여기에 ADR로 추가된다. [../research/](../research/) 참고.
