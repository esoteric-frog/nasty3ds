#!/bin/zsh
# Hostile packets against a real hosted room. The app must stay alive and must not grow.
# It uses a scratch profile (no real save data). It opens a game window for about 20 s.
set -uo pipefail
cd ${0:A:h:h}
GAME=${1:-$(ls ~/Library/Application\ Support/Nasty3DS/games/*.(cci|3ds|cxi|zcci)(N) | head -1)}
[[ -n "$GAME" ]] || { echo "No game file"; exit 1; }
T=$(mktemp -d); E=vendor/azahar/externals/enet
swift build -c release 2>&1 | tail -1
cc -o $T/client Tests/RoomCheck/client.c $E/*.c -I$E/include -DHAS_SOCKLEN_T 2>/dev/null || { echo "client build failed"; exit 1; }
N3_PROFILE=$T/profile N3_ROOM=host .build/release/Nasty3DS "$GAME" >/dev/null 2>&1 &
APP=$!
fail=0
check() { if eval "$1"; then echo "ok    $2"; else echo "FAIL  $2"; fail=1; fi }
rss() { ps -o rss= -p $APP | tr -d ' ' }
for i in {1..40}; do grep -q "local play state=2" $T/profile/core.log 2>/dev/null && break; sleep 0.5; done
check 'grep -q "local play state=2" $T/profile/core.log' "the room is open"
PORT=$(sed -n 's/.*local play: hosting on port \([0-9]*\).*/\1/p' $T/profile/core.log | head -1)
check '[[ -n "$PORT" ]]' "the room port is known ($PORT)"
send() { $T/client $PORT "$1" >/dev/null || { echo "FAIL  the test client did not connect"; fail=1; } }
before=$(rss)
# a Wi-Fi packet from a device that never joined, with a data size field of 1 GB
send 050000000000000000ffffffffffff40000000; sleep 2
after=$(rss)
check '[[ -n "$before" && -n "$after" && $((after - before)) -lt 200000 ]]' "a 1 GB size field from a stranger does not grow the app (grew $(( (after - before) / 1024 )) MB)"
# a packet with no bytes
send ""; sleep 2
check 'kill -0 $APP 2>/dev/null' "a packet with no bytes does not crash the app"
# four silent devices must not hold every place in the room
for i in 1 2 3 4; do HOLD=600 $T/client $PORT ff >/dev/null & done; sleep 5
N3_PROFILE=$T/profile2 N3_ROOM=join:127.0.0.1:$PORT .build/release/Nasty3DS "$GAME" >/dev/null 2>&1 &
APP2=$!
for i in {1..40}; do grep -q "local play state=2" $T/profile2/core.log 2>/dev/null && break; sleep 0.5; done
check 'grep -q "local play state=2 players=2" $T/profile2/core.log' "a real player can join while four silent devices hold connections"
check 'kill -0 $APP 2>/dev/null' "the host app is alive at the end"
kill -TERM $APP $APP2 2>/dev/null; pkill -f "$T/client" 2>/dev/null; wait 2>/dev/null
rm -rf $T
[[ $fail == 0 ]] && echo "PASS: check-room" || { echo "FAILED: check-room"; exit 1; }
