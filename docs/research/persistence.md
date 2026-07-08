# R2–R4. Persistence / Visibility / DB 호스팅

Temporal은 **main store**(워크플로우 상태·이벤트·Task)와 **visibility store**(검색/조회) 두 영속 계층이 필요. 서비스별 독립 클러스터라 서비스마다 다른 선택 가능.

> 상태: 리서치 반영됨. 아래 **추천**은 사용자 확정 시 ADR로 승격(R2/R3/R4 → ADR). 사이징/HA는 [sizing-scaling-ha.md](sizing-scaling-ha.md).

---

## 핵심 사실 (결정에 영향)
- **Cassandra는 visibility store로 못 쓴다.** advanced visibility 미지원 → main을 C*로 하면 visibility는 **무조건 SQL이나 ES 별도** 필요.
- **v1.20+부터 advanced visibility가 SQL(PostgreSQL 12+, MySQL 8.0.17+, SQLite)** 에서 동작. 즉 **Postgres 하나로 main + visibility 둘 다 가능**.
- 공식 Helm 차트는 **BYO-DB**: 서버 컴포넌트만 배포하고 **DB는 외부에서 제공**(차트가 DB 서브차트를 설치하지 않음). → 누가/어떻게 프로비저닝하든 **Temporal은 Postgres 엔드포인트만 알면 됨**.

---

## R2. Main store
| 옵션 | 메모 |
|------|------|
| **PostgreSQL** ✅추천 | 관리형/operator 친화, 중소 규모 무난, **visibility까지 겸용 가능**. 사내 **cnpg** 운영 중이라 자연스러움 |
| Cassandra | 초대형 쓰기 처리량용. 운영 난이도↑, **visibility 불가**(별도 SQL/ES 필요) → 우리 규모엔 과함 |
| MySQL | PG와 유사, 조직 표준이 MySQL일 때만 |

지원 버전: PostgreSQL 13.x~16.x (advanced visibility는 12+). 드라이버 `postgres12_pgx`.

## R3. Visibility store — **"Postgres로 됩니다"**
| 옵션 | 메모 |
|------|------|
| **PostgreSQL advanced visibility** ✅추천(시작) | v1.20+ 지원. main과 같은 Postgres(cnpg)에 **별도 DB**(`temporal_visibility`)로. ES 운영 부담 없음. custom Search Attribute는 namespace에 등록 필요 |
| Elasticsearch / OpenSearch | **[공식 권장]** 워크플로우가 많거나 visibility 쿼리 부하가 크면. 검색 성능·대규모에 유리하나 별도 스택 운영 비용 |

**추천**: **시작은 Postgres(cnpg) advanced visibility로 main+visibility 통합** → 단일 DB 기술, ES 불필요로 운영 단순. 특정 서비스가 **visibility 쿼리 부하/대량 List·검색**을 입증하면 그 서비스만 ES/OpenSearch로 승격(서비스별 독립이라 개별 선택 가능).

## R4. DB 호스팅 — **cnpg(CloudNativePG) 사용**
- **Temporal이 강제하는 "전용 DB operator"는 없다.** 차트가 BYO-DB라 **cnpg로 프로비저닝한 in-cluster Postgres가 1급 선택지**. (차트 번들 DB는 데모용)
- 연결 방법(차트 values 개략):
  - `server.config.persistence.datastores.default` (+ `.visibility`)에 `pluginName/driverName: postgres12_pgx`, `connectAddr: <cnpg-rw-service>:5432`
  - 자격증명은 **cnpg가 생성한 Secret**을 `existingSecret`로 주입(하드코딩 금지)
  - 스키마: `manageSchema: true`로 차트가 setup/upgrade Job 실행, **또는** admin-tools Job으로 직접

### 한 PG에 두 DB로? ✅ 가능 (권장 시작 형태)
- **필요 DB 2개**: `temporal`(main) + `temporal_visibility`. **하나의 cnpg Postgres 인스턴스 안에 두 database로 분리**해도 전혀 문제없다 — Temporal datastore 설정의 `default`/`visibility`가 같은 `connectAddr`에 `databaseName`만 다르게 가리키면 됨.
- 트레이드오프: 같은 PG 자원·커넥션 예산을 공유 → visibility 검색 부하가 커지면 그 서비스만 나중에 visibility를 별도 PG/ES로 분리. **시작은 한 PG·두 DB로 단순하게.**

