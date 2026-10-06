#!/bin/sh
# Development LaunchAgent for a locally built ompd (never the production com.magicelklabs.lantern.ompd agent the app registers).
#
#   scripts/dev-launchagent.sh install <OMPD_HOME> [-- <ompd run arguments>...]
#   scripts/dev-launchagent.sh uninstall
#   scripts/dev-launchagent.sh kickstart
#
# install writes ~/Library/LaunchAgents/com.magicelklabs.lantern.ompd.dev.plist running `<ompd> run <arguments>` with
# OMPD_HOME=<OMPD_HOME> (KeepAlive, RunAtLoad, log in $OMPD_HOME/ompd.log) and bootstraps it into gui/$UID.
# The binary is $OMPD_BINARY, else the ompd of this checkout's debug build.
set -eu

LABEL=com.magicelklabs.lantern.ompd.dev
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"
REPO=$(cd "$(dirname "$0")/.." && pwd)

usage() {
	sed -n '4,6s/^#   //p' "$0" >&2
	exit 2
}

# XML-escapes $1 for a plist <string>.
xml() {
	printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

is_loaded() {
	launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1
}

unload() {
	if is_loaded; then
		launchctl bootout "$DOMAIN/$LABEL"
		# bootout returns before the job is gone; wait for it so a following bootstrap does not race it.
		tries=0
		while is_loaded && [ $tries -lt 100 ]; do
			sleep 0.2
			tries=$((tries + 1))
		done
	fi
}

install() {
	[ $# -ge 1 ] || usage
	home=$1
	shift
	if [ $# -gt 0 ]; then
		[ "$1" = "--" ] || usage
		shift
	fi
	case "$home" in /*) ;; *) home="$(pwd)/$home" ;; esac
	binary=${OMPD_BINARY:-}
	if [ -z "$binary" ]; then
		binary="$(cd "$REPO" && swift build --show-bin-path)/ompd"
	fi
	[ -x "$binary" ] || { echo "no ompd executable at $binary (swift build --product ompd)" >&2; exit 1; }
	mkdir -p "$home"
	chmod 700 "$home"
	mkdir -p "$(dirname "$PLIST")"

	arguments="		<string>$(xml "$binary")</string>
		<string>run</string>"
	for argument in "$@"; do
		arguments="$arguments
		<string>$(xml "$argument")</string>"
	done

	unload
	cat >"$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
$arguments
	</array>
	<key>EnvironmentVariables</key>
	<dict>
		<key>OMPD_HOME</key>
		<string>$(xml "$home")</string>
	</dict>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>ProcessType</key>
	<string>Interactive</string>
	<!-- ompd stops omp by stdin EOF and kills stragglers after 15 s. -->
	<key>ExitTimeOut</key>
	<integer>20</integer>
	<!-- If ompd dies abruptly, its omp children must survive long enough to finish their EOF teardown. -->
	<key>AbandonProcessGroup</key>
	<true/>
	<key>StandardOutPath</key>
	<string>$(xml "$home")/ompd.log</string>
	<key>StandardErrorPath</key>
	<string>$(xml "$home")/ompd.log</string>
</dict>
</plist>
EOF
	plutil -lint "$PLIST" >/dev/null
	launchctl bootstrap "$DOMAIN" "$PLIST"
	echo "installed $LABEL: $binary run $* (OMPD_HOME=$home)"
}

case "${1:-}" in
install)
	shift
	install "$@"
	;;
uninstall)
	unload
	rm -f "$PLIST"
	echo "uninstalled $LABEL"
	;;
kickstart)
	launchctl kickstart -k "$DOMAIN/$LABEL"
	;;
*)
	usage
	;;
esac
