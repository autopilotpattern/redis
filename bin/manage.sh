#!/bin/bash

preStart() {
    logDebug "preStart"

    waitForLeader

    local nodeAddress=$(ifconfig eth0 | awk '/inet addr/ {gsub("addr:", "", $2); print $2}')
    local lockPath=services/redis/locks/master

    local serviceName=$(jq -r '.services[0].name' /etc/containerpilot.json)
    if [[ "${serviceName}" == "redis-replica" ]]; then

        echo "Getting master address"
        local i
        for (( i = 0; i < ${MASTER_WAIT_TIMEOUT-60}; i++ )); do
            getServiceAddresses "redis"
            if [[ ${serviceAddresses} ]]; then
                break
            fi
            sleep 1
        done
        if [[ ! ${serviceAddresses} ]]; then
            echo "No healthy master, trying to set this node as master"

            logDebug "Locking ${lockPath}"
            local session=$(consul-cli --consul="${CONSUL}:8500" kv lock "${lockPath}" --ttl=30s --lock-delay=5s)
            echo ${session} > /var/run/redis-master.sid

            getServiceAddresses "redis"
            if [[ ! ${serviceAddresses} ]]; then
                echo "Still no healthy master, setting this node as master"

                jq '.services[0].name = "redis"' /etc/containerpilot.json  > /etc/containerpilot.json.new
                mv /etc/containerpilot.json.new /etc/containerpilot.json
                kill -HUP 1
            fi

            logDebug "Unlocking ${lockPath}"
            consul-cli --consul="${CONSUL}:8500" kv unlock "${lockPath}" --session="$session"
        fi

    else

        local session=$(< /var/run/redis-master.sid)
        if [[ "$(consul-cli --consul="${CONSUL}:8500" kv lock "${lockPath}" --ttl=30s --session="${session}")" != "${session}" ]]; then
            echo "This node is no longer the master"

            jq '.services[0].name = "redis-replica"' /etc/containerpilot.json  > /etc/containerpilot.json.new
            mv /etc/containerpilot.json.new /etc/containerpilot.json
            kill -HUP 1
        fi

    fi

    if [[ ${serviceAddresses} ]]; then
        echo "Master is ${serviceAddresses}"
    else
        echo "Master is ${nodeAddress} (this node)"
        export MASTER_ADDRESS=${nodeAddress}
    fi
    consul-template -consul=${CONSUL}:8500 -once -template=/etc/redis.conf.tmpl:/etc/redis.conf -template=/etc/sentinel.conf.tmpl:/etc/sentinel.conf
    if [[ $? != 0 ]]; then
        exit 1
    fi
}

health() {
    logDebug "health"
    redis-cli INFO > /dev/null || (err=$? ; echo "redis info failed" ; exit $err)
    redis-cli -p 26379 PING | grep PONG > /dev/null || (echo "sentinel ping failed" ; exit 1)
}

snapshot() {
    echo "snapshot"
    # TODO
}

waitForLeader() {
    logDebug -n "Waiting for consul leader"
    local tries=0
    while true
    do
        logDebug -n "."
        tries=$((tries + 1))
        local leader=$(consul-cli --consul="${CONSUL}:8500" --template="{{.}}" status leader)
        if [[ -n "$leader" ]]; then
            logDebug ""
            break
        elif [[ $tries -eq 60 ]]; then
            logDebug ""
            echo "No consul leader"
            exit 1
        fi
        sleep 1
    done
}

getServiceAddresses() {
    local serviceInfo=$(consul-cli --consul="${CONSUL}:8500" health service --passing "$1")
    serviceAddresses=($(echo $serviceInfo | jq -r '.[].Service.Address'))
    logDebug "serviceAddresses $1 ${serviceAddresses[*]}"
}

logDebug() {
    if [[ -n "$DEBUG" ]]; then
        echo $*
    fi
}

help() {
    echo "Usage: ./manage.sh preStart => first-run configuration"
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
