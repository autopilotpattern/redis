FROM redis:3.2.8-alpine

RUN apk add --no-cache curl jq openssl tar bash

# Add ContainerPilot and set its configuration file path
ENV CONTAINERPILOT_VER 2.7.0
ENV CONTAINERPILOT file:///etc/containerpilot.json
RUN export CONTAINERPILOT_CHECKSUM=687f7d83e031be7f497ffa94b234251270aee75b \
    && curl -Lso /tmp/containerpilot.tar.gz \
        "https://github.com/joyent/containerpilot/releases/download/${CONTAINERPILOT_VER}/containerpilot-${CONTAINERPILOT_VER}.tar.gz" \
    && echo "${CONTAINERPILOT_CHECKSUM}  /tmp/containerpilot.tar.gz" | sha1sum -c \
    && tar zxf /tmp/containerpilot.tar.gz -C /usr/local/bin \
    && rm /tmp/containerpilot.tar.gz

ENV CONSUL_VER 0.7.2
ENV CONSUL_SHA256 aa97f4e5a552d986b2a36d48fdc3a4a909463e7de5f726f3c5a89b8a1be74a58
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
