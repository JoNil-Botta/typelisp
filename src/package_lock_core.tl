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
(import read as reader)
(import package_cache_core)

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
  (unsafe
    (ptr-read (ptr-addr-of package-lock-version))))

(define (package-lock-char-code-at [text : (& text str)] [idx : i64]) : i64
  (cast (string.string-ref text idx) : i64))

(define (package-lock-string-less?
  [left : (& left str)]
  [right : (& right str)]) : bool
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
      (< left-len right-len))))

(define (package-lock-alias-char? [c : char]) : bool
  (let
    [code : i64 (cast c : i64)]
    (or
      (and (>= code 48) (<= code 57))
      (and (>= code 65) (<= code 90))
      (and (>= code 97) (<= code 122))
      (= code 45)
      (= code 95))))

(define (package-lock-alias-token-valid? [value : (& value str)]) : bool
  (let
    [n : i64 (string.string-length value)]
    [i : i64 0]
    [ok : bool (> n 0)]
    (while ok
      (if (< i n)
        (if (package-lock-alias-char? (string.string-ref value i))
          (set! i (+ i 1))
          (set! ok false))
        (set! ok false)))
    (= i n)))

(define (package-lock-entry-list-fallback) : PackageLockEntry
  (PackageLockEntry "" "" (Rev) "" ""))

(define (package-lock-entry-list-lookup-from
  [entries : (& entries package_lock_entry_vec.Vec)]
  [alias : (& alias str)]
  [index : i64]) : PackageLockMaybeEntry
  (if (>= index (package_lock_entry_vec.len entries))
    (No)
    (let
      [entry : PackageLockEntry
        (package_lock_entry_vec.get
          entries
          index
          (package-lock-entry-list-fallback))]
      (if (string.eq entry.alias alias)
        (Some entry)
        (package-lock-entry-list-lookup-from entries alias (+ index 1))))))

(define (package-lock-entry-list-lookup
  [entries : (& entries package_lock_entry_vec.Vec)]
  [alias : (& alias str)]) : PackageLockMaybeEntry
  (package-lock-entry-list-lookup-from entries alias 0))

(define (package-lock-entry-list-insert-position
  [entries : (& entries package_lock_entry_vec.Vec)]
  [alias : (& alias str)]
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
        (if (package-lock-string-less? alias head.alias)
          index
          (package-lock-entry-list-insert-position entries alias (+ index 1)))))))

(define (package-lock-entry-list-insert-at!
  [entries : (&mut entries package_lock_entry_vec.Vec)]
  [entry : (& PackageLockEntry)]
  [index : i64]) : unit
  (package_lock_entry_vec.push-ref! entries (package-lock-entry-list-fallback))
  (let
    [write : i64 (- (package_lock_entry_vec.len entries) 1)]
    (while (> write index)
      (let
        [previous : PackageLockEntry
          (package_lock_entry_vec.get
            entries
            (- write 1)
            (package-lock-entry-list-fallback))]
        (package_lock_entry_vec.set-ref! entries write previous)
        (set! write (- write 1))))
    (package_lock_entry_vec.set-ref!
      entries
      index
      (owned_view.compiler-owned-reference-shared-view entry))))

(define (package-lock-entry-list-insert
  [entries : package_lock_entry_vec.Vec]
  [entry : PackageLockEntry]) : ResultPackageLockEntryList
  (let
    [next : package_lock_entry_vec.Vec entries]
    [index : i64
      (package-lock-entry-list-insert-position (& next) entry.alias 0)]
    (if (< index 0)
      (Err
        (str_cat.str-cat
          "package-lock: duplicate dependency alias `"
          entry.alias
          "`"))
      (begin
        (package-lock-entry-list-insert-at! (&mut next) (& entry) index)
        (Ok next)))))

