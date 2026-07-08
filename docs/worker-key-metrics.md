# 개발자 관점 핵심 지표 — Temporal Worker

> 작성: 2026-07-01 · 상태: **구현 완료(dev)** · 범위: dev → prod
> "시스템 자원(CPU/heap/goroutine)" 말고 **워크플로우·액티비티를 작성·운영하는 개발자에게 실제로 중요한 지표**가 무엇인지 정리한다.
> 개발자 대시보드([platform/monitoring/dashboards/temporal-developer.json](../platform/monitoring/dashboards/temporal-developer.json)) 구현·커밋 완료. 서버 중심 대시보드는 [temporal-server.json](../platform/monitoring/dashboards/temporal-server.json).

관련: [platform/monitoring/README.md](../platform/monitoring/README.md) · [alerting-design.md](alerting-design.md)

---

## 요약 — 왜 자원 지표만으론 부족한가

Go 런타임 지표(goroutines/heap/CPU)는 **장애 후 원인 규명**용이지, 개발자가 평소 보는 지표가 아니다.
개발자가 정작 알고 싶은 건 세 가지다:

1. **내 워커가 일을 제때 처리하고 있나** (지연 / 워커 부족)
2. **내 코드가 실패하고 있나** (비즈니스 정확도 / 배포 사고)
3. **재시도·타임아웃이 조용히 쌓이고 있나** (성공처럼 보이지만 병들어가는 상태)

핵심 통찰: **schedule-to-start가 튀는데 워커 CPU는 한가하다 → 자원 문제가 아니라 poller/slot 부족.**
자원 지표만 보면 이걸 놓친다.

---

## 1순위 — "일을 제때 처리하고 있나"

| 지표 | 의미 | 현재 대시보드 |
|------|------|:---:|
| `workflow_task_schedule_to_start_latency` | 태스크가 큐에 올라와서 워커가 집어들기까지의 지연. **워커 부족의 1차 신호** | ✅ 있음 |
| `temporal_activity_schedule_to_start_latency` | 액티비티 버전. 워크플로우와 별개 워커/task queue라 **따로 봐야 함** | ✅ 추가 (histogram/ms) |
| `approximate_backlog_count` (backlog) | task queue에 실제 대기 중인 태스크 수 (서버측). ⚠️ `task_lag_per_tl` 아님 — 아래 함정 참조 | ✅ 있음 |
| Sync Match Rate (`poll_success_sync`/`poll_success`) | 태스크가 DB 안 거치고 바로 매칭되는 비율 (목표 >99%) | ✅ 있음 |

> **schedule-to-start 지표가 스케일링 판단의 핵심.** 이 값이 튀면 워커 수/slot을 늘려야 한다는 뜻이지, 코드가 느린 게 아니다.

---

## 2순위 — "내 코드가 실패하고 있나" (비즈니스 정확도)

| 지표 | 의미 | 현재 대시보드 |
|------|------|:---:|
| `workflow_failed` / `workflow_completed` | 워크플로우 실패율 | ✅ 있음 |
| activity 실패 | 액티비티 실패 (재시도 유발) | 🟡 근사 (실패 counter 미노출 — 실행−성공으로 대용) |
| `temporal_activity_execution_latency` | 액티비티 자체 실행 시간 (내 코드/외부 호출이 느린지) | ✅ 추가 (histogram/ms) |
| `temporal_workflow_task_execution_failed_total` | 워크플로우 태스크 실패 — **non-determinism 에러 포함** | ✅ 추가 (0 라인) |

> ⚠️ **`workflow_task_execution_failed`는 특히 중요.**
> 워크플로우 코드를 배포로 바꿨을 때 발생하는 **non-determinism 에러**가 여기서 잡힌다.
> 배포 직후 이 값이 튀면 → versioning 실수 신호. 배포 사고를 가장 빨리 감지하는 지표.

---

## 3순위 — "재시도·타임아웃이 조용히 쌓이고 있나"

| 지표 | 의미 | 현재 대시보드 |
|------|------|:---:|
| `temporal_activity_task_received` (재시도 포함) | 액티비티가 계속 재시도 중 — 결국 성공하니 **실패 알람엔 안 잡힘** | ✅ 추가 (전용 retry counter 없어 대용) |
| `workflow_endtoend_latency` | 워크플로우 시작~완료 전체 소요 (사용자 체감 지연) | ✅ 있음 |
| `sticky_cache_hit` / `sticky_cache_miss` | 캐시 미스 시 full history replay → 지연·부하 | ✅ 있음 (hit%) |

> 재시도는 "성공하는 실패"라 실패율 지표에 안 잡히지만, 외부 API가 불안정하다는 조기 경보다.

---

## 진단 — 대시보드 커버리지 (2026-07-01 갱신)

**workflow(Go) 관점 — 탄탄:**
schedule-to-start · backlog · sync match · 완료/실패 · task_execution_failed(non-determinism) · endtoend · sticky cache

**activity(Python) 관점 — 추가 완료(개발자 대시보드):**
schedule-to-start · execution latency · 실패 근사(실행−성공) · 시도율(task_received)

**남은 한계:**
- ⚠️ activity **전용 실패/재시도 counter가 Python Core SDK에 없음** → 실패는 근사치. 정확한 최종 실패는 워크플로우 실패·history로 확인.
- 실측 데이터는 activity가 **실제 실행돼야** 시리즈 생성(histogram counter 특성) — idle 구간 No data는 정상.

---

## ⚠️ worker별 SDK가 다르다 — 쿼리 방식이 갈린다 (실측 2026-07-01)

