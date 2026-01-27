#!/bin/sh
# SPDX-FileCopyrightText: 2020 Loetkolben
# SPDX-License-Identifier: MIT
set -eu

# Absolute path to $0's directory, resolving all symlinks in the path

readonly EXEC_DIR="$(cd "$(dirname "$0")"; pwd)"

###
# Config Section
# I belive these are sensible defaults.
# You may override these settings in a file ctlconf.sh in the EXEC_DIR.
# It will be automatically sourced if it exists.
###

# Server directory
SERVER_DIR="$EXEC_DIR/Server"

# Java Config
JAVA_PATH="java"
JAVA_MEM_ARGS="-Xms4G -Xmx6G"
JAVA_OTHER_ARGS="-XX:AOTCache=HytaleServer.aot"

# Minecraft server config
SERVER_JAR="HytaleServer.jar"
SERVER_ARGS="--assets ../Assets.zip --backup --backup-dir backups --backup-frequency 30"

# Server nice adjustment. Increases process niceness by x.
# (Higher niceness = "less" priority)
NICE_ADJ=10

# Name of the screen the server is to be run in
SCREEN_NAME="$(basename "$SERVER_DIR")"

# Server (Java) PID File. Used to check if the server is alive.
SERVER_PID_FILE="$SERVER_DIR/server.pid"

# Screen PID File. Required for systemd.
# If you change this, remember to change the service file as well.
SCREEN_PID_FILE="$SERVER_DIR/screen.pid"


###
# Generic function definitions
###

die() {
  echo "$@"
  exit 1
}

command_exists() {
  command -v "$1" >/dev/null || die "Missing command '$1'"
}

# Check if server is running (something with $SERVER_PID_FILE exists)
serverpid_isrunning() {
	# Check if pid file exists
	[ -e "$SERVER_PID_FILE" ] || return 1

	# Check if a proccess exists at $SERVER_PID_FILE
	ps -p "$(cat "$SERVER_PID_FILE")" > /dev/null || return 1

	return 0
}

screen_isrunning() {
	# Check if pid file exists
	[ -e "$SCREEN_PID_FILE" ] || return 1

	# Check if a screen proccess exists at $SCRREN_PID_FILE
	[ "screen" = "$(ps -o comm= -p "$(cat "$SCREEN_PID_FILE")")" ] || return 1

	return 0
}

die_screennotrunning() {
	if ! screen_isrunning; then
		if serverpid_isrunning; then
			die "Server not running in screen. Cannot control."
		else
			die "Server not running."
		fi
	fi
}

# Runs $0 fg in a screen with the configured name
screen_start() {
	if ! screen_isrunning; then
		# Die also if server is running outside of screen (manual testing or so...)
		serverpid_isrunning && die "Server already running"

		echo "Running '$0' 'fg' in screen $SCREEN_NAME"
		screen -dmS "$SCREEN_NAME" "$0" "fg"
	else
		echo "NOT starting the server: screen pid file exists and corresponding process is running"
		echo "See 'screen -ls' output (our screen pid is '$(cat "$SCREEN_PID_FILE")'):"
		screen -ls
		exit 1
	fi
}

# Requests the server to stop and waits for it to shut down
screen_stop() {
	if screen_isrunning; then
		echo "Requesting server to stop."
		srv_stop

		echo "Waiting for server to terminate..."
		while screen_isrunning; do
			sleep 1
		done

		rm -- "$SCREEN_PID_FILE"
		rm -- "$SERVER_PID_FILE"

		echo "  Server terminated."
	else
		if serverpid_isrunning; then
			die "Connot control. Server is running (something with the servers pid exists), but not in screen."
		else
			die "Cannot stop. Server not running (at all)."
		fi
	fi
}

start_in_fg(){
	cd -- "$SERVER_DIR"

	# Server PID file
	echo $$ > "$SERVER_PID_FILE"

	# Screen PID file (if we are running in a screen)
	if [ "$(ps -p $PPID -o comm=)" = "screen" ]; then
		echo $PPID > "$SCREEN_PID_FILE"
	else
		rm -f -- "$SCREEN_PID_FILE"
	fi

	srv_exec
}


###
# srv_ function definitions
###

# exec's the server (in other words: the server runs with our pid)
srv_exec(){
	# execute server
	# shellcheck disable=2086  # some arguments must be split
    APPLIED_UPDATE=false

    # Apply staged update if present
    if [ -f "updater/staging/Server/HytaleServer.jar" ]; then
        echo "[Launcher] Applying staged update..."
        # Only replace update files, preserve config/saves/mods
        cp -f updater/staging/Server/HytaleServer.jar Server/
        [ -f "updater/staging/Server/HytaleServer.aot" ] && cp -f updater/staging/Server/HytaleServer.aot Server/
        [ -d "updater/staging/Server/Licenses" ] && rm -rf Server/Licenses && cp -r updater/staging/Server/Licenses Server/
        [ -f "updater/staging/Assets.zip" ] && cp -f updater/staging/Assets.zip ./
        [ -f "updater/staging/start.sh" ] && cp -f updater/staging/start.sh ./
        [ -f "updater/staging/start.bat" ] && cp -f updater/staging/start.bat ./
        rm -rf updater/staging
        APPLIED_UPDATE=true
    fi

    START_TIME=$(date +%s)
	exec nice -n $NICE_ADJ "$JAVA_PATH" $JAVA_MEM_ARGS $JAVA_OTHER_ARGS -jar "$SERVER_JAR" $SERVER_ARGS
    EXIT_CODE=$?
    ELAPSED=$(( $(date +%s) - START_TIME ))
}

srv_runcmd() {
	die_screennotrunning
	screen -p 0 -x "$(cat "$SCREEN_PID_FILE")" -X stuff "$*$(printf \\r)"
}

srv_stop(){
	srv_runcmd "stop"
}


###
# "Main"
###

if [ "$#" -ne "1" ]; then
	echo "Give one (and only one) command."
	exit 1
fi

case $1 in
	fg|foreground)
		start_in_fg
		;;

	start|start-screen)
		screen_start
		;;

	stop|stop-screen)
		screen_stop
		;;

	backup)
		backup_main
		;;

	*)
		echo "Invalid commad."
		exit 1
		;;
esac

