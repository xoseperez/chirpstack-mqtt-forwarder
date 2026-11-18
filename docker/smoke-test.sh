#!/usr/bin/env bash

# Checks a built image before it is pushed: the binary runs on the platform, the
# start script renders a complete configuration from environment variables, the
# forwarder accepts that configuration, and it starts at once with the
# semtech_udp backend but waits for concentratord with the concentratord one.
#
#   docker/smoke-test.sh IMAGE PLATFORM

set -euo pipefail

IMAGE=$1
PLATFORM=$2

# --init keeps the tested command from becoming PID 1, which signals sent from
# inside the container (such as the timeouts below) cannot kill.
run() { docker run --rm --init --platform "${PLATFORM}" --network none "$@"; }

fail() { echo "FAIL: $*" >&2; exit 1; }

# The password holds characters that break naive templating: quotes,
# backslashes, "&" and "|".
ENV=(
    -e MQTT_SERVER=tcp://broker.example.com:1883
    -e MQTT_USERNAME=gateway
    -e 'MQTT_PASSWORD=p&ss|"w\rd'
    -e KEEPALIVE_INTERVAL=15
    -e 'BACKEND_FILTER_DEVADDR=0000ff00/24, 00000000/8'
)

echo "== ${PLATFORM}: binary"
run "${IMAGE}" ./chirpstack-mqtt-forwarder -V

echo "== ${PLATFORM}: configuration"
CONFIG=$(run "${ENV[@]}" "${IMAGE}" bash start --render)
echo "${CONFIG}"
if grep -nE '\$\{|\{\{' <<< "${CONFIG}"; then
    fail "placeholders left in the configuration"
fi
for expected in \
    'server="tcp://broker.example.com:1883"' \
    'password="p&ss|\"w\\rd"' \
    'keep_alive_interval="15s"' \
    'dev_addr_prefixes=["0000ff00/24","00000000/8"]' \
    'event_url="ipc:///tmp/concentratord_event"'; do
    grep -qF -- "${expected}" <<< "${CONFIG}" || fail "'${expected}' missing from the configuration"
done

echo "== ${PLATFORM}: forwarder accepts the configuration"
# "configfile" loads the configuration and prints it back without starting
# anything; it prints the password with only its quote escaped.
PARSED=$(run "${ENV[@]}" "${IMAGE}" \
    bash -c 'bash start --render > /dev/null && ./chirpstack-mqtt-forwarder -c run/config.toml configfile') \
    || fail "the forwarder rejected the configuration"
grep -qF -- 'password="p&ss|\"w\rd"' <<< "${PARSED}" || fail "the password did not survive the round trip"
grep -qF -- '"00000000/8",' <<< "${PARSED}" || fail "the DevAddr filters did not survive the round trip"

echo "== ${PLATFORM}: semtech_udp backend starts without concentratord"
OUTPUT=$(run -e BACKEND=semtech_udp "${IMAGE}" timeout -s KILL 10 bash start 2>&1 || true)
echo "${OUTPUT}"
grep -q 'Setting up Semtech UDP packet-forwarder backend' <<< "${OUTPUT}" \
    || fail "the forwarder did not start with the semtech_udp backend"

echo "== ${PLATFORM}: concentratord backend waits for concentratord"
OUTPUT=$(run "${IMAGE}" timeout -s KILL 8 bash start 2>&1 || true)
echo "${OUTPUT}"
grep -q 'Backend: *concentratord' <<< "${OUTPUT}" || fail "the start script did not get to the banner"
if grep -q 'Starting .*(version:' <<< "${OUTPUT}"; then
    fail "the forwarder started before concentratord's socket existed"
fi

echo "== ${PLATFORM}: OK"
