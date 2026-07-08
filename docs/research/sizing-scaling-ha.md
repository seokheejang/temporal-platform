# R5. 운영 사이징 · 스케일 · HA (self-hosted)

> ⚠️ **공식 입장 먼저**: Temporal은 "정해진 최소 스펙"을 제시하지 않는다. 워크로드에 따라 천차만별이라 **자체 부하테스트(PoC, 예: Omes 벤치마크 툴)로 right-sizing** 하라고 명시한다.
> 아래에서 **[공식]** 표기 외는 커뮤니티/휴리스틱 **시작점**이며, 반드시 부하테스트로 검증 전제. (출처: 문서 하단)

---

## 1. 최소 동작 자원 · 디스크 (Q1)

### 핵심: 서버 4 role은 stateless = 디스크 없음
- frontend/history/matching/worker는 **PVC가 없다**. → **디스크는 전부 DB(+visibility store) 몫.**
- 즉 "디스크 용량" = **DB 사이징 문제**: `워크플로우 수 × 보존기간(retention) × event history 크기`에 비례. 시작은 작게(수~수십 GB) 잡고 모니터링하며 증설.

### CPU/메모리 시작점 — **Temporal 문서의 실제 예시 기준**
> Temporal 스케일링 자료에 나오는 **시작점 예시**(공식은 "고정 최소"가 아니라 "이 값에서 시작해 부하테스트로 조정"이라는 의미):

| 대상 | 시작점 (문서 예시) | 비고 |
|------|--------------------|------|
| 각 server role (FE/History/Matching/Worker) | **2 pods × (1 CPU, 1 GB)** | 4 role 합계 8 pods, 8 vCPU, 8 GB |
| DB (예시는 MySQL) | **4 vCPU / 32 GB** | DB가 천장이라 서버보다 크게 잡음 |
| 처리량 참고 | 위 구성에서 **150 → 1,350 state transitions/s**까지 스케일, 1,200/s에서 latency ~50ms | |

- dev/PoC는 위에서 축소(role당 100–250m / 256–512Mi, 단일 replica). **prod는 위 1 CPU/1 GB ×2에서 시작해 부하테스트로 상향.**
- **[공식]** 모든 pod이 CPU/memory **request 안**에 머물러야 하며, **잦은 재시작(OOM)·CPU throttling은 성능에 치명적**.
- History 메모리는 `NumHistoryShards`에 비례(샤드별 캐시·큐) — shard 많을수록 메모리↑.

### 벤치마크/검증 도구 (직접 측정용)
- **Omes** — Temporal 공식 부하테스트 툴(`throughput_stress` 시나리오 등). 자기 워크로드로 right-sizing.
- `temporalio/benchmark-latency` 레포 + "Tips for running Temporal on Kubernetes", "K8s CPU Throttling" 블로그 = 실운영 튜닝 참고.

### NumHistoryShards = 빌드 시 확정 (불변)
- **[공식]** 소규모 prod **512** 권장. 작은 서비스라도 512면 무난(과하면 history 메모리·DB 압력↑). **변경 불가**라 목표 규모로 미리.

---

## 2. 확장 기준 — 무엇을 보고, 어떤 순서로 (Q2)

### 대전제: 수평 확장이 되다가 결국 **persistence DB가 천장**
- **[공식 블로그]** "거의 항상 persistence backend가 병목이 되는 지점까지 확장 가능." → DB는 넉넉·HA로, 그리고 **sync match를 유지해 DB 부하를 줄이는 게 1순위**(poller 부족 → async match → DB로 task flush → DB 부하 급증).

