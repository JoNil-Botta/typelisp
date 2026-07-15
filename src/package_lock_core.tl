;; package_lock_core.tl - Deterministic typelisp.lock parser/emitter.
;;
;; This module models the lockfile data needed after remote package pins are
;; resolved. It parses and emits `typelisp.lock` S-expressions only; build-time
;; fetch/replay behavior remains owned by the package build pipeline.
(import stdlib.io)
(import stdlib.string)
(import stdlib.vector)
(import lex as lexer)
(import read as reader)
(import "package_cache_core.tl")

(defstruct PackageLockEntry
  (alias String)
  (url String)
  (pin-kind PackageCachePinKind)
  (pin-value String)
  (commit String))

(import (vector.vector PackageLockEntry core) as package_lock_entry_vec)

(defstruct PackageLockFile
  (version String)
  (entries package_lock_entry_vec.Vec))

(defstruct PackageLockPin
  (kind PackageCachePinKind)
  (value String))

(define (package-lock-symbol-text [name-id : i64]) : String
  (reader.read-symbol-text-for-id name-id))

(defenum PackageLockMaybeEntry
  (No)
  (Some PackageLockEntry))

(defenum ResultPackageLockString
  (Ok String)
  (Err String))

(defenum ResultPackageLockPinKind
  (Ok PackageCachePinKind)
  (Err String))

(defenum ResultPackageLockPin
  (Ok PackageLockPin)
  (Err String))

(defenum ResultPackageLockEntry
  (Ok PackageLockEntry)
  (Err String))

(defenum ResultPackageLockEntryList
  (Ok package_lock_entry_vec.Vec)
  (Err String))

(defenum ResultPackageLockFile
  (Ok PackageLockFile)
  (Err String))

(define package-lock-version : String
  "v1")

(define (package-lock-char-code-at [text : String] [idx : i64]) : i64
  (cast (string.string-ref text idx) : i64))

(define (package-lock-string-less? [left : String] [right : String]) : bool
  (let
    [left-len : i64 (string.string-length left)]
    [right-len : i64 (string.string-length right)]
    [limit : i64
      (if (< left-len right-len)
        left-len
        right-len)]
    [idx : i64 0]
    [done : bool false]
    [less : bool false]
    (begin
      (while (and (not done) (< idx limit))
        (let
          [lc : i64 (package-lock-char-code-at left idx)]
          [rc : i64 (package-lock-char-code-at right idx)]
          (if (= lc rc)
            (set! idx (+ idx 1))
            (begin
              (set! less (< lc rc))
              (set! done true)))))
      (if done
        less
        (< left-len right-len)))))

(define (package-lock-alias-char? [c : char]) : bool
  (let
    [code : i64 (cast c : i64)]
    (or
      (and (>= code 48) (<= code 57))
      (and (>= code 65) (<= code 90))
      (and (>= code 97) (<= code 122))
      (= code 45)
      (= code 95))))

(define (package-lock-alias-token-valid? [value : String]) : bool
  (let
    [n : i64 (string.string-length value)]
    [i : i64 0]
    [ok : bool (> n 0)]
    (begin
      (while ok
        (if (< i n)
          (if (package-lock-alias-char? (string.string-ref value i))
            (set! i (+ i 1))
            (set! ok false))
          (set! ok false)))
      (= i n))))

(define (package-lock-entry-list-fallback) : PackageLockEntry
  (PackageLockEntry "" "" (PackageCachePinKind.Rev) "" ""))

(define (package-lock-entry-list-lookup-from
  [entries : (& entries package_lock_entry_vec.Vec)]
  [alias : String]
  [index : i64]) : PackageLockMaybeEntry
  (if (>= index (package_lock_entry_vec.len entries))
    (PackageLockMaybeEntry.No)
    (let
      [entry : PackageLockEntry
        (package_lock_entry_vec.get
          entries
          index
          (package-lock-entry-list-fallback))]
      (if (string.eq (struct-get entry alias) alias)
        (PackageLockMaybeEntry.Some entry)
        (package-lock-entry-list-lookup-from entries alias (+ index 1))))))

