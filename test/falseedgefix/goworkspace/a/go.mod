module example.com/wa

go 1.22

// A quoted replace of a module by a SIBLING root (indexed beside this one): the cross-root alias.
replace "example.com/wb" => "../b"
