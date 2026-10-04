'use strict'
// Bm: `ctx` is a request context, never an Application; this file defining Application is no evidence.
const proto = require('./context')
const Schemas = require('./schemas')

class Application {
  constructor () {
    this.context = Object.create(proto)
    this.bucket = new Schemas()
  }

  onerror (err) {
    console.error(err)
  }

  handle (ctx) {
    this.onerror(new Error('local'))
    return respond(ctx)
  }

  schemas () {
    return this.bucket.listSchemas()
  }

  listSchemas () {
    return []
  }
}

function respond (ctx) {
  if (!ctx.writable) ctx.onerror(new Error('closed'))
}

// Siblings of the receiver shape: optional chaining and a computed member, on the same context object.
function respondSafely (ctx) {
  ctx?.onerror?.(new Error('maybe'))
}

function respondComputed (ctx) {
  ctx['onerror'](new Error('computed'))
}

module.exports = Application
