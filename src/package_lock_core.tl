;; package_lock_core.tl - Deterministic typelisp.lock parser/emitter (#1993).
;;
;; This module models the lockfile data needed after remote package pins are
;; resolved. It parses and emits `typelisp.lock` S-expressions only; build-time
;; fetch/replay behavior remains owned by the package build pipeline.
(import "../stdlib/string.tl")
(import "../stdlib/str_cat.tl")
(import "read.tl")
(import "package_cache_core.tl")

(defstruct PackageLockEntry
  (alias String)
  (url String)
  (pin-kind PackageCachePinKind)
  (pin-value String)
  (commit String))

(defenum PackageLockEntryList
  (PackageLockEntryNil)
  (PackageLockEntryCons PackageLockEntry (Box PackageLockEntryList)))

(defstruct PackageLockFile
  (version String)
  (entries PackageLockEntryList))

(defstruct PackageLockPin
  (kind PackageCachePinKind)
  (value String))

(defenum PackageLockMaybeEntry
  (PackageLockNoEntry)
  (PackageLockSomeEntry PackageLockEntry))

(defenum ResultPackageLockString
  (OkPackageLockString String)
  (ErrPackageLockString String))

(defenum ResultPackageLockPinKind
  (OkPackageLockPinKind PackageCachePinKind)
  (ErrPackageLockPinKind String))

(defenum ResultPackageLockPin
  (OkPackageLockPin PackageLockPin)
  (ErrPackageLockPin String))

(defenum ResultPackageLockEntry
  (OkPackageLockEntry PackageLockEntry)
  (ErrPackageLockEntry String))

(defenum ResultPackageLockEntryList
  (OkPackageLockEntryList PackageLockEntryList)
  (ErrPackageLockEntryList String))

(defenum ResultPackageLockFile
  (OkPackageLockFile PackageLockFile)
  (ErrPackageLockFile String))

(define package-lock-version : String
  "v1")

(define (package-lock-char-code-at [text : String] [idx : i64]) : i64
  (cast (string-ref text idx) : i64))

(define (package-lock-string-less? [left : String] [right : String]) : bool
  (let
    [left-len : i64 (string-length left)]
    [right-len : i64 (string-length right)]
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
    [n : i64 (string-length value)]
    [i : i64 0]
    [ok : bool (> n 0)]
    (begin
      (while ok
        (if (< i n)
          (if (package-lock-alias-char? (string-ref value i))
            (set! i (+ i 1))
            (set! ok false))
          (set! ok false)))
      (= i n))))

(define (package-lock-entry-list-count [entries : PackageLockEntryList]) : i64
  (match entries
    [(PackageLockEntryNil) 0]
    [(PackageLockEntryCons _ rest)
      (+ 1 (package-lock-entry-list-count (box-get rest)))]))

(define (package-lock-entry-list-lookup
  [entries : PackageLockEntryList]
  [alias : String]) : PackageLockMaybeEntry
  (match entries
    [(PackageLockEntryNil) (PackageLockNoEntry)]
    [(PackageLockEntryCons entry rest)
      (if (string-eq (struct-get entry alias) alias)
        (PackageLockSomeEntry entry)
        (package-lock-entry-list-lookup (box-get rest) alias))]))

(define (package-lock-entry-list-insert
  [entries : PackageLockEntryList]
  [entry : PackageLockEntry]) : ResultPackageLockEntryList
  (match entries
    [(PackageLockEntryNil)
      (OkPackageLockEntryList
        (PackageLockEntryCons entry (box PackageLockEntryNil)))]
    [(PackageLockEntryCons head rest)
      (if (string-eq (struct-get head alias) (struct-get entry alias))
        (ErrPackageLockEntryList
          (str-cat
            "package-lock: duplicate dependency alias `"
            (struct-get entry alias)
            "`"))
        (if (package-lock-string-less?
          (struct-get entry alias)
          (struct-get head alias))
          (OkPackageLockEntryList (PackageLockEntryCons entry (box entries)))
          (match (package-lock-entry-list-insert (box-get rest) entry)
            [(ErrPackageLockEntryList message)
              (ErrPackageLockEntryList message)]
            [(OkPackageLockEntryList next)
              (OkPackageLockEntryList (PackageLockEntryCons head (box next)))])))]))

(define (package-lock-field-string-value [ftail : Sexpr] [fname : String]) : ResultPackageLockString
  (match ftail
    [(SCons vhead vrest)
      (match (box-get vhead)
        [(SStr val)
          (match (box-get vrest)
            [(SNil) (OkPackageLockString val)]
            [_
              (ErrPackageLockString
                (str-cat
                  "package-lock: field `"
                  fname
                  "` takes a single string value"))])]
        [_
          (ErrPackageLockString
            (str-cat "package-lock: field `" fname "` must have a string value"))])]
    [_
      (ErrPackageLockString
        (str-cat "package-lock: field `" fname "` must have a string value"))]))

(define (package-lock-parse-pin-kind [value : String]) : ResultPackageLockPinKind
  (cond
    [(string-eq value "rev") (OkPackageLockPinKind (PackageCachePinRev))]
    [(string-eq value "tag") (OkPackageLockPinKind (PackageCachePinTag))]
    [(string-eq value "branch") (OkPackageLockPinKind (PackageCachePinBranch))]
    [else
      (ErrPackageLockPinKind
        "package-lock: pin kind must be `rev`, `tag`, or `branch`")]))

(define (package-lock-pin-shape-error) : ResultPackageLockPin
  (ErrPackageLockPin "package-lock: pin must be `(rev|tag|branch \"value\")`"))

(define (package-lock-pin-form [form : Sexpr]) : ResultPackageLockPin
  (match form
    [(SCons kind-node kind-tail)
      (match (box-get kind-node)
        [(SSym kind-name)
          (match (box-get kind-tail)
            [(SCons value-node end)
              (match (box-get end)
                [(SNil)
                  (match (box-get value-node)
                    [(SStr pin-value)
                      (if (string-eq pin-value "")
                        (ErrPackageLockPin
                          "package-lock: pin value must not be empty")
                        (match (package-lock-parse-pin-kind kind-name)
                          [(ErrPackageLockPinKind message)
                            (ErrPackageLockPin message)]
                          [(OkPackageLockPinKind pin-kind)
                            (OkPackageLockPin
                              (PackageLockPin pin-kind pin-value))]))]
                    [_ (package-lock-pin-shape-error)])]
                [_ (package-lock-pin-shape-error)])]
            [_ (package-lock-pin-shape-error)])]
        [_ (package-lock-pin-shape-error)])]
    [_ (package-lock-pin-shape-error)]))

(define (package-lock-field-pin-value [ftail : Sexpr]) : ResultPackageLockPin
  (match ftail
    [(SCons pin-form after-pin)
      (match (box-get after-pin)
        [(SNil) (package-lock-pin-form (box-get pin-form))]
        [_ (ErrPackageLockPin "package-lock: field `pin` takes one value")])]
    [_ (ErrPackageLockPin "package-lock: field `pin` takes one value")]))

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
    [(SNil)
      (cond
        [(not has-alias)
          (ErrPackageLockEntry
            "package-lock: dependency missing required field `alias`")]
        [(not has-url)
          (ErrPackageLockEntry
            "package-lock: dependency missing required field `url`")]
        [(not has-pin)
          (ErrPackageLockEntry
            "package-lock: dependency missing required field `pin`")]
        [(not has-commit)
          (ErrPackageLockEntry
            "package-lock: dependency missing required field `commit`")]
        [(string-eq alias "")
          (ErrPackageLockEntry
            "package-lock: dependency alias must not be empty")]
        [(not (package-lock-alias-token-valid? alias))
          (ErrPackageLockEntry
            "package-lock: dependency alias may only contain ASCII letters, digits, '-' and '_'")]
        [(string-eq url "")
          (ErrPackageLockEntry "package-lock: dependency url must not be empty")]
        [(string-eq commit "")
          (ErrPackageLockEntry
            "package-lock: dependency commit must not be empty")]
        [else
          (OkPackageLockEntry
            (PackageLockEntry alias url pin-kind pin-value commit))])]
    [(SCons field rest)
      (match (box-get field)
        [(SCons fhead ftail)
          (match (box-get fhead)
            [(SSym fname)
              (cond
                [(string-eq fname "alias")
                  (if has-alias
                    (ErrPackageLockEntry
                      "package-lock: duplicate dependency field `alias`")
                    (match (package-lock-field-string-value
                      (box-get ftail)
                      fname)
                      [(ErrPackageLockString message)
                        (ErrPackageLockEntry message)]
                      [(OkPackageLockString value)
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
                [(string-eq fname "url")
                  (if has-url
                    (ErrPackageLockEntry
                      "package-lock: duplicate dependency field `url`")
                    (match (package-lock-field-string-value
                      (box-get ftail)
                      fname)
                      [(ErrPackageLockString message)
                        (ErrPackageLockEntry message)]
                      [(OkPackageLockString value)
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
                [(string-eq fname "pin")
                  (if has-pin
                    (ErrPackageLockEntry
                      "package-lock: duplicate dependency field `pin`")
                    (match (package-lock-field-pin-value (box-get ftail))
                      [(ErrPackageLockPin message)
                        (ErrPackageLockEntry message)]
                      [(OkPackageLockPin pin)
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
                [(string-eq fname "commit")
                  (if has-commit
                    (ErrPackageLockEntry
                      "package-lock: duplicate dependency field `commit`")
                    (match (package-lock-field-string-value
                      (box-get ftail)
                      fname)
                      [(ErrPackageLockString message)
                        (ErrPackageLockEntry message)]
                      [(OkPackageLockString value)
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
                  (ErrPackageLockEntry
                    (str-cat
                      "package-lock: unknown dependency field `"
                      fname
                      "`"))])]
            [_
              (ErrPackageLockEntry
                "package-lock: dependency fields must start with a field name")])]
        [_
          (ErrPackageLockEntry "package-lock: dependency fields must be lists")])]
    [_ (ErrPackageLockEntry "package-lock: dependency fields must be lists")]))

(define (package-lock-entry-from-form [form : Sexpr]) : ResultPackageLockEntry
  (match form
    [(SCons head rest)
      (match (box-get head)
        [(SSym name)
          (if (string-eq name "dependency")
            (package-lock-entry-fields
              (box-get rest)
              ""
              false
              ""
              false
              (PackageCachePinRev)
              ""
              false
              ""
              false)
            (ErrPackageLockEntry
              "package-lock: dependency entries must start with `dependency`"))]
        [_
          (ErrPackageLockEntry
            "package-lock: dependency entries must start with `dependency`")])]
    [_ (ErrPackageLockEntry "package-lock: dependency entries must be lists")]))

(define (package-lock-dependencies-entries
  [entries : Sexpr]
  [acc : PackageLockEntryList]) : ResultPackageLockEntryList
  (match entries
    [(SNil) (OkPackageLockEntryList acc)]
    [(SCons entry rest)
      (match (package-lock-entry-from-form (box-get entry))
        [(ErrPackageLockEntry message) (ErrPackageLockEntryList message)]
        [(OkPackageLockEntry parsed)
          (match (package-lock-entry-list-insert acc parsed)
            [(ErrPackageLockEntryList message)
              (ErrPackageLockEntryList message)]
            [(OkPackageLockEntryList next)
              (package-lock-dependencies-entries (box-get rest) next)])])]
    [_
      (ErrPackageLockEntryList
        "package-lock: `dependencies` must contain dependency lists")]))

(define (package-lock-fields
  [fields : Sexpr]
  [version : String]
  [has-version : bool]
  [entries : PackageLockEntryList]
  [has-deps : bool]) : ResultPackageLockFile
  (match fields
    [(SNil)
      (cond
        [(not has-version)
          (ErrPackageLockFile "package-lock: missing required field `version`")]
        [(not (string-eq version package-lock-version))
          (ErrPackageLockFile
            (str-cat "package-lock: unsupported version `" version "`"))]
        [(not has-deps)
          (ErrPackageLockFile
            "package-lock: missing required field `dependencies`")]
        [else (OkPackageLockFile (PackageLockFile version entries))])]
    [(SCons field rest)
      (match (box-get field)
        [(SCons fhead ftail)
          (match (box-get fhead)
            [(SSym fname)
              (if (string-eq fname "version")
                (if has-version
                  (ErrPackageLockFile "package-lock: duplicate field `version`")
                  (match (package-lock-field-string-value (box-get ftail) fname)
                    [(ErrPackageLockString message)
                      (ErrPackageLockFile message)]
                    [(OkPackageLockString value)
                      (package-lock-fields
                        (box-get rest)
                        value
                        true
                        entries
                        has-deps)]))
                (if (string-eq fname "dependencies")
                  (if has-deps
                    (ErrPackageLockFile
                      "package-lock: duplicate field `dependencies`")
                    (match (package-lock-dependencies-entries
                      (box-get ftail)
                      (PackageLockEntryNil))
                      [(ErrPackageLockEntryList message)
                        (ErrPackageLockFile message)]
                      [(OkPackageLockEntryList parsed)
                        (package-lock-fields
                          (box-get rest)
                          version
                          has-version
                          parsed
                          true)]))
                  (ErrPackageLockFile
                    (str-cat "package-lock: unknown field `" fname "`"))))]
            [_
              (ErrPackageLockFile
                "package-lock: fields must start with a field name")])]
        [_ (ErrPackageLockFile "package-lock: fields must be lists")])]
    [_ (ErrPackageLockFile "package-lock: fields must be lists")]))

(define (package-lock-from-form [form : Sexpr]) : ResultPackageLockFile
  (match form
    [(SCons head rest)
      (match (box-get head)
        [(SSym name)
          (if (string-eq name "typelisp-lock")
            (package-lock-fields
              (box-get rest)
              ""
              false
              (PackageLockEntryNil)
              false)
            (ErrPackageLockFile
              (str-cat "expected `typelisp-lock` form, got `" name "`")))]
        [_
          (ErrPackageLockFile
            "package-lock: lockfile must start with `typelisp-lock`")])]
    [_
      (ErrPackageLockFile
        "package-lock: lockfile must be a `(typelisp-lock ...)` form")]))

(define (package-lock-parse [source : String]) : ResultPackageLockFile
  (match (read-result (lex source))
    [(ErrSexpr message)
      (ErrPackageLockFile (string-append "package-lock: " message))]
    [(OkSexpr form) (package-lock-from-form form)]))

(define (package-lock-quote-text) : String
  "\"")

(define (package-lock-backslash-text) : String
  "\\")

(define (package-lock-escape-string [text : String]) : String
  (let
    [n : i64 (string-length text)]
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
                (set! out (string-append out (string-append slash quote)))]
              [(= code 92)
                (set! out (string-append out (string-append slash slash)))]
              [(= code 10)
                (set! out (string-append out (string-append slash "n")))]
              [(= code 9)
                (set! out (string-append out (string-append slash "t")))]
              [(= code 13)
                (set! out (string-append out (string-append slash "r")))]
              [else (set! out (string-append out (substring text i 1)))]))
          (set! i (+ i 1))))
      out)))

(define (package-lock-quote-string [text : String]) : String
  (string-append
    (package-lock-quote-text)
    (string-append (package-lock-escape-string text) (package-lock-quote-text))))

(define (package-lock-emit-string-field [field : String] [value : String]) : String
  (string-append
    "      ("
    (string-append
      field
      (string-append
        " "
        (string-append (package-lock-quote-string value) ")\n")))))

(define (package-lock-emit-final-string-field [field : String] [value : String]) : String
  (string-append
    "      ("
    (string-append
      field
      (string-append
        " "
        (string-append (package-lock-quote-string value) "))\n")))))

(define (package-lock-emit-pin-field [kind-name : String] [value : String]) : String
  (string-append
    "      (pin ("
    (string-append
      kind-name
      (string-append
        " "
        (string-append (package-lock-quote-string value) "))\n")))))

(define (package-lock-emit-entry [entry : PackageLockEntry]) : String
  (let
    [kind-name : String
      (package-cache-pin-kind-name (struct-get entry pin-kind))]
    (string-append
      "    (dependency\n"
      (string-append
        (package-lock-emit-string-field "alias" (struct-get entry alias))
        (string-append
          (package-lock-emit-string-field "url" (struct-get entry url))
          (string-append
            (package-lock-emit-pin-field kind-name (struct-get entry pin-value))
            (package-lock-emit-final-string-field
              "commit"
              (struct-get entry commit))))))))

(define (package-lock-emit-entries [entries : PackageLockEntryList]) : String
  (match entries
    [(PackageLockEntryNil) ""]
    [(PackageLockEntryCons entry rest)
      (string-append
        (package-lock-emit-entry entry)
        (package-lock-emit-entries (box-get rest)))]))

(define (package-lock-emit [lock : PackageLockFile]) : String
  (string-append
    "(typelisp-lock\n"
    (string-append
      "  (version \"v1\")\n"
      (string-append
        "  (dependencies\n"
        (string-append
          (package-lock-emit-entries (struct-get lock entries))
          "  ))\n")))))

(define (package-lock-valid-source) : String
  "(typelisp-lock (version \"v1\") (dependencies (dependency (alias \"zeta\") (url \"https://github.com/owner/zeta.git\") (pin (rev \"abcdef0123456789abcdef0123456789abcdef01\")) (commit \"abcdef0123456789abcdef0123456789abcdef01\")) (dependency (alias \"alpha\") (url \"https://github.com/owner/alpha.git\") (pin (branch \"main\")) (commit \"1111111111111111111111111111111111111111\"))))")

(define (package-lock-expected-emitted) : String
  (string-append
    "(typelisp-lock\n"
    (string-append
      "  (version \"v1\")\n"
      (string-append
        "  (dependencies\n"
        (string-append
          "    (dependency\n      (alias \"alpha\")\n      (url \"https://github.com/owner/alpha.git\")\n      (pin (branch \"main\"))\n      (commit \"1111111111111111111111111111111111111111\"))\n"
          (string-append
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
    (string-eq (struct-get entry alias) alias)
    (string-eq (struct-get entry url) url)
    (package-cache-pin-kind-eq? (struct-get entry pin-kind) kind)
    (string-eq (struct-get entry pin-value) pin-value)
    (string-eq (struct-get entry commit) commit)))

(define (package-lock-list-has-entry?
  [entries : PackageLockEntryList]
  [alias : String]
  [url : String]
  [kind : PackageCachePinKind]
  [pin-value : String]
  [commit : String]) : bool
  (match (package-lock-entry-list-lookup entries alias)
    [(PackageLockNoEntry) false]
    [(PackageLockSomeEntry entry)
      (package-lock-entry-matches? entry alias url kind pin-value commit)]))

(define (package-lock-valid-parse-ok?) : bool
  (match (package-lock-parse (package-lock-valid-source))
    [(ErrPackageLockFile _) false]
    [(OkPackageLockFile lock)
      (let
        [entries : PackageLockEntryList (struct-get lock entries)]
        (and
          (string-eq (struct-get lock version) package-lock-version)
          (= (package-lock-entry-list-count entries) 2)
          (package-lock-list-has-entry?
            entries
            "alpha"
            "https://github.com/owner/alpha.git"
            (PackageCachePinBranch)
            "main"
            "1111111111111111111111111111111111111111")
          (package-lock-list-has-entry?
            entries
            "zeta"
            "https://github.com/owner/zeta.git"
            (PackageCachePinRev)
            "abcdef0123456789abcdef0123456789abcdef01"
            "abcdef0123456789abcdef0123456789abcdef01")))]))

(define (package-lock-emit-stable-ok?) : bool
  (match (package-lock-parse (package-lock-valid-source))
    [(ErrPackageLockFile _) false]
    [(OkPackageLockFile lock)
      (string-eq (package-lock-emit lock) (package-lock-expected-emitted))]))

(define (package-lock-round-trip-ok?) : bool
  (match (package-lock-parse (package-lock-valid-source))
    [(ErrPackageLockFile _) false]
    [(OkPackageLockFile lock)
      (match (package-lock-parse (package-lock-emit lock))
        [(ErrPackageLockFile _) false]
        [(OkPackageLockFile again)
          (let
            [entries : PackageLockEntryList (struct-get again entries)]
            (and
              (= (package-lock-entry-list-count entries) 2)
              (package-lock-list-has-entry?
                entries
                "alpha"
                "https://github.com/owner/alpha.git"
                (PackageCachePinBranch)
                "main"
                "1111111111111111111111111111111111111111")
              (package-lock-list-has-entry?
                entries
                "zeta"
                "https://github.com/owner/zeta.git"
                (PackageCachePinRev)
                "abcdef0123456789abcdef0123456789abcdef01"
                "abcdef0123456789abcdef0123456789abcdef01")))])]))

(define (package-lock-parse-rejects? [source : String] [expected : String]) : bool
  (match (package-lock-parse source)
    [(ErrPackageLockFile message) (string-eq message expected)]
    [(OkPackageLockFile _) false]))

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
    (begin
      (panic "package-lock: self-test mismatch")
      ;; lint-allow: unreachable-code
      1)))

(test
  package-lock-parse-emit-round-trip
  (if (package-lock-self-test-ok?)
    unit
    (panic "package-lock: inline self-test mismatch")))