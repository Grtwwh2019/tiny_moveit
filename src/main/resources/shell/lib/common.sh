#!/bin/sh

EXIT_SUCCESS=0
EXIT_INVALID_ARGUMENTS=2
EXIT_AUTHENTICATION_FAILED=3
EXIT_TASK_NOT_FOUND_OR_FORBIDDEN=4
EXIT_TASK_START_FAILED=5
EXIT_TRANSFER_FAILED=6
EXIT_TIMEOUT=7
EXIT_COMMUNICATION_ERROR=8
EXIT_INTERNAL_ERROR=9

LOG_READY=0
RESPONSE_FILE=
DAT_REP_LOGFILE=
TASK_FILE=
STEPS_FILE=
DEBUG_FILE=none
DEBUG_LEVEL=0
TASK_NAME=
NOMINAL_START=
RESULT_END_TIME=
HTTP_SEQUENCE=0
HTTP_BODY=
HTTP_CODE=
HTTP_CURL_ERROR=

usage() {
  printf '%s\n' "Usage: java -jar moveit-task-runner-shell.jar -host:<server> -user:<username> -password:<password|env:VAR> -startid:<taskId> -waitsecs:<seconds> -tf:<task.xml> -sf:<steps.xml> -rf:<response.txt> [-df:<debug.log|none>] [-D:<level>] [--poll-seconds=<seconds> | --poll-initial-seconds=<seconds> --poll-increment-seconds=<seconds> --poll-max-seconds=<seconds>] [--connect-timeout-seconds=<seconds>] [--read-timeout-seconds=<seconds>] [--server-host=<automation-host>] [--secure|--insecure]"
}

one_line() {
  printf '%s' "$1" | tr '\r\n' '  '
}

json_escape() {
  printf '%s' "$1" | awk '
    BEGIN { output = "" }
    {
      if (NR > 1) output = output "\\n"
      for (i = 1; i <= length($0); i++) {
        c = substr($0, i, 1)
        if (c == "\\") output = output "\\\\"
        else if (c == "\"") output = output "\\\""
        else if (c == "\t") output = output "\\t"
        else output = output c
      }
    }
    END { printf "%s", output }
  '
}

json_get_string() {
  printf '%s' "$1" | awk -v wanted_key="$2" '
    { data = data $0 "\n" }
    END {
      target = "\"" wanted_key "\""
      key_at = index(data, target)
      if (!key_at) exit
      rest = substr(data, key_at + length(target))
      colon_at = index(rest, ":")
      if (!colon_at) exit
      rest = substr(rest, colon_at + 1)
      i = 1
      while (i <= length(rest) && substr(rest, i, 1) ~ /[[:space:]]/) i++
      if (substr(rest, i, 1) != "\"") exit
      i++
      output = ""
      escaped = 0
      for (; i <= length(rest); i++) {
        c = substr(rest, i, 1)
        if (escaped) {
          if (c == "n") output = output "\n"
          else if (c == "r") output = output "\r"
          else if (c == "t") output = output "\t"
          else output = output c
          escaped = 0
        } else if (c == "\\") {
          escaped = 1
        } else if (c == "\"") {
          printf "%s", output
          exit
        } else {
          output = output c
        }
      }
    }
  '
}

json_get_number() {
  printf '%s' "$1" | awk -v wanted_key="$2" '
    { data = data $0 "\n" }
    END {
      target = "\"" wanted_key "\""
      key_at = index(data, target)
      if (!key_at) exit
      rest = substr(data, key_at + length(target))
      colon_at = index(rest, ":")
      if (!colon_at) exit
      rest = substr(rest, colon_at + 1)
      i = 1
      while (i <= length(rest) && substr(rest, i, 1) ~ /[[:space:]]/) i++
      output = ""
      for (; i <= length(rest); i++) {
        c = substr(rest, i, 1)
        if (c ~ /[0-9eE+.-]/) output = output c
        else break
      }
      printf "%s", output
    }
  '
}

prepare_output_file() {
  _prepare_path=$1
  _prepare_label=$2
  _prepare_directory=$(dirname "$_prepare_path")
  mkdir -p "$_prepare_directory" || return 1
  : > "$_prepare_path" || return 1
  return 0
}

write_response_file() {
  [ -n "${RESPONSE_FILE:-}" ] || return 0
  _response_code=$1
  _response_description=$(one_line "$2")
  _response_task_name=$(one_line "${TASK_NAME:-}")
  _response_nominal=$(one_line "${NOMINAL_START:-}")
  _response_end=$(one_line "${RESULT_END_TIME:-}")
  {
    printf 'ErrorCode: %s\n' "$_response_code"
    printf 'ErrorDescription: %s\n' "$_response_description"
    printf 'TaskID: %s\n' "${TASK_ID:-}"
    printf 'TaskName: %s\n' "$_response_task_name"
    printf 'NominalStart: %s\n' "$_response_nominal"
    printf 'TimeEnded: %s\n' "$_response_end"
  } > "$RESPONSE_FILE"
}

