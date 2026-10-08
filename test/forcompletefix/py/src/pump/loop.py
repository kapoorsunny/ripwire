class MessagePump:
    def __init__(self):
        self._pending = []
        self._running = True

    def post(self, message):
        self._pending.append(message)

    def run_forever(self):
        while self._running:
            self._drain()

    def _drain(self):
        while self._pending:
            message = self._pending.pop(0)
            self.deliver(message)

    def deliver(self, message):
        handler = getattr(self, "on_" + message.kind, None)
        if handler is not None:
            handler(message)