두 worker의 Temporal SDK가 달라 **같은 개념의 지표라도 메트릭명·타입·단위가 다르다.**
로컬 test server로 `/metrics`를 실측 덤프해 확정했다(상상 아님).

| | workflow (Go SDK, tally) | activity-worker (Python **Core SDK**) |
|---|---|---|
| latency 타입 | **summary** (`quantile` 라벨) | **histogram** (`_bucket`/`_sum`/`_count`) |
| latency 단위 | 초 (`_seconds`) | **밀리초** (`_seconds` 접미사 없음) |
| latency 쿼리 | `max(..._latency_seconds{quantile="0.95"})` | `histogram_quantile(0.95, sum by(le,...)(rate(..._latency_bucket[5m])))` |
| counter 접미사 | `_total` 있음 | **`_total` 없음** |
| 예: 완료 | `temporal_workflow_completed_total` | `temporal_workflow_completed` |

> Python은 `worker.py`에서 `PrometheusConfig(bind_address=...)`만 넘기고 옵션 전부 기본값
> (`counters_total_suffix=False`, `unit_suffix=False`, `durations_as_seconds=False`) → 위 표대로 노출.

### activity-worker가 실제 노출하는 activity 메트릭 (실측 — 딱 4종)

- `temporal_activity_execution_latency` (histogram, ms) — 실행 시간
- `temporal_activity_schedule_to_start_latency` (histogram, ms) — 대기
- `temporal_activity_succeed_endtoend_latency` (histogram, ms) — 스케줄~최종성공
- `temporal_activity_task_received` (counter) — 수신 시도(재시도 포함)

⚠️ **`temporal_activity_execution_failed`(실패 counter)는 노출되지 않는다.**
실패는 재시도로 흡수되고 최종 실패는 `temporal_workflow_failed`로만 잡힌다.
→ 대시보드는 실패를 `execution_latency_count − succeed_endtoend_count`(실행−성공)로 근사.

### 노출 배선 (완료)

activity-worker는 `METRICS_ADDRESS=0.0.0.0:9090`으로 앱이 메트릭을 열고,
values의 `metrics.enabled: true`로 수집 배선(containerPort/Service/ServiceMonitor)을 켰다
(2026-07-01, endpoint ready·수집 배선 실측 확인). `platform/monitoring/README.md` M4 참조.

---

## ⚠️ task queue backlog — 함정 2개 (실측 2026-07-01)

**함정 1 — `task_lag_per_tl`을 sum하면 부풀려진다.**
matching의 `task_lag_per_tl`은 **파티션별 gauge**인데 `taskqueue` 라벨이 root/내부 파티션마다 값이 달라
`sum by (taskqueue)`하면 파티션이 중복 합산돼 실제보다 훨씬 크게 나온다(dev에서 600~800K로 보였으나 실제 적체 아님).
공식도 "sum 집계 misleading"이라 명시(temporalio/temporal#3143·#9945).
→ **실제 backlog는 `approximate_backlog_count` 사용**(서버측 실제 대기 근사, dev 실측 평시 0).
이 메트릭은 `partition`이 별도 라벨이라 `taskqueue`가 깔끔한 큐명 → `sum by (taskqueue, task_type)` 안전.

**함정 2 — `approximate_backlog_count`엔 `$namespace` 필터가 안 먹는다.**
Prometheus가 스크레이프 시 메트릭 원래 `namespace` 라벨을 k8s `namespace`와 충돌 방지로 **`exported_namespace`로 rename**한다.
그 결과 라벨이 갈린다(실측):
- `namespace="dev-temporal-example-service"` (k8s ns)
- `exported_namespace="example_service_dev"` (Temporal ns)

대시보드 `$namespace` 변수는 `label_values(service_requests, namespace)` → **k8s ns 값**(`dev-temporal-example-service`)을 반환.
그래서 `exported_namespace=~"$namespace"`가 매칭 0건 → **No data**.
→ backlog 패널은 **namespace 필터를 뺀다**(dev Temporal ns 하나뿐이라 실용상 무해). 필터 필요 시 변수를 `exported_namespace` 기준으로 별도 정의해야 함.

> ⚠️ 메트릭마다 `namespace` 라벨이 k8s ns인지 Temporal ns인지 다르다(server 메트릭은 k8s ns라 `$namespace` 필터가 먹음).
> 새 패널 만들 때 라벨을 Metrics browser로 반드시 실측 확인할 것.

---

## 완료 (2026-07-01)

- ✅ **메트릭 실측 검증** — 로컬 test server로 `/metrics` 덤프, Python Core SDK 메트릭명·타입·단위 확정.
- ✅ **activity-worker 메트릭 노출 배선** — `metrics.enabled: true` (커밋 `b71460c`), 수집 실측 확인.
- ✅ **개발자 대시보드** — `temporal-developer.json` 12패널 (workflow/activity/matching).
- ✅ **SLO 알람** — `TemporalWFTaskExecutionFailed`·`TemporalWorkflowFailed` (둘 다 critical, increase()·for 1m). `alerts-rules.yaml`.

## 다음 단계 (남은 것)

1. **평시값 관측 후 임계치 알람 추가** — schedule-to-start p99·sync match<95%·backlog 급증. 며칠 평시 데이터 필요(`alerting-design.md` M6).
2. **적용** — 위 변경 모두 ArgoCD sync 필요(server 앱=알람, worker 앱=메트릭, grafana=대시보드 configmap).
3. **prod 확장** — dev 검증 후 prod에 동일 적용.
