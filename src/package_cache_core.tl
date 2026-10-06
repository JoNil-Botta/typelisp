;; package_cache_core.tl - Deterministic package cache layout helpers.
;;
;; This module plans local cache entries for normalized remote package
;; dependencies and classifies existing entries as reusable, missing, or
;; partial/corrupt. It does not fetch, resolve tag/branch pins, or update
;; lockfiles itself; build_cli_core.tl consumes these helpers for package build
;; cache reuse/refetch and lockfile integration.
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.fs)
(import stdlib.byte_buf)
(import stdlib.io)
(import stdlib.string)

(defenum PackageCachePinKind
  (Rev)
  (Tag)
  (Branch))

(defstruct PackageCacheRemoteSpec
  (url String)
  (pin-kind PackageCachePinKind)
  (pin-value String))

(defstruct PackageCacheKey
  (url String)
  (commit String))

(defenum ResultPackageCacheRemoteSpec
  (Ok PackageCacheRemoteSpec)
  (Err String))

(defenum ResultPackageCacheKey
  (Ok PackageCacheKey)
  (Err String))

(defenum PackageCacheEntryState
  (Miss String)
  (CompleteHit String)
  (PartialOrCorrupt String String))

(define package-cache-version : String
  "v1")
(define package-cache-metadata-name : String
  "typelisp-cache-entry.txt")
(define package-cache-complete-marker-name : String
  ".typelisp-cache-complete")

(define (package-cache-pin-kind-name [kind : PackageCachePinKind]) : String
  (match kind
    [(Rev) "rev"]
    [(Tag) "tag"]
    [(Branch) "branch"]))

(define (package-cache-pin-kind-eq?
  [left : PackageCachePinKind]
  [right : PackageCachePinKind]) : bool
  (match left
    [(Rev)
      (match right
        [(Rev) true]
        [_ false])]
    [(Tag)
      (match right
        [(Tag) true]
        [_ false])]
    [(Branch)
      (match right
        [(Branch) true]
        [_ false])]))

(defenum ResultPackageCachePinKind
  (Ok PackageCachePinKind)
  (Err String))

(define (package-cache-safe-code? [code : i64]) : bool
  (or
    (and (>= code 48) (<= code 57))
    (and (>= code 65) (<= code 90))
    (and (>= code 97) (<= code 122))
    (= code 45)
    (= code 95)))

(define (package-cache-hex-digit [value : i64]) : String
  (cond
    [(= value 0) "0"]
    [(= value 1) "1"]
    [(= value 2) "2"]
    [(= value 3) "3"]
    [(= value 4) "4"]
    [(= value 5) "5"]
    [(= value 6) "6"]
    [(= value 7) "7"]
    [(= value 8) "8"]
    [(= value 9) "9"]
    [(= value 10) "a"]
    [(= value 11) "b"]
    [(= value 12) "c"]
    [(= value 13) "d"]
    [(= value 14) "e"]
    [else "f"]))

(define (package-cache-escape-code [code : i64]) : String
  (let
    [byte : i64 (% code 256)]
    [hi : i64 (/ byte 16)]
    [lo : i64 (% byte 16)]
    (str_cat.str-cat
      "_x"
      (package-cache-hex-digit hi)
      (package-cache-hex-digit lo)
      "_")))

(define (package-cache-escape-component [text : (& text str)]) : String
  (let
    [n : i64 (string.string-length text)]
    [i : i64 0]
    [out : String ""]
    (while (< i n)
      (let
        [code : i64 (cast (string.string-ref text i) : i64)]
        (if (package-cache-safe-code? code)
          (set! out (str_cat.str-cat out (string.substring text i 1) ""))
          (set! out (str_cat.str-cat out (package-cache-escape-code code) "")))
        (set! i (+ i 1))))
    out))

