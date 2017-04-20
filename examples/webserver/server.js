const http = require('http')
const piloted = require('piloted')
const Redis = require('ioredis')

let redis

main()
async function main () {
    await piloted.config(require('/etc/containerpilot.json'))
    configureRedis()
    piloted.on('refresh', configureRedis)

    const server = http.createServer(onRequest)
    server.listen(8000)
}

async function onRequest (req, res) {
    try {
        const value = await redis.get('test:key')
        res.end(`test:key = ${value}`)
        console.log('%s 200 OK', new Date())
    }
    catch (err) {
        res.statusCode = 500
        res.end(`An error occurred: ${err.message}`)
        console.log('%s 500 ERROR %s', new Date(), err.message)
    }
}

function configureRedis () {
    if (redis) redis.quit()

    const sentinels = piloted
        .serviceHosts('redis-sentinel')
        .map(s => Object.assign(s, { host: s.address }))

    redis = new Redis({ sentinels, name: 'mymaster' })
    redis.once('connect', () => console.log('%s connected to redis', new Date()))
}
