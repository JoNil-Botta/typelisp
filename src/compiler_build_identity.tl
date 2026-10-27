;; Commit provenance and exact source-content identity have different jobs.
;; The commit is a named static array: its bytes must never name a literal or
;; enter the compressed stdlib image. The tree identity keys TLCI/frontend
;; admission, so different commits of one tree execute the same compiler work.
;; Plain source-tool builds carry `unknown` and cannot trust frontend surfaces.
(cfg
  (any stage0-build-version compiler-build-identity)
  (import stdlib.comptime))
(import stdlib.string)

(defmacro (compiler-build-identity-global-shared-view [place : Expr]) : Expr
  `(unsafe
    (ptr-read (ptr-addr-of ,place))))

(cfg
  (any stage0-build-version compiler-build-identity)
  (include-str-comptime
    compiler-build-git-hash-input
    "../target/build-stage0/git-hash.txt"))

(cfg
  (any stage0-build-version compiler-build-identity)
  (include-str compiler-build-producer-hash "../target/build-stage0/tree-hash.txt"))

(cfg
  (not (any stage0-build-version compiler-build-identity))
  (define compiler-build-producer-hash : String
    "unknown"))

;; Expand to scalar literals so the existing static-array lowering emits one
;; fixed-size, symbol-named provenance field with no content-derived labels.
(cfg
  (any stage0-build-version compiler-build-identity)
  (defmacro (compiler-build-commit-array [identity : Expr]) : Expr
    (let
      [text : String (comptime.expr-string-value identity)]
      [length : i64 (string.string-length text)]
      [bytes : comptime.ExprList (comptime.expr-list-empty)]
      (while (> length 40)
        (match (string.string-ref text (- length 1))
          ['\n' unit]
          ['\r' unit]
          [_
            (comptime.comptime-error
              "compiler commit must be a full Git object name")])
        (set! length (- length 1)))
      (if (!= length 40)
        (comptime.comptime-error
          "compiler commit must be a full Git object name")
        unit)
      (while (> length 0)
        (set! length (- length 1))
        (let
          [byte : char (string.string-ref text length)]
          (if (if (>= byte '0')
            (if (<= byte '9')
              true
              (if (>= byte 'a')
                (<= byte 'f')
                false))
            false)
            unit
            (comptime.comptime-error
              "compiler commit must be a full Git object name"))
          (set!
            bytes
            (comptime.expr-list-cons
              (comptime.expr-int (cast byte : i64))
              bytes))))
      `(array ,@bytes))))

(cfg
  (any stage0-build-version compiler-build-identity)
  (define compiler-build-commit-bytes : (Array u8 40)
    (compiler-build-commit-array (compiler-build-git-hash-input))))
(cfg
  (any stage0-build-version compiler-build-identity)
  (define compiler-build-git-hash : String
    (unsafe
      (string-from-bytes
        (ptr-cast (__tl_array-data compiler-build-commit-bytes) : (Ptr u8))
        40))))
(cfg
  (not (any stage0-build-version compiler-build-identity))
  (define compiler-build-git-hash : String
    "unknown"))

(define (compiler-build-git-hash-shared-view) : String
  (compiler-build-identity-global-shared-view compiler-build-git-hash))

(define (compiler-build-producer-identity) : String
  (string.copy (& compiler-build-producer-hash)))