(define (package-lock-field-string-value
  [ftail : reader.SpannedSexpr]
  [fname : String]) : ResultPackageLockString
  (match (reader.sexpr-slice-view ftail)
    [(List (slice (Str val-id _))) (Ok (ci.intern-id-str val-id))]
    [(List (slice (Str _ _) & _))
      (Err
        (str_cat.str-cat
          "package-lock: field `"
          fname
          "` takes a single string value"))]
    [_
      (Err
        (str_cat.str-cat
          "package-lock: field `"
          fname
          "` must have a string value"))]))

(define (package-lock-parse-pin-kind [value : String]) : ResultPackageLockPinKind
  (cond
    [(string.eq value "rev") (Ok (Rev))]
    [(string.eq value "tag") (Ok (Tag))]
    [(string.eq value "branch") (Ok (Branch))]
    [else (Err "package-lock: pin kind must be `rev`, `tag`, or `branch`")]))

(define (package-lock-pin-shape-error) : ResultPackageLockPin
  (Err "package-lock: pin must be `(rev|tag|branch \"value\")`"))

(define (package-lock-pin-form [form : reader.SpannedSexpr]) : ResultPackageLockPin
  (match (reader.sexpr-slice-view form)
    [(List (slice (Sym kind-name _) (Str pin-value-id _)))
      (let
        [pin-value : String (ci.intern-id-str pin-value-id)]
        (if (string.eq pin-value "")
          (Err "package-lock: pin value must not be empty")
          (let
            [pin-kind
              (try
                (package-lock-parse-pin-kind
                  (package-lock-symbol-text kind-name)))]
            (Ok (PackageLockPin pin-kind pin-value)))))]
    [_ (package-lock-pin-shape-error)]))

(define (package-lock-field-pin-value [ftail : reader.SpannedSexpr]) : ResultPackageLockPin
  (match (reader.sexpr-slice-view ftail)
    [(List (slice pin-form)) (package-lock-pin-form pin-form)]
    [_ (Err "package-lock: field `pin` takes one value")]))

(define (package-lock-entry-fields-items
  [fields : (& program (Slice reader.SpannedSexpr))]
  [alias : String]
  [has-alias : bool]
  [url : String]
  [has-url : bool]
  [pin-kind : package_cache_core.PackageCachePinKind]
  [pin-value : String]
  [has-pin : bool]
  [commit : String]
  [has-commit : bool]) : ResultPackageLockEntry
  (match fields
    [(slice)
      (cond
        [(not has-alias)
          (Err "package-lock: dependency missing required field `alias`")]
        [(not has-url)
          (Err "package-lock: dependency missing required field `url`")]
        [(not has-pin)
          (Err "package-lock: dependency missing required field `pin`")]
        [(not has-commit)
          (Err "package-lock: dependency missing required field `commit`")]
        [(string.eq alias "")
          (Err "package-lock: dependency alias must not be empty")]
        [(not (package-lock-alias-token-valid? alias))
          (Err
            "package-lock: dependency alias may only contain ASCII letters, digits, '-' and '_'")]
        [(string.eq url "")
          (Err "package-lock: dependency url must not be empty")]
        [(string.eq commit "")
          (Err "package-lock: dependency commit must not be empty")]
        [else (Ok (PackageLockEntry alias url pin-kind pin-value commit))])]
    [(slice field & rest)
      (match (reader.sexpr-slice-view field)
        [(List (slice (Sym fname _) & _))
          (let
            [ftail (reader.spanned-sexpr-drop field 1)]
            (cond
              [(string.eq (package-lock-symbol-text fname) "alias")
                (if has-alias
                  (Err "package-lock: duplicate dependency field `alias`")
                  (let
                    [value
                      (try
                        (package-lock-field-string-value
                          ftail
                          (package-lock-symbol-text fname)))]
                    (package-lock-entry-fields-items
                      rest
                      value
                      true
                      url
                      has-url
                      pin-kind
                      pin-value
                      has-pin
                      commit
                      has-commit)))]
              [(string.eq (package-lock-symbol-text fname) "url")
                (if has-url
                  (Err "package-lock: duplicate dependency field `url`")
                  (let
                    [value
                      (try
                        (package-lock-field-string-value
                          ftail
                          (package-lock-symbol-text fname)))]
                    (package-lock-entry-fields-items
                      rest
                      alias
                      has-alias
                      value
                      true
                      pin-kind
                      pin-value
                      has-pin
                      commit
                      has-commit)))]
              [(string.eq (package-lock-symbol-text fname) "pin")
                (if has-pin
                  (Err "package-lock: duplicate dependency field `pin`")
                  (let
                    [pin (try (package-lock-field-pin-value ftail))]
                    (package-lock-entry-fields-items
                      rest
                      alias
                      has-alias
                      url
                      has-url
                      pin.kind
                      pin.value
                      true
                      commit
                      has-commit)))]
              [(string.eq (package-lock-symbol-text fname) "commit")
                (if has-commit
                  (Err "package-lock: duplicate dependency field `commit`")
                  (let
                    [value
                      (try
                        (package-lock-field-string-value
                          ftail
                          (package-lock-symbol-text fname)))]
                    (package-lock-entry-fields-items
                      rest
                      alias
                      has-alias
                      url
                      has-url
                      pin-kind
                      pin-value
                      has-pin
                      value
                      true)))]
              [else
                (Err
                  (str_cat.str-cat
                    "package-lock: unknown dependency field `"
                    (package-lock-symbol-text fname)
                    "`"))]))]
        [(List (slice _ & _))
          (Err "package-lock: dependency fields must start with a field name")]
        [_ (Err "package-lock: dependency fields must be lists")])]))