(define (package-lock-entry-list-lookup
  [entries : package_lock_entry_vec.Vec]
  [alias : String]) : PackageLockMaybeEntry
  (package-lock-entry-list-lookup-from (& entries) alias 0))

(define (package-lock-entry-list-insert-position
  [entries : (& entries package_lock_entry_vec.Vec)]
  [alias : String]
  [index : i64]) : i64
  (if (>= index (package_lock_entry_vec.len entries))
    index
    (let
      [head : PackageLockEntry
        (package_lock_entry_vec.get
          entries
          index
          (package-lock-entry-list-fallback))]
      (if (string.eq (struct-get head alias) alias)
        -1
        (if (package-lock-string-less? alias (struct-get head alias))
          index
          (package-lock-entry-list-insert-position entries alias (+ index 1)))))))

(define (package-lock-entry-list-insert-at!
  [entries : (&mut entries package_lock_entry_vec.Vec)]
  [entry : PackageLockEntry]
  [index : i64]) : unit
  (begin
    (package_lock_entry_vec.push entries (package-lock-entry-list-fallback))
    (let
      [write : i64 (- (package_lock_entry_vec.len entries) 1)]
      (begin
        (while (> write index)
          (let
            [previous : PackageLockEntry
              (package_lock_entry_vec.get
                entries
                (- write 1)
                (package-lock-entry-list-fallback))]
            (begin
              (package_lock_entry_vec.set entries write previous)
              (set! write (- write 1)))))
        (package_lock_entry_vec.set entries index entry)))))

(define (package-lock-entry-list-insert
  [entries : package_lock_entry_vec.Vec]
  [entry : PackageLockEntry]) : ResultPackageLockEntryList
  (let
    [next : package_lock_entry_vec.Vec entries]
    [index : i64
      (package-lock-entry-list-insert-position
        (& next)
        (struct-get entry alias)
        0)]
    (if (< index 0)
      (ResultPackageLockEntryList.Err
        (string.concat3
          "package-lock: duplicate dependency alias `"
          (struct-get entry alias)
          "`"))
      (begin
        (package-lock-entry-list-insert-at! (&mut next) entry index)
        (ResultPackageLockEntryList.Ok next)))))

(define (package-lock-field-string-value
  [ftail : reader.Sexpr]
  [fname : String]) : ResultPackageLockString
  (match ftail
    [(reader.Sexpr.Cons vhead vrest)
      (match (box-get vhead)
        [(reader.Sexpr.Str val-id)
          (match (box-get vrest)
            [(reader.Sexpr.Nil)
              (ResultPackageLockString.Ok
                (reader.read-symbol-text-for-id val-id))]
            [_
              (ResultPackageLockString.Err
                (string.concat3
                  "package-lock: field `"
                  fname
                  "` takes a single string value"))])]
        [_
          (ResultPackageLockString.Err
            (string.concat3
              "package-lock: field `"
              fname
              "` must have a string value"))])]
    [_
      (ResultPackageLockString.Err
        (string.concat3
          "package-lock: field `"
          fname
          "` must have a string value"))]))

(define (package-lock-parse-pin-kind [value : String]) : ResultPackageLockPinKind
  (cond
    [(string.eq value "rev")
      (ResultPackageLockPinKind.Ok (PackageCachePinKind.Rev))]
    [(string.eq value "tag")
      (ResultPackageLockPinKind.Ok (PackageCachePinKind.Tag))]
    [(string.eq value "branch")
      (ResultPackageLockPinKind.Ok (PackageCachePinKind.Branch))]
    [else
      (ResultPackageLockPinKind.Err
        "package-lock: pin kind must be `rev`, `tag`, or `branch`")]))

(define (package-lock-pin-shape-error) : ResultPackageLockPin
  (ResultPackageLockPin.Err
    "package-lock: pin must be `(rev|tag|branch \"value\")`"))

