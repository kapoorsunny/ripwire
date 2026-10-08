from pump.loop import MessagePump
from pump.resolver import Resolver


class App(MessagePump):
    def __init__(self):
        super().__init__()
        self.resolver = Resolver()

    def on_lookup(self, message):
        return self.resolver.resolve(message.name)


def main():
    app = App()
    app.run_forever()