(define (package-lock-entry-from-form [form : reader.SpannedSexpr]) : ResultPackageLockEntry
  (match (reader.sexpr-slice-view form)
    [(List items) (package-lock-entry-from-form-items items)]
    [_ (Err "package-lock: dependency entries must be lists")]))

(define (package-lock-entry-from-form-items
  [form : (& program (Slice reader.SpannedSexpr))]) : ResultPackageLockEntry
  (match form
    [(slice head & rest)
      (match (reader.sexpr-view head)
        [(Sym name)
          (if (string.eq (package-lock-symbol-text name) "dependency")
            (package-lock-entry-fields-items
              rest
              ""
              false
              ""
              false
              (Rev)
              ""
              false
              ""
              false)
            (Err
              "package-lock: dependency entries must start with `dependency`"))]
        [_
          (Err "package-lock: dependency entries must start with `dependency`")])]
    [_ (Err "package-lock: dependency entries must be lists")]))

(define (package-lock-dependencies-entries
  [entries : reader.SpannedSexpr]
  [acc : package_lock_entry_vec.Vec]) : ResultPackageLockEntryList
  (match (reader.sexpr-slice-view entries)
    [(List items) (package-lock-dependencies-entries-items items acc)]
    [_ (Err "package-lock: `dependencies` must contain dependency lists")]))

(define (package-lock-dependencies-entries-items
  [entries : (& program (Slice reader.SpannedSexpr))]
  [acc : package_lock_entry_vec.Vec]) : ResultPackageLockEntryList
  (match entries
    [(slice) (Ok acc)]
    [(slice entry & rest)
      (let
        [parsed (try (package-lock-entry-from-form entry))]
        [next (try (package-lock-entry-list-insert acc parsed))]
        (package-lock-dependencies-entries-items rest next))]))

