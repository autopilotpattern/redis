#!/bin/bash

preStart() {
    logDebug "preStart"

    waitForLeader

    local nodeAddress=$(ifconfig eth0 | awk '/inet addr/ {gsub("addr:", "", $2); print $2}')
    local lockPath=services/redis/locks/master

    getRegisteredServiceName
    if [[ "${registeredServiceName}" == "redis-replica" ]]; then

        echo "Getting master address"

        if [[ "$(consul-cli --consul="${CONSUL}:8500" health service --passing "redis")" == "true" ]]; then
            # only wait for a healthy service if there is one registered in the catalog
            local i
            for (( i = 0; i < ${MASTER_WAIT_TIMEOUT-60}; i++ )); do
                getServiceAddresses "redis"
                if [[ ${serviceAddresses} ]]; then
                    break
                fi
                sleep 1
            done
        fi

        if [[ ! ${serviceAddresses} ]]; then
            echo "No healthy master, trying to set this node as master"

            logDebug "Locking ${lockPath}"
            local session=$(consul-cli --consul="${CONSUL}:8500" kv lock "${lockPath}" --ttl=30s --lock-delay=5s)
            echo ${session} > /var/run/redis-master.sid

            getServiceAddresses "redis"
            if [[ ! ${serviceAddresses} ]]; then
                echo "Still no healthy master, setting this node as master"

                setRegisteredServiceName "redis"
            fi

            logDebug "Unlocking ${lockPath}"
            consul-cli --consul="${CONSUL}:8500" kv unlock "${lockPath}" --session="$session"
        fi

    else

        local session=$(< /var/run/redis-master.sid)
        if [[ "$(consul-cli --consul="${CONSUL}:8500" kv lock "${lockPath}" --ttl=30s --session="${session}")" != "${session}" ]]; then
            echo "This node is no longer the master"

            setRegisteredServiceName "redis-replica"
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

    echo "$MANTA_PRIVATE_KEY" | tr '#' '\n' > /tmp/mantakey.pem

    restoreFromBackup
}

health() {
    logDebug "health"
    redis-cli PING | grep PONG > /dev/null || (echo "redis ping failed" ; exit 1)

    getRedisInfo
    local role=${redisInfo[role]}
    getRegisteredServiceName
    logDebug "Role ${role}, service ${registeredServiceName}"

    if [[ "${registeredServiceName}" == "redis" ]] && [[ "${role}" != "master" ]]; then
        setRegisteredServiceName "redis-replica"
    elif [[ "${registeredServiceName}" == "redis-replica" ]] && [[ "${role}" != "slave" ]]; then
        setRegisteredServiceName "redis"
    fi
}

healthSentinel() {
    logDebug "healthSentinel"
    redis-cli -p 26379 PING | grep PONG > /dev/null || (echo "sentinel ping failed" ; exit 1)
}

preStop() {
    logDebug "preStop"

    local sentinels=$(redis-cli -p 26379 SENTINEL SENTINELS mymaster | awk '/^ip$/ { getline; print $0 }')
    logDebug "Sentinels to reset: ${sentinels}"
    kill $(cat /var/run/sentinel.pid)

    for sentinel in ${sentinels} ; do
        echo "Resetting sentinel $sentinel"
        redis-cli -h "${sentinel}" -p 26379 SENTINEL RESET "*"
    done
}

backUpIfTime() {
    logDebug "backUpIfTime"

    local backupCheckName=redis-backup-run
    local status=$(consul-cli --consul="${CONSUL}:8500" agent checks | jq -r ".\"${backupCheckName}\".Status")
    logDebug "status $status"
    if [[ "${status}" != "passing" ]]; then
        consul-cli --consul="${CONSUL}:8500" check pass "${backupCheckName}"
        if [[ $? != 0 ]]; then
            consul-cli --consul="${CONSUL}:8500" check register "${backupCheckName}" --ttl=${BACKUP_TTL-24h} || exit 1
            consul-cli --consul="${CONSUL}:8500" check pass "${backupCheckName}" || exit 1
        fi

        saveBackup
    fi
}

