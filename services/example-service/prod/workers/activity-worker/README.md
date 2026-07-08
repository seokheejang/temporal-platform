# activity-worker worker (dev) — 앱 시크릿 운영

Python 추론 activity worker. 앱 시크릿을 **ESO**(Vault KV → K8s Secret → `envFrom`)로 받는다.
시크릿 전달 방식 결정 근거: 앱이 시크릿을 평문 env로 기대(앱이 `os.environ`에서
`EXAMPLE_API_KEY` 자동 read)하고 코드에 Vault fetch 로직이 없어 ESO가 적합 (Vault Agent는 부적합).

| 항목 | 값 |
|---|---|
| Vault KV 경로 | `secret/k8s/temporal/example-service/dev/activity-worker` |
| ESO ClusterSecretStore | `vault-secret-store` (kubernetes auth `eso-role`, vault, KV v2) |
| 생성 Secret | `activity-worker-secrets` (worker ns에 생성) |
| worker k8s ns | `dev-temporal-example-service-worker` |
| 현재 키 | `example_api_key` 하나 (개발자 협의 후 `EXTRA_*` 등 확장) |

배선: [values.yaml](values.yaml) `externalSecret`/`envFrom`, 템플릿 [charts/worker/templates/externalsecret.yaml](../../../../../charts/worker/templates/externalsecret.yaml).

## 시크릿 시드 (운영자, 배포 전 선행)

> ⚠️ KV **쓰기** 권한 토큰 필요 — repo의 `temporal-pki` 토큰으로는 불가.
> 키는 인자 아닌 **환경변수**로 받는다(쉘 히스토리·화면에 비밀 미유출). `vault kv put`을 직접 칠
> 필요 없이 스크립트가 권한 체크·중복 방지·후속 안내까지 한다.

```bash
cd services/example-service/dev/workers/activity-worker/

# 실제 외부 API 키로 시드
VAULT_ADDR=https://vault.example.com \
VAULT_TOKEN=<운영자_KV_write_토큰> \
EXAMPLE_API_KEY=<실제_외부 API_키> \
  ./seed-kv.sh dev

# (또는) 경로만 먼저 만들고 값은 나중에:
VAULT_ADDR=... VAULT_TOKEN=... ./seed-kv.sh dev        # example_api_key=CHANGE_ME
vault kv patch secret/k8s/temporal/example-service/dev/activity-worker example_api_key=<키>
```

이미 존재하면 건너뜀 — 덮어쓰기는 `./seed-kv.sh dev --force`.

## 동기화·반영 확인

```bash
# ESO 동기화 (경로·권한 정상이면 SecretSynced=True)
kubectl get externalsecret -n dev-temporal-example-service-worker

# 키 변경 후 반영 — env는 파드 재시작 전엔 안 바뀜 (Reloader 자동화는 향후)
kubectl rollout restart deploy/dev-temporal-example-service-worker-activity-worker \
  -n dev-temporal-example-service-worker
```

> dev 실측: `eso-role`이 `k8s/temporal/.../db`를 이미 동기화 중 → 형제 경로 `activity-worker`도
> 추가 권한 없이 읽힐 가능성 높음. `SecretSynced=False`면 `eso-role` 정책에 경로 read 추가 필요.
