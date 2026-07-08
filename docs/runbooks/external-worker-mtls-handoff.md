# 외부 서비스 Temporal mTLS — 개발자 핸드오프 (Vault 직접 발급)

> dev 환경에서 두 외부 서비스(scheduler·admin) → on-prem vault → Temporal frontend mTLS 경로를 **end-to-end 실증 완료**.
> 이 문서는 "DevOps가 무엇을 주고 / 앱이 무엇을 코드로 해야 하는가"를 정리한다.

---

## 1. DevOps가 각 서비스에 전달하는 값 (4개)

| 항목 | 값 | 비밀? | 비고 |
|---|---|:---:|---|
| `VAULT_ADDR` | `https://vault.example.com` | ✗ | 공통 |
| `VAULT_ROLE_ID` | (서비스별 — 아래) | △ | 고정값. 그 자체론 무력 |
| `VAULT_SECRET_ID` | (서비스별 — 아래) | **✓✓** | **비밀번호** — 안전 채널로만, 코드/깃에 절대 금지 |
| (PKI 경로·role은 고정) | `pki_temporal_int` / `temporal-client` | ✗ | 코드 상수로 둬도 됨 |

서비스별 role_id (secret_id는 별도 안전 채널로 전달):

| 서비스 | approle role | role_id |
|---|---|---|
| Scheduler | `temporal-worker-scheduler` | (rotate 후 값) |
| admin | `temporal-worker-admin` | (rotate 후 값) |

> ⚠️ **secret_id 전달은 Slack/메일 평문 금지.** Vault·1Password·k8s Secret(ESO) 등 안전 채널.
> ⚠️ secret_id는 발급 시 1회만 표시되고 vault에 평문 저장 안 됨. 분실 시 재발급.
> 🔒 **운영 권장**: secret_id에 CIDR 바인딩(서비스 출발 IP 대역)을 걸면 유출돼도 타 위치에서 무력 — DevOps와 협의.

### 권장: secret_id를 어디에 둘까
- **admin (AWS k8s 파드)**: k8s Secret으로 주입 → 환경변수 `VAULT_SECRET_ID`. (가능하면 ESO로 Vault KV에서 자동 주입)
- **Scheduler (on-prem VM)**: 파일 권한 600 + 환경변수, 또는 systemd `EnvironmentFile`.

---

## 2. 앱이 코드로 해야 하는 일 (cert-manager를 코드로 대신)

```
시작 시:  ① approle login (role_id+secret_id → vault token)
          ② PKI issue (token으로 cert 발급)
          ③ 받은 cert로 mTLS gRPC 채널 구성 → Temporal 접속
주기적:   ④ TTL 2/3 지점에 ①~③ 재실행 → 채널 교체(무중단)
```

### 발급 요청 (Vault REST)
```
POST {VAULT_ADDR}/v1/auth/approle/login
  body: {"role_id":"...","secret_id":"..."}
  → resp.auth.client_token   (vault 토큰, TTL 1h)

POST {VAULT_ADDR}/v1/pki_temporal_int/issue/temporal-client
  header: X-Vault-Token: <client_token>
  body: {"common_name":"<svc>.worker.temporal.example", "ttl":"48h"}
  → resp.data.certificate    (leaf cert, PEM)
    resp.data.private_key     (PEM)
    resp.data.issuing_ca      (Intermediate CA, PEM)
    resp.data.ca_chain        ([Intermediate, Root], PEM 배열)
```
- `common_name`: 서비스 식별용. Scheduler=`scheduler.worker.temporal.example`, admin=`admin.worker.temporal.example`
- `ttl`: 최대 48h(role max_ttl). 개발 검증 땐 짧게(예 `10m`) 줘서 재발급 로직을 빨리 확인 가능.

### 🔑 가장 중요한 함정 — client cert는 full chain이어야 함
Temporal Java SDK(gRPC/Netty TLS)는 client cert를 보낼 때 **leaf + Intermediate 둘 다** 보내야 서버가 받아준다.
**leaf 하나만 보내면 `tls: certificate required`로 거부**된다. (실측으로 확인: leaf만→거부, full chain→SERVING)

