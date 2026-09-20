#!/bin/sh
exec 2>/dev/null
SD=/mnt/sdcard
SETTINGS=$SD/buddy_settings.ini
CONFIG=/userdata/xhr_config.ini
WEBLOG=$SD/logs/web_access.log
mkdir -p "$SD/logs" "$SD/snapshots"

web_log(){ echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$WEBLOG" 2>/dev/null; }
get_setting(){ VAL=$(grep "^$1=" "$SETTINGS" 2>/dev/null|tail -1|cut -d= -f2-|tr -d '\r'); [ -z "$VAL" ] && VAL=$(grep "^$1=" "$CONFIG" 2>/dev/null|tail -1|cut -d= -f2-|tr -d '\r'); [ -z "$VAL" ] && VAL="$2"; echo "$VAL"; }
get_field(){ echo "$BODY"|tr '&' '\n'|grep "^$1="|head -1|cut -d= -f2-; }
urldecode(){ printf '%b' "$(echo "$1"|sed 's/+/ /g; s/%\([0-9A-Fa-f][0-9A-Fa-f]\)/\\x\1/g')"; }
html_escape(){ echo "$1"|sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g'; }
send_headers(){ printf "HTTP/1.0 %s\r\nContent-Type: %s\r\nConnection: close\r\n\r\n" "$1" "$2"; }
send_redirect(){ printf "HTTP/1.0 302 Found\r\nLocation: %s\r\nConnection: close\r\n\r\n" "$1"; }
update_setting(){ KEY="$1"; VAL="$2"; if grep -q "^${KEY}=" "$SETTINGS" 2>/dev/null; then sed -i "s|^${KEY}=.*|${KEY}=${VAL}|" "$SETTINGS"; else echo "${KEY}=${VAL}" >> "$SETTINGS"; fi; touch /tmp/buddy_settings_changed; }

capture_snapshot(){
  [ -x /tmp/snapshot_grabber ] || return 1
  WAIT=0
  while ! mkdir /tmp/buddy_snapshot.lock 2>/dev/null; do WAIT=$((WAIT+1)); [ "$WAIT" -ge 10 ] && return 1; sleep 1; done
  rm -f /tmp/buddy_snapshot.jpg
  LD_LIBRARY_PATH=/tmp /tmp/snapshot_grabber /tmp/buddy_snapshot.jpg >/tmp/snapshot-grabber.log 2>&1
  RC=$?
  rm -rf /tmp/buddy_snapshot.lock 2>/dev/null
  [ "$RC" -eq 0 ] && [ -f /tmp/buddy_snapshot.jpg ] && [ "$(wc -c < /tmp/buddy_snapshot.jpg 2>/dev/null)" -gt 1000 ]
}

read -r REQUEST_LINE
METHOD=$(echo "$REQUEST_LINE"|cut -d' ' -f1)
REQUEST_URI=$(echo "$REQUEST_LINE"|cut -d' ' -f2)
REQUEST_PATH=$(echo "$REQUEST_URI"|cut -d'?' -f1)
QUERY_STRING=$(echo "$REQUEST_URI"|grep '?'|cut -d'?' -f2-)
CONTENT_LENGTH=0
AUTH_HEADER=""
while IFS= read -r HEADER; do
  HEADER=$(echo "$HEADER"|tr -d '\r'); [ -z "$HEADER" ] && break
  case "$HEADER" in
    Content-Length:*|content-length:*) CONTENT_LENGTH=$(echo "$HEADER"|sed 's/[^0-9]//g');;
    Authorization:*|authorization:*) AUTH_HEADER=$(echo "$HEADER"|cut -d' ' -f3-);;
  esac
done
BODY=""
[ "$METHOD" = "POST" ] && [ "$CONTENT_LENGTH" -gt 0 ] && BODY=$(dd bs=1 count="$CONTENT_LENGTH" 2>/dev/null)

WEB_USER=$(get_setting web_username "")
WEB_PASS=$(get_setting web_password "")
if [ "$REQUEST_PATH" != "/snapshot.jpg" ] && [ -n "$WEB_USER" ]; then
  EXPECTED=$(echo -n "${WEB_USER}:${WEB_PASS}"|uuencode -m - 2>/dev/null|sed -n '2p')
  if [ "$AUTH_HEADER" != "$EXPECTED" ]; then
    printf "HTTP/1.0 401 Unauthorized\r\nWWW-Authenticate: Basic realm=\"Buddy3D Camera\"\r\nContent-Type: text/html\r\nConnection: close\r\n\r\n"
    echo "<html><body><h2>Authentication Required</h2></body></html>"
    exit 0
  fi