(define (package-cache-unversioned-root [package-root : (& package-root str)]) : String
  (let
    [target : String
      (fs.path-join-owned-pair (string.copy package-root) "target")]
    [typelisp : String (fs.path-join-owned-pair target "typelisp")]
    [cache : String (fs.path-join-owned-pair typelisp "cache")]
    (fs.path-join-owned-pair cache "packages")))

(define (package-cache-default-root [package-root : (& package-root str)]) : String
  (let
    [root : String (package-cache-unversioned-root package-root)]
    (fs.path-join-owned-pair root (string.copy (& package-cache-version)))))

(define (package-cache-entry-url-dir
  [root : (& root str)]
  [key : (& key PackageCacheKey)]) : String
  (let
    [git-dir : String (fs.path-join-owned-pair (string.copy root) "git")]
    [url-dir : String (package-cache-escape-component (& key.url))]
    (fs.path-join-owned-pair git-dir url-dir)))

(define (package-cache-entry-rev-dir
  [root : (& root str)]
  [key : (& key PackageCacheKey)]) : String
  (let
    [url-dir : String (package-cache-entry-url-dir root key)]
    (fs.path-join-owned-pair url-dir "rev")))

(define (package-cache-entry-path
  [root : (& root str)]
  [key : (& key PackageCacheKey)]) : String
  (let
    [rev-dir : String (package-cache-entry-rev-dir root key)]
    [commit-dir : String (package-cache-escape-component (& key.commit))]
    (fs.path-join-owned-pair rev-dir commit-dir)))

(define (package-cache-staging-root [root : (& root str)]) : String
  (fs.path-join-owned-pair (string.copy root) "_staging"))

(define (package-cache-staging-url-dir
  [root : (& root str)]
  [key : (& key PackageCacheKey)]) : String
  (let
    [staging-root : String (package-cache-staging-root root)]
    [git-dir : String (fs.path-join-owned-pair staging-root "git")]
    [url-dir : String (package-cache-escape-component (& key.url))]
    (fs.path-join-owned-pair git-dir url-dir)))

(define (package-cache-staging-rev-dir
  [root : (& root str)]
  [key : (& key PackageCacheKey)]) : String
  (let
    [url-dir : String (package-cache-staging-url-dir root key)]
    (fs.path-join-owned-pair url-dir "rev")))

(define (package-cache-staging-path
  [root : (& root str)]
  [key : (& key PackageCacheKey)]
  [attempt : i64]) : String
  (let
    [rev-dir : String (package-cache-staging-rev-dir root key)]
    [commit-dir : String (package-cache-escape-component (& key.commit))]
    [staged-name : String
      (str_cat.str-cat commit-dir ".tmp." (string.int->string attempt))]
    (fs.path-join-owned-pair rev-dir staged-name)))

(define (package-cache-metadata-path [entry-path : (& entry_path str)]) : String
  (fs.path-join-owned-pair
    (string.copy entry-path)
    (string.copy (& package-cache-metadata-name))))

(define (package-cache-complete-marker-path [entry-path : (& entry_path str)]) : String
  (fs.path-join-owned-pair
    (string.copy entry-path)
    (string.copy (& package-cache-complete-marker-name))))

(define (package-cache-metadata-content [key : (& key PackageCacheKey)]) : String
  (let
    [url : String (string.copy (& key.url))]
    [commit : String (string.copy (& key.commit))]
    (str_cat.str-cat
      "typelisp-package-cache-v1\nurl="
      url
      "\ncommit="
      commit
      "\n")))

(define (package-cache-complete-marker-content) : String
  "typelisp-package-cache-v1 complete\n")

(define (package-cache-file-exists? [path : (& path str)]) : bool
  (match (io.try-file-exists? path)
    [(OkIoBool exists) exists]
    [(ErrIoBool _) false]))

