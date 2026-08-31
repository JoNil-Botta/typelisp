;; package_lock_core.tl - Deterministic typelisp.lock parser/emitter/transaction.
;;
;; This module models the lockfile data needed after remote package pins are
;; resolved. It parses and emits `typelisp.lock` S-expressions and owns the
;; shared atomic, conflict-aware filesystem commit boundary. Build-time
;; fetch/replay behavior remains owned by the package build pipeline.
(import compiler_owned_view as owned_view)
(import stdlib.byte_buf)
(import stdlib.env)
(import stdlib.fs)
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.io)
(import stdlib.string)
(import stdlib.time)
(import stdlib.vector)
(import compiler_intern as ci)
(import lex as lexer)
(import read as reader)
(import package_cache_core)

(defmacro (package-lock-global-shared-view [place : Expr]) : Expr
  (cfg
    stage0-seed-bootstrap
    place
    `(unsafe
      (ptr-read (ptr-addr-of ,place)))))

(defstruct PackageLockEntry
  (alias String)
  (url String)
  (pin-kind package_cache_core.PackageCachePinKind)
  (pin-value String)
  (commit String))

(import (vector.vector PackageLockEntry core) as package_lock_entry_vec)

(defstruct PackageLockFile
  (version String)
  (entries package_lock_entry_vec.Vec))

(defstruct PackageLockPin
  (kind package_cache_core.PackageCachePinKind)
  (value String))

(define (package-lock-symbol-text [name-id : ci.InternSyntaxId]) : String
  (reader.symbol-text-for-syntax-id name-id))

(defenum PackageLockMaybeEntry
  (No)
  (Some PackageLockEntry))

(defenum ResultPackageLockString
  (Ok String)
  (Err String))

(defenum ResultPackageLockPinKind
  (Ok package_cache_core.PackageCachePinKind)
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

(defstruct PackageLockSnapshot
  (path String)
  (source String)
  (existed bool))

(defenum ResultPackageLockSnapshot
  (Ok PackageLockSnapshot)
  (Err String))

(defenum PackageLockCommitOutcome
  (Unchanged String)
  (Reused String)
  (Replaced String))

(defenum ResultPackageLockCommit
  (Ok PackageLockCommitOutcome)
  (Err String))

(define package-lock-stage-sequence : i64
  0)
(define package-lock-version : String
  "v1")

(define (package-lock-version-shared-view) : String
  (package-lock-global-shared-view package-lock-version))

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
          [lc : i64
            (package-lock-char-code-at
              (owned_view.compiler-owned-shared-view left)
              idx)]
          [rc : i64
            (package-lock-char-code-at
              (owned_view.compiler-owned-shared-view right)
              idx)]
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
  (PackageLockEntry "" "" (package_cache_core.PackageCachePinKind.Rev) "" ""))

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
      (if (string.eq entry.alias alias)
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
      (if (string.eq head.alias alias)
        -1
        (if (package-lock-string-less?
          (owned_view.compiler-owned-shared-view alias)
          head.alias)
          index
          (package-lock-entry-list-insert-position entries alias (+ index 1)))))))

(define (package-lock-entry-list-insert-at!
  [entries : (&mut entries package_lock_entry_vec.Vec)]
  [entry : PackageLockEntry]
  [index : i64]) : unit
  (begin
    (package_lock_entry_vec.push-ref!
      entries
      (package-lock-entry-list-fallback))
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
              (package_lock_entry_vec.set-ref! entries write previous)
              (set! write (- write 1)))))
        (package_lock_entry_vec.set-ref! entries index entry)))))

(define (package-lock-entry-list-insert
  [entries : package_lock_entry_vec.Vec]
  [entry : PackageLockEntry]) : ResultPackageLockEntryList
  (let
    [next : package_lock_entry_vec.Vec
      (package-lock-global-shared-view entries)]
    [index : i64
      (package-lock-entry-list-insert-position
        (& next)
        (owned_view.compiler-owned-shared-view entry.alias)
        0)]
    (if (< index 0)
      (ResultPackageLockEntryList.Err
        (str_cat.str-cat
          "package-lock: duplicate dependency alias `"
          entry.alias
          "`"))
      (begin
        (package-lock-entry-list-insert-at! (&mut next) entry index)
        (ResultPackageLockEntryList.Ok next)))))

