'use strict';

const { JobQueue } = require( './queue' );

class Worker {
  constructor() {
    this.queue = new JobQueue();
  }

  tick() {
    this.queue.drain();
  }

  start() {
    for( let i = 0; i < 3; i++ ) {
      this.tick();
    }
  }
}

// A relay forwards to whatever it was handed: nothing proves `target` is a JobQueue.
function relay( target ) {
  target.drain();
}

module.exports = { Worker, relay };
