#!/usr/bin/env bash
set -euo pipefail

# Temporal 알람 Slack webhook Secret 생성 — 운영자가 로컬에서 직접(ESO/Vault 미사용).
#
# AlertmanagerConfig(alertmanagerconfig.yaml)가 apiURL로 참조하는 Secret을 만든다.
# ⚠️ webhook URL은 시크릿 — git·매니페스트에 평문 금지. 인자(환경변수) 경유로만.
#
# 이 Secret은 GitOps(ArgoCD) 밖에서 운영자가 직접 만든다 — webhook이 git에 안 들어가게.
# (rule·alertmanagerconfig는 ArgoCD sync, 이 Secret만 수동. 설계: docs/alerting-design.md)
#
# 사용:  SLACK_WEBHOOK_URL=<webhook> ./create-webhook-secret.sh dev [--apply]
#   기본은 dry-run(명령만 출력) — 검토 후 --apply 또는 출력된 명령을 직접 실행.

ENV="${1:-dev}"
APPLY="${2:-}"
[[ "$ENV" == "dev" ]] || { echo "usage: SLACK_WEBHOOK_URL=<url> $0 [dev] [--apply]  (현재 dev만)"; exit 1; }

: "${SLACK_WEBHOOK_URL:?SLACK_WEBHOOK_URL 필요 (예: https://hooks.slack.com/services/...)}"
[[ "$SLACK_WEBHOOK_URL" == https://hooks.slack.com/* ]] || {
  echo "❌ SLACK_WEBHOOK_URL 형식 오류 — https://hooks.slack.com/... 이어야 합니다."; exit 1; }
command -v kubectl >/dev/null || { echo "kubectl 필요"; exit 1; }

# AlertmanagerConfig 참조값과 일치해야 함 (alertmanagerconfig.yaml apiURL.name/key, metadata.namespace)
NS="${ENV}-temporal-example-service"
SECRET="temporal-example-service-alert-slack"
KEY="url"
KUBECONFIG_PATH="${KUBECONFIG:-~/.kube/dev-cluster}"

echo "═══════════════════════════════════════════════════════════════"
echo "  알람 webhook Secret 생성"
echo "  KUBECONFIG: ${KUBECONFIG_PATH}"
echo "  ns:        ${NS}"
echo "  secret:    ${SECRET}  (key: ${KEY})"
echo "  webhook:   ${SLACK_WEBHOOK_URL:0:30}…(이하 생략)"
echo "═══════════════════════════════════════════════════════════════"

# create는 이미 있으면 실패 → apply로 idempotent하게(--dry-run=client -o yaml | apply -f -).
# 출력 yaml에 평문 webhook이 stdout에만 흐르고 파일로 안 남게 파이프.
GEN_CMD=(kubectl create secret generic "$SECRET" -n "$NS"
         --from-literal="${KEY}=${SLACK_WEBHOOK_URL}"
         --dry-run=client -o yaml)

if [[ "$APPLY" == "--apply" ]]; then
  read -p "위 설정으로 Secret을 apply 하시겠습니까? (yes/no): " c
  [[ "$c" == "yes" ]] || { echo "취소됨."; exit 0; }
  "${GEN_CMD[@]}" | kubectl apply -n "$NS" -f -
  echo "✅ ${NS}/${SECRET} 생성/갱신 완료"
else
  echo
  echo "[dry-run] 아래 명령을 검토 후 실행하세요 (또는 --apply 재실행):"
  echo
  echo "  KUBECONFIG=${KUBECONFIG_PATH} kubectl create secret generic ${SECRET} -n ${NS} \\"
  echo "    --from-literal=${KEY}='<webhook>' \\"
  echo "    --dry-run=client -o yaml | KUBECONFIG=${KUBECONFIG_PATH} kubectl apply -f -"
  echo
  echo "  ⚠️ <webhook>에 실제 URL — 쉘 히스토리 주의(앞에 공백 두면 histignore)."
fi

echo
echo "확인(값 미출력): kubectl get secret ${SECRET} -n ${NS} -o jsonpath='{.data.${KEY}}' | head -c 20; echo …"
echo "AlertmanagerConfig가 이 Secret을 참조 — sync 후 알람 발화 시 전용 채널로 전송."
