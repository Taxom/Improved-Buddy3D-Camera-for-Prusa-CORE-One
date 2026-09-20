#!/bin/sh

SD=/mnt/sdcard
SETTINGS=$SD/buddy_settings.ini
CONFIG=/userdata/xhr_config.ini
BACKUP_DIR=$SD/backup
FACTORY_CONFIG=$BACKUP_DIR/xhr_config.ini.factory
HOSTS=/etc/hosts
HOSTS_OVERLAY=/tmp/hosts.buddy3d
LOGFILE=$SD/logs/buddy_boot.log

mkdir -p "$SD/logs" "$BACKUP_DIR" "$SD/snapshots"

log() {
    TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "----")
    echo "${TIMESTAMP} [boot] $*" >> "$LOGFILE"
}

log_err() {
    TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "----")
    echo "${TIMESTAMP} [ERROR] $*" >> "$LOGFILE"
}

get_setting() {
    VAL=$(grep "^$1=" "$SETTINGS" 2>/dev/null | tail -1 | cut -d'=' -f2- | tr -d '\r')
    [ -z "$VAL" ] && VAL="$2"
    echo "$VAL"
}

apply_setting() {
    KEY="$1"
    VAL="$2"
    if grep -q "^${KEY}=" "$CONFIG" 2>/dev/null; then
        sed -i "s|^${KEY}=.*|${KEY}=${VAL}|" "$CONFIG"
    elif grep -q '^\[config\]' "$CONFIG" 2>/dev/null; then
        sed -i "/^\[config\]/a ${KEY}=${VAL}" "$CONFIG"
    fi
}

log "=========================================="
log "Buddy3D local-only overlay starting"
log "=========================================="

# Keep a copy of the camera configuration on the SD card only.
# We intentionally do not create our own persistent backup in /userdata.
if [ ! -f "$FACTORY_CONFIG" ] && [ -f "$CONFIG" ]; then
    cp "$CONFIG" "$FACTORY_CONFIG" && log "Saved initial xhr_config.ini backup to SD card"
fi

# Create local settings on first run.
if [ ! -f "$SETTINGS" ]; then
    cat > "$SETTINGS" << 'EOF'
# Buddy3D Local-Only Settings
# Network association/DHCP remain under the stock firmware.
# This overlay does not provide an AP fallback or manage Wi-Fi credentials.

[config]
rtsp_server_mode=2
video_quality=6
volume=40
ir_mode=1

# Local privacy
block_prusa_cloud=1
block_prusa_ota=1

# Optional local NTP server. Leave blank to keep stock NTP behavior.
# Set this privately in buddy_settings.ini on the SD card.
local_ntp_server=

# Web UI
web_enabled=1
web_username=
web_password=

# Snapshot
snapshot_enabled=1

# Development shell (temporary; disable for normal use)
debug_telnet_enabled=1
debug_telnet_port=2323
EOF
fi

# Apply only camera/application settings that we intentionally manage.
for KEY in rtsp_server_mode video_quality volume ir_mode snapshot_upload_interval camera_name; do
    VAL=$(get_setting "$KEY" "")
    [ -n "$VAL" ] && apply_setting "$KEY" "$VAL"
done

# Always ensure local RTSP stays enabled unless explicitly changed in settings.
RTSP_MODE=$(get_setting rtsp_server_mode "2")
apply_setting rtsp_server_mode "$RTSP_MODE"

# ------------------------------------------------------------
# Non-persistent Prusa service blocking
# ------------------------------------------------------------
# Build an overlay in tmpfs and bind-mount it over /etc/hosts.
# The real rootfs file is never edited. Reboot removes the overlay.
BLOCK_CLOUD=$(get_setting block_prusa_cloud "1")
BLOCK_OTA=$(get_setting block_prusa_ota "1")

if [ "$BLOCK_CLOUD" = "1" ] || [ "$BLOCK_OTA" = "1" ]; then
    if cp "$HOSTS" "$HOSTS_OVERLAY" 2>/dev/null; then
        if [ "$BLOCK_CLOUD" = "1" ]; then
            cat >> "$HOSTS_OVERLAY" << 'EOF'
