from pump.cache import LookupCache


class Resolver:
    def __init__(self):
        self.cache = LookupCache()

    def resolve(self, name):
        return self.cache.fetch_entry(name)


class Downloader:
    def pull(self, source, url):
        # `source` is an untyped parameter: nothing proves it is a LookupCache.
        return source.fetch_entry(url)
