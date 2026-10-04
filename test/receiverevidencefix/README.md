# receiverevidencefix — calls bound by name alone (test/receiverevidencecheck.sh)

Each directory is its own root (the gate indexes one at a time). Every root holds member calls (or, in an
implicit-receiver language, bare calls) whose receiver nothing proves to be the class of the same-named
definition beside them, plus near-miss calls whose receiver IS proven and whose edges must stay plain.

- `js/` — `ctx.onerror()` (plain and optional-chained) in the file that defines `Application.onerror`; a
  constructor-assigned `this.bucket` (a `Schemas`) beside the caller's own `listSchemas`; WeakMap `.set/.get`
  beside same-file accessors; Promise `.then` beside `Reply.prototype.then`; a stream's `.on` beside a test
  double; an outside router's `.all` and a Set's `.delete` beside instance shorthands; URLSearchParams `.append`
  beside `Response.append`; a `done` parameter beside another file's closure; `context.handler()` beside a free
  `handler`. Kept: `this.onerror()`, a same-file bare call, a relative module receiver, a closure called in its
  own function, `new Application()` / `new Schemas()` deciding between same-named methods; `reply.send()` on a
  parameter is the name-only true edge the gate wants kept AND marked.
- `ts/` — a loop variable over `Router<T>[]` beside `SmartRouter.add`; WHATWG `headers.get()` beside
  `Context.get` / `Cache.get`. Kept: an annotated parameter, construction through an import alias, a
  constructed local.
- `py/` (src layout) — dict/set/list/str receivers in files that import `Styles` / `Content`; an argument's
  `.animate`; an asyncio handle's `.cancel`; an outside package's parser `.write`; `self._send` holding a passed
  callable beside a nested `_send`; non-self receivers in `App`'s own file; `read = os.read` and
  `feed = parser.feed` called from a nested def; `add_widget = widgets.append` beside a nested `add_widget`.
  Kept: `self.update()`, a constructor-assigned field through the class cone, a typed parameter, construction,
  an import alias, an imported function beside same-named methods, `cls.default_rules()`, the
  `XTermParser.feed` the alias really reaches; `pump.call_later()` on a parameter is kept and marked.
- `go/` — an item's typed `text util.Chars` field, a typed parameter, a typed local through an aliased import
  and an embedded field, all beside `Merger.Get/Length` in the caller's package; an outside `tcell.Screen`'s
  `Size` and an outside value's `Runes` beside a renderer's methods. Kept: `m := &Merger{}`, the method
  receiver itself.
- `java/ kt/ cs/ cpp/ swift/ rb/` — a bare call inside a class whose base is outside the tree (or whose name
  comes from an outside import) beside an unrelated class's method of that name. Kept: own members (private
  too), an in-repo superclass's member, a free / top-level function, a Ruby included module, a Ruby top-level
  def.

The names are paraphrases of graded false rows; the code is minimal and is never built.
