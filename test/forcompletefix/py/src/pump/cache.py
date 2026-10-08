class LookupCache:
    def __init__(self):
        self._slots = {}

    def fetch_entry(self, key):
        """Return the cached entry for key, computing and storing it on a miss."""
        if key not in self._slots:
            self._slots[key] = self._compute(key)
        return self._slots[key]

    @staticmethod
    def _compute(key):
        return key.upper()

    def evict_entries(
        self,
        keys,
    ):
        for key in keys:
            self._slots.pop(key, None)