### ⚠️ 두 DB는 워크로드가 다르다 — 자원은 "합산"으로 사이징·관리
한 PG에 합치면 둘이 같은 CPU·IOPS·메모리(shared_buffers)·커넥션을 **경쟁**한다. 그래서 인스턴스는 **두 워크로드의 합**으로 잡고, 각 DB를 **따로** 본다.

| | `temporal` (main) | `temporal_visibility` |
|---|---|---|
| 성격 | **쓰기 중심·트랜잭션·핫패스** (모든 state transition이 events+tasks를 한 트랜잭션으로 write) | 상태 변화마다 레코드 upsert(write) **+ UI/CLI List·검색의 read·인덱스 부하** |
| 민감 자원 | write IOPS, 커넥션, write latency | 검색 쿼리 CPU, 인덱스, read — **무겁고 spiky** 가능 |

- **커넥션**: Temporal은 `default`/`visibility` datastore에 **독립 커넥션 풀**(`sqlMaxConns`)을 둠 → `max_connections`는 **두 풀 합 × pods** 기준으로 산정(또는 Pooler).
- **디스크**: 두 DB 모두 증가(main = 열린 워크플로우 + retention, visibility = 레코드 + 인덱스) → **합산 + 헤드룸 + 사용량 알람**.
- **사이징 비율은 상상하지 말 것** → per-DB로 CPU·IOPS·커넥션·슬로우쿼리·테이블/인덱스 크기를 **측정**해서 잡는다 (Omes/pg stats). [근거 없는 수치 금지 원칙](README.md#-원칙-필독--근거-없는-수치-금지).
- **분리 트리거(모니터링)**: visibility 검색 부하가 **main write latency(핫패스)**를 압박하면 → visibility를 별도 PG 또는 ES로 분리.

### cnpg 운영 메모 (자원 제약 환경)
- **인스턴스 수**: `instances: 2` (**1 primary + 1 standby**) = 사용자 환경 선택. failover 확보됨. cnpg는 prod 3을 권장하지만 2도 흔한 절충.
  - 복제는 **async 스트리밍(기본) 유지 권장** — standby 1대뿐이라 synchronous로 묶으면 standby 다운 시 쓰기가 막힘. async면 가용성↑(아주 작은 RPO 감수).
- **WAL은 cnpg가 자동 관리** → 동작에 추가 설정 불필요. 단 prod 권장:
  - **`max_connections` 상향**: Temporal은 서비스×pod×풀(default+visibility)로 커넥션을 많이 연다. PG 기본 100은 부족할 수 있음 → `postgresql.parameters.max_connections` 상향, 또는 **cnpg Pooler(PgBouncer)** 도입.
  - **WAL 아카이빙/백업**: `backup.barmanObjectStore`(S3 등)로 base backup + WAL 아카이브 → PITR. 기록 시스템이라 강권장.
  - (선택) **`walStorage` 분리 볼륨**: write-heavy라 WAL IOPS를 데이터와 분리하면 유리.
- AZ 분산 권장 → [sizing-scaling-ha.md](sizing-scaling-ha.md) Q3.

---

## 조사 항목 (남은 TODO)
- [ ] 클라우드/플랫폼(EKS?) 확정 — managed(RDS/Aurora) 대안 검토 여부
- [ ] 서비스별 규모/SLA → store 매핑(어느 서비스가 ES 필요할지)
- [ ] 비용 추정 (독립 클러스터 N개 × cnpg)

## 결정
- R2: **PostgreSQL(cnpg)** _(추천, 확정 시 ADR)_
- R3: **Postgres advanced visibility로 시작, 필요 서비스만 ES** _(추천)_
- R4: **cnpg in-cluster** _(추천)_

## Sources
- [Persistence | docs.temporal.io](https://docs.temporal.io/temporal-service/persistence)
- [Self-hosted Visibility setup | docs.temporal.io](https://docs.temporal.io/self-hosted-guide/visibility)
- [Temporal helm-charts (BYO DB) | github.com/temporalio/helm-charts](https://github.com/temporalio/helm-charts)
- [CloudNativePG](https://cloudnative-pg.io/)
