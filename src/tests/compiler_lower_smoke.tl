;; compiler_lower_smoke.tl - Runnable smoke for compiler_lower.tl (#446).
(import "../compiler_driver_core.tl")

(define (compiler-lower-smoke-imported-local-enum-vector-source) : String
  "(module stdlib.vector)
(defstruct StringVec (len i64) (first String))
(define (string-vec-new) : StringVec
  (StringVec 0 \"\"))
(define (string-vec-push [v : StringVec] [value : String]) : StringVec
  (StringVec (+ (struct-get v len) 1) value))
(define (string-vec-get [v : StringVec] [index : i64] [fallback : String]) : String
  (if (< index (struct-get v len))
    (struct-get v first)
    fallback))
(export
  (type StringVec)
  (value string-vec-new)
  (value string-vec-push)
  (value string-vec-get))
(module stdlib.list)
(import stdlib.vector)
(defenum StringList (StringNil) (StringCons String (Box StringList)))
(define (string-list-single [value : String]) : StringList
  (StringCons value (box StringNil)))
(define (string-list-count [items : StringList]) : i64
  (match items
    [(StringNil) 0]
    [(StringCons _ rest) (+ 1 (string-list-count (box-get rest)))]))
(define (string-list-to-vec-into
  [items : StringList]
  [out : vector.StringVec]) : vector.StringVec
  (match items
    [(StringNil) out]
    [(StringCons head rest)
      (string-list-to-vec-into
        (box-get rest)
        (vector.string-vec-push out head))]))
(define (string-list-to-vec [items : StringList]) : vector.StringVec
  (string-list-to-vec-into items (vector.string-vec-new)))
(define (string-list-from-vec-single [v : vector.StringVec]) : StringList
  (StringCons (vector.string-vec-get v 0 \"\") (box StringNil)))
(define (string-list-roundtrip-count [items : StringList]) : i64
  (string-list-count (string-list-from-vec-single (string-list-to-vec items))))
(export
  (type StringList)
  (variant StringNil)
  (variant StringCons)
  (value string-list-single)
  (value string-list-count)
  (value string-list-roundtrip-count))
(module main)
(import stdlib.list)
(define (main) : i64
  (list.string-list-roundtrip-count (list.string-list-single \"a\")))")

(define (compiler-lower-smoke-imported-local-enum-vector-ok?) : bool
  (match (lower-compiler-source
    (compiler-lower-smoke-imported-local-enum-vector-source))
    [(OkCompilerLower _ _) true]
    [(ErrCompilerLower _) false]))

(define (compiler-lower-smoke-imported-nullary-file-ok?) : bool
  (let
    [root : String "target/lower_nullary_stdlib"]
    [dep : String "target/lower_nullary_stdlib/list.tl"]
    [entry : String "target/lower_nullary_entry.tl"]
    [roots : StringVec (string-vec-push (string-vec-new) root)]
    (begin
      (compiler-load-test-mkdir root)
      (write-file
        dep
        "(module stdlib.list)
(defenum StringList (StringNil) (StringCons String (Box StringList)))
(define (string-list-cons [value : String] [rest : StringList]) : StringList
  (StringCons value (box rest)))
(define (string-list-single [value : String]) : StringList
  (StringCons value (box StringNil)))
(export
  (type StringList)
  (variant StringNil)
  (variant StringCons)
  (value string-list-cons)
  (value string-list-single))")
      (write-file
        entry
        "(import stdlib.list)
(define (main) : i64
  (string-length
    (match (list.string-list-single \"a\")
      [(list.StringNil) \"\"]
      [(list.StringCons head _) head])))")
      (match (compiler-load-file-with-paths-and-roots
        entry
        (sym-i64-empty)
        roots)
        [(OkCompilerLoadWithPaths decls paths _ _)
          (match (lower-compiler-program-with-decl-paths
            entry
            (ast-program decls)
            paths)
            [(OkCompilerLower _ _) true]
            [(ErrCompilerLower _) false])]
        [(ErrCompilerLoadWithPaths _) false]))))

(define (compiler-lower-smoke-stdlib-args-ok?) : bool
  (let
    [roots : StringVec (string-vec-push (string-vec-new) "stdlib")]
    (match (compiler-driver-load-and-lower-escaping
      "stdlib/args.tl"
      (BackendTargetLinux)
      roots
      (BackendModeScalar)
      (compiler-cfg-empty))
      [(OkCompilerDriverLowered _ _ _ _) true]
      [(ErrCompilerDriverLowered _) false])))

(define (compiler-lower-smoke-issue3494-ok?) : bool
  (and
    (compiler-lower-smoke-imported-local-enum-vector-ok?)
    (compiler-lower-smoke-imported-nullary-file-ok?)
    (compiler-lower-smoke-stdlib-args-ok?)))

(define (main) : i64
  (begin
    (compiler-lower-self-test)
    (unless
      (compiler-lower-smoke-issue3494-ok?)
      (panic "lower: issue3494 smoke failed"))
    42))