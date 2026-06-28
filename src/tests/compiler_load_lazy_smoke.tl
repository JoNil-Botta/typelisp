;; compiler_load_lazy_smoke.tl - Lazy dotted import loader smokes (#3871).
(import stdlib.io)
(import stdlib.vector)
(import "../compiler_load.tl")

(define (lazy-unused-dotted-import-ok?) : bool
  (begin
    (compiler-load-test-mkdir "target/cl_lazy_dotted")
    (compiler-load-test-mkdir "target/cl_lazy_dotted/nested")
    (io.write-file
      "target/cl_lazy_dotted/nested/dep.tl"
      "(module nested.dep)
(define (get) : i64 7)")
    (io.write-file
      "target/cl_lazy_dotted/entry.tl"
      "(module lazy.dotted.entry)
(import nested.dep as dep)
(define (main) : i64 42)")
    (match (compiler-load-file-with-paths
      "target/cl_lazy_dotted/entry.tl"
      (sym-i64-empty))
      [(OkCompilerLoadWithPaths decls _ _ seen)
        (and
          (= (compiler-load-lazy-import-skip-count) 1)
          (= (compiler-load-decl-list-count decls) 3)
          (compiler-load-decl-list-has-import-alias? decls "nested.dep" "dep")
          (sym-i64-contains seen "lazy.dotted.entry")
          (not (sym-i64-contains seen "nested.dep")))]
      [(ErrCompilerLoadWithPaths _) false])))

(define (lazy-used-dotted-import-ok?) : bool
  (begin
    (compiler-load-test-mkdir "target/cl_lazy_dotted_used")
    (compiler-load-test-mkdir "target/cl_lazy_dotted_used/nested")
    (io.write-file
      "target/cl_lazy_dotted_used/nested/dep.tl"
      "(module nested.dep)
(define (get) : i64 7)")
    (io.write-file
      "target/cl_lazy_dotted_used/entry.tl"
      "(module lazy.dotted.used.entry)
(import nested.dep as dep)
(define (main) : i64 (dep.get))")
    (match (compiler-load-file-with-paths
      "target/cl_lazy_dotted_used/entry.tl"
      (sym-i64-empty))
      [(OkCompilerLoadWithPaths _ _ _ seen)
        (and
          (= (compiler-load-lazy-import-skip-count) 0)
          (sym-i64-contains seen "lazy.dotted.used.entry")
          (sym-i64-contains seen "nested.dep"))]
      [(ErrCompilerLoadWithPaths _) false])))

(define (package-lazy-unused-dotted-import-ok?) : bool
  (begin
    (compiler-load-test-mkdir "target/cl_pkg_lazy_dotted")
    (compiler-load-test-mkdir "target/cl_pkg_lazy_dotted/nested")
    (io.write-file
      "target/cl_pkg_lazy_dotted/nested/dep.tl"
      "(module nested.dep)
(define (get) : i64 7)")
    (io.write-file
      "target/cl_pkg_lazy_dotted/entry.tl"
      "(module pkg.lazy.dotted.entry)
(import nested.dep as dep)
(define (main) : i64 42)")
    (match (compiler-load-package-file-with-paths-and-roots
      "target/cl_pkg_lazy_dotted/entry.tl"
      (sym-i64-empty)
      (vector.string-vec-new)
      "target/cl_pkg_lazy_dotted"
      (compiler-pkg-deps-empty))
      [(OkCompilerLoadWithPaths decls _ _ seen)
        (and
          (= (compiler-load-lazy-import-skip-count) 1)
          (= (compiler-load-decl-list-count decls) 3)
          (compiler-load-decl-list-has-import-alias? decls "nested.dep" "dep")
          (sym-i64-contains seen "pkg.lazy.dotted.entry")
          (not (sym-i64-contains seen "nested.dep")))]
      [(ErrCompilerLoadWithPaths _) false])))

(define (package-lazy-used-dotted-import-ok?) : bool
  (begin
    (compiler-load-test-mkdir "target/cl_pkg_lazy_dotted_used")
    (compiler-load-test-mkdir "target/cl_pkg_lazy_dotted_used/nested")
    (io.write-file
      "target/cl_pkg_lazy_dotted_used/nested/dep.tl"
      "(module nested.dep)
(define (get) : i64 7)")
    (io.write-file
      "target/cl_pkg_lazy_dotted_used/entry.tl"
      "(module pkg.lazy.dotted.used.entry)
(import nested.dep as dep)
(define (main) : i64 (dep.get))")
    (match (compiler-load-package-file-with-paths-and-roots
      "target/cl_pkg_lazy_dotted_used/entry.tl"
      (sym-i64-empty)
      (vector.string-vec-new)
      "target/cl_pkg_lazy_dotted_used"
      (compiler-pkg-deps-empty))
      [(OkCompilerLoadWithPaths _ _ _ seen)
        (and
          (= (compiler-load-lazy-import-skip-count) 0)
          (sym-i64-contains seen "pkg.lazy.dotted.used.entry")
          (sym-i64-contains seen "nested.dep"))]
      [(ErrCompilerLoadWithPaths _) false])))

(define (main) : i64
  (begin
    (unless
      (lazy-unused-dotted-import-ok?)
      (return (io.panic "lazy unused dotted import smoke mismatch")))
    (unless
      (lazy-used-dotted-import-ok?)
      (return (io.panic "lazy used dotted import smoke mismatch")))
    (unless
      (package-lazy-unused-dotted-import-ok?)
      (return (io.panic "package lazy unused dotted import smoke mismatch")))
    (unless
      (package-lazy-used-dotted-import-ok?)
      (return (io.panic "package lazy used dotted import smoke mismatch")))
    42))