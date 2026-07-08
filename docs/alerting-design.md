# Temporal 알람 설계 (PrometheusRule → Slack)

> 작성: 2026-06-30 · 상태: **설계 + MVP 구현** · 범위: dev(우선) → prod
> Temporal 서버·worker 장애를 Slack으로 알리기 위한 설계. 룰·라우팅 **전부 이 repo에서 관리**(아래 검토 결론).
> ⚠️ **알람 채널은 observability 공통채널이 아닌 이 repo 전용 Slack 채널**(사용자 결정) — 자체 AlertmanagerConfig로 라우팅.
> observability에서 빌려쓰는 것: Prometheus·Alertmanager **엔진**(ruleSelector·alertmanagerConfigSelector가 열려있어 우리 CR을 채택)뿐. 룰·receiver·webhook은 전부 이 repo.

이 문서의 클러스터/메트릭 사실은 2026-06-30 dev read-only 실측 기준. 메트릭명은 실제 수집 중인 것만 사용(상상 금지).

---

## 1. 검토 결론 — 룰을 어디서 관리하나

**이 repo에서 PrometheusRule을 관리한다 (observability에 합치지 않음).** 기술적으로 가능하고, 응집도상 맞는 방향.

### 왜 가능한가 (실측)

알람이 Slack까지 가는 체인은 **룰 출처를 따지지 않는다**:

```
PrometheusRule ──(라벨 managed-by=observability)──> Prometheus 채택 ──(alert severity)──> Alertmanager ──(severity 매칭)──> Slack
```

| 요소 | dev 실측값 | 함의 |
|------|------------|------|
| Prometheus `ruleSelector` | `{app.kubernetes.io/managed-by: observability}` | 이 라벨만 붙이면 **어느 repo·ns의 룰이든** 채택 |
| Prometheus `ruleNamespaceSelector` | `{}` (전체 ns) | Temporal ns(`dev-temporal-*`)에 둬도 watch됨 |
| Alertmanager `alertmanagerConfigSelector`·`NamespaceSelector` | 둘 다 `{}`(모든 ns 채택) | ⭐ **이 repo가 자체 AlertmanagerConfig 추가 가능** → 전용 채널 라우팅 |
| Alertmanager `matcherStrategy` | `None` (dev 실측) | route matcher가 ns 자동제한 안 됨 → **route.matchers로 service 라벨 좁혀야** 다른 alert 안 샘 |
| AlertmanagerConfig 참조 Secret ns | Operator는 **config와 같은 ns**에서 읽음 | rule·config·secret 셋을 한 ns(`dev-temporal-example-service`)로 묶음 → AppProject `dev-temporal-*` 허용범위 (monitoring 불침범) |
| observability Application | `path: manifests`(자기 repo만) sync | 이 repo 룰을 **prune 안 함** (selfHeal 충돌 없음) |

> **채널 분리 결정(사용자)**: observability 공통 Slack이 아닌 **이 repo 전용 채널**로 받음. severity는 채널 내 분기(critical=더 자주 리마인드)로만 쓰고, 채널 자체는 `service=temporal-example-service` matcher로 라우팅.

→ observability는 **인프라(alertmanager·slack·라벨 규약) 제공**, 룰은 개방형. 이 repo가 룰만 올리면 됨.

### 왜 이 repo가 맞나 (vs observability 합치기)

| | 이 repo (채택) | observability 합치기 |
|---|---|---|
| 응집도 | ⭐ 차트·values·ServiceMonitor와 한곳 (ADR-0002 자기완결) | 룰만 분리 |
| 작성 방식 | 평범한 PrometheusRule YAML | ⚠️ observability는 **jsonnet 빌드** — 학습·진입장벽 |
| 변경 주체 | Temporal 담당 직접 | observability repo PR 경유 |
| 결합도 | 라벨 규약 한 줄만 의존 (느슨) | 강결합 |

이 repo는 이미 ServiceMonitor(`charts/worker`)·PodMonitor(`db/`)를 자체 관리 중 → PrometheusRule만 외부로 보낼 이유 없음.

---

## 2. 지켜야 할 계약 (observability 규약 — 어기면 Slack 안 감)