(define (package-lock-fields-items
  [fields : (& program (Slice reader.SpannedSexpr))]
  [version : String]
  [has-version : bool]
  [entries : package_lock_entry_vec.Vec]
  [has-deps : bool]) : ResultPackageLockFile
  (match fields
    [(slice)
      (cond
        [(not has-version)
          (Err "package-lock: missing required field `version`")]
        [(not (string.eq version package-lock-version))
          (Err
            (str_cat.str-cat "package-lock: unsupported version `" version "`"))]
        [(not has-deps)
          (Err "package-lock: missing required field `dependencies`")]
        [else (Ok (PackageLockFile version entries))])]
    [(slice field & rest)
      (match (reader.sexpr-slice-view field)
        [(List (slice (Sym fname _) & _))
          (let
            [ftail (reader.spanned-sexpr-drop field 1)]
            (if (string.eq (package-lock-symbol-text fname) "version")
              (if has-version
                (Err "package-lock: duplicate field `version`")
                (let
                  [value
                    (try
                      (package-lock-field-string-value
                        ftail
                        (package-lock-symbol-text fname)))]
                  (package-lock-fields-items rest value true entries has-deps)))
              (if (string.eq (package-lock-symbol-text fname) "dependencies")
                (if has-deps
                  (Err "package-lock: duplicate field `dependencies`")
                  (let
                    [parsed
                      (try
                        (package-lock-dependencies-entries
                          ftail
                          (package_lock_entry_vec.new)))]
                    (package-lock-fields-items
                      rest
                      version
                      has-version
                      parsed
                      true)))
                (Err
                  (str_cat.str-cat
                    "package-lock: unknown field `"
                    (package-lock-symbol-text fname)
                    "`")))))]
        [(List (slice _ & _))
          (Err "package-lock: fields must start with a field name")]
        [_ (Err "package-lock: fields must be lists")])]))

(define (package-lock-from-form [form : reader.SpannedSexpr]) : ResultPackageLockFile
  (match (reader.sexpr-slice-view form)
    [(List items) (package-lock-from-form-items items)]
    [_ (Err "package-lock: lockfile must be a `(typelisp-lock ...)` form")]))

(define (package-lock-from-form-items
  [form : (& program (Slice reader.SpannedSexpr))]) : ResultPackageLockFile
  (match form
    [(slice head & rest)
      (match (reader.sexpr-view head)
        [(Sym name)
          (if (string.eq (package-lock-symbol-text name) "typelisp-lock")
            (package-lock-fields-items
              rest
              ""
              false
              (package_lock_entry_vec.new)
              false)
            (Err
              (str_cat.str-cat
                "expected `typelisp-lock` form, got `"
                (package-lock-symbol-text name)
                "`")))]
        [_ (Err "package-lock: lockfile must start with `typelisp-lock`")])]
    [_ (Err "package-lock: lockfile must be a `(typelisp-lock ...)` form")]))

(define (package-lock-parse [source : String]) : ResultPackageLockFile
  (let
    [mark : i64 (reader.sp-node-pool-len)]
    [result : ResultPackageLockFile
      (match (reader.data-result source)
        [(Err message) (Err (str_cat.str-cat "package-lock: " message))]
        [(Ok form) (package-lock-from-form form)])]
    (reader.sp-node-pool-truncate! mark)
    result))

(define (package-lock-quote-text) : String
  "\"")

(define (package-lock-backslash-text) : String
  "\\")

(define (package-lock-escape-string [text : (& text str)]) : String
  (let
    [n : i64 (string.string-length text)]
    [i : i64 0]
    [out : String ""]
    [slash : String (package-lock-backslash-text)]
    [quote : String (package-lock-quote-text)]
    (while (< i n)
      (let
        [code : i64 (package-lock-char-code-at text i)]
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
          [else (set! out (str_cat.str-cat out (string.substring text i 1) ""))]))
      (set! i (+ i 1)))
    out))

(define (package-lock-quote-string [text : (& str)]) : String
  (str_cat.str-cat
    (package-lock-quote-text)
    (package-lock-escape-string text)
    (package-lock-quote-text)))

(define (package-lock-emit-string-field [field : String] [value : (& str)]) : String
  (str_cat.str-cat "      (" field " " (package-lock-quote-string value) ")\n"))

(define (package-lock-emit-final-string-field
  [field : String]
  [value : (& str)]) : String
  (str_cat.str-cat "      (" field " " (package-lock-quote-string value) "))\n"))

