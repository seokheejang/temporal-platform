# Runbook — Temporal 서버 mTLS 켜기 (B3) + 함정 9선

> **상태: ✅ dev 검증 완료 (2026-06-25).** **두 worker(Go workflow·Python activity-worker) 모두** mTLS(client cert)로 frontend 접속·폴링 성공, 평문 접속(admintools·web)은 거부됨 = 양방향 mTLS·cert-only(§A1-bis) 실증.
>
> ⚠️ **web UI·admintools는 평문이라 mTLS 서버에 못 붙음** — UI로 workflow 보거나 admintools CLI 쓰려면 web/admintools에도 client cert 마운트 필요(미구현, 남은 작업). 평문 e2e·namespace 등록 등 admintools 작업은 mTLS 켜기 전에 끝낼 것.
>
> 이 문서는 mTLS를 켜는 절차 + **켜는 과정에서 실제로 만난 함정 8개와 해법**을 박제한다. prod 적용 시 같은 함정을 반복하지 않도록 **반드시 먼저 읽을 것**. cert 발급(1~5)·내부 통신(6~8) 순으로 함정이 연쇄했다.

---

## TL;DR — mTLS 켜기 (검증된 절차)

```bash
# 0. 선행: Vault role require_cn=false (함정 3) — 운영자, 1회만
vault write pki_temporal_int/roles/temporal-server \
    allowed_domains="cluster.local,svc.cluster.local,dev.k8s.example.com" \
    allow_subdomains=true allow_bare_domains=true require_cn=false \
    max_ttl=2160h key_type=rsa key_bits=2048 server_flag=true client_flag=true

# 1. 서버 mTLS on — values-mtls.yaml 생성(파일 존재=on, ignoreMissingValueFiles 토글)
cp services/example-service/dev/values-mtls.yaml.example \
   services/example-service/dev/values-mtls.yaml

# 2. worker도 짝으로 on (서버만 켜면 평문 worker 끊김 / worker만 켜면 평문 서버에 handshake 실패)
#    services/example-service/dev/workers/<name>/values.yaml:
#      temporal.tls.enabled: true
#      temporal.tls.certManager.enabled: true
#    ⚠️ Python(activity-worker)은 mTLS 코드 미구현 → 켜면 끊김. Go(workflow)만 검증됨.

# 3. commit + push → ArgoCD sync (server + worker)
#    server는 ApplicationSet 변경 없으면 sync만. cert backoff면 Certificate 삭제로 리셋(함정 4).
```

평문 복귀: `values-mtls.yaml` 삭제 + worker `tls.enabled: false` → sync.

---

## 구조 — 무엇을 켜는가

Temporal TLS는 **두 구간**을 따로 설정한다(`config.tls.internode` / `config.tls.frontend`):

| 구간 | 무엇 | 목적 |
|---|---|---|
| **frontend** | 클라이언트(worker·CLI·외부 SDK) ↔ 서버 | ⭐ **핵심** — worker 신원(cert-only) 검증, 외부 접속 보호 |
| **internode** | 서버 내부 4-role(frontend·history·matching·worker)끼리 | 부차 — 내부 트래픽 암호화. 함정 6·8을 부름 |

> **worker 인증·외부 접속이 목적이면 frontend가 본질.** internode는 "전구간 암호화"를 원할 때 추가하는 옵션이고, IP SAN·publicClient 같은 내부 배선 함정을 동반한다(아래). dev는 둘 다 켜서 검증 완료했으나, prod에서 internode가 부담되면 frontend-only + internalFrontend 구조를 검토.

구성 자산:
- `services/example-service/chart/templates/server-mtls-certificate.yaml` — 서버 cert(cert-manager, ClusterIssuer `temporal-ca-issuer`)
- `services/example-service/chart/values.yaml` §mtls — 토글
- `services/example-service/dev/values-mtls.yaml(.example)` — config.tls + 볼륨마운트 + probe override
- `argocd/dev/applicationset.yaml` — `ignoreMissingValueFiles` + mtls valueFile (파일 존재=on 토글)
- worker: `charts/worker/templates/certificate.yaml` (client cert) + `temporal.tls.*` 토글

