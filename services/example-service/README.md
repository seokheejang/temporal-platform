# example-service Temporal 클러스터

재사용 가능한 참조 예제 서비스. 서비스별 독립 Temporal 클러스터 (ADR-0003).

## 확정값

| 항목 | 값 |
|---|---|
| k8s namespace | `dev-temporal-example-service` (dev) · `prod-temporal-example-service` (prod, 미구축) |
| 엔드포인트 | UI·gRPC 외부 주소 → [외부 접속 엔드포인트](#외부-접속-엔드포인트-개발자용) (dev 노출 완료) |
| ArgoCD 앱 | `dev-temporal-example-service-server` · `dev-temporal-example-service-db` · (향후) `...-worker-{name}` — 체계: `{env}-temporal-{svc}-{component}` |
| NumHistoryShards | **512** (불변 — 생성 후 변경 불가, R5) |
| Persistence | cnpg PostgreSQL `temporal-pg` (main `temporal` + visibility `temporal_visibility`, postgres12_pgx) |
| DB 자격증명 | Vault KV `k8s/temporal/example-service/dev/db` → ESO → `temporal-pg-app` |
| worker 앱 시크릿 | activity-worker: Vault KV `k8s/temporal/example-service/dev/activity-worker` → ESO → `activity-worker-secrets` ([운영 절차](dev/workers/activity-worker/README.md)) · workflow: 없음(Temporal만) |
| chart | upstream temporalio/temporal **1.2.0** pin ([chart/Chart.yaml](chart/Chart.yaml)) |

## 외부 접속 엔드포인트 (개발자용)

> dev(dev-cluster) 기준. **사내망**에서 접근. 둘 다 **mTLS(client cert 필수)** — cert 없이는 거부됨(§아래).

| 용도 | 주소 | 프로토콜 | 비고 |
|---|---|---|---|
| **Web UI** | `https://temporal-example-service.dev.k8s.example.com` | HTTPS (443) | 브라우저. 무인증(SSO는 C2 후속) |
| **gRPC frontend** (SDK worker·CLI) | `temporal-example-service-grpc.dev.k8s.example.com:7233` | gRPC + mTLS | 외부 SDK worker가 여기로 접속. LB IP `192.0.2.100` |

**접속에 필요한 것:**
- **Temporal namespace**: `example-service-dev` (SDK client `namespace`·CLI `--namespace`)
- **mTLS client cert**: 양방향·cert-only(§A1-bis). cert 없으면 접속 거부.
  - in-cluster worker → cert-manager가 자동 발급(차트 `temporal.tls.certManager.enabled`)
  - **외부 worker → Vault approle로 client cert 직접 발급 필요**(B4, 발급 경로 미구축 — 앱팀/인프라 협의)
  - CA: 사내 Vault PKI (`Temporal Intermediate CA`). 서버 cert도 여기서 발급
- **CLI 예시**: `temporal --address temporal-example-service-grpc.dev.k8s.example.com:7233 --namespace example-service-dev --tls-cert-path <cert> --tls-key-path <key> --tls-ca-path <ca> workflow list`

> ⚠️ 평문 접속(cert 없음)은 `connection reset`/handshake 실패로 거부됨 — 정상 동작(mTLS 보안).
> mTLS 켜기·끄기와 함정은 [mTLS 런북](../../docs/runbooks/temporal-mtls-enable.md).

## 설계 메모 (앱팀 입력 대기)

- **용도/워크로드**: TODO (이 서비스가 Temporal로 무엇을 하는지 정의)
- **워커 위치**: MVP는 in-cluster 가정 — 외부 worker 등장 시 B4(approle)·C1(gRPC 노출) 트리거
- **스케일**: dev 단일 replica → prod role당 ≥2 (R5)

구조 규칙은 [../_template/README.md](../_template/README.md), 차트 전략은 [ADR-0005](../../docs/adr/0005-umbrella-wrapper-per-service.md).
