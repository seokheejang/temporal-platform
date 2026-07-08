# 전제하는 플랫폼 스택 (Platform Assumptions)

이 repo의 예제(`services/example-service/`)와 공용 차트(`charts/`)는 아래 플랫폼 구성요소가
클러스터에 이미 있다고 가정한다. **다른 환경에 이식할 때는 이 표를 보고 자신의 스택으로 교체하거나
해당 기능을 꺼라.** 대부분 차트 값의 토글로 켜고 끌 수 있다.

| 구성요소 | 용도 | 대체 / 제거 방법 |
|---|---|---|
| **Kubernetes** | 배포 대상 | 필수 |
| **ArgoCD** | GitOps 배포 (Application / ApplicationSet / AppProject) | 다른 GitOps 도구를 쓰면 `argocd/`를 대체. 수동 `helm install`도 가능 |
| **Helm** | 패키징 (upstream `temporalio/temporal` umbrella wrapper) | 필수 (차트 렌더링) |
| **cert-manager** | in-cluster mTLS cert 발급/자동갱신 | mTLS를 끄면(`temporal.tls.enabled: false`) 불필요 |
| **HashiCorp Vault + PKI engine** | mTLS용 사설 CA (Root/Intermediate), 외부 worker cert 발급 | 다른 CA를 쓰면 `ClusterIssuer`를 교체 (cert-manager는 ACME/CA/SelfSigned 등 지원). Vault PKI 세팅: [runbooks/vault-pki-setup.md](runbooks/vault-pki-setup.md) |
| **External Secrets Operator (ESO)** | Vault KV -> k8s Secret 동기화 (DB 자격증명, 앱 시크릿) | 시크릿 백엔드가 다르면 `ClusterSecretStore`를 교체. Secret을 직접 만들면 `externalSecret.enabled: false` |
| **CloudNativePG (cnpg)** | Temporal persistence + visibility PostgreSQL | managed PG(RDS/Aurora 등)를 쓰면 `db/` 매니페스트를 빼고 `temporal.server.config.persistence`의 connectAddr만 지정 |
| **kube-prometheus-stack** (Prometheus Operator + Grafana) | 메트릭 수집(ServiceMonitor/PodMonitor) / 대시보드 / 알람(PrometheusRule) | 관측성을 끄면(`metrics.enabled: false`, `serviceMonitor.enabled: false`) 불필요 |
| **Gateway API / HTTPRoute** (예제는 Cilium Gateway) | Web UI 외부 노출 | Ingress 등 다른 방식으로 교체 (`web-httproute.yaml`) |
| **LoadBalancer + MetalLB** (예제) | 외부 gRPC(frontend 7233) 노출 | 클라우드 LB로 교체하면 `loadBalancerIP` 고정을 빼도 됨 (`frontend-grpc-lb.yaml`) |
| **Keycloak** (선택) | Web UI SSO (OIDC) | UI 무인증으로 두면 불필요. `platform/keycloak/` 삭제 |
| **컨테이너 레지스트리 + imagePullSecret** (`regcred`) | worker 이미지 pull | 퍼블릭 이미지면 `imagePullSecrets` 제거 |

## 보안 레이어 토글 요약

예제는 기본적으로 **평문(mTLS off)** 으로 시작하고, 파일 하나로 mTLS를 켠다.

- **mTLS on/off**: `services/<svc>/<env>/values-mtls.yaml`(`.example`에서 복사) 존재 = on, 삭제 = off.
  워커 쪽도 `temporal.tls.enabled: true` + `certManager.enabled: true`를 짝으로 켠다.
  자세한 절차와 함정은 [runbooks/temporal-mtls-enable.md](runbooks/temporal-mtls-enable.md).
- **관측성 on/off**: 차트 값 `metrics.enabled` / `serviceMonitor.enabled`.
- **시크릿 주입 on/off**: 차트 값 `externalSecret.enabled` (ESO 사용 시).

## placeholder 규약

중성화 과정에서 조직 고유값을 아래 규약으로 치환했다. 실제 배포 시 사용 환경 값으로 바꾼다.

| placeholder | 의미 |
|---|---|
| `example`, `example-org` | 조직/네임스페이스 |
| `example.com`, `k8s.example.com` | 도메인 |
| `registry.example.com` | 컨테이너 레지스트리 |
| `example-service` | 서비스명 |
| `vault.example.com` | Vault 주소 |
| `192.0.2.x`, `198.51.100.x` | 예시 IP (RFC 5737 문서용 대역) |
| `EXAMPLE_API_KEY`, `EXTRA_*` | 앱 시크릿/env 예시 |
