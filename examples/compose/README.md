# Autopilot Pattern Redis on local Docker

To launch redis locally (on Docker for Mac as an example):

```bash
$ docker-compose -p redis up -d
```

To scale it:

```bash
$ docker-compose -p redis scale redis=3
```
