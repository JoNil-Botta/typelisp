;; compiler_build_identity.tl - deterministic identity of the running compiler.
;;
;; Publication/bootstrap builds provide the source Git hash through the same
;; generated input on every host.  Plain source-tool builds deliberately carry
;; `unknown`; they may execute callback-ABI-compatible TLCI code, but exact-build
;; frontend surfaces must fall back to source compilation. The repository root
;; package build refreshes this input from its own Git HEAD before enabling the
;; `compiler-build-identity` cfg.
(import stdlib.string)

(defmacro (compiler-build-identity-global-shared-view [place : Expr]) : Expr
  (cfg
    stage0-seed-bootstrap
    place
    `(unsafe
      (ptr-read (ptr-addr-of ,place)))))

(cfg
  (any stage0-build-version compiler-build-identity)
  (include-str compiler-build-git-hash-raw "../target/build-stage0/git-hash.txt"))

(cfg
  (not (any stage0-build-version compiler-build-identity))
  (define compiler-build-git-hash-raw : String
    "unknown"))

(define (compiler-build-identity-trim-length [identity : String] [length : i64]) : i64
  (if (and
    (> length 0)
    (or
      (= (string.string-ref identity (- length 1)) '\n')
      (= (string.string-ref identity (- length 1)) '\r')))
    (compiler-build-identity-trim-length identity (- length 1))
    length))

(define compiler-build-git-hash : String
  (string.substring
    (compiler-build-identity-global-shared-view compiler-build-git-hash-raw)
    0
    (compiler-build-identity-trim-length
      (compiler-build-identity-global-shared-view compiler-build-git-hash-raw)
      (string.string-length compiler-build-git-hash-raw))))

(define (compiler-build-git-hash-shared-view) : String
  (compiler-build-identity-global-shared-view compiler-build-git-hash))