;; package_cache_core.tl - Deterministic package cache layout helpers (#2002).
;;
;; This module plans local cache entries for normalized remote package
;; dependencies and classifies existing entries as reusable, missing, or
;; partial/corrupt. It does not fetch, resolve tag/branch pins, or update
;; lockfiles itself; build_cli_core.tl consumes these helpers for package build
;; cache reuse/refetch and lockfile integration.
(import "../stdlib/core_macros.tl" module stdlib.core_macros as core)

(import "../stdlib/fs.tl")

(import "../stdlib/io.tl")

(import "../stdlib/string.tl")

(import "../stdlib/str_cat.tl")

(defenum PackageCachePinKind
  (PackageCachePinRev)
  (PackageCachePinTag)
  (PackageCachePinBranch))

(defstruct PackageCacheRemoteSpec
  (url String)
  (pin-kind PackageCachePinKind)
  (pin-value String))

(defstruct PackageCacheKey
  (url String)
  (commit String))

(defenum ResultPackageCacheRemoteSpec
  (OkPackageCacheRemoteSpec PackageCacheRemoteSpec)
  (ErrPackageCacheRemoteSpec String))

(defenum ResultPackageCacheKey
  (OkPackageCacheKey PackageCacheKey)
  (ErrPackageCacheKey String))

(defenum PackageCacheEntryState
  (PackageCacheMiss String)
  (PackageCacheCompleteHit String)
  (PackageCachePartialOrCorrupt String String))

(define package-cache-version : String
  "v1")

(define package-cache-metadata-name : String
  "typelisp-cache-entry.txt")

(define package-cache-complete-marker-name : String
  ".typelisp-cache-complete")

(define (package-cache-pin-kind-name [kind : PackageCachePinKind]) : String
  (match kind
    [(PackageCachePinRev) "rev"]
    [(PackageCachePinTag) "tag"]
    [(PackageCachePinBranch) "branch"]))

(define (package-cache-pin-kind-eq?
  [left : PackageCachePinKind]
  [right : PackageCachePinKind]) : bool
  (match left
    [(PackageCachePinRev)
      (match right
        [(PackageCachePinRev) true]
        [_ false])]
    [(PackageCachePinTag)
      (match right
        [(PackageCachePinTag) true]
        [_ false])]
    [(PackageCachePinBranch)
      (match right
        [(PackageCachePinBranch) true]
        [_ false])]))

(defenum ResultPackageCachePinKind
  (OkPackageCachePinKind PackageCachePinKind)
  (ErrPackageCachePinKind String))

(define (package-cache-parse-pin-kind [value : String]) : ResultPackageCachePinKind
  (core/cond
    (string-eq value "rev")
    (OkPackageCachePinKind (PackageCachePinRev))
    (string-eq value "tag")
    (OkPackageCachePinKind (PackageCachePinTag))
    (string-eq value "branch")
    (OkPackageCachePinKind (PackageCachePinBranch))
    (ErrPackageCachePinKind
      (str-cat "package-cache: unsupported remote pin kind '" value "'"))))

(define (package-cache-find-code-from
  [text : String]
  [needle : i64]
  [start : i64]) : i64
  (let
    [n : i64 (string-length text)]
    [i : i64 start]
    [found : i64 -1]
    (begin
      (while (and (= found -1) (< i n))
        (if (= (cast (string-ref text i) : i64) needle)
          (set! found i)
          (set! i (+ i 1))))
      found)))

(define (package-cache-parse-normalized-remote [dep : String]) : ResultPackageCacheRemoteSpec
  (let
    [n : i64 (string-length dep)]
    [hash : i64 (package-cache-find-code-from dep 35 0)]
    (core/cond
      (or (<= hash 0) (>= hash (- n 1)))
      (ErrPackageCacheRemoteSpec
        "package-cache: remote dependency must be URL#rev|tag|branch=value")
      (let
        [url : String (substring dep 0 hash)]
        [fragment : String (substring dep (+ hash 1) (- n (+ hash 1)))]
        [eq : i64 (package-cache-find-code-from fragment 61 0)]
        [fragment-len : i64 (string-length fragment)]
        (core/cond
          (or (<= eq 0) (>= eq (- fragment-len 1)))
          (ErrPackageCacheRemoteSpec
            "package-cache: remote dependency pin must be rev|tag|branch=value")
          (let
            [kind-text : String (substring fragment 0 eq)]
            [pin-value : String
              (substring fragment (+ eq 1) (- fragment-len (+ eq 1)))]
            (if (= (string-length pin-value) 0)
              (ErrPackageCacheRemoteSpec
                "package-cache: remote dependency pin must not be empty")
              (match (package-cache-parse-pin-kind kind-text)
                [(ErrPackageCachePinKind message)
                  (ErrPackageCacheRemoteSpec message)]
                [(OkPackageCachePinKind kind)
                  (OkPackageCacheRemoteSpec
                    (PackageCacheRemoteSpec url kind pin-value))]))))))))

(define (package-cache-key-from-spec [spec : PackageCacheRemoteSpec]) : ResultPackageCacheKey
  (let
    [kind : PackageCachePinKind (struct-get spec pin-kind)]
    (match kind
      [(PackageCachePinRev)
        (let
          [commit : String (struct-get spec pin-value)]
          (if (= (string-length commit) 0)
            (ErrPackageCacheKey "package-cache: exact commit must not be empty")
            (OkPackageCacheKey (PackageCacheKey (struct-get spec url) commit))))]
      [_
        (ErrPackageCacheKey
          (str-cat
            "package-cache: cache key requires exact rev pin, got "
            (package-cache-pin-kind-name kind)
            ""))])))

(define (package-cache-key-from-normalized-remote [dep : String]) : ResultPackageCacheKey
  (match (package-cache-parse-normalized-remote dep)
    [(ErrPackageCacheRemoteSpec message) (ErrPackageCacheKey message)]
    [(OkPackageCacheRemoteSpec spec) (package-cache-key-from-spec spec)]))

(define (package-cache-safe-code? [code : i64]) : bool
  (or
    (and (>= code 48) (<= code 57))
    (and (>= code 65) (<= code 90))
    (and (>= code 97) (<= code 122))
    (= code 45)
    (= code 95)))

(define (package-cache-hex-digit [value : i64]) : String
  (core/cond
    (= value 0)
    "0"
    (= value 1)
    "1"
    (= value 2)
    "2"
    (= value 3)
    "3"
    (= value 4)
    "4"
    (= value 5)
    "5"
    (= value 6)
    "6"
    (= value 7)
    "7"
    (= value 8)
    "8"
    (= value 9)
    "9"
    (= value 10)
    "a"
    (= value 11)
    "b"
    (= value 12)
    "c"
    (= value 13)
    "d"
    (= value 14)
    "e"
    "f"))

(define (package-cache-escape-code [code : i64]) : String
  (let
    [byte : i64 (% code 256)]
    [hi : i64 (/ byte 16)]
    [lo : i64 (% byte 16)]
    (str-cat
      "_x"
      (package-cache-hex-digit hi)
      (string-append (package-cache-hex-digit lo) "_"))))

(define (package-cache-escape-component [text : String]) : String
  (let
    [n : i64 (string-length text)]
    [i : i64 0]
    [out : String ""]
    (begin
      (while (< i n)
        (let
          [code : i64 (cast (string-ref text i) : i64)]
          (begin
            (if (package-cache-safe-code? code)
              (set! out (string-append out (substring text i 1)))
              (set! out (string-append out (package-cache-escape-code code))))
            (set! i (+ i 1)))))
      out)))

(define (package-cache-unversioned-root [package-root : String]) : String
  (fs-path-join-owned-pair
    (fs-path-join-owned-pair
      (fs-path-join-owned-pair
        (fs-path-join-owned-pair package-root "target")
        "typelisp")
      "cache")
    "packages"))

(define (package-cache-default-root [package-root : String]) : String
  (fs-path-join-owned-pair
    (package-cache-unversioned-root package-root)
    package-cache-version))

(define (package-cache-entry-url-dir [root : String] [key : PackageCacheKey]) : String
  (fs-path-join-owned-pair
    (fs-path-join-owned-pair root "git")
    (package-cache-escape-component (struct-get key url))))

(define (package-cache-entry-rev-dir [root : String] [key : PackageCacheKey]) : String
  (fs-path-join-owned-pair (package-cache-entry-url-dir root key) "rev"))

(define (package-cache-entry-path [root : String] [key : PackageCacheKey]) : String
  (fs-path-join-owned-pair
    (package-cache-entry-rev-dir root key)
    (package-cache-escape-component (struct-get key commit))))

(define (package-cache-staging-root [root : String]) : String
  (fs-path-join-owned-pair root "_staging"))

(define (package-cache-staging-url-dir [root : String] [key : PackageCacheKey]) : String
  (fs-path-join-owned-pair
    (fs-path-join-owned-pair (package-cache-staging-root root) "git")
    (package-cache-escape-component (struct-get key url))))

(define (package-cache-staging-rev-dir [root : String] [key : PackageCacheKey]) : String
  (fs-path-join-owned-pair (package-cache-staging-url-dir root key) "rev"))

(define (package-cache-staging-path
  [root : String]
  [key : PackageCacheKey]
  [attempt : i64]) : String
  (fs-path-join-owned-pair
    (package-cache-staging-rev-dir root key)
    (string-append
      (package-cache-escape-component (struct-get key commit))
      (string-append ".tmp." (int->string attempt)))))

(define (package-cache-metadata-path [entry-path : String]) : String
  (fs-path-join-owned-pair entry-path package-cache-metadata-name))

(define (package-cache-complete-marker-path [entry-path : String]) : String
  (fs-path-join-owned-pair entry-path package-cache-complete-marker-name))

(define (package-cache-metadata-content [key : PackageCacheKey]) : String
  (string-append
    "typelisp-package-cache-v1\nurl="
    (string-append
      (struct-get key url)
      (string-append "\ncommit=" (string-append (struct-get key commit) "\n")))))

(define (package-cache-complete-marker-content) : String
  "typelisp-package-cache-v1 complete\n")

(define (package-cache-file-exists? [path : String]) : bool
  (match (try-file-exists? (& path))
    [(OkIoBool exists) exists]
    [(ErrIoBool _) false]))

(define (package-cache-entry-state
  [entry-path : String]
  [key : PackageCacheKey]) : PackageCacheEntryState
  (let
    [metadata-path : String (package-cache-metadata-path entry-path)]
    [marker-path : String (package-cache-complete-marker-path entry-path)]
    [has-entry : bool (package-cache-file-exists? entry-path)]
    [has-metadata : bool (package-cache-file-exists? metadata-path)]
    [has-marker : bool (package-cache-file-exists? marker-path)]
    (core/cond
      (and (not has-entry) (not has-metadata) (not has-marker))
      (PackageCacheMiss entry-path)
      (not has-metadata)
      (PackageCachePartialOrCorrupt entry-path "missing metadata")
      (not has-marker)
      (PackageCachePartialOrCorrupt entry-path "missing completion marker")
      (match (try-read-file (& metadata-path))
        [(ErrIoString error)
          (PackageCachePartialOrCorrupt
            entry-path
            (string-append "metadata read failed: " (io-error-message error)))]
        [(OkIoString metadata)
          (if (not (string-eq metadata (package-cache-metadata-content key)))
            (PackageCachePartialOrCorrupt entry-path "metadata mismatch")
            (match (try-read-file (& marker-path))
              [(ErrIoString error)
                (PackageCachePartialOrCorrupt
                  entry-path
                  (string-append
                    "completion marker read failed: "
                    (io-error-message error)))]
              [(OkIoString marker)
                (if (string-eq marker (package-cache-complete-marker-content))
                  (PackageCacheCompleteHit entry-path)
                  (PackageCachePartialOrCorrupt
                    entry-path
                    "completion marker mismatch"))]))]))))

(define (package-cache-entry-reusable? [state : PackageCacheEntryState]) : bool
  (match state
    [(PackageCacheCompleteHit _) true]
    [_ false]))

(define (package-cache-then-mkdir [result : ResultIoUnit] [path : String]) : ResultIoUnit
  (match result
    [(ErrIoUnit error) (ErrIoUnit error)]
    [(OkIoUnit) (try-mkdir-if-missing (& path))]))

(define (package-cache-prepare-entry-parents
  [root : String]
  [key : PackageCacheKey]) : ResultIoUnit
  (let
    [git-dir : String (fs-path-join-owned-pair root "git")]
    [url-dir : String (package-cache-entry-url-dir root key)]
    [rev-dir : String (package-cache-entry-rev-dir root key)]
    (package-cache-then-mkdir
      (package-cache-then-mkdir
        (package-cache-then-mkdir (try-mkdir-if-missing (& root)) git-dir)
        url-dir)
      rev-dir)))

(define (package-cache-prepare-entry-dir
  [root : String]
  [key : PackageCacheKey]) : ResultIoUnit
  (let
    [entry : String (package-cache-entry-path root key)]
    (package-cache-then-mkdir
      (package-cache-prepare-entry-parents root key)
      entry)))

(define (package-cache-prepare-staging-parents
  [root : String]
  [key : PackageCacheKey]) : ResultIoUnit
  (let
    [staging-root : String (package-cache-staging-root root)]
    [git-dir : String (fs-path-join-owned-pair staging-root "git")]
    [url-dir : String (package-cache-staging-url-dir root key)]
    [rev-dir : String (package-cache-staging-rev-dir root key)]
    (package-cache-then-mkdir
      (package-cache-then-mkdir
        (package-cache-then-mkdir
          (package-cache-then-mkdir
            (try-mkdir-if-missing (& root))
            staging-root)
          git-dir)
        url-dir)
      rev-dir)))

(define (package-cache-finalize-staged
  [staged-path : String]
  [entry-path : String]) : ResultIoUnit
  (try-rename (& staged-path) (& entry-path)))

(define (package-cache-write-complete-marker
  [entry-path : String]
  [key : PackageCacheKey]) : ResultIoUnit
  (let
    [metadata-path : String (package-cache-metadata-path entry-path)]
    [marker-path : String (package-cache-complete-marker-path entry-path)]
    [metadata : String (package-cache-metadata-content key)]
    [marker : String (package-cache-complete-marker-content)]
    (match (try-write-file (& metadata-path) (& metadata))
      [(ErrIoUnit error) (ErrIoUnit error)]
      [(OkIoUnit) (try-write-file (& marker-path) (& marker))])))

(define (package-cache-parse-ok?
  [dep : String]
  [expected-url : String]
  [expected-kind : PackageCachePinKind]
  [expected-pin : String]) : bool
  (match (package-cache-parse-normalized-remote dep)
    [(ErrPackageCacheRemoteSpec _) false]
    [(OkPackageCacheRemoteSpec spec)
      (and
        (string-eq (struct-get spec url) expected-url)
        (package-cache-pin-kind-eq? (struct-get spec pin-kind) expected-kind)
        (string-eq (struct-get spec pin-value) expected-pin))]))

(define (package-cache-parse-rejects? [dep : String]) : bool
  (match (package-cache-parse-normalized-remote dep)
    [(ErrPackageCacheRemoteSpec _) true]
    [(OkPackageCacheRemoteSpec _) false]))

(define (package-cache-key-ok? [dep : String] [expected-commit : String]) : bool
  (match (package-cache-key-from-normalized-remote dep)
    [(ErrPackageCacheKey _) false]
    [(OkPackageCacheKey key)
      (string-eq (struct-get key commit) expected-commit)]))

(define (package-cache-key-rejects? [dep : String]) : bool
  (match (package-cache-key-from-normalized-remote dep)
    [(ErrPackageCacheKey _) true]
    [(OkPackageCacheKey _) false]))

(define (package-cache-state-complete? [state : PackageCacheEntryState]) : bool
  (match state
    [(PackageCacheCompleteHit _) true]
    [_ false]))

(define (package-cache-state-miss? [state : PackageCacheEntryState]) : bool
  (match state
    [(PackageCacheMiss _) true]
    [_ false]))

(define (package-cache-state-partial? [state : PackageCacheEntryState]) : bool
  (match state
    [(PackageCachePartialOrCorrupt _ _) true]
    [_ false]))

(define (package-cache-expect-key [dep : String]) : PackageCacheKey
  (match (package-cache-key-from-normalized-remote dep)
    [(OkPackageCacheKey key) key]
    [(ErrPackageCacheKey message)
      (begin
        (panic message)
        (PackageCacheKey "" ""))]))

(define (package-cache-expect-ok [result : ResultIoUnit] [message : String]) : unit
  (match result
    [(OkIoUnit) unit]
    [(ErrIoUnit error) (panic (string-append message (io-error-message error)))]))

(define (package-cache-expect-temp [result : ResultIoString]) : String
  (match result
    [(OkIoString value) value]
    [(ErrIoString error)
      (begin
        (panic
          (string-append
            "package-cache: temp dir failed: "
            (io-error-message error)))
        "")]))

(define (package-cache-pure-self-test-ok?) : bool
  (let
    [dep-a : String "https://github.com/owner/repo.git#rev=abc123"]
    [dep-b : String "https://github.com/owner/repo.git#rev=def456"]
    [dep-c : String "https://github.com/owner/other.git#rev=abc123"]
    [key-a : PackageCacheKey (package-cache-expect-key dep-a)]
    [key-b : PackageCacheKey (package-cache-expect-key dep-b)]
    [key-c : PackageCacheKey (package-cache-expect-key dep-c)]
    [dot-key : PackageCacheKey
      (package-cache-expect-key "https://github.com/owner/repo.git#rev=..")]
    [root : String "root"]
    [path-a : String (package-cache-entry-path root key-a)]
    [path-a-again : String (package-cache-entry-path root key-a)]
    [path-b : String (package-cache-entry-path root key-b)]
    [path-c : String (package-cache-entry-path root key-c)]
    [path-dot : String (package-cache-entry-path root dot-key)]
    [parent-segment : String ".."]
    [stage-a : String (package-cache-staging-path root key-a 7)]
    [stage-a-again : String (package-cache-staging-path root key-a 7)]
    (and
      (package-cache-parse-ok?
        dep-a
        "https://github.com/owner/repo.git"
        (PackageCachePinRev)
        "abc123")
      (package-cache-parse-ok?
        "https://github.com/owner/repo.git#tag=v1.0.0"
        "https://github.com/owner/repo.git"
        (PackageCachePinTag)
        "v1.0.0")
      (package-cache-parse-ok?
        "https://github.com/owner/repo.git#branch=main"
        "https://github.com/owner/repo.git"
        (PackageCachePinBranch)
        "main")
      (package-cache-parse-rejects? "https://github.com/owner/repo.git")
      (package-cache-parse-rejects?
        "https://github.com/owner/repo.git#sha=abc123")
      (package-cache-key-ok? dep-a "abc123")
      (package-cache-key-rejects?
        "https://github.com/owner/repo.git#tag=v1.0.0")
      (string-eq path-a path-a-again)
      (not (string-eq path-a path-b))
      (not (string-eq path-a path-c))
      (not (string-contains (& path-dot) (& parent-segment)))
      (string-eq stage-a stage-a-again))))

(define (package-cache-filesystem-self-test-ok?) : bool
  (let
    [temp-prefix : String "typelisp-package-cache"]
    [root : String
      (package-cache-expect-temp (try-create-temp-dir (& temp-prefix)))]
    [key : PackageCacheKey
      (package-cache-expect-key "https://github.com/owner/repo.git#rev=abc123")]
    [missing : String (package-cache-entry-path root key)]
    [complete-key : PackageCacheKey
      (package-cache-expect-key "https://github.com/owner/repo.git#rev=def456")]
    [partial-key : PackageCacheKey
      (package-cache-expect-key "https://github.com/owner/repo.git#rev=feed01")]
    [mismatch-key : PackageCacheKey
      (package-cache-expect-key "https://github.com/owner/repo.git#rev=bad999")]
    [wrong-key : PackageCacheKey
      (package-cache-expect-key "https://github.com/owner/repo.git#rev=other")]
    [complete : String (package-cache-entry-path root complete-key)]
    [partial : String (package-cache-entry-path root partial-key)]
    [mismatch : String (package-cache-entry-path root mismatch-key)]
    [partial-metadata-path : String (package-cache-metadata-path partial)]
    [mismatch-metadata-path : String (package-cache-metadata-path mismatch)]
    [mismatch-marker-path : String
      (package-cache-complete-marker-path mismatch)]
    [partial-metadata : String (package-cache-metadata-content partial-key)]
    [wrong-metadata : String (package-cache-metadata-content wrong-key)]
    [marker : String (package-cache-complete-marker-content)]
    (begin
      (package-cache-expect-ok
        (package-cache-prepare-entry-dir root complete-key)
        "prepare complete entry: ")
      (package-cache-expect-ok
        (package-cache-write-complete-marker complete complete-key)
        "write complete marker: ")
      (package-cache-expect-ok
        (package-cache-prepare-entry-dir root partial-key)
        "prepare partial entry: ")
      (package-cache-expect-ok
        (try-write-file (& partial-metadata-path) (& partial-metadata))
        "write partial metadata: ")
      (package-cache-expect-ok
        (package-cache-prepare-entry-dir root mismatch-key)
        "prepare mismatch entry: ")
      (package-cache-expect-ok
        (try-write-file (& mismatch-metadata-path) (& wrong-metadata))
        "write mismatch metadata: ")
      (package-cache-expect-ok
        (try-write-file (& mismatch-marker-path) (& marker))
        "write mismatch marker: ")
      (and
        (package-cache-state-miss? (package-cache-entry-state missing key))
        (package-cache-state-complete?
          (package-cache-entry-state complete complete-key))
        (package-cache-entry-reusable?
          (package-cache-entry-state complete complete-key))
        (package-cache-state-partial?
          (package-cache-entry-state partial partial-key))
        (not
          (package-cache-entry-reusable?
            (package-cache-entry-state partial partial-key)))
        (package-cache-state-partial?
          (package-cache-entry-state mismatch mismatch-key))))))

(define (package-cache-self-test) : i64
  (if (and
    (package-cache-pure-self-test-ok?)
    (package-cache-filesystem-self-test-ok?))
    42
    (begin
      (panic "package-cache: self-test mismatch")
      1)))

(test
  package-cache-parse-key-and-paths
  (if (package-cache-pure-self-test-ok?)
    unit
    (panic "package-cache: pure inline test mismatch")))