(define (package-lock-pin-form [form : reader.Sexpr]) : ResultPackageLockPin
  (match form
    [(reader.Sexpr.Cons kind-node kind-tail)
      (match (box-get kind-node)
        [(reader.Sexpr.Sym kind-name)
          (match (box-get kind-tail)
            [(reader.Sexpr.Cons value-node end)
              (match (box-get end)
                [(reader.Sexpr.Nil)
                  (match (box-get value-node)
                    [(reader.Sexpr.Str pin-value-id)
                      (let
                        [pin-value : String
                          (reader.read-symbol-text-for-id pin-value-id)]
                        (if (string.eq pin-value "")
                          (ResultPackageLockPin.Err
                            "package-lock: pin value must not be empty")
                          (match (package-lock-parse-pin-kind
                            (package-lock-symbol-text kind-name))
                            [(ResultPackageLockPinKind.Err message)
                              (ResultPackageLockPin.Err message)]
                            [(ResultPackageLockPinKind.Ok pin-kind)
                              (ResultPackageLockPin.Ok
                                (PackageLockPin pin-kind pin-value))])))]
                    [_ (package-lock-pin-shape-error)])]
                [_ (package-lock-pin-shape-error)])]
            [_ (package-lock-pin-shape-error)])]
        [_ (package-lock-pin-shape-error)])]
    [_ (package-lock-pin-shape-error)]))

(define (package-lock-field-pin-value [ftail : reader.Sexpr]) : ResultPackageLockPin
  (match ftail
    [(reader.Sexpr.Cons pin-form after-pin)
      (match (box-get after-pin)
        [(reader.Sexpr.Nil) (package-lock-pin-form (box-get pin-form))]
        [_
          (ResultPackageLockPin.Err "package-lock: field `pin` takes one value")])]
    [_ (ResultPackageLockPin.Err "package-lock: field `pin` takes one value")]))

(define (package-lock-entry-fields
  [fields : reader.Sexpr]
  [alias : String]
  [has-alias : bool]
  [url : String]
  [has-url : bool]
  [pin-kind : PackageCachePinKind]
  [pin-value : String]
  [has-pin : bool]
  [commit : String]
  [has-commit : bool]) : ResultPackageLockEntry
  (match fields
    [(reader.Sexpr.Nil)
      (cond
        [(not has-alias)
          (ResultPackageLockEntry.Err
            "package-lock: dependency missing required field `alias`")]
        [(not has-url)
          (ResultPackageLockEntry.Err
            "package-lock: dependency missing required field `url`")]
        [(not has-pin)
          (ResultPackageLockEntry.Err
            "package-lock: dependency missing required field `pin`")]
        [(not has-commit)
          (ResultPackageLockEntry.Err
            "package-lock: dependency missing required field `commit`")]
        [(string.eq alias "")
          (ResultPackageLockEntry.Err
            "package-lock: dependency alias must not be empty")]
        [(not (package-lock-alias-token-valid? alias))
          (ResultPackageLockEntry.Err
            "package-lock: dependency alias may only contain ASCII letters, digits, '-' and '_'")]
        [(string.eq url "")
          (ResultPackageLockEntry.Err
            "package-lock: dependency url must not be empty")]
        [(string.eq commit "")
          (ResultPackageLockEntry.Err
            "package-lock: dependency commit must not be empty")]
        [else
          (ResultPackageLockEntry.Ok
            (PackageLockEntry alias url pin-kind pin-value commit))])]
    [(reader.Sexpr.Cons field rest)
      (match (box-get field)
        [(reader.Sexpr.Cons fhead ftail)
          (match (box-get fhead)
            [(reader.Sexpr.Sym fname)
              (cond
                [(string.eq (package-lock-symbol-text fname) "alias")
                  (if has-alias
                    (ResultPackageLockEntry.Err
                      "package-lock: duplicate dependency field `alias`")
                    (match (package-lock-field-string-value
                      (box-get ftail)
                      (package-lock-symbol-text fname))
                      [(ResultPackageLockString.Err message)
                        (ResultPackageLockEntry.Err message)]
                      [(ResultPackageLockString.Ok value)
                        (package-lock-entry-fields
                          (box-get rest)
                          value
                          true
                          url
                          has-url
                          pin-kind
                          pin-value
                          has-pin
                          commit
                          has-commit)]))]
                [(string.eq (package-lock-symbol-text fname) "url")
                  (if has-url
                    (ResultPackageLockEntry.Err
                      "package-lock: duplicate dependency field `url`")
                    (match (package-lock-field-string-value
                      (box-get ftail)
                      (package-lock-symbol-text fname))
                      [(ResultPackageLockString.Err message)
                        (ResultPackageLockEntry.Err message)]
                      [(ResultPackageLockString.Ok value)
                        (package-lock-entry-fields
                          (box-get rest)
                          alias
                          has-alias
                          value
                          true
                          pin-kind
                          pin-value
                          has-pin
                          commit
                          has-commit)]))]
                [(string.eq (package-lock-symbol-text fname) "pin")
                  (if has-pin
                    (ResultPackageLockEntry.Err
                      "package-lock: duplicate dependency field `pin`")
                    (match (package-lock-field-pin-value (box-get ftail))
                      [(ResultPackageLockPin.Err message)
                        (ResultPackageLockEntry.Err message)]
                      [(ResultPackageLockPin.Ok pin)
                        (package-lock-entry-fields
                          (box-get rest)
                          alias
                          has-alias
                          url
                          has-url
                          (struct-get pin kind)
                          (struct-get pin value)
                          true
                          commit
                          has-commit)]))]
                [(string.eq (package-lock-symbol-text fname) "commit")
                  (if has-commit
                    (ResultPackageLockEntry.Err
                      "package-lock: duplicate dependency field `commit`")
                    (match (package-lock-field-string-value
                      (box-get ftail)
                      (package-lock-symbol-text fname))
                      [(ResultPackageLockString.Err message)
                        (ResultPackageLockEntry.Err message)]
                      [(ResultPackageLockString.Ok value)
                        (package-lock-entry-fields
                          (box-get rest)
                          alias
                          has-alias
                          url
                          has-url
                          pin-kind
                          pin-value
                          has-pin
                          value
                          true)]))]
                [else
                  (ResultPackageLockEntry.Err
                    (string.concat3
                      "package-lock: unknown dependency field `"
                      (package-lock-symbol-text fname)
                      "`"))])]
            [_
              (ResultPackageLockEntry.Err
                "package-lock: dependency fields must start with a field name")])]
        [_
          (ResultPackageLockEntry.Err
            "package-lock: dependency fields must be lists")])]
    [_
      (ResultPackageLockEntry.Err
        "package-lock: dependency fields must be lists")]))

