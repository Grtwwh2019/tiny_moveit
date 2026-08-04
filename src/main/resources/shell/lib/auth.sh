#!/bin/sh

ACCESS_TOKEN=
TOKEN_AGE_SECONDS=0
TOKEN_EXPIRES_IN=30
TOKEN_REFRESH_SECONDS=20

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

  TOKEN_EXPIRES_IN=$(json_get_number "$HTTP_BODY" expires_in)
  is_positive_integer "$TOKEN_EXPIRES_IN" || TOKEN_EXPIRES_IN=30
  if [ "$TOKEN_EXPIRES_IN" -gt 10 ]; then
    TOKEN_REFRESH_SECONDS=$((TOKEN_EXPIRES_IN - 5))
  else
    TOKEN_REFRESH_SECONDS=1
  fi
  TOKEN_AGE_SECONDS=0

  log_line INFO "Authentication succeeded, user=$USERNAME, expiresIn=${TOKEN_EXPIRES_IN}s"
}

ensure_moveit_token() {
  if [ -z "$ACCESS_TOKEN" ] || [ "$TOKEN_AGE_SECONDS" -ge "$TOKEN_REFRESH_SECONDS" ]; then
    log_line INFO "Access token is missing or near expiry; requesting a new token"
    authenticate_moveit
  fi
}

authorized_http_execute() {
  ensure_moveit_token
  http_execute "$@" --header "Authorization: Bearer $ACCESS_TOKEN" || return 1

  if [ "$HTTP_CODE" = "401" ]; then
    log_line WARN "Access token was rejected; requesting a new token and retrying once"
    ACCESS_TOKEN=
    authenticate_moveit
    http_execute "$@" --header "Authorization: Bearer $ACCESS_TOKEN" || return 1
  fi
  return 0
}
