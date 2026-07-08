#!/usr/bin/env bash
set -euo pipefail

# Temporal namespace 등록 — 서버(admintools)에 서비스용 namespace를 생성/확인한다.
#
# 절차 출처: docs/runbooks/temporal-namespace-register.md (이 스크립트는 그 절차의 자동화).
# 패턴: services/.../seed-kv.sh 와 동일(인자·사전체크·idempotent·확인 출력).
#
# ⚠️ 이것은 Temporal "애플리케이션" 명령(operator namespace create)이지 k8s 리소스 변경이 아니다.
#    단 namespace 생성은 서버 상태를 바꾸는 작업이라 **운영자가 직접 실행**한다(런북 원칙).
# ⚠️ worker values의 temporal.namespace 와 --namespace 가 반드시 일치해야 worker가 붙는다
#    (미등록/불일치 시 NamespaceNotFound).
#
# 사용:
#   ./register-namespace.sh --svc example-service --env dev \
#       --namespace example-service-dev [--retention 7d] [--description "..."] [--dry-run]
#
# 사전조건: kubectl 컨텍스트가 대상 클러스터(dev=dev-cluster)를 가리켜야 함(KUBECONFIG).

usage() {
  cat <<EOF
Usage: $0 --svc <service> --env <dev|prod> --namespace <TEMPORAL_NS> [options]

Required:
  --svc          서비스명 (예: example-service) — k8s ns {env}-temporal-{svc} 유도용
  --env          dev | prod
  --namespace    등록할 Temporal namespace (worker values temporal.namespace와 일치)

Optional:
  --retention    Event History 보존기간 (default: dev=7d / prod=30d). 서버 최소 1d.
  --description  용도 메모 (default: "{svc} worker/activity 워크로드용 ({env})")
  --dry-run      실행 명령만 출력하고 멈춤 (변경 없음)

Example:
  $0 --svc example-service --env dev --namespace example-service-dev
EOF
  exit 1
}

SVC="" ; ENV="" ; TEMPORAL_NS="" ; RETENTION="" ; DESCRIPTION="" ; DRYRUN=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --svc)         SVC="$2"; shift 2 ;;
    --env)         ENV="$2"; shift 2 ;;
    --namespace)   TEMPORAL_NS="$2"; shift 2 ;;
    --retention)   RETENTION="$2"; shift 2 ;;
    --description) DESCRIPTION="$2"; shift 2 ;;
    --dry-run)     DRYRUN="1"; shift ;;
    -h|--help)     usage ;;
    *) echo "Unknown arg: $1" >&2; usage ;;
  esac
done

[[ -z "$SVC" || -z "$ENV" || -z "$TEMPORAL_NS" ]] && usage
case "$ENV" in dev|prod) ;; *) echo "ERROR: --env must be dev or prod" >&2; exit 1 ;; esac
command -v kubectl >/dev/null || { echo "kubectl 필요"; exit 1; }

# derived — 조직 컨벤션 {env}-temporal-{svc} (server·db·admintools가 사는 k8s ns)
KNS="${ENV}-temporal-${SVC}"
ADDR="${KNS}-server-frontend:7233"
RETENTION="${RETENTION:-$([[ "$ENV" == "prod" ]] && echo 30d || echo 7d)}"
DESCRIPTION="${DESCRIPTION:-${SVC} worker/activity 워크로드용 (${ENV})}"

# admintools 파드 (pod 이름은 재배포 시 바뀌므로 매번 조회)
POD="$(kubectl -n "$KNS" get pods -o name 2>/dev/null | grep admintools | head -1 || true)"
[[ -n "$POD" ]] || { echo "ERROR: admintools 파드를 못 찾음 (k8s ns: $KNS). 컨텍스트/서버 배포 확인."; exit 1; }

cat <<EOF
══════════════════════════════════════════════════════════════════════════════
  Temporal namespace 등록
══════════════════════════════════════════════════════════════════════════════
  서비스/환경:    ${SVC} / ${ENV}
  k8s ns:        ${KNS}
  admintools:    ${POD}
  frontend ADDR: ${ADDR}
  Temporal NS:   ${TEMPORAL_NS}
  retention:     ${RETENTION}
  description:   ${DESCRIPTION}
══════════════════════════════════════════════════════════════════════════════
EOF

# 1) 이미 등록돼 있나? (idempotent — 있으면 describe만, create 안 함)
if kubectl -n "$KNS" exec "$POD" -- \
     temporal operator namespace describe --address "$ADDR" --namespace "$TEMPORAL_NS" >/dev/null 2>&1; then
  echo "⏭  '${TEMPORAL_NS}' 이미 등록됨 — describe만 출력 (변경은 'temporal operator namespace update')."
  kubectl -n "$KNS" exec "$POD" -- \
    temporal operator namespace describe --address "$ADDR" --namespace "$TEMPORAL_NS" 2>&1 | \
    grep -iE "Name|State|Retention|Description" | head
  exit 0
fi

# 2) 생성 (★ 변경 작업)
CREATE_CMD=(temporal operator namespace create --address "$ADDR" --namespace "$TEMPORAL_NS" --retention "$RETENTION" --description "$DESCRIPTION")
if [[ -n "$DRYRUN" ]]; then
  echo "[dry-run] kubectl -n $KNS exec $POD -- ${CREATE_CMD[*]}"
  exit 0
fi

read -p "위 설정으로 namespace를 생성하시겠습니까? (yes/no): " confirm
[[ "$confirm" == "yes" ]] || { echo "취소됨."; exit 0; }

kubectl -n "$KNS" exec "$POD" -- "${CREATE_CMD[@]}"
echo "✅ '${TEMPORAL_NS}' 생성 요청 완료."

# 3) 확인
echo "--- describe (State=Registered·retention 확인) ---"
kubectl -n "$KNS" exec "$POD" -- \
  temporal operator namespace describe --address "$ADDR" --namespace "$TEMPORAL_NS" 2>&1 | \
  grep -iE "Name|State|Retention|Description" | head
echo
echo "다음: worker values temporal.namespace=${TEMPORAL_NS} 와 일치 확인 → ArgoCD sync → worker pod Running."
