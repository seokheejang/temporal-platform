# Temporal 알람 (dev) — PrometheusRule → 전용 Slack 채널

Temporal 서버·worker·DB 장애를 **이 repo 전용 Slack 채널**로 알린다. observability 공통 채널과 별개.
설계·검토 결론: [docs/alerting-design.md](../../../../docs/alerting-design.md).

**룰·라우팅은 서버 wrapper 차트에 통합**(별도 ArgoCD 앱 안 만듦 — 앱 수 최소화). 서버 앱이 같이 sync한다:
- [chart/templates/alerts-rules.yaml](../../chart/templates/alerts-rules.yaml) — PrometheusRule(가용성 `up==0` 3개). `service: temporal-example-service` 라벨이 라우팅 키.
- [chart/templates/alerts-config.yaml](../../chart/templates/alerts-config.yaml) — AlertmanagerConfig(`service` matcher → 전용 채널 + Slack 템플릿).
- 토글: `alerts.enabled`(차트 values), dev는 [../values.yaml](../values.yaml)에서 on.

이 디렉토리엔 **운영자 도구만** 둔다:

| 파일 | 역할 |
|---|---|
| [create-webhook-secret.sh](create-webhook-secret.sh) | webhook Secret을 운영자가 **로컬에서 직접** 생성(ESO/Vault 미사용, GitOps 밖 — webhook 평문 git 미유출) |

**webhook Secret만 GitOps 밖**(운영자 수동). 서버 차트 ns(`dev-temporal-example-service`)에 생성 — Operator가 AlertmanagerConfig 참조 Secret을 같은 ns에서 읽기 때문(차트가 그 ns에 배포되므로 자동 일치).

## 동작 체인

```
PrometheusRule (up==0, labels: service=temporal-example-service, severity)
   ↓ Prometheus가 채택 (ruleSelector managed-by=observability)
alert 발생
   ↓ Alertmanager (alertmanagerConfigSelector={} → 이 ns config도 자동 병합)
AlertmanagerConfig route matcher (service=temporal-example-service)
   ↓ receiver
전용 Slack webhook (운영자 수동 Secret temporal-example-service-alert-slack)
```

Slack 메시지 형태(observability와 동일): `[DEV][WARNING] TemporalWorkerDown (dev-temporal-example-service-worker)`
- `[DEV]/[PROD]`는 Prometheus `externalLabels.stage` 자동 주입(룰이 안 박음 — prod 복제 시 자동으로 `[PROD]`).

## 배포 절차

### 1. webhook Secret 생성 (운영자, 1회 — 로컬에서 직접)

ESO/Vault 미사용 — 운영자가 webhook을 인자로 줘서 직접 만든다(GitOps 밖, webhook이 git에 안 들어가게).

```bash
# dry-run(명령만 출력) → 검토 후 --apply (또는 출력된 명령 직접 실행)
KUBECONFIG=~/.kube/dev-cluster \
SLACK_WEBHOOK_URL=<전용채널 webhook> \
  ./create-webhook-secret.sh dev            # 검토용 dry-run
KUBECONFIG=~/.kube/dev-cluster \
SLACK_WEBHOOK_URL=<전용채널 webhook> \
  ./create-webhook-secret.sh dev --apply    # 실제 생성(yes 확인)
```
생성되는 Secret: `dev-temporal-example-service/temporal-example-service-alert-slack` (key `url`).
> ⚠️ webhook URL은 시크릿 — git·매니페스트에 평문 금지. 쉘 히스토리도 주의(명령 앞 공백 두면 histignore).
> ⚠️ 이 Secret은 ArgoCD 관리 밖 — 앱 prune/재생성과 무관하게 유지(수동 생성이라).

### 2. ArgoCD 배포 (서버 앱 sync — 별도 앱 없음)

알람은 서버 wrapper 차트에 통합됐으므로 **새 Application·AppSet 변경 불필요.** git push 후 기존 서버 앱을 sync하면 PrometheusRule·AlertmanagerConfig가 같이 생성된다.

```
ArgoCD UI → dev-temporal-example-service-server 앱 → (Refresh) → SYNC
```
> alerts.enabled 토글만 켠 차트 values 변경이라 ArgoCD가 git에서 자동 감지(AppSet 재적용 불필요).

### 3. 검증 (read-only)

```bash
DK=~/.kube/dev-cluster; NS=dev-temporal-example-service
# 리소스 생성 (rule·config는 ArgoCD sync)
KUBECONFIG=$DK kubectl get prometheusrule,alertmanagerconfig -n $NS
# webhook Secret 존재 (운영자 수동 생성분)
KUBECONFIG=$DK kubectl get secret temporal-example-service-alert-slack -n $NS
# Prometheus에 룰 등록 확인 (Prometheus UI Alerts 탭 또는)
KUBECONFIG=$DK kubectl exec -n monitoring prometheus-kube-prometheus-stack-prometheus-0 -c prometheus -- \
  wget -qO- 'http://localhost:9090/api/v1/rules?type=alert' | grep -o 'Temporal[A-Za-z]*'
```
실제 Slack 도달 테스트: worker를 잠깐 0 replica로 두면 `TemporalWorkerDown`이 5분 뒤 발화(또는 임계 짧은 룰로 임시 테스트). ⚠️ 변경은 운영자 수동.

## 룰 추가 (운영하며 확장)

이 디렉토리에 PrometheusRule 파일을 추가하거나 [chart의 alerts-rules.yaml](../../chart/templates/alerts-rules.yaml)에 rule을 더하면 같은 Application이 sync한다. **새 alert엔 반드시**:
- `labels.severity: critical|warning`
- `labels.service: temporal-example-service` ← 없으면 전용 채널로 안 감(observability 공통으로 빠지거나 누락)
- `annotations.summary` (Slack 본문)

다음 후보(실재 메트릭): persistence_error / service_error / schedule_to_start 지연 — [docs/alerting-design.md §4](../../../../docs/alerting-design.md) 참조.
