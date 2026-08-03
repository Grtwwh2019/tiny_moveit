#!/bin/sh

query_moveit_result() {
  RESULT_FOUND=0
  _report_nominal=$(json_escape "$NOMINAL_START")
  _report_payload='{"predicate":"TaskID=='"$TASK_ID"';NominalStart==\"'"$_report_nominal"'\";Status=in=(\"Success\",\"Failure\")","orderBy":"!StartTime","maxCount":10}'

  http_execute \
    --request POST \
    --url "$BASE_URL/api/v1/reports/taskruns" \
    --header 'Accept: application/json' \
    --header 'Content-Type: application/json' \
    --header "Authorization: Bearer $ACCESS_TOKEN" \
    --data "$_report_payload" \
    || fatal "$EXIT_COMMUNICATION_ERROR" "Task result request failed: $HTTP_CURL_ERROR"

  http_is_success || fatal "$EXIT_COMMUNICATION_ERROR" \
    "Task result request failed, HTTP=$HTTP_CODE, response=$(abbreviate_response "$HTTP_BODY")"

  RESULT_STATUS=$(json_get_string "$HTTP_BODY" Status)
  [ -n "$RESULT_STATUS" ] || return 0

  RESULT_FOUND=1
  RESULT_STATUS_CODE=$(json_get_number "$HTTP_BODY" StatusCode)
  RESULT_RUN_ID=$(json_get_number "$HTTP_BODY" RunID)
  RESULT_FILES_SENT=$(json_get_number "$HTTP_BODY" FilesSent)
  RESULT_TOTAL_BYTES_SENT=$(json_get_number "$HTTP_BODY" TotalBytesSent)
  RESULT_STATUS_MESSAGE=$(json_get_string "$HTTP_BODY" StatusMsg)

  [ -n "$RESULT_STATUS_CODE" ] || RESULT_STATUS_CODE=-1
  [ -n "$RESULT_RUN_ID" ] || RESULT_RUN_ID=0
  [ -n "$RESULT_FILES_SENT" ] || RESULT_FILES_SENT=0
  [ -n "$RESULT_TOTAL_BYTES_SENT" ] || RESULT_TOTAL_BYTES_SENT=0
}

wait_for_moveit_result() {
  _report_started_at=$(date '+%s')
  _report_deadline=$((_report_started_at + TIMEOUT_SECONDS))
  log_line INFO "Polling final result, timeout=${TIMEOUT_SECONDS}s, interval=${POLL_SECONDS}s"

  while [ "$(date '+%s')" -lt "$_report_deadline" ]; do
    query_moveit_result
    if [ "$RESULT_FOUND" -eq 1 ]; then
      _report_summary="Task finished, status=$RESULT_STATUS, statusCode=$RESULT_STATUS_CODE, runId=$RESULT_RUN_ID, filesSent=$RESULT_FILES_SENT, totalBytesSent=$RESULT_TOTAL_BYTES_SENT"
      if [ -n "$RESULT_STATUS_MESSAGE" ]; then
        _report_summary="$_report_summary, statusMessage=$(one_line "$RESULT_STATUS_MESSAGE")"
      fi

      if [ "$RESULT_STATUS" = "Success" ] && [ "$RESULT_STATUS_CODE" -eq 0 ]; then
        log_line INFO "$_report_summary"
        emit_success
        return 0
      fi

      log_line ERROR "$_report_summary"
      fatal "$EXIT_TRANSFER_FAILED" \
        "MOVEit task failed: ${RESULT_STATUS_MESSAGE:-$RESULT_STATUS}"
    fi
    sleep "$POLL_SECONDS"
  done

  fatal "$EXIT_TIMEOUT" \
    "Timed out waiting for MOVEit task, taskId=$TASK_ID, nominalStart=$NOMINAL_START"
}
