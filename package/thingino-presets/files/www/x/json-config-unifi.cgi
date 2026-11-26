#!/bin/sh

# UniFi Protect mode: the "unifi-protect" settings preset plus readiness checks for native ONVIF adoption.
#   GET                      -> {"enabled": bool, "status": "...", "undo": bool, "checks": [{id,label,ok,detail}],
#                                "adopt": {"host","onvif_port","username","rtsp_main","rtsp_sub"}}
#   POST {"enable": true}    -> apply the unifi-protect preset (reboots when streamer settings change)
#   POST {"enable": false}   -> undo it (only when it is the active preset and an undo point exists)

# shellcheck disable=SC1091 # runtime file, not present in the source tree
. /var/www/x/auth.sh
require_auth

PRESET=/usr/sbin/thingino-preset
ID=unifi-protect
REQ_FILE=""

# shellcheck disable=SC2329 # invoked via trap
cleanup() { [ -n "$REQ_FILE" ] && rm -f "$REQ_FILE"; }
trap cleanup EXIT

json_escape() {
	printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g' | awk 'NR > 1 { printf "\\n" } { printf "%s", $0 }'
}

send_json() {
	printf 'Status: %s\n' "${2:-200 OK}"
	printf 'Content-Type: application/json\nCache-Control: no-store\nPragma: no-cache\nConnection: close\n\n%s\n' "$1"
	exit 0
}

json_error() {
	send_json "{\"error\":{\"code\":${1:-400},\"message\":\"$(json_escape "$2")\"}}" "${3:-400 Bad Request}"
}

rconf() { raptorctl config get "$1" "$2" 2>/dev/null; }

CHECKS="" SEP=""
check() {   # id label ok(0/1) detail
	CHECKS="$CHECKS$SEP{\"id\":\"$1\",\"label\":\"$(json_escape "$2")\",\"ok\":$([ "$3" = 1 ] && echo true || echo false),\"detail\":\"$(json_escape "$4")\"}"
	SEP=","
}

handle_get() {
	status=$($PRESET status 2>/dev/null)
	enabled=false
	case "$status" in "$ID" | "$ID (modified)") enabled=true ;; esac
	undo=false; [ -f /etc/presets/.undo.tar ] && undo=true

	# ONVIF events: Protect subscribes to them for motion
	if pidof onvif_notify_server >/dev/null; then check notify "ONVIF event service running" 1 ""
	else check notify "ONVIF event service running" 0 "onvif_notify_server is not running"; fi

	if jct /etc/onvif.json path '$.events[?(@.topic=="tns1:VideoSource/MotionAlarm")]' --mode values 2>/dev/null | grep -q topic; then
		check topics "Single motion topic" 0 "VideoSource/MotionAlarm is published next to CellMotionDetector; Protect merges them and motion flaps"
	else check topics "Single motion topic" 1 ""; fi

	me=$(rconf motion enabled)
	[ "$me" = "true" ] && check motion "Camera motion detection on" 1 "" || check motion "Camera motion detection on" 0 "[motion] enabled is '${me:-default}'"

	codec=$(rconf audio codec)
	case "$codec" in
	aac) check audio "Audio Protect can play (AAC)" 1 "" ;;
	*) check audio "Audio Protect can play (AAC)" 0 "audio codec is '${codec:-l16 (default)}'; Protect ignores G711/L16" ;;
	esac

	sfps=$(rconf sensor fps); s0fps=$(rconf stream0 fps)
	if [ -n "$s0fps" ] && [ "$sfps" = "$s0fps" ]; then check fps "Sensor and stream frame rates match" 1 "$s0fps fps"
	else check fps "Sensor and stream frame rates match" 0 "sensor ${sfps:-default}, stream ${s0fps:-default}: dropped sensor frames make playback judder"; fi

	# ONVIF mirrors the RTSP login unless onvif.json overrides it; Protect uses one login for both
	ruser=$(rconf rtsp username); ouser=$(jct /etc/onvif.json get server.username 2>/dev/null)
	if [ -z "$ouser" ] || [ "$ouser" = "$ruser" ]; then
		opass=$(jct /etc/onvif.json get server.password 2>/dev/null)
		if [ -z "$opass" ] || [ "$opass" = "$(rconf rtsp password)" ]; then check creds "ONVIF and RTSP use the same login" 1 ""
		else check creds "ONVIF and RTSP use the same login" 0 "onvif.json sets a different password"; fi
	else check creds "ONVIF and RTSP use the same login" 0 "onvif.json user '$ouser' differs from the RTSP user"; fi

	if grep -q "freq_drift_ppm\|stratum" /run/sync_status 2>/dev/null; then check time "Clock synchronised" 1 ""
	else check time "Clock synchronised" 0 "no NTP sync yet; Protect rejects cameras with a wrong clock"; fi

	host=$(ip -4 -o addr show 2>/dev/null | awk '$2 != "lo" {sub(/\/.*/, "", $4); print $4; exit}')
	port=$(rconf rtsp port); [ -n "$port" ] || port=554
	main=$(rconf rtsp endpoint_main); [ -n "$main" ] || main=stream0
	sub=$(rconf rtsp endpoint_sub); [ -n "$sub" ] || sub=stream1
	oport=$(jct /etc/onvif.json get server.port 2>/dev/null); [ -n "$oport" ] || oport=80
	send_json "{\"enabled\":$enabled,\"status\":\"$(json_escape "$status")\",\"undo\":$undo,\"checks\":[$CHECKS],\"adopt\":{\"host\":\"$host\",\"onvif_port\":\"$oport\",\"username\":\"$(json_escape "$ruser")\",\"rtsp_main\":\"rtsp://$host:$port/${main#/}\",\"rtsp_sub\":\"rtsp://$host:$port/${sub#/}\"}}"
}

handle_post() {
	REQ_FILE=$(mktemp /tmp/unifi-req.XXXXXX)
	if [ -n "$CONTENT_LENGTH" ]; then dd bs=1 count="$CONTENT_LENGTH" 2>/dev/null >"$REQ_FILE"; else cat >"$REQ_FILE"; fi
	enable=$(jct "$REQ_FILE" get enable 2>/dev/null)
	case "$enable" in
	true)
		log=$($PRESET apply "$ID" 2>&1) || json_error 500 "$log" "500 Internal Server Error"
		;;
	false)
		case "$($PRESET status 2>/dev/null)" in
		"$ID" | "$ID (modified)") ;;
		*) json_error 409 "UniFi Protect mode is not the active preset; choose another preset under Settings > Presets" "409 Conflict" ;;
		esac
		[ -f /etc/presets/.undo.tar ] || json_error 409 "no undo point; choose another preset under Settings > Presets" "409 Conflict"
		log=$($PRESET undo 2>&1) || json_error 500 "$log" "500 Internal Server Error"
		;;
	*) json_error 400 "send {\"enable\": true|false}" ;;
	esac
	reboot=false; echo "$log" | grep -q "^rebooting" && reboot=true
	send_json "{\"ok\":true,\"reboot\":$reboot,\"log\":\"$(json_escape "$log")\"}"
}

case "$REQUEST_METHOD" in
GET) handle_get ;;
POST) handle_post ;;
*) json_error 405 "method not allowed" "405 Method Not Allowed" ;;
esac
