#!/bin/sh
set -eu
LC_ALL=C

application_seconds=${WARP_SHUTDOWN_GRACE_PERIOD_SECONDS:-25}
container_seconds=${WARP_CONTAINER_STOP_GRACE_PERIOD_SECONDS:-30}

validate_positive_seconds() {
  name=$1
  seconds=$2

  case "$seconds" in
    ''|*[!0-9]*)
      echo "$name must be a positive integer" >&2
      exit 1
      ;;
  esac

}

normalize_decimal() {
  normalized=$1
  while [ "${normalized#0}" != "$normalized" ]; do
    normalized=${normalized#0}
  done
  printf '%s' "$normalized"
}

validate_positive_seconds WARP_SHUTDOWN_GRACE_PERIOD_SECONDS "$application_seconds"
validate_positive_seconds WARP_CONTAINER_STOP_GRACE_PERIOD_SECONDS "$container_seconds"

application_normalized=$(normalize_decimal "$application_seconds")
container_normalized=$(normalize_decimal "$container_seconds")

if [ -z "$application_normalized" ] || [ -z "$container_normalized" ]; then
  echo "shutdown windows must be greater than zero" >&2
  exit 1
fi

if ! awk -v application="$application_normalized" -v container="$container_normalized" \
  'BEGIN {
    valid = length(container) > length(application) ||
      (length(container) == length(application) && "x" container > "x" application)
    exit !valid
  }'; then
  echo "WARP_CONTAINER_STOP_GRACE_PERIOD_SECONDS must be greater than WARP_SHUTDOWN_GRACE_PERIOD_SECONDS" >&2
  exit 1
fi

echo "shutdown windows valid: application=${application_seconds}s container=${container_seconds}s"
