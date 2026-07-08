# 0006. SDK worker는 공용 generic 차트 (서버는 서비스별, worker는 공용)

- Status: Accepted
- Date: 2026-06-12 (결정) / 2026-06-24 (ADR 박제)

## Context

[ADR-0005](0005-umbrella-wrapper-per-service.md)에서 **서버**(Temporal 엔진) 차트는 **서비스별 umbrella wrapper**(`services/<svc>/chart/`)로 갈랐다. 그렇다면 SDK worker(workflow/activity 비즈니스 코드를 실행하는 프로세스)는 어떻게 둘 것인가 — 서버처럼 서비스별로 쪼갤 것인가, 공용 1벌로 둘 것인가가 `charts/` 구조와 worker AppSet 설계를 막고 있었다.

먼저 용어를 못 박는다(혼동 방지):

```
서비스(예: example-service) = Temporal 클러스터 1벌의 단위. worker가 아니라 그 상위 그릇.
  ├── 서버  = Temporal 엔진 4 role(frontend·history·matching·worker[internal])  → charts/temporal (ADR-0005)
  ├── DB    = cnpg PostgreSQL                                                    → 별도 앱
  └── SDK worker들 = 사용자 코드를 실행하는 외부 프로세스                         → charts/worker (이 ADR)
        ├── orchestration-worker (Go)
        └── activity-worker (Python)
```

- **"worker"라는 단어가 두 곳에 나옴**: ① 서버 내부 `worker` *role*(엔진 부품) ② 우리가 배포하는 **SDK worker**(외부 프로세스). 이 ADR의 worker = ②.
- `example-service`은 **서비스**이지 worker가 아니다. activity-worker·orchestration-worker가 그 서비스에 속한 worker들이다.

worker의 실측 성격(2026-06-12 정합성 점검):
- 배포 형상 = **Deployment 1개, Service 없음**(outbound-only — worker가 frontend로 long-poll만, inbound 트래픽 없음).
- 서비스/언어(Go·Python)가 달라도 하는 일은 "컨테이너 띄우고 `TEMPORAL_ADDRESS`·`TEMPORAL_NAMESPACE`(+선택 mTLS/앱 env) 주입"이 전부.
- 서버와 달리 **서비스별로 다른 부속 리소스가 없다**(Certificate·HTTPRoute·dynamicconfig는 서버 쪽).
- upstream 차트 dependency가 없다(우리가 쓴 generic Deployment 템플릿).

## Decision

**SDK worker는 공용 generic 차트 `charts/worker` 1벌로 두고, worker별 차이는 values로만 흡수한다.**

```
charts/worker/                                   ← 공용 generic 차트 (전 서비스·전 worker 공유, 1벌)
services/<svc>/<env>/workers/<name>/values.yaml  ← worker 인스턴스 1개 = 디렉토리 1개 = ArgoCD 앱 1개
```

- 차트가 고정 주입: `TEMPORAL_ADDRESS`·`TEMPORAL_NAMESPACE` + mTLS TLS env(토글) — Temporal 연결 계약.
- worker별 차이는 values의 `image`·`replicaCount`·`resources`·자유 `env[]`/`envFrom[]`로 흡수(앱 시크릿은 `envFrom`+ESO).
- 배포: worker AppSet(`argocd/dev/applicationset-workers.yaml`)이 `services/*/dev/workers/*` 디렉토리마다 앱 1개 생성, 차트는 `charts/worker` + 그 worker values를 2-source로 합성(ADR-0005 §4와 같은 패턴).
- CI 연동: 앱 repo CI가 이미지 빌드 → 이 repo worker values의 `image.tag`만 커밋(GitOps). 차트(틀)는 고정, 변하는 건 values뿐.

## 왜 서버는 서비스별(ADR-0005)인데 worker는 공용인가 — 같은 원칙의 반대 결론

분리는 "필요한 만큼만" 한다는 동일 원칙([ADR-0004](0004-thin-shared-base.md) 정신)을 양쪽에 적용한 결과:

| 기준 | 서버 차트 (서비스별 wrapper) | worker 차트 (공용 generic) |
|---|---|---|
| 서비스별 부속 리소스 | mTLS Certificate·UI HTTPRoute·dynamicconfig — **확정적으로 다름** | 없음(Deployment 하나) |
| 독립 버전 pin | upstream 1.31.0 **서비스별 카나리 업그레이드** 필요(마이너 건너뛰기 금지) | upstream dependency 없음 |
| 업그레이드 폭발반경 | 서비스별 단계 적용 필요 | 해당 없음 |
| → 결론 | **분리할 이유 2개 존재 → 서비스별** | **분리할 이유 0개 → 공용** |

## Consequences

- worker 종류가 늘어도 차트는 1벌 — probe·securityContext·라벨 수정이 한 곳에 반영(중복 제거).
- `charts/worker`는 ADR-0005가 "공유 wrapper로는 불사용"이라 한 `charts/` 최상위의 **유일한 정당한 입주자**다(서버 wrapper는 서비스별, worker generic은 공용 — 둘은 다른 차트).
- 한계: worker가 generic을 벗어나는 요구(예: 특정 worker만 Service·HPA·sidecar)가 생기면 차트에 토글 옵션을 추가하거나, 그 worker만 별도 차트로 분기(서버의 vendor 탈출구와 같은 발상). 현재 MVP 범위엔 없음.
- 검증: helm template/lint 통과(2026-06-12·2026-06-24). env 신규 추가는 `env[]`/`envFrom[]` 자유 확장으로 흡수됨(코드 수정 불필요).
