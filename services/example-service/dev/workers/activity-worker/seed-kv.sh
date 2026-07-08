#!/usr/bin/env bash
set -euo pipefail

# activity-worker worker 앱 시크릿 시드 — Vault KV (ExternalSecret의 원천 데이터)
#
# 패턴 출처: platform/keycloak/seed-kv.sh (우리 repo 기존 ESO seed 컨벤션).
# ⚠️ ESO 방식이라 per-service Vault policy/K8s-auth-role을 만들지 않는다.
#    ESO ClusterSecretStore(vault-secret-store)의 eso-role이 secret/k8s/* 를
#    광범위하게 read 한다. 이 스크립트는 KV seed만 담당.
#
# 실행 주체: 운영자 (KV write 권한 토큰 필요 — repo의 .token(temporal-pki)으로는 불가)
# 사용:  VAULT_ADDR=https://vault.example.com VAULT_TOKEN=<운영자토큰> \
#          EXAMPLE_API_KEY=<실제외부 API키> ./seed-kv.sh [dev] [--force]
#
# - example_api_key는 외부 서비스에서 발급받은 값이라 랜덤 생성 불가 → 환경변수로 받는다.
#   미지정 시 CHANGE_ME placeholder로 경로만 만들고, 운영자가 나중에 vault kv patch로 채운다.
# - 이미 존재하는 경로는 건너뜀 — 덮어쓰기는 의도적일 때만 --force.
# - 비밀값은 화면 출력·쉘 히스토리에 남기지 않는다(환경변수 경유).

ENV="${1:-dev}"
FORCE="${2:-}"
[[ "$ENV" == "dev" ]] || { echo "usage: $0 [dev] [--force]  (현재 dev만 — prod 등록 후 확장)"; exit 1; }

: "${VAULT_ADDR:?VAULT_ADDR 필요}"
: "${VAULT_TOKEN:?VAULT_TOKEN 필요 (KV write 가능한 운영자 토큰)}"
command -v vault >/dev/null || { echo "vault CLI 필요"; exit 1; }

# activity-worker worker 시크릿 경로 (ExternalSecret vaultPath와 일치 — charts/worker externalSecret.vaultPath).
PATH_KV="secret/k8s/temporal/example-service/${ENV}/activity-worker"

# 권한 사전 확인 (KV v2 → 실제 API 경로는 secret/data/...)
CAP="$(vault token capabilities "secret/data/k8s/temporal/example-service/${ENV}/activity-worker")"
if [[ "$CAP" != *create* && "$CAP" != *update* && "$CAP" != *root* ]]; then
  echo "❌ 이 토큰엔 KV write 권한이 없습니다 (capabilities: $CAP)"
  echo "   temporal-pki 토큰이 아닌, KV 쓰기 가능한 운영자 토큰으로 실행하세요."
  exit 1
fi

# example_api_key: 운영자가 EXAMPLE_API_KEY 환경변수로 주입. 미지정이면 CHANGE_ME(경로만 생성).
GKEY="${EXAMPLE_API_KEY:-CHANGE_ME}"
if [[ "$GKEY" == "CHANGE_ME" ]]; then
  echo "⚠️  EXAMPLE_API_KEY 미지정 — placeholder(CHANGE_ME)로 경로만 생성합니다."
  echo "    이후 실제 값 주입: vault kv patch ${PATH_KV} example_api_key=<실제키>"
fi

if vault kv get "$PATH_KV" >/dev/null 2>&1 && [[ "$FORCE" != "--force" ]]; then
  echo "⏭  $PATH_KV 이미 존재 — 건너뜀 (덮어쓰기는 --force)"
else
  vault kv put "$PATH_KV" example_api_key="$GKEY" >/dev/null
  echo "✅ $PATH_KV 시드 완료"
fi

echo
echo "값 확인(필요 시): vault kv get ${PATH_KV}"
echo "ESO 동기화 확인: kubectl get externalsecret -n dev-temporal-example-service-worker"
echo "  → activity-worker-secrets 가 SecretSynced=True 면 권한·경로 정상."
echo "키 변경 후 반영: kubectl rollout restart deploy/dev-temporal-example-service-worker-activity-worker \\"
echo "                  -n dev-temporal-example-service-worker  (env는 재시작 전엔 안 바뀜)"
