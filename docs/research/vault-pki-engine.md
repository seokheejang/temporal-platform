# Vault PKI Secrets Engine — 개념과 우리 구축(As-Built) 상세

> **목적**: vault에 구축한 Temporal mTLS CA(2026-06-11)를 *이해하고 재현하고 운영*하기 위한 개념 문서.
> 실행 절차는 [../runbooks/vault-pki-setup.md](../runbooks/vault-pki-setup.md), 이 문서는 "그 절차가 왜 그렇게 생겼는지".
> 개념 다이어그램(신뢰 체인·mTLS 구간·누가 갱신): [../architecture/concepts-essentials.html](../architecture/concepts-essentials.html) (§4 보안)

## 0. 쉬운 용어 정리 — 여권 비유 (먼저 읽기)

인증서 신뢰 체인을 **여권 발급 체계**에 빗대면 한 번에 잡힌다:

| 용어 | 비유 | 정체 | 우리 환경 |
|---|---|---|---|
| **Root CA** | 🏛️ 국가(정부) | 신뢰의 최종 근원(trust anchor). 너무 중요해 **평소엔 금고에 보관**, Intermediate 만들 때만 꺼냄 | `pki/` "Example Internal Root CA" (~2036, 휴면) |
| **Intermediate CA** | 🏢 여권 발급 관청 | Root에게 서명(보증)받아, **Root 대신 실제로 leaf를 발급하는 중간 관청** | `pki_temporal_int/` "Temporal Intermediate CA" (~2031) |
| **leaf 인증서** | 🪪 개인 여권 | 체인의 **맨 끝(말단)**에서 통신 주체가 들고 다니는 "신분증". **발급받는 쪽**이며 더 이상 아무것도 발급 못 함 | 서버·orchestration-worker·activity-worker 각각 1장 |
| **leaf 개인키** | ✍️ 여권 본인 서명/지문 | 본인만 가짐. **Vault는 저장조차 안 함**(발급 시 1회 반환하고 끝) | 각 서버·worker가 보관 |

**신뢰 체인**: `Root ──서명──> Intermediate ──발급──> leaf`. leaf를 검증할 땐 이 사슬을 거슬러 올라가 **Root에 닿으면 믿는다**.

**왜 Intermediate를 끼우나** (Root가 직접 leaf 발급 안 하는 이유):
1. **폭발 반경 제한** — Intermediate 유출 시 그것만 폐기·재발급. 모든 곳에 깔린 Root 신뢰는 보존.
2. **Root 휴면** — 일상 발급이 Root 키를 안 건드림 → 노출 면적 최소화 (prod 정석=오프라인 Root).
3. **제품별 격리** — 다른 제품은 같은 Root 밑에 `pki_<other>_int` 추가, 규칙·권한 안 섞임.

> ⚠️ 흔한 오해: "leaf = 말단 CA"가 **아니다**. CA는 *발급하는 쪽*(Root/Intermediate), leaf는 *발급받아 신원 증명에 쓰는 쪽*. "Root = PKI 자체"도 아니다 — Root는 PKI 안의 최상위 CA **1개**이고, PKI는 Root·Intermediate·role·policy·발급경로·CRL을 **다 합친 시스템 전체**.

## 1. PKI engine이란

Vault secrets engine의 하나로, **X.509 인증기관(CA)을 HTTP API로 제공**한다. 전통적 CA 운영(openssl로 키 만들고, CSR 받고, 서명하고, 파일로 전달)을 API 호출 한 번으로 대체한다.

핵심 가치:
- **짧은 수명 인증서 운영이 현실화** — 발급이 API 한 번이라 90일짜리를 자동 갱신하는 모델이 가능 (수동 CA에선 비현실적)
- **CA 개인키가 Vault 밖으로 안 나감** — 서명은 Vault 안에서 일어나고 결과물(인증서)만 나옴
- **감사 가능** — 누가 언제 뭘 발급했는지 audit log
- Vault **OSS 내장** 엔진 — vault(OSS 1.21.2, 실측)에서 라이선스 없이 사용 가능

## 2. 핵심 객체 4가지

| 객체 | 정체 | 우리 구축에서 |
|---|---|---|
| **mount** | `vault secrets enable -path=<p> pki`로 만드는 PKI 인스턴스. 각자 독립된 키·인증서·발급규칙·CRL 보유 | `pki/` (Root) · `pki_temporal_int/` (Intermediate) |
| **issuer** | mount 안의 "서명 주체"(CA 인증서+키 쌍). 한 mount에 여러 issuer를 둘 수 있음(CA 회전 대비) — 이름으로 참조 | `root-2026` · `temporal-int-2026` |
| **role** | 발급 규칙 템플릿 — 허용 도메인, 최대 TTL, 키 스펙, EKU 플래그. **"이 role로는 이런 인증서만 나간다"는 정책 경계** | `temporal-server` |
| **policy** | Vault ACL — 어떤 토큰이 어떤 path를 호출할 수 있는지. role이 "무엇을 발급하나"라면 policy는 "누가 발급 요청 가능한가" | `temporal-pki` |

