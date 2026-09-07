#!/bin/sh
# Shared shell helpers for kidsfirewall-genrules and kidsfirewall-monitor.
# POSIX/ash only — no bashisms, this runs under busybox ash on the router.

KFW_RUN_DIR="/var/run/kidsfirewall"
KFW_USAGE_DIR="$KFW_RUN_DIR/usage"
KFW_TABLE="kidsfirewall"
KFW_NFT_FILE="$KFW_RUN_DIR/ruleset.nft"
KFW_DNSMASQ_FILE="/tmp/dnsmasq.d/kidsfirewall.conf"

kfw_log() {
	logger -t kidsfirewall "$*"
}

# nft identifiers can't contain '-', '.', ':' etc. Sanitize a UCI section
# name / arbitrary string into something safe to use in set/counter names.
kfw_ident() {
	# printf, not echo: echo's own trailing newline would otherwise get
	# converted into a spurious trailing underscore by tr -c (newline
	# isn't in the allowed set either), corrupting every generated
	# identifier (dest_instagram_, block_instagram_, ...).
	printf '%s' "$1" | tr -c 'a-zA-Z0-9_' '_'
}

kfw_mac_lower() {
	echo "$1" | tr 'A-F' 'a-f'
}

# "HH:MM" -> minutes since midnight (0-1439). No validation beyond what
# UCI/LuCI already enforce on input.
# Prints minutes-since-midnight and returns 0 on a valid "H:MM"/"HH:MM"
# (00-23 : 00-59) string; returns 1 and prints nothing otherwise (empty,
# missing colon, non-numeric, out-of-range hour/minute, ...) so callers
# can skip the rule instead of blowing up $(( )) on garbage input.
kfw_time_to_minutes() {
	case "$1" in
		[0-9]:[0-9][0-9]|[0-9][0-9]:[0-9][0-9]) ;;
		*) return 1 ;;
	esac
	h="${1%%:*}"
	m="${1##*:}"
	h=$((10#$h))
	m=$((10#$m))
	[ "$h" -le 23 ] && [ "$m" -le 59 ] || return 1
	echo $((h * 60 + m))
}

kfw_now_minutes() {
	h=$(date +'%H')
	m=$(date +'%M')
	case "$h" in ''|*[!0-9]*) h=0 ;; esac
	case "$m" in ''|*[!0-9]*) m=0 ;; esac
	echo $((10#$h * 60 + 10#$m))
}

# 1=mon .. 7=sun, matching the 'mon'/'tue'/... tokens used in UCI 'days' lists
kfw_now_dow() {
	date +'%u'
}

kfw_dow_token() {
	case "$1" in
		1) echo mon ;;
		2) echo tue ;;
		3) echo wed ;;
		4) echo thu ;;
		5) echo fri ;;
		6) echo sat ;;
		7) echo sun ;;
	esac
}

# kfw_in_window start_min stop_min now_min -> return 0 if now is inside
# [start,stop), handling windows that wrap past midnight (stop < start).
kfw_in_window() {
	start=$1 stop=$2 now=$3
	if [ "$start" -le "$stop" ]; then
		[ "$now" -ge "$start" ] && [ "$now" -lt "$stop" ]
	else
		[ "$now" -ge "$start" ] || [ "$now" -lt "$stop" ]
	fi
}

kfw_today_stamp() {
	date +'%Y-%m-%d'
}

kfw_week_stamp() {
	# Year + week-of-year (not ISO week numbering, just needs to change
	# once a week — %G/%V aren't reliably supported by musl's strftime),
	# used as the reset boundary for period=weekly
	date +'%Y-%U'
}
