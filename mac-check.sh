#!/bin/bash
# Used Apple Silicon Mac inspection. Run ON the Mac you're buying:  bash mac-check.sh
# Read-only: changes nothing. Saves a report to the Desktop.
# Flags (used by the Mac Check app): --report-only  print report, no prompts/files
#                                    --screen-test  only open the screen/keyboard/speaker/trackpad page
# Output format (the app parses it): "== Title ==" section, "  [ABOUT] x" section explainer,
# "  [PASS|WARN|FAIL] x" result, "  [TIP] x" advice for the result above, 8-space lines = result details.

HERE=$(cd "$(dirname "$0")" && pwd)

screen_test() { open -a Safari "$HERE/test-page.html"; }
[ "$1" = --screen-test ] && { screen_test; exit 0; }

PASS=0; WARN=0; FAIL=0
ok()    { echo "  [PASS] $*"; PASS=$((PASS+1)); }
warn()  { echo "  [WARN] $*"; WARN=$((WARN+1)); }
bad()   { echo "  [FAIL] $*"; FAIL=$((FAIL+1)); }
tip()   { echo "  [TIP] $*"; }
about() { echo "  [ABOUT] $*"; }
info()  { echo "      $*"; }
list()  { sed 's/^/        /'; }
hdr()   { echo; echo "== $* =="; }
field() { sed -n "s/^ *$1: //p" | head -1; }   # pull "Key: value" from system_profiler text

HW=$(system_profiler SPHardwareDataType 2>/dev/null)
PW=$(system_profiler SPPowerDataType 2>/dev/null)
SERIAL=$(echo "$HW" | field 'Serial Number (system)')
MODEL=$(echo "$HW" | field 'Model Name')
REPORT=~/Desktop/mac-check-${SERIAL:-unknown}-$(date +%Y%m%d-%H%M).txt

if [ "$(id -u)" = 0 ]; then ROOT=1
elif [ "$1" = --report-only ]; then ROOT=0
else
  echo "Some checks (boot security, all profiles) need admin. Enter password or press Ctrl-C at the prompt to skip them."
  sudo -v 2>/dev/null && ROOT=1 || ROOT=0
fi
[ "$1" = --report-only ] && REPORT=/dev/null