saveBackup() {
    logDebug "saveBackup"

    echo "Saving backup"
    local prevLastSave=$(redis-cli LASTSAVE)
    redis-cli BGSAVE || (echo "BGSAVE failed" ; exit 1)

    local tries=0
    while true
    do
        logDebug -n "."
        tries=$((tries + 1))
        local lastSave=$(redis-cli LASTSAVE)
        if [[ "${lastSave}" != "${prevLastSave}" ]]; then
            logDebug ""
            break
        elif [[ $tries -eq 60 ]]; then
            logDebug ""
            echo "Timeout waiting for backup"
            exit 1
        fi
        sleep 1
    done

    local backupFilename=dump-$(date -u +%Y%m%d%H%M%S -d @${lastSave}).rdb.gz
    gzip /data/dump.rdb -c > /data/${backupFilename}

    echo "Uploading ${backupFilename}"
    (manta ${MANTA_BUCKET}/${backupFilename} --upload-file /data/${backupFilename} -H 'content-type: application/gzip; type=file' --fail) || (echo "Backup upload failed" ; exit 1)

    (consul-cli --consul="${CONSUL}:8500" kv write services/redis/last-backup "${backupFilename}") || (echo "Set last backup value failed" ; exit 1)

    # remove the backup files so they don't grow without limit
    rm ${backupFilename}
}

restoreFromBackup() {
    local backupFilename=$(consul-cli --consul="${CONSUL}:8500" kv read --format=text services/redis/last-backup)

    if [[ -n ${backupFilename} ]]; then
        echo "Downloading ${backupFilename}"
        manta ${MANTA_BUCKET}/${backupFilename} | gunzip > /data/dump.rdb
        if [[ ! -s /data/dump.rdb ]]; then
            echo "Backup download failed"
            exit 1
        fi

        redis-server --appendonly no &
        local i
        for (( i = 0; i < 10; i++ )); do
            sleep 0.1
            redis-cli PING | grep PONG > /dev/null && break
        done

        redis-cli CONFIG SET appendonly yes | grep OK > /dev/null || exit 1

        for (( i = 0; i < 600; i++ )); do
            sleep 0.1
            getRedisInfo
            logDebug "aof_rewrite_in_progress ${redisInfo[aof_rewrite_in_progress]}"
            if [[ "${redisInfo[aof_rewrite_in_progress]}" == "0" ]]; then
                break
            fi
        done

        logDebug "Shutting down"
        redis-cli SHUTDOWN || exit 1

        wait
    fi
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

getRegisteredServiceName() {
    registeredServiceName=$(jq -r '.services[0].name' /etc/containerpilot.json)
}

setRegisteredServiceName() {
    jq ".services[0].name = \"$1\"" /etc/containerpilot.json  > /etc/containerpilot.json.new
    mv /etc/containerpilot.json.new /etc/containerpilot.json
    kill -HUP 1
}

declare -A redisInfo
getRedisInfo() {
    eval $(redis-cli INFO | tr -d '\r' | egrep -v '^(#.*)?$' | sed -E 's/^([^:]*):(.*)$/redisInfo[\1]="\2"/')
}

manta() {
    local alg=rsa-sha256
    local keyId=/$MANTA_USER/$MANTA_SUBUSER/keys/$MANTA_KEY_ID
    local now=$(date -u "+%a, %d %h %Y %H:%M:%S GMT")
    local sig=$(echo "date:" $now | \
                tr -d '\n' | \
                openssl dgst -sha256 -sign /tmp/mantakey.pem | \
                openssl enc -e -a | tr -d '\n')

    curl -sS $MANTA_URL"$@" -H "date: $now"  \
        -H "Authorization: Signature keyId=\"$keyId\",algorithm=\"$alg\",signature=\"$sig\""
}

logDebug() {
    if [[ -n "$DEBUG" ]]; then
        echo $*
    fi
}

help() {
    echo "Usage: ./manage.sh preStart       => first-run configuration"
    echo "       ./manage.sh health         => health check Redis"
    echo "       ./manage.sh healthSentinel => health check Sentinel"
    echo "       ./manage.sh preStop        => prepare for stop"
    echo "       ./manage.sh backUpIfTime   => save backup if it is time"
    echo "       ./manage.sh saveBackup     => save backup now"
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
