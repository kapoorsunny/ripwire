'use strict';

function resizeImage( payload ) {
  const w = payload.width / 2;
  const h = payload.height / 2;
  return { width: w, height: h };
}

function logUnknown( payload ) {
  return { skipped: true, payload };
}

const handlers = {
  resize: resizeImage,
  fallback: logUnknown,
};

function pickHandler( type ) {
  return handlers[ type ] || handlers.fallback;
}

function runJob( job ) {
  const handler = pickHandler( job.type );
  return handler( job.payload );
}

class JobQueue {
  constructor() {
    this.jobs = [];
    this.stopped = false;
  }

  push( job ) {
    this.jobs.push( job );
  }

  drain() {
    while( this.jobs.length > 0 && !this.stopped ) {
      const job = this.jobs.shift();
      runJob( job );
    }
  }
}

module.exports = { JobQueue, runJob };
