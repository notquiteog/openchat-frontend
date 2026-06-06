#!/usr/bin/env bash
set -euo pipefail

firebase_options=""
android_google_services=""
ios_google_service_info=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --firebase-options)
      firebase_options="${2:-}"
      shift 2
      ;;
    --android-google-services)
      android_google_services="${2:-}"
      shift 2
      ;;
    --ios-google-service-info)
      ios_google_service_info="${2:-}"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

require_file() {
  local path="$1"
  local label="$2"
  if [ -z "$path" ] || [ ! -s "$path" ]; then
    echo "$label was not decoded; check the matching GitHub secret." >&2
    exit 1
  fi
}

reject_placeholder() {
  local path="$1"
  local label="$2"
  if grep -Eq 'REPLACE_WITH|your-firebase-project-id|000000000000' "$path"; then
    echo "$label still contains placeholder Firebase values." >&2
    exit 1
  fi
}

if [ -n "$firebase_options" ]; then
  require_file "$firebase_options" "FIREBASE_OPTIONS_DART"
  reject_placeholder "$firebase_options" "FIREBASE_OPTIONS_DART"
  grep -q 'FirebaseOptions' "$firebase_options" || {
    echo "FIREBASE_OPTIONS_DART did not decode to firebase_options.dart." >&2
    exit 1
  }
fi

if [ -n "$android_google_services" ]; then
  require_file "$android_google_services" "GOOGLE_SERVICES_JSON"
  reject_placeholder "$android_google_services" "GOOGLE_SERVICES_JSON"
  grep -q '"project_id"' "$android_google_services" || {
    echo "GOOGLE_SERVICES_JSON did not decode to google-services.json." >&2
    exit 1
  }
  grep -Eq '"package_name"[[:space:]]*:[[:space:]]*"com\.openchat\.openchat"' "$android_google_services" || {
    echo "GOOGLE_SERVICES_JSON is not configured for Android package com.openchat.openchat." >&2
    exit 1
  }
fi

if [ -n "$ios_google_service_info" ]; then
  require_file "$ios_google_service_info" "GOOGLE_SERVICE_INFO_PLIST"
  reject_placeholder "$ios_google_service_info" "GOOGLE_SERVICE_INFO_PLIST"
  grep -q '<key>GOOGLE_APP_ID</key>' "$ios_google_service_info" || {
    echo "GOOGLE_SERVICE_INFO_PLIST did not decode to GoogleService-Info.plist." >&2
    exit 1
  }
  tr -d '\n\r\t ' < "$ios_google_service_info" |
    grep -Fq '<key>BUNDLE_ID</key><string>com.openchat.openchat</string>' || {
      echo "GOOGLE_SERVICE_INFO_PLIST is not configured for iOS bundle com.openchat.openchat." >&2
      exit 1
    }
fi
