#!/bin/sh -xe
redis-sentinel /etc/sentinel.conf &
exec redis-server /etc/redis.conf $*
