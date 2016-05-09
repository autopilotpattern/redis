#!/bin/sh -xe
redis-sentinel /etc/sentinel.conf &
echo $! > /var/run/sentinel.pid
exec redis-server /etc/redis.conf $*
