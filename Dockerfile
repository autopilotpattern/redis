FROM redis:3-alpine

RUN apk add --no-cache curl jq openssl tar

# Add ContainerPilot and set its configuration file path
ENV CONTAINERPILOT_VER 2.1.0
ENV CONTAINERPILOT file:///etc/containerpilot.json
RUN export CONTAINERPILOT_CHECKSUM=e7973bf036690b520b450c3a3e121fc7cd26f1a2 \
    && curl -Lso /tmp/containerpilot.tar.gz \
        "https://github.com/joyent/containerpilot/releases/download/${CONTAINERPILOT_VER}/containerpilot-${CONTAINERPILOT_VER}.tar.gz" \
    && echo "${CONTAINERPILOT_CHECKSUM}  /tmp/containerpilot.tar.gz" | sha1sum -c \
    && tar zxf /tmp/containerpilot.tar.gz -C /usr/local/bin \
    && rm /tmp/containerpilot.tar.gz

ENV CONSUL_TEMPLATE_VER 0.14.0
ENV CONSUL_TEMPLATE_SHA256 7c70ea5f230a70c809333e75fdcff2f6f1e838f29cfb872e1420a63cdf7f3a78
RUN curl -Lso /tmp/consul-template.zip "https://releases.hashicorp.com/consul-template/${CONSUL_TEMPLATE_VER}/consul-template_${CONSUL_TEMPLATE_VER}_linux_amd64.zip" \
    && echo "${CONSUL_TEMPLATE_SHA256}  /tmp/consul-template.zip" | sha256sum -c \
    && unzip -d /usr/local/bin /tmp/consul-template.zip \
    && rm /tmp/consul-template.zip

ENV CONSUL_CLI_VER 0.2.0
ENV CONSUL_CLI_SHA256 0282b3a76c642cb7b541c53254d0d847aba083b7ae586e1fbfba5c83370715e2
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