(define (package-lock-entry-from-form [form : reader.Sexpr]) : ResultPackageLockEntry
  (match form
    [(reader.Sexpr.Cons head rest)
      (match (box-get head)
        [(reader.Sexpr.Sym name)
          (if (string.eq (package-lock-symbol-text name) "dependency")
            (package-lock-entry-fields
              (box-get rest)
              ""
              false
              ""
              false
              (PackageCachePinKind.Rev)
              ""
              false
              ""
              false)
            (ResultPackageLockEntry.Err
              "package-lock: dependency entries must start with `dependency`"))]
        [_
          (ResultPackageLockEntry.Err
            "package-lock: dependency entries must start with `dependency`")])]
    [_
      (ResultPackageLockEntry.Err
        "package-lock: dependency entries must be lists")]))

(define (package-lock-dependencies-entries
  [entries : reader.Sexpr]
  [acc : package_lock_entry_vec.Vec]) : ResultPackageLockEntryList
  (match entries
    [(reader.Sexpr.Nil) (ResultPackageLockEntryList.Ok acc)]
    [(reader.Sexpr.Cons entry rest)
      (match (package-lock-entry-from-form (box-get entry))
        [(ResultPackageLockEntry.Err message)
          (ResultPackageLockEntryList.Err message)]
        [(ResultPackageLockEntry.Ok parsed)
          (match (package-lock-entry-list-insert acc parsed)
            [(ResultPackageLockEntryList.Err message)
              (ResultPackageLockEntryList.Err message)]
            [(ResultPackageLockEntryList.Ok next)
              (package-lock-dependencies-entries (box-get rest) next)])])]
    [_
      (ResultPackageLockEntryList.Err
        "package-lock: `dependencies` must contain dependency lists")]))

