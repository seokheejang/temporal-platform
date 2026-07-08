# platform/monitoring — Temporal 관측성 (메트릭)

Temporal `example-service` 클러스터의 Grafana 대시보드·(추후) ServiceMonitor·알람을 관리한다.
수집 형상은 **pull 모델(ServiceMonitor)** — 개발팀 합의(2026-06-26). 전체 일감(M0~M6)은 [docs/STATUS.md §D1 관측성](../../docs/STATUS.md) 참조.

## 전제 (dev 실측 2026-06-26)

- **kube-prometheus-stack 기 가동** (`monitoring` ns) — 도구 설치 불필요, **ServiceMonitor/PrometheusRule만 추가**.
- **Temporal 서버 4 role 전부 `:9090/metrics` 노출** (headless svc `metrics:9090`). frontend/history/matching/worker 응답 확인.
- **cnpg PostgreSQL `:9187/metrics` 노출** (postgres exporter 내장).
- ⚠️ **worker 2개(Go·Python)는 메트릭 미노출** — SDK 메트릭 활성화가 선결(M4). 그래서 이 초안은 **서버 중심**.

## 파일

| 파일 | 내용 |
|------|------|
| `dashboards/temporal-server.json` | Temporal 대시보드 (서버 4 role + cnpg + **worker SDK**). 총 44패널. uid `temporal-server-eventautomation` 유지(파일명도 호환 위해 유지). |

## dashboards/temporal-server.json

서버 중심 대시보드 1장. 패널 메트릭은 **dev `/metrics` 직접 스크레이프로 확인한 실측값**(cnpg 2패널 제외).

**변수(templating)**
- `$datasource` — Prometheus 데이터소스 선택
- `$namespace` — Temporal namespace 필터 (multi/all). dev 값 예: `example_service_dev` (점이 `_`로 정규화됨에 주의).
- `$worker` — worker job 선택 (`label_values(up{job=~".*-worker-.*-metrics"}, job)`). 현재 workflow(Go)만 노출.

**패널 그룹 — 서버 (1~6, dev `/metrics` 실측)**
1. 클러스터 헬스 — shard 수(`numshards_gauge`=512)·membership 변경·총 RPS·persistence 에러율
2. Service RPC — role별 RPS(`service_requests`)·p95 latency(`service_latency` histogram)·에러 타입(`service_error_with_type`)
3. Persistence — p95/p99(`persistence_latency` histogram)·operation별 top
4. Shard/History — shard lock p95(`lock_latency`, 통념 <5ms)·acquire shards p95
5. Matching — **Sync Match Rate**(`poll_success_sync`/`poll_success`, 목표 >99%)·poll success/timeouts·task queue backlog(`task_lag_per_tl`)
6. DB(cnpg) — 수동 PodMonitor + 공식 메트릭명 확정(아래 §cnpg)

**패널 그룹 — Worker SDK (7~12, dev workflow worker `:9090` 실측 — M4 완료)**
7. Worker 헬스 — up·`num_pollers`·`task_slots_available`·sticky cache hit%
8. Workflow/Activity 실행 — `workflow_completed/failed_total` rate·endtoend latency p95/p99
9. Task queue 지연 — **`workflow_task_schedule_to_start_latency`**(워커 부족/적체 핵심 SLO)·task execution latency
10. 슬롯/폴링 — `task_slots_used/available`·task_queue별 `num_pollers`
11. 서버 통신 — `request_total` rate(operation별)·request/long-poll latency p95
12. Go 런타임 — goroutines·heap·CPU (자원/누수)

**메트릭 타입 → 쿼리 방식** (dev 실측 확인)
- 서버 histogram (`service_latency`·`persistence_latency` 등): `histogram_quantile(0.95, sum by (le,...) (rate(*_bucket[5m])))`
- ⚠️ **worker SDK latency는 summary 타입**(tally Prometheus reporter) — `_bucket` 없음! `quantile` 라벨 직접 조회: `max(temporal_..._latency_seconds{quantile="0.95"})`. histogram_quantile 쓰면 빈 그래프. (2026-06-30 실측 확정 — 노출 quantile: 0.5/0.75/0.95/0.99/0.999)
- ⚠️ worker summary는 **idle 구간에 NaN** 노출(샘플 없음) — 정상. long-poll(Poll*TaskQueue)은 항상 ~60s라 값 있음.
- counter (`service_requests`·`workflow_completed_total`·`*_total`): `rate(...[5m])`
- gauge (`numshards_gauge`·`task_lag_per_tl`·`task_slots_*`·`num_pollers`): 직접