(define (package-cache-entry-state
  [entry-path : (& entry_path str)]
  [key : (& key PackageCacheKey)]) : PackageCacheEntryState
  (let
    [metadata-path : String (package-cache-metadata-path entry-path)]
    [marker-path : String (package-cache-complete-marker-path entry-path)]
    [has-entry : bool (package-cache-file-exists? entry-path)]
    [has-metadata : bool (package-cache-file-exists? metadata-path)]
    [has-marker : bool (package-cache-file-exists? marker-path)]
    (cond
      [(and (not has-entry) (not has-metadata) (not has-marker))
        (Miss (string.copy entry-path))]
      [(not has-metadata)
        (PartialOrCorrupt (string.copy entry-path) "missing metadata")]
      [(not has-marker)
        (PartialOrCorrupt (string.copy entry-path) "missing completion marker")]
      [else
        (match (io.try-read-file (& metadata-path))
          [(ErrIoBytes error)
            (PartialOrCorrupt
              (string.copy entry-path)
              (str_cat.str-cat
                "metadata read failed: "
                (io.error-message error)))]
          [(OkIoBytes metadata)
            (if (not
              (string.eq
                (byte_buf.to-string metadata)
                (package-cache-metadata-content key)))
              (PartialOrCorrupt (string.copy entry-path) "metadata mismatch")
              (match (io.try-read-file (& marker-path))
                [(ErrIoBytes error)
                  (PartialOrCorrupt
                    (string.copy entry-path)
                    (str_cat.str-cat
                      "completion marker read failed: "
                      (io.error-message error)))]
                [(OkIoBytes marker)
                  (if (string.eq
                    (byte_buf.to-string marker)
                    (package-cache-complete-marker-content))
                    (CompleteHit (string.copy entry-path))
                    (PartialOrCorrupt
                      (string.copy entry-path)
                      "completion marker mismatch"))]))])])))

(define (package-cache-then-mkdir [result : io.ResultIoUnit] [path : String]) : io.ResultIoUnit
  (let
    [_ (try result)]
    (fs.try-mkdir-if-missing (& path))))

(define (package-cache-prepare-entry-parents
  [root : (& root str)]
  [key : (& key PackageCacheKey)]) : io.ResultIoUnit
  (let
    [git-dir : String (fs.path-join-owned-pair (string.copy root) "git")]
    [url-dir : String (package-cache-entry-url-dir root key)]
    [rev-dir : String (package-cache-entry-rev-dir root key)]
    (package-cache-then-mkdir
      (package-cache-then-mkdir
        (package-cache-then-mkdir (fs.try-mkdir-if-missing root) git-dir)
        url-dir)
      rev-dir)))

(define (package-cache-prepare-staging-parents
  [root : (& root str)]
  [key : (& key PackageCacheKey)]) : io.ResultIoUnit
  (let
    [staging-root : String (package-cache-staging-root root)]
    [git-dir : String
      (fs.path-join-owned-pair (string.copy (& staging-root)) "git")]
    [url-dir : String (package-cache-staging-url-dir root key)]
    [rev-dir : String (package-cache-staging-rev-dir root key)]
    (package-cache-then-mkdir
      (package-cache-then-mkdir
        (package-cache-then-mkdir
          (package-cache-then-mkdir (fs.try-mkdir-if-missing root) staging-root)
          git-dir)
        url-dir)
      rev-dir)))

(define (package-cache-finalize-staged
  [staged-path : String]
  [entry-path : (& entry-path str)]) : io.ResultIoUnit
  (fs.try-rename (& staged-path) entry-path))

(define (package-cache-write-complete-marker
  [entry-path : (& entry_path str)]
  [key : (& key PackageCacheKey)]) : io.ResultIoUnit
  (let
    [metadata-path : String (package-cache-metadata-path entry-path)]
    [marker-path : String (package-cache-complete-marker-path entry-path)]
    [metadata : String (package-cache-metadata-content key)]
    [marker : String (package-cache-complete-marker-content)]
    [_
      (try
        (io.try-write-file
          (& metadata-path)
          (byte_buf.str-as-bytes (& metadata))))]
    (io.try-write-file (& marker-path) (byte_buf.str-as-bytes (& marker)))))