{
echo "Mac inspection report — $(date)"

hdr "Identity"
about "What this Mac says it is. Compare model, chip, memory and storage with the seller's listing, and the serial with the one printed on the bottom of the case."
info "Model Name: $MODEL"
echo "$HW" | grep -E 'Model Number|Chip|Memory|Serial Number' | sed 's/^ */      /'
info "macOS: $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
[ "$(uname -m)" = arm64 ] && ok "Apple Silicon (M-series) Mac" || bad "Not an Apple Silicon Mac ($(uname -m))"

hdr "Ownership locks"
about "Locks that would stop you from using the Mac after you buy it. Any red result here is a deal-breaker."
AL=$(echo "$HW" | field 'Activation Lock Status')
if [ "$AL" = Disabled ]; then ok "Activation Lock is off"
else bad "Activation Lock is ON"
     tip "The Mac is still tied to the seller's Apple Account. They must open System Settings › [their name] › Sign Out (or turn off Find My) before you pay. If they can't, it may be stolen."; fi
ENR=$(profiles status -type enrollment 2>&1)
if echo "$ENR" | grep -q 'DEP: Yes'; then bad "Owned by a company or school (DEP)"
     tip "This Mac belongs to an organisation and will lock itself again even after a full erase. Don't buy it."
else ok "Not registered to a company or school"; fi
if echo "$ENR" | grep -q 'MDM enrollment: Yes'; then bad "Remotely managed (MDM)"
     tip "Someone else can control, lock or wipe this Mac over the internet. Don't buy unless the seller removes it and you re-check."
else ok "Not remotely managed"; fi
if [ $ROOT = 1 ]; then
  # asks Apple's servers, so it catches machines registered to an org even after a wipe
  DEP=$(sudo profiles show -type enrollment 2>&1)
  if echo "$DEP" | grep -qiE 'ConfigurationURL|IsMDMUnremovable'; then bad "Apple's records say an organisation owns this serial"
       tip "It will re-lock after an erase. Don't buy it."
  elif echo "$DEP" | grep -qiE '\(null\)|not DEP enabled'; then ok "Apple's records show no organisation owner"
  else warn "Couldn't reach Apple to check organisation ownership"
       tip "Connect to Wi-Fi and run the admin checks again."; fi
  P=$(sudo profiles list -all 2>&1)
  if echo "$P" | grep -q 'no configuration profiles'; then ok "No configuration profiles installed"
  else warn "Configuration profiles are installed"; echo "$P" | list
       tip "Profiles can force settings, VPNs or certificates. Ask the seller what they are; an erase removes them unless the Mac is DEP-registered."; fi
else
  info "Admin checks not run — press “Run with Admin Checks” for 3 more checks"
fi

hdr "Security & tampering"
about "Signs that someone weakened the Mac's built-in protection or installed software to watch or control it."
csrutil status | grep -q enabled && ok "System Integrity Protection is on" \
  || { bad "System Integrity Protection is OFF"; tip "Someone deliberately disabled a core security feature. Ask why, and insist on a full erase before buying."; }
spctl --status 2>/dev/null | grep -q enabled && ok "App security checks (Gatekeeper) are on" \
  || { warn "Gatekeeper is off"; tip "Any app can run without Apple's safety checks. An erase turns it back on."; }
if [ $ROOT = 1 ]; then
  BP=$(sudo bputil -d 2>&1)
  if echo "$BP" | grep -qE 'Security Mode: *Full'; then ok "Startup security is at Full"
  else warn "Startup security is lowered ($(echo "$BP" | sed -nE 's/.*Security Mode: *//p' | head -1))"
       tip "This allows low-level system changes. A full erase via Recovery restores it."; fi
fi
KX=$(kmutil showloaded --list-only 2>/dev/null | grep -v com.apple)
[ -z "$KX" ] && ok "No third-party drivers loaded" \
  || { warn "Third-party drivers (kernel extensions) are loaded"; echo "$KX" | list; tip "Unusual on Apple Silicon. Needs lowered security to load — ask the seller what they are."; }
LD=$(ls /Library/LaunchDaemons /Library/LaunchAgents ~/Library/LaunchAgents 2>/dev/null | grep -v -e '^$' -e ':$' -e '^com.apple')
RA=$(echo "$LD" | grep -iE 'teamviewer|anydesk|rustdesk|splashtop|logmein|screenconnect|connectwise|gotoassist|vnc|remotepc|chrome-remote|prey|absolute|jamf|kandji|mosyle|addigy|hexnode|intune|filewave|airwatch|workspaceone|meshagent')
if [ -n "$RA" ]; then warn "Remote-control or tracking software found"; echo "$RA" | list
     tip "These tools let someone see or control this Mac remotely. Ask the seller to remove them, or erase the Mac before you use it."
else ok "No remote-control or tracking software found ($(echo "$LD" | grep -c .) background helpers from normal apps)"; [ -n "$LD" ] && echo "$LD" | list; fi
OPEN=$(netstat -anv -p tcp 2>/dev/null | awk '/LISTEN/{print $4}' | grep -oE '\.(22|5900|3283)$' | sort -u | tr '\n' ' ')
if [ -z "$OPEN" ]; then ok "Remote login and screen sharing are off"
else warn "Remote access is switched on (ports: ${OPEN//./})"
     tip "22 = Remote Login (SSH), 5900 = Screen Sharing, 3283 = Remote Management. Turn them off in System Settings › General › Sharing."; fi
USERS=$(dscl . list /Users UniqueID | awk '$2>=500 && $1 !~ /^_/ {print $1}')
HIDDEN=$(for u in $USERS; do dscl . read /Users/$u IsHidden 2>/dev/null | grep -q ' 1' && echo $u; done)
ADMINS=$(dscl . read /Groups/admin GroupMembership 2>/dev/null | sed 's/GroupMembership: //; s/root//')
info "Accounts: $(echo $USERS) · Admins: $(echo $ADMINS)"
if [ -n "$HIDDEN" ]; then bad "Hidden user account found: $(echo $HIDDEN)"
     tip "Hidden accounts are a classic way to keep secret access. Insist on a full erase."
elif [ $(echo "$USERS" | grep -c .) -gt 1 ]; then warn "More than one user account"
     tip "Usually harmless (a family member or an app's service account), but after the seller erases the Mac only your account should exist."
else ok "Only one user account"; fi

hdr "Crash history"
about "Whole-Mac crashes (kernel panics) usually point to failing memory, SSD or logic board. Erasing deletes this history, so check it BEFORE the seller erases."
PANICS=$(find /Library/Logs/DiagnosticReports -maxdepth 2 -iname '*panic*' ! -name '.*' 2>/dev/null)
N=$(echo "$PANICS" | grep -c .)
if [ "$N" = 0 ]; then ok "No system crashes recorded"
elif [ "$N" -lt 3 ]; then warn "$N system crash$( [ $N = 1 ] || echo es) recorded"; echo "$PANICS" | xargs -n1 basename | list
     tip "One or two can come from a bad accessory or app. Ask the seller what happened."
else bad "$N system crashes recorded"; echo "$PANICS" | xargs -n1 basename | list
     tip "Repeated crashes are a strong sign of a hardware fault. Run the stress test and Apple Diagnostics, and be ready to walk away."; fi

hdr "Battery & charger"
about "Batteries wear out with use. Apple rates these for 1000 charge cycles; below 80% capacity you'll notice shorter battery life."
CYC=$(echo "$PW" | field 'Cycle Count'); COND=$(echo "$PW" | field 'Condition'); MAXC=$(echo "$PW" | field 'Maximum Capacity')
BI=$(ioreg -rn AppleSmartBattery)
DESIGN=$(echo "$BI" | sed -n 's/.*"DesignCapacity" = //p'); RAW=$(echo "$BI" | sed -n 's/.*"AppleRawMaxCapacity" = //p')
info "Charge cycles: $CYC of 1000"
info "Holds: $MAXC of original (${RAW:-?} of ${DESIGN:-?} mAh)"
[ "$COND" = Normal ] && ok "Battery condition: Normal" \
  || { bad "Battery condition: $COND"; tip "macOS says the battery needs service. Budget for a replacement or negotiate the price down."; }
[ "${MAXC%\%}" -ge 80 ] 2>/dev/null && ok "Battery capacity $MAXC" \
  || { warn "Battery capacity $MAXC"; tip "Below 80% means noticeably shorter battery life. Use it to negotiate."; }
[ "${CYC:-9999}" -lt 500 ] && ok "Cycle count $CYC is fine" \
  || { warn "Cycle count $CYC is high"; tip "Heavily used battery. It still works, but expect to replace it sooner."; }
CH=$(echo "$PW" | sed -n '/AC Charger Information/,/^ *$/p')
CW=$(echo "$CH" | field 'Wattage (W)'); CN=$(echo "$CH" | field 'Name'); CM=$(echo "$CH" | field 'Manufacturer')
if [ -z "$CW" ]; then info "Charger: not connected — plug the seller's charger in and run again"
else info "Charger: ${CN:-unnamed} · ${CW} W · ${CM:-maker not reported}"
  echo "$CN $CM" | grep -qi apple && ok "Genuine Apple charger" \
    || { warn "Charger isn't identified as Apple's"; tip "Not a problem with the Mac itself, but don't pay extra for it. Cheap chargers can charge slowly or damage the port."; }
  if echo "$PW" | grep -q 'Charging: Yes'; then ok "Battery is charging"
  elif echo "$PW" | grep -q 'Fully Charged: Yes'; then ok "Battery is full"
  else warn "Charger is connected but the battery isn't charging"
       tip "Try another port and cable. If it never charges, the port or charging circuit may be faulty."; fi
fi

hdr "Storage (SSD)"
about "SSDs wear out with writing. “Wear” is the drive's own estimate of life used; Apple SSDs usually last well past 100%. Errors or low spare are bad signs."
NV=$(system_profiler SPNVMeDataType 2>/dev/null)
info "Size: $(echo "$NV" | grep -m1 -E '^ *Capacity' | sed 's/^ *Capacity: //; s/ (.*//')"
echo "$NV" | grep -q 'S.M.A.R.T. status: Verified' && ok "Drive health check passed" \
  || { bad "Drive health check failed"; tip "The SSD reports a problem. It is soldered to the board, so replacing it is expensive. Don't buy."; }
SSDW=$HERE/ssdwear; [ -x "$SSDW" ] || SSDW=$HERE/../MacOS/ssdwear   # next to the script, or inside the app
if [ -x "$SSDW" ] && eval "$("$SSDW" | grep -E '^[A-Z_]+=[0-9.]+$')" && [ -n "$PERCENT_USED" ]; then
  info "Data written: $TB_WRITTEN TB · Powered on: $POWER_ON_HOURS hours (~$((POWER_ON_HOURS/24)) days) · Sudden power-offs: $UNSAFE_SHUTDOWNS"
  if [ "$PERCENT_USED" -ge 80 ]; then bad "SSD wear $PERCENT_USED%"; tip "The drive is near the end of its rated life. It is soldered in and costly to replace."
  elif [ "$PERCENT_USED" -ge 20 ]; then warn "SSD wear $PERCENT_USED%"; tip "Heavily written drive (often from low memory swapping). Fine for now, but factor it into the price."
  else ok "SSD wear $PERCENT_USED% (lots of life left)"; fi
  [ "$MEDIA_ERRORS" = 0 ] && ok "No SSD data errors" || { bad "SSD reports $MEDIA_ERRORS data errors"; tip "The drive has failed to read or write data. Don't buy."; }
  [ "$CRITICAL_WARNING" = 0 ] && [ "$SPARE" -ge "$SPARE_THRESHOLD" ] && ok "SSD spare capacity is healthy" \
    || { bad "SSD is raising a critical warning (spare $SPARE%)"; tip "The drive is running out of backup cells. Don't buy."; }
else info "SSD wear details unavailable (ssdwear helper missing)"; fi

hdr "Wireless"
about "Checks the Wi-Fi and Bluetooth chips are present and that Wi-Fi can actually pick up networks (a loose antenna shows the card but finds little)."
AP=$(system_profiler SPAirPortDataType 2>/dev/null)
echo "$AP" | grep -q 'Card Type' && ok "Wi-Fi chip present" || { bad "No Wi-Fi chip found"; tip "Wi-Fi hardware isn't detected. That's a logic board fault."; }
NETS=$(echo "$AP" | grep -c 'PHY Mode')
if echo "$AP" | grep -q 'Status: Off'; then warn "Wi-Fi is turned off"; tip "Turn Wi-Fi on from the menu bar and run again to test the antenna."
elif [ "$NETS" -gt 0 ]; then ok "Wi-Fi can see $NETS network$( [ $NETS = 1 ] || echo s)"
else warn "Wi-Fi sees no networks"; tip "Fine if there are truly none nearby. If your phone sees networks here, the antenna may be damaged."; fi
system_profiler SPBluetoothDataType 2>/dev/null | grep -q 'Chipset' && ok "Bluetooth chip present (use the Bluetooth scan below to test range)" \
  || { bad "No Bluetooth chip found"; tip "Bluetooth hardware isn't detected. That's a logic board fault."; }

hdr "Other parts"
about "Each built-in part should show up. A missing part is dead or disconnected inside."
system_profiler SPDisplaysDataType | grep -E 'Display Type|Resolution' | sed 's/^ */      /'
system_profiler SPCameraDataType | grep -q 'Model ID' && ok "Camera detected" || { bad "No camera found"; tip "The camera or its cable is broken. Expensive display repair."; }
system_profiler SPAudioDataType  | grep -qi 'microphone' && ok "Microphone detected" || warn "No built-in microphone listed"
ioreg -c AppleBiometricSensor 2>/dev/null | grep -q AppleBiometricSensor && ok "Touch ID sensor detected" \
  || { warn "No Touch ID sensor detected"; tip "Fine if this model has no Touch ID. Otherwise the sensor or its cable is faulty."; }

hdr "Summary"
echo "  $PASS pass · $WARN warn · $FAIL fail"
[ $FAIL -gt 0 ] && echo "  >>> Do NOT buy until every FAIL is resolved."
} 2>&1 | tee "$REPORT"

[ "$1" = --report-only ] && exit 0
echo; echo "Report saved: $REPORT"

read -p "Press Enter to open the screen, keyboard, speaker and trackpad test in Safari (Ctrl-C to skip)…" _ || exit 0
screen_test
echo "Also do: Apple Diagnostics (shut down, hold power until 'Loading startup options', then Cmd-D),"
echo "every USB-C/MagSafe port with the charger, and Photo Booth for camera + mic."