127.0.0.1 connect.prusa3d.com
127.0.0.1 camera-signaling.prusa3d.com
127.0.0.1 timezone.prusa3d.com
::1 connect.prusa3d.com
::1 camera-signaling.prusa3d.com
::1 timezone.prusa3d.com
EOF
        fi
        if [ "$BLOCK_OTA" = "1" ]; then
            cat >> "$HOSTS_OVERLAY" << 'EOF'
127.0.0.1 connect-ota.prusa3d.com
::1 connect-ota.prusa3d.com
EOF
        fi

        if mount --bind "$HOSTS_OVERLAY" "$HOSTS" 2>/dev/null; then
            log "Applied RAM-only Prusa hosts overlay (cloud=$BLOCK_CLOUD ota=$BLOCK_OTA)"
        else
            log_err "Failed to bind-mount hosts overlay"
        fi
    else
        log_err "Failed to create temporary hosts overlay"
    fi
else
    log "Prusa service blocking disabled"
fi

# ------------------------------------------------------------
# Optional local NTP override
# ------------------------------------------------------------
# If local_ntp_server is set in the private SD-card settings, replace the
# stock pool.ntp.org configuration at runtime. Nothing under /oem is modified.
LOCAL_NTP=$(get_setting local_ntp_server "")
if [ -n "$LOCAL_NTP" ]; then
    cat > /tmp/buddy-ntp.conf << EOF
server $LOCAL_NTP iburst
restrict default nomodify nopeer noquery limited kod
restrict 127.0.0.1
restrict [::1]
EOF

    if [ -x /oem/usr/etc/init.d/S10ntp ]; then
        /oem/usr/etc/init.d/S10ntp stop >/dev/null 2>&1
    else
        [ -f /var/run/ntpd.pid ] && kill "$(cat /var/run/ntpd.pid)" 2>/dev/null
        rm -f /var/run/ntpd.pid
    fi

    if ntpd -g -p /var/run/ntpd.pid -c /tmp/buddy-ntp.conf; then
        log "NTP redirected to configured local server"
    else
        log_err "Failed to start ntpd with configured local server"
    fi
fi

# ------------------------------------------------------------
# Snapshot support
# ------------------------------------------------------------
# snapshot_grabber is invoked on demand by the web handler.
# Nothing continuously JPEG-encodes frames in the background.
SNAPSHOT_ENABLED=$(get_setting snapshot_enabled "1")
if [ "$SNAPSHOT_ENABLED" = "1" ]; then
    if [ -f "$SD/bin/snapshot_grabber" ]; then
        cp "$SD/bin/snapshot_grabber" /tmp/snapshot_grabber 2>/dev/null
        chmod +x /tmp/snapshot_grabber 2>/dev/null
    else
        log_err "snapshot_grabber not found"
    fi

    if [ -f "$SD/bin/libjpeg.so.8" ]; then
        cp "$SD/bin/libjpeg.so.8" /tmp/libjpeg.so.8 2>/dev/null
    else
        log_err "libjpeg.so.8 not found"
    fi
fi

# ------------------------------------------------------------
# Temporary development shell
# ------------------------------------------------------------
DEBUG_TELNET=$(get_setting debug_telnet_enabled "1")
DEBUG_TELNET_PORT=$(get_setting debug_telnet_port "2323")
if [ "$DEBUG_TELNET" = "1" ]; then
    telnetd -p "$DEBUG_TELNET_PORT" -l /bin/sh
    log "Development telnet started on port $DEBUG_TELNET_PORT"
fi

# ------------------------------------------------------------
# Local web UI
# ------------------------------------------------------------
WEB_ENABLED=$(get_setting web_enabled "1")
if [ "$WEB_ENABLED" = "1" ] && [ -f "$SD/web/server.sh" ]; then
    sh "$SD/web/server.sh" &
    log "Web server started (PID $!)"
else
    log "Web server disabled"
fi

# Preserve a current config snapshot on SD for diagnostics/rollback.
cp "$CONFIG" "$SD/xhr_config.ini" 2>/dev/null
sync

# Start the stock Buddy3D application. It continues to own the camera pipeline
# and RTSP encoder exactly as in the stock firmware.
log "Starting stock lp_app"
lp_app --noshell --log2file "$SD/logs"
RC=$?
log_err "lp_app exited unexpectedly (exit code: $RC)"
exit "$RC"