| mTLS 파일 | = Vault 응답의 |
|---|---|
| client cert (보낼 것) | `certificate` + `issuing_ca` ← **반드시 둘 다, 이 순서** |
| client key | `private_key` |
| 신뢰 루트 (서버 검증용) | `ca_chain` (Root 포함) |

---

## 3. Temporal 접속 파라미터 (dev)

| 항목 | 값 |
|---|---|
| frontend 주소 | `temporal-example-service-grpc.dev.k8s.example.com:7233` |
| TLS server name (SNI) | `dev-temporal-example-service-server.dev-temporal-example-service.svc.cluster.local` |
| namespace | `example-service-dev` |

> ⚠️ **server name 고정 필수**: frontend는 IP/외부도메인으로 응답할 수 있는데 server cert SAN은 내부 svc 이름이다.
> SNI(`tls-server-name`)를 위 svc 이름으로 고정해야 server cert 검증을 통과한다. (in-cluster worker도 동일 이유로 고정)

---

## 4. Java 샘플 (Temporal Java SDK 1.33 + Vault REST)

> 의존성: `temporal-sdk`, `grpc-netty-shaded`, `netty-handler`, `okhttp`(또는 Spring Vault) — admin 서비스에 이미 존재.
> 핵심은 **WorkflowServiceStubs 의 SslContext 를 vault 발급 cert로 구성**하는 것.

```java
import io.temporal.serviceclient.WorkflowServiceStubs;
import io.temporal.serviceclient.WorkflowServiceStubsOptions;
import io.grpc.netty.shaded.io.netty.handler.ssl.SslContext;
import io.grpc.netty.shaded.io.netty.handler.ssl.SslContextBuilder;

import java.io.ByteArrayInputStream;
import java.nio.charset.StandardCharsets;
import java.security.KeyFactory;
import java.security.PrivateKey;
import java.security.cert.CertificateFactory;
import java.security.cert.X509Certificate;
import java.security.spec.PKCS8EncodedKeySpec;
import java.util.*;
import okhttp3.*;
import com.fasterxml.jackson.databind.*;

public class TemporalMtlsClient {

  static final String VAULT_ADDR = System.getenv("VAULT_ADDR");          // https://vault.example.com
  static final String ROLE_ID    = System.getenv("VAULT_ROLE_ID");
  static final String SECRET_ID  = System.getenv("VAULT_SECRET_ID");
  static final String CN         = "admin.worker.temporal.example";       // 서비스별
  static final String TARGET     = "temporal-example-service-grpc.dev.k8s.example.com:7233";
  static final String SERVER_NAME= "dev-temporal-example-service-server.dev-temporal-example-service.svc.cluster.local";
  static final String NAMESPACE  = "example-service-dev";

  static final OkHttpClient http = new OkHttpClient();
  static final ObjectMapper om = new ObjectMapper();
  static final MediaType JSON = MediaType.parse("application/json");

  /** ① approle login → vault token */
  static String vaultLogin() throws Exception {
    String body = om.writeValueAsString(Map.of("role_id", ROLE_ID, "secret_id", SECRET_ID));
    Request req = new Request.Builder()
        .url(VAULT_ADDR + "/v1/auth/approle/login")
        .post(RequestBody.create(body, JSON)).build();
    try (Response r = http.newCall(req).execute()) {
      JsonNode n = om.readTree(r.body().string());
      return n.path("auth").path("client_token").asText();
    }
  }

  /** ② PKI issue → cert 묶음 */
  static JsonNode vaultIssue(String token) throws Exception {
    String body = om.writeValueAsString(Map.of("common_name", CN, "ttl", "48h"));
    Request req = new Request.Builder()
        .url(VAULT_ADDR + "/v1/pki_temporal_int/issue/temporal-client")
        .header("X-Vault-Token", token)
        .post(RequestBody.create(body, JSON)).build();
    try (Response r = http.newCall(req).execute()) {
      return om.readTree(r.body().string()).path("data");
    }
  }

  /** ③ vault 응답 → Netty SslContext (★ full chain 주의) */
  static SslContext buildSslContext(JsonNode data) throws Exception {
    var cf = CertificateFactory.getInstance("X.509");

    // client chain = leaf + issuing_ca (★ 반드시 둘 다)
    X509Certificate leaf  = parseCert(cf, data.get("certificate").asText());
    X509Certificate inter = parseCert(cf, data.get("issuing_ca").asText());
    X509Certificate[] clientChain = { leaf, inter };

    // private key (PKCS#8 PEM)
    PrivateKey key = parseKey(data.get("private_key").asText());

    // 신뢰 루트 = ca_chain (Root 포함)
    List<X509Certificate> trust = new ArrayList<>();
    for (JsonNode c : data.get("ca_chain")) trust.add(parseCert(cf, c.asText()));

    return SslContextBuilder.forClient()
        .keyManager(key, clientChain)                                  // ← client cert로 full chain 제시
        .trustManager(trust.toArray(new X509Certificate[0]))           // ← 서버 검증용 Root
        .build();
  }

  static X509Certificate parseCert(CertificateFactory cf, String pem) throws Exception {
    return (X509Certificate) cf.generateCertificate(
        new ByteArrayInputStream(pem.getBytes(StandardCharsets.UTF_8)));
  }
  static PrivateKey parseKey(String pem) throws Exception {
    String b64 = pem.replaceAll("-----[^-]+-----", "").replaceAll("\\s", "");
    byte[] der = Base64.getDecoder().decode(b64);
    return KeyFactory.getInstance("RSA").generatePrivate(new PKCS8EncodedKeySpec(der));
  }

  /** WorkflowServiceStubs 생성 (재발급 시 새로 만들어 교체) */
  static WorkflowServiceStubs connect() throws Exception {
    String token = vaultLogin();
    JsonNode data = vaultIssue(token);
    SslContext ssl = buildSslContext(data);
    return WorkflowServiceStubs.newServiceStubs(
        WorkflowServiceStubsOptions.newBuilder()
            .setTarget(TARGET)
            .setSslContext(ssl)
            .setChannelInitializer(ch -> ch.overrideAuthority(SERVER_NAME)) // ← SNI 고정 (server cert SAN)
            .build());
  }

  // ④ 재발급: TTL의 2/3 지점에 connect()를 다시 호출해 새 stubs로 교체,
  //    기존 stubs는 in-flight 처리 후 shutdown. (스케줄러/ScheduledExecutorService)
}
```

