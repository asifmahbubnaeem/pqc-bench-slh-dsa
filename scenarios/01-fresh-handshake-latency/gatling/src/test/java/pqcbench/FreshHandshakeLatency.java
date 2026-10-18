package pqcbench;

import io.gatling.javaapi.core.*;
import io.gatling.javaapi.http.*;

import java.time.Duration;

import static io.gatling.javaapi.core.CoreDsl.*;
import static io.gatling.javaapi.http.HttpDsl.*;

/**
 * Scenario 01: Fresh-handshake latency (Java version).
 *
 * Each request opens a new TCP+TLS connection so every request pays the full
 * handshake cost. This is the scenario where PQ overhead is most visible.
 *
 * Config via -D system properties (set by run.sh):
 *   -Dtarget=https://IP:443    target URL
 *   -Drate=1000                requests per second during measurement
 *   -DmeasureSec=300           measurement window (default 300 = 5 min)
 *   -DwarmupSec=30             warmup window (default 30 s)
 *   -Dtag=classical            free-form label for the arm
 */
public class FreshHandshakeLatency extends Simulation {

    private static String prop(String name, String defaultValue) {
        String v = System.getProperty(name);
        return (v == null || v.isEmpty()) ? defaultValue : v;
    }

    private static int propInt(String name, int defaultValue) {
        try { return Integer.parseInt(prop(name, String.valueOf(defaultValue))); }
        catch (NumberFormatException e) { return defaultValue; }
    }

    private final String target     = prop("target", "https://127.0.0.1:443");
    private final int rate          = propInt("rate", 1000);
    private final int measureSec    = propInt("measureSec", 300);
    private final int warmupSec     = propInt("warmupSec", 30);
    private final String tag        = prop("tag", "untagged");

    // HTTP protocol config:
    //   - shareConnections(false) forces a new TCP+TLS per virtual user
    //   - disableCaching stops HTTP short-circuits
    //   - self-signed ML-DSA-65 cert can't validate; we probe the handshake,
    //     not verify trust, so cert validation is disabled globally via
    //     -Dgatling.http.ssl.trustAll=true in run.sh
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
        .exec(http("fresh_hs").get("/").check(status().is(200)));

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
            global().responseTime().max().lt(30000)
        );
    }
}