fi

html_header(){
  ACTIVE="$1"; TITLE="$2"
  cat <<EOF
<!DOCTYPE html><html><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Buddy3D — $TITLE</title>
<style>*{box-sizing:border-box}body{font-family:sans-serif;background:#1a1a2e;color:#e0e0e0;margin:0}nav{background:#0f0f23;padding:0 12px;display:flex;overflow-x:auto}nav a{color:#778;text-decoration:none;padding:13px 12px}nav a.active{color:#fa6831;border-bottom:2px solid #fa6831}.wrap{max-width:680px;margin:auto;padding:18px 20px}h1{color:#fa6831}.card{background:#16213e;border-radius:8px;padding:16px;margin-bottom:12px}.setting,.svc{display:flex;justify-content:space-between;gap:12px;padding:9px 0;border-bottom:1px solid rgba(255,255,255,.05)}input,select{background:#11182c;border:1px solid #2c3858;color:#ddd;border-radius:5px;padding:7px}.btn{display:inline-block;background:#fa6831;border:0;color:#fff;border-radius:6px;padding:9px 14px;text-decoration:none}.btn-outline{background:transparent;border:1px solid #3c4c70;color:#b8c4dc}.preview-img{width:100%;background:#0b0f18;min-height:180px;object-fit:contain}.note{font-size:.82em;color:#8994aa}.good{color:#72c98f}.warn{color:#e6bf6a}.bad{color:#ef7e7e}.log-list{background:#0d1323;padding:10px;max-height:420px;overflow:auto;font-family:monospace;font-size:.78em}.media-item{display:flex;justify-content:space-between;gap:12px;padding:9px 0;border-bottom:1px solid rgba(255,255,255,.05)}</style></head><body><nav>
EOF
  for PAGE in status capture media settings security logs; do LABEL=$(echo "$PAGE"|cut -c1|tr a-z A-Z)$(echo "$PAGE"|cut -c2-); [ "$PAGE" = "$ACTIVE" ] && echo "<a class=\"active\" href=\"/$PAGE\">$LABEL</a>" || echo "<a href=\"/$PAGE\">$LABEL</a>"; done
  echo '</nav><div class="wrap">'
  [ -f /tmp/buddy_settings_changed ] && echo '<div class="card warn">Some settings require a reboot to apply.</div>'
}
html_footer(){ echo '</div></body></html>'; }

case "$REQUEST_PATH" in
/|/index.html|/status)
  CAMERA_NAME=$(html_escape "$(get_setting camera_name 'Buddy3D Camera')")
  CUR_IP=$(ifconfig wlan0 2>/dev/null|grep 'inet addr'|sed 's/.*addr:\([^ ]*\).*/\1/')
  SSID=$(grep 'ssid=' /tmp/config/wpa_supplicant.conf 2>/dev/null|grep -v scan_ssid|head -1|sed 's/.*ssid="\(.*\)".*/\1/')
  MEM_FREE=$(awk '/MemAvailable/{print $2}' /proc/meminfo 2>/dev/null)
  SD_FREE=$(df -h "$SD" 2>/dev/null|tail -1|awk '{print $4}')
  BC=$(get_setting block_prusa_cloud "1"); BO=$(get_setting block_prusa_ota "1"); TE=$(get_setting debug_telnet_enabled "1")
  send_headers "200 OK" "text/html"; html_header status Status
  cat <<EOF
<h1>$CAMERA_NAME</h1><div class="card"><h2>System</h2><div class="svc"><span>IP</span><span>$CUR_IP</span></div><div class="svc"><span>SSID</span><span>$(html_escape "$SSID")</span></div><div class="svc"><span>Available RAM</span><span>${MEM_FREE:-?} KB</span></div><div class="svc"><span>SD free</span><span>${SD_FREE:-?}</span></div></div>
<div class="card"><h2>Services</h2><div class="svc"><span>RTSP</span><span class="good">rtsp://$CUR_IP/live</span></div><div class="svc"><span>Snapshot</span><span class="good">On-demand</span></div><div class="svc"><span>Prusa Cloud</span><span>$([ "$BC" = 1 ]&&echo Blocked||echo Allowed)</span></div><div class="svc"><span>Prusa OTA</span><span>$([ "$BO" = 1 ]&&echo Blocked||echo Allowed)</span></div><div class="svc"><span>Debug Telnet</span><span>$([ "$TE" = 1 ]&&echo 2323||echo Disabled)</span></div></div>
<div class="card"><div class="note">Warm reboot is disabled: on this camera it can start stock firmware before the SD overlay is available. Use a power cycle when a restart is required.</div></div>
EOF
  html_footer;;
