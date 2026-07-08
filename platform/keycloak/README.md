# platform/keycloak — Temporal SSO용 IdP (K1)

self-hosted **Keycloak** (MVP 결정 2026-06-11). Temporal OIDC JWT의 발급자.
로그인은 Google 브로커링(K3 — 비밀번호 미보관), Temporal claim 매핑은 K2에서.

## 결정 (2026-06-11)

| 항목 | 결정 | 근거 |
|---|---|---|
| 위치 | **dev in-cluster** (ns `keycloak`) | 플랫폼 재활용(cnpg·ESO·Gateway·LE)·realm IaC로 이동성. 전사 IdP 승격 시 외부 재검토 |
| 배포 | **codecentric `keycloakx`** chart 7.2.0 (Keycloak 26.6.2) | helm values 패턴·ArgoCD 적합. bitnami는 라이선스 리스크 제외 |
| realm IaC | **keycloak-config-cli** (jkroepke chart 1.3.7) — K2에서 | 지속 reconcile(드리프트 교정), operator의 1회성 import 한계 회피 |
| DB | 전용 cnpg `keycloak-pg` (2 inst · standard · 10Gi) | dev 기존 another-workload-pg 패턴 동일 |
| 노출 | `keycloak.dev.k8s.example.com` — shared-gateway HTTPRoute(차트 내장) | wildcard LE cert로 커버, TLS는 gateway 종단 |
| URL prefix | `/auth` (keycloakx 기본 유지) | issuer = `https://keycloak.dev.k8s.example.com/auth/realms/<realm>` |
| 시크릿 | Vault KV → ESO(`vault-secret-store`) | 기존 cnpg 패턴 동일 (basic-auth) |
| 규모 | replicas 1 (MVP) | HA·cache 클러스터링(JGroups)은 prod 단계 |

## 파일

```
namespace.yaml          ns keycloak
externalsecrets.yaml    keycloak-pg-app(DB) · keycloak-admin(부트스트랩) ← Vault KV
cnpg-cluster.yaml       keycloak-pg (PostgreSQL)
values-keycloakx.yaml   keycloakx 차트 values (helm template 렌더 검증됨 2026-06-11)
```

## 적용 순서 (운영자 실행 — 이 repo 보조는 read-only)

```bash
# 0. Vault KV 시드 (선행 — KV 쓰기 가능한 운영자 토큰 필요, temporal-pki 토큰 불가)
#    비밀번호 랜덤 생성·히스토리 미노출·기존 값 보호(--force 없으면 건너뜀)
VAULT_ADDR=https://vault.example.com VAULT_TOKEN=<운영자토큰> ./platform/keycloak/seed-kv.sh dev

# 1. ns + 시크릿 + DB
kubectl apply -f platform/keycloak/namespace.yaml
kubectl apply -f platform/keycloak/externalsecrets.yaml
kubectl get externalsecret -n keycloak          # 둘 다 SecretSynced 확인
kubectl apply -f platform/keycloak/cnpg-cluster.yaml
kubectl get cluster -n keycloak                 # Cluster in healthy state 대기

# 2. Keycloak (ArgoCD 등록 전 임시 — A6에서 Application으로 전환)
helm upgrade --install keycloak keycloakx \
  --repo https://codecentric.github.io/helm-charts --version 7.2.0 \
  -n keycloak -f platform/keycloak/values-keycloakx.yaml

# 3. 검증
kubectl get pods -n keycloak                    # keycloak-keycloakx-0 Ready
kubectl get httproute -n keycloak               # hostname 확인
curl -s https://keycloak.dev.k8s.example.com/auth/realms/master/.well-known/openid-configuration | jq .issuer
# → 브라우저: /auth/admin → keycloak-admin 자격증명 로그인
```

## 다음 단계

- **K2**: realm `temporal` + OIDC client(UI·CLI) + role + ⭐`permissions` protocol mapper(`namespace:role` 포맷) — keycloak-config-cli로 IaC
- **K3**: Google upstream IdP 브로커링 (Google 콘솔 client 필요 — 크로스팀)
- **B6**: Temporal ClaimMapper/Authorizer 연동 (K2 + Temporal 배포 후)
- **K5**: realm export 백업 · prod HA

## 배포 검증 (2026-06-11 dev)

- ✅ cnpg 2/2 healthy · KC 26.6.2 기동 · ESO 주입 admin 생성("Created temporary admin user") · 콘솔 로그인 성공
- ✅ OIDC issuer = `https://keycloak.dev.k8s.example.com/auth/realms/master` — DNS→Gateway→HTTPRoute→KC 전 체인 정상

## 확인 필요 / 운영 메모

- ⚠️ `KC_BOOTSTRAP_ADMIN_*`로 만든 admin은 KC 26에서 **임시 계정 취급** — 콘솔에서 영구 admin 생성 후 임시 계정 정리 권장 (일상 로그인은 K3 Google 브로커링으로 대체 예정)
- replicas>1 시 JGroups DNS discovery env 추가 필요 (`values-keycloakx.yaml` 주석)
- ArgoCD Application 등록은 chart 전략(A5/A6) 확정 후
