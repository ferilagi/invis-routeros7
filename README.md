# Mikrotik RouterOS in Docker

This extrasmall image was created for **TEST PURPOSE** only!

## How to use

### Create your own `Dockerfile`

List of all available tags is [here](https://hub.docker.com/r/ferilagi/invis-routeros7/tags/),
`latest` will be used by default.

### Use image from docker hub

```bash
docker pull ferilagi/ros7
docker run -d -p 8291:8291 -p 2222:22 -p 28729:8728 -p 28729:8729 -p 5900:5900 -ti ferilagi/ros7
```

### Use in docker-compose.yml

Example is [here](docker-compose.yml).

```yml
version: "3"

services:
  routeros-7:
    image: ferilagi/ros7:latest
    restart: unless-stopped
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun
    ports:
      -  "5900:5900"
      - "8291:8291"
      #- "2222:22"
      #- "28728:8728"
      - "28729:8729"
     environment:
      - MAC_ADDRESS=54:05:AB:54:11:AB
      - ENABLE_VNC=false
```

Now you can connect to your RouterOS container via VNC protocol
(on localhost 5900 port) and via SSH (on localhost 1222 port).

## List of exposed ports

| Description | Ports                             |
| ----------- | --------------------------------- |
| Defaults    | 22, 23, 80, 443, 8291, 8728, 8729 |
| Radius      | 1812/udp, 1813/udp                |
| OpenVPN     | 1194/tcp, 1194/udp                |
| L2TP        | 1701                              |
| PPTP        | 1723                              |

## Links

- https://github.com/joshkunz/qemu-docker
- https://github.com/ennweb/docker-kvm
- https://github.com/evilfreelancer/docker-routeros
