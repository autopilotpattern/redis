#!/usr/bin/env node
'use strict';

const Redis = require('ioredis');
const request = require('request');

const serviceCatalogUrl = `http://${process.env.CONSUL}:8500/v1/catalog/service/redis-sentinel`;

function getServices() {
    request.get(serviceCatalogUrl, (err, res, body) => {
        let sentinels;
        if (err) {
            console.error(err);
        } else {
            try {
                let services = JSON.parse(body);
                sentinels = services.map(service => ({ host: service.ServiceAddress, port: service.ServicePort }));
            } catch (err) {
                console.error(err);
            }
        }
        if (sentinels && sentinels.length) {
            startCounter(sentinels);
        } else {
            setTimeout(getServices, 1000);
        }
    });
}

function startCounter(sentinels) {
    let client = new Redis({
        sentinels: sentinels,
        name: process.env.REDIS_MASTER || 'mymaster',
    });

    client.on('error', err => {
        console.error(err);
    });

    setInterval(() => client.incr('test:counter').then(res => console.log(res)), 1000);
}

getServices();
