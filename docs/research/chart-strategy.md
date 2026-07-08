# R1. Chart 전략 — ✅ 결정됨 ([ADR-0005](../adr/0005-umbrella-wrapper-per-service.md))

upstream `temporalio/temporal` 차트를 이 repo에서 어떻게 참조/관리할지.

## 실측 (2026-06-11 — ArtifactHub API + GitHub raw)

| 항목 | 확인값 | 함의 |
|------|--------|------|
| 공식 차트 | `temporalio/temporal` **chart 1.2.0 / server 1.31.0** (repo `https://go.temporal.io/helm-charts`, 소스 `temporalio/helm-charts` 내 `charts/temporal/`) | 1.x 졸업 — 과거 "0.x 실험적" 단계 아님 |
| **subchart 의존성 없음** | `Chart.yaml`에 `dependencies:` 블록 자체가 없음 — cassandra/grafana 등 번들 제거됨 | "공식 차트는 무겁다"는 옛 전제 **폐기**. BYO-DB/관측성 구조라 우리 cnpg·모니터링 방향과 정합 |
| values 최상위 | `server` · `web` · `schema` · `admintools` · `extraObjects` 등 | **schema setup Job 내장**(A4 별도 구현 불필요 가능성) · `extraObjects`로 임의 리소스 주입 가능 |
| GitOps 가이드 | README가 `existingSecret`(production 권장)·**ESO ExternalSecret 예시** 직접 문서화 | 우리 ESO 패턴(K1에서 검증)과 동일 |
| 프리셋 values | repo에 `values/` 디렉토리(시나리오별 프리셋) | 참고용 |

## 후보 비교 (실측 반영)

전제: 서비스별 독립 클러스터(ADR-0003) · 3-layer values(ADR-0004) · ArgoCD 자기완결 repo(ADR-0002) · 서비스마다 추가 리소스 필요(mTLS `Certificate`, UI HTTPRoute, dynamicconfig CM 등 — B3/C2에서 확정).

| | A. Umbrella (서비스별 wrapper chart) | B. ArgoCD multi-source | C. Vendoring (복사/fork) |
|---|---|---|---|
| 구조 | `charts/temporal-base/`가 공식 차트를 dependency로 pin, 서비스 values가 `temporal:` 키 아래 override | Application이 chart(helm repo) + values(git `$values` ref) 두 source 참조 | 공식 차트를 repo에 복사 |
| 3-layer values | helm 다중 `-f` merge — 단 **`temporal:` 키 아래로 한 단계 중첩** | helm 다중 valueFiles merge — **중첩 없음** (우리 설계 그대로) | 중첩 없음 |
| 추가 리소스(Certificate 등) | ✅ wrapper templates/에 동거 — **한 source·한 앱** | ⚠️ 별도 git source/디렉토리 + 같은 Application에 추가 source — 구성 분산 | ✅ templates에 직접 추가 (upstream diff 오염) |
| 버전 pin | Chart.lock 커밋 — **서비스별 버전 분리 가능**(독립 클러스터와 정합) | Application spec의 targetRevision — 서비스별 분리 가능 | git 커밋 자체가 pin |
| 로컬 검증 | ✅ `helm template`/`lint` 그대로 (K1에서 쓴 워크플로우) | ⚠️ ArgoCD 렌더 경로 재현 번거로움 | ✅ |
| upstream 추적 | `helm dependency update` + lock diff (renovate 자동화 가능) | targetRevision bump | **수동 diff/merge — 부담 최대** |
| ArgoCD 의존 | 없음 (단일 git source) | multi-source 기능 의존 (성숙했지만 UI/rollback 일부 제약 이력) | 없음 |
| 차트 커스텀 한계 돌파 | ❌ values로 안 되는 건 불가(extraObjects로 일부 보완) | ❌ 동일 | ✅ 유일하게 가능 |

## 우리 제약과의 매핑

- **`extraObjects` 존재**가 A↔C 갈림을 좁힘: 차트가 임의 리소스 주입을 지원하므로 "values로 안 되면 vendoring" 시나리오가 줄어듦. 단 extraObjects는 values 안 YAML이라 가독성·리뷰성이 떨어져, 추가 리소스가 많아지면 umbrella templates 쪽이 깔끔.
- **schema Job 내장** → A4가 "별도 구현"에서 "차트 옵션 검증"으로 축소될 수 있음 (배포 시 확인).
- B의 매력(중첩 없는 순수 values)은 실재하나, 추가 리소스가 확정적으로 존재(B3 Certificate)하는 순간 어차피 git source가 붙음 → "순수 values repo" 이점이 희석됨.

## 결정 (2026-06-11 grill-me 세션)
**서비스별 umbrella wrapper + 같은 repo 2-source** — 5단계 결정 트리(배포 단위/구현/배치/values 주입/vendor 탈출구) 전문은 [ADR-0005](../adr/0005-umbrella-wrapper-per-service.md).

## Sources
- [temporalio/helm-charts](https://github.com/temporalio/helm-charts) — Chart.yaml·values.yaml·README (2026-06-11 raw 조회)
- [ArtifactHub: temporalio/temporal](https://artifacthub.io/packages/helm/temporalio/temporal)
- [ArgoCD multi-source applications](https://argo-cd.readthedocs.io/en/stable/user-guide/multiple_sources/)
