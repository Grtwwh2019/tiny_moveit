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

SERVER=
USERNAME=
PASSWORD_SPEC=
TASK_ID=
TIMEOUT_SECONDS=
POLL_SECONDS=
POLL_INITIAL_SECONDS=${MOVEIT_POLL_INITIAL_SECONDS:-15}
POLL_INCREMENT_SECONDS=${MOVEIT_POLL_INCREMENT_SECONDS:-5}
POLL_MAX_SECONDS=${MOVEIT_POLL_MAX_SECONDS:-60}
POLL_FIXED_OPTION_SET=0
POLL_PROGRESSIVE_OPTION_SET=0
CONNECT_TIMEOUT_SECONDS=30
READ_TIMEOUT_SECONDS=60
SERVER_HOST=
# The target Solaris environment uses an internal self-signed certificate chain.
# Disable TLS verification by default so existing scheduler arguments do not change.
INSECURE=1

while [ "$#" -gt 0 ]; do
  case "$1" in
    -host:*) SERVER=${1#*:} ;;
    -user:*) USERNAME=${1#*:} ;;
    -password:*) PASSWORD_SPEC=${1#*:} ;;
    -startid:*) TASK_ID=${1#*:} ;;
    -waitsecs:*) TIMEOUT_SECONDS=${1#*:} ;;
    -tf:*) TASK_FILE=${1#*:} ;;
    -sf:*) STEPS_FILE=${1#*:} ;;
    -rf:*) RESPONSE_FILE=${1#*:} ;;
    -df:*) DEBUG_FILE=${1#*:} ;;
    -D:*) DEBUG_LEVEL=${1#*:} ;;
    --timeout-seconds=*) TIMEOUT_SECONDS=${1#*=} ;;
    --poll-seconds=*)
      POLL_SECONDS=${1#*=}
      POLL_FIXED_OPTION_SET=1
      ;;
    --poll-initial-seconds=*)
      POLL_INITIAL_SECONDS=${1#*=}
      POLL_PROGRESSIVE_OPTION_SET=1
      ;;
    --poll-increment-seconds=*)
      POLL_INCREMENT_SECONDS=${1#*=}
      POLL_PROGRESSIVE_OPTION_SET=1
      ;;
    --poll-max-seconds=*)
      POLL_MAX_SECONDS=${1#*=}
      POLL_PROGRESSIVE_OPTION_SET=1
      ;;
    --connect-timeout-seconds=*) CONNECT_TIMEOUT_SECONDS=${1#*=} ;;
    --read-timeout-seconds=*) READ_TIMEOUT_SECONDS=${1#*=} ;;
    --server-host=*) SERVER_HOST=${1#*=} ;;
    --secure) INSECURE=0 ;;
    --insecure) INSECURE=1 ;;
    *)
      emit_failure "$EXIT_INVALID_ARGUMENTS" "Unknown option: $1"
      usage >&2
      exit "$EXIT_INVALID_ARGUMENTS"
      ;;
  esac
  shift
done