주요 API path 구조 (mount별로 동일한 모양):

```
<mount>/issue/<role>      # 발급: Vault가 키+인증서 생성해 반환
<mount>/sign/<role>       # 서명: 클라이언트 CSR을 서명만 (키는 클라이언트 보관)
<mount>/ca/pem            # CA 인증서 조회 — ★비인증(토큰 불필요), trust 배포용
<mount>/crl               # 폐기 목록(CRL) — 비인증
<mount>/roles/<name>      # 발급 규칙 관리 (관리자)
<mount>/config/urls       # AIA/CRL 포인터 설정 (관리자)
```

## 3. 우리 토폴로지 (As-Built 2026-06-11)

```
vault.example.com (Vault OSS 1.21.2)
│
├── pki/                     Root CA  "Example Internal Root CA"
│     issuer: root-2026      rsa-4096 · 2026-06-11 ~ 2036-06-08 (10y)
│     역할: Intermediate 서명 + 신뢰 기준점(trust anchor). leaf 직접 발급 안 함.
│           평시엔 휴면 — 새 Intermediate 추가/교체 때만 사용.
│
└── pki_temporal_int/        Intermediate CA  "Temporal Intermediate CA"
      issuer: temporal-int-2026   rsa-4096 · ~2031-06-10 (5y) · Root가 서명
      역할: Temporal 관련 leaf 인증서 전부 여기서 발급 (일상 운영의 실체)
      role: temporal-server
        - allowed_domains: cluster.local, svc.cluster.local, dev.k8s.example.com
        - max_ttl 2160h(90d) · rsa-2048 · server_flag+client_flag (EKU 둘 다)
```

**왜 2단(Root → Intermediate)인가:**
1. **폭발 반경 제한** — Intermediate 유출 시 Intermediate만 폐기·재발급. 모든 곳에 배포된 Root 신뢰는 그대로.
2. **Root 휴면** — 일상 트래픽이 Root 키를 안 건드림 → 노출 면적 최소화. prod 정석(오프라인 Root)으로 가는 중간 단계.
3. **제품별 격리** — 나중에 다른 제품이 mTLS 쓰면 `pki_<other>_int`를 같은 Root 밑에 추가. Temporal과 발급 규칙·권한이 섞이지 않음.

**Intermediate의 범위는 "Temporal 제품"이지 "k8s 안"이 아니다** — 외부 SDK Worker의 client cert도 여기서 발급한다. k8s 안/밖은 발급 *경로*(cert-manager vs approle)만 가른다.

## 4. 발급 경로: `sign` vs `issue`

| | `sign/<role>` | `issue/<role>` |
|---|---|---|
| 개인키 생성 위치 | **클라이언트** (CSR만 Vault로) | **Vault** (키+인증서 통째로 반환) |
| 개인키의 Vault 통과 | ❌ 안 함 (보안상 우위) | ⭕ 응답에 포함 |
| 우리 사용처 | **cert-manager** (in-cluster) — ClusterIssuer `path: pki_temporal_int/sign/temporal-server` | **외부 SDK Worker** (approle 로그인 후 직접 호출) |

> `sign-verbatim`(CSR 내용을 role 검증 없이 그대로 서명)도 있으나 정책 우회라 사용하지 않음.

## 5. TTL 3층 구조 — 인증서 수명과 토큰 수명은 별개

"발급된 신분증"(인증서)과 "발급 창구 출입증"(Vault 토큰)의 구분. **토큰이 만료돼도 이미 발급된 인증서는 유효기간까지 산다.**

