# charts/ — repo 공용 차트

서비스 간 공유하는 generic 차트를 둔다. (서비스별 Temporal 서버 wrapper는 `services/<svc>/chart/` — ADR-0005)

| 차트 | 용도 | 소비자 |
|---|---|---|
| [worker/](worker/) | generic SDK worker Deployment — worker별 차이는 values로만 | `argocd/dev/applicationset-workers.yaml` (2-source) |

## worker 차트 사용법

worker 추가 = `services/<svc>/<env>/workers/<name>/values.yaml` 생성이 전부다 (AppSet이 앱 자동 생성).
템플릿: [services/_template/dev/workers/example-worker/values.yaml](../services/_template/dev/workers/example-worker/values.yaml)

- `image.tag`는 **CI가 GitOps로 갱신**하는 필드 — 앱 repo CI가 빌드 후 이 repo에 커밋.
- `TEMPORAL_ADDRESS` / `TEMPORAL_NAMESPACE` 환경변수가 컨테이너에 주입된다 (worker 코드가 읽는 계약).
- CI tag 갱신이 자동 배포로 이어지려면 worker AppSet의 `automated` sync 활성화 필요 (서버 검증 후).