/capture)
  CUR_IP=$(ifconfig wlan0 2>/dev/null|grep 'inet addr'|sed 's/.*addr:\([^ ]*\).*/\1/')
  send_headers "200 OK" "text/html"; html_header capture Capture
  echo "<h1>Capture</h1><div class='card'><img id='preview' class='preview-img' src='/snapshot.jpg?t=$(date +%s)'><p><button class='btn btn-outline' type='button' onclick=\"document.getElementById('preview').src='/snapshot.jpg?t='+Date.now()\">Refresh Preview</button></p><div class='note'>No background JPEG loop. RTSP: rtsp://$CUR_IP/live</div></div><div class='card'><form method='POST' action='/save/snapshot'><button class='btn btn-outline'>Take Snapshot</button></form></div>"
  html_footer;;
/snapshot.jpg)
  if capture_snapshot; then SIZE=$(wc -c < /tmp/buddy_snapshot.jpg); printf "HTTP/1.0 200 OK\r\nContent-Type: image/jpeg\r\nContent-Length: %s\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n" "$SIZE"; cat /tmp/buddy_snapshot.jpg; else send_headers "503 Service Unavailable" "text/plain"; echo "Fresh snapshot unavailable"; fi;;
/save/snapshot)
  if capture_snapshot; then FNAME="$SD/snapshots/$(date +%Y-%m-%d_%H-%M-%S).jpg"; cp /tmp/buddy_snapshot.jpg "$FNAME" && sync; web_log "Snapshot saved: $FNAME"; fi
  send_redirect "/media";;
/media)
  send_headers "200 OK" "text/html"; html_header media Media; echo '<h1>Media</h1><div class="card"><h2>Snapshots</h2>'
  COUNT=0
  for NAME in $(ls -1 "$SD/snapshots/" 2>/dev/null|grep '\.jpg$'|sort -r|head -30); do COUNT=$((COUNT+1)); SAFE=$(html_escape "$NAME"); echo "<div class='media-item'><span>$SAFE</span><span><a href='/file/snapshots/$SAFE'>View</a> <form method='POST' action='/delete/snapshot/$SAFE' style='display:inline'><button>Delete</button></form></span></div>"; done
  [ "$COUNT" -eq 0 ] && echo '<div class="note">No snapshots saved yet.</div>'
  echo '</div>'; html_footer;;
/file/snapshots/*)
  NAME=$(urldecode "$(echo "$REQUEST_PATH"|sed 's|^/file/snapshots/||')"); case "$NAME" in *..*|*/*|"") send_headers "403 Forbidden" "text/plain"; echo Forbidden; exit 0;; esac
  FILE="$SD/snapshots/$NAME"; if [ -f "$FILE" ]; then SIZE=$(wc -c < "$FILE"); printf "HTTP/1.0 200 OK\r\nContent-Type: image/jpeg\r\nContent-Length: %s\r\nConnection: close\r\n\r\n" "$SIZE"; cat "$FILE"; else send_headers "404 Not Found" "text/plain"; echo Not found; fi;;
/delete/snapshot/*)
  NAME=$(urldecode "$(echo "$REQUEST_PATH"|sed 's|^/delete/snapshot/||')"); case "$NAME" in *..*|*/*|"") send_headers "403 Forbidden" "text/plain"; echo Forbidden; exit 0;; esac; rm -f "$SD/snapshots/$NAME"; sync; send_redirect "/media";;
/settings)
  CN=$(html_escape "$(get_setting camera_name 'Buddy3D Camera')"); IR=$(get_setting ir_mode 1); VQ=$(get_setting video_quality 6); VOL=$(get_setting volume 40); BC=$(get_setting block_prusa_cloud 1); BO=$(get_setting block_prusa_ota 1)
  A="";D="";N=""; case "$IR" in 0)D=selected;;2)N=selected;;*)A=selected;;esac; BCH="";[ "$BC" = 1 ]&&BCH=checked; BOH="";[ "$BO" = 1 ]&&BOH=checked
  send_headers "200 OK" "text/html"; html_header settings Settings
  cat <<EOF
