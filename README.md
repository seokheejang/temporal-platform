# temporal-platform

> Self-hosted Temporal on Kubernetes, managed via Helm + ArgoCD (GitOps).

Kubernetes에 **Temporal**을 Helm + ArgoCD(GitOps)로 배포하기 위한 재사용 가능한 인프라 부트스트랩.
서비스마다 **독립적인 Temporal 클러스터**를 선언적으로 관리한다 (서비스별 설계, 각 서비스 안에 dev/prod).

이 repo는 특정 조직에 종속되지 않도록 **중성화된 템플릿**이다. 실제 배포에 쓰려면 `example`,
`example.com`, `registry.example.com`, `192.0.2.x` 같은 placeholder를 사용 환경 값으로 바꾼다.
전제하는 플랫폼 스택은 [docs/platform-assumptions.md](docs/platform-assumptions.md)를 먼저 확인할 것.

## 구조

```
.
├── docs/        # 문서: 용어집(glossary), 결정 이력(adr), 리서치(research), 운영 절차(runbooks)
├── base/        # 조직 공통 기본값 (얇게 유지, 정말 전역적인 것만)
├── argocd/      # ArgoCD Application/ApplicationSet/AppProject (dev/prod)
├── charts/      # 공용 Helm 차트 (worker)
├── platform/    # 플랫폼 구성요소 (keycloak, monitoring)
└── services/    # 서비스별 Temporal 클러스터 (서비스 x 환경)
    ├── _template/       # 새 서비스 스캐폴드
    └── example-service/ # 중성화된 작동 예제 (server / db / worker / mTLS / alerts)
```

values는 3-layer로 합성된다: `base/` -> `services/<svc>/` -> `services/<svc>/<env>/`.

## 새 서비스 추가

1. `services/_template/`를 `services/<service-name>/`으로 복사한다.
2. 서비스 README와 `values.yaml`(서비스 공통), `dev|prod/values.yaml`(환경 차이)를 채운다.
3. `argocd/`에 해당 서비스를 등록한다 (ApplicationSet이 디렉토리를 자동 인식).

작동하는 예시는 `services/example-service/`를 참고한다.

## worker

SDK worker 코드/이미지는 이 repo 밖(앱)에서 관리하고, 이 repo는 **배포(CD)만** 담당한다.
공용 차트 `charts/worker`가 worker 1개를 배포하며, 서비스별 값은
`services/<svc>/<env>/workers/<name>/values.yaml`에 둔다. 예제는 범용 worker 2종
(`orchestration-worker`, `activity-worker`)을 보여준다. image.repository는 placeholder이므로
사용 환경의 레지스트리/이미지로 교체한다.

## 문서

| 문서 | 내용 |
|------|------|
| [docs/architecture/index.html](docs/architecture/index.html) | **아키텍처 그림** (전체 토폴로지 / 필수 개념) |
| [docs/platform-assumptions.md](docs/platform-assumptions.md) | **이 repo가 전제하는 플랫폼 스택** (먼저 읽기) |
| [services/example-service/README.md](services/example-service/README.md) | 작동 예제 서비스: 엔드포인트 / 확정값 / mTLS |
| [docs/glossary.md](docs/glossary.md) | 용어집 (Temporal / k8s / auth) |
| [docs/adr/](docs/adr/) | 아키텍처 결정 이력 (ADR) |
| [docs/research/](docs/research/) | 리서치 (아키텍처 / persistence / sizing / topology / Vault PKI) |
| [docs/runbooks/](docs/runbooks/) | 운영 절차 (mTLS 적용 / namespace 등록 / Vault PKI 세팅) |
| [docs/STATUS.md](docs/STATUS.md) | 배포 진행상황 추적 템플릿 |

> 아키텍처는 핵심 문서만 간략히 담았다(`docs/architecture/`). 상세 다이어그램(인증 흐름·CI/CD·실측 토폴로지 등)은 필요 시 추가.

## 라이선스

MIT ([LICENSE](LICENSE)).
