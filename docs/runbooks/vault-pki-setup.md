# Runbook — Vault PKI 세팅 (Temporal mTLS 공통 CA)

> **상태: ✅ 구축 완료 (2026-06-11) — 1~4-1 실행됨.** Temporal mTLS용 공통 사설 CA를 사내 Vault(`vault.example.com`)의 PKI secrets engine으로 구축하는 절차.
> 실행 기록·런북 대비 변경점은 아래 [실행 기록](#실행-기록-2026-06-11) 참고. 4-2(ClusterIssuer apply)·5(외부 worker)는 미실행.
> 관련 개념: [../architecture/concepts-essentials.html](../architecture/concepts-essentials.html) (§4 보안 - mTLS/PKI) · 용어는 [../glossary.md](../glossary.md) §6.
> **개념 이해**(PKI engine이 뭔지·sign vs issue·TTL 층위·권한 모델): [../research/vault-pki-engine.md](../research/vault-pki-engine.md) ← 절차만 따라하기 전에 일독 권장.

## ⚠️ 실행 원칙
- 아래 **변경(mutating) 명령은 운영자가 직접 실행**한다. (이 repo의 자동화/AI 보조는 read-only 점검·가이드만)
- 지금 확인에 쓴 **root 토큰 직접 사용은 지양** — 세팅 후 전용 정책(`temporal-pki`)으로 좁히고 **root 토큰은 rotate**.
- `vault` CLI는 PKI 권한이 있는 워크스테이션/바스천에서 실행(또는 동등한 HTTP API). `export VAULT_ADDR="https://vault.example.com"`.

---

## 0. 검증된 현재 환경 (2026-06-08, read-only 점검)

| 항목 | 실측값 | 함의 |
|------|--------|------|
| Vault | **OSS(Community) 1.21.2**, initialized·unsealed | PKI engine 내장 — 별도 라이선스 불필요 |
| secrets engines | `cubbyhole` · `identity` · `secret`(KV v2) · `sys` | **PKI mount 없음 → 신규 구축 필요** |
| auth methods | **`approle`** · **`kubernetes-dev/`** · **`kubernetes-prod/`** · `userpass` · `token` | cert-manager는 `kubernetes-dev/` 재활용, 외부 worker는 `approle` |
| 현재 Vault 용도 | External Secrets Operator(`ClusterSecretStore: vault-secret-store`) + `vault-agent-injector` | **앱 시크릿(KV)** 용 — 인증서/PKI와 무관 |

> 즉 "Vault는 이미 있고 PKI만 없는" 상태. PKI mount + Root/Intermediate를 새로 만들면 됨.

---

## 1. Root CA (dev: Vault 내부 생성)

> prod 정석은 **외부 오프라인 Root**에서 Intermediate만 서명하는 것. dev/PoC는 Vault 내부 root로 시작 가능.

```bash
vault secrets enable -path=pki pki
vault secrets tune -max-lease-ttl=87600h pki                       # 10년
vault write -field=certificate pki/root/generate/internal \
    common_name="Example Internal Root CA" \
    issuer_name="root-2026" ttl=87600h \
    key_type=rsa key_bits=4096 > base/pki/root-ca.crt    # CA 계층은 4096 (장수명 보강, 실행값)
vault write pki/config/urls \
    issuing_certificates="$VAULT_ADDR/v1/pki/ca" \
    crl_distribution_points="$VAULT_ADDR/v1/pki/crl"
```

## 2. Intermediate CA (Temporal 전용 mount)

> 범용 PKI와 섞지 않도록 **Temporal 전용 mount**(`pki_temporal_int`)로 격리.

```bash
vault secrets enable -path=pki_temporal_int pki
vault secrets tune -max-lease-ttl=43800h pki_temporal_int          # 5년

# (a) CSR 생성
vault write -field=csr pki_temporal_int/intermediate/generate/internal \
    common_name="Temporal Intermediate CA" \
    issuer_name="temporal-int-2026" \
    key_type=rsa key_bits=4096 > t_int.csr               # CA 계층은 4096 (실행값)

# (b) Root로 서명
vault write -field=certificate pki/root/sign-intermediate \
    issuer_ref="root-2026" csr=@t_int.csr \
    format=pem_bundle ttl=43800h > t_int.crt

# (c) 서명된 cert를 다시 import
vault write pki_temporal_int/intermediate/set-signed certificate=@t_int.crt

vault write pki_temporal_int/config/urls \
    issuing_certificates="$VAULT_ADDR/v1/pki_temporal_int/ca" \
    crl_distribution_points="$VAULT_ADDR/v1/pki_temporal_int/crl"
```

## 3. Role (발급 규칙) — internode EKU 함정 주의

```bash
vault write pki_temporal_int/roles/temporal-server \
    allowed_domains="cluster.local,svc.cluster.local,dev.k8s.example.com" \
    allow_subdomains=true \
    allow_bare_domains=true \
    max_ttl=2160h \
    key_type=rsa key_bits=2048 \
    server_flag=true client_flag=true
```
> ⚠️ **internode mTLS cert는 EKU에 ServerAuth + ClientAuth 둘 다** 필요(피어가 서버이자 클라이언트). Vault role 기본값이 `server_flag=true client_flag=true`라 충족되지만 명시해 둠.

## 4. cert-manager 연동 (in-cluster · `kubernetes-dev/` 재활용)

### 4-1. Vault 측 (직접 실행)
```bash
vault policy write temporal-pki - <<'EOF'
path "pki_temporal_int/sign/temporal-server"  { capabilities = ["create","update"] }
path "pki_temporal_int/issue/temporal-server" { capabilities = ["create","update"] }
EOF

vault write auth/kubernetes-dev/role/cert-manager-temporal \
    bound_service_account_names="cert-manager" \
    bound_service_account_namespaces="cert-manager" \
    policies="temporal-pki" ttl=10m
```
> 전제: `kubernetes-dev/` auth는 이미 dev용으로 구성됨(token reviewer 등). cert-manager SA 토큰 검증이 되는지 4-3에서 확인.

### 4-2. k8s 측 (ArgoCD/GitOps로 apply — 이 repo의 K8s 변경은 선언적으로만)
```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: temporal-ca-issuer
spec:
  vault:
    server: https://vault.example.com
    path: pki_temporal_int/sign/temporal-server
    auth:
      kubernetes:
        mountPath: /v1/auth/kubernetes-dev      # 기존 auth mount 재활용
        role: cert-manager-temporal
        serviceAccountRef:
          name: cert-manager
```
이후 Temporal namespace에 `Certificate` 리소스를 만들면 cert-manager가 Vault에서 발급하고 **만료 전 자동 갱신**한다(기존 cert들과 동일 메커니즘 — `status.renewalTime`).

### 4-3. 검증 (read-only)
```bash
vault read auth/kubernetes-dev/role/cert-manager-temporal
# k8s 측: kubectl describe clusterissuer temporal-ca-issuer  → Ready=True 확인
```

## 5. 외부 SDK Worker (cluster 밖 · `approle`)

> cert-manager는 in-cluster 전용이라 외부 worker엔 발급 못 함 → Vault에서 직접 발급/갱신.

```bash
vault policy write temporal-worker - <<'EOF'
path "pki_temporal_int/issue/temporal-server" { capabilities = ["create","update"] }
EOF
vault write auth/approle/role/temporal-worker token_policies="temporal-worker" token_ttl=1h

# worker: role_id/secret_id 로그인 후 발급 (또는 Vault Agent로 자동 갱신)
vault write pki_temporal_int/issue/temporal-server \
    common_name="worker-1.<svc>" ttl=2160h
```

## 6. Temporal 서버 mTLS 신뢰 설정 (개략)
- frontend `clientCAFiles` = **공통 Root CA**(`root_ca.crt`) → 내부(cert-manager 발급)·외부(worker AppRole 발급) leaf를 한 루트로 신뢰.
- internode/frontend `tls` 블록에 cert-manager가 채운 Secret 마운트. (상세는 차트 전략 확정 후)

## 7. 자동갱신 ≠ 무중단 — 워크로드 reload 전략 (중요)

cert-manager는 **Secret만 갱신**하고 **파드를 재기동하지 않는다.** 앱이 cert를 시작 시 1회만 읽어 메모리에 들고 있으면, Secret이 갱신돼도 **옛 cert를 계속 쓰다 만료 시 mTLS 실패 → 장애**가 날 수 있다. 소비자별로 반영 방식이 다르다.

| 소비자 유형 | 갱신 반영 | 재기동 필요? |
|---|---|:---:|
| **프록시/게이트웨이가 TLS 종단**(Envoy·Cilium Gateway) | Secret 핫리로드(SDS) | ❌ |
| **operator가 cert 관리**(예: DB operator) | operator가 rotation 오케스트레이션 | operator 처리 |
| **앱이 cert 파일 핫리로드**(file watch/refresh) | 앱이 주기적 재로드 | ❌ |
| **앱이 시작 시 1회만 읽음 + 핫리로드 없음** | ⚠️ 반영 안 됨 | ✅ **재기동 필요** |

**dev 기보유 안전장치 (실측 2026-06-08):**
- **Cilium Gateway**(Envoy): `*.dev.k8s.example.com` cert 핫리로드 → 게이트웨이 재기동 불필요.
- **stakater/Reloader 설치됨**(`reloader` ns) — ⚠️ **실측(2026-06-08): `--auto-reload-all` 미설정 = 기본 opt-in 모드, annotation 단 워크로드 0개 → 현재 미사용(아무것도 안 함).** 쓰려면 워크로드에 annotation opt-in:
  - `reloader.stakater.com/auto: "true"` (마운트된 모든 cm/secret 변경 시), 또는
  - `secret.reloader.stakater.com/reload: "<secret-name>"` (특정 secret만 — **cert엔 이게 적합**).
  - 동작: Secret 변경 감지 → pod template 패치 → **정상 롤링 재기동**(전략·PDB 준수).
  - ❗ annotation은 **Deployment 최상위 `metadata.annotations`** 에 (파드 템플릿 아님). helm 차트가 보통 `podAnnotations`만 노출하므로 **Deployment-level annotation 지원 여부 확인** 필요.
- **DB operator**: 앱 cert rotation 관리.

**Temporal 적용 시:**
- Temporal 서버는 TLS cert **자동 reload를 지원**하는 것으로 알려짐(파일 refresh) → 재기동 없이 반영 가능. **우리 차트/버전 실제 동작 확인 필요(확인 필요).**
- 안전망으로 Temporal Deployment에 **Reloader annotation 병행** 권장.
- ⚠️ **subPath 마운트 함정**: Secret을 `subPath`로 마운트하면 **갱신 파일이 반영 안 됨**(k8s 동작) → cert는 subPath 없이 디렉토리 마운트.

**route53 DNS-01 solver 의존성 (공개 cert 갱신):**
- `letsencrypt-prod`는 **Secret `route53-credentials`(정적 AWS access key)** 로 DNS-01 갱신(실측 Ready=True).
- ⚠️ 이 **AWS 키가 rotate/비활성화되면 갱신이 조용히 실패**하고 만료 때 드러난다. `renewBefore=30d` 버퍼가 있으나 → **Certificate Ready 상태/만료 임박 알람** 필요. (on-prem라 IRSA 대신 정적 키 → 모니터링이 완화책)

---

## 검증 체크리스트 (read-only — 보조 실행 가능)

> 명령마다 필요한 권한이 다르다. `temporal-pki` 토큰(일상 운영)으로 되는 것과 관리자 권한이 필요한 것을 구분.
> 2026-06-11 실측: 비인증·temporal-pki 단계 모두 통과, 권한 밖 명령은 거부 확인(최소권한 동작).

```bash
# ① 토큰 불필요 (비인증 공개 엔드포인트 — trust 배포용)
curl -s "$VAULT_ADDR/v1/pki/ca/pem"              | openssl x509 -noout -subject          # Root CA
curl -s "$VAULT_ADDR/v1/pki_temporal_int/ca/pem" | openssl x509 -noout -subject -issuer  # Intermediate

# ② temporal-pki 토큰으로 가능 (.token)
vault token lookup -format=json | jq '.data | {display_name, policies, ttl}'
vault write -format=json pki_temporal_int/issue/temporal-server \
    common_name="smoke.temporal.svc.cluster.local" ttl=5m \
  | jq -r '.data.certificate' | openssl x509 -noout -subject -enddate   # 발급 스모크
# (vault list pki_temporal_int/roles 는 이 토큰으로 "거부"가 정상 — 최소권한 확인용)

# ③ 관리자(root급) 권한 필요
vault list pki_temporal_int/roles
vault read  auth/kubernetes-dev/role/cert-manager-temporal

# ④ k8s 측 (ClusterIssuer apply 후)
kubectl describe clusterissuer temporal-ca-issuer    # Ready=True
kubectl get certificate -A -o wide
```

### ⑤ k8s end-to-end 발급 스모크 (재사용 절차 — dev 2026-06-11 통과)

> Temporal 없이 발급 파이프라인 전체(Certificate → cert-manager → Vault sign → Secret)를 검증.
> prod 적용 후 / 발급 장애 의심 시 동일하게 사용. Certificate 생성은 운영자 실행(apply), 검증은 read-only.

```yaml
# /tmp/temporal-ca-issuer-smoke-cert.yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: temporal-ca-issuer-smoke
  namespace: default
spec:
  secretName: temporal-ca-issuer-smoke-tls
  commonName: smoke.temporal.svc.cluster.local
  dnsNames: [smoke.temporal.svc.cluster.local]
  duration: 24h
  privateKey: { algorithm: RSA, size: 2048 }
  usages: [server auth, client auth]
  issuerRef: { name: temporal-ca-issuer, kind: ClusterIssuer, group: cert-manager.io }
```

```bash
kubectl apply -f /tmp/temporal-ca-issuer-smoke-cert.yaml          # 운영자 실행

# 검증 (read-only) — 기대값 주석
kubectl get certificate temporal-ca-issuer-smoke -n default        # READY=True
kubectl get secret temporal-ca-issuer-smoke-tls -n default \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > /tmp/issued.crt
openssl x509 -in /tmp/issued.crt -noout -issuer                # issuer=Temporal Intermediate CA
openssl x509 -in /tmp/issued.crt -noout -text \
  | grep -A1 "Extended Key Usage"                              # Server + Client 둘 다
{ cat base/pki/temporal-int-ca.crt; echo; cat base/pki/root-ca.crt; } > /tmp/chain.pem
openssl verify -CAfile /tmp/chain.pem /tmp/issued.crt          # OK

# 정리 — ⚠️ Certificate 삭제해도 Secret은 자동 삭제 안 됨 (둘 다 삭제)
kubectl delete certificate temporal-ca-issuer-smoke -n default
kubectl delete secret temporal-ca-issuer-smoke-tls -n default
```
> macOS 기본 openssl(LibreSSL)은 `-ext` 옵션이 없음 — EKU 확인은 `openssl x509 -noout -text | grep -A1 "Extended Key Usage"` 사용.

## 실행 기록 (2026-06-11)

1~4-1을 root 토큰으로 실행 완료. 런북 대비 변경/실측:

| 항목 | 실행값 | 비고 |
|------|--------|------|
| Root CA | `pki` mount · CN=`Example Internal Root CA` · issuer=`root-2026` · **2026-06-11 ~ 2036-06-08** | ✅ **Vault 내부 Root 확정**(MVP/dev 방식, 사용자 결정 2026-06-11) |
| Intermediate | `pki_temporal_int` mount · CN=`Temporal Intermediate CA` · issuer=`temporal-int-2026` · **~2031-06-10** | Root 서명 체인 `openssl verify` OK |
| 키 길이 | **CA 계층(root/int)은 rsa-4096** (런북 기본 2048에서 상향) · leaf role은 rsa-2048 유지 | 장수명 CA 보강 |
| role `temporal-server` | `allowed_domains`에 **`dev.k8s.example.com` 추가** (외부 노출 frontend SAN 대비) | EKU 스모크: 발급 leaf에 **ServerAuth+ClientAuth 둘 다 확인** ✅ |
| policy/auth | `temporal-pki` policy + `auth/kubernetes-dev/role/cert-manager-temporal` 생성 | Vault 경고: **audience 미설정**(선택) — 강화 시 role에 `audience` 추가 |
| CA 공개 cert | repo `base/pki/root-ca.crt` · `base/pki/temporal-int-ca.crt` 저장 (공개 자료, 키 아님 — Vault에서 재조회 가능) | ClusterIssuer 매니페스트: `base/pki/clusterissuer-temporal-ca-issuer-{dev,prod}.yaml` (env별 분리 — 차이는 auth mountPath뿐) |

**미실행 / 후속:**
- [~] **root 토큰 rotate** — 전용 토큰(`temporal-pki` policy, 72h) 발급 + `.token` 교체 완료(2026-06-11). **기존 root 토큰 revoke는 미실시** — 다른 root 토큰/unseal key 복구 경로(`vault operator generate-root`) 확인 후 운영자 직접 실행.
- [x] 4-2 ClusterIssuer apply — ✅ **dev 적용 완료(2026-06-11): Ready=True "Vault verified"**. 사전 실측 통과: SA `cert-manager/cert-manager` 일치 · cert-manager v1.17.2(serviceAccountRef는 v1.12+) · `cert-manager-tokenrequest` RBAC(helm 기본) 존재.
- [ ] **prod ClusterIssuer** — 매니페스트 준비됨(`base/pki/clusterissuer-temporal-ca-issuer-prod.yaml`). 선행: `auth/kubernetes-prod/role/cert-manager-temporal` 생성(관리자 권한) + prod SA 실측 + prod 전용 Intermediate 분리 결정.
- [x] dev **end-to-end 발급 스모크** — ✅ 통과(2026-06-11): Certificate Ready → Secret(`kubernetes.io/tls`) 채움 · 발급자=Temporal Intermediate CA · EKU Server+Client · repo CA로 체인 verify OK · Secret `ca.crt`=Root CA.
- [ ] 5(외부 SDK Worker approle) — MVP는 in-cluster worker라 보류, 외부 worker 등장 시 실행.

## 남은 결정 / 확인 필요
- `vault.example.com`가 **prod 정식 Vault인지 / dev·보조용인지** — prod CA를 둘지 소유·SLA 확인.
- ~~PKI mount·Root 발급 권한 주체~~ → 직접 실행함(root 토큰 보유 확인, 2026-06-11).
- ~~Root 생성 위치~~ → ✅ **Vault 내부 Root(dev/MVP)** 확정. prod 승격 시 오프라인 Root 재검토.
- `kubernetes-dev/` auth가 cert-manager SA 토큰을 검증하도록 구성됐는지(token reviewer/JWT).
- prod는 `kubernetes-prod/` auth + 별도 Intermediate 분리 여부.

## Sources
- [Vault PKI secrets engine | developer.hashicorp.com](https://developer.hashicorp.com/vault/docs/secrets/pki)
- [Build your own CA (root+intermediate) | Vault tutorial](https://developer.hashicorp.com/vault/tutorials/secrets-management/pki-engine)
- [cert-manager Vault Issuer | cert-manager.io](https://cert-manager.io/docs/configuration/vault/)
- [Temporal self-hosted security (clientCAFiles·mTLS) | docs.temporal.io](https://docs.temporal.io/self-hosted-guide/security)
