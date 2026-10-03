;; package_cache_smoke.tl - Runnable package cache helper smoke.
(import package_cache_core as cache)
(import compiler_owned_view as owned_view)
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.fs)
(import stdlib.byte_buf)
(import stdlib.io)
(import stdlib.string)

(define (main) : i64
  (package-cache-self-test))

(define (package-cache-parse-pin-kind [value : String]) : cache.ResultPackageCachePinKind
  (cond
    [(string.eq value "rev") (Ok (Rev))]
    [(string.eq value "tag") (Ok (Tag))]
    [(string.eq value "branch") (Ok (Branch))]
    [else
      (Err
        (str_cat.str-cat
          "package-cache: unsupported remote pin kind '"
          value
          "'"))]))

(define (package-cache-find-code-from
  [text : (& text str)]
  [needle : i64]
  [start : i64]) : i64
  (let
    [n : i64 (string.string-length text)]
    [i : i64 start]
    [found : i64 -1]
    (while (and (= found -1) (< i n))
      (if (= (cast (string.string-ref text i) : i64) needle)
        (set! found i)
        (set! i (+ i 1))))
    found))

(define (package-cache-parse-normalized-remote [dep : (& dep str)]) : cache.ResultPackageCacheRemoteSpec
  (let
    [n : i64 (string.string-length dep)]
    [hash : i64 (package-cache-find-code-from dep 35 0)]
    (if (or (<= hash 0) (>= hash (- n 1)))
      (Err "package-cache: remote dependency must be URL#rev|tag|branch=value")
      (let
        [url : String (string.substring dep 0 hash)]
        [fragment : String (string.substring dep (+ hash 1) (- n (+ hash 1)))]
        [eq : i64 (package-cache-find-code-from fragment 61 0)]
        [fragment-len : i64 (string.string-length fragment)]
        (if (or (<= eq 0) (>= eq (- fragment-len 1)))
          (Err
            "package-cache: remote dependency pin must be rev|tag|branch=value")
          (let
            [kind-text : String (string.substring fragment 0 eq)]
            [pin-value : String
              (string.substring fragment (+ eq 1) (- fragment-len (+ eq 1)))]
            (if (= (string.string-length pin-value) 0)
              (Err "package-cache: remote dependency pin must not be empty")
              (match (package-cache-parse-pin-kind kind-text)
                [(Err message) (Err message)]
                [(Ok kind)
                  (Ok (cache.PackageCacheRemoteSpec url kind pin-value))]))))))))

(define (package-cache-key-from-spec [spec : cache.PackageCacheRemoteSpec]) : cache.ResultPackageCacheKey
  (let
    [kind : cache.PackageCachePinKind spec.pin-kind]
    (match kind
      [(Rev)
        (let
          [commit : String spec.pin-value]
          (if (= (string.string-length commit) 0)
            (Err "package-cache: exact commit must not be empty")
            (Ok (cache.PackageCacheKey spec.url commit))))]
      [_
        (Err
          (str_cat.str-cat
            "package-cache: cache key requires exact rev pin, got "
            (cache.package-cache-pin-kind-name kind)
            ""))])))

(define (package-cache-key-from-normalized-remote [dep : String]) : cache.ResultPackageCacheKey
  (match (package-cache-parse-normalized-remote dep)
    [(Err message) (Err message)]
    [(Ok spec) (package-cache-key-from-spec spec)]))

(define (package-cache-entry-reusable? [state : cache.PackageCacheEntryState]) : bool
  (match state
    [(CompleteHit _) true]
    [_ false]))

(define (package-cache-prepare-entry-dir
  [root : (& root str)]
  [key : (& key cache.PackageCacheKey)]) : io.ResultIoUnit
  (let
    [entry : String (cache.package-cache-entry-path root key)]
    (cache.package-cache-then-mkdir
      (cache.package-cache-prepare-entry-parents root key)
      entry)))

(define (package-cache-parse-ok?
  [dep : String]
  [expected-url : String]
  [expected-kind : cache.PackageCachePinKind]
  [expected-pin : String]) : bool
  (match (package-cache-parse-normalized-remote dep)
    [(Err _) false]
    [(Ok spec)
      (and
        (string.eq spec.url expected-url)
        (cache.package-cache-pin-kind-eq? spec.pin-kind expected-kind)
        (string.eq spec.pin-value expected-pin))]))