> 참고: `overrideAuthority(SERVER_NAME)`로 SNI를 고정한다. SDK 버전에 따라 `WorkflowServiceStubsOptions.setChannelInitializer`나
> Netty의 `SslContextBuilder ... .build()` 후 채널 옵션으로 줄 수 있다 — 핵심은 "TLS 검증에 쓰는 호스트명을 server cert SAN(svc 이름)으로 맞추는 것".

---

## 5. 검증 순서 (개발자가 확인할 것)

1. **login만** — role_id/secret_id로 token 받기 (실패 시 secret_id·CIDR 확인)
2. **issue만** — cert 받아 `openssl x509 -text`로 CN·EKU(ClientAuth)·만료 확인
3. **짧은 TTL로 재발급 로직** — `ttl=10m`로 발급, 7분쯤 뒤 재발급·채널 교체가 도는지 (★ 90일 아닌 짧게 — 갱신 버그 조기 발견)
4. **접속** — `WorkflowServiceStubs` 생성 후 `listNamespaces` 또는 헬스 호출 → `example-service-dev` 보이면 성공
5. **full chain 누락 테스트** — 일부러 leaf만 보내보면 `certificate required` 거부 재현 (함정 체득용)

---

## 6. DevOps가 보증하는 환경 (실증 완료)
- 두 서비스 → vault 도달성 OK (admin은 AWS→on-prem cross-network 포함)
- approle login + `temporal-client` issue OK (ClientAuth-only cert)
- full-chain cert로 frontend `:7233` mTLS → **SERVING + namespace 조회** OK
- cert max_ttl = 48h (role 상한)