response_indicates_success() {
  success=`egrep -e 'ErrorCode: 0' "$DAT_REP_LOGFILE"`
  [ -n "$success" ]
}

emit_failure() {
  _emit_failure_code=$1
  _emit_failure_plain=$2
  write_response_file "$_emit_failure_code" "$_emit_failure_plain" || :
  _emit_failure_message=$(json_escape "$_emit_failure_plain")
  printf '{"result":"FAILURE","exitCode":%s,"message":"%s"}\n' \
    "$_emit_failure_code" "$_emit_failure_message"
}

emit_success() {
  write_response_file 0 "" || return 1
  response_indicates_success || return 1
  _emit_success_message=$(json_escape "File transfer succeeded")
  _emit_success_status=$(json_escape "$RESULT_STATUS")
  _emit_success_run_id=$(json_escape "$RESULT_RUN_ID")
  _emit_success_nominal=$(json_escape "$NOMINAL_START")
  printf '{"result":"SUCCESS","exitCode":0,"taskId":"%s","runId":"%s","nominalStart":"%s","status":"%s","statusCode":%s,"filesSent":%s,"totalBytesSent":%s,"message":"%s"}\n' \
    "$TASK_ID" "$_emit_success_run_id" "$_emit_success_nominal" \
    "$_emit_success_status" "$RESULT_STATUS_CODE" "$RESULT_FILES_SENT" \
    "$RESULT_TOTAL_BYTES_SENT" "$_emit_success_message"
  return 0
}

log_line() {
  [ "$LOG_READY" -eq 1 ] || return 0
  _log_level=$1
  case "$_log_level" in
    ERROR) _log_required_level=0 ;;
    WARN) _log_required_level=20 ;;
    INFO) _log_required_level=40 ;;
    DEBUG) _log_required_level=60 ;;
    *) _log_required_level=60 ;;
  esac
  [ "$DEBUG_LEVEL" -ge "$_log_required_level" ] || return 0
  _log_message=$(one_line "$2")
  _log_timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  printf '%s [%s] %s\n' "$_log_timestamp" "$_log_level" "$_log_message" >> "$DEBUG_FILE"
}

fatal() {
  _fatal_code=$1
  _fatal_message=$2
  log_line ERROR "$_fatal_message" || :
  log_line INFO "Program exit code=$_fatal_code" || :
  emit_failure "$_fatal_code" "$_fatal_message"
  exit "$_fatal_code"
}

is_positive_integer() {
  case "$1" in
    ''|*[!0-9]*|0) return 1 ;;
    *) return 0 ;;
  esac
}

is_nonnegative_integer() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

http_execute() {
  HTTP_SEQUENCE=$((HTTP_SEQUENCE + 1))
  log_line DEBUG "HTTP request sequence=$HTTP_SEQUENCE" || :
  _http_body_file="$MOVEIT_SHELL_HOME/http-body.$$.${HTTP_SEQUENCE}"
  _http_error_file="$MOVEIT_SHELL_HOME/http-error.$$.${HTTP_SEQUENCE}"

  set -- --silent --show-error \
    --connect-timeout "$CONNECT_TIMEOUT_SECONDS" \
    --max-time "$READ_TIMEOUT_SECONDS" \
    --output "$_http_body_file" \
    --stderr "$_http_error_file" \
    --write-out '%{http_code}' "$@"

  if [ "$INSECURE" -eq 1 ]; then
    set -- "$@" --insecure
  fi

  HTTP_CODE=$(curl "$@")
  _http_curl_rc=$?
  if [ -f "$_http_body_file" ]; then
    HTTP_BODY=$(cat "$_http_body_file")
  else
    HTTP_BODY=
  fi
  if [ -f "$_http_error_file" ]; then
    HTTP_CURL_ERROR=$(cat "$_http_error_file")
  else
    HTTP_CURL_ERROR=
  fi
  rm -f "$_http_body_file" "$_http_error_file"

  log_line DEBUG "HTTP response sequence=$HTTP_SEQUENCE, status=${HTTP_CODE:-none}, curlExit=$_http_curl_rc" || :

  [ "$_http_curl_rc" -eq 0 ] || return 1
  case "$HTTP_CODE" in
    [0-9][0-9][0-9]) return 0 ;;
    *) HTTP_CURL_ERROR="Invalid HTTP status returned by curl"; return 1 ;;
  esac
}

http_is_success() {
  case "$HTTP_CODE" in
    2[0-9][0-9]) return 0 ;;
    *) return 1 ;;
  esac
}

abbreviate_response() {
  printf '%s' "$1" | tr '\r\n' '  ' | cut -c1-2000
}
