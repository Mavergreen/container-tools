#!/bin/sh
# platform: macOS-only -- launchctl and open start the menu-bar app and the VM agent as the console user
if [ -z "$ROOT" ]; then
  _uid=$(stat -f %u /dev/console 2>/dev/null)
  if [ -n "$_uid" ] && [ "${_uid:-0}" -gt 0 ]; then
    . "$(dirname "$0")/stop-gui.sh"
    mav_stop_gui_instance 'Contents/MacOS/DockerMenu' "$_uid"
    launchctl asuser "$_uid" open -a "/Applications/Mavericks Container Tools.app" >/dev/null 2>&1 || true
    launchctl asuser "$_uid" load "/Library/LaunchAgents/dev.mavergreen.container-tools-machine.plist" >/dev/null 2>&1 || true
  fi
fi
