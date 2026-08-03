#!/bin/sh

set -u

if [ -z "${MOVEIT_SHELL_HOME:-}" ]; then
  printf '%s\n' '{"result":"FAILURE","exitCode":9,"message":"MOVEIT_SHELL_HOME is not set"}'
  exit 9
fi

. "$MOVEIT_SHELL_HOME/lib/common.sh"
. "$MOVEIT_SHELL_HOME/lib/auth.sh"
. "$MOVEIT_SHELL_HOME/lib/task.sh"
. "$MOVEIT_SHELL_HOME/lib/report.sh"

if [ "$#" -lt 5 ]; then
  emit_failure "$EXIT_INVALID_ARGUMENTS" \
    "Expected 5 required arguments: <server> <username> <password|env:VAR> <taskId> <logFile>"
  usage >&2
  exit "$EXIT_INVALID_ARGUMENTS"
fi

SERVER=$1
USERNAME=$2
PASSWORD_SPEC=$3
TASK_ID=$4
LOG_FILE=$5
shift 5

TIMEOUT_SECONDS=3600
POLL_SECONDS=5
CONNECT_TIMEOUT_SECONDS=30
READ_TIMEOUT_SECONDS=60
SERVER_HOST=
INSECURE=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --timeout-seconds=*) TIMEOUT_SECONDS=${1#*=} ;;
    --poll-seconds=*) POLL_SECONDS=${1#*=} ;;
    --connect-timeout-seconds=*) CONNECT_TIMEOUT_SECONDS=${1#*=} ;;
    --read-timeout-seconds=*) READ_TIMEOUT_SECONDS=${1#*=} ;;
    --server-host=*) SERVER_HOST=${1#*=} ;;
    --insecure) INSECURE=1 ;;
    *)
      emit_failure "$EXIT_INVALID_ARGUMENTS" "Unknown option: $1"
      usage >&2
      exit "$EXIT_INVALID_ARGUMENTS"
      ;;
  esac
  shift
done

for _positive_value in "$TIMEOUT_SECONDS" "$POLL_SECONDS" \
  "$CONNECT_TIMEOUT_SECONDS" "$READ_TIMEOUT_SECONDS"; do
  is_positive_integer "$_positive_value" || {
    emit_failure "$EXIT_INVALID_ARGUMENTS" "Timeout and polling options must be positive integers"
    exit "$EXIT_INVALID_ARGUMENTS"
  }
done

case "$TASK_ID" in
  ''|*[!0-9]*)
    emit_failure "$EXIT_INVALID_ARGUMENTS" "taskId must contain digits only"
    exit "$EXIT_INVALID_ARGUMENTS"
    ;;
esac

case "$SERVER" in
  http://*|https://*) BASE_URL=${SERVER%/} ;;
  *) BASE_URL="https://${SERVER%/}" ;;
esac

case "$PASSWORD_SPEC" in
  env:*)
    PASSWORD_ENV_NAME=${PASSWORD_SPEC#env:}
    case "$PASSWORD_ENV_NAME" in
      ''|[0-9]*|*[!A-Za-z0-9_]*)
        emit_failure "$EXIT_INVALID_ARGUMENTS" "Invalid password environment variable name"
        exit "$EXIT_INVALID_ARGUMENTS"
        ;;
    esac
    PASSWORD=$(printenv "$PASSWORD_ENV_NAME") || PASSWORD=
    [ -n "$PASSWORD" ] || {
      emit_failure "$EXIT_INVALID_ARGUMENTS" \
        "Password environment variable is missing or empty: $PASSWORD_ENV_NAME"
      exit "$EXIT_INVALID_ARGUMENTS"
    }
    ;;
  *) PASSWORD=$PASSWORD_SPEC ;;
esac

_log_directory=$(dirname "$LOG_FILE")
mkdir -p "$_log_directory" || {
  emit_failure "$EXIT_INTERNAL_ERROR" "Unable to create log directory: $_log_directory"
  exit "$EXIT_INTERNAL_ERROR"
}
: >> "$LOG_FILE" || {
  emit_failure "$EXIT_INTERNAL_ERROR" "Unable to open log file: $LOG_FILE"
  exit "$EXIT_INTERNAL_ERROR"
}
LOG_READY=1

command -v curl >/dev/null 2>&1 || fatal "$EXIT_INTERNAL_ERROR" \
  "curl is required but was not found"

log_line INFO "========== MOVEit shell task run started =========="
log_line INFO "server=$BASE_URL, taskId=$TASK_ID, timeoutSeconds=$TIMEOUT_SECONDS"
if [ "$INSECURE" -eq 1 ]; then
  log_line WARN "TLS certificate and hostname verification are disabled"
fi

authenticate_moveit
verify_moveit_task
start_moveit_task
wait_for_moveit_result
_runner_exit_code=$?

log_line INFO "Program exit code=$_runner_exit_code"
log_line INFO "========== MOVEit shell task run finished =========="
exit "$_runner_exit_code"