| 층 | 무엇 | 수명 | 만료 시 |
|---|---|---|---|
| CA 인증서 | Root / Intermediate | 10y / 5y | 체인 재구축(드묾) — mount `max-lease-ttl`(87600h/43800h)이 상한 |
| leaf 인증서 | Temporal 서버·worker cert | ≤90d (role `max_ttl=2160h`) | cert-manager가 만료 전 자동 갱신(`status.renewalTime`) — 단 [갱신≠reload 함정](../runbooks/vault-pki-setup.md#7-자동갱신--무중단--워크로드-reload-전략-중요) |
| Vault 토큰 | API 호출 자격 | 운영자 72h · cert-manager 10m(k8s auth) · worker 1h(approle) | 재발급. 자동화 주체는 토큰을 보관하지 않고 매번 짧게 받음 |

### 5-bis. Vault PKI는 무엇을 저장하나 — "발급만 하는 CA"의 실제 저장 내용

"개인키를 저장 안 한다"는 거친 표현이라 정정: **leaf의 *개인키*만 저장 안 하고, 나머지는 저장한다.**

| 항목 | 저장? | 비고 |
|---|---|---|
| **CA(Root·Intermediate) 인증서 + 개인키** | ✅ | 키를 보관하는 **유일한 예외** — 서명은 Vault 내부에서 일어나야 하므로 |
| **발급한 leaf 인증서(공개부)** | ✅ (기본 `no_store=false`) | 일련번호로 보관 → 목록 조회·일련번호 기반 폐기(revocation)에 필요 |
| **leaf 개인키** | ❌ **절대** | `issue` 시 호출자에게 **1회 반환하고 끝**. `sign`이면 키가 Vault를 아예 안 거침 |
| **폐기 정보(CRL·revoked·serial)** | ✅ | 폐기 기능에 필수 |
| **issuer/role/policy/config** | ✅ | 발급 규칙·권한·AIA/CRL URL |

**핵심**: leaf 공개 인증서는 남아 있지만, 그건 **폐기·감사**용이지 **갱신**용이 아니다. Vault는 저장된 leaf의 만료일을 보고 "곧 만료니 재발급하자"를 **스스로 트리거하지 않는다** → 갱신은 여전히 외부 소비자(cert-manager 등)가 요청해야 함.

> 운영 팁: 우리 role은 leaf TTL ≤90d. HashiCorp는 짧은 TTL(<30d)·고발급량이면 `no_store=true` 권장(storage·성능). 단 일련번호 폐기를 못 하게 됨 → 우리는 발급량이 적어 **기본값 유지 + `auto-tidy`(만료 cert 자동정리, §8)** 가 적절.

## 6. 인증(auth)·권한 모델 — 누가 어떻게 발급받나

```
운영자          : .token (temporal-pki policy, 72h)  →  issue/sign 만 가능
cert-manager    : k8s SA 토큰 → auth/kubernetes-dev/role/cert-manager-temporal (10m) → sign
외부 SDK Worker : role_id+secret_id → auth/approle (1h) → issue   [MVP 보류]
```

`temporal-pki` policy 전문 (이것이 운영 토큰의 전체 권한):

```hcl
path "pki_temporal_int/sign/temporal-server"  { capabilities = ["create","update"] }
path "pki_temporal_int/issue/temporal-server" { capabilities = ["create","update"] }
```

실측 검증(2026-06-11): 이 토큰으로 발급 ⭕ · `vault list pki_temporal_int/roles` ❌(거부) — **최소권한이 의도대로 동작**. role·policy·mount 변경이 필요하면 그때만 관리자 권한을 다시 쓴다.

**비인증 엔드포인트**: `/v1/<mount>/ca/pem`, `/v1/<mount>/crl`은 토큰 없이 공개 — Root cert를 Temporal frontend `clientCAFiles`·worker 신뢰 저장소에 배포할 때 권한이 필요 없는 이유. (인증서는 공개 자료, 비밀은 개인키뿐 — repo `base/pki/*.crt`를 커밋해도 되는 이유이기도 하다.)

### 왜 auth는 기존 mount를 공유하나 — Temporal 전용 auth mount를 안 만든 이유

auth mount는 "**신원 검증 방법**"의 설정 덩어리다. `kubernetes-dev/` = dev 클러스터의 TokenReview 설정 — 검증 대상이 같은 클러스터면 mount를 새로 만들어도 **같은 설정의 복사본**일 뿐이다. mount가 갈리는 기준은 **신뢰 도메인**이고, 그래서 클러스터별로 `kubernetes-dev/`·`kubernetes-prod/`가 나뉜다.

Temporal 격리는 **mount 안의 role + policy**에서 이미 걸려 있다:

```
auth/kubernetes-dev/                      ← mount: "dev 토큰 검증기" (전사 공유)
 ├── role/cert-manager-temporal   ★Temporal 전용
 │     bound: cert-manager SA/ns 만          (누가)
 │     policies: temporal-pki 만             (무엇을 — PKI 발급 외 전부 거부, 실측 확인)
 └── role/...                     ← 다른 팀 role과 정책이 안 섞임
auth/approle/                              ← mount 공유 (외부 worker용, 보류)
 └── role/temporal-worker         ★Temporal 전용 (런북 §5)
```

비유: 입국심사대(mount)는 하나, **비자 종류(role)** 가 다른 것. 목적별로 심사 시스템을 새로 짓지 않는다.

**PKI는 전용 mount를 만들었는데 auth는 왜 공유하나** — mount의 의미가 다르기 때문:

| | secrets engine (PKI) | auth method |
|---|---|---|
| mount = | **CA 그 자체** (키+체인+발급규칙) | 신원 **검증 방법** 설정 |
| 분리 단위 | 제품별 — `pki_temporal_int` 유출 시 그 CA만 통째 폐기(실질적 보안 경계) | 신뢰 도메인별 — 클러스터가 같으면 검증기도 같음 |
| Temporal 격리 수단 | **전용 mount** | **전용 role + policy** (mount 공유) |

전용 auth mount를 고려할 시점: Temporal이 별도 클러스터로 가거나, approle secret_id 관리를 앱팀에 위임하며 관리 경계를 행정적으로 분리하고 싶을 때. MVP에선 해당 없음.

## 7. `config/urls` (AIA/CRL)의 의미

```
issuing_certificates   = $VAULT_ADDR/v1/<mount>/ca     # "내 발급자 인증서는 여기"
crl_distribution_points = $VAULT_ADDR/v1/<mount>/crl   # "폐기 목록은 여기"
```

이 URL들은 **이후 발급되는 leaf 인증서 안에 박힌다**(AIA/CDP 확장). 검증자가 중간 인증서를 못 찾거나 폐기 여부를 확인할 때 따라가는 포인터. 미설정 시 Vault가 경고를 내며(Intermediate mount 생성 직후 실측), 체인 조립이 클라이언트 설정에만 의존하게 된다.

## 8. 운영 함정 모음 (이번 구축에서 실제 만난 것 포함)

| 함정 | 내용 | 대응 |
|---|---|---|
| **internode EKU** | Temporal internode mTLS는 피어가 서버이자 클라이언트 → EKU에 **ServerAuth+ClientAuth 둘 다** 필요 | role에 `server_flag=true client_flag=true` (발급 스모크로 EKU 확인 완료) |
| **갱신 ≠ reload** | cert-manager는 Secret만 갱신, 파드 재기동 안 함 | 런북 §7 — Reloader annotation·subPath 금지 |
| **Temporal 서버는 cert를 읽기만** | 서버 `tls`는 `certFile`/`keyFile`/`clientCaFiles` **파일 경로를 읽을 뿐** — CA에 발급 요청·자동 재갱신 로직 **없음**(`expirationChecks`는 만료를 *경고만*). 발급·갱신 주체는 cert-manager, 서버는 소비자 ([config.go RootTLS](https://github.com/temporalio/temporal/blob/main/common/config/config.go), [config ref](https://docs.temporal.io/references/configuration)) | mTLS 무중단 갱신 = **둘 중 하나 필수**: ① `server.config.tls.refreshInterval`(RootTLS 최상위 필드, "Interval between refreshes of certificates loaded from files") 설정 + **`certFile` 파일 마운트**(주의: `certData` base64 인라인은 reload 안 됨) → 서버가 주기적으로 디스크 재독 = 무중단. ② 또는 워크로드에 Reloader opt-in → Secret 갱신 시 파드 롤링 재기동. **미설정이면 옛 cert 메모리 보유 → 만료 장애** |
| **공식 chart TLS 자동 주입 없음** | chart에 `server.tls` 자동 Secret 생성/마운트 values 없음 | `server.config.tls`(internode/frontend/refreshInterval) 직접 작성 + `server.additionalVolumes`(cert-manager Secret) + `additionalVolumeMounts`로 수동 마운트, `certFile`을 그 경로로 ([helm values.yaml](https://github.com/temporalio/helm-charts/blob/main/charts/temporal/values.yaml)) |
| **mount `max-lease-ttl`** | mount 상한 > role `max_ttl` 이어야 함. 기본 32d라 tune 없이는 10y root 발급 불가 | `vault secrets tune -max-lease-ttl=...` 선행 |
| **audience 미설정** | k8s auth role에 audience 없으면 Vault가 경고(선택 사항) | 강화 시 `audience` 추가 검토 |
| **root 토큰 위생** | 세팅 후 root 토큰 계속 쓰면 최소권한 무의미 | 전용 토큰 발급·교체 완료, root revoke는 복구 경로 확인 후 |
| **macOS LibreSSL** | `openssl x509 -ext` 옵션 없음 | `-text \| grep -A1 "Extended Key Usage"` |

## Sources

- [PKI secrets engine | developer.hashicorp.com](https://developer.hashicorp.com/vault/docs/secrets/pki)
- [Build your own CA (root+intermediate) | Vault tutorial](https://developer.hashicorp.com/vault/tutorials/secrets-management/pki-engine)
- [PKI secrets engine API | developer.hashicorp.com](https://developer.hashicorp.com/vault/api-docs/secret/pki)
- [Tokens | developer.hashicorp.com](https://developer.hashicorp.com/vault/docs/concepts/tokens)
- [cert-manager Vault Issuer | cert-manager.io](https://cert-manager.io/docs/configuration/vault/)
- 실측: vault.example.com 구축·검증 로그 (2026-06-11, 이 repo 런북 "실행 기록")
