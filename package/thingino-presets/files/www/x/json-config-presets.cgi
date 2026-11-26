#!/bin/sh

# Settings presets (thingino-preset) for the web UI.
#   GET                                -> {"status": "...", "active": "...", "undo": bool, "presets": [{id,name,description,source}]}
#   POST {"action":"diff","id":X}      -> {"changes": [{file,key,current,new}], "reboot": bool}
#   POST {"action":"apply","id":X}     -> {"ok": true, "log": "...", "reboot": bool}   (reboots when streamer settings change)
#   POST {"action":"undo"}             -> {"ok": true, "log": "...", "reboot": bool}
#   POST {"action":"save","id":X,"name":Y}

# shellcheck disable=SC1091 # runtime file, not present in the source tree
. /var/www/x/auth.sh
require_auth

PRESET=/usr/sbin/thingino-preset
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

valid_id() { case "$1" in "" | *[!a-z0-9_-]*) return 1 ;; esac; return 0; }

preset_file() {
	for d in /etc/presets /usr/share/thingino/presets; do
		[ -f "$d/$1.json" ] && { echo "$d/$1.json"; return 0; }
	done
	return 1
}

handle_get() {
	out="" sep=""
	tab=$(printf '\t')
	while IFS="$tab" read -r id name src active; do
		f=$(preset_file "$id") || continue
		desc=$(jct "$f" get description 2>/dev/null)
		out="$out$sep{\"id\":\"$(json_escape "$id")\",\"name\":\"$(json_escape "$name")\",\"description\":\"$(json_escape "$desc")\",\"source\":\"$src\",\"active\":$([ "$active" = active ] && echo true || echo false)}"
		sep=","
	done <<EOF
$($PRESET list 2>/dev/null)
EOF
	status=$($PRESET status 2>/dev/null)
	active=$(cat /etc/presets/.active 2>/dev/null)
	undo=false; [ -f /etc/presets/.undo.tar ] && undo=true
	send_json "{\"status\":\"$(json_escape "$status")\",\"active\":\"$(json_escape "$active")\",\"undo\":$undo,\"presets\":[$out]}"
}

handle_post() {
	REQ_FILE=$(mktemp /tmp/presets-req.XXXXXX)
	if [ -n "$CONTENT_LENGTH" ]; then
		dd bs=1 count="$CONTENT_LENGTH" 2>/dev/null >"$REQ_FILE"
	else
		cat >"$REQ_FILE"
	fi
	action=$(jct "$REQ_FILE" get action 2>/dev/null)
	id=$(jct "$REQ_FILE" get id 2>/dev/null)
	case "$action" in
	diff)
		valid_id "$id" || json_error 400 "invalid preset id"
		out="" sep="" reboot=false
		tab=$(printf '\t')
		while IFS="$tab" read -r file key cur new; do
			[ -n "$file" ] || continue
			[ "$file" = raptor ] && reboot=true
			out="$out$sep{\"file\":\"$(json_escape "$file")\",\"key\":\"$(json_escape "$key")\",\"current\":\"$(json_escape "$cur")\",\"new\":\"$(json_escape "$new")\"}"
			sep=","
		done <<EOF
$($PRESET diff "$id" 2>/dev/null)
EOF
		send_json "{\"changes\":[$out],\"reboot\":$reboot}"
		;;
	apply)
		valid_id "$id" || json_error 400 "invalid preset id"
		log=$($PRESET apply "$id" 2>&1) || json_error 500 "$log" "500 Internal Server Error"
		reboot=false; echo "$log" | grep -q "^rebooting" && reboot=true
		send_json "{\"ok\":true,\"reboot\":$reboot,\"log\":\"$(json_escape "$log")\"}"
		;;
	undo)
		log=$($PRESET undo 2>&1) || json_error 400 "$log"
		reboot=false; echo "$log" | grep -q "^rebooting" && reboot=true
		send_json "{\"ok\":true,\"reboot\":$reboot,\"log\":\"$(json_escape "$log")\"}"
		;;
	save)
		valid_id "$id" || json_error 400 "preset id: lowercase letters, digits, - and _ only"
		name=$(jct "$REQ_FILE" get name 2>/dev/null | tr -d '"\\')
		[ -n "$name" ] || name="$id"
		log=$($PRESET save "$id" "$name" 2>&1) || json_error 500 "$log" "500 Internal Server Error"
		send_json "{\"ok\":true,\"log\":\"$(json_escape "$log")\"}"
		;;
	*) json_error 400 "unknown action" ;;
	esac
}

case "$REQUEST_METHOD" in
GET) handle_get ;;
POST) handle_post ;;
*) json_error 405 "method not allowed" "405 Method Not Allowed" ;;
esac
