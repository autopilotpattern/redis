FROM alpine

RUN apk add --no-cache nodejs

WORKDIR /opt/app
RUN npm install ioredis request
COPY counter.js /opt/app/

CMD [ "/opt/app/counter.js" ]