이 repo의 PrometheusRule이 기존 Slack 파이프라인을 타려면 **반드시**:

1. **PrometheusRule 라벨 `app.kubernetes.io/managed-by: observability`** — 없으면 Prometheus `ruleSelector` 탈락 → 룰 자체가 로드 안 됨.
2. **각 alert에 `labels.severity: critical | warning`** — Alertmanager 라우팅 매칭 키. 없으면 `null` receiver로 빠져 **Slack 미전송**.
3. **`annotations.summary` / `description`** — Slack 메시지 본문 템플릿이 이 필드 렌더(없으면 메시지 빈약). `runbook_url`(선택)도 렌더됨.
4. **(권장) `labels.stage: dev|prod`** — Slack 제목에 `[DEV]`/`[PROD]` 태그로 표시(observability 템플릿 `.CommonLabels.stage`).

> ⚠️ 이 규약은 관측 플랫폼 설정에서 역산한 것이다. 플랫폼이 규약을 바꾸면(예: ruleSelector 라벨 변경) 이 repo 룰도 따라가야 함. 결합점은 이 라벨 하나뿐.

---

## 3. 배선 — 서버 wrapper 차트에 통합 (확정)

**별도 ArgoCD 앱을 만들지 않는다**(앱 수 최소화, 사용자 결정). 룰·라우팅을 서버 wrapper 차트의 helm 템플릿으로 넣어 **서버 앱이 같이 sync**한다 — mTLS cert·gRPC LB 같은 기존 부속 리소스와 동일 자리.

```
services/example-service/
├── chart/templates/
│   ├── alerts-rules.yaml     # PrometheusRule (up==0) — alerts.enabled 토글
│   └── alerts-config.yaml    # AlertmanagerConfig (전용 채널 라우팅)
├── chart/values.yaml         # alerts: {enabled, webhookSecretName, webhookSecretKey}
├── dev/values.yaml           # alerts.enabled: true (dev 토글)
└── dev/alerts/               # 운영자 도구만 (create-webhook-secret.sh, README)
```

- **ns**: 차트가 서버 ns(`dev-temporal-example-service`)에 배포 → 룰·config·webhook Secret 전부 이 ns. Operator가 AlertmanagerConfig 참조 Secret을 같은 ns에서 읽으므로 자동 일치. (worker 알람도 job 라벨로 잡으니 ns 분리 불필요)
- **sync 주체**: 기존 **서버 Application**(`dev-temporal-example-service-server`). 차트 values 토글이라 git push 후 서버 앱 sync로 반영 — **AppSet 변경·재적용 불필요**(새 앱 0개).
- release명·job 라벨은 `.Values.env`/`.Values.svcName`으로 동적 생성 → dev/prod 공통(prod 복제 시 자동 치환).

---

## 4. 알람 룰 후보 (실재 메트릭 기반)

dev에서 **실제 수집 확인된 메트릭만** 사용. 임계치는 시작값(운영하며 튜닝).

### 4-A. 가용성 — `up` (가장 중요, 모든 컴포넌트 공통)

| alert | 식 | severity | 비고 |
|-------|-----|----------|------|
| TemporalServerDown | `up{job=~"dev-temporal-example-service-server-.*-headless"} == 0` for 2m | critical | 서버 4 role(frontend/history/matching/worker) 각각 |
| TemporalWorkerDown | `up{job="dev-temporal-example-service-worker-workflow-metrics"} == 0` for 5m | warning | worker는 재배포 잦아 2m→5m 여유 |
| TemporalDBDown | `up{job="dev-temporal-example-service/temporal-pg"} == 0` for 2m | critical | cnpg PodMonitor 타깃 |

> job 라벨은 dev 실측값. prod은 `prod-` prefix로 치환(또는 정규식 `.*-server-.*-headless`로 env 무관하게).

### 4-B. 서버 내부 오류 (service-side 메트릭 — 실재 확인)