for _required_pair in \
  "host:$SERVER" \
  "user:$USERNAME" \
  "password:$PASSWORD_SPEC" \
  "startid:$TASK_ID" \
  "waitsecs:$TIMEOUT_SECONDS" \
  "tf:$TASK_FILE" \
  "sf:$STEPS_FILE" \
  "rf:$RESPONSE_FILE"; do
  _required_name=${_required_pair%%:*}
  _required_value=${_required_pair#*:}
  [ -n "$_required_value" ] || {
    emit_failure "$EXIT_INVALID_ARGUMENTS" "Missing required argument: -${_required_name}:<value>"
    usage >&2
    exit "$EXIT_INVALID_ARGUMENTS"
  }
done

DAT_REP_LOGFILE=$RESPONSE_FILE

if [ "$POLL_FIXED_OPTION_SET" -eq 1 ] && [ "$POLL_PROGRESSIVE_OPTION_SET" -eq 1 ]; then
  emit_failure "$EXIT_INVALID_ARGUMENTS" \
    "--poll-seconds cannot be combined with progressive polling options"
  exit "$EXIT_INVALID_ARGUMENTS"
fi

if [ "$POLL_FIXED_OPTION_SET" -eq 1 ]; then
  POLL_MODE=fixed
  is_positive_integer "$POLL_SECONDS" || {
    emit_failure "$EXIT_INVALID_ARGUMENTS" "--poll-seconds must be a positive integer"
    exit "$EXIT_INVALID_ARGUMENTS"
  }
else
  POLL_MODE=progressive
  for _poll_value in "$POLL_INITIAL_SECONDS" "$POLL_INCREMENT_SECONDS" "$POLL_MAX_SECONDS"; do
    is_positive_integer "$_poll_value" || {
      emit_failure "$EXIT_INVALID_ARGUMENTS" \
        "Progressive polling options and environment variables must be positive integers"
      exit "$EXIT_INVALID_ARGUMENTS"
    }
  done
  [ "$POLL_MAX_SECONDS" -ge "$POLL_INITIAL_SECONDS" ] || {
    emit_failure "$EXIT_INVALID_ARGUMENTS" \
      "Progressive polling maximum must be greater than or equal to the initial interval"
    exit "$EXIT_INVALID_ARGUMENTS"
  }
fi

for _positive_value in "$TIMEOUT_SECONDS" \
  "$CONNECT_TIMEOUT_SECONDS" "$READ_TIMEOUT_SECONDS"; do
  is_positive_integer "$_positive_value" || {
    emit_failure "$EXIT_INVALID_ARGUMENTS" "Timeout options must be positive integers"
    exit "$EXIT_INVALID_ARGUMENTS"
  }
done

is_nonnegative_integer "$DEBUG_LEVEL" || {
  emit_failure "$EXIT_INVALID_ARGUMENTS" "Debug level (-D) must be a non-negative integer"
  exit "$EXIT_INVALID_ARGUMENTS"
}

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

prepare_output_file "$RESPONSE_FILE" response || {
  emit_failure "$EXIT_INTERNAL_ERROR" "Unable to create response file: $RESPONSE_FILE"
  exit "$EXIT_INTERNAL_ERROR"
}
prepare_output_file "$TASK_FILE" task || {
  emit_failure "$EXIT_INTERNAL_ERROR" "Unable to create task result file: $TASK_FILE"
  exit "$EXIT_INTERNAL_ERROR"
}
prepare_output_file "$STEPS_FILE" steps || {
  emit_failure "$EXIT_INTERNAL_ERROR" "Unable to create steps result file: $STEPS_FILE"
  exit "$EXIT_INTERNAL_ERROR"
}

case "$DEBUG_FILE" in
  none|NONE) DEBUG_FILE=none ;;
  *)
    prepare_output_file "$DEBUG_FILE" debug || {
      emit_failure "$EXIT_INTERNAL_ERROR" "Unable to create debug file: $DEBUG_FILE"
      exit "$EXIT_INTERNAL_ERROR"
    }
    LOG_READY=1
    ;;
esac

command -v curl >/dev/null 2>&1 || fatal "$EXIT_INTERNAL_ERROR" \
  "curl is required but was not found"
command -v egrep >/dev/null 2>&1 || fatal "$EXIT_INTERNAL_ERROR" \
  "egrep is required but was not found"

log_line INFO "========== MOVEit shell task run started =========="
log_line INFO "server=$BASE_URL, taskId=$TASK_ID, waitSeconds=$TIMEOUT_SECONDS, debugLevel=$DEBUG_LEVEL"
if [ "$POLL_MODE" = "fixed" ]; then
  log_line INFO "Polling configuration: mode=fixed, interval=${POLL_SECONDS}s"
else
  log_line INFO "Polling configuration: mode=progressive, initial=${POLL_INITIAL_SECONDS}s, increment=${POLL_INCREMENT_SECONDS}s, max=${POLL_MAX_SECONDS}s"
fi
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
