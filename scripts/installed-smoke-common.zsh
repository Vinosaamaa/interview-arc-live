#!/bin/zsh

# Shared installed-bundle gate for the opt-in smoke wrappers. Callers retain
# their product-specific opt-in and helper environment while this function
# owns bundle identity, signature, manifest, and isolated-workspace checks.
_interview_arc_live_smoke_scripts_dir="${${(%):-%N}:A:h}"

interview_arc_live_run_installed_smoke() {
  local helper_name="$1"
  local smoke_directory_prefix="$2"
  shift 2

  case "$helper_name:$smoke_directory_prefix" in
    InterviewArcLiveCodexSmoke:interview-arc-live-codex-smoke|\
    InterviewArcLiveEndpointSmoke:interview-arc-live-endpoint-smoke|\
    InterviewArcLiveSpeechSmoke:interview-arc-live-speech-smoke)
      ;;
    *)
      echo "Refusing an unsupported installed smoke helper." >&2
      return 65
      ;;
  esac

  local bundle_identifier="app.interviewarc.live"
  local app_name="Interview Arc Live.app"
  local installed_app
  local package_manifest

  if [[ $# -eq 2 ]]; then
    installed_app="${1:A}"
    package_manifest="${2:A}"
  elif [[ $# -eq 1 && -d "/Applications/$app_name" ]]; then
    installed_app="/Applications/$app_name"
    package_manifest="${1:A}"
  elif [[ $# -eq 1 \
      && -d "${HOME:?Current user home directory is unavailable.}/Applications/$app_name" ]]; then
    installed_app="${HOME}/Applications/$app_name"
    package_manifest="${1:A}"
  else
    echo "Interview Arc Live is not installed in a standard Applications directory." >&2
    return 66
  fi

  local info_plist="$installed_app/Contents/Info.plist"
  local helper="$installed_app/Contents/Helpers/$helper_name"
  if [[ ! -d "$installed_app" || ! -f "$info_plist" || ! -x "$helper" ]]; then
    echo "The installed Interview Arc Live bundle does not include the requested smoke helper." >&2
    return 66
  fi

  local actual_identifier
  actual_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist")"
  if [[ "$actual_identifier" != "$bundle_identifier" ]]; then
    echo "Refusing to smoke an application that is not Interview Arc Live." >&2
    return 65
  fi
  if ! /usr/bin/codesign --verify --deep --strict "$installed_app" >/dev/null 2>&1; then
    echo "Installed Interview Arc Live signature verification failed." >&2
    return 65
  fi
  "$_interview_arc_live_smoke_scripts_dir/verify-package-manifest.sh" \
    "$installed_app" \
    "$package_manifest" >/dev/null

  local smoke_root
  smoke_root="$(/usr/bin/mktemp -d \
    "${TMPDIR:-/tmp}/${smoke_directory_prefix}.XXXXXX")"
  cleanup_installed_smoke() {
    if [[ -n "${smoke_root:-}" \
        && -d "$smoke_root" \
        && "${smoke_root:t}" == ${smoke_directory_prefix}.* ]]; then
      rm -rf -- "$smoke_root"
    fi
  }
  trap cleanup_installed_smoke EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM

  local repo_root="${_interview_arc_live_smoke_scripts_dir:h}"
  if [[ "${smoke_root:A}" == "${repo_root:A}"/* ]]; then
    echo "Refusing to run the installed smoke inside the source repository." >&2
    return 65
  fi

  cd "$smoke_root"
  local helper_status=0
  if [[ "$helper_name" == "InterviewArcLiveSpeechSmoke" ]]; then
    local helper_stdout="$smoke_root/helper.stdout"
    "$helper" > "$helper_stdout" || helper_status=$?
    if (( helper_status == 0 )); then
      local -a report_keys=(
        model_revision
        chunk_count
        time_to_first_audio_ms
        generation_total_ms
        audio_duration_ms
        audio_bytes
      )
      local report_key report_value
      for report_key in "${report_keys[@]}"; do
        if ! report_value="$(/usr/bin/awk -F= -v requested="$report_key" '
          $1 == requested {
            count += 1
            value = substr($0, length($1) + 2)
          }
          END {
            if (count != 1 || value == "") exit 65
            print value
          }
        ' "$helper_stdout")"; then
          echo "Installed local-speech smoke returned an invalid report." >&2
          helper_status=65
          break
        fi
        print -r -- "$report_key=$report_value"
      done
    fi
  else
    "$helper" || helper_status=$?
  fi
  cleanup_installed_smoke
  trap - EXIT HUP INT TERM
  return "$helper_status"
}
