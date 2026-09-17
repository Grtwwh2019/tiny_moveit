#!/bin/sh

set -eu

PROJECT_DIRECTORY=$(CDPATH= cd "$(dirname "$0")" && pwd)
GENERATOR_CLASSES="$PROJECT_DIRECTORY/target/payload-generator"
PROTECTED_PAYLOAD="$PROJECT_DIRECTORY/src/main/protected/META-INF/.runtime.bin"

mkdir -p "$GENERATOR_CLASSES"
javac -source 1.8 -target 1.8 -encoding UTF-8 \
  -d "$GENERATOR_CLASSES" \
  "$PROJECT_DIRECTORY/src/build/java/com/example/moveit/build/ShellPayloadGenerator.java"

java -cp "$GENERATOR_CLASSES" com.example.moveit.build.ShellPayloadGenerator \
  "$PROJECT_DIRECTORY/src/main/resources/shell" \
  "$PROTECTED_PAYLOAD"

exec mvn clean package
