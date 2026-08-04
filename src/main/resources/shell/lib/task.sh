#!/bin/sh

verify_moveit_task() {
  authorized_http_execute \
    --request GET \
    --url "$BASE_URL/api/v1/tasks/$TASK_ID" \
    --header 'Accept: application/json' \
    || fatal "$EXIT_COMMUNICATION_ERROR" "Task lookup failed: $HTTP_CURL_ERROR"

  case "$HTTP_CODE" in
    401)
      fatal "$EXIT_AUTHENTICATION_FAILED" \
        "Authorization failed after access token renewal"
      ;;
    403|404)
      fatal "$EXIT_TASK_NOT_FOUND_OR_FORBIDDEN" \
        "Task does not exist or access is denied, taskId=$TASK_ID, HTTP=$HTTP_CODE"
      ;;
  esac
  http_is_success || fatal "$EXIT_COMMUNICATION_ERROR" \
    "Task lookup failed, HTTP=$HTTP_CODE, response=$(abbreviate_response "$HTTP_BODY")"

  TASK_NAME=$(json_get_string "$HTTP_BODY" Name)
  log_line INFO "Task verified, taskId=$TASK_ID, taskName=${TASK_NAME:-unknown}"
}

start_moveit_task() {
  log_line INFO "Starting task, taskId=$TASK_ID"

  authorized_http_execute \
    --request POST \
    --url "$BASE_URL/api/v1/tasks/$TASK_ID/start" \
    --header 'Accept: application/json' \
    --header 'Content-Type: application/json' \
    --data '{}' \
    || fatal "$EXIT_TASK_START_FAILED" "Task start request failed: $HTTP_CURL_ERROR"

  http_is_success || fatal "$EXIT_TASK_START_FAILED" \
    "MOVEit rejected task start, HTTP=$HTTP_CODE, response=$(abbreviate_response "$HTTP_BODY")"

  NOMINAL_START=$(json_get_string "$HTTP_BODY" nominalStart)
  [ -n "$NOMINAL_START" ] || fatal "$EXIT_TASK_START_FAILED" \
    "Task start response does not contain nominalStart"

  log_line INFO "Task started, nominalStart=$NOMINAL_START"
}
