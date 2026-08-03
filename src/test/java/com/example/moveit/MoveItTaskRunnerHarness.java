package com.example.moveit;

import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpHandler;
import com.sun.net.httpserver.HttpServer;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Collections;
import java.util.Map;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;

/** Dependency-free integration test harness; run its main method after test-compile. */
public final class MoveItTaskRunnerHarness {
    private HttpServer server;
    private final AtomicReference<String> tokenRequestBody = new AtomicReference<String>();
    private final AtomicReference<String> reportRequestBody = new AtomicReference<String>();
    private final AtomicReference<String> reportAuthorization = new AtomicReference<String>();

    public static void main(String[] args) throws Exception {
        runTest(new TestCase() {
            @Override
            public void run(MoveItTaskRunnerHarness harness) throws Exception {
                harness.embeddedShellReturnsZeroAndPollsUntilSuccess();
            }
        });
        runTest(new TestCase() {
            @Override
            public void run(MoveItTaskRunnerHarness harness) throws Exception {
                harness.embeddedShellReturnsSixWhenMoveItReportsFailure();
            }
        });
        runTest(new TestCase() {
            @Override
            public void run(MoveItTaskRunnerHarness harness) throws Exception {
                harness.embeddedShellReadsPasswordFromEnvironment();
            }
        });
        System.out.println("Integration tests passed: 3/3");
    }

    private static void runTest(TestCase testCase) throws Exception {
        MoveItTaskRunnerHarness harness = new MoveItTaskRunnerHarness();
        try {
            testCase.run(harness);
        } finally {
            harness.stopServer();
        }
    }

    private void stopServer() {
        if (server != null) {
            server.stop(0);
        }
    }

    private void embeddedShellReturnsZeroAndPollsUntilSuccess() throws Exception {
        final AtomicInteger reportCalls = new AtomicInteger();
        startServer(new ReportScenario() {
            @Override
            String response() {
                if (reportCalls.incrementAndGet() == 1) {
                    return "{\"items\":[]}";
                }
                return "{\"items\":[{\"RunID\":42,\"Status\":\"Success\","
                        + "\"StatusCode\":0,\"FilesSent\":3,\"TotalBytesSent\":1234,"
                        + "\"StatusMsg\":\"Completed\"}]}";
            }
        });
        Path log = Files.createTempFile("moveit-shell-success", ".log");

        int exitCode = MoveItTaskRunner.run(arguments(log, "secret"),
                Collections.<String, String>emptyMap(), false);

        assertEquals(0, exitCode, "success exit code");
        assertEquals(2, reportCalls.get(), "report poll count");
        assertContains(reportRequestBody.get(), "TaskID==123", "report TaskID predicate");
        assertContains(reportRequestBody.get(),
                "NominalStart==\\\"2026-08-04 10:11:12.34\\\"",
                "report nominalStart predicate");
        assertContains(reportRequestBody.get(),
                "Status=in=(\\\"Success\\\",\\\"Failure\\\")",
                "report status predicate");
        assertEquals("Bearer test-token", reportAuthorization.get(), "authorization header");
        String content = readFile(log);
        assertContains(content, "status=Success", "success log status");
        assertContains(content, "filesSent=3", "success log file count");
        assertContains(content, "Program exit code=0", "success log exit code");
    }

    private void embeddedShellReturnsSixWhenMoveItReportsFailure() throws Exception {
        startServer(new ReportScenario() {
            @Override
            String response() {
                return "{\"items\":[{\"RunID\":99,\"Status\":\"Failure\","
                        + "\"StatusCode\":17,\"FilesSent\":0,\"TotalBytesSent\":0,"
                        + "\"StatusMsg\":\"Destination unavailable\"}]}";
            }
        });
        Path log = Files.createTempFile("moveit-shell-failure", ".log");

        int exitCode = MoveItTaskRunner.run(arguments(log, "secret"),
                Collections.<String, String>emptyMap(), false);

        assertEquals(6, exitCode, "failure exit code");
        String content = readFile(log);
        assertContains(content, "Destination unavailable", "failure log message");
        assertContains(content, "Program exit code=6", "failure log exit code");
    }

