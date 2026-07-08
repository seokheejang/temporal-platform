# 진행상황 (STATUS)

배포 진행 단계와 결정 현황을 추적하는 문서. (README는 정체성/가이드, 이 문서는 상태 추적, 역할 분리)
새 환경에 이 repo를 적용할 때 이 템플릿을 채워 나간다.

> 마커: `[x]` 완료 / `[~]` 진행·보류 / `[ ]` 미착수

## 현재 단계

```
① 리서치  ->  ② 아키텍처 설계  ->  ③ 배포  ->  ④ 검증·안정화  ->  ⑤ 운영
```

## 체크리스트

### ① 리서치 / 설계
- [ ] Temporal 아키텍처·사이징·persistence 검토 ([docs/research/](research/))
- [ ] `NumHistoryShards` 확정 (생성 후 변경 불가)
- [ ] 클라우드/플랫폼 확인, managed DB 대안 검토
- [ ] Temporal 서버 / Helm 차트 버전 선정
- [ ] 시크릿·인증서 관리 방식 확정 ([platform-assumptions.md](platform-assumptions.md))

### ② 배포
- [ ] cnpg(또는 managed) PostgreSQL + DB 2개 (main / visibility)
- [ ] cert-manager + ClusterIssuer (mTLS 쓸 경우)
- [ ] schema setup Job (DB 스키마 생성)
- [ ] Temporal 서버 배포 (ArgoCD)
- [ ] Web UI 배포 + 외부 노출
- [ ] worker 배포

### ③ 검증·안정화
- [ ] 스모크: namespace 등록 -> 워크플로우 실행 -> UI 확인 ([runbooks/temporal-namespace-register.md](runbooks/temporal-namespace-register.md))
- [ ] mTLS: cert 없는 접속 거부 / cert 있으면 통과 ([runbooks/temporal-mtls-enable.md](runbooks/temporal-mtls-enable.md))
- [ ] 관측성: 메트릭 수집 / 대시보드 / 알람
- [ ] HA·부하: pod drain / DB failover / SLO
- [ ] 백업/DR: PITR 리허설, 업그레이드·스키마 마이그레이션

## 확정된 결정 (ADR)

주요 아키텍처 결정은 [docs/adr/](adr/) 참고.