---

## 🕳 함정 8선 (실측 2026-06-25, 순서대로 터짐)

### 함정 1 — cert commonName이 평이름 → Vault role 거부
- 증상: `common name dev-...-worker-workflow not allowed by this role`
- 원인: cert CN이 평이름인데 Vault role `allowed_domains`는 도메인 형식만 허용
- 해법: CN을 FQDN으로 (단 함정 2로 이어짐)

### 함정 2 — CN FQDN이 64바이트 초과 → cert-manager webhook 거부
- 증상: `spec.commonName: Too long: may not be more than 64 bytes`
- 원인: worker FQDN ~100자, server FQDN ~93자 > X.509 CN 한계 64
- 해법: **CN 생략, SAN(dnsNames)만 사용.** 현대 X.509는 CN 무시·SAN 기반. SAN은 길이 제한 없음

### 함정 3 — Vault role `require_cn=true` → CN 없으면 거부
- 증상: `the common_name field is required ... unless require_cn is set to false`
- 원인: CN을 뺐는데(함정 2) Vault role 기본값이 CN을 강제
- 해법: **Vault role `require_cn=false`** (운영자, PKI 설정 — repo 밖). SAN-only cert 허용. 보안 손실 없음(SAN 검증은 유지)

### 함정 4 — cert-manager backoff에 갇혀 재시도 안 함
- 증상: role 고쳤는데 cert가 계속 `Ready=False`, 새 CertificateRequest 안 생김
- 원인: 이전 실패의 exponential backoff(최대 ~30분) 동안 재시도 보류
- 해법: **Certificate 삭제** → ArgoCD 재생성으로 backoff 리셋 → 즉시 재발급. (`cmctl renew`도 가능하나 dev엔 cmctl 없음)

### 함정 5 — 서버 cert SAN에 short name → Vault role 거부
- 증상: `subject alternate name dev-...-server-frontend not allowed by this role`
- 원인: SAN에 short name(FQDN 아닌 `...-frontend`)이 있으면 allowed_domains 불일치
- 해법: **SAN은 FQDN만**(`...svc.cluster.local`). worker·internode 모두 k8s 내부 FQDN 통신이라 충분
- 참고: worker cert는 SAN이 FQDN 하나뿐이라 이 함정 없었음 — 서버 cert만 short name 포함했던 것

### 함정 6 — internode가 Pod IP로 dial → cert에 IP SAN 없어 검증 실패
- 증상: `x509: cannot validate certificate for 198.51.100.87 because it doesn't contain any IP SANs`, frontend 0/1
- 원인: Temporal internode는 멤버십을 **Pod IP로 관리**해 IP로 dial. cert엔 DNS SAN만 있음(IP는 동적이라 못 박음)
- 해법: **internode/frontend `client.serverName`을 공통 이름으로 고정**(`{release}.{ns}.svc.cluster.local`) + 그 이름을 cert SAN에 추가. IP로 dial해도 serverName으로 검증 → SAN 매칭 통과

### 함정 7 — frontend readinessProbe(gRPC)가 mTLS handshake 실패
- 증상: `Readiness probe failed: timeout`, frontend 영구 0/1 → Service endpoint 전환 안 됨 → worker가 옛 평문 pod에 붙어 CrashLoop
- 원인: 기본 readinessProbe가 gRPC(7233)인데 mTLS(requireClientAuth) 켜지자 kubelet probe가 client cert 없이 붙어 timeout. (liveness는 이미 tcpSocket이라 무사)
- 해법: **frontend.readinessProbe를 tcpSocket(port rpc)으로 교체.** TCP는 TLS handshake 안 해 통과
  - ⚠️ frontend는 자체 `server.frontend.readinessProbe`(gRPC)를 가져 전역보다 우선 → frontend에 직접 override
  - ⚠️ helm valueFiles deep merge라 차트 기본 `grpc:`가 안 지워지고 tcpSocket과 공존 → **`grpc: null` 명시 제거** 필요

