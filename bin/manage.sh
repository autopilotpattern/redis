#!/bin/ash

preStart() {
    # echo "preStart"

    waitForLeader

    local serviceName=$(jq -r '.services[0].name' /etc/containerpilot.json)
    if [[ "${serviceName}" == "redis-replica" ]]; then
        getServiceAddress "redis"
        if [[ "${serviceAddress}" == "null" ]]; then
            echo "No master, trying to set this node as master"

            local session=$(consul-cli --consul="${CONSUL}:8500" kv lock services/redis/locks/master --ttl=30s --lock-delay=5s)

            getServiceAddress "redis"
            if [[ "${serviceAddress}" == "null" ]]; then
                echo "Still no master, setting this node as master"

                jq '.services[0].name = "redis"' /etc/containerpilot.json  > /etc/containerpilot.json.new
                mv /etc/containerpilot.json.new /etc/containerpilot.json
                kill -HUP 1
            else
                echo "Master is ${serviceAddress}"
            fi

            consul-cli --consul="${CONSUL}:8500" kv unlock services/redis/locks/master --session="$session"
        fi
    fi

    local nodeAddress=$(ifconfig eth0 | awk '/inet addr/ {gsub("addr:", "", $2); print $2}')
    NODE_ADDRESS=$nodeAddress consul-template -consul=${CONSUL}:8500 -once -template=/etc/redis.conf.tmpl:/etc/redis.conf -template=/etc/sentinel.conf.tmpl:/etc/sentinel.conf
    if [[ $? != 0 ]]; then
        exit 1
    fi
}

health() {
    # echo "health"
    redis-cli INFO > /dev/null || (err=$? ; echo "redis info failed" ; exit $err)
    redis-cli -p 26379 PING | grep PONG > /dev/null || (echo "sentinel ping failed" ; exit 1)
}

snapshot() {
    echo "snapshot"
    # TODO
}

waitForLeader() {
    local tries=0
    while true
    do
        tries=$((tries + 1))
        local leader=$(consul-cli --consul="${CONSUL}:8500" --template="{{.}}" status leader)
        if [[ -n "$leader" ]]; then
            break
        elif [[ $tries -eq 30 ]]; then
            echo "No consul leader"
            exit 1
        fi
        sleep 2
    done
}

getServiceAddress() {
    serviceAddress=$(consul-cli --consul="${CONSUL}:8500" catalog service "$1" | jq -r '.[0].ServiceAddress')
}

help() {
    echo "Usage: ./manage.sh preStart  => first-run configuration"
    echo "       ./manage.sh health   => health check"
    echo "       ./manage.sh snapshot => save snapshot"
}

if [[ -z ${CONSUL} ]]; then
    echo "Missing CONSUL environment variable"
    exit 1
fi

until
    cmd=$1
    if [[ -z "$cmd" ]]; then
        help
    fi
    shift 1
    $cmd "$@"
    [ "$?" -ne 127 ]
do
    help
    exit
done
