# argocd/prod — placeholder (prod 클러스터 prod 미구축)

prod 클러스터(prod · prod-cluster)의 ArgoCD에 apply할 매니페스트 자리. `argocd/dev/`를 복제해 다음만 바꾼다:

- generator: `services/*/dev` → `services/*/prod` (applicationset · applicationset-db 동일)
- destination은 그대로 in-cluster (prod ArgoCD가 자기 클러스터에 배포)

## 선행 조건 (prod 배포 게이트)

- [ ] prod ArgoCD에 이 repo 등록 (repo credential)
- [ ] Vault: `auth/kubernetes-prod/role/cert-manager-temporal` 생성 + ClusterIssuer prod 적용 ([런북](../../docs/runbooks/vault-pki-setup.md))
- [ ] Vault KV 시드: `k8s/temporal/<svc>/prod/db`
- [ ] prod에 cnpg·ESO·cert-manager·Gateway 존재 확인 (dev 실측 패턴과 대조)
- [ ] 사이징 확정 (R5 — 부하테스트 기반) · prod 전용 Intermediate 분리 여부 결정