(define (package-lock-emit-pin-field [kind-name : String] [value : (& str)]) : String
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
      (package-lock-emit-string-field "alias" (& entry.alias))
      (package-lock-emit-string-field "url" (& entry.url))
      (package-lock-emit-pin-field kind-name (& entry.pin-value))
      (package-lock-emit-final-string-field "commit" (& entry.commit)))))

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

(define (package-lock-emit-entries [entries : (& package_lock_entry_vec.Vec)]) : String
  (package-lock-emit-entries-from entries 0))

(define (package-lock-emit [lock : (& PackageLockFile)]) : String
  (str_cat.str-cat
    "(typelisp-lock\n"
    "  (version \"v1\")\n"
    "  (dependencies\n"
    (package-lock-emit-entries (& lock.entries))
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
    [(ErrIoBool error)
      (Err
        (package-lock-transaction-error "read" path (io.error-message error)))]
    [(OkIoBool exists)
      (if exists
        (match (io.try-read-file (& path))
          [(ErrIoBytes error)
            (Err
              (package-lock-transaction-error
                "read"
                path
                (io.error-message error)))]
          [(OkIoBytes contents)
            (Ok (PackageLockSnapshot path (byte_buf.to-string contents) true))])
        (Ok (PackageLockSnapshot path "" false)))]))

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

(define (package-lock-io-already-exists? [error : (& io.IoError)]) : bool
  (match error
    [(IoSystemCode code _) (= code fs.fs-status-already-exists)]
    [_ false]))

(define (package-lock-io-retryable-replace? [error : (& io.IoError)]) : bool
  (match error
    [(IoSystemCode code _) (or (= code 32) (= code 33))]
    [_ false]))

(define (package-lock-transaction-fault? [phase : String]) : bool
  (let
    [name : String "TYPELISP_PACKAGE_LOCK_TEST_FAULT"]
    (match (env.get (& name))
      [(EnvNoString) false]
      [(EnvSomeString value) (string.eq value phase)])))

(define (package-lock-transaction-pause? [phase : String]) : bool
  (let
    [name : String "TYPELISP_PACKAGE_LOCK_TEST_PAUSE"]
    (match (env.get (& name))
      [(EnvNoString) false]
      [(EnvSomeString value) (string.eq value phase)])))

(define (package-lock-transaction-wait-release [path : (& str)]) : ResultPackageLockString
  (let
    [attempt : i64 0]
    [done : bool false]
    [error-message : String ""]
    (while (and (not done) (< attempt 6000))
      (match (io.try-file-exists? path)
        [(ErrIoBool error)
          (set! error-message (io.error-message error))
          (set! done true)]
        [(OkIoBool exists)
          (if exists
            (match (time.sleep-ms 10)
              [(ErrTimeUnit error)
                (set! error-message (time.error-message error))
                (set! done true)]
              [(OkTimeUnit) (set! attempt (+ attempt 1))])
            (set! done true))]))
    (if (> (string.string-length error-message) 0)
      (Err error-message)
      (if (>= attempt 6000)
        (Err "package-lock transaction test pause timed out")
        (Ok "")))))

(define (package-lock-transaction-maybe-pause [phase : String]) : ResultPackageLockString
  (if (package-lock-transaction-pause? phase)
    (let
      [name : String "TYPELISP_PACKAGE_LOCK_TEST_RELEASE_FILE"]
      (match (env.get (& name))
        [(EnvNoString)
          (match (time.sleep-ms 2000)
            [(ErrTimeUnit error) (Err (time.error-message error))]
            [(OkTimeUnit) (Ok "")])]
        [(EnvSomeString path) (package-lock-transaction-wait-release (& path))]))
    (Ok "")))

(define (package-lock-stage-next-sequence) : i64
  (set! package-lock-stage-sequence (+ package-lock-stage-sequence 1))
  package-lock-stage-sequence)

