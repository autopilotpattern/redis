# Autopilot Pattern Redis

Redis designed for automated operation using the [Autopilot Pattern](http://autopilotpattern.io/).

[![DockerPulls](https://img.shields.io/docker/pulls/faithlife/redis.svg)](https://registry.hub.docker.com/u/faithlife/redis/)
[![DockerStars](https://img.shields.io/docker/stars/faithlife/redis.svg)](https://registry.hub.docker.com/u/faithlife/redis/)
[![ImageLayers](https://badge.imagelayers.io/faithlife/redis:autopilot.svg)](https://imagelayers.io/?images=faithlife/redis:autopilot)
[![Join the chat at https://gitter.im/autopilotpattern/general](https://badges.gitter.im/autopilotpattern/general.svg)](https://gitter.im/autopilotpattern/general)

---

## Architecture

A running cluster includes the following components:

- [Redis](http://redis.io/): we're using Redis 3.2.
- [Redis Sentinel](http://redis.io/topics/sentinel): manage failover.
- [ContainerPilot](https://www.joyent.com/containerpilot): included in our Redis containers to orchestrate bootstrap behavior and coordinate replication using keys and checks stored in Consul in the `preStart`, `health`, and `backup` handlers.
- [Consul](https://www.consul.io/): is our service catalog that works with ContainerPilot and helps coordinate service discovery, replication, and failover
- [Manta](https://www.joyent.com/object-storage): the Joyent object store, for securely and durably storing our Redis backups.
- `manage.sh`: a small bash script that ContainerPilot will call into to do the heavy lifting of bootstrapping Redis.

When a new Redis node is started, ContainerPilot's `preStart` handler will call into `manage.sh`.


### Bootstrapping via `preStart` handler

`preStart` performs the following:

1. Is this container configured as a replica? If yes:
  1. Wait for the master to become healthy in the service registry.
  1. If there is no healthy master, try to reconfigure as master and restart.
1. Is this container configured as the master? If yes:
  1. Verify this node should still start as master.
  1. If this node shouldn't be master, reconfigure as a replica and restart.
1. Write redis and sentinel configurations based on the master in the service registry or this node if there is no master.
1. Restore the last backup if one exists.

### Maintenance via `health` handler

`health` performs the following:

1. Ping redis, verify the response.
1. Verify the service configuration (master or replica) matches redis's role (master or slave). Sentinel may have performed a failover and changed this node's role. If the role is changed, the service registry needs to be updated so any containers started in the future are configured correctly. If the service configuration and role do not match, reconfigure to match the current role.

`healthSentinel` pings sentinel.

### Backups via `backup` task

ContainerPilot calls the `backup` handler via a recurring task. The backup handler will:

1. Check the backup run TTL health check on the redis service.
1. If the TTL has expired:
  1. Pass the check.
  1. Create a backup.
  1. Upload the backup to Manta.

---

## Running the cluster

Starting a new cluster is easy once you have [your `_env` file set with the configuration details](#configuration), **just run `docker-compose up -d` and in a few moments you'll have a running Redis master**. Both the master and replicas are described as a single `docker-compose` service. During startup, [ContainerPilot](http://containerpilot.io) will ask Consul if an existing master has been created. If not, the node will initialize as a new master and all future nodes will self-configure replication with the master in their `preStart` handler.

**Run `docker-compose scale redis=3` to add replicas**. The replicas will automatically configure themselves to to replicate from the master and will register themselves in Consul as replicas once they're ready. There should be at least 3 nodes to have a quorum in case of a node failure.

### Configuration

Pass these variables via an `_env` file. The included `setup.sh` can be used to test your Docker and Triton environment, and to encode the Manta SSH key in the `_env` file.

- `MANTA_URL`: the full Manta endpoint URL. (ex. `https://us-east.manta.joyent.com`)
- `MANTA_USER`: the Manta account name.
- `MANTA_SUBUSER`: the Manta subuser account name, if any.
- `MANTA_ROLE`: the Manta role name, if any.
- `MANTA_KEY_ID`: the MD5-format ssh key id for the Manta account/subuser (ex. `1a:b8:30:2e:57:ce:59:1d:16:f6:19:97:f2:60:2b:3d`); the included `setup.sh` will encode this automatically
- `MANTA_PRIVATE_KEY`: the private ssh key for the Manta account/subuser; the included `setup.sh` will encode this automatically
- `MANTA_BUCKET`: the path on Manta where backups will be stored. (ex. `/myaccount/stor/manage`); the bucket must already exist and be writeable by the `MANTA_USER`/`MANTA_PRIVATE_KEY`

These variables are optional but you most likely want them:

- `LOG_LEVEL`: will set the logging level of the `manage.sh` script. Set to `DEBUG` for more logging.
- `CONSUL` is the hostname for the Consul instance(s). Defaults to `consul`.

### Where to store data

This pattern automates the data management and makes container effectively stateless to the Docker daemon and schedulers. This is designed to maximize convenience and reliability by minimizing the external coordination needed to manage the database. The use of external volumes (`--volumes-from`, `-v`, etc.) is not recommended.

On Triton, there's no need to use data volumes because the performance hit you normally take with overlay file systems in Linux doesn't happen with ZFS.

### Using an existing database

If you start your Redis container instance with a data directory that already contains a database (specifically, a appendonly.aof file), the pre-existing database won't be changed in any way.