## cnpg(DB) 메트릭 수집 (M3)

cnpg 1.29.0의 `enablePodMonitor`가 만드는 PodMonitor엔 `release` label을 못 붙여 Operator가 선택하지 못한다(서버 ServiceMonitor와 동일 원인). → cnpg 공식 권장대로 **수동 PodMonitor** 사용:
- [services/example-service/dev/db/cnpg-cluster.yaml](../../services/example-service/dev/db/cnpg-cluster.yaml): `monitoring.enablePodMonitor: false` (중복 방지)
- [services/example-service/dev/db/podmonitor.yaml](../../services/example-service/dev/db/podmonitor.yaml): `release: kube-prometheus-stack` label 붙인 PodMonitor (selector `cnpg.io/cluster=temporal-pg`, port `metrics`=9187)
- db 앱(ApplicationSet)이 `dev/db` 디렉토리를 통째로 sync → PodMonitor도 함께 적용.

cnpg 메트릭명은 **CloudNativePG 1.29 공식 default-monitoring 기준 확정**:
- `cnpg_backends_total` (gauge, label `state`/`datname` 등 — active 필터 권장)
- `cnpg_pg_replication_lag` (gauge, 초, 라벨 없음)
- `cnpg_collector_up` (gauge, 인스턴스 헬스 — cnpg엔 `pg_up` 없음)
- 출처: cloudnative-pg.io/documentation/1.29/monitoring · default-monitoring.yaml(release-1.29)

> ⚠️ 단 default monitoring ConfigMap이 켜져 있을 때만 노출 — sync 후 `:9187` 실제 확인 권장.

서버/matching 패널 메트릭은 전부 dev 실측 확정(sync 후 시리즈 수집 검증 완료).

## 상태 / 다음

- ✅ **M2 서버 수집**: ServiceMonitor(차트 values) — sync 후 시리즈 수집 검증 완료.
- ✅ **M3 DB 수집**: 수동 PodMonitor + 메트릭명 확정 — sync 후 `:9187` 실제 노출만 확인하면 됨.
- ✅ **M4 worker 수집+대시보드**: `charts/worker`에 ServiceMonitor 토글(`metrics.enabled`, workflow on) → `temporal_*` SDK 메트릭 수집 검증 완료. 대시보드에 worker 6그룹 추가(schedule_to_start·workflow 완료/실패·task slots·sticky cache·Go 런타임). ⚠️ activity-worker(Python)는 9090 미노출이라 미포함 — 노출 배선 후 `$worker`에 자동 합류.
- ✅ **M5 대시보드**: temporal-server.json (서버+worker+cnpg, 44패널).
- 🟡 **M6 PrometheusRule 알람**: ✅ 가용성(up==0) MVP 가동([services/example-service/dev/alerts/](../../services/example-service/dev/alerts/)). 다음 SLO 알람 후보 — schedule_to_start p99·sync match<95%·task_slots_available=0·persistence latency·shard lock. **임계치는 이 대시보드로 평시값 관측 후 확정**(알람 튜닝). 출처: docs.temporal.io worker-health·performance-bottlenecks.

## ⚠️ 선결조건 — ServiceMonitor (이게 없으면 대시보드가 빈다)

대시보드 ConfigMap만 올리면 **데이터가 안 나온다.** 원인은 수집 경로 부재 (실측으로 확정):

1. Temporal 공식 차트가 headless svc에 `prometheus.io/scrape:true`·`port:9090` annotation을 **기본으로 붙임**(`server.metrics.annotations.enabled:true`).
2. **그러나 dev Prometheus는 kube-prometheus-stack(Operator)** — Operator는 annotation을 안 보고 **ServiceMonitor만** 본다. → annotation 무시 → 시리즈 0건.
3. 차트의 `serviceMonitor`는 기본 `false` → 안 만들어짐.

> 검증: ServiceMonitor 필요 여부는 Temporal 고유가 아니라 **Prometheus Operator 환경의 표준**(공식 차트 values 주석 "Use this if you installed the Prometheus Operator", 기본 off). 공식 문서는 직접 scrape_config도 제시하나, dev는 Operator라 ServiceMonitor가 정답.

### 해법 — 차트 values에서 serviceMonitor 활성화 (GitOps)

손으로 ServiceMonitor 매니페스트를 만들지 않고 **공식 차트 옵션**을 켠다.
[services/example-service/dev/values.yaml](../../services/example-service/dev/values.yaml)의 `temporal.server.metrics`:

```yaml
temporal:
  server:
    metrics:
      serviceMonitor:
        enabled: true
        interval: 30s
        additionalLabels:
          release: kube-prometheus-stack   # Operator의 serviceMonitorSelector가 요구(실측) — 없으면 무시됨
```