(define (package-cache-parse-rejects? [dep : String]) : bool
  (match (package-cache-parse-normalized-remote dep)
    [(Err _) true]
    [(Ok _) false]))

(define (package-cache-key-ok? [dep : String] [expected-commit : String]) : bool
  (match (package-cache-key-from-normalized-remote dep)
    [(Err _) false]
    [(Ok key) (string.eq key.commit expected-commit)]))

(define (package-cache-key-rejects? [dep : String]) : bool
  (match (package-cache-key-from-normalized-remote dep)
    [(Err _) true]
    [(Ok _) false]))

(define (package-cache-state-complete? [state : cache.PackageCacheEntryState]) : bool
  (match state
    [(CompleteHit _) true]
    [_ false]))

(define (package-cache-state-miss? [state : cache.PackageCacheEntryState]) : bool
  (match state
    [(Miss _) true]
    [_ false]))

(define (package-cache-state-partial? [state : cache.PackageCacheEntryState]) : bool
  (match state
    [(PartialOrCorrupt _ _) true]
    [_ false]))

(define (package-cache-expect-key [dep : String]) : cache.PackageCacheKey
  (match (package-cache-key-from-normalized-remote dep)
    [(Ok key) key]
    [(Err message) (io.panic message)]))

(define (package-cache-expect-ok [result : io.ResultIoUnit] [message : String]) : unit
  (match result
    [(OkIoUnit) unit]
    [(ErrIoUnit error)
      (io.panic (str_cat.str-cat message (io.error-message error)))]))

(define (package-cache-expect-temp [result : io.ResultIoString]) : String
  (match result
    [(OkIoString value) value]
    [(ErrIoString error)
      (io.panic
        (str_cat.str-cat
          "package-cache: temp dir failed: "
          (io.error-message error)))]))

(define (package-cache-pure-self-test-ok?) : bool
  (let
    [dep-a : String "https://github.com/owner/repo.git#rev=abc123"]
    [dep-b : String "https://github.com/owner/repo.git#rev=def456"]
    [dep-c : String "https://github.com/owner/other.git#rev=abc123"]
    [key-a : cache.PackageCacheKey
      (package-cache-expect-key (owned_view.compiler-owned-shared-view dep-a))]
    [key-b : cache.PackageCacheKey (package-cache-expect-key dep-b)]
    [key-c : cache.PackageCacheKey (package-cache-expect-key dep-c)]
    [dot-key : cache.PackageCacheKey
      (package-cache-expect-key "https://github.com/owner/repo.git#rev=..")]
    [root : String "root"]
    [path-a : String (cache.package-cache-entry-path root (& key-a))]
    [path-a-again : String (cache.package-cache-entry-path root (& key-a))]
    [path-b : String (cache.package-cache-entry-path root (& key-b))]
    [path-c : String (cache.package-cache-entry-path root (& key-c))]
    [path-dot : String (cache.package-cache-entry-path root (& dot-key))]
    [parent-segment : String ".."]
    [stage-a : String (cache.package-cache-staging-path root (& key-a) 7)]
    [stage-a-again : String (cache.package-cache-staging-path root (& key-a) 7)]
    (and
      (package-cache-parse-ok?
        (owned_view.compiler-owned-shared-view dep-a)
        "https://github.com/owner/repo.git"
        (Rev)
        "abc123")
      (package-cache-parse-ok?
        "https://github.com/owner/repo.git#tag=v1.0.0"
        "https://github.com/owner/repo.git"
        (Tag)
        "v1.0.0")
      (package-cache-parse-ok?
        "https://github.com/owner/repo.git#branch=main"
        "https://github.com/owner/repo.git"
        (Branch)
        "main")
      (package-cache-parse-rejects? "https://github.com/owner/repo.git")
      (package-cache-parse-rejects?
        "https://github.com/owner/repo.git#sha=abc123")
      (package-cache-key-ok? dep-a "abc123")
      (package-cache-key-rejects?
        "https://github.com/owner/repo.git#tag=v1.0.0")
      (string.eq path-a path-a-again)
      (not (string.eq path-a path-b))
      (not (string.eq path-a path-c))
      (not (string.contains (& path-dot) (& parent-segment)))
      (string.eq stage-a stage-a-again))))

