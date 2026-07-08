# <service-name> Temporal 클러스터

> 새 서비스 = 이 `_template/`를 `services/<service-name>/`으로 복사 → `<SERVICE>`/`<service-name>` 치환 → push.
> ApplicationSet이 디렉토리를 자동 인식해 앱을 만든다(서버·DB·worker별) — AppSet 수정 불필요.
> 앱 명명 체계: `{env}-temporal-{svc}-{component}` (component = server | db | worker-{name})
> 살아있는 레퍼런스: [../example-service/](../example-service/)

## 이 서비스의 설계 (작성)
- **용도/워크로드**: <이 서비스가 Temporal로 무엇을 하는지>
- **NumHistoryShards**: <생성 전 확정 — 불변> (R5)
- **스케일**: <role별 replica·resource 개략>
- **워커 위치**: <in-cluster / 외부> — 외부면 B4(approle)·C1(gRPC 노출) 트리거
- **특이사항**: <다른 서비스와 다르게 설계한 점>

## 구조 (env-first — svc 루트는 env 불변, <env>/는 그 env의 전부)
```
<service-name>/
├── README.md
├── chart/               # umbrella wrapper (ADR-0005) — upstream pin + 부속 리소스 templates/
│   ├── Chart.yaml       #   복사 후 helm dependency update → Chart.lock 커밋
│   └── templates/       #   B3 Certificate · C2 UI HTTPRoute 자리
├── values.yaml          # 서비스 공통 — 설계의 핵심 (temporal: 키 아래)
├── dev/
│   ├── values.yaml      # dev 차이만
│   ├── db/              # dev DB 앱 (cnpg Cluster + Database CR + externalsecrets.yaml)
│   └── workers/         # SDK worker 앱들 — worker 1개 = 디렉토리 1개 (charts/worker 공용 차트 + values만)
│       └── <worker>/values.yaml   # image.tag는 CI가 GitOps로 갱신
└── prod/
    ├── values.yaml      # prod 차이만
    └── db/              # prod 승격 시
```

## 체크리스트 (복사 후)
- [ ] Vault KV 시드: `k8s/temporal/<service-name>/<env>/db` (username=temporal)
- [ ] `chart/Chart.yaml` 치환 + `helm dependency update` (Chart.lock 커밋, tgz는 gitignore)
- [ ] 로컬 렌더 검증: `helm template <svc> chart/ -f ../../base/values-common.yaml -f values.yaml -f dev/values.yaml`
- [ ] ⚠️ ExternalSecret 파일명은 `externalsecrets.yaml`(복수형) — `.gitignore` `*secret*.yaml` 예외가 복수형만 허용