### 신호(metric) → 조치
| 신호 / 메트릭 | 임계 | 늘릴 것 |
|---------------|------|---------|
| **Schedule-to-Start latency** p95 | > 150ms (SLO) | worker **poller 수** ↑, task queue **partition** ↑, matching replica |
| **Poll Sync Rate** `poll_success_sync / poll_success` | < 99% | poller 수 ↑ (sync match 회복 → DB 부하↓) |
| **Shard lock latency** p95 `lock_latency_bucket` | > 5ms (이상 ~1ms) | **History** 자원/replica (shard 수는 빌드시 결정) |
| `service_latency`(StartWorkflow 등) ↑ / `state_transition_count` 정체 | — | **History** 스케일 |
| `persistence_latency` ↑ / **DB CPU > 80%** | — | **DB 스케일**(수직·IOPS·read replica·커넥션) — 천장 |
| frontend RPS↑ / `resource_exhausted` 에러 | — | **frontend** replica (stateless라 가장 쉬움) |

- **[공식 메트릭 3종]** `service_requests/errors/latency`, `persistence_requests/errors/latency`, `workflow_success/failed/timeout/...` — Prometheus+Grafana로 상시 관측.

### 증설 순서 (실무 권장)
1. **poller 충분히** (sync match 유지 → DB 부하 최소화) — worker 측. *시작 10+10이면 보통 부족, 100~150까지도.*
2. **frontend** 확장 (stateless, 연결/poll 분산).
3. **history / matching** 확장 (shard lock · schedule-to-start 신호 기반).
4. **DB** 수직/HA 강화 (천장 — IOPS·CPU·커넥션 수).
5. task queue **partition**(런타임 조정 가능) / **NumHistoryShards**(빌드시 결정) 재검토.

---

## 3. 장애방지 최소 replica (HA) (Q3)

> **[공식]** 99.99% 가용성은 "부하테스트로 검증하라"만 있고 **구체 replica 수 명시는 없음**. 아래는 k8s HA 통념 + Temporal 구조 근거의 권장값.

- **각 role 최소 2 replica** (롤링 업데이트·노드 장애로 1대 빠져도 지속):
  - ⚠️ **History 1 replica = 모든 shard가 한 pod = SPOF**. 2+여야 장애 시 shard 재분배(failover).
  - frontend 2+ (LB 뒤), matching 2+, worker(internal) 2+.
- **AZ 분산**: `topologySpreadConstraints` / pod anti-affinity로 replica를 노드·AZ에 흩뿌림.
- **PodDisruptionBudget**: `minAvailable`로 드레인/롤링 시 동시 중단 제한.
- **DB HA**: cnpg는 prod **3 인스턴스(1 primary + 2 replica)** 권장, 최소 2. AZ 분산. ([persistence.md](persistence.md) Q4)
- **최소 HA prod 합계 예시(1 클러스터)**: frontend×2 + history×2 + matching×2 + worker×2 + web-ui×1~2 + Postgres(cnpg)×3.

> 서비스별 독립 클러스터라 위 세트가 **서비스 수 × (dev/prod)** 만큼 곱해짐 → 작은 서비스는 dev에서 1 replica로 절약하고 prod만 2+로 가는 식의 차등도 가능([R4 비용](persistence.md) 고려).

---

## Sources
- [Production readiness checklist | docs.temporal.io](https://docs.temporal.io/self-hosted-guide/production-checklist)
- [Self-hosted defaults | docs.temporal.io](https://docs.temporal.io/self-hosted-guide/defaults)
- [Scaling Temporal: The basics (시작점 1CPU/1GB·DB 4c/32GB·throughput) | temporal.io](https://temporal.io/blog/scaling-temporal-the-basics)
- [Cloud Benchmark: Cloud vs Self-Hosted | temporal.io](https://temporal.io/blog/benchmarking-latency-temporal-cloud-vs-self-hosted-temporal)
- [Tips for running Temporal on Kubernetes | temporal.io](https://temporal.io/blog/tips-for-running-temporal-on-kubernetes)
- [K8s CPU Throttling 튜닝 | temporal.io](https://temporal.io/blog/tuning-temporal-server-request-latency-on-kubernetes)
- [OSS cluster metrics reference | docs.temporal.io](https://docs.temporal.io/references/cluster-metrics)
- [Monitor Temporal metrics | docs.temporal.io](https://docs.temporal.io/self-hosted-guide/monitoring)
