;; package_lock_core.tl - Deterministic typelisp.lock parser/emitter (#1993).
;;
;; This module models the lockfile data needed after remote package pins are
;; resolved. It parses and emits `typelisp.lock` S-expressions only; build-time
;; fetch/replay behavior remains owned by the package build pipeline.
(import stdlib.io)
(import stdlib.string)
(import stdlib.str_cat)
(import "read.tl")
(import "package_cache_core.tl")

(defstruct PackageLockEntry
  (alias String)
  (url String)
  (pin-kind PackageCachePinKind)
  (pin-value String)
  (commit String))

(defenum PackageLockEntryList
  (Nil)
  (Cons PackageLockEntry (Box PackageLockEntryList)))

(defstruct PackageLockFile
  (version String)
  (entries PackageLockEntryList))

(defstruct PackageLockPin
  (kind PackageCachePinKind)
  (value String))

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
  (Ok PackageLockEntryList)
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

(define (package-lock-entry-list-count [entries : PackageLockEntryList]) : i64
  (match entries
    [(PackageLockEntryList.Nil) 0]
    [(PackageLockEntryList.Cons _ rest)
      (+ 1 (package-lock-entry-list-count (box-get rest)))]))

(define (package-lock-entry-list-lookup
  [entries : PackageLockEntryList]
  [alias : String]) : PackageLockMaybeEntry
  (match entries
    [(PackageLockEntryList.Nil) (PackageLockMaybeEntry.No)]
    [(PackageLockEntryList.Cons entry rest)
      (if (string.string-eq (struct-get entry alias) alias)
        (PackageLockMaybeEntry.Some entry)
        (package-lock-entry-list-lookup (box-get rest) alias))]))

(define (package-lock-entry-list-insert
  [entries : PackageLockEntryList]
  [entry : PackageLockEntry]) : ResultPackageLockEntryList
  (match entries
    [(PackageLockEntryList.Nil)
      (ResultPackageLockEntryList.Ok
        (PackageLockEntryList.Cons entry (box PackageLockEntryList.Nil)))]
    [(PackageLockEntryList.Cons head rest)
      (if (string.string-eq (struct-get head alias) (struct-get entry alias))
        (ResultPackageLockEntryList.Err
          (str_cat.str-cat
            "package-lock: duplicate dependency alias `"
            (struct-get entry alias)
            "`"))
        (if (package-lock-string-less?
          (struct-get entry alias)
          (struct-get head alias))
          (ResultPackageLockEntryList.Ok
            (PackageLockEntryList.Cons entry (box entries)))
          (match (package-lock-entry-list-insert (box-get rest) entry)
            [(ResultPackageLockEntryList.Err message)
              (ResultPackageLockEntryList.Err message)]
            [(ResultPackageLockEntryList.Ok next)
              (ResultPackageLockEntryList.Ok
                (PackageLockEntryList.Cons head (box next)))])))]))

(define (package-lock-field-string-value [ftail : Sexpr] [fname : String]) : ResultPackageLockString
  (match ftail
    [(Sexpr.Cons vhead vrest)
      (match (box-get vhead)
        [(Sexpr.Str val)
          (match (box-get vrest)
            [(Sexpr.Nil) (ResultPackageLockString.Ok val)]
            [_
              (ResultPackageLockString.Err
                (str_cat.str-cat
                  "package-lock: field `"
                  fname
                  "` takes a single string value"))])]
        [_
          (ResultPackageLockString.Err
            (str_cat.str-cat
              "package-lock: field `"
              fname
              "` must have a string value"))])]
    [_
      (ResultPackageLockString.Err
        (str_cat.str-cat
          "package-lock: field `"
          fname
          "` must have a string value"))]))

(define (package-lock-parse-pin-kind [value : String]) : ResultPackageLockPinKind
  (cond
    [(string.string-eq value "rev")
      (ResultPackageLockPinKind.Ok (PackageCachePinKind.Rev))]
    [(string.string-eq value "tag")
      (ResultPackageLockPinKind.Ok (PackageCachePinKind.Tag))]
    [(string.string-eq value "branch")
      (ResultPackageLockPinKind.Ok (PackageCachePinKind.Branch))]
    [else
      (ResultPackageLockPinKind.Err
        "package-lock: pin kind must be `rev`, `tag`, or `branch`")]))

(define (package-lock-pin-shape-error) : ResultPackageLockPin
  (ResultPackageLockPin.Err
    "package-lock: pin must be `(rev|tag|branch \"value\")`"))

(define (package-lock-pin-form [form : Sexpr]) : ResultPackageLockPin
  (match form
    [(Sexpr.Cons kind-node kind-tail)
      (match (box-get kind-node)
        [(Sexpr.Sym kind-name)
          (match (box-get kind-tail)
            [(Sexpr.Cons value-node end)
              (match (box-get end)
                [(Sexpr.Nil)
                  (match (box-get value-node)
                    [(Sexpr.Str pin-value)
                      (if (string.string-eq pin-value "")
                        (ResultPackageLockPin.Err
                          "package-lock: pin value must not be empty")
                        (match (package-lock-parse-pin-kind kind-name)
                          [(ResultPackageLockPinKind.Err message)
                            (ResultPackageLockPin.Err message)]
                          [(ResultPackageLockPinKind.Ok pin-kind)
                            (ResultPackageLockPin.Ok
                              (PackageLockPin pin-kind pin-value))]))]
                    [_ (package-lock-pin-shape-error)])]
                [_ (package-lock-pin-shape-error)])]
            [_ (package-lock-pin-shape-error)])]
        [_ (package-lock-pin-shape-error)])]
    [_ (package-lock-pin-shape-error)]))

(define (package-lock-field-pin-value [ftail : Sexpr]) : ResultPackageLockPin
  (match ftail
    [(Sexpr.Cons pin-form after-pin)
      (match (box-get after-pin)
        [(Sexpr.Nil) (package-lock-pin-form (box-get pin-form))]
        [_
          (ResultPackageLockPin.Err "package-lock: field `pin` takes one value")])]
    [_ (ResultPackageLockPin.Err "package-lock: field `pin` takes one value")]))

(define (package-lock-entry-fields
  [fields : Sexpr]
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
    [(Sexpr.Nil)
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
        [(string.string-eq alias "")
          (ResultPackageLockEntry.Err
            "package-lock: dependency alias must not be empty")]
        [(not (package-lock-alias-token-valid? alias))
          (ResultPackageLockEntry.Err
            "package-lock: dependency alias may only contain ASCII letters, digits, '-' and '_'")]
        [(string.string-eq url "")
          (ResultPackageLockEntry.Err
            "package-lock: dependency url must not be empty")]
        [(string.string-eq commit "")
          (ResultPackageLockEntry.Err
            "package-lock: dependency commit must not be empty")]
        [else
          (ResultPackageLockEntry.Ok
            (PackageLockEntry alias url pin-kind pin-value commit))])]
    [(Sexpr.Cons field rest)
      (match (box-get field)
        [(Sexpr.Cons fhead ftail)
          (match (box-get fhead)
            [(Sexpr.Sym fname)
              (cond
                [(string.string-eq fname "alias")
                  (if has-alias
                    (ResultPackageLockEntry.Err
                      "package-lock: duplicate dependency field `alias`")
                    (match (package-lock-field-string-value
                      (box-get ftail)
                      fname)
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
                [(string.string-eq fname "url")
                  (if has-url
                    (ResultPackageLockEntry.Err
                      "package-lock: duplicate dependency field `url`")
                    (match (package-lock-field-string-value
                      (box-get ftail)
                      fname)
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
                [(string.string-eq fname "pin")
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
                [(string.string-eq fname "commit")
                  (if has-commit
                    (ResultPackageLockEntry.Err
                      "package-lock: duplicate dependency field `commit`")
                    (match (package-lock-field-string-value
                      (box-get ftail)
                      fname)
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
                    (str_cat.str-cat
                      "package-lock: unknown dependency field `"
                      fname
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

(define (package-lock-entry-from-form [form : Sexpr]) : ResultPackageLockEntry
  (match form
    [(Sexpr.Cons head rest)
      (match (box-get head)
        [(Sexpr.Sym name)
          (if (string.string-eq name "dependency")
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
  [entries : Sexpr]
  [acc : PackageLockEntryList]) : ResultPackageLockEntryList
  (match entries
    [(Sexpr.Nil) (ResultPackageLockEntryList.Ok acc)]
    [(Sexpr.Cons entry rest)
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
  [fields : Sexpr]
  [version : String]
  [has-version : bool]
  [entries : PackageLockEntryList]
  [has-deps : bool]) : ResultPackageLockFile
  (match fields
    [(Sexpr.Nil)
      (cond
        [(not has-version)
          (ResultPackageLockFile.Err
            "package-lock: missing required field `version`")]
        [(not (string.string-eq version package-lock-version))
          (ResultPackageLockFile.Err
            (str_cat.str-cat "package-lock: unsupported version `" version "`"))]
        [(not has-deps)
          (ResultPackageLockFile.Err
            "package-lock: missing required field `dependencies`")]
        [else (ResultPackageLockFile.Ok (PackageLockFile version entries))])]
    [(Sexpr.Cons field rest)
      (match (box-get field)
        [(Sexpr.Cons fhead ftail)
          (match (box-get fhead)
            [(Sexpr.Sym fname)
              (if (string.string-eq fname "version")
                (if has-version
                  (ResultPackageLockFile.Err
                    "package-lock: duplicate field `version`")
                  (match (package-lock-field-string-value (box-get ftail) fname)
                    [(ResultPackageLockString.Err message)
                      (ResultPackageLockFile.Err message)]
                    [(ResultPackageLockString.Ok value)
                      (package-lock-fields
                        (box-get rest)
                        value
                        true
                        entries
                        has-deps)]))
                (if (string.string-eq fname "dependencies")
                  (if has-deps
                    (ResultPackageLockFile.Err
                      "package-lock: duplicate field `dependencies`")
                    (match (package-lock-dependencies-entries
                      (box-get ftail)
                      (PackageLockEntryList.Nil))
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
                    (str_cat.str-cat "package-lock: unknown field `" fname "`"))))]
            [_
              (ResultPackageLockFile.Err
                "package-lock: fields must start with a field name")])]
        [_ (ResultPackageLockFile.Err "package-lock: fields must be lists")])]
    [_ (ResultPackageLockFile.Err "package-lock: fields must be lists")]))

(define (package-lock-from-form [form : Sexpr]) : ResultPackageLockFile
  (match form
    [(Sexpr.Cons head rest)
      (match (box-get head)
        [(Sexpr.Sym name)
          (if (string.string-eq name "typelisp-lock")
            (package-lock-fields
              (box-get rest)
              ""
              false
              (PackageLockEntryList.Nil)
              false)
            (ResultPackageLockFile.Err
              (str_cat.str-cat "expected `typelisp-lock` form, got `" name "`")))]
        [_
          (ResultPackageLockFile.Err
            "package-lock: lockfile must start with `typelisp-lock`")])]
    [_
      (ResultPackageLockFile.Err
        "package-lock: lockfile must be a `(typelisp-lock ...)` form")]))

(define (package-lock-parse [source : String]) : ResultPackageLockFile
  (match (read-result (lex source))
    [(ResultSexpr.Err message)
      (ResultPackageLockFile.Err
        (string.string-append "package-lock: " message))]
    [(ResultSexpr.Ok form) (package-lock-from-form form)]))

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
                (set!
                  out
                  (string.string-concat3
                    out
                    (string.string-append slash quote)
                    ""))]
              [(= code 92)
                (set!
                  out
                  (string.string-concat3
                    out
                    (string.string-append slash slash)
                    ""))]
              [(= code 10)
                (set!
                  out
                  (string.string-concat3
                    out
                    (string.string-append slash "n")
                    ""))]
              [(= code 9)
                (set!
                  out
                  (string.string-concat3
                    out
                    (string.string-append slash "t")
                    ""))]
              [(= code 13)
                (set!
                  out
                  (string.string-concat3
                    out
                    (string.string-append slash "r")
                    ""))]
              [else
                (set!
                  out
                  (string.string-concat3 out (string.substring text i 1) ""))]))
          (set! i (+ i 1))))
      out)))

(define (package-lock-quote-string [text : String]) : String
  (string.string-append
    (package-lock-quote-text)
    (string.string-append
      (package-lock-escape-string text)
      (package-lock-quote-text))))

(define (package-lock-emit-string-field [field : String] [value : String]) : String
  (string.string-append
    "      ("
    (string.string-append
      field
      (string.string-append
        " "
        (string.string-append (package-lock-quote-string value) ")\n")))))

(define (package-lock-emit-final-string-field [field : String] [value : String]) : String
  (string.string-append
    "      ("
    (string.string-append
      field
      (string.string-append
        " "
        (string.string-append (package-lock-quote-string value) "))\n")))))

(define (package-lock-emit-pin-field [kind-name : String] [value : String]) : String
  (string.string-append
    "      (pin ("
    (string.string-append
      kind-name
      (string.string-append
        " "
        (string.string-append (package-lock-quote-string value) "))\n")))))

(define (package-lock-emit-entry [entry : PackageLockEntry]) : String
  (let
    [kind-name : String
      (package-cache-pin-kind-name (struct-get entry pin-kind))]
    (string.string-append
      "    (dependency\n"
      (string.string-append
        (package-lock-emit-string-field "alias" (struct-get entry alias))
        (string.string-append
          (package-lock-emit-string-field "url" (struct-get entry url))
          (string.string-append
            (package-lock-emit-pin-field kind-name (struct-get entry pin-value))
            (package-lock-emit-final-string-field
              "commit"
              (struct-get entry commit))))))))

(define (package-lock-emit-entries [entries : PackageLockEntryList]) : String
  (match entries
    [(PackageLockEntryList.Nil) ""]
    [(PackageLockEntryList.Cons entry rest)
      (string.string-append
        (package-lock-emit-entry entry)
        (package-lock-emit-entries (box-get rest)))]))

(define (package-lock-emit [lock : PackageLockFile]) : String
  (string.string-append
    "(typelisp-lock\n"
    (string.string-append
      "  (version \"v1\")\n"
      (string.string-append
        "  (dependencies\n"
        (string.string-append
          (package-lock-emit-entries (struct-get lock entries))
          "  ))\n")))))

(define (package-lock-valid-source) : String
  "(typelisp-lock (version \"v1\") (dependencies (dependency (alias \"zeta\") (url \"https://github.com/owner/zeta.git\") (pin (rev \"abcdef0123456789abcdef0123456789abcdef01\")) (commit \"abcdef0123456789abcdef0123456789abcdef01\")) (dependency (alias \"alpha\") (url \"https://github.com/owner/alpha.git\") (pin (branch \"main\")) (commit \"1111111111111111111111111111111111111111\"))))")

(define (package-lock-expected-emitted) : String
  (string.string-append
    "(typelisp-lock\n"
    (string.string-append
      "  (version \"v1\")\n"
      (string.string-append
        "  (dependencies\n"
        (string.string-append
          "    (dependency\n      (alias \"alpha\")\n      (url \"https://github.com/owner/alpha.git\")\n      (pin (branch \"main\"))\n      (commit \"1111111111111111111111111111111111111111\"))\n"
          (string.string-append
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
    (string.string-eq (struct-get entry alias) alias)
    (string.string-eq (struct-get entry url) url)
    (package-cache-pin-kind-eq? (struct-get entry pin-kind) kind)
    (string.string-eq (struct-get entry pin-value) pin-value)
    (string.string-eq (struct-get entry commit) commit)))

(define (package-lock-list-has-entry?
  [entries : PackageLockEntryList]
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
        [entries : PackageLockEntryList (struct-get lock entries)]
        (and
          (string.string-eq (struct-get lock version) package-lock-version)
          (= (package-lock-entry-list-count entries) 2)
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
      (string.string-eq
        (package-lock-emit lock)
        (package-lock-expected-emitted))]))

(define (package-lock-round-trip-ok?) : bool
  (match (package-lock-parse (package-lock-valid-source))
    [(ResultPackageLockFile.Err _) false]
    [(ResultPackageLockFile.Ok lock)
      (match (package-lock-parse (package-lock-emit lock))
        [(ResultPackageLockFile.Err _) false]
        [(ResultPackageLockFile.Ok again)
          (let
            [entries : PackageLockEntryList (struct-get again entries)]
            (and
              (= (package-lock-entry-list-count entries) 2)
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

(define (package-lock-parse-rejects? [source : String] [expected : String]) : bool
  (match (package-lock-parse source)
    [(ResultPackageLockFile.Err message) (string.string-eq message expected)]
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