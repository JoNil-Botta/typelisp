;; compiler_load_lazy_smoke.tl - Lazy dotted import loader smokes (#3871).
(import stdlib.io)
(import stdlib.vector as svec)
(import "../compiler_load.tl")
(import sym_i64_env)

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
      (sym_i64_env.sym-i64-empty))
      [(ResultCompilerLoadWithPaths.Ok decls _ _ seen)
        (and
          (= (compiler-load-lazy-import-skip-count) 1)
          (= (compiler-load-decl-list-count decls) 3)
          (compiler-load-decl-list-has-import-alias? decls "nested.dep" "dep")
          (sym_i64_env.sym-i64-contains seen "lazy.dotted.entry")
          (not (sym_i64_env.sym-i64-contains seen "nested.dep")))]
      [(ResultCompilerLoadWithPaths.Err _) false])))

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
      (sym_i64_env.sym-i64-empty))
      [(ResultCompilerLoadWithPaths.Ok _ _ _ seen)
        (and
          (= (compiler-load-lazy-import-skip-count) 0)
          (sym_i64_env.sym-i64-contains seen "lazy.dotted.used.entry")
          (sym_i64_env.sym-i64-contains seen "nested.dep"))]
      [(ResultCompilerLoadWithPaths.Err _) false])))

(define (lazy-used-stdlib-array-dotted-import-ok?) : bool
  (begin
    (compiler-load-test-mkdir "target/cl_lazy_stdlib_array")
    (compiler-load-test-mkdir "target/cl_lazy_stdlib_array/nested")
    (io.write-file
      "target/cl_lazy_stdlib_array/nested/user.tl"
      "(module nested.user)
(import stdlib.array)
(define (len-b) : i64 (array.length (array.make-array i64 2)))")
    (io.write-file
      "target/cl_lazy_stdlib_array/entry.tl"
      "(module lazy.stdlib.array.entry)
(import stdlib.array)
(import nested.user as user)
(define (len-a) : i64 (array.length (array.make-array i64 1)))
(define (main) : i64 (user.len-b))")
    (match (compiler-load-file-with-paths
      "target/cl_lazy_stdlib_array/entry.tl"
      (sym_i64_env.sym-i64-empty))
      [(ResultCompilerLoadWithPaths.Ok decls _ _ seen)
        (and
          (= (compiler-load-lazy-import-skip-count) 0)
          (compiler-load-decl-list-has-import-alias?
            decls
            "stdlib.array"
            "array")
          (sym_i64_env.sym-i64-contains seen "lazy.stdlib.array.entry")
          (sym_i64_env.sym-i64-contains seen "nested.user")
          (sym_i64_env.sym-i64-contains seen "stdlib.array"))]
      [(ResultCompilerLoadWithPaths.Err _) false])))

(define (lazy-canonical-stdlib-array-import-ok?) : bool
  (begin
    (compiler-load-test-mkdir "target/cl_lazy_stdlib_array_canonical")
    (compiler-load-test-mkdir "target/cl_lazy_stdlib_array_canonical/nested")
    (io.write-file
      "target/cl_lazy_stdlib_array_canonical/nested/user.tl"
      "(module nested.user)
(import stdlib.array)
(define (len-b) : i64
  (stdlib.array.length (stdlib.array.make-array i64 2)))")
    (io.write-file
      "target/cl_lazy_stdlib_array_canonical/entry.tl"
      "(module lazy.stdlib.array.canonical.entry)
(import stdlib.array)
(import nested.user as user)
(define (len-a) : i64
  (stdlib.array.length (stdlib.array.make-array i64 1)))
(define (main) : i64 (user.len-b))")
    (match (compiler-load-file-with-paths
      "target/cl_lazy_stdlib_array_canonical/entry.tl"
      (sym_i64_env.sym-i64-empty))
      [(ResultCompilerLoadWithPaths.Ok decls _ _ seen)
        (and
          (= (compiler-load-lazy-import-skip-count) 2)
          (= (compiler-load-decl-list-count decls) 9)
          (compiler-load-decl-list-has-import-alias?
            decls
            "stdlib.array"
            "array")
          (sym_i64_env.sym-i64-contains
            seen
            "lazy.stdlib.array.canonical.entry")
          (sym_i64_env.sym-i64-contains seen "nested.user")
          (not (sym_i64_env.sym-i64-contains seen "stdlib.array")))]
      [(ResultCompilerLoadWithPaths.Err _) false])))

(define (lazy-stdlib-result-macro-import-ok?) : bool
  (begin
    (compiler-load-test-mkdir "target/cl_lazy_stdlib_result")
    (io.write-file
      "target/cl_lazy_stdlib_result/entry.tl"
      "(module lazy.stdlib.result.entry)
(import stdlib.result)
(import (result i64 String) as result_i64_string)
(define (main) : i64 42)")
    (match (compiler-load-file-with-paths
      "target/cl_lazy_stdlib_result/entry.tl"
      (sym_i64_env.sym-i64-empty))
      [(ResultCompilerLoadWithPaths.Ok decls _ _ seen)
        (and
          (= (compiler-load-lazy-import-skip-count) 1)
          (compiler-load-decl-list-has-import-alias?
            decls
            "stdlib.result"
            "result")
          (sym_i64_env.sym-i64-contains seen "lazy.stdlib.result.entry")
          (not (sym_i64_env.sym-i64-contains seen "stdlib.result")))]
      [(ResultCompilerLoadWithPaths.Err _) false])))

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
      (sym_i64_env.sym-i64-empty)
      (svec.string-vec-new)
      "target/cl_pkg_lazy_dotted"
      (compiler-pkg-deps-empty))
      [(ResultCompilerLoadWithPaths.Ok decls _ _ seen)
        (and
          (= (compiler-load-lazy-import-skip-count) 1)
          (= (compiler-load-decl-list-count decls) 3)
          (compiler-load-decl-list-has-import-alias? decls "nested.dep" "dep")
          (sym_i64_env.sym-i64-contains seen "pkg.lazy.dotted.entry")
          (not (sym_i64_env.sym-i64-contains seen "nested.dep")))]
      [(ResultCompilerLoadWithPaths.Err _) false])))

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
      (sym_i64_env.sym-i64-empty)
      (svec.string-vec-new)
      "target/cl_pkg_lazy_dotted_used"
      (compiler-pkg-deps-empty))
      [(ResultCompilerLoadWithPaths.Ok _ _ _ seen)
        (and
          (= (compiler-load-lazy-import-skip-count) 0)
          (sym_i64_env.sym-i64-contains seen "pkg.lazy.dotted.used.entry")
          (sym_i64_env.sym-i64-contains seen "nested.dep"))]
      [(ResultCompilerLoadWithPaths.Err _) false])))

(define (main) : i64
  (begin
    (unless
      (lazy-unused-dotted-import-ok?)
      (return (io.panic "lazy unused dotted import smoke mismatch")))
    (unless
      (lazy-used-dotted-import-ok?)
      (return (io.panic "lazy used dotted import smoke mismatch")))
    (unless
      (lazy-used-stdlib-array-dotted-import-ok?)
      (return (io.panic "lazy used stdlib.array dotted import smoke mismatch")))
    (unless
      (lazy-canonical-stdlib-array-import-ok?)
      (return (io.panic "lazy canonical stdlib.array import smoke mismatch")))
    (unless
      (lazy-stdlib-result-macro-import-ok?)
      (return (io.panic "lazy stdlib.result macro import smoke mismatch")))
    (unless
      (package-lazy-unused-dotted-import-ok?)
      (return (io.panic "package lazy unused dotted import smoke mismatch")))
    (unless
      (package-lazy-used-dotted-import-ok?)
      (return (io.panic "package lazy used dotted import smoke mismatch")))
    42))