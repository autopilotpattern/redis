#!/bin/sh -xe
manage.sh preStart #|| exit $?
if [[ $? != 0 ]]; then
    exit $?
fi
redis-sentinel /etc/sentinel.conf &
echo $! > /var/run/sentinel.pid
exec redis-server /etc/redis.conf $*
