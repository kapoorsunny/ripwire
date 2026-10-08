package app

import "example.com/qraw/lib"

// UseRaw calls through an import a backquoted local replace puts in this tree: a true edge.
func UseRaw(n int) int { return lib.Raw(n) }