(define (package-lock-fields
  [fields : reader.Sexpr]
  [version : String]
  [has-version : bool]
  [entries : package_lock_entry_vec.Vec]
  [has-deps : bool]) : ResultPackageLockFile
  (match fields
    [(reader.Sexpr.Nil)
      (cond
        [(not has-version)
          (ResultPackageLockFile.Err
            "package-lock: missing required field `version`")]
        [(not (string.eq version package-lock-version))
          (ResultPackageLockFile.Err
            (string.concat3 "package-lock: unsupported version `" version "`"))]
        [(not has-deps)
          (ResultPackageLockFile.Err
            "package-lock: missing required field `dependencies`")]
        [else (ResultPackageLockFile.Ok (PackageLockFile version entries))])]
    [(reader.Sexpr.Cons field rest)
      (match (box-get field)
        [(reader.Sexpr.Cons fhead ftail)
          (match (box-get fhead)
            [(reader.Sexpr.Sym fname)
              (if (string.eq (package-lock-symbol-text fname) "version")
                (if has-version
                  (ResultPackageLockFile.Err
                    "package-lock: duplicate field `version`")
                  (match (package-lock-field-string-value
                    (box-get ftail)
                    (package-lock-symbol-text fname))
                    [(ResultPackageLockString.Err message)
                      (ResultPackageLockFile.Err message)]
                    [(ResultPackageLockString.Ok value)
                      (package-lock-fields
                        (box-get rest)
                        value
                        true
                        entries
                        has-deps)]))
                (if (string.eq (package-lock-symbol-text fname) "dependencies")
                  (if has-deps
                    (ResultPackageLockFile.Err
                      "package-lock: duplicate field `dependencies`")
                    (match (package-lock-dependencies-entries
                      (box-get ftail)
                      (package_lock_entry_vec.new))
                      [(ResultPackageLockEntryList.Err message)
                        (ResultPackageLockFile.Err message)]
                      [(ResultPackageLockEntryList.Ok parsed)
                        (package-lock-fields
                          (box-get rest)
                          version
                          has-version
                          parsed
                          true)]))
                  (ResultPackageLockFile.Err
                    (string.concat3
                      "package-lock: unknown field `"
                      (package-lock-symbol-text fname)
                      "`"))))]
            [_
              (ResultPackageLockFile.Err
                "package-lock: fields must start with a field name")])]
        [_ (ResultPackageLockFile.Err "package-lock: fields must be lists")])]
    [_ (ResultPackageLockFile.Err "package-lock: fields must be lists")]))

(define (package-lock-from-form [form : reader.Sexpr]) : ResultPackageLockFile
  (match form
    [(reader.Sexpr.Cons head rest)
      (match (box-get head)
        [(reader.Sexpr.Sym name)
          (if (string.eq (package-lock-symbol-text name) "typelisp-lock")
            (package-lock-fields
              (box-get rest)
              ""
              false
              (package_lock_entry_vec.new)
              false)
            (ResultPackageLockFile.Err
              (string.concat3
                "expected `typelisp-lock` form, got `"
                (package-lock-symbol-text name)
                "`")))]
        [_
          (ResultPackageLockFile.Err
            "package-lock: lockfile must start with `typelisp-lock`")])]
    [_
      (ResultPackageLockFile.Err
        "package-lock: lockfile must be a `(typelisp-lock ...)` form")]))

(define (package-lock-parse [source : String]) : ResultPackageLockFile
  (match (reader.read-result (lexer.lex source))
    [(reader.ResultSexpr.Err message)
      (ResultPackageLockFile.Err (string.append "package-lock: " message))]
    [(reader.ResultSexpr.Ok form) (package-lock-from-form form)]))

(define (package-lock-quote-text) : String
  "\"")

(define (package-lock-backslash-text) : String
  "\\")

