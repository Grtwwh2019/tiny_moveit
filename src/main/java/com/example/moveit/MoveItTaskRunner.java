package com.example.moveit;

import java.io.IOException;
import java.io.InputStream;
import java.nio.file.FileVisitResult;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.SimpleFileVisitor;
import java.nio.file.attribute.BasicFileAttributes;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.Map;

/**
 * Dependency-free Java launcher. All MOVEit behavior lives in embedded shell scripts.
 */
public final class MoveItTaskRunner {
    private static final int INTERNAL_ERROR = 9;
    private static final List<String> SHELL_RESOURCES = Arrays.asList(
            "shell/moveit-runner.sh",
            "shell/lib/common.sh",
            "shell/lib/auth.sh",
            "shell/lib/task.sh",
            "shell/lib/report.sh"
    );

    private MoveItTaskRunner() {
    }

    public static void main(String[] args) {
        System.exit(run(args, System.getenv(), true));
    }

    static int run(String[] args, Map<String, String> environment) {
        return run(args, environment, true);
    }

    static int run(String[] args, Map<String, String> environment, boolean inheritIo) {
        Path shellHome = null;
        try {
            shellHome = Files.createTempDirectory("moveit-shell-");
            extractShellResources(shellHome);

            String shell = environment.get("MOVEIT_SHELL");
            if (shell == null || shell.trim().isEmpty()) {
                shell = "/bin/sh";
            }

            List<String> command = new ArrayList<String>();
            command.add(shell);
            command.add(shellHome.resolve("shell/moveit-runner.sh").toString());
            command.addAll(Arrays.asList(args));

            ProcessBuilder processBuilder = new ProcessBuilder(command);
            processBuilder.environment().putAll(environment);
            processBuilder.environment().put("MOVEIT_SHELL_HOME",
                    shellHome.resolve("shell").toString());
            if (inheritIo) {
                processBuilder.inheritIO();
            } else {
                processBuilder.redirectOutput(shellHome.resolve("test-stdout.log").toFile());
                processBuilder.redirectError(shellHome.resolve("test-stderr.log").toFile());
            }

            Process process = processBuilder.start();
            return process.waitFor();
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            printLauncherFailure("Shell process was interrupted");
            return INTERNAL_ERROR;
        } catch (IOException e) {
            printLauncherFailure("Unable to start embedded shell modules: " + e.getMessage());
            return INTERNAL_ERROR;
        } finally {
            deleteRecursively(shellHome);
        }
    }

    private static void extractShellResources(Path shellHome) throws IOException {
        ClassLoader classLoader = MoveItTaskRunner.class.getClassLoader();
        for (String resource : SHELL_RESOURCES) {
            Path destination = shellHome.resolve(resource);
            Files.createDirectories(destination.getParent());
            InputStream input = classLoader.getResourceAsStream(resource);
            if (input == null) {
                throw new IOException("Missing embedded resource: " + resource);
            }
            try {
                Files.copy(input, destination);
            } finally {
                input.close();
            }
        }
    }

    private static void deleteRecursively(Path root) {
        if (root == null || !Files.exists(root)) {
            return;
        }
        try {
            Files.walkFileTree(root, new SimpleFileVisitor<Path>() {
                @Override
                public FileVisitResult visitFile(Path file, BasicFileAttributes attrs)
                        throws IOException {
                    Files.deleteIfExists(file);
                    return FileVisitResult.CONTINUE;
                }

                @Override
                public FileVisitResult postVisitDirectory(Path directory, IOException exception)
                        throws IOException {
                    if (exception != null) {
                        throw exception;
                    }
                    Files.deleteIfExists(directory);
                    return FileVisitResult.CONTINUE;
                }
            });
        } catch (IOException ignored) {
            // Temporary extraction cleanup must not change the shell module's exit code.
        }
    }

    private static void printLauncherFailure(String message) {
        String safe = message == null ? "" : message.replace("\\", "\\\\")
                .replace("\"", "\\\"").replace("\r", " ").replace("\n", " ");
        System.out.println("{\"result\":\"FAILURE\",\"exitCode\":9,\"message\":\""
                + safe + "\"}");
    }
}
