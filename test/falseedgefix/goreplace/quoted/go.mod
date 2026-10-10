module example.com/rq

go 1.22

// Not buildable Go on purpose, as ../go.mod: the quoted spellings Go's go.mod grammar allows for a local replace.
replace "example.com/qlegacy" => "./qlegacy"

replace (
	`example.com/qraw` => ./qraw
)

// A quoted module replaced by another MODULE (not a directory) is not this tree's code.
replace "example.com/qremote" => "example.com/qfork" v1.0.0
