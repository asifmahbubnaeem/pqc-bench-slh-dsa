package pqcbench;

import io.gatling.javaapi.core.*;
import io.gatling.javaapi.http.*;

import java.time.Duration;

import static io.gatling.javaapi.core.CoreDsl.*;
import static io.gatling.javaapi.http.HttpDsl.*;

/**
 * Scenario 04: Cert-chain size impact on fresh-handshake latency.
 *
 * Same shape as Phase 1's FreshHandshakeLatency: new TCP + TLS per request,
 * 3-byte response, measure full response time (= time-to-first-byte for a
 * trivial endpoint). Phase 3 flips the server's cert between arms (ecdsa /
 * rsa-2048 / ml-dsa-65) via terraform `cert_type` variable — THIS simulation
 * doesn't care which cert the server serves; it just measures what the client
 * sees. The driver (`run.sh`) orchestrates the sweep.
 *
 * Config via -D system properties:
 *   -Dtarget=https://PUBLIC_IP:443    always public IP (cross-region ready)
 *   -Drate=300                        users/sec (= req/sec with fresh conns)
 *   -DmeasureSec=300                  5 min default
 *   -DwarmupSec=30
 *   -Dtag=ecdsa-us-east-1             arm label; usually "<cert>-<region>"
 */
public class CertChainHandshake extends Simulation {

    private static String prop(String name, String defaultValue) {
        String v = System.getProperty(name);
        return (v == null || v.isEmpty()) ? defaultValue : v;
    }

    private static int propInt(String name, int defaultValue) {
        try { return Integer.parseInt(prop(name, String.valueOf(defaultValue))); }
        catch (NumberFormatException e) { return defaultValue; }
    }

    private final String target      = prop("target", "https://127.0.0.1:443");
    private final int rate           = propInt("rate", 300);
    private final int measureSec     = propInt("measureSec", 300);
    private final int warmupSec      = propInt("warmupSec", 30);
    private final String tag         = prop("tag", "cert-untagged");

    // No shareConnections → fresh TCP + TLS per request, so every request
    // pays the full handshake cost including cert bytes. Same assertion
    // shape as Phase 1/2 for consistency.
    private final HttpProtocolBuilder httpProtocol = http
        .baseUrl(target)
        .disableCaching()
        .disableFollowRedirect()
        .disableUrlEncoding()
        .disableWarmUp()
        .header("X-Bench-Tag", tag);

    private final ScenarioBuilder warmupSc  = scenario("warmup_"  + tag)
        .exec(http("warmup_hs").get("/").check(status().is(200)));

    private final ScenarioBuilder measureSc = scenario("measure_" + tag)
        .exec(http("cert_hs").get("/").check(status().is(200)));

    {
        setUp(
            warmupSc.injectOpen(
                constantUsersPerSec(100).during(Duration.ofSeconds(warmupSec))
            ),
            measureSc.injectOpen(
                nothingFor(Duration.ofSeconds(warmupSec + 5L)),
                constantUsersPerSec(rate).during(Duration.ofSeconds(measureSec))
            )
        )
        .protocols(httpProtocol)
        .assertions(
            global().successfulRequests().percent().gte(99.0),
            // Cross-region max can legitimately be high (RTT * N); allow 60s
            global().responseTime().max().lt(60000)
        );
    }
}
