FROM redis:3-alpine

RUN apk add --no-cache curl jq openssl tar bash

# Add ContainerPilot and set its configuration file path
ENV CONTAINERPILOT_VER 2.4.1
ENV CONTAINERPILOT file:///etc/containerpilot.json
RUN export CONTAINERPILOT_CHECKSUM=198d96c8d7bfafb1ab6df96653c29701510b833c \
    && curl -Lso /tmp/containerpilot.tar.gz \
        "https://github.com/joyent/containerpilot/releases/download/${CONTAINERPILOT_VER}/containerpilot-${CONTAINERPILOT_VER}.tar.gz" \
    && echo "${CONTAINERPILOT_CHECKSUM}  /tmp/containerpilot.tar.gz" | sha1sum -c \
    && tar zxf /tmp/containerpilot.tar.gz -C /usr/local/bin \
    && rm /tmp/containerpilot.tar.gz

ENV CONSUL_VER 0.6.4
ENV CONSUL_SHA256 abdf0e1856292468e2c9971420d73b805e93888e006c76324ae39416edcf0627
RUN curl -Lso /tmp/consul.zip "https://releases.hashicorp.com/consul/${CONSUL_VER}/consul_${CONSUL_VER}_linux_amd64.zip" \
    && echo "${CONSUL_SHA256}  /tmp/consul.zip" | sha256sum -c \
    && unzip /tmp/consul -d /usr/local/bin \
    && rm /tmp/consul.zip \
    && mkdir -p /opt/consul/config

ENV CONSUL_TEMPLATE_VER 0.15.0
ENV CONSUL_TEMPLATE_SHA256 b7561158d2074c3c68ff62ae6fc1eafe8db250894043382fb31f0c78150c513a
RUN curl -Lso /tmp/consul-template.zip "https://releases.hashicorp.com/consul-template/${CONSUL_TEMPLATE_VER}/consul-template_${CONSUL_TEMPLATE_VER}_linux_amd64.zip" \
    && echo "${CONSUL_TEMPLATE_SHA256}  /tmp/consul-template.zip" | sha256sum -c \
    && unzip -d /usr/local/bin /tmp/consul-template.zip \
    && rm /tmp/consul-template.zip

ENV CONSUL_CLI_VER 0.3.1
ENV CONSUL_CLI_SHA256 037150d3d689a0babf4ba64c898b4497546e2fffeb16354e25cef19867e763f1
RUN curl -Lso /tmp/consul-cli.tgz "https://github.com/CiscoCloud/consul-cli/releases/download/v${CONSUL_CLI_VER}/consul-cli_${CONSUL_CLI_VER}_linux_amd64.tar.gz" \
    && echo "${CONSUL_CLI_SHA256}  /tmp/consul-cli.tgz" | sha256sum -c \
    && tar zxf /tmp/consul-cli.tgz -C /usr/local/bin --strip-components 1 \
    && rm /tmp/consul-cli.tgz

COPY etc/* /etc/
COPY bin/* /usr/local/bin/

# override the parent entrypoint
ENTRYPOINT []

CMD [ "containerpilot", \
      "/usr/local/bin/redis-server-sentinel.sh" \
]
