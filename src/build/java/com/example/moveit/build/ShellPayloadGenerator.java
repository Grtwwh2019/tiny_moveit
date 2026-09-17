package com.example.moveit.build;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.security.SecureRandom;
import java.util.Arrays;
import java.util.List;

import javax.crypto.Cipher;
import javax.crypto.spec.GCMParameterSpec;
import javax.crypto.spec.SecretKeySpec;

/** Build-only tool: combines and encrypts the shell modules packaged in the JAR. */
public final class ShellPayloadGenerator {
    private static final String[] LIBRARIES = new String[]{
            "lib/common.sh", "lib/auth.sh", "lib/task.sh", "lib/report.sh"
    };
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

    private ShellPayloadGenerator() {
    }

    public static void main(String[] args) throws Exception {
        if (args.length != 2) {
            throw new IllegalArgumentException("Expected shell source directory and output file");
        }
        Path source = Paths.get(args[0]);
        Path output = Paths.get(args[1]);
        byte[] plain = combine(source);
        byte[] key = key();
        byte[] iv = new byte[12];
        new SecureRandom().nextBytes(iv);

        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(Cipher.ENCRYPT_MODE, new SecretKeySpec(key, "AES"),
                new GCMParameterSpec(128, iv));
        cipher.updateAAD(D);
        byte[] encrypted = cipher.doFinal(plain);

        Files.createDirectories(output.getParent());
        ByteArrayOutputStream payload = new ByteArrayOutputStream(iv.length + encrypted.length);
        payload.write(iv);
        payload.write(encrypted);
        Files.write(output, payload.toByteArray());

        Arrays.fill(plain, (byte) 0);
        Arrays.fill(key, (byte) 0);
    }

    private static byte[] combine(Path source) throws IOException {
        StringBuilder script = new StringBuilder("#!/bin/sh\n\nset -u\n\n");
        for (String library : LIBRARIES) {
            append(script, source.resolve(library), false);
        }
        append(script, source.resolve("moveit-runner.sh"), true);
        String combined = script.toString();
        if (combined.contains("$MOVEIT_SHELL_HOME/lib/")) {
            throw new IOException("Combined script still contains a module source directive");
        }
        return combined.getBytes(StandardCharsets.UTF_8);
    }

    private static void append(StringBuilder output, Path input, boolean main) throws IOException {
        List<String> lines = Files.readAllLines(input, StandardCharsets.UTF_8);
        for (String line : lines) {
            if (line.startsWith("#!")) {
                continue;
            }
            if (main && (line.equals("set -u") || line.startsWith(". \"$MOVEIT_SHELL_HOME/"))) {
                continue;
            }
            output.append(line).append('\n');
        }
        output.append('\n');
    }

    private static byte[] key() {
        byte[] key = new byte[A.length];
        for (int i = 0; i < key.length; i++) {
            key[i] = (byte) (A[i] ^ B[i]);
        }
        return key;
    }
}
