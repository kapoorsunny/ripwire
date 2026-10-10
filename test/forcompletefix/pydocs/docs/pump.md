# Message pump

## How a message is delivered

The message pump drains pending messages and delivers each message to its handler.
`MessagePump.post` queues a message; `run_forever` drains the pending queue.

## Delivering a message to a handler

`deliver` looks up the `on_<kind>` handler for each message and calls it.
A message without a handler is dropped.

## Draining pending messages

`_drain` pops messages in arrival order until the pending queue is empty.
