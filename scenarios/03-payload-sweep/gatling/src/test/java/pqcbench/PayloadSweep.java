package pqcbench;

import io.gatling.javaapi.core.*;
import io.gatling.javaapi.http.*;

import java.time.Duration;

import static io.gatling.javaapi.core.CoreDsl.*;
import static io.gatling.javaapi.http.HttpDsl.*;

/**
 * Scenario 03: Payload-size sweep.
 *
 * Measures end-to-end request latency across response sizes for both the
 * classical and PQ TLS configurations. Uses the resumed-handshake pattern
 * (shareConnections) so the handshake amortizes over N requests per user
 * — the signal here is bulk transfer + record-layer overhead, not the
 * handshake itself (that's scenario 02).
 *
 * The server-side endpoint is picked by -Dpayload:
 *   100B  → /payload/100B
 *   10K   → /payload/10K
 *   100K  → /payload/100K
 *   1M    → /payload/1M
 *
 * Config via -D system properties:
 *   -Dtarget=https://IP:443
 *   -Dpayload=100B                size key (also used in tag)
 *   -Drate=200                    users/sec created
 *   -DrequestsPerUser=10          requests per TLS connection
 *   -DmeasureSec=300
 *   -DwarmupSec=30
 *   -Dtag=classical-100B
 */
public class PayloadSweep extends Simulation {

    private static String prop(String name, String defaultValue) {
        String v = System.getProperty(name);
        return (v == null || v.isEmpty()) ? defaultValue : v;
    }

    private static int propInt(String name, int defaultValue) {
        try { return Integer.parseInt(prop(name, String.valueOf(defaultValue))); }
        catch (NumberFormatException e) { return defaultValue; }
    }

    private final String target          = prop("target", "https://127.0.0.1:443");
    private final String payload         = prop("payload", "100B");
    private final int rate               = propInt("rate", 200);
    private final int requestsPerUser    = propInt("requestsPerUser", 10);
    private final int measureSec         = propInt("measureSec", 300);
    private final int warmupSec          = propInt("warmupSec", 30);
    private final String tag             = prop("tag", "payload-untagged");

    private final String path = "/payload/" + payload;

    // Resumed-handshake pattern — the handshake isn't the measurement here.
    // What we're measuring is request latency once the TLS tunnel is warm,
    // across different payload sizes.
    private final HttpProtocolBuilder httpProtocol = http
        .baseUrl(target)
        .shareConnections()
        .disableCaching()
        .disableFollowRedirect()
        .disableUrlEncoding()
        .disableWarmUp()
        .header("X-Bench-Tag", tag);

    private final ScenarioBuilder warmupSc  = scenario("warmup_"  + tag)
        .repeat(requestsPerUser).on(
            exec(http("warmup_payload").get(path).check(status().is(200)))
        );

    private final ScenarioBuilder measureSc = scenario("measure_" + tag)
        .repeat(requestsPerUser).on(
            exec(http("payload_req").get(path).check(status().is(200)))
        );

    {
        setUp(
            warmupSc.injectOpen(
                constantUsersPerSec(50).during(Duration.ofSeconds(warmupSec))
            ),
            measureSc.injectOpen(
                nothingFor(Duration.ofSeconds(warmupSec + 5L)),
                constantUsersPerSec(rate).during(Duration.ofSeconds(measureSec))
            )
        )
        .protocols(httpProtocol)
        .assertions(
            global().successfulRequests().percent().gte(99.0),
            global().responseTime().max().lt(30000)
        );
    }
}
