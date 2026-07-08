# 토폴로지: 서비스별 독립 클러스터 (확정 배경)

## 모델
- 서비스 A, B … 마다 **별도 Temporal 클러스터**(frontend/history/matching/worker + 자체 DB)를 둔다.
- 각 클러스터는 **독립적으로 설계**한다(스케일, persistence, 버전이 서로 다를 수 있음).
- 한 클러스터 안에서 namespace로 테넌트를 나누는 "공유 클러스터" 방식은 **채택하지 않음**.

## 채택 이유
- 서비스별 요구사항/설계가 근본적으로 다름.
- 강한 격리(blast radius), 독립 스케일링/버전업.

## 비용·운영 트레이드오프 (인지하고 진행)
- DB·운영 비용이 서비스 수에 비례(N배). → 리서치 단계에서 DB 호스팅/비용 추정 필요(R4 참고).
- 서비스가 늘수록 클러스터 관리 표준화가 중요 → `services/_template/` + ArgoCD ApplicationSet로 표준화.

상세 결정: [../adr/0003-per-service-independent-clusters.md](../adr/0003-per-service-independent-clusters.md)
