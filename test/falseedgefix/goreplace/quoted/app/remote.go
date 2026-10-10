package app

import lib "example.com/qremote/lib"

// UseRemote calls a module replaced by another MODULE, not a directory: outside the tree, no edge to the in-tree Quote.
func UseRemote(n int) int { return lib.Quote(n) }
