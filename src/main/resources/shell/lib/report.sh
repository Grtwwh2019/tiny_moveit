#!/bin/sh

query_moveit_result() {
  RESULT_FOUND=0
  _report_nominal=$(json_escape "$NOMINAL_START")
  _report_payload='{"predicate":"TaskID=='"$TASK_ID"';NominalStart==\"'"$_report_nominal"'\";Status=in=(\"Success\",\"Failure\")","orderBy":"!StartTime","maxCount":10}'

  authorized_http_execute \
    --request POST \
    --url "$BASE_URL/api/v1/reports/taskruns" \
    --header 'Accept: application/json' \
    --header 'Content-Type: application/json' \
    --data "$_report_payload" \
    || fatal "$EXIT_COMMUNICATION_ERROR" "Task result request failed: $HTTP_CURL_ERROR"

  http_is_success || fatal "$EXIT_COMMUNICATION_ERROR" \
    "Task result request failed, HTTP=$HTTP_CODE, response=$(abbreviate_response "$HTTP_BODY")"

  RESULT_STATUS=$(json_get_string "$HTTP_BODY" Status)
  [ -n "$RESULT_STATUS" ] || return 0

  RESULT_FOUND=1
  _report_task_name=$(json_get_string "$HTTP_BODY" TaskName)
  [ -n "$_report_task_name" ] && TASK_NAME=$_report_task_name
  RESULT_STATUS_CODE=$(json_get_number "$HTTP_BODY" StatusCode)
  RESULT_RUN_ID=$(json_get_number "$HTTP_BODY" RunID)
  RESULT_FILES_SENT=$(json_get_number "$HTTP_BODY" FilesSent)
  RESULT_TOTAL_BYTES_SENT=$(json_get_number "$HTTP_BODY" TotalBytesSent)
  RESULT_STATUS_MESSAGE=$(json_get_string "$HTTP_BODY" StatusMsg)
  RESULT_END_TIME=$(json_get_string "$HTTP_BODY" EndTime)

  [ -n "$RESULT_STATUS_CODE" ] || RESULT_STATUS_CODE=-1
  [ -n "$RESULT_RUN_ID" ] || RESULT_RUN_ID=0
  [ -n "$RESULT_FILES_SENT" ] || RESULT_FILES_SENT=0
  [ -n "$RESULT_TOTAL_BYTES_SENT" ] || RESULT_TOTAL_BYTES_SENT=0
}

write_export_report() {
  _export_type=$1
  _export_path=$2
  _export_order=$3
  _export_max_count=$4
  _export_nominal=$(json_escape "$NOMINAL_START")
  _export_payload='{"type":"'"$_export_type"'","format":"XML","queryInput":{"predicate":"TaskID=='"$TASK_ID"';NominalStart==\"'"$_export_nominal"'\"","orderBy":"'"$_export_order"'","maxCount":'"$_export_max_count"'}}'

  authorized_http_execute \
    --request POST \
    --url "$BASE_URL/api/v1/reports/export" \
    --header 'Accept: application/xml' \
    --header 'Content-Type: application/json' \
    --data "$_export_payload" \
    || fatal "$EXIT_COMMUNICATION_ERROR" \
      "$_export_type report export failed: $HTTP_CURL_ERROR"

  http_is_success || fatal "$EXIT_COMMUNICATION_ERROR" \
    "$_export_type report export failed, HTTP=$HTTP_CODE, response=$(abbreviate_response "$HTTP_BODY")"
  [ -n "$HTTP_BODY" ] || fatal "$EXIT_COMMUNICATION_ERROR" \
    "$_export_type report export returned an empty response"

  printf '%s\n' "$HTTP_BODY" > "$_export_path" || fatal "$EXIT_INTERNAL_ERROR" \
    "Unable to write report file: $_export_path"
}

write_requested_reports() {
  write_export_report TaskRuns "$TASK_FILE" '!StartTime' 10
  write_export_report Activity "$STEPS_FILE" LogStamp 100000
  log_line INFO "Task and step XML reports written"
}

wait_for_moveit_result() {
  _report_elapsed=0
  if [ "$POLL_MODE" = "fixed" ]; then
    _report_interval=$POLL_SECONDS
  else
    _report_interval=$POLL_INITIAL_SECONDS
  fi
  log_line INFO "Polling final result, timeout=${TIMEOUT_SECONDS}s"

  while [ "$_report_elapsed" -lt "$TIMEOUT_SECONDS" ]; do
    query_moveit_result
    if [ "$RESULT_FOUND" -eq 1 ]; then
      write_requested_reports
      _report_summary="Task finished, status=$RESULT_STATUS, statusCode=$RESULT_STATUS_CODE, runId=$RESULT_RUN_ID, filesSent=$RESULT_FILES_SENT, totalBytesSent=$RESULT_TOTAL_BYTES_SENT"
      if [ -n "$RESULT_STATUS_MESSAGE" ]; then
        _report_summary="$_report_summary, statusMessage=$(one_line "$RESULT_STATUS_MESSAGE")"
      fi

      if [ "$RESULT_STATUS" = "Success" ] && [ "$RESULT_STATUS_CODE" -eq 0 ]; then
        log_line INFO "$_report_summary"
        if emit_success; then
          return 0
        fi
        fatal "$EXIT_INTERNAL_ERROR" \
          "Response file does not contain the required success marker: ErrorCode: 0"
      fi

      log_line ERROR "$_report_summary"
      fatal "$EXIT_TRANSFER_FAILED" \
        "MOVEit task failed: ${RESULT_STATUS_MESSAGE:-$RESULT_STATUS}"
    fi

    _report_sleep=$_report_interval
    _report_remaining=$((TIMEOUT_SECONDS - _report_elapsed))
    if [ "$_report_sleep" -gt "$_report_remaining" ]; then
      _report_sleep=$_report_remaining
    fi
    log_line DEBUG "Task result is not final; next check in ${_report_sleep}s"
    sleep "$_report_sleep"
    _report_elapsed=$((_report_elapsed + _report_sleep))
    TOKEN_AGE_SECONDS=$((TOKEN_AGE_SECONDS + _report_sleep))

    if [ "$POLL_MODE" = "progressive" ]; then
      _report_next_interval=$((_report_interval + POLL_INCREMENT_SECONDS))
      if [ "$_report_next_interval" -gt "$POLL_MAX_SECONDS" ]; then
        _report_interval=$POLL_MAX_SECONDS
      else
        _report_interval=$_report_next_interval
      fi
    fi
  done

  fatal "$EXIT_TIMEOUT" \
    "Timed out waiting for MOVEit task, taskId=$TASK_ID, nominalStart=$NOMINAL_START"
}