<h1>Settings</h1><form method="POST" action="/save/settings"><div class="card"><div class="setting"><label>Camera Name</label><input name="camera_name" value="$CN"></div><div class="setting"><label>Volume</label><input type="range" name="volume" min="0" max="100" value="$VOL"></div><div class="setting"><label>IR mode</label><select name="ir_mode"><option value="1" $A>Auto</option><option value="0" $D>Day</option><option value="2" $N>Night</option></select></div><div class="setting"><label>Video Quality</label><input type="range" name="video_quality" min="1" max="10" value="$VQ"></div></div><div class="card"><div class="setting"><label>Block Prusa Cloud</label><input type="checkbox" name="block_prusa_cloud" value="1" $BCH></div><div class="setting"><label>Block Prusa OTA</label><input type="checkbox" name="block_prusa_ota" value="1" $BOH></div><div class="note">Wi-Fi/DHCP/AP fallback are not managed by this overlay.</div></div><button class="btn">Save Settings</button></form>
EOF
  html_footer;;
/save/settings)
  CN=$(urldecode "$(get_field camera_name)"); [ -n "$CN" ]&&update_setting camera_name "$CN"; update_setting ir_mode "$(get_field ir_mode)"; update_setting video_quality "$(get_field video_quality)"; update_setting volume "$(get_field volume)"; BC=$(get_field block_prusa_cloud); [ -z "$BC" ]&&BC=0; BO=$(get_field block_prusa_ota); [ -z "$BO" ]&&BO=0; update_setting block_prusa_cloud "$BC"; update_setting block_prusa_ota "$BO"; sync; send_redirect "/settings";;
/security)
  U=$(html_escape "$(get_setting web_username '')"); TE=$(get_setting debug_telnet_enabled 1); TCH="";[ "$TE" = 1 ]&&TCH=checked
  send_headers "200 OK" "text/html"; html_header security Security
  echo "<h1>Security</h1><div class='card'><form method='POST' action='/save/webauth'><div class='setting'><label>Username</label><input name='web_username' value='$U'></div><div class='setting'><label>Password</label><input type='password' name='web_password'></div><button class='btn btn-outline'>Save Web Credentials</button></form><div class='note'>LAN/VPN only. /snapshot.jpg remains unauthenticated for Home Assistant.</div></div><div class='card'><form method='POST' action='/save/security'><div class='setting'><label>Debug Telnet :2323</label><input type='checkbox' name='debug_telnet_enabled' value='1' $TCH></div><button class='btn btn-outline'>Save</button></form></div>"
  html_footer;;
/save/webauth)
  update_setting web_username "$(urldecode "$(get_field web_username)")"; update_setting web_password "$(urldecode "$(get_field web_password)")"; sync; send_redirect "/security";;
/save/security)
  TE=$(get_field debug_telnet_enabled); [ -z "$TE" ]&&TE=0; update_setting debug_telnet_enabled "$TE"; sync; send_redirect "/security";;
/logs)
  W=$(echo "$QUERY_STRING"|tr '&' '\n'|grep '^file='|cut -d= -f2); [ -z "$W" ]&&W=boot
  case "$W" in web)LP="$WEBLOG";;snapshot)LP=/tmp/snapshot-grabber.log;;camera)CF=$(ls -1 "$SD/logs/" 2>/dev/null|grep '\.log$'|grep -v buddy_boot|grep -v web_access|sort -r|head -1);LP="$SD/logs/$CF";;*)LP="$SD/logs/buddy_boot.log";;esac
  send_headers "200 OK" "text/html"; html_header logs Logs; echo "<h1>Logs</h1><p><a href='/logs?file=boot'>Boot</a> | <a href='/logs?file=web'>Web</a> | <a href='/logs?file=camera'>Camera</a> | <a href='/logs?file=snapshot'>Snapshot</a></p><div class='log-list'>"
  [ -f "$LP" ] && tail -150 "$LP"|while IFS= read -r L;do echo "<div>$(html_escape "$L")</div>";done || echo "Log not available."
  echo '</div>'; html_footer;;
/network|/save/network|/save/wifi|/save/timelapse|/save/print) send_headers "403 Forbidden" "text/plain"; echo "Disabled in local-only build.";;
/camera|/print|/system) send_redirect "/status";;
/reboot) send_headers "409 Conflict" "text/plain"; echo "Warm reboot disabled. Power-cycle the camera to guarantee the SD overlay loads.";;
/*) send_headers "404 Not Found" "text/plain"; echo "Not found";;
esac