(define (package-lock-escape-string [text : String]) : String
  (let
    [n : i64 (string.string-length text)]
    [i : i64 0]
    [out : String ""]
    [slash : String (package-lock-backslash-text)]
    [quote : String (package-lock-quote-text)]
    (begin
      (while (< i n)
        (begin
          (let
            [code : i64 (package-lock-char-code-at text i)]
            (cond
              [(= code 34)
                (set! out (string.concat3 out (string.append slash quote) ""))]
              [(= code 92)
                (set! out (string.concat3 out (string.append slash slash) ""))]
              [(= code 10)
                (set! out (string.concat3 out (string.append slash "n") ""))]
              [(= code 9)
                (set! out (string.concat3 out (string.append slash "t") ""))]
              [(= code 13)
                (set! out (string.concat3 out (string.append slash "r") ""))]
              [else
                (set! out (string.concat3 out (string.substring text i 1) ""))]))
          (set! i (+ i 1))))
      out)))

(define (package-lock-quote-string [text : String]) : String
  (string.append
    (package-lock-quote-text)
    (string.append (package-lock-escape-string text) (package-lock-quote-text))))

(define (package-lock-emit-string-field [field : String] [value : String]) : String
  (string.append
    "      ("
    (string.append
      field
      (string.append
        " "
        (string.append (package-lock-quote-string value) ")\n")))))

(define (package-lock-emit-final-string-field [field : String] [value : String]) : String
  (string.append
    "      ("
    (string.append
      field
      (string.append
        " "
        (string.append (package-lock-quote-string value) "))\n")))))

(define (package-lock-emit-pin-field [kind-name : String] [value : String]) : String
  (string.append
    "      (pin ("
    (string.append
      kind-name
      (string.append
        " "
        (string.append (package-lock-quote-string value) "))\n")))))

(define (package-lock-emit-entry [entry : PackageLockEntry]) : String
  (let
    [kind-name : String
      (package-cache-pin-kind-name (struct-get entry pin-kind))]
    (string.append
      "    (dependency\n"
      (string.append
        (package-lock-emit-string-field "alias" (struct-get entry alias))
        (string.append
          (package-lock-emit-string-field "url" (struct-get entry url))
          (string.append
            (package-lock-emit-pin-field kind-name (struct-get entry pin-value))
            (package-lock-emit-final-string-field
              "commit"
              (struct-get entry commit))))))))

(define (package-lock-emit-entries-from
  [entries : (& entries package_lock_entry_vec.Vec)]
  [index : i64]) : String
  (if (>= index (package_lock_entry_vec.len entries))
    ""
    (string.append
      (package-lock-emit-entry
        (package_lock_entry_vec.get
          entries
          index
          (package-lock-entry-list-fallback)))
      (package-lock-emit-entries-from entries (+ index 1)))))

(define (package-lock-emit-entries [entries : package_lock_entry_vec.Vec]) : String
  (package-lock-emit-entries-from (& entries) 0))

(define (package-lock-emit [lock : PackageLockFile]) : String
  (string.append
    "(typelisp-lock\n"
    (string.append
      "  (version \"v1\")\n"
      (string.append
        "  (dependencies\n"
        (string.append
          (package-lock-emit-entries (struct-get lock entries))
          "  ))\n")))))

(define (package-lock-valid-source) : String
  "(typelisp-lock (version \"v1\") (dependencies (dependency (alias \"zeta\") (url \"https://github.com/owner/zeta.git\") (pin (rev \"abcdef0123456789abcdef0123456789abcdef01\")) (commit \"abcdef0123456789abcdef0123456789abcdef01\")) (dependency (alias \"alpha\") (url \"https://github.com/owner/alpha.git\") (pin (branch \"main\")) (commit \"1111111111111111111111111111111111111111\"))))")

(cfg
  test
  (define (package-lock-growth-source) : String
    "(typelisp-lock (version \"v1\") (dependencies (dependency (alias \"foxtrot\") (url \"u\") (pin (rev \"f\")) (commit \"f\")) (dependency (alias \"alpha\") (url \"u\") (pin (rev \"a\")) (commit \"a\")) (dependency (alias \"echo\") (url \"u\") (pin (rev \"e\")) (commit \"e\")) (dependency (alias \"bravo\") (url \"u\") (pin (rev \"b\")) (commit \"b\")) (dependency (alias \"delta\") (url \"u\") (pin (rev \"d\")) (commit \"d\")) (dependency (alias \"charlie\") (url \"u\") (pin (rev \"c\")) (commit \"c\"))))"))