(define (package-cache-filesystem-self-test-ok?) : bool
  (let
    [temp-prefix : String "typelisp-package-cache"]
    [root : String
      (package-cache-expect-temp (fs.try-create-temp-dir (& temp-prefix)))]
    [key : cache.PackageCacheKey
      (package-cache-expect-key "https://github.com/owner/repo.git#rev=abc123")]
    [missing : String (cache.package-cache-entry-path root (& key))]
    [complete-key : cache.PackageCacheKey
      (package-cache-expect-key "https://github.com/owner/repo.git#rev=def456")]
    [partial-key : cache.PackageCacheKey
      (package-cache-expect-key "https://github.com/owner/repo.git#rev=feed01")]
    [mismatch-key : cache.PackageCacheKey
      (package-cache-expect-key "https://github.com/owner/repo.git#rev=bad999")]
    [wrong-key : cache.PackageCacheKey
      (package-cache-expect-key "https://github.com/owner/repo.git#rev=other")]
    [complete : String (cache.package-cache-entry-path root (& complete-key))]
    [partial : String (cache.package-cache-entry-path root (& partial-key))]
    [mismatch : String (cache.package-cache-entry-path root (& mismatch-key))]
    [partial-metadata-path : String (cache.package-cache-metadata-path partial)]
    [mismatch-metadata-path : String
      (cache.package-cache-metadata-path mismatch)]
    [mismatch-marker-path : String
      (cache.package-cache-complete-marker-path mismatch)]
    [partial-metadata : String
      (cache.package-cache-metadata-content (& partial-key))]
    [wrong-metadata : String
      (cache.package-cache-metadata-content (& wrong-key))]
    [marker : String (cache.package-cache-complete-marker-content)]
    (package-cache-expect-ok
      (package-cache-prepare-entry-dir root (& complete-key))
      "prepare complete entry: ")
    (package-cache-expect-ok
      (cache.package-cache-write-complete-marker complete (& complete-key))
      "write complete marker: ")
    (package-cache-expect-ok
      (package-cache-prepare-entry-dir root (& partial-key))
      "prepare partial entry: ")
    (package-cache-expect-ok
      (io.try-write-file
        (& partial-metadata-path)
        (byte_buf.str-as-bytes (& partial-metadata)))
      "write partial metadata: ")
    (package-cache-expect-ok
      (package-cache-prepare-entry-dir root (& mismatch-key))
      "prepare mismatch entry: ")
    (package-cache-expect-ok
      (io.try-write-file
        (& mismatch-metadata-path)
        (byte_buf.str-as-bytes (& wrong-metadata)))
      "write mismatch metadata: ")
    (package-cache-expect-ok
      (io.try-write-file
        (& mismatch-marker-path)
        (byte_buf.str-as-bytes (& marker)))
      "write mismatch marker: ")
    (and
      (package-cache-state-miss?
        (cache.package-cache-entry-state missing (& key)))
      (package-cache-state-complete?
        (cache.package-cache-entry-state complete (& complete-key)))
      (package-cache-entry-reusable?
        (cache.package-cache-entry-state complete (& complete-key)))
      (package-cache-state-partial?
        (cache.package-cache-entry-state partial (& partial-key)))
      (not
        (package-cache-entry-reusable?
          (cache.package-cache-entry-state partial (& partial-key))))
      (package-cache-state-partial?
        (cache.package-cache-entry-state mismatch (& mismatch-key))))))

(define (package-cache-self-test) : i64
  (if (and
    (package-cache-pure-self-test-ok?)
    (package-cache-filesystem-self-test-ok?))
    42
    (io.panic "package-cache: self-test mismatch")))

(test
  package-cache-parse-key-and-paths
  (if (package-cache-pure-self-test-ok?)
    unit
    (io.panic "package-cache: pure inline test mismatch")))