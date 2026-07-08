# 0005. Chart 전략 — 서비스별 umbrella wrapper + 같은 repo 2-source

- Status: Accepted
- Date: 2026-06-11 (grill-me 결정 세션)

## Context
upstream `temporalio/temporal` 차트(실측: chart 1.2.0/server 1.31.0, **subchart 번들 없음**·BYO-DB·schema Job 내장·ESO 패턴 문서화 — [R1 리서치](../research/chart-strategy.md))를 어떻게 소비할지가 `argocd/` 구조·values 스키마·`charts/` 사용 여부를 막고 있었다. 추가 제약: 서비스마다 부속 리소스(mTLS Certificate·UI HTTPRoute·dynamicconfig CM)가 확정적으로 존재하고, 서버 업그레이드는 마이너 건너뛰기 금지라 서비스별 단계 적용이 필요하다.

## Decision
결정 트리 5단계로 확정:

1. **배포 단위**: 서비스 = ArgoCD Application **1개** (서버+Certificate+HTTPRoute+dynamicconfig, sync wave로 순서 제어). **cnpg DB는 별도 Application** — 서버 롤백/prune이 DB를 건드리지 않게 생명주기 분리.
2. **구현**: **umbrella wrapper chart** — 공식 차트를 dependency로 pin, 부속 리소스는 wrapper `templates/`에 동거. 로컬 `helm template`/lint 검증 루프(K1에서 검증된 워크플로우) 유지.
3. **wrapper 배치**: **서비스별** `services/<svc>/chart/` — Chart.yaml 단위 버전 pin이므로 서비스별 카나리 업그레이드 가능(독립 클러스터 ADR-0003 정합). 스캐폴딩은 `services/_template/`.
4. **3-layer values 주입**: **같은 repo 2-source** — source① chart 경로, source② `ref: values` → `$values/base/...`, `$values/services/<svc>/...`, `$values/services/<svc>/<env>/...`. 근거: ArgoCD는 chart 디렉토리 밖 valueFiles를 차단(path traversal 보호)하므로 ADR-0004의 3-layer 배치를 보존하는 유일한 경로. 같은 repo 참조라 multi-source의 구성 분산 단점은 해당 없음. wrapper 사용으로 모든 층의 값은 `temporal:` 키 아래 중첩 — 전 층 일관 규칙.
5. **vendor 탈출구**: 기본은 values+`extraObjects`. 안 풀리는 커스텀이 나오면 **그 서비스 wrapper만** dependency를 떼고 차트를 복사(부분 vendor) — 서비스별 wrapper 구조의 보너스로 나머지 서비스는 무영향.

## Consequences
- `charts/` 최상위 디렉토리는 공유 wrapper 용도로는 불사용(서비스별 `services/<svc>/chart/`로) — 스캐폴드 정리 필요.
- values 스키마: 3-layer 모든 파일에서 Temporal 서버 값은 `temporal:` 키 아래 (wrapper 자체 값과 구분).
- Chart.lock 커밋, `charts/**/charts/`(tgz)는 .gitignore 유지 — ArgoCD repo-server가 렌더 시 dependency를 resolve.
- **검증 필요(A6 구현 시)**: ArgoCD repo-server의 `go.temporal.io/helm-charts` 아웃바운드 접근 + dependency 자동 build 동작.
- ADR-0004의 "merge 메커니즘은 R1 이후 결정" 항목이 본 ADR로 해소됨.
