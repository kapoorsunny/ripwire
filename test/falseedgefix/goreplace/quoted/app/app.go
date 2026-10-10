package app

import "example.com/qlegacy/lib"

// UseQuoted calls through an import a quoted local replace puts in this tree: a true edge.
func UseQuoted(n int) int { return lib.Quote(n) }
