# 리서치 (① 단계)

아키텍처를 설계하기 전, Temporal 운영에 필요한 선택지들을 조사해 여기에 기록한다.
조사 결과로 결정이 확정되면 [../adr/](../adr/)에 ADR로 승격한다.

## ⛔ 원칙 (필독) — 근거 없는 수치 금지

> **성능 수치 · 인프라 자원(CPU/메모리/디스크) · 벤치마크가 필요한 정보는 반드시 근거 있는 자료(공식 문서 / 공식 벤치마크 / 1차 출처)를 바탕으로 제시하고 설계한다. 절대 상상·추정으로 수치를 만들지 않는다.**
>
> - 모든 수치에는 **출처 링크**를 붙인다 (각 문서 하단 Sources).
> - 출처가 없거나 우리 워크로드에 맞는 값을 모르면 → **"미확인 / 직접 측정 필요(Omes 등)"** 라고 명시하고, 임의 숫자를 적지 않는다.
> - "시작점 예시"도 출처가 있을 때만 그렇게 표기하고, 없으면 적지 않는다.

## 기초 (먼저 읽기)

| # | 주제 | 문서 | 상태 |
|---|------|------|------|
| R0 | Temporal 아키텍처 기초 (흐름·4서비스·persistence·샤딩, infra 관점) | [temporal-architecture.md](temporal-architecture.md) | ✅ 정리됨 |
| R5 | 운영 사이징 · 스케일 기준 · HA 최소 replica | [sizing-scaling-ha.md](sizing-scaling-ha.md) | ✅ 정리됨 |

## 열린 결정 (리서치하며 확정)

| # | 주제 | 문서 | 상태 |
|---|------|------|------|
| R1 | Chart 전략: umbrella(dependency) vs ArgoCD multi-source vs vendoring | [chart-strategy.md](chart-strategy.md) | 🔴 미정 |
| R2 | Main store: **PostgreSQL(cnpg)** | [persistence.md](persistence.md) | 🟡 추천 도출 |
| R3 | Visibility: **Postgres로 시작, 필요 서비스만 ES** | [persistence.md](persistence.md) | 🟡 추천 도출 |
| R4 | DB 호스팅: **cnpg in-cluster** | [persistence.md](persistence.md) | 🟡 추천 도출 |

## 확정된 전제 (배경)

서비스별 독립 클러스터 토폴로지는 [topology.md](topology.md)에 근거 정리. 결정 이력은 [../adr/0003-per-service-independent-clusters.md](../adr/0003-per-service-independent-clusters.md).