→ 차트가 5개 role(frontend/internal-frontend/history/matching/worker) ServiceMonitor를 `metrics` 포트(9090)로 생성. `helm template` 렌더로 `release` label 부착 확인 완료.

**적용 = ArgoCD sync** (values 변경이라 git push 후 server 앱 sync):
```sh
KUBECONFIG=~/.kube/dev-cluster kubectl -n argocd get app dev-temporal-example-service-server   # 현재 상태
# ArgoCD UI 또는 argocd CLI로 sync (이 repo는 수동 sync 유지). values 변경은 sync로 반영됨.
```

**수집 확인** (sync 후 1~2분):
```sh
# ServiceMonitor 생성됐나
KUBECONFIG=~/.kube/dev-cluster kubectl get servicemonitor -n dev-temporal-example-service
# Prometheus에 시리즈 들어왔나 (빈 배열이면 아직)
KUBECONFIG=~/.kube/dev-cluster kubectl exec -n monitoring \
  prometheus-kube-prometheus-stack-prometheus-0 -c prometheus -- \
  sh -c "wget -qO- 'http://localhost:9090/api/v1/query?query=numshards_gauge'"
```
→ 시리즈가 채워지면 대시보드에도 데이터가 뜬다.

## Grafana 대시보드 적용 — kubectl (id/pwd·API 불필요)

dev Grafana(kube-prometheus-stack)는 **dashboard sidecar provisioning**이 켜져 있다.
`grafana_dashboards=1` label이 붙은 ConfigMap을 만들면 sidecar가 자동으로 읽어 대시보드로 로드한다.
(sidecar 실측: `LABEL=grafana_dashboards`, `LABEL_VALUE=1`, `NAMESPACE=ALL` → 어느 ns든 OK.)

> 로그인·Grafana API·UI import 전부 불필요. ConfigMap 하나만 apply 하면 끝.

### 적용 (apply)

```sh
# repo 루트에서 실행. dev = dev-cluster. monitoring ns에 dashboard ConfigMap 생성 (--dry-run | apply로 멱등)
KUBECONFIG=~/.kube/dev-cluster kubectl create configmap temporal-server-dashboard \
  --namespace monitoring \
  --from-file=temporal-server.json=platform/monitoring/dashboards/temporal-server.json \
  --dry-run=client -o yaml \
  | KUBECONFIG=~/.kube/dev-cluster kubectl label --local -f - grafana_dashboards=1 -o yaml \
  | KUBECONFIG=~/.kube/dev-cluster kubectl apply -f -
```

> `KUBECONFIG=~/.kube/dev-cluster`가 dev 클러스터(dev-cluster). 파이프 각 단계마다 prefix가 필요(서브셸이 분리됨). 한 번만 쓰려면 `export KUBECONFIG=~/.kube/dev-cluster` 후 prefix 없이 실행해도 됨.

- `--from-file=<key>=<path>`: ConfigMap data 키를 `temporal-server.json`으로 고정 (sidecar는 파일명 그대로 마운트).
- `create ... --dry-run=client -o yaml | label --local | apply`: **멱등** — 처음엔 생성, 이후엔 갱신. JSON을 고치고 같은 명령을 다시 돌리면 대시보드도 갱신된다.
- `grafana_folder` annotation을 추가하면 Grafana 폴더 지정 가능(선택). 위 파이프 끝에 추가:
  `... | KUBECONFIG=~/.kube/dev-cluster kubectl annotate --local -f - grafana_folder=Temporal -o yaml | KUBECONFIG=~/.kube/dev-cluster kubectl apply -f -`

### 확인

```sh
KUBECONFIG=~/.kube/dev-cluster kubectl get configmap temporal-server-dashboard -n monitoring --show-labels   # grafana_dashboards=1 확인
KUBECONFIG=~/.kube/dev-cluster kubectl logs -n monitoring -l app.kubernetes.io/name=grafana -c grafana-sc-dashboard --tail=20  # sidecar가 읽었는지
```
→ Grafana UI > Dashboards 에서 **"Temporal Server — example-service (dev)"** 검색. `$datasource`로 Prometheus 선택.

### 제거

```sh
KUBECONFIG=~/.kube/dev-cluster kubectl delete configmap temporal-server-dashboard -n monitoring
```

> ⚠️ 위 명령은 **클러스터를 변경**(ConfigMap 생성/삭제)한다 — 적용은 운영자가 직접 실행. 이 repo의 조회 도구는 read-only.