;; The lock file a package root publishes. Replacement goes through a
;; transient sibling `<lock>.stage.<pid>.<sequence>.<attempt>`; the infix and
;; the stage-name predicate below are the only spellings of that sibling.
(define (package-lock-file-name) : String
  "typelisp.lock")

(define (package-lock-stage-infix) : String
  ".stage.")

(define (package-lock-decimal-digit? [c : char]) : bool
  (and (>= c '0') (<= c '9')))

;; True exactly when `name` is spelled like a stage sibling of the package
;; lock file as `package-lock-stage-path` builds it: the lock file name, the
;; stage infix, then three nonempty dot-separated decimal runs and nothing
;; else. Package source discovery never treats such a name as package content.
(define (package-lock-stage-name? [name : (& name str)]) : bool
  (let
    [prefix : String
      (str_cat.str-cat (package-lock-file-name) (package-lock-stage-infix))]
    [len : i64 (string.string-length name)]
    [index : i64 (string.string-length (& prefix))]
    [runs : i64 0]
    [ok : bool (string.is-string-prefix-at name (& prefix) 0)]
    (while (and ok (< runs 3))
      (let
        [start : i64 index]
        (while (and
          (< index len)
          (package-lock-decimal-digit? (string.string-ref name index)))
          (set! index (+ index 1)))
        (set! runs (+ runs 1))
        (cond
          [(= index start) (set! ok false)]
          [(= runs 3) unit]
          [(and (< index len) (= (string.string-ref name index) '.'))
            (set! index (+ index 1))]
          [else (set! ok false)])))
    (and ok (= index len))))

(define (package-lock-stage-path
  [destination : String]
  [sequence : i64]
  [attempt : i64]) : String
  (str_cat.str-cat
    destination
    (package-lock-stage-infix)
    (string.int->string (fs.process-id))
    "."
    (string.int->string sequence)
    "."
    (string.int->string attempt)))

(define (package-lock-remove-stage [path : String]) : ResultPackageLockString
  (match (fs.try-remove-file-if-exists (& path))
    [(OkIoUnit) (Ok "")]
    [(ErrIoUnit error)
      (Err
        (package-lock-transaction-error "cleanup" path (io.error-message error)))]))

(define (package-lock-stage-write-opened
  [path : String]
  [source : (& str)]
  [handle : io.FileHandle]) : ResultPackageLockString
  (if (package-lock-transaction-fault? "during-stage")
    (begin
      (io.file-close handle)
      (package-lock-remove-stage (string.copy path))
      (Err
        (package-lock-transaction-error
          "during-stage"
          path
          "injected test failure")))
    (match (io.file-write handle (byte_buf.str-as-bytes source))
      [(ErrIoUnit error)
        (io.file-close handle)
        (package-lock-remove-stage (string.copy path))
        (Err
          (package-lock-transaction-error
            "stage-write"
            path
            (io.error-message error)))]
      [(OkIoUnit)
        (match (io.file-flush handle)
          [(ErrIoUnit error)
            (io.file-close handle)
            (package-lock-remove-stage (string.copy path))
            (Err
              (package-lock-transaction-error
                "stage-flush"
                path
                (io.error-message error)))]
          [(OkIoUnit)
            (match (io.file-close handle)
              [(ErrIoUnit error)
                (package-lock-remove-stage (string.copy path))
                (Err
                  (package-lock-transaction-error
                    "stage-close"
                    path
                    (io.error-message error)))]
              [(OkIoUnit) (Ok path)])])])))

