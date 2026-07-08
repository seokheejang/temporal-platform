# Runbook — Temporal namespace 등록 (worker 접속 선행 작업)

> **상태: 🔴 미실행 — 🔲 namespace 이름 앱팀 확정 대기.** worker(workflow·activity-worker)가 Temporal 서버에 붙으려면, 그 worker가 쓸 **Temporal namespace를 서버에 미리 등록**해야 한다. 등록 안 된 namespace로 붙으면 worker가 `NamespaceNotFound`로 기동 실패한다.
>
> **이건 "외부 namespace와 통신"이 아니라 "워크로드용 namespace 사전 생성"이다.** namespace는 외부/내부 구분이 아니라 Temporal 서버 *내부의* 논리공간이고, self-hosted Temporal은 (`default`조차) 명시 등록을 요구한다.
>
> ⚠️ **namespace 이름은 앱 도메인 값 → 앱 개발자가 지정**(인프라 단독 결정 아님). 앱 코드 기본값은 `example-service-dev`(Go·Python). **아래 명령의 `<TEMPORAL_NS>`에 앱팀 확정값을 넣어 실행**한다(worker values `temporal.namespace`와 반드시 일치). 참고 권장: Temporal 공식 [Namespace best practices](https://docs.temporal.io/best-practices/managing-namespace)(`<use-case>-<env>`·인프라토큰 제외). worker values: [services/example-service/dev/workers/](../../services/example-service/dev/workers/).
>
> 🛠 **자동화 스크립트**: 아래 절차는 [scripts/temporal/register-namespace.sh](../../scripts/temporal/register-namespace.sh)로 한 번에 실행 가능(idempotent — 이미 있으면 describe만, `--dry-run` 지원). 운영자가 직접 실행:
> ```bash
> ./scripts/temporal/register-namespace.sh --svc example-service --env dev \
>     --namespace example-service-dev
> ```
> 아래 단계별 수동 절차는 스크립트가 하는 일의 설명 + 트러블슈팅 참고용.

## ⚠️ 실행 원칙

- 아래 **변경(mutating) 명령은 운영자가 직접 실행**한다. (이 repo의 자동화/AI 보조는 read-only 점검·가이드만 — namespace create/update/delete는 모두 변경 작업)
- 실행 위치: **`dev-temporal-example-service` k8s ns의 admintools 파드 안**에서 `temporal` CLI로. (admintools가 서버 frontend로 붙는 진입점)
- ⚠️ **개념 구분 주의** — 이 런북엔 두 종류의 "namespace"가 나온다:
  - **k8s namespace** `dev-temporal-example-service` = 파드가 사는 곳 (`kubectl -n` 인자)
  - **Temporal namespace** `<TEMPORAL_NS>` = 서버 안 논리공간 (`--namespace` / `temporal operator namespace` 인자)
  - **둘은 다른 레이어**라 이름이 달라도(달라서) 정상.

---

## 0. 검증된 현재 환경 (2026-06-24, read-only 점검)

| 항목 | 실측값 | 함의 |
|------|--------|------|
| k8s ns | `dev-temporal-example-service` (Active) | admintools·server·db가 사는 곳 |
| admintools | deploy `dev-temporal-example-service-server-admintools` (1/1) | CLI 진입점. **pod 이름은 바뀌므로 deploy로 exec** |
| frontend Service | `dev-temporal-example-service-server-frontend:7233` | cluster health = **SERVING**, 서버 1.31.0 |
| temporal CLI | `temporal version 1.7.0` (admintools 내장) | `operator namespace` 서브커맨드 사용 |
| **등록된 Temporal namespace** | **`temporal-system`(시스템) · `smoke-test`(throwaway)** | 🔴 **`<TEMPORAL_NS>` 미등록 → 생성 필요** |

> `temporal-system`은 서버 내부 운영용이라 건드리지 않는다. `smoke-test`는 Phase 1 검증용 throwaway(워크로드용 아님).

---

## 1. 등록 전 확인 (read-only)

admintools 파드로 들어가 현재 등록된 namespace를 확인한다. `ADDR`는 frontend Service 주소.

```bash
# k8s ns(-n)와 Temporal address를 변수로 (오타 방지)
KNS=dev-temporal-example-service
ADDR=dev-temporal-example-service-server-frontend:7233

# admintools 파드 이름 얻기 (pod 이름은 재배포 시 바뀌므로 매번 조회)
POD=$(kubectl -n $KNS get pods -o name | grep admintools | head -1)

# 현재 등록된 Temporal namespace 목록 (<TEMPORAL_NS> 없어야 정상 = 생성 대상)
kubectl -n $KNS exec $POD -- temporal operator namespace list --address $ADDR
```

기대: `temporal-system`·`smoke-test`만 보이고 `<TEMPORAL_NS>`은 없음.

---

## 2. namespace 생성 (★ 변경 작업 — 운영자 실행)

```bash
kubectl -n $KNS exec $POD -- \
  temporal operator namespace create \
    --address $ADDR \
    --namespace <TEMPORAL_NS> \
    --retention 7d \
    --description "example-service worker/activity 워크로드용 (dev)"
```

옵션 설명 (CLI 1.7.0 `--help` 실측 — `--namespace`·`--retention duration`·`--description` 확인됨):
- `--namespace <TEMPORAL_NS>` — **Temporal namespace 이름**(확정값, §A2). worker values의 `temporal.namespace`와 **반드시 일치**.
- `--retention 7d` — 완료된 workflow Event History 보존기간. **dev=7일 권장**(공식: dev 짧게·prod 길게). 서버 기본 3일·최소 1일. `7d`/`168h` 동일(공식 예시는 `5d`식 일 단위 표기).
- `--description` — 용도 메모(선택, 권장).

> **prod(prod)는 별도** — namespace `example-service-prod`(또는 컨벤션 확정값), retention 길게(예: `30d`). prod 클러스터에서 같은 절차로 별도 실행.

---

## 3. 등록 검증 (read-only)

```bash
# 목록에 <TEMPORAL_NS> 이 보이는지
kubectl -n $KNS exec $POD -- temporal operator namespace list --address $ADDR

# 상세 — retention·state(Registered) 확인
kubectl -n $KNS exec $POD -- \
  temporal operator namespace describe --address $ADDR --namespace <TEMPORAL_NS>
```

기대: `State: Registered`, `Retention: 168h0m0s`(또는 지정값), 이름 일치.

---

## 4. 이후 — worker 배포

namespace가 `Registered`되면 worker가 붙을 수 있다. worker values의 `temporal.namespace: <TEMPORAL_NS>`이 이 등록값과 일치하므로, image(CI)·시크릿(activity-worker)이 채워지면 ArgoCD sync로 배포 → frontend에 polling 시작.

> worker가 여전히 `NamespaceNotFound`면: ① 이름 오타(values vs 등록값) ② 잘못된 address(다른 클러스터) ③ namespace state가 `Deprecated`/`Deleted`인지 describe로 확인.

---

## 트러블슈팅

| 증상 | 원인 | 대응 |
|------|------|------|
| `NamespaceNotFound` (worker 로그) | namespace 미등록 또는 이름 불일치 | §2 생성 / values의 `temporal.namespace` 대조 |
| `namespace already exists` (create 시) | 이미 등록됨 | 정상 — describe로 retention만 확인. 변경은 `namespace update` |
| connection refused / DEADLINE_EXCEEDED | address 오류·서버 다운 | `temporal operator cluster health --address $ADDR` = SERVING 확인 |
| retention 바꾸고 싶음 | 생성 후 변경 | `temporal operator namespace update --namespace <TEMPORAL_NS> --retention <new>` (변경 작업) |

---

## 실행 기록

_(미실행 — 운영자가 §2 실행 후 날짜·결과·실제 retention 값을 여기 기록)_
