# argocd/

이 repo를 source로 클러스터에 sync하는 ArgoCD 매니페스트 (ADR [0001](../docs/adr/0001-deploy-with-argocd-gitops.md)/[0002](../docs/adr/0002-self-contained-repo.md)/[0005](../docs/adr/0005-umbrella-wrapper-per-service.md)).

## 구조 — 환경(클러스터)별 분리 (per-cluster ArgoCD)

조직 모델은 **클러스터마다 자기 ArgoCD**(실측 2026-06-11: dev ArgoCD는 in-cluster만 등록).
ApplicationSet은 자기가 설치된 ArgoCD에만 Application을 만들므로, **환경 디렉토리를 그 환경 클러스터의 ArgoCD에 apply**한다.
두 환경의 AppSet은 같은 `services/`를 바라보고 generator 패턴만 다르다(`services/*/dev` vs `services/*/prod`) — 진실의 원천은 한 repo.

```
argocd/
├── dev/                         # → dev 클러스터(dev · dev-cluster)의 ArgoCD에 apply
│   ├── project.yaml             #   AppProject temporal (소스/대상 화이트리스트)
│   ├── applicationset.yaml      #   서버 앱: services/*/dev → temporal-{svc}-dev (2-source·3-layer)
│   └── applicationset-db.yaml   #   DB 앱:  services/*/dev/db → temporal-{svc}-db-dev (env-first 구조)
└── prod/                        # → prod 클러스터(prod · prod-cluster)의 ArgoCD에 apply (미구축 — README 참고)
```

## 동작

- generator(git directories)가 GitHub 원격을 스캔 → 디렉토리마다 Application 자동 생성.
  **새 서비스 추가 = `services/<svc>/` 디렉토리 추가 + push** (AppSet 수정 불필요).
- 앱 간 순서: **DB 앱 먼저 sync·healthy → 서버 앱 sync** (MVP 수동 — automated 전환 시 재검토).
- ⚠️ ArgoCD는 push된 커밋만 본다 — 로컬 변경은 sync에 반영되지 않음.

## 적용 (운영자)

```bash
# dev (dev 클러스터)
KUBECONFIG=~/.kube/dev-cluster kubectl apply -f argocd/dev/
```
