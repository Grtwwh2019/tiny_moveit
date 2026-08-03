#!/bin/sh

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [ -f "$SCRIPT_DIR/moveit-task-runner-shell.jar" ]; then
  JAR_PATH="$SCRIPT_DIR/moveit-task-runner-shell.jar"
else
  JAR_PATH="$SCRIPT_DIR/target/moveit-task-runner-shell.jar"
fi

if [ ! -f "$JAR_PATH" ]; then
  echo "Missing $JAR_PATH. Run: mvn clean package" >&2
  exit 9
fi

exec java -jar "$JAR_PATH" "$@"
