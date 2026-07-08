# 용어집 (Glossary)

Temporal 이해 + 개발자와의 소통 sync를 위한 살아있는 용어집. **새 용어가 나올 때마다 여기에 추가**한다.

## 관리 규칙
- 카테고리 안에서 대략 중요도/연관 순. 한 용어 = 한 줄 정의 + (필요시) **혼동주의**.
- k8s·IAM 등 다른 맥락과 같은 단어는 **[§0 헷갈리는 용어](#0-헷갈리는-용어-disambiguation)** 표에 반드시 등록.
- 출처가 필요한 정의는 [research/temporal-architecture.md](research/temporal-architecture.md) 참고.

---

## 0. 헷갈리는 용어 (Disambiguation) ⚠️

같은 단어가 Temporal / k8s / IAM에서 **다른 뜻**. 회의·문서에서 사고 나는 지점.

| 단어 | Temporal에서 | 다른 맥락에서 | 소통 팁 |
|------|--------------|----------------|---------|
| **Namespace** | 워크플로우의 논리 격리/테넌트 단위. retention 등 정책을 가짐 | k8s: 리소스 격리 단위 | 한 k8s namespace 안에 여러 Temporal namespace가 들어갈 수 있음. "어느 쪽 namespace?"를 먼저 확인 |
| **Worker** | ① **Worker Service**(서버 내부 시스템 워크플로우 처리 컴포넌트) | — | 회의에서 "워커"는 보통 ②번. 서버 얘기면 "internal worker service"라고 명시 |
| | ② **SDK Worker**(우리가 코드로 짜서 띄우는 비즈니스 코드 실행 프로세스) | k8s: (무관) | ②는 클러스터 **밖**에 배포되는 우리 앱 |
| **Cluster** | **Temporal Cluster (= Temporal Service)**: Frontend/History/Matching/Worker 4서비스 + DB 묶음 | k8s Cluster | 우리 토폴로지에선 한 k8s cluster 안에 **서비스별 Temporal cluster 여러 개**가 뜸 |
| **Service** | ① Temporal의 4개 컴포넌트(서비스) ② "Temporal Service" = 클러스터 전체 ③ Nexus Service | k8s Service(네트워크 추상화) | 가장 자주 충돌. "k8s Service"인지 "Temporal 컴포넌트"인지 매번 명시 |
| **Role** | ① 서버 role(frontend/history/matching/worker) ② **인가 role**(Reader/Writer/Admin/Worker) | k8s RBAC Role / AWS IAM Role | 4가지 다 다름. 인가 얘기면 "Temporal authz role" |
| **Task / Task Queue** | Worker가 long-poll 하는 작업 큐(Workflow Task / Activity Task 라우팅) | SQS/Kafka 같은 메시지 큐 아님 / k8s Job 아님 | "Temporal Task Queue"는 메시지 브로커가 아니라 매칭 큐 |
| **History** | ① **Event History**(워크플로우 이벤트 로그) ② **History Service**(컴포넌트) | — | 둘 다 Temporal 용어지만 의미 다름 |
| **Schedule** | Temporal Schedule(크론성 워크플로우 기동) | k8s CronJob | 워크플로우 스케줄링 ≠ 파드 스케줄링 |
| **Activity** | 작업의 최소 단위(부수효과/IO 허용) | 일반 영어 "활동" | Temporal 고유 개념으로 대문자 Activity 사용 |

---

## 1. Temporal 핵심 개념 (개발자 소통용)

| 용어 | 정의 |
|------|------|
| **Durable Execution** | 워크플로우의 모든 상태 전이를 영속화해, 프로세스가 죽어도 멈춘 지점부터 정확히 재개되는 실행 모델. Temporal의 핵심 가치 |
| **Workflow** | 오케스트레이션을 기술하는 **결정적(deterministic)** 함수. 장기 실행·내결함성. 직접 IO 하지 않고 Activity를 호출 |
| **Activity** | 실제 일(외부 호출·IO·부수효과)을 하는 단위. 비결정적 가능, 독립적으로 재시도됨 |
| **Worker (SDK)** | Workflow/Activity 코드를 담아 Task Queue를 polling 하며 실행하는 우리 프로세스. **서버 밖**에 배포 |
| **Task Queue** | Worker가 long-poll 하는 이름 붙은 큐. Workflow Task/Activity Task를 적절한 Worker로 라우팅 |
| **Event History** | 워크플로우 실행마다 쌓이는 append-only 이벤트 로그. 상태의 source of truth |
| **Replay** | Worker가 Event History를 재생해 워크플로우 상태를 재구성하는 것. 그래서 코드가 **결정적**이어야 함 |
| **Determinism** | 같은 입력/히스토리에 항상 같은 결과. 워크플로우 코드 제약(시간·랜덤·외부호출은 API 통해서만) |
| **Signal** | 실행 중 워크플로우에 비동기로 외부 입력을 보냄 |
| **Query** | 실행 중 워크플로우 상태를 동기로 읽음(상태 변경 없음) |
| **Update** | 동기 요청+응답으로 워크플로우 상태를 변경(Signal+Query의 결합형, 최신) |
| **Child Workflow** | 워크플로우가 띄우는 하위 워크플로우 |
| **Continue-As-New** | 히스토리 비대화를 막기 위해 새 실행으로 상태를 이월하며 재시작 |
| **Retry Policy** | Activity/Workflow 재시도 정책(간격·최대횟수·백오프) |
| **Timeout 종류** | schedule-to-start / start-to-close / schedule-to-close / heartbeat — 각기 다른 구간을 제한 |
| **Heartbeat** | 장시간 Activity가 살아있음을 주기적으로 보고(중단 감지·재시도용) |
| **Schedule** | 크론·간격 기반으로 워크플로우를 주기 기동 |
| **Search Attributes** | 워크플로우에 붙이는 인덱싱 가능한 메타데이터. visibility 검색/필터에 사용 |

---

## 2. 서버 컴포넌트 (infra용)

| 용어 | 정의 |
|------|------|
| **Frontend Service** | 모든 요청의 stateless 게이트웨이(인증·rate limit·검증·라우팅). 외부 노출 대상(gRPC 7233) |
| **History Service** | 워크플로우 상태·Event History·timer를 영속화. **샤딩된 stateful** 서비스. History Engine이 여기 동작 |
| **Matching Service** | Task Queue 호스팅, Worker↔Task 매칭. stateful |
| **Worker Service (internal)** | 서버 내부 시스템 워크플로우(replication·archival·schedule 처리 등). ※ SDK Worker와 별개 |
| **History Shard** | 워크플로우를 분배하는 샤딩 단위. `hash(workflowID+namespace)`로 배정. 동시성/처리량의 기본 단위 |
| **NumHistoryShards** | 클러스터의 shard 개수. **생성 후 변경 불가**. 소규모 prod 권장 512 |
| **History Engine** | shard 단위로 워크플로우 상태 전이를 처리하는 History 서비스 내부 엔진 |
| **Persistence (main store)** | 워크플로우 상태·Task·Namespace 메타데이터를 저장하는 필수 DB(Cassandra/PostgreSQL/MySQL) |
| **Visibility store** | "실행 중 워크플로우 목록/검색"용 저장소. main DB(standard) 또는 ES/SQL(advanced) |
| **Standard / Advanced visibility** | standard=기본 필터, advanced=커스텀 Search Attribute·SQL-like 필터. v1.20+ SQL로도 advanced 가능 |
| **Ringpop / Membership** | 노드 디스커버리·shard 소유권 분배용 gossip 멤버십 프로토콜 |
| **auto-setup** | DB 스키마를 자동 생성하는 **개발 전용** 이미지. 프로덕션 금지 |
| **temporal-sql-tool / temporal-cassandra-tool** | 프로덕션 스키마 생성·업그레이드 CLI |

---

## 3. 멀티테넌시 & 클러스터 간 연결

| 용어 | 정의 |
|------|------|
| **Namespace** (Temporal) | 클러스터 내 논리 격리/테넌트 단위. retention period, 인가 범위를 가짐 |
| **Multi-cluster Replication / Global Namespace** | 여러 Temporal 클러스터 간 비동기 복제로 HA/DR 제공 |
| **Nexus** | (2025 GA) 격리된 namespace 간 Temporal 호출을 연결. ⚠️ **self-hosted는 단일 클러스터 내에서만** 지원 |
| **Nexus Endpoint / Service / Operation** | Nexus의 호출 대상·서비스·연산 단위 |

---

## 4. 인증 · 보안 (auth)

| 용어 | 정의 | 비고 |
|------|------|------|
| **mTLS** | 양방향 TLS. Temporal은 **internode**(서비스 간)와 **frontend**(외부 노출) 두 구간을 따로 설정 | 전송 암호화·노드 신뢰 |
| **Authorizer** | 모든 API 호출마다 호출됨. caller의 role/permission claim + 호출 대상을 보고 허용/거부 판정하는 **플러그인** | 커스텀 가능 |
| **ClaimMapper** | TLS 인증서/JWT의 신원 정보를 Temporal **Claims(role)** 로 변환하는 플러그인. 기본 JWT ClaimMapper는 public key로 서명 검증 | Authorizer의 입력을 만듦 |
| **Claims / Role** | ClaimMapper가 만든 권한. role: **Reader / Writer / Admin / Worker** (namespace 또는 system 레벨) | k8s RBAC·IAM Role과 무관 |
| **JWT** | 서명된 토큰. ClaimMapper가 검증·파싱해 권한 추출 | OIDC/OAuth2가 발급 |
| **OIDC (OpenID Connect)** | OAuth2 위의 인증 프로토콜. Temporal Web UI SSO 로그인에 사용 | |
| **OAuth2** | 토큰 기반 인가 프레임워크 | |
| **SSO** | 단일 로그인. Web UI에 `TEMPORAL_AUTH_ENABLED=true` + OIDC 설정으로 활성화 | |
| **IdP (Identity Provider)** | 신원을 인증하고 토큰을 발급하는 시스템 (Okta, Google, Azure AD/Entra, Auth0, Keycloak 등) | Temporal이 신뢰하는 토큰 발급자 |
| **IAP (Identity-Aware Proxy)** | 앱 앞단에서 인증을 강제하는 인증 프록시(대표적으로 GCP IAP). Temporal **내장 기능 아님** | Web UI 앞에 둘 수 있는 외부 방식. IdP와 혼동 주의 |
| **RBAC** | 역할 기반 접근 제어. 여기선 보통 **k8s RBAC**(Role/RoleBinding)를 가리킴 — Temporal authz role과 별개 | |
| **API Key** | (주로 Temporal Cloud) 키 기반 인증 수단 | self-hosted는 mTLS/JWT 중심 |

> **IdP vs IAP 한 줄 정리**: IdP = "**누구인지** 인증하고 토큰 발급"(Okta 등). IAP = "앱 앞에서 **통과 여부**를 강제하는 프록시"(GCP IAP 등). 둘은 역할이 다르며, IAP가 뒤의 IdP를 호출해 인증할 수 있음.

---

## 5. 배포 · DevOps

| 용어 | 정의 |
|------|------|
| **Helm Chart** | k8s 배포 패키지. Temporal 공식 차트는 4서비스 + (옵션)Cassandra/ES/Prometheus/Grafana 번들 |
| **ArgoCD / Application / ApplicationSet** | GitOps 컨트롤러 / 배포 단위 CR / 다수 Application을 생성하는 제너레이터 |
| **AppProject** | ArgoCD에서 소스·대상·권한을 묶는 경계 |
| **values 3-layer** | `base/` → `services/<svc>/` → `services/<svc>/<env>/` 순으로 합성되는 우리 repo의 values 레이어링 |

---

## 6. 인증서 · CA · 시크릿 관리 (PKI/TLS 운영)

> mTLS·Vault PKI 설계 용어. PKI·mTLS 개념도 = [architecture/concepts-essentials.html](architecture/concepts-essentials.html), 세팅 절차 = [runbooks/vault-pki-setup.md](runbooks/vault-pki-setup.md).

| 용어 | 정의 | 비고 / 혼동주의 |
|------|------|------|
| **CA (Certificate Authority)** | 인증서에 서명·발급하는 신뢰 주체(서명키 보유) | "발급 자동화(cert-manager)"와 **다른 층** |
| **Root / Intermediate CA** | 신뢰 최상위(Root, 보통 오프라인) → 중간 CA가 실제 leaf 발급. 단일 Root+Intermediate가 정석 | Root 유출=전체 붕괴 → 오프라인 권장 |
| **사설 CA vs 공개 CA** | 사설=내 Root만 신뢰(내부 mTLS) / 공개=브라우저가 신뢰(Let's Encrypt) | example.com=**공개**, MongoDB·Temporal mTLS=**사설** |
| **cert-manager** | k8s에서 cert를 발급·저장(Secret)·**자동갱신**하는 컨트롤러. **그 자체는 CA 아님** — Issuer로 CA 지정 | **in-cluster 전용**(외부 worker 발급 불가) |
| **Issuer / ClusterIssuer** | cert-manager가 어떤 CA로 발급할지 정의(ns/클러스터 범위). 타입: ACME·CA·SelfSigned·Vault | 타입에 따라 공개/사설 갈림 |
| **ACME** | 인증서 자동 발급·갱신 프로토콜(Let's Encrypt 대표). Vault PKI도 사설 ACME 서버 제공(1.14+) | |
| **DNS-01 challenge** | ACME 도메인 소유 증명을 DNS 레코드로. wildcard 발급에 필요. dev는 route53로 수행 | 자격증명 만료 시 갱신 실패 |
| **Let's Encrypt** | 무료 공개 ACME CA(90일 cert). 공개 도메인 TLS용 | 내부 mTLS엔 부적합 |
| **EKU (Extended Key Usage)** | cert 용도(serverAuth/clientAuth). **Temporal internode cert는 둘 다 필요**(피어가 서버이자 클라이언트) | 흔한 mTLS 함정 |
| **Vault PKI** | HashiCorp Vault의 사설 CA 엔진(OSS 내장). Root/Intermediate 발급 + cert-manager Vault Issuer + 외부 발급 | vault엔 **아직 미설정** |
| **External Secrets Operator (ESO)** | 외부 저장소(Vault 등) 값을 k8s Secret으로 동기화하는 컨트롤러. **인증서/PKI 아님** | dev는 ESO로 Vault KV→Secret |
| **Vault Agent (Injector)** | Vault 시크릿을 파드에 sidecar로 주입·갱신 | dev는 외부 vault 가리킴 |
| **Reloader (stakater)** | ConfigMap/Secret 변경 시 워크로드를 **롤링 재기동**. **annotation opt-in 필요** | cert 갱신 후 앱 reload용. dev 설치됐으나 **미사용** |
| **hot-reload (cert)** | 앱/프록시가 재기동 없이 새 cert를 다시 읽음(Envoy/Cilium SDS 등) | 재기동 없이 갱신 반영 |
| **renewBefore / renewalTime** | cert-manager 자동갱신 시점(`renewalTime = notAfter − renewBefore`, 기본 renewBefore=수명 1/3) | **Secret 갱신 ≠ 앱 reload** |

---

## 참고
- 컴포넌트·흐름 상세: [research/temporal-architecture.md](research/temporal-architecture.md)
- 출처: [docs.temporal.io security](https://docs.temporal.io/self-hosted-guide/security), [Temporal Server](https://docs.temporal.io/temporal-service/temporal-server), [Persistence](https://docs.temporal.io/temporal-service/persistence)