(define (package-lock-expected-emitted) : String
  (string.append
    "(typelisp-lock\n"
    (string.append
      "  (version \"v1\")\n"
      (string.append
        "  (dependencies\n"
        (string.append
          "    (dependency\n      (alias \"alpha\")\n      (url \"https://github.com/owner/alpha.git\")\n      (pin (branch \"main\"))\n      (commit \"1111111111111111111111111111111111111111\"))\n"
          (string.append
            "    (dependency\n      (alias \"zeta\")\n      (url \"https://github.com/owner/zeta.git\")\n      (pin (rev \"abcdef0123456789abcdef0123456789abcdef01\"))\n      (commit \"abcdef0123456789abcdef0123456789abcdef01\"))\n"
            "  ))\n"))))))

(define (package-lock-entry-matches?
  [entry : PackageLockEntry]
  [alias : String]
  [url : String]
  [kind : PackageCachePinKind]
  [pin-value : String]
  [commit : String]) : bool
  (and
    (string.eq (struct-get entry alias) alias)
    (string.eq (struct-get entry url) url)
    (package-cache-pin-kind-eq? (struct-get entry pin-kind) kind)
    (string.eq (struct-get entry pin-value) pin-value)
    (string.eq (struct-get entry commit) commit)))

(define (package-lock-list-has-entry?
  [entries : package_lock_entry_vec.Vec]
  [alias : String]
  [url : String]
  [kind : PackageCachePinKind]
  [pin-value : String]
  [commit : String]) : bool
  (match (package-lock-entry-list-lookup entries alias)
    [(PackageLockMaybeEntry.No) false]
    [(PackageLockMaybeEntry.Some entry)
      (package-lock-entry-matches? entry alias url kind pin-value commit)]))

(define (package-lock-valid-parse-ok?) : bool
  (match (package-lock-parse (package-lock-valid-source))
    [(ResultPackageLockFile.Err _) false]
    [(ResultPackageLockFile.Ok lock)
      (let
        [entries : package_lock_entry_vec.Vec (struct-get lock entries)]
        (and
          (string.eq (struct-get lock version) package-lock-version)
          (= (package_lock_entry_vec.len (& entries)) 2)
          (package-lock-list-has-entry?
            entries
            "alpha"
            "https://github.com/owner/alpha.git"
            (PackageCachePinKind.Branch)
            "main"
            "1111111111111111111111111111111111111111")
          (package-lock-list-has-entry?
            entries
            "zeta"
            "https://github.com/owner/zeta.git"
            (PackageCachePinKind.Rev)
            "abcdef0123456789abcdef0123456789abcdef01"
            "abcdef0123456789abcdef0123456789abcdef01")))]))

(define (package-lock-emit-stable-ok?) : bool
  (match (package-lock-parse (package-lock-valid-source))
    [(ResultPackageLockFile.Err _) false]
    [(ResultPackageLockFile.Ok lock)
      (string.eq (package-lock-emit lock) (package-lock-expected-emitted))]))

(define (package-lock-round-trip-ok?) : bool
  (match (package-lock-parse (package-lock-valid-source))
    [(ResultPackageLockFile.Err _) false]
    [(ResultPackageLockFile.Ok lock)
      (match (package-lock-parse (package-lock-emit lock))
        [(ResultPackageLockFile.Err _) false]
        [(ResultPackageLockFile.Ok again)
          (let
            [entries : package_lock_entry_vec.Vec (struct-get again entries)]
            (and
              (= (package_lock_entry_vec.len (& entries)) 2)
              (package-lock-list-has-entry?
                entries
                "alpha"
                "https://github.com/owner/alpha.git"
                (PackageCachePinKind.Branch)
                "main"
                "1111111111111111111111111111111111111111")
              (package-lock-list-has-entry?
                entries
                "zeta"
                "https://github.com/owner/zeta.git"
                (PackageCachePinKind.Rev)
                "abcdef0123456789abcdef0123456789abcdef01"
                "abcdef0123456789abcdef0123456789abcdef01")))])]))