### 함정 9 — Python worker가 빈 TLS env에 IsADirectoryError (off→on 차트 불일치)
- 증상: activity-worker(Python) `IsADirectoryError: [Errno 21] Is a directory: '.'` at `Path(caPath).read_bytes()`
- 원인: 차트가 mTLS off일 때 `TEMPORAL_TLS_*` env를 빈값(`""`)으로 **선언**했는데, Python `buildTemporalTls()`는 `os.environ.get()`이 **None일 때만** 평문으로 봄. `""`(빈 문자열)은 None이 아니라 mTLS 분기를 타고 `Path("")`(=현재 디렉토리 `.`)를 읽으려다 실패. Go는 `value != ""` 체크라 빈값도 무시했지만 Python `.get()`은 `""`를 그대로 반환 → 런타임 차이
- 해법: **mTLS off일 때 TLS env를 아예 생략**(빈값 선언 X). 양쪽 다 None/미설정 → 평문. on일 때만 주입. (deployment.yaml `else` 블록에서 빈값 env 제거)
- 교훈: "선언만 하고 빈값" 패턴은 Go엔 OK여도 Python `os.environ.get()`엔 함정. env는 있거나 없거나로.

### 함정 8 — server-worker publicClient가 mTLS frontend에 평문 접속 (과도기)
- 증상: server-worker(내부 worker role)가 `tls: first record does not look like a TLS handshake` → CrashLoop
- 원인: server-worker는 `publicClient`로 frontend에 붙는데, frontend가 mTLS인 과도기(frontend 아직 0/1, endpoint 미전환)에 평문 옛 pod에 붙음
- **해법: 자체 해소됨** — 함정 7 고쳐 frontend가 Ready되면 Service endpoint가 mTLS pod로 전환되고, publicClient도 `config.tls.frontend.client`(serverName/rootCa) 설정으로 붙음. 즉 함정 6·7이 풀리면 8은 따라서 해소
- ⚠️ 과도기에 server-worker·workflow worker가 **restart 여러 번 누적**(흉터)되나, frontend 정상화 후 안 늘어나면 안정. restart 카운트 자체는 무시 가능

---

## 검증 (dev 실측 2026-06-25)

```bash
# 1. 서버 cert Ready + Secret
kubectl get certificate -n dev-temporal-example-service       # temporal-server-tls Ready=True
# 2. 서버 6 pod 1/1 Running, frontend 새 pod가 Service endpoint
kubectl get endpoints dev-temporal-example-service-server-frontend -n dev-temporal-example-service
# 3. Go worker mTLS 접속 성공 (로그)
kubectl logs -n dev-temporal-example-service-worker deploy/...-worker-workflow --tail=5
#    → "Started Worker Namespace example-service-dev TaskQueue ...", handshake 에러 0
# 4. 평문 접속 거부 (양방향 mTLS 보안 동작 증명)
#    - activity-worker(평문): "BrokenPipe / stream closed" = 서버가 cert 없는 접속 끊음
#    - admintools(평문): "error reading server preface: EOF"
```

> ⚠️ **admintools 평문 거부 부작용**: mTLS 켜면 admintools의 `temporal operator ...` 명령이 막힌다(평문 경유). namespace 등록·조회 등은 그 전에 하거나, admintools에 cert를 물리는 별도 설정 필요(미구현). 평문 e2e 검증은 mTLS 켜기 전에 끝낼 것.

---

## 남은 작업
- **Python(activity-worker) mTLS 코드** — 앱팀. 미구현이라 현재 평문→거부됨. 구현되면 worker values에 `tls.enabled:true` 켜면 됨(차트는 준비됨)
- **외부 gRPC 노출(C1)** — 외부 SDK worker가 frontend로 붙으려면 Gateway+GRPCRoute+LB+외부도메인. cert SAN에 외부 도메인 추가(cert-manager 자동 재발급). 이번 범위 밖
- **admintools mTLS cert** — 평문 CLI가 막히므로, 운영 편의 위해 admintools에 client cert 마운트 검토
- **internalFrontend** — internode mTLS 부담 시 내부 role을 평문 internal-frontend로 분리하는 Temporal 공식 패턴(이번엔 internode 직접 켜서 검증 완료라 미적용)