(define (package-lock-field-string-value
  [ftail : reader.Sexpr]
  [fname : String]) : ResultPackageLockString
  (match (reader.sexpr-view ftail)
    [(reader.SexprView.Cons vhead vrest)
      (match (reader.sexpr-view vhead)
        [(reader.SexprView.Str val-id)
          (match (reader.sexpr-view vrest)
            [(reader.SexprView.Nil)
              (ResultPackageLockString.Ok (ci.intern-id-str val-id))]
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
    [(string.eq value "rev")
      (ResultPackageLockPinKind.Ok (package_cache_core.PackageCachePinKind.Rev))]
    [(string.eq value "tag")
      (ResultPackageLockPinKind.Ok (package_cache_core.PackageCachePinKind.Tag))]
    [(string.eq value "branch")
      (ResultPackageLockPinKind.Ok
        (package_cache_core.PackageCachePinKind.Branch))]
    [else
      (ResultPackageLockPinKind.Err
        "package-lock: pin kind must be `rev`, `tag`, or `branch`")]))

(define (package-lock-pin-shape-error) : ResultPackageLockPin
  (ResultPackageLockPin.Err
    "package-lock: pin must be `(rev|tag|branch \"value\")`"))

(define (package-lock-pin-form [form : reader.Sexpr]) : ResultPackageLockPin
  (match (reader.sexpr-view form)
    [(reader.SexprView.Cons kind-node kind-tail)
      (match (reader.sexpr-view kind-node)
        [(reader.SexprView.Sym kind-name)
          (match (reader.sexpr-view kind-tail)
            [(reader.SexprView.Cons value-node end)
              (match (reader.sexpr-view end)
                [(reader.SexprView.Nil)
                  (match (reader.sexpr-view value-node)
                    [(reader.SexprView.Str pin-value-id)
                      (let
                        [pin-value : String (ci.intern-id-str pin-value-id)]
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
  (match (reader.sexpr-view ftail)
    [(reader.SexprView.Cons pin-form after-pin)
      (match (reader.sexpr-view after-pin)
        [(reader.SexprView.Nil) (package-lock-pin-form pin-form)]
        [_
          (ResultPackageLockPin.Err "package-lock: field `pin` takes one value")])]
    [_ (ResultPackageLockPin.Err "package-lock: field `pin` takes one value")]))

(define (package-lock-entry-fields
  [fields : reader.Sexpr]
  [alias : String]
  [has-alias : bool]
  [url : String]
  [has-url : bool]
  [pin-kind : package_cache_core.PackageCachePinKind]
  [pin-value : String]
  [has-pin : bool]
  [commit : String]
  [has-commit : bool]) : ResultPackageLockEntry
  (match (reader.sexpr-view fields)
    [(reader.SexprView.Nil)
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
        [(not
            (package-lock-alias-token-valid?
              (owned_view.compiler-owned-shared-view alias)))
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
    [(reader.SexprView.Cons field rest)
      (match (reader.sexpr-view field)
        [(reader.SexprView.Cons fhead ftail)
          (match (reader.sexpr-view fhead)
            [(reader.SexprView.Sym fname)
              (cond
                [(string.eq (package-lock-symbol-text fname) "alias")
                  (if has-alias
                    (ResultPackageLockEntry.Err
                      "package-lock: duplicate dependency field `alias`")
                    (match (package-lock-field-string-value
                      ftail
                      (package-lock-symbol-text fname))
                      [(ResultPackageLockString.Err message)
                        (ResultPackageLockEntry.Err message)]
                      [(ResultPackageLockString.Ok value)
                        (package-lock-entry-fields
                          rest
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
                      ftail
                      (package-lock-symbol-text fname))
                      [(ResultPackageLockString.Err message)
                        (ResultPackageLockEntry.Err message)]
                      [(ResultPackageLockString.Ok value)
                        (package-lock-entry-fields
                          rest
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
                    (match (package-lock-field-pin-value ftail)
                      [(ResultPackageLockPin.Err message)
                        (ResultPackageLockEntry.Err message)]
                      [(ResultPackageLockPin.Ok pin)
                        (package-lock-entry-fields
                          rest
                          alias
                          has-alias
                          url
                          has-url
                          pin.kind
                          pin.value
                          true
                          commit
                          has-commit)]))]
                [(string.eq (package-lock-symbol-text fname) "commit")
                  (if has-commit
                    (ResultPackageLockEntry.Err
                      "package-lock: duplicate dependency field `commit`")
                    (match (package-lock-field-string-value
                      ftail
                      (package-lock-symbol-text fname))
                      [(ResultPackageLockString.Err message)
                        (ResultPackageLockEntry.Err message)]
                      [(ResultPackageLockString.Ok value)
                        (package-lock-entry-fields
                          rest
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
  (match (reader.sexpr-view form)
    [(reader.SexprView.Cons head rest)
      (match (reader.sexpr-view head)
        [(reader.SexprView.Sym name)
          (if (string.eq (package-lock-symbol-text name) "dependency")
            (package-lock-entry-fields
              rest
              ""
              false
              ""
              false
              (package_cache_core.PackageCachePinKind.Rev)
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
  (match (reader.sexpr-view entries)
    [(reader.SexprView.Nil) (ResultPackageLockEntryList.Ok acc)]
    [(reader.SexprView.Cons entry rest)
      (match (package-lock-entry-from-form entry)
        [(ResultPackageLockEntry.Err message)
          (ResultPackageLockEntryList.Err message)]
        [(ResultPackageLockEntry.Ok parsed)
          (match (package-lock-entry-list-insert acc parsed)
            [(ResultPackageLockEntryList.Err message)
              (ResultPackageLockEntryList.Err message)]
            [(ResultPackageLockEntryList.Ok next)
              (package-lock-dependencies-entries rest next)])])]
    [_
      (ResultPackageLockEntryList.Err
        "package-lock: `dependencies` must contain dependency lists")]))

(define (package-lock-fields
  [fields : reader.Sexpr]
  [version : String]
  [has-version : bool]
  [entries : package_lock_entry_vec.Vec]
  [has-deps : bool]) : ResultPackageLockFile
  (match (reader.sexpr-view fields)
    [(reader.SexprView.Nil)
      (cond
        [(not has-version)
          (ResultPackageLockFile.Err
            "package-lock: missing required field `version`")]
        [(not (string.eq version package-lock-version))
          (ResultPackageLockFile.Err
            (str_cat.str-cat "package-lock: unsupported version `" version "`"))]
        [(not has-deps)
          (ResultPackageLockFile.Err
            "package-lock: missing required field `dependencies`")]
        [else (ResultPackageLockFile.Ok (PackageLockFile version entries))])]
    [(reader.SexprView.Cons field rest)
      (match (reader.sexpr-view field)
        [(reader.SexprView.Cons fhead ftail)
          (match (reader.sexpr-view fhead)
            [(reader.SexprView.Sym fname)
              (if (string.eq (package-lock-symbol-text fname) "version")
                (if has-version
                  (ResultPackageLockFile.Err
                    "package-lock: duplicate field `version`")
                  (match (package-lock-field-string-value
                    ftail
                    (package-lock-symbol-text fname))
                    [(ResultPackageLockString.Err message)
                      (ResultPackageLockFile.Err message)]
                    [(ResultPackageLockString.Ok value)
                      (package-lock-fields rest value true entries has-deps)]))
                (if (string.eq (package-lock-symbol-text fname) "dependencies")
                  (if has-deps
                    (ResultPackageLockFile.Err
                      "package-lock: duplicate field `dependencies`")
                    (match (package-lock-dependencies-entries
                      ftail
                      (package_lock_entry_vec.new))
                      [(ResultPackageLockEntryList.Err message)
                        (ResultPackageLockFile.Err message)]
                      [(ResultPackageLockEntryList.Ok parsed)
                        (package-lock-fields
                          rest
                          version
                          has-version
                          parsed
                          true)]))
                  (ResultPackageLockFile.Err
                    (str_cat.str-cat
                      "package-lock: unknown field `"
                      (package-lock-symbol-text fname)
                      "`"))))]
            [_
              (ResultPackageLockFile.Err
                "package-lock: fields must start with a field name")])]
        [_ (ResultPackageLockFile.Err "package-lock: fields must be lists")])]
    [_ (ResultPackageLockFile.Err "package-lock: fields must be lists")]))

(define (package-lock-from-form [form : reader.Sexpr]) : ResultPackageLockFile
  (match (reader.sexpr-view form)
    [(reader.SexprView.Cons head rest)
      (match (reader.sexpr-view head)
        [(reader.SexprView.Sym name)
          (if (string.eq (package-lock-symbol-text name) "typelisp-lock")
            (package-lock-fields
              rest
              ""
              false
              (package_lock_entry_vec.new)
              false)
            (ResultPackageLockFile.Err
              (str_cat.str-cat
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
  (match (reader.result (lexer.lex source))
    [(reader.ResultSexpr.Err message)
      (ResultPackageLockFile.Err (str_cat.str-cat "package-lock: " message))]
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
            [code : i64
              (package-lock-char-code-at
                (owned_view.compiler-owned-shared-view text)
                i)]
            (cond
              [(= code 34)
                (set!
                  out
                  (str_cat.str-cat
                    out
                    (owned_view.compiler-owned-shared-view slash)
                    (owned_view.compiler-owned-shared-view quote)
                    ""))]
              [(= code 92)
                (set!
                  out
                  (str_cat.str-cat
                    out
                    (owned_view.compiler-owned-shared-view slash)
                    (owned_view.compiler-owned-shared-view slash)
                    ""))]
              [(= code 10)
                (set!
                  out
                  (str_cat.str-cat
                    out
                    (owned_view.compiler-owned-shared-view slash)
                    "n"
                    ""))]
              [(= code 9)
                (set!
                  out
                  (str_cat.str-cat
                    out
                    (owned_view.compiler-owned-shared-view slash)
                    "t"
                    ""))]
              [(= code 13)
                (set!
                  out
                  (str_cat.str-cat
                    out
                    (owned_view.compiler-owned-shared-view slash)
                    "r"
                    ""))]
              [else
                (set! out (str_cat.str-cat out (string.substring text i 1) ""))]))
          (set! i (+ i 1))))
      out)))

(define (package-lock-quote-string [text : String]) : String
  (str_cat.str-cat
    (package-lock-quote-text)
    (package-lock-escape-string text)
    (package-lock-quote-text)))

(define (package-lock-emit-string-field [field : String] [value : String]) : String
  (str_cat.str-cat "      (" field " " (package-lock-quote-string value) ")\n"))

(define (package-lock-emit-final-string-field [field : String] [value : String]) : String
  (str_cat.str-cat "      (" field " " (package-lock-quote-string value) "))\n"))

(define (package-lock-emit-pin-field [kind-name : String] [value : String]) : String
  (str_cat.str-cat
    "      (pin ("
    kind-name
    " "
    (package-lock-quote-string value)
    "))\n"))

(define (package-lock-emit-entry [entry : PackageLockEntry]) : String
  (let
    [kind-name : String
      (package_cache_core.package-cache-pin-kind-name entry.pin-kind)]
    (str_cat.str-cat
      "    (dependency\n"
      (package-lock-emit-string-field "alias" entry.alias)
      (package-lock-emit-string-field "url" entry.url)
      (package-lock-emit-pin-field kind-name entry.pin-value)
      (package-lock-emit-final-string-field "commit" entry.commit))))

(define (package-lock-emit-entries-from
  [entries : (& entries package_lock_entry_vec.Vec)]
  [index : i64]) : String
  (if (>= index (package_lock_entry_vec.len entries))
    ""
    (str_cat.str-cat
      (package-lock-emit-entry
        (package_lock_entry_vec.get
          entries
          index
          (package-lock-entry-list-fallback)))
      (package-lock-emit-entries-from entries (+ index 1)))))

(define (package-lock-emit-entries [entries : package_lock_entry_vec.Vec]) : String
  (package-lock-emit-entries-from (& entries) 0))

(define (package-lock-emit [lock : PackageLockFile]) : String
  (str_cat.str-cat
    "(typelisp-lock\n"
    "  (version \"v1\")\n"
    "  (dependencies\n"
    (package-lock-emit-entries lock.entries)
    "  ))\n"))

(define (package-lock-transaction-error
  [phase : String]
  [path : String]
  [detail : String]) : String
  (str_cat.str-cat
    "package-lock transaction "
    phase
    " failed for '"
    path
    "': "
    detail))

(define (package-lock-transaction-read [path : String]) : ResultPackageLockSnapshot
  (match (io.try-file-exists? (& path))
    [(io.ErrIoBool error)
      (ResultPackageLockSnapshot.Err
        (package-lock-transaction-error "read" path (io.error-message error)))]
    [(io.OkIoBool exists)
      (if exists
        (match (io.try-read-file (& path))
          [(io.ErrIoBytes error)
            (ResultPackageLockSnapshot.Err
              (package-lock-transaction-error
                "read"
                path
                (io.error-message error)))]
          [(io.OkIoBytes contents)
            (ResultPackageLockSnapshot.Ok
              (PackageLockSnapshot path (byte_buf.to-string contents) true))])
        (ResultPackageLockSnapshot.Ok (PackageLockSnapshot path "" false)))]))

(define (package-lock-snapshot-identity-eq?
  [left : (& left PackageLockSnapshot)]
  [right : (& right PackageLockSnapshot)]) : bool
  (and
    (= left.existed right.existed)
    (if left.existed
      (string.eq left.source right.source)
      true)))

(define (package-lock-snapshot-is-source?
  [snapshot : (& snapshot PackageLockSnapshot)]
  [source : String]) : bool
  (and snapshot.existed (string.eq snapshot.source source)))

(define (package-lock-io-already-exists? [error : io.IoError]) : bool
  (match error
    [(io.IoSystemCode code _) (= code fs.fs-status-already-exists)]
    [_ false]))

(define (package-lock-io-retryable-replace? [error : io.IoError]) : bool
  (match error
    [(io.IoSystemCode code _) (or (= code 32) (= code 33))]
    [_ false]))

(define (package-lock-transaction-fault? [phase : String]) : bool
  (let
    [name : String "TYPELISP_PACKAGE_LOCK_TEST_FAULT"]
    (match (env.get (& name))
      [(env.EnvNoString) false]
      [(env.EnvSomeString value) (string.eq value phase)])))

(define (package-lock-transaction-pause? [phase : String]) : bool
  (let
    [name : String "TYPELISP_PACKAGE_LOCK_TEST_PAUSE"]
    (match (env.get (& name))
      [(env.EnvNoString) false]
      [(env.EnvSomeString value) (string.eq value phase)])))

(define (package-lock-transaction-wait-release [path : String]) : ResultPackageLockString
  (let
    [attempt : i64 0]
    [done : bool false]
    [error-message : String ""]
    (begin
      (while (and (not done) (< attempt 6000))
        (match (io.try-file-exists? (& path))
          [(io.ErrIoBool error)
            (begin
              (set! error-message (io.error-message error))
              (set! done true))]
          [(io.OkIoBool exists)
            (if exists
              (match (time.sleep-ms 10)
                [(time.ErrTimeUnit error)
                  (begin
                    (set! error-message (time.error-message error))
                    (set! done true))]
                [(time.OkTimeUnit) (set! attempt (+ attempt 1))])
              (set! done true))]))
      (if (> (string.string-length error-message) 0)
        (ResultPackageLockString.Err error-message)
        (if (>= attempt 6000)
          (ResultPackageLockString.Err
            "package-lock transaction test pause timed out")
          (ResultPackageLockString.Ok ""))))))

(define (package-lock-transaction-maybe-pause [phase : String]) : ResultPackageLockString
  (if (package-lock-transaction-pause? phase)
    (let
      [name : String "TYPELISP_PACKAGE_LOCK_TEST_RELEASE_FILE"]
      (match (env.get (& name))
        [(env.EnvNoString)
          (match (time.sleep-ms 2000)
            [(time.ErrTimeUnit error)
              (ResultPackageLockString.Err (time.error-message error))]
            [(time.OkTimeUnit) (ResultPackageLockString.Ok "")])]
        [(env.EnvSomeString path) (package-lock-transaction-wait-release path)]))
    (ResultPackageLockString.Ok "")))

(define (package-lock-stage-next-sequence) : i64
  (begin
    (set! package-lock-stage-sequence (+ package-lock-stage-sequence 1))
    package-lock-stage-sequence))

(define (package-lock-stage-path
  [destination : String]
  [sequence : i64]
  [attempt : i64]) : String
  (str_cat.str-cat
    destination
    ".stage."
    (string.int->string (fs.process-id))
    "."
    (string.int->string sequence)
    "."
    (string.int->string attempt)))

(define (package-lock-remove-stage [path : String]) : ResultPackageLockString
  (match (fs.try-remove-file-if-exists (& path))
    [(io.OkIoUnit) (ResultPackageLockString.Ok "")]
    [(io.ErrIoUnit error)
      (ResultPackageLockString.Err
        (package-lock-transaction-error "cleanup" path (io.error-message error)))]))

(define (package-lock-stage-write-opened
  [path : String]
  [source : String]
  [handle : io.FileHandle]) : ResultPackageLockString
  (if (package-lock-transaction-fault? "during-stage")
    (begin
      (io.file-close handle)
      (package-lock-remove-stage (clone path))
      (ResultPackageLockString.Err
        (package-lock-transaction-error
          "during-stage"
          path
          "injected test failure")))
    (match (io.file-write handle (byte_buf.str-as-bytes (& source)))
      [(io.ErrIoUnit error)
        (begin
          (io.file-close handle)
          (package-lock-remove-stage (clone path))
          (ResultPackageLockString.Err
            (package-lock-transaction-error
              "stage-write"
              path
              (io.error-message error))))]
      [(io.OkIoUnit)
        (match (io.file-flush handle)
          [(io.ErrIoUnit error)
            (begin
              (io.file-close handle)
              (package-lock-remove-stage (clone path))
              (ResultPackageLockString.Err
                (package-lock-transaction-error
                  "stage-flush"
                  path
                  (io.error-message error))))]
          [(io.OkIoUnit)
            (match (io.file-close handle)
              [(io.ErrIoUnit error)
                (begin
                  (package-lock-remove-stage (clone path))
                  (ResultPackageLockString.Err
                    (package-lock-transaction-error
                      "stage-close"
                      path
                      (io.error-message error))))]
              [(io.OkIoUnit) (ResultPackageLockString.Ok path)])])])))

(define (package-lock-stage-write-attempt
  [destination : String]
  [source : String]
  [sequence : i64]
  [attempt : i64]) : ResultPackageLockString
  (if (>= attempt 100)
    (ResultPackageLockString.Err
      (package-lock-transaction-error
        "stage-create"
        destination
        "could not allocate a unique sibling staging path"))
    (let
      [path : String
        (package-lock-stage-path (clone destination) sequence attempt)]
      (match (io.file-open (& path) (io.OpenWriteCreateNew))
        [(io.OkIoFile handle)
          (package-lock-stage-write-opened path source handle)]
        [(io.ErrIoFile error)
          (if (package-lock-io-already-exists? (clone error))
            (package-lock-stage-write-attempt
              destination
              source
              sequence
              (+ attempt 1))
            (ResultPackageLockString.Err
              (package-lock-transaction-error
                "stage-create"
                path
                (io.error-message error))))]))))

(define (package-lock-stage-write [destination : String] [source : String]) : ResultPackageLockString
  (package-lock-stage-write-attempt
    destination
    source
    (package-lock-stage-next-sequence)
    0))

(define (package-lock-stage-validate [path : String] [expected : String]) : ResultPackageLockString
  (match (io.try-read-file (& path))
    [(io.ErrIoBytes error)
      (ResultPackageLockString.Err
        (package-lock-transaction-error
          "stage-validate"
          path
          (io.error-message error)))]
    [(io.OkIoBytes contents)
      (let
        [actual : String (byte_buf.to-string contents)]
        (if (not (string.eq actual expected))
          (ResultPackageLockString.Err
            (package-lock-transaction-error
              "stage-validate"
              path
              "staged bytes differ from the complete canonical lock"))
          (match (package-lock-parse actual)
            [(ResultPackageLockFile.Err message)
              (ResultPackageLockString.Err
                (package-lock-transaction-error "stage-validate" path message))]
            [(ResultPackageLockFile.Ok _) (ResultPackageLockString.Ok path)])))]))

(define (package-lock-transaction-ensure-dir [path : String]) : ResultPackageLockString
  (match (fs.try-mkdir-if-missing (& path))
    [(io.OkIoUnit) (ResultPackageLockString.Ok path)]
    [(io.ErrIoUnit error)
      (ResultPackageLockString.Err
        (package-lock-transaction-error
          "coordination-directory"
          path
          (io.error-message error)))]))

(define (package-lock-transaction-lock-path [destination : String]) : ResultPackageLockString
  (let
    [parent : String (fs.dirname (& destination))]
    [target-name : String "target"]
    [typelisp-name : String "typelisp"]
    [locks-name : String "locks"]
    [guard-name : String "package-lock.writer-lock"]
    [target : String (fs.path-join (& parent) (& target-name))]
    [typelisp : String (fs.path-join (& target) (& typelisp-name))]
    [locks : String (fs.path-join (& typelisp) (& locks-name))]
    [guard : String (fs.path-join (& locks) (& guard-name))]
    (match (package-lock-transaction-ensure-dir target)
      [(ResultPackageLockString.Err message)
        (ResultPackageLockString.Err message)]
      [(ResultPackageLockString.Ok _)
        (match (package-lock-transaction-ensure-dir typelisp)
          [(ResultPackageLockString.Err message)
            (ResultPackageLockString.Err message)]
          [(ResultPackageLockString.Ok _)
            (match (package-lock-transaction-ensure-dir locks)
              [(ResultPackageLockString.Err message)
                (ResultPackageLockString.Err message)]
              [(ResultPackageLockString.Ok _)
                (ResultPackageLockString.Ok guard)])])])))

(define (package-lock-transaction-finish
  [lock : fs.FsFileLock]
  [stage : String]
  [remove-stage : bool]
  [result : ResultPackageLockCommit]) : ResultPackageLockCommit
  (let
    [cleanup : ResultPackageLockString
      (if remove-stage
        (package-lock-remove-stage (clone stage))
        (ResultPackageLockString.Ok ""))]
    [release : io.ResultIoUnit (fs.file-lock-release lock)]
    (match cleanup
      [(ResultPackageLockString.Err message)
        (ResultPackageLockCommit.Err message)]
      [(ResultPackageLockString.Ok _)
        (match release
          [(io.ErrIoUnit error)
            (ResultPackageLockCommit.Err
              (package-lock-transaction-error
                "coordination-unlock"
                stage
                (io.error-message error)))]
          [(io.OkIoUnit) result])])))

(define (package-lock-atomic-replace-attempt
  [stage : String]
  [destination : String]
  [attempt : i64]) : ResultPackageLockString
  (match (fs.try-atomic-replace (& stage) (& destination))
    [(io.OkIoUnit) (ResultPackageLockString.Ok destination)]
    [(io.ErrIoUnit error)
      (if (and
        (< attempt 100)
        (package-lock-io-retryable-replace? (clone error)))
        (match (time.sleep-ms 10)
          [(time.ErrTimeUnit sleep-error)
            (ResultPackageLockString.Err (time.error-message sleep-error))]
          [(time.OkTimeUnit)
            (package-lock-atomic-replace-attempt
              stage
              destination
              (+ attempt 1))])
        (ResultPackageLockString.Err (io.error-message error)))]))

(define (package-lock-transaction-under-lock
  [snapshot : PackageLockSnapshot]
  [source : String]
  [stage : String]
  [lock : fs.FsFileLock]) : ResultPackageLockCommit
  (match (package-lock-transaction-read (clone snapshot.path))
    [(ResultPackageLockSnapshot.Err message)
      (package-lock-transaction-finish
        lock
        stage
        true
        (ResultPackageLockCommit.Err message))]
    [(ResultPackageLockSnapshot.Ok current)
      (cond
        [(package-lock-snapshot-is-source? (& current) (clone source))
          (package-lock-transaction-finish
            lock
            stage
            true
            (ResultPackageLockCommit.Ok
              (PackageLockCommitOutcome.Reused snapshot.path)))]
        [(not (package-lock-snapshot-identity-eq? (& snapshot) (& current)))
          (package-lock-transaction-finish
            lock
            stage
            true
            (ResultPackageLockCommit.Err
              (str_cat.str-cat
                "package-lock transaction conflict for '"
                snapshot.path
                "': lock changed since resolution; rerun against the current lock")))]
        [(package-lock-transaction-fault? "before-replace")
          (package-lock-transaction-finish
            lock
            stage
            true
            (ResultPackageLockCommit.Err
              (package-lock-transaction-error
                "before-replace"
                snapshot.path
                "injected test failure")))]
        [else
          (match (package-lock-atomic-replace-attempt
            (clone stage)
            (clone snapshot.path)
            0)
            [(ResultPackageLockString.Err message)
              (package-lock-transaction-finish
                lock
                stage
                true
                (ResultPackageLockCommit.Err
                  (package-lock-transaction-error
                    "replace"
                    snapshot.path
                    message)))]
            [(ResultPackageLockString.Ok _)
              (package-lock-transaction-finish
                lock
                stage
                false
                (ResultPackageLockCommit.Ok
                  (PackageLockCommitOutcome.Replaced snapshot.path)))])])]))

(define (package-lock-transaction-acquire
  [snapshot : PackageLockSnapshot]
  [source : String]
  [guard : String]
  [stage : String]) : ResultPackageLockCommit
  (match (package-lock-transaction-maybe-pause "before-lock")
    [(ResultPackageLockString.Err message)
      (begin
        (package-lock-remove-stage stage)
        (ResultPackageLockCommit.Err message))]
    [(ResultPackageLockString.Ok _)
      (match (fs.file-lock-acquire (& guard))
        [(fs.ErrFsFileLock error)
          (begin
            (package-lock-remove-stage stage)
            (ResultPackageLockCommit.Err
              (package-lock-transaction-error
                "coordination-lock"
                guard
                (io.error-message error))))]
        [(fs.OkFsFileLock lock)
          (package-lock-transaction-under-lock snapshot source stage lock)])]))

(define (package-lock-transaction-stage-ready
  [snapshot : PackageLockSnapshot]
  [source : String]
  [guard : String]
  [stage : String]) : ResultPackageLockCommit
  (match (package-lock-stage-validate (clone stage) (clone source))
    [(ResultPackageLockString.Err message)
      (begin
        (package-lock-remove-stage stage)
        (ResultPackageLockCommit.Err message))]
    [(ResultPackageLockString.Ok _)
      (if (package-lock-transaction-fault? "after-stage")
        (begin
          (package-lock-remove-stage stage)
          (ResultPackageLockCommit.Err
            (package-lock-transaction-error
              "after-stage"
              snapshot.path
              "injected test failure")))
        (package-lock-transaction-acquire snapshot source guard stage))]))

(define (package-lock-transaction-with-guard
  [snapshot : PackageLockSnapshot]
  [source : String]
  [guard : String]) : ResultPackageLockCommit
  (match (package-lock-stage-write (clone snapshot.path) (clone source))
    [(ResultPackageLockString.Err message)
      (ResultPackageLockCommit.Err message)]
    [(ResultPackageLockString.Ok stage)
      (package-lock-transaction-stage-ready snapshot source guard stage)]))

(define (package-lock-transaction-commit
  [snapshot : PackageLockSnapshot]
  [source : String]) : ResultPackageLockCommit
  (match (package-lock-parse (clone source))
    [(ResultPackageLockFile.Err message)
      (ResultPackageLockCommit.Err
        (package-lock-transaction-error "validate" snapshot.path message))]
    [(ResultPackageLockFile.Ok _)
      (if (package-lock-snapshot-is-source? (& snapshot) (clone source))
        (ResultPackageLockCommit.Ok
          (PackageLockCommitOutcome.Unchanged snapshot.path))
        (if (package-lock-transaction-fault? "before-stage")
          (ResultPackageLockCommit.Err
            (package-lock-transaction-error
              "before-stage"
              snapshot.path
              "injected test failure"))
          (match (package-lock-transaction-lock-path (clone snapshot.path))
            [(ResultPackageLockString.Err message)
              (ResultPackageLockCommit.Err message)]
            [(ResultPackageLockString.Ok guard)
              (package-lock-transaction-with-guard snapshot source guard)])))]))

(define (package-lock-valid-source) : String
  "(typelisp-lock (version \"v1\") (dependencies (dependency (alias \"zeta\") (url \"https://github.com/owner/zeta.git\") (pin (rev \"abcdef0123456789abcdef0123456789abcdef01\")) (commit \"abcdef0123456789abcdef0123456789abcdef01\")) (dependency (alias \"alpha\") (url \"https://github.com/owner/alpha.git\") (pin (branch \"main\")) (commit \"1111111111111111111111111111111111111111\"))))")

(cfg
  test
  (define (package-lock-growth-source) : String
    "(typelisp-lock (version \"v1\") (dependencies (dependency (alias \"foxtrot\") (url \"u\") (pin (rev \"f\")) (commit \"f\")) (dependency (alias \"alpha\") (url \"u\") (pin (rev \"a\")) (commit \"a\")) (dependency (alias \"echo\") (url \"u\") (pin (rev \"e\")) (commit \"e\")) (dependency (alias \"bravo\") (url \"u\") (pin (rev \"b\")) (commit \"b\")) (dependency (alias \"delta\") (url \"u\") (pin (rev \"d\")) (commit \"d\")) (dependency (alias \"charlie\") (url \"u\") (pin (rev \"c\")) (commit \"c\"))))"))

(define (package-lock-expected-emitted) : String
  (str_cat.str-cat
    "(typelisp-lock\n"
    "  (version \"v1\")\n"
    "  (dependencies\n"
    "    (dependency\n      (alias \"alpha\")\n      (url \"https://github.com/owner/alpha.git\")\n      (pin (branch \"main\"))\n      (commit \"1111111111111111111111111111111111111111\"))\n"
    "    (dependency\n      (alias \"zeta\")\n      (url \"https://github.com/owner/zeta.git\")\n      (pin (rev \"abcdef0123456789abcdef0123456789abcdef01\"))\n      (commit \"abcdef0123456789abcdef0123456789abcdef01\"))\n"
    "  ))\n"))

(define (package-lock-entry-matches?
  [entry : PackageLockEntry]
  [alias : String]
  [url : String]
  [kind : package_cache_core.PackageCachePinKind]
  [pin-value : String]
  [commit : String]) : bool
  (and
    (string.eq entry.alias alias)
    (string.eq entry.url url)
    (package_cache_core.package-cache-pin-kind-eq? entry.pin-kind kind)
    (string.eq entry.pin-value pin-value)
    (string.eq entry.commit commit)))

(define (package-lock-list-has-entry?
  [entries : package_lock_entry_vec.Vec]
  [alias : String]
  [url : String]
  [kind : package_cache_core.PackageCachePinKind]
  [pin-value : String]
  [commit : String]) : bool
  (match (package-lock-entry-list-lookup
    entries
    (owned_view.compiler-owned-shared-view alias))
    [(PackageLockMaybeEntry.No) false]
    [(PackageLockMaybeEntry.Some entry)
      (package-lock-entry-matches? entry alias url kind pin-value commit)]))

(define (package-lock-valid-parse-ok?) : bool
  (match (package-lock-parse (package-lock-valid-source))
    [(ResultPackageLockFile.Err _) false]
    [(ResultPackageLockFile.Ok lock)
      (let
        [entries : package_lock_entry_vec.Vec lock.entries]
        (and
          (string.eq lock.version package-lock-version)
          (= (package_lock_entry_vec.len (& entries)) 2)
          (package-lock-list-has-entry?
            (owned_view.compiler-owned-shared-view entries)
            "alpha"
            "https://github.com/owner/alpha.git"
            (package_cache_core.PackageCachePinKind.Branch)
            "main"
            "1111111111111111111111111111111111111111")
          (package-lock-list-has-entry?
            entries
            "zeta"
            "https://github.com/owner/zeta.git"
            (package_cache_core.PackageCachePinKind.Rev)
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
            [entries : package_lock_entry_vec.Vec again.entries]
            (and
              (= (package_lock_entry_vec.len (& entries)) 2)
              (package-lock-list-has-entry?
                (owned_view.compiler-owned-shared-view entries)
                "alpha"
                "https://github.com/owner/alpha.git"
                (package_cache_core.PackageCachePinKind.Branch)
                "main"
                "1111111111111111111111111111111111111111")
              (package-lock-list-has-entry?
                entries
                "zeta"
                "https://github.com/owner/zeta.git"
                (package_cache_core.PackageCachePinKind.Rev)
                "abcdef0123456789abcdef0123456789abcdef01"
                "abcdef0123456789abcdef0123456789abcdef01")))])]))

(cfg
  test
  (define (package-lock-entry-alias-at?
    [entries : (& entries package_lock_entry_vec.Vec)]
    [index : i64]
    [alias : String]) : bool
    (string.eq
      (__tl-project-field
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
        (if (package-lock-growth-entries-ok? (& lock.entries))
          (match (package-lock-parse (package-lock-emit lock))
            [(ResultPackageLockFile.Err _) false]
            [(ResultPackageLockFile.Ok again)
              (package-lock-growth-entries-ok? (& again.entries))])
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

(cfg
  test
  (define (package-lock-transaction-test-fail [message : String]) : never
    (io.panic message)))

(cfg
  test
  (define (package-lock-transaction-test-snapshot [path : String]) : PackageLockSnapshot
    (match (package-lock-transaction-read path)
      [(ResultPackageLockSnapshot.Err message)
        (package-lock-transaction-test-fail message)]
      [(ResultPackageLockSnapshot.Ok snapshot) snapshot])))

(cfg
  test
  (define (package-lock-transaction-test-read [path : String]) : String
    (match (io.try-read-file (& path))
      [(io.ErrIoBytes error)
        (package-lock-transaction-test-fail (io.error-message error))]
      [(io.OkIoBytes contents) (byte_buf.to-string contents)])))

(cfg
  test
  (define (package-lock-transaction-test-expect-commit
    [snapshot : PackageLockSnapshot]
    [source : String]
    [kind : i64]) : unit
    (match (package-lock-transaction-commit snapshot source)
      [(ResultPackageLockCommit.Err message)
        (package-lock-transaction-test-fail message)]
      [(ResultPackageLockCommit.Ok outcome)
        (let
          [actual : i64
            (match outcome
              [(PackageLockCommitOutcome.Unchanged _) 0]
              [(PackageLockCommitOutcome.Reused _) 1]
              [(PackageLockCommitOutcome.Replaced _) 2])]
          (if (= actual kind)
            unit
            (package-lock-transaction-test-fail
              "package-lock transaction: unexpected commit outcome")))])))

(cfg
  test
  (define (package-lock-transaction-test-expect-error
    [snapshot : PackageLockSnapshot]
    [source : String]
    [needle : String]) : unit
    (match (package-lock-transaction-commit snapshot source)
      [(ResultPackageLockCommit.Ok _)
        (package-lock-transaction-test-fail
          "package-lock transaction unexpectedly succeeded")]
      [(ResultPackageLockCommit.Err message)
        (if (string.contains (& message) (& needle))
          unit
          (package-lock-transaction-test-fail message))])))

(cfg
  test
  (define (package-lock-transaction-test-set-fault [phase : String]) : unit
    (let
      [name : String "TYPELISP_PACKAGE_LOCK_TEST_FAULT"]
      (if (env.set! (& name) (& phase))
        unit
        (package-lock-transaction-test-fail
          "package-lock transaction: cannot set fault injection")))))

(cfg
  test
  (define (package-lock-transaction-test-clear-fault) : unit
    (let
      [name : String "TYPELISP_PACKAGE_LOCK_TEST_FAULT"]
      (if (env.unset! (& name))
        unit
        (package-lock-transaction-test-fail
          "package-lock transaction: cannot clear fault injection")))))

(cfg
  test
  (define (package-lock-transaction-test-cleanup
    [root : String]
    [path : String]
    [collision : String]) : unit
    (let
      [target-name : String "target"]
      [typelisp-name : String "typelisp"]
      [locks-name : String "locks"]
      [guard-name : String "package-lock.writer-lock"]
      [target : String (fs.path-join (& root) (& target-name))]
      [typelisp : String (fs.path-join (& target) (& typelisp-name))]
      [locks : String (fs.path-join (& typelisp) (& locks-name))]
      [guard : String (fs.path-join (& locks) (& guard-name))]
      (begin
        (fs.try-remove-file-if-exists (& path))
        (fs.try-remove-file-if-exists (& collision))
        (fs.try-remove-file-if-exists (& guard))
        (fs.try-remove-dir-if-exists (& locks))
        (fs.try-remove-dir-if-exists (& typelisp))
        (fs.try-remove-dir-if-exists (& target))
        (fs.try-remove-dir-if-exists (& root))
        unit))))

(cfg
  test
  (define (package-lock-transaction-test) : unit
    (match (fs.try-create-temp-dir "typelisp package lock transaction")
      [(io.ErrIoString error)
        (package-lock-transaction-test-fail (io.error-message error))]
      [(io.OkIoString root)
        (let
          [lock-name : String "typelisp.lock"]
          [path : String (fs.path-join (& root) (& lock-name))]
          [collision : String
            (package-lock-stage-path
              (clone path)
              (+ package-lock-stage-sequence 1)
              0)]
          [collision-source : String "unrelated staging owner\n"]
          [source-a : String
            "(typelisp-lock\n  (version \"v1\")\n  (dependencies\n  ))\n"]
          [source-b : String
            "(typelisp-lock\n  (version \"v1\")\n  (dependencies\n    (dependency\n      (alias \"dep\")\n      (url \"https://example.invalid/a.git\")\n      (pin (rev \"a\"))\n      (commit \"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"))\n  ))\n"]
          [source-c : String
            "(typelisp-lock\n  (version \"v1\")\n  (dependencies\n    (dependency\n      (alias \"dep\")\n      (url \"https://example.invalid/a.git\")\n      (pin (rev \"b\"))\n      (commit \"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"))\n  ))\n"]
          (begin
            (match (io.try-write-file
              (& collision)
              (byte_buf.str-as-bytes (& collision-source)))
              [(io.ErrIoUnit error)
                (package-lock-transaction-test-fail (io.error-message error))]
              [(io.OkIoUnit) unit])
            (package-lock-transaction-test-expect-commit
              (package-lock-transaction-test-snapshot (clone path))
              (clone source-a)
              2)
            (if (string.eq
              (package-lock-transaction-test-read (clone path))
              source-a)
              unit
              (package-lock-transaction-test-fail
                "package-lock transaction: initial replacement mismatch"))
            (package-lock-transaction-test-expect-commit
              (package-lock-transaction-test-snapshot (clone path))
              (clone source-a)
              0)
            (let
              [snapshot-a : PackageLockSnapshot
                (package-lock-transaction-test-snapshot (clone path))]
              (begin
                (match (io.try-write-file
                  (& path)
                  (byte_buf.str-as-bytes (& source-b)))
                  [(io.ErrIoUnit error)
                    (package-lock-transaction-test-fail
                      (io.error-message error))]
                  [(io.OkIoUnit) unit])
                (package-lock-transaction-test-expect-error
                  snapshot-a
                  (clone source-c)
                  "changed since resolution")))
            (match (io.file-open (& path) (io.OpenWriteCreateNew))
              [(io.OkIoFile handle)
                (begin
                  (io.file-close handle)
                  (package-lock-transaction-test-fail
                    "package-lock transaction: exclusive create reopened lock"))]
              [(io.ErrIoFile _) unit])
            (if (string.eq
              (package-lock-transaction-test-read (clone path))
              source-b)
              unit
              (package-lock-transaction-test-fail
                "package-lock transaction: conflict overwrote winner"))
            (package-lock-transaction-test-set-fault "before-stage")
            (package-lock-transaction-test-expect-error
              (package-lock-transaction-test-snapshot (clone path))
              (clone source-c)
              "before-stage")
            (package-lock-transaction-test-clear-fault)
            (package-lock-transaction-test-set-fault "during-stage")
            (package-lock-transaction-test-expect-error
              (package-lock-transaction-test-snapshot (clone path))
              (clone source-c)
              "during-stage")
            (package-lock-transaction-test-clear-fault)
            (if (string.eq
              (package-lock-transaction-test-read (clone collision))
              collision-source)
              unit
              (package-lock-transaction-test-fail
                "package-lock transaction: removed another staging owner"))
            (package-lock-transaction-test-set-fault "before-replace")
            (package-lock-transaction-test-expect-error
              (package-lock-transaction-test-snapshot (clone path))
              source-c
              "before-replace")
            (package-lock-transaction-test-clear-fault)
            (if (string.eq
              (package-lock-transaction-test-read (clone path))
              source-b)
              unit
              (package-lock-transaction-test-fail
                "package-lock transaction: injected failure changed lock"))
            (package-lock-transaction-test-cleanup root path collision)))])))

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

(test package-lock-atomic-transaction (package-lock-transaction-test))