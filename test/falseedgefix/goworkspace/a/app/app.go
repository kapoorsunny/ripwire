package app

import "example.com/wb/lib"

// Use calls into the sibling root a quoted replace maps: a true edge.
func Use(n int) int { return lib.Far(n) }