    private void embeddedShellReadsPasswordFromEnvironment() throws Exception {
        startServer(new ReportScenario() {
            @Override
            String response() {
                return "{\"items\":[{\"RunID\":7,\"Status\":\"Success\","
                        + "\"StatusCode\":0,\"FilesSent\":1,\"TotalBytesSent\":10}]}";
            }
        });
        Path log = Files.createTempFile("moveit-shell-env", ".log");
        Map<String, String> environment =
                Collections.singletonMap("MOVEIT_TEST_PASSWORD", "secret value");

        int exitCode = MoveItTaskRunner.run(
                arguments(log, "env:MOVEIT_TEST_PASSWORD"), environment, false);

        assertEquals(0, exitCode, "environment password exit code");
        assertContains(tokenRequestBody.get(), "password=secret+value",
                "URL-encoded environment password");
    }

    private String[] arguments(Path log, String password) {
        return new String[]{
                "http://127.0.0.1:" + server.getAddress().getPort(),
                "api-user", password, "123", log.toString(),
                "--poll-seconds=1", "--timeout-seconds=10"
        };
    }

    private void startServer(final ReportScenario scenario) throws IOException {
        server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        server.createContext("/api/v1/token", new HttpHandler() {
            @Override
            public void handle(HttpExchange exchange) throws IOException {
                tokenRequestBody.set(read(exchange.getRequestBody()));
                respond(exchange, 200,
                        "{\"access_token\":\"test-token\",\"token_type\":\"bearer\"}");
            }
        });
        server.createContext("/api/v1/tasks/123/start", jsonHandler(200,
                "{\"nominalStart\":\"2026-08-04 10:11:12.34\"}"));
        server.createContext("/api/v1/tasks/123", jsonHandler(200,
                "{\"ID\":\"123\",\"Name\":\"Daily Transfer\"}"));
        server.createContext("/api/v1/reports/taskruns", new HttpHandler() {
            @Override
            public void handle(HttpExchange exchange) throws IOException {
                reportRequestBody.set(read(exchange.getRequestBody()));
                reportAuthorization.set(exchange.getRequestHeaders().getFirst("Authorization"));
                respond(exchange, 200, scenario.response());
            }
        });
        server.start();
    }

    private static HttpHandler jsonHandler(final int status, final String body) {
        return new HttpHandler() {
            @Override
            public void handle(HttpExchange exchange) throws IOException {
                respond(exchange, status, body);
            }
        };
    }

    private static void respond(HttpExchange exchange, int status, String body) throws IOException {
        byte[] bytes = body.getBytes(StandardCharsets.UTF_8);
        exchange.getResponseHeaders().set("Content-Type", "application/json; charset=utf-8");
        exchange.sendResponseHeaders(status, bytes.length);
        OutputStream output = exchange.getResponseBody();
        output.write(bytes);
        output.close();
    }

    private static String read(InputStream input) throws IOException {
        ByteArrayOutputStream output = new ByteArrayOutputStream();
        byte[] buffer = new byte[1024];
        int count;
        while ((count = input.read(buffer)) != -1) {
            output.write(buffer, 0, count);
        }
        return new String(output.toByteArray(), StandardCharsets.UTF_8);
    }

    private static String readFile(Path path) throws IOException {
        return new String(Files.readAllBytes(path), StandardCharsets.UTF_8);
    }

    private static void assertContains(String actual, String expected, String description) {
        if (actual == null || !actual.contains(expected)) {
            throw new AssertionError(description + " expected to contain <" + expected
                    + "> but was <" + actual + ">");
        }
    }

    private static void assertEquals(Object expected, Object actual, String description) {
        if (expected == null ? actual != null : !expected.equals(actual)) {
            throw new AssertionError(description + " expected <" + expected
                    + "> but was <" + actual + ">");
        }
    }

    private interface TestCase {
        void run(MoveItTaskRunnerHarness harness) throws Exception;
    }

    private abstract static class ReportScenario {
        abstract String response();
    }
}