| alert | 메트릭 근거 | severity |
|-------|------------|----------|
| TemporalPersistenceErrors | `persistence_error_with_type` / `persistence_errors` 증가율 | warning→critical |
| TemporalServiceErrors | `service_error_with_type` 증가율 (frontend gRPC 오류) | warning |
| TemporalPersistenceLatencyHigh | `persistence_latency_bucket` p99 임계 초과 | warning |
| TemporalDBConnPoolSaturation | `persistence_sql_in_use / persistence_sql_max_open_conn` 高 | warning |

### 4-C. worker SDK (client-side 메트릭)

dev에서 **실제 수집 확인된 것**(2026-06-30):
- 지연: `temporal_workflow_task_execution_latency_*`, `temporal_activity_execution_latency_*`, `temporal_activity_schedule_to_start_latency_*`, `temporal_workflow_task_schedule_to_start_latency_*`
- 폴링: `temporal_workflow_task_queue_poll_empty_total` / `_poll_succeed_total`, `temporal_activity_poll_no_task_total`
- long-poll: `temporal_long_request_latency_seconds`

| alert | 메트릭 근거 | severity |
|-------|------------|----------|
| TemporalWFTaskScheduleToStartHigh | `temporal_workflow_task_schedule_to_start_latency_*` p99 高 = 워커 부족/적체 | warning |
| TemporalActivityScheduleToStartHigh | `temporal_activity_schedule_to_start_latency_*` p99 高 = 큐 적체 | warning |
| TemporalWFTaskExecLatencyHigh | `temporal_workflow_task_execution_latency_*` p99 비정상 | warning |

> ⚠️ **확인 필요 — 실패(failure) 카운터**: `temporal_workflow_task_execution_failed_total`·`temporal_activity_execution_failed_total` 류는 **2026-06-30 현재 수집 메트릭에 없음.** 원인 미확정 — ⓐ 실패 0건이라 시계열 미생성(Prometheus는 발생해야 노출)일 수도, ⓑ 이 SDK 버전이 다른 메트릭명을 쓸 수도. **워크플로 실패를 한 번 유발해 메트릭명을 실측 확인한 뒤** 실패 기반 알람을 추가할 것. 그 전까지는 위 latency/적체 기반으로 간접 감지.
> ⚠️ worker 알람은 **현재 workflow(Go)만** 적용 가능 — activity-worker(Python)는 9090 미노출(메트릭 없음). activity-worker 메트릭 배선 후 동일 룰 확장.

### 시작 범위 (MVP — 과알람 방지)

처음엔 **4-A(up 전부) + 4-B의 PersistenceErrors/ServiceErrors**만. 4-C 세부는 워크로드 패턴 보고 추가. 임계치 없는 알람 남발은 피로도만 키움.

---

## 5. 열린 결정

1. ~~sync 배선~~ → ✅ **확정: 서버 wrapper 차트 통합**(별도 앱 없음, §3).
2. **룰 ns 배치** — 대상별 ns vs 한 ns 통일.
3. **severity 분배** — 어떤 걸 critical(pager+chat) vs warning(chat only)로. up/persistence=critical, worker=warning 제안.
4. **임계치·for 지속시간** — 4-B/4-C latency·error rate 구체값(운영 데이터 없어 초기 보수적).
5. **prod 라벨 치환** — job 정규식으로 env 무관하게 vs env별 룰 분리.
6. **stage 라벨 주입** — dev/prod 구분 위해 룰에 `stage` 넣을지(Slack 제목 태그).

---

## 6. 참고

- 관측 플랫폼(Prometheus/Alertmanager)의 라우팅·라벨 규약은 사용 환경의 플랫폼 설정을 따른다.
- 룰 채택 라벨: `app.kubernetes.io/managed-by: observability` (사용 환경의 Prometheus ruleSelector에 맞춰 조정).
- 이 repo 메트릭 수집: [charts/worker/templates/servicemonitor.yaml](../charts/worker/templates/servicemonitor.yaml) · [services/example-service/dev/db/podmonitor.yaml](../services/example-service/dev/db/podmonitor.yaml)
- 서버 메트릭 ServiceMonitor: 서버 wrapper values `temporal.server.metrics.serviceMonitor`
- 전체 토폴로지(메트릭 수집 경로 포함): [docs/architecture/overview-topology.html](architecture/overview-topology.html)