(define (package-lock-stage-write-attempt
  [destination : String]
  [source : String]
  [sequence : i64]
  [attempt : i64]) : ResultPackageLockString
  (if (>= attempt 100)
    (Err
      (package-lock-transaction-error
        "stage-create"
        destination
        "could not allocate a unique sibling staging path"))
    (let
      [path : String
        (package-lock-stage-path (string.copy destination) sequence attempt)]
      (match (io.file-open (& path) (OpenWriteCreateNew))
        [(OkIoFile handle)
          (package-lock-stage-write-opened path (& source) handle)]
        [(ErrIoFile error)
          (if (package-lock-io-already-exists? (& (clone error)))
            (package-lock-stage-write-attempt
              destination
              source
              sequence
              (+ attempt 1))
            (Err
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
    [(ErrIoBytes error)
      (Err
        (package-lock-transaction-error
          "stage-validate"
          path
          (io.error-message error)))]
    [(OkIoBytes contents)
      (let
        [actual : String (byte_buf.to-string contents)]
        (if (not (string.eq actual expected))
          (Err
            (package-lock-transaction-error
              "stage-validate"
              path
              "staged bytes differ from the complete canonical lock"))
          (match (package-lock-parse actual)
            [(Err message)
              (Err
                (package-lock-transaction-error "stage-validate" path message))]
            [(Ok _) (Ok path)])))]))

(define (package-lock-transaction-ensure-dir [path : String]) : ResultPackageLockString
  (match (fs.try-mkdir-if-missing (& path))
    [(OkIoUnit) (Ok path)]
    [(ErrIoUnit error)
      (Err
        (package-lock-transaction-error
          "coordination-directory"
          path
          (io.error-message error)))]))

(define (package-lock-transaction-lock-path [destination : (& str)]) : ResultPackageLockString
  (let
    [parent : String (fs.dirname destination)]
    [target-name : String "target"]
    [typelisp-name : String "typelisp"]
    [locks-name : String "locks"]
    [guard-name : String "package-lock.writer-lock"]
    [target : String (fs.path-join (& parent) (& target-name))]
    [typelisp : String (fs.path-join (& target) (& typelisp-name))]
    [locks : String (fs.path-join (& typelisp) (& locks-name))]
    [guard : String (fs.path-join (& locks) (& guard-name))]
    [_ (try (package-lock-transaction-ensure-dir target))]
    (let
      [_ (try (package-lock-transaction-ensure-dir typelisp))]
      (let
        [_ (try (package-lock-transaction-ensure-dir locks))]
        (Ok guard)))))

(define (package-lock-transaction-finish
  [lock : fs.FsFileLock]
  [stage : String]
  [remove-stage : bool]
  [result : ResultPackageLockCommit]) : ResultPackageLockCommit
  (let
    [cleanup : ResultPackageLockString
      (if remove-stage
        (package-lock-remove-stage (string.copy stage))
        (Ok ""))]
    [release : io.ResultIoUnit (fs.file-lock-release lock)]
    [_ (try cleanup)]
    (match release
      [(ErrIoUnit error)
        (Err
          (package-lock-transaction-error
            "coordination-unlock"
            stage
            (io.error-message error)))]
      [(OkIoUnit) result])))

(define (package-lock-atomic-replace-attempt
  [stage : (& str)]
  [destination : String]
  [attempt : i64]) : ResultPackageLockString
  (match (fs.try-atomic-replace stage (& destination))
    [(OkIoUnit) (Ok destination)]
    [(ErrIoUnit error)
      (if (and
        (< attempt 100)
        (package-lock-io-retryable-replace? (& (clone error))))
        (match (time.sleep-ms 10)
          [(ErrTimeUnit sleep-error) (Err (time.error-message sleep-error))]
          [(OkTimeUnit)
            (package-lock-atomic-replace-attempt
              stage
              destination
              (+ attempt 1))])
        (Err (io.error-message error)))]))

(define (package-lock-transaction-under-lock
  [snapshot : PackageLockSnapshot]
  [source : String]
  [stage : String]
  [lock : fs.FsFileLock]) : ResultPackageLockCommit
  (match (package-lock-transaction-read (string.copy snapshot.path))
    [(Err message)
      (package-lock-transaction-finish lock stage true (Err message))]
    [(Ok current)
      (cond
        [(package-lock-snapshot-is-source? (& current) (string.copy source))
          (package-lock-transaction-finish
            lock
            stage
            true
            (Ok (Reused snapshot.path)))]
        [(not (package-lock-snapshot-identity-eq? (& snapshot) (& current)))
          (package-lock-transaction-finish
            lock
            stage
            true
            (Err
              (str_cat.str-cat
                "package-lock transaction conflict for '"
                snapshot.path
                "': lock changed since resolution; rerun against the current lock")))]
        [(package-lock-transaction-fault? "before-replace")
          (package-lock-transaction-finish
            lock
            stage
            true
            (Err
              (package-lock-transaction-error
                "before-replace"
                snapshot.path
                "injected test failure")))]
        [else
          (match (package-lock-atomic-replace-attempt
            (& (string.copy stage))
            (string.copy snapshot.path)
            0)
            [(Err message)
              (package-lock-transaction-finish
                lock
                stage
                true
                (Err
                  (package-lock-transaction-error
                    "replace"
                    snapshot.path
                    message)))]
            [(Ok _)
              (package-lock-transaction-finish
                lock
                stage
                false
                (Ok (Replaced snapshot.path)))])])]))

(define (package-lock-transaction-acquire
  [snapshot : PackageLockSnapshot]
  [source : String]
  [guard : String]
  [stage : String]) : ResultPackageLockCommit
  (match (package-lock-transaction-maybe-pause "before-lock")
    [(Err message)
      (package-lock-remove-stage stage)
      (Err message)]
    [(Ok _)
      (match (fs.file-lock-acquire (& guard))
        [(ErrFsFileLock error)
          (package-lock-remove-stage stage)
          (Err
            (package-lock-transaction-error
              "coordination-lock"
              guard
              (io.error-message error)))]
        [(OkFsFileLock lock)
          (package-lock-transaction-under-lock snapshot source stage lock)])]))

(define (package-lock-transaction-stage-ready
  [snapshot : PackageLockSnapshot]
  [source : String]
  [guard : String]
  [stage : String]) : ResultPackageLockCommit
  (match (package-lock-stage-validate (string.copy stage) (string.copy source))
    [(Err message)
      (package-lock-remove-stage stage)
      (Err message)]
    [(Ok _)
      (if (package-lock-transaction-fault? "after-stage")
        (begin
          (package-lock-remove-stage stage)
          (Err
            (package-lock-transaction-error
              "after-stage"
              snapshot.path
              "injected test failure")))
        (package-lock-transaction-acquire snapshot source guard stage))]))

(define (package-lock-transaction-with-guard
  [snapshot : PackageLockSnapshot]
  [source : String]
  [guard : String]) : ResultPackageLockCommit
  (let
    [stage
      (try
        (package-lock-stage-write
          (string.copy snapshot.path)
          (string.copy source)))]
    (package-lock-transaction-stage-ready snapshot source guard stage)))

(define (package-lock-transaction-commit
  [snapshot : PackageLockSnapshot]
  [source : String]) : ResultPackageLockCommit
  (match (package-lock-parse (string.copy source))
    [(Err message)
      (Err (package-lock-transaction-error "validate" snapshot.path message))]
    [(Ok _)
      (if (package-lock-snapshot-is-source? (& snapshot) (string.copy source))
        (Ok (Unchanged snapshot.path))
        (if (package-lock-transaction-fault? "before-stage")
          (Err
            (package-lock-transaction-error
              "before-stage"
              snapshot.path
              "injected test failure"))
          (let
            [guard
              (try
                (package-lock-transaction-lock-path
                  (& (string.copy snapshot.path))))]
            (package-lock-transaction-with-guard snapshot source guard))))]))

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
  [entries : (& entries package_lock_entry_vec.Vec)]
  [alias : String]
  [url : String]
  [kind : package_cache_core.PackageCachePinKind]
  [pin-value : String]
  [commit : String]) : bool
  (match (package-lock-entry-list-lookup entries alias)
    [(No) false]
    [(Some entry)
      (package-lock-entry-matches? entry alias url kind pin-value commit)]))