(cfg
  test
  (define (package-lock-entry-alias-at?
    [entries : (& entries package_lock_entry_vec.Vec)]
    [index : i64]
    [alias : String]) : bool
    (string.eq
      (struct-get
        (package_lock_entry_vec.get
          entries
          index
          (package-lock-entry-list-fallback))
        alias)
      alias)))

(cfg
  test
  (define (package-lock-growth-entries-ok?
    [entries : (& entries package_lock_entry_vec.Vec)]) : bool
    (and
      (= (package_lock_entry_vec.len entries) 6)
      (= (package_lock_entry_vec.capacity entries) 8)
      (package-lock-entry-alias-at? entries 0 "alpha")
      (package-lock-entry-alias-at? entries 1 "bravo")
      (package-lock-entry-alias-at? entries 2 "charlie")
      (package-lock-entry-alias-at? entries 3 "delta")
      (package-lock-entry-alias-at? entries 4 "echo")
      (package-lock-entry-alias-at? entries 5 "foxtrot"))))

(cfg
  test
  (define (package-lock-growth-order-ok?) : bool
    (match (package-lock-parse (package-lock-growth-source))
      [(ResultPackageLockFile.Err _) false]
      [(ResultPackageLockFile.Ok lock)
        (if (package-lock-growth-entries-ok? (& (struct-get lock entries)))
          (match (package-lock-parse (package-lock-emit lock))
            [(ResultPackageLockFile.Err _) false]
            [(ResultPackageLockFile.Ok again)
              (package-lock-growth-entries-ok? (& (struct-get again entries)))])
          false)])))

(define (package-lock-parse-rejects? [source : String] [expected : String]) : bool
  (match (package-lock-parse source)
    [(ResultPackageLockFile.Err message) (string.eq message expected)]
    [(ResultPackageLockFile.Ok _) false]))

(define (package-lock-rejections-ok?) : bool
  (and
    (package-lock-parse-rejects?
      "(typelisp-lock (version \"v1\") (dependencies (dependency (alias \"dup\") (url \"u\") (pin (rev \"a\")) (commit \"a\")) (dependency (alias \"dup\") (url \"u\") (pin (tag \"v1\")) (commit \"b\"))))"
      "package-lock: duplicate dependency alias `dup`")
    (package-lock-parse-rejects?
      "(typelisp-lock (version \"v1\") (dependencies (dependency (alias \"a\") (url \"u\") (pin (rev \"a\")))))"
      "package-lock: dependency missing required field `commit`")
    (package-lock-parse-rejects?
      "(typelisp-lock (version \"v1\") (dependencies (dependency (alias a) (url \"u\") (pin (rev \"a\")) (commit \"a\"))))"
      "package-lock: field `alias` must have a string value")
    (package-lock-parse-rejects?
      "(typelisp-lock (version \"v2\") (dependencies))"
      "package-lock: unsupported version `v2`")
    (package-lock-parse-rejects?
      "(typelisp-lock (version \"v1\") (dependencies (dependency (alias \"a\") (url \"u\") (pin (sha \"a\")) (commit \"a\"))))"
      "package-lock: pin kind must be `rev`, `tag`, or `branch`")))

(define (package-lock-self-test-ok?) : bool
  (and
    (package-lock-valid-parse-ok?)
    (package-lock-emit-stable-ok?)
    (package-lock-round-trip-ok?)
    (package-lock-rejections-ok?)))

(define (package-lock-self-test) : i64
  (if (package-lock-self-test-ok?)
    42
    (io.panic "package-lock: self-test mismatch")))

(test
  package-lock-parse-emit-round-trip
  (if (package-lock-self-test-ok?)
    unit
    (io.panic "package-lock: inline self-test mismatch")))

(test
  package-lock-generated-vector-growth-order
  (if (package-lock-growth-order-ok?)
    unit
    (io.panic "package-lock: generated vector growth/order mismatch")))