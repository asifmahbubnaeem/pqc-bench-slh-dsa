package pqcbench;

import io.gatling.javaapi.core.*;
import io.gatling.javaapi.http.*;

import java.time.Duration;

import static io.gatling.javaapi.core.CoreDsl.*;
import static io.gatling.javaapi.http.HttpDsl.*;

/**
 * Scenario 02: Resumed-handshake latency.
 *
 * Each virtual user does ONE TLS handshake and then N requests over the same
 * connection via Gatling's connection pool (shareConnections). This measures
 * the "warm" case where TLS session resumption / keep-alive is in play — i.e.
 * what most real production traffic actually looks like.
 *
 * Config via -D system properties:
 *   -Dtarget=https://IP:443
 *   -Drate=300                 users/sec created (each does requestsPerUser)
 *   -DrequestsPerUser=10       how many requests per TLS connection
 *   -DmeasureSec=300
 *   -DwarmupSec=30
 *   -Dtag=classical-resumed
 */
public class ResumedHandshake extends Simulation {

    private static String prop(String name, String defaultValue) {
        String v = System.getProperty(name);
        return (v == null || v.isEmpty()) ? defaultValue : v;
    }

    private static int propInt(String name, int defaultValue) {
        try { return Integer.parseInt(prop(name, String.valueOf(defaultValue))); }
        catch (NumberFormatException e) { return defaultValue; }
    }

    private final String target          = prop("target", "https://127.0.0.1:443");
    private final int rate               = propInt("rate", 300);
    private final int requestsPerUser    = propInt("requestsPerUser", 10);
    private final int measureSec         = propInt("measureSec", 300);
    private final int warmupSec          = propInt("warmupSec", 30);
    private final String tag             = prop("tag", "resumed-untagged");

    // Key difference from FreshHandshake: shareConnections() is enabled, so
    // Gatling pools TCP+TLS connections. Second+ requests on the same virtual
    // user reuse the TLS session.
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
            exec(http("warmup_req").get("/").check(status().is(200)))
        );

    private final ScenarioBuilder measureSc = scenario("measure_" + tag)
        .repeat(requestsPerUser).on(
            exec(http("resumed_req").get("/").check(status().is(200)))
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
