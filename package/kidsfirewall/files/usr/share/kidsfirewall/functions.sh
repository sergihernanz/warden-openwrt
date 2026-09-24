#!/bin/sh
# Shared shell helpers for kidsfirewall-genrules and kidsfirewall-monitor.
# POSIX/ash only — no bashisms, this runs under busybox ash on the router.

KFW_RUN_DIR="/var/run/kidsfirewall"
KFW_USAGE_DIR="$KFW_RUN_DIR/usage"
KFW_TABLE="kidsfirewall"
KFW_NFT_FILE="$KFW_RUN_DIR/ruleset.nft"
KFW_DNSMASQ_FILE="/tmp/dnsmasq.d/kidsfirewall.conf"
KFW_SAFE_DNS_STATE_DIR="/etc/kidsfirewall"
KFW_SAFE_DNS_STATE_FILE="$KFW_SAFE_DNS_STATE_DIR/safe_dns.state"
KFW_SAFE_DNS_STATUS_FILE="$KFW_RUN_DIR/safe_dns_status"

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

# Strips a single leading zero (if any) from a 1-2 digit numeric string,
# so it's safe to hand to $(( )) without misparsing as octal ("08"/"09"
# are invalid octal digits and would otherwise blow up the expansion).
# NOT using the "10#$var" base-prefix notation for this: that's a
# bash/ksh arithmetic extension, not POSIX, and busybox ash on OpenWRT
# does NOT implement it -- confirmed directly against the actual shell
# (`ash: arithmetic syntax error` on literally `$((10#08))`) after two
# separate "fixed" versions of this file kept guarding the wrong thing
# (input validity) when the real problem was the syntax itself being
# unsupported regardless of input.
kfw_strip_leading_zero() {
	v="${1#0}"
	[ -n "$v" ] && echo "$v" || echo 0
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
	h=$(kfw_strip_leading_zero "${1%%:*}")
	m=$(kfw_strip_leading_zero "${1##*:}")
	[ "$h" -le 23 ] && [ "$m" -le 59 ] || return 1
	echo $((h * 60 + m))
}

kfw_now_minutes() {
	h=$(date +'%H')
	m=$(date +'%M')
	case "$h" in ''|*[!0-9]*) h=0 ;; esac
	case "$m" in ''|*[!0-9]*) m=0 ;; esac
	h=$(kfw_strip_leading_zero "$h")
	m=$(kfw_strip_leading_zero "$m")
	echo $((h * 60 + m))
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

# One resolver address per line for the given Safe DNS provider, or
# nothing for "off"/unknown. Shared between kidsfirewall-genrules (which
# writes these to dhcp/dnsmasq) and kidsfirewall-monitor (which checks
# whether the live dhcp config still matches). Single source of truth so
# the two can never drift apart from each other.
kfw_safe_dns_servers() {
	case "$1" in
	cleanbrowsing)
		echo "185.228.168.168"
		echo "185.228.169.168"
		echo "2a0d:2a00:1::"
		echo "2a0d:2a00:2::"
		;;
	opendns)
		echo "208.67.222.123"
		echo "208.67.220.123"
		;;
	cloudflare)
		echo "1.1.1.3"
		echo "1.0.0.3"
		echo "2606:4700:4700::1113"
		echo "2606:4700:4700::1003"
		;;
	custom)
		# config_list_foreach, not `uci get ... | while read`: uci get on
		# a list option prints values space-joined on one line on this
		# build rather than one per line (see kidsfirewall-genrules'
		# domain/cidr handling for the bug this caused there).
		kfw_collect_custom_dns() { [ -n "$1" ] && echo "$1"; }
		config_list_foreach global safe_dns_server kfw_collect_custom_dns
		;;
	esac
}
