from collections import defaultdict
import os
from os.path import expanduser
import random
import re
import string
import subprocess
import sys
import time
import unittest
import uuid

from testcases import AutopilotPatternTest, WaitTimeoutError, \
     dump_environment_to_file
import requests


class RedisStackTest(AutopilotPatternTest):
    project_name = 'redis'

    def setUp(self):
        if 'COMPOSE_FILE' in os.environ and 'triton' in os.environ['COMPOSE_FILE']:
            account = os.environ['TRITON_ACCOUNT']
            dc = os.environ['TRITON_DC']
            self.consul_cns = 'redis-consul.svc.{}.{}.triton.zone'.format(account, dc)
            self.redis_cns = 'redis.svc.{}.{}.triton.zone'.format(account, dc)
            os.environ['CONSUL'] = self.consul_cns

    def test_redis(self):
        ###############################################
        # scale up
        ###############################################
        self.instrument(self.wait_for_containers,
                        {'redis': 1, 'consul': 1}, timeout=300)
        self.instrument(self.wait_for_service, 'redis', count=1, timeout=300)
        self.instrument(self.wait_for_service, 'redis-sentinel', count=1, timeout=180)

        self.compose_scale('redis', 3)
        self.instrument(self.wait_for_containers,
                        {'redis': 3, 'consul': 1}, timeout=300)
        self.instrument(self.wait_for_service, 'redis', count=1, timeout=180)
        self.instrument(self.wait_for_service, 'redis-replica', count=2, timeout=180)
        self.instrument(self.wait_for_service, 'redis-sentinel', count=3, timeout=180)

        ###############################################
        # manual fail over
        ###############################################
        master_container = self.get_service_instances_from_consul('redis')[0]
        master_ip = self.get_service_addresses_from_consul('redis')[0]

        # force redis sentinel to failover master to a new redis instance
        self.docker_exec(master_container, 'redis-cli -p 26379 sentinel failover mymaster')
        self.instrument(self.wait_for_failover_from, master_ip)

        ###############################################
        # validate replication
        ###############################################
        master_container = self.get_service_instances_from_consul('redis')[0]
        replica_containers = self.get_service_instances_from_consul('redis-replica')
        value = uuid.uuid4()
        self.docker_exec(master_container, 'redis-cli set test:repl ' + str(value))
        for replica in replica_containers:
            self.instrument(self.wait_for_replicated_value, replica, 'test:repl', value)

        ###############################################
        # container destruction fail over
        ###############################################
        # TODO: kill the leader, verify failover
        # this test is failing due to sentinel never electing a new master when
        # the existign master container is stopped; more investigation required
        # self.docker_stop(master_container)
        # self.instrument(self.wait_for_service, 'redis', count=1, timeout=60)
        # self.instrument(self.wait_for_service, 'redis-replica', count=1, timeout=60)

    def wait_for_failover_from(self, from_ip, timeout=30):
        """
        Waits for the IP address of the `redis` service in Consul to change
        from what we knew the IP address to be prior to failing over
        """
        while timeout > 0:
            addresses = self.get_service_addresses_from_consul('redis')
            if (len(addresses) > 0 and addresses[0] != from_ip):
                break
            time.sleep(1)
            timeout -= 1
        else:
            raise WaitTimeoutError("Timed out waiting for redis service to be updated in Consul.")

    def wait_for_replicated_value(self, replica, key, value, timeout=30):
        """
        Waits for the given key/value pair to be written to the given replica
        """
        while timeout > 0:
            replicated_value = self.docker_exec(replica, 'redis-cli get test:repl')
            if (replicated_value.strip('\n') == value):
                break
            time.sleep(1)
            timeout -= 1
        else:
            raise WaitTimeoutError("Timed out waiting for redis replica to receive replicated value.")

    def wait_for_containers(self, expected={}, timeout=30):
        """
        Waits for all containers to be marked as 'Up' for all services.
        `expected` should be a dict of {"service_name": count}.
        TODO: lower this into the base class implementation.
        """
        svc_regex = re.compile(r'^{}_(\w+)_\d+$'.format(self.project_name))

        def get_service_name(container_name):
            return svc_regex.match(container_name).group(1)

        while timeout > 0:
            containers = self.compose_ps()
            found = defaultdict(int)
            states = []
            for container in containers:
                service = get_service_name(container.name)
                found[service] = found[service] + 1
                states.append(container.state == 'Up')
            if all(states):
                if not expected or found == expected:
                    break
            time.sleep(1)
            timeout -= 1
        else:
            raise WaitTimeoutError("Timed out waiting for containers to start.")

if __name__ == "__main__":
    unittest.main()
