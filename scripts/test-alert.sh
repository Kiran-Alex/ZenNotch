#!/bin/zsh
# Dev aid: create a real task or meeting a few minutes from now, to watch ZenNotch's
# alerts fire end to end.
#
# Usage:
#   ./scripts/test-alert.sh [minutes] [title]             # Reminders task (default: due in 7 min)
#   ./scripts/test-alert.sh --meeting [minutes] [title]   # Calendar event with a Meet link (default: 7 min)
#   ./scripts/test-alert.sh --meeting-nolink [minutes]    # Calendar event without a link
#   ./scripts/test-alert.sh --cleanup                     # delete every test task and event this made
#
# The first run asks for permission to control Reminders / Calendar (System Settings >
# Privacy & Security > Automation). Test items are named "ZenNotch test: ...".
set -euo pipefail

PREFIX="ZenNotch test"
DOMAIN="site.kiranalex.zennotch"

# Calendar and Reminders reject scripting with -600 ("Application isn't running") until
# they're launched. Start them hidden in the background and wait until they answer.
ensure_running() {
  local app=$1
  if ! pgrep -xq "$app"; then
    open -gj -a "$app"
  fi
  for _ in {1..40}; do
    osascript -e "tell application \"$app\" to get name" >/dev/null 2>&1 && return 0
    sleep 0.25
  done
  echo "$app didn't start; open it once and try again." >&2
  exit 1
}

if [[ "${1:-}" == "--cleanup" ]]; then
  ensure_running Reminders
  ensure_running Calendar
  osascript - "$PREFIX" <<'APPLESCRIPT'
on run argv
  set prefix to item 1 of argv
  set n to 0
  tell application "Reminders"
    set found to (every reminder whose name starts with prefix)
    set n to n + (count of found)
    repeat with r in found
      delete r
    end repeat
  end tell
  tell application "Calendar"
    repeat with c in (every calendar whose writable is true)
      set found to (every event of c whose summary starts with prefix)
      set n to n + (count of found)
      repeat with e in found
        delete e
      end repeat
    end repeat
  end tell
  return "Deleted " & n & " test item(s)."
end run
APPLESCRIPT
  exit 0
fi

# Flags may come anywhere ("--meeting 1" or "1 --meeting"); the rest are minutes and title.
MODE="task"
ARGS=()
for arg in "$@"; do
  case "$arg" in
    --meeting) MODE="meeting" ;;
    --meeting-nolink) MODE="nolink" ;;
    --*) echo "unknown option: $arg" >&2; exit 1 ;;
    *) ARGS+=("$arg") ;;
  esac
done
set -- "${ARGS[@]}"

MINUTES="${1:-7}"
if ! [[ "$MINUTES" =~ ^[0-9]+$ ]] || (( MINUTES < 1 )); then
  echo "minutes must be a whole number of at least 1" >&2
  exit 1
fi

if [[ "$MODE" == "task" ]]; then
  TITLE="$PREFIX: ${2:-Prep slides for design review}"
  LEAD=$(defaults read "$DOMAIN" taskAlertLeadMinutes 2>/dev/null || echo 5)
  ensure_running Reminders
  osascript - "$TITLE" "$MINUTES" <<'APPLESCRIPT'
on run argv
  set t to item 1 of argv
  set mins to (item 2 of argv) as integer
  -- Whole minute, so the alert lands on :00 seconds.
  set d to (current date) + mins * minutes
  set seconds of d to 0
  tell application "Reminders"
    make new reminder in default list with properties {name:t, due date:d}
  end tell
  return "Created task \"" & t & "\" due " & (time string of d)
end run
APPLESCRIPT
  echo "Heads-up should appear about $LEAD min before that (if enabled and still ahead)."
else
  TITLE="$PREFIX: ${2:-Team standup}"
  LINK=""
  [[ "$MODE" == "meeting" ]] && LINK="https://meet.google.com/abc-defg-hij"
  LEAD=$(defaults read "$DOMAIN" meetingAlertLeadMinutes 2>/dev/null || echo 5)
  ensure_running Calendar
  osascript - "$TITLE" "$MINUTES" "$LINK" <<'APPLESCRIPT'
on run argv
  set t to item 1 of argv
  set mins to (item 2 of argv) as integer
  set link to item 3 of argv
  set d to (current date) + mins * minutes
  set seconds of d to 0
  tell application "Calendar"
    set cals to (every calendar whose writable is true)
    if (count of cals) is 0 then error "No writable calendar found."
    set c to item 1 of cals
    set e to make new event at end of events of c with properties {summary:t, start date:d, end date:d + 30 * minutes}
    if link is not "" then set url of e to link
    set calName to name of c
  end tell
  return "Created event \"" & t & "\" in " & calName & " at " & (time string of d)
end run
APPLESCRIPT
  echo "\"Starts in\" card should appear about $LEAD min before that, then \"Starting now\" at the start."
  if [[ "$MODE" == "nolink" ]]; then
    echo "No link: you only get alerts if \"Also alert for events without a meeting link\" is on."
  fi
fi
echo "Clean up afterwards with: ./scripts/test-alert.sh --cleanup"
