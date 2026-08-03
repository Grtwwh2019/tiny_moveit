#!/bin/sh

authenticate_moveit() {
  log_line INFO "Connecting to MOVEit Automation Web Admin: $BASE_URL"

  set -- --request POST \
    --url "$BASE_URL/api/v1/token" \
    --header 'Accept: application/json' \
    --header 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode 'grant_type=password' \
    --data-urlencode "username=$USERNAME" \
    --data-urlencode "password=$PASSWORD"

  if [ -n "$SERVER_HOST" ]; then
    set -- "$@" --data-urlencode "server_host=$SERVER_HOST"
  fi

  http_execute "$@" || fatal "$EXIT_AUTHENTICATION_FAILED" \
    "Authentication request failed: $HTTP_CURL_ERROR"
  http_is_success || fatal "$EXIT_AUTHENTICATION_FAILED" \
    "MOVEit authentication failed, HTTP=$HTTP_CODE, response=$(abbreviate_response "$HTTP_BODY")"

  ACCESS_TOKEN=$(json_get_string "$HTTP_BODY" access_token)
  [ -n "$ACCESS_TOKEN" ] || fatal "$EXIT_AUTHENTICATION_FAILED" \
    "Authentication response does not contain access_token"

  log_line INFO "Authentication succeeded, user=$USERNAME"
}
