#!/usr/bin/env bash
set -euo pipefail

# Keycloak 시크릿 시드 — Vault KV (externalsecrets.yaml의 원천 데이터)
#
# 실행 주체: 운영자 (KV write 권한 토큰 필요 — repo의 .token(temporal-pki)으로는 불가)
# 사용:  VAULT_ADDR=https://vault.example.com VAULT_TOKEN=<운영자토큰> ./seed-kv.sh [dev|prod] [--force]
#
# - 비밀번호는 여기서 랜덤 생성 (쉘 히스토리에 평문 안 남김 · 화면 출력 안 함)
# - 이미 존재하는 경로는 건너뜀 — 운영 중 비번 교체는 DB/KC 양쪽 재설정이 필요한 작업이라
#   의도적일 때만 --force 로

ENV="${1:-dev}"
FORCE="${2:-}"
[[ "$ENV" == "dev" || "$ENV" == "prod" ]] || { echo "usage: $0 [dev|prod] [--force]"; exit 1; }

: "${VAULT_ADDR:?VAULT_ADDR 필요}"
: "${VAULT_TOKEN:?VAULT_TOKEN 필요 (KV write 가능한 운영자 토큰)}"
command -v vault >/dev/null || { echo "vault CLI 필요"; exit 1; }

BASE="secret/k8s/keycloak/${ENV}"

# 권한 사전 확인 (KV v2 → 실제 API 경로는 secret/data/...)
CAP="$(vault token capabilities "secret/data/k8s/keycloak/${ENV}/db")"
if [[ "$CAP" != *create* && "$CAP" != *update* && "$CAP" != *root* ]]; then
  echo "❌ 이 토큰엔 KV write 권한이 없습니다 (capabilities: $CAP)"
  echo "   temporal-pki 토큰이 아닌, KV 쓰기 가능한 운영자 토큰으로 실행하세요."
  exit 1
fi

gen() { openssl rand -base64 33 | tr -d '/+=' | head -c 32; }

seed() {
  local path="$1"; shift
  if vault kv get "$path" >/dev/null 2>&1 && [[ "$FORCE" != "--force" ]]; then
    echo "⏭  $path 이미 존재 — 건너뜀 (덮어쓰기는 --force)"
    return
  fi
  vault kv put "$path" "$@" >/dev/null
  echo "✅ $path 시드 완료"
}

seed "$BASE/db"    username=keycloak password="$(gen)"
seed "$BASE/admin" username=admin    password="$(gen)"

echo
echo "비밀번호 조회(필요 시): vault kv get ${BASE}/admin"
echo "다음 단계: kubectl apply -f platform/keycloak/namespace.yaml -f platform/keycloak/externalsecrets.yaml"
echo "          → kubectl get externalsecret -n keycloak (SecretSynced 확인)"
