;; compiler_load_lazy_smoke.tl - Lazy dotted import loader smokes.
(import stdlib.byte_buf)
(import stdlib.io)
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector String) as svec)
(import compiler_load as load)
(import compiler_load_tests as load_tests)
(import compiler_cfg_core as cfg)
(import compiler_ast_types as ast)
(import compiler_builtin_ids as cbi)
(import compiler_diagnostic as cdiag)
(import compiler_intern as ci)
(import compiler_parse_core as parser)
(import read as reader)
(import sym_i64_env)

(define (lazy-write-text [path : String] [contents : String]) : unit
  (io.write-file path (byte_buf.str-as-bytes (& contents))))

(define (lazy-unused-dotted-import-ok?) : bool
  (load.compiler-load-test-mkdir "target/cl_lazy_dotted")
  (load.compiler-load-test-mkdir "target/cl_lazy_dotted/nested")
  (lazy-write-text
    "target/cl_lazy_dotted/nested/dep.tl"
    "(module nested.dep)
(define (get) : i64 7)")
  (lazy-write-text
    "target/cl_lazy_dotted/entry.tl"
    "(module lazy.dotted.entry)
(import nested.dep as dep)
;; dep.get in a comment must not demand the import.
(define (main) : i64
  (begin
    \"dep.get\"
    42))")
  (match (load_tests.compiler-load-file-with-paths
    "target/cl_lazy_dotted/entry.tl"
    (sym_i64_env.sym-i64-empty))
    [(Ok decls _ _ seen)
      (and
        (= (load_tests.compiler-load-lazy-import-skip-count) 1)
        (= (load_tests.compiler-load-decl-list-count decls) 3)
        (load_tests.compiler-load-decl-list-has-import-alias?
          decls
          "nested.dep"
          "dep")
        (load_tests.compiler-load-test-seen-contains? seen "lazy.dotted.entry")
        (not (load_tests.compiler-load-test-seen-contains? seen "nested.dep")))]
    [(Err _) false]))

(define (lazy-used-dotted-import-ok?) : bool
  (load.compiler-load-test-mkdir "target/cl_lazy_dotted_used")
  (load.compiler-load-test-mkdir "target/cl_lazy_dotted_used/nested")
  (lazy-write-text
    "target/cl_lazy_dotted_used/nested/dep.tl"
    "(module nested.dep)
(define (get) : i64 7)")
  (lazy-write-text
    "target/cl_lazy_dotted_used/entry.tl"
    "(module lazy.dotted.used.entry)
(import nested.dep as dep)
(define (main) : i64 (dep.get))")
  (match (load_tests.compiler-load-file-with-paths
    "target/cl_lazy_dotted_used/entry.tl"
    (sym_i64_env.sym-i64-empty))
    [(Ok _ _ _ seen)
      (and
        (= (load_tests.compiler-load-lazy-import-skip-count) 0)
        (load_tests.compiler-load-test-seen-contains?
          seen
          "lazy.dotted.used.entry")
        (load_tests.compiler-load-test-seen-contains? seen "nested.dep"))]
    [(Err _) false]))

(define (lazy-selected-after-summary-ok?) : bool
  (load.compiler-load-test-mkdir "target/cl_lazy_selected")
  (lazy-write-text
    "target/cl_lazy_selected/provider.tl"
    "(module provider)
(define (answer) : i64 42)")
  (lazy-write-text
    "target/cl_lazy_selected/entry.tl"
    "(import provider as unused)
(import provider.answer as value)
(define (main) : i64 (value))")
  (match (load_tests.compiler-load-file-with-paths
    "target/cl_lazy_selected/entry.tl"
    (sym_i64_env.sym-i64-empty))
    [(Ok decls _ _ seen)
      (and
        (= (load_tests.compiler-load-lazy-import-skip-count) 1)
        (load_tests.compiler-load-test-seen-contains? seen "provider")
        (load_tests.compiler-load-decl-list-has-selected-import?
          decls
          "provider"
          "answer"
          "value"))]
    [(Err _) false]))

(define (lazy-removed-array-module-rejected?) : bool
  (load.compiler-load-test-mkdir "target/cl_removed_array_module")
  (lazy-write-text
    "target/cl_removed_array_module/entry.tl"
    (str_cat.str-cat
      "(module removed.array.entry)\n(import stdlib."
      "array)\n(define (main) : i64 42)"))
  (match (load_tests.compiler-load-file-with-paths
    "target/cl_removed_array_module/entry.tl"
    (sym_i64_env.sym-i64-empty))
    [(Ok _ _ _ _) false]
    [(Err diagnostic)
      (let
        [message : String
          (cdiag.compiler-diagnostic-message (__tl-box-place diagnostic))]
        (and
          (load.compiler-load-string-contains?
            message
            "compiler-load: cannot read import stdlib/")
          (load.compiler-load-string-contains? message "array.tl")))]))

(define (lazy-stdlib-result-macro-import-ok?) : bool
  (load.compiler-load-test-mkdir "target/cl_lazy_stdlib_result")
  (lazy-write-text
    "target/cl_lazy_stdlib_result/entry.tl"
    "(module lazy.stdlib.result.entry)
(import stdlib.result)
(import (result.result i64 String) as result_i64_string)
(define (main) : i64 42)")
  (match (load_tests.compiler-load-file-with-paths
    "target/cl_lazy_stdlib_result/entry.tl"
    (sym_i64_env.sym-i64-empty))
    [(Ok decls _ _ seen)
      (and
        (= (load_tests.compiler-load-lazy-import-skip-count) 0)
        (load_tests.compiler-load-decl-list-has-import-alias?
          decls
          "stdlib.result"
          "result")
        (load_tests.compiler-load-test-seen-contains?
          seen
          "lazy.stdlib.result.entry")
        (load_tests.compiler-load-test-seen-contains? seen "stdlib.result"))]
    [(Err _) false]))

(define (lazy-canonical-path-entry-ok?
  [dir : String]
  [entry-module : String]
  [source : String]) : bool
  ;; SPEC 4.4.3: a use spelled with the imported module's full canonical path
  ;; keeps the import loaded without any alias use (#8812).
  (let
    [nested : String (str_cat.str-cat (clone dir) "/nested")]
    [entry : String (str_cat.str-cat (clone dir) "/entry.tl")]
    (load.compiler-load-test-mkdir (& dir))
    (load.compiler-load-test-mkdir (& nested))
    (lazy-write-text
      (str_cat.str-cat nested "/dep.tl")
      "(module nested.dep)
(defstruct Box (value i64))
(define (get) : i64 7)")
    (lazy-write-text (string.copy entry) source)
    (match (load_tests.compiler-load-file-with-paths
      entry
      (sym_i64_env.sym-i64-empty))
      [(Ok _ _ _ seen)
        (and
          (= (load_tests.compiler-load-lazy-import-skip-count) 0)
          (load_tests.compiler-load-test-seen-contains? seen (& entry-module))
          (load_tests.compiler-load-test-seen-contains? seen "nested.dep"))]
      [(Err _) false])))

(define (lazy-canonical-path-demand-ok?) : bool
  (and
    (lazy-canonical-path-entry-ok?
      "target/cl_lazy_canonical_value"
      "lazy.canonical.value.entry"
      "(module lazy.canonical.value.entry)
(import nested.dep)
(define (main) : i64 (nested.dep.get))")
    (lazy-canonical-path-entry-ok?
      "target/cl_lazy_canonical_type"
      "lazy.canonical.type.entry"
      "(module lazy.canonical.type.entry)
(import nested.dep)
(define (read [b : nested.dep.Box]) : i64 0)
(define (main) : i64 42)")
    (lazy-canonical-path-entry-ok?
      "target/cl_lazy_canonical_both"
      "lazy.canonical.both.entry"
      "(module lazy.canonical.both.entry)
(import nested.dep)
(define (g) : i64 (dep.get))
(define (main) : i64 (+ (g) (nested.dep.get)))")))

(define (lazy-unused-macro-only-import-ok?) : bool
  ;; A declaration-macro-only module stays skipped without a qualified use.
  (load.compiler-load-test-mkdir "target/cl_lazy_unused_macro_only")
  (load.compiler-load-test-mkdir "target/cl_lazy_unused_macro_only/generic")
  (load.compiler-load-test-mkdir
    "target/cl_lazy_unused_macro_only/generic/macro")
  (lazy-write-text
    "target/cl_lazy_unused_macro_only/generic/macro/dep.tl"
    "(module generic.macro.dep)
(defmacro (make [T : type]) : Module (expr-unit))")
  (lazy-write-text
    "target/cl_lazy_unused_macro_only/entry.tl"
    "(module lazy.unused.macro.only.entry)
(import generic.macro.dep as api)
(define (main) : i64 42)")
  (match (load_tests.compiler-load-file-with-paths
    "target/cl_lazy_unused_macro_only/entry.tl"
    (sym_i64_env.sym-i64-empty))
    [(Ok _ _ _ seen)
      (and
        (= (load_tests.compiler-load-lazy-import-skip-count) 1)
        (not
          (load_tests.compiler-load-test-seen-contains?
            seen
            "generic.macro.dep")))]
    [(Err _) false]))

(define (lazy-local-decl-entry-ok?
  [dir : String]
  [source : String]
  [skipped : bool]) : bool
  ;; A local type, enum or extern declaration demands an aliased import only
  ;; through the types it names. A cleanup owner, a typed varargs extern and
  ;; a local macro stay eager (#9682).
  (let
    [nested : String (str_cat.str-cat (clone dir) "/nested")]
    [entry : String (str_cat.str-cat (clone dir) "/entry.tl")]
    (load.compiler-load-test-mkdir (& dir))
    (load.compiler-load-test-mkdir (& nested))
    (lazy-write-text
      (str_cat.str-cat nested "/dep.tl")
      "(module nested.dep)
(defstruct Box (value i64))
(define (close [x : i64]) : unit unit)
(define (get) : i64 7)")
    (lazy-write-text (string.copy entry) source)
    (match (load_tests.compiler-load-file-with-paths
      entry
      (sym_i64_env.sym-i64-empty))
      [(Ok _ _ _ seen)
        (if skipped
          (and
            (= (load_tests.compiler-load-lazy-import-skip-count) 1)
            (not
              (load_tests.compiler-load-test-seen-contains? seen "nested.dep")))
          (and
            (= (load_tests.compiler-load-lazy-import-skip-count) 0)
            (load_tests.compiler-load-test-seen-contains? seen "nested.dep")))]
      [(Err _) false])))

(define (lazy-local-decl-demand-ok?) : bool
  (and
    (lazy-local-decl-entry-ok?
      "target/cl_lazy_local_struct"
      "(module lazy.local.struct.entry)
(import nested.dep as dep)
(defstruct Pair (value i64))
(defstruct RefBox (:lifetimes text) (borrowed (& text str)))
(define (main) : i64 42)"
      true)
    (lazy-local-decl-entry-ok?
      "target/cl_lazy_local_enum"
      "(module lazy.local.enum.entry)
(import nested.dep as dep)
(defenum Choice (One i64) (None))
(defenum RefChoice (:lifetimes text) (Borrowed (& text str)))
(define (main) : i64 42)"
      true)
    (lazy-local-decl-entry-ok?
      "target/cl_lazy_local_extern"
      "(module lazy.local.extern.entry)
(import nested.dep as dep)
(extern (read-byte [arg0 : (Ptr u8)]) : u8)
(define (main) : i64 42)"
      true)
    (lazy-local-decl-entry-ok?
      "target/cl_lazy_local_field_type"
      "(module lazy.local.field.type.entry)
(import nested.dep as dep)
(defstruct Pair (box dep.Box))
(define (main) : i64 42)"
      false)
    (lazy-local-decl-entry-ok?
      "target/cl_lazy_local_field_lifetime_type"
      "(module lazy.local.field.lifetime.type.entry)
(import nested.dep as dep)
(defstruct RefBox (:lifetimes text) (borrowed (& text dep.Box)))
(define (main) : i64 42)"
      false)
    (lazy-local-decl-entry-ok?
      "target/cl_lazy_local_field_canonical"
      "(module lazy.local.field.canonical.entry)
(import nested.dep as dep)
(defstruct Pair (box nested.dep.Box))
(define (main) : i64 42)"
      false)
    (lazy-local-decl-entry-ok?
      "target/cl_lazy_local_field_cleanup"
      "(module lazy.local.field.cleanup.entry)
(import nested.dep as dep)
(defstruct Handle (:cleanup close-handle) (fd i64 (:cleanup dep.close)))
(define (main) : i64 42)"
      false)
    (lazy-local-decl-entry-ok?
      "target/cl_lazy_local_payload_type"
      "(module lazy.local.payload.type.entry)
(import nested.dep as dep)
(defenum Choice (One dep.Box) (None))
(define (main) : i64 42)"
      false)
    (lazy-local-decl-entry-ok?
      "target/cl_lazy_local_payload_cleanup"
      "(module lazy.local.payload.cleanup.entry)
(import nested.dep as dep)
(defenum Slot (:cleanup close-slot) (Full i64 (:cleanup dep.close)) (Empty))
(define (main) : i64 42)"
      false)
    (lazy-local-decl-entry-ok?
      "target/cl_lazy_local_extern_type"
      "(module lazy.local.extern.type.entry)
(import nested.dep as dep)
(extern (read-box [arg0 : (Ptr dep.Box)]) : u8)
(define (main) : i64 42)"
      false)
    (lazy-local-decl-entry-ok?
      "target/cl_lazy_local_extern_varargs"
      "(module lazy.local.extern.varargs.entry)
(import nested.dep as dep)
(extern (sum-boxes [count : i64] [value : ...dep.Box]) : i32 (:symbol \"sum_boxes\"))
(define (main) : i64 42)"
      false)
    (lazy-local-decl-entry-ok?
      "target/cl_lazy_local_cleanup_owner"
      "(module lazy.local.cleanup.owner.entry)
(import nested.dep as dep)
(define (local-close [x : i64]) : unit unit)
(defstruct Handle (:cleanup close-handle) (fd i64 (:cleanup local-close)))
(define (main) : i64 42)"
      false)
    (lazy-local-decl-entry-ok?
      "target/cl_lazy_local_macro"
      "(module lazy.local.macro.entry)
(import nested.dep as dep)
(defmacro (one) : Expr (expr-int 1))
(define (main) : i64 42)"
      false)))

(define (lazy-direct-module-macro-demand-ok?) : bool
  (load.compiler-load-test-mkdir "target/cl_lazy_module_macro")
  (lazy-write-text
    "target/cl_lazy_module_macro/entry.tl"
    "(module lazy.module.macro.entry)
(import stdlib.option)
(import (option.option i64) as option_i64)
(define (main) : i64 42)")
  (match (load_tests.compiler-load-file-with-paths
    "target/cl_lazy_module_macro/entry.tl"
    (sym_i64_env.sym-i64-empty))
    [(Ok _ _ _ seen)
      (and
        (= (load_tests.compiler-load-lazy-import-skip-count) 0)
        (load_tests.compiler-load-test-seen-contains?
          seen
          "lazy.module.macro.entry")
        (load_tests.compiler-load-test-seen-contains? seen "stdlib.option"))]
    [(Err _) false]))

(define (lazy-unused-module-macro-import-ok?) : bool
  (load.compiler-load-test-mkdir "target/cl_lazy_unused_module_macro")
  (lazy-write-text
    "target/cl_lazy_unused_module_macro/entry.tl"
    "(module lazy.unused.module.macro.entry)
(import stdlib.option)
(define (main) : i64 42)")
  (match (load_tests.compiler-load-file-with-paths
    "target/cl_lazy_unused_module_macro/entry.tl"
    (sym_i64_env.sym-i64-empty))
    [(Ok _ _ _ seen)
      (and
        (= (load_tests.compiler-load-lazy-import-skip-count) 1)
        (load_tests.compiler-load-test-seen-contains?
          seen
          "lazy.unused.module.macro.entry")
        (not
          (load_tests.compiler-load-test-seen-contains? seen "stdlib.option")))]
    [(Err _) false]))

(define (lazy-aliased-module-macro-demand-ok?) : bool
  (load.compiler-load-test-mkdir "target/cl_lazy_aliased_module_macro")
  (load.compiler-load-test-mkdir "target/cl_lazy_aliased_module_macro/generic")
  (load.compiler-load-test-mkdir
    "target/cl_lazy_aliased_module_macro/generic/macro")
  (lazy-write-text
    "target/cl_lazy_aliased_module_macro/generic/macro/dep.tl"
    "(module generic.macro.dep)
(defmacro (make [T : type]) : Module (expr-unit))")
  (lazy-write-text
    "target/cl_lazy_aliased_module_macro/entry.tl"
    "(module lazy.aliased.module.macro.entry)
(import generic.macro.dep as api)
(import (make i64) as made)
(define (main) : i64 42)")
  (match (load_tests.compiler-load-file-with-paths
    "target/cl_lazy_aliased_module_macro/entry.tl"
    (sym_i64_env.sym-i64-empty))
    [(Ok _ _ _ seen)
      (and
        (= (load_tests.compiler-load-lazy-import-skip-count) 0)
        (load_tests.compiler-load-test-seen-contains?
          seen
          "lazy.aliased.module.macro.entry")
        (load_tests.compiler-load-test-seen-contains? seen "generic.macro.dep"))]
    [(Err _) false]))

(define (lazy-qualified-module-macro-demand-ok?) : bool
  (load.compiler-load-test-mkdir "target/cl_lazy_qualified_module_macro")
  (load.compiler-load-test-mkdir
    "target/cl_lazy_qualified_module_macro/generic")
  (load.compiler-load-test-mkdir
    "target/cl_lazy_qualified_module_macro/generic/macro")
  (lazy-write-text
    "target/cl_lazy_qualified_module_macro/generic/macro/dep.tl"
    "(module generic.macro.dep)
(defmacro (make [T : type]) : Module (expr-unit))")
  (lazy-write-text
    "target/cl_lazy_qualified_module_macro/entry.tl"
    "(module lazy.qualified.module.macro.entry)
(import generic.macro.dep as api)
(import (generic.macro.dep.make i64) as made)
(define (main) : i64 42)")
  (match (load_tests.compiler-load-file-with-paths
    "target/cl_lazy_qualified_module_macro/entry.tl"
    (sym_i64_env.sym-i64-empty))
    [(Ok _ _ _ seen)
      (and
        (= (load_tests.compiler-load-lazy-import-skip-count) 0)
        (load_tests.compiler-load-test-seen-contains?
          seen
          "lazy.qualified.module.macro.entry")
        (load_tests.compiler-load-test-seen-contains? seen "generic.macro.dep"))]
    [(Err _) false]))

(define (lazy-stdlib-vector-qualified-module-macro-demand-ok?) : bool
  (load.compiler-load-test-mkdir "target/cl_lazy_stdlib_vector_module_macro")
  (lazy-write-text
    "target/cl_lazy_stdlib_vector_module_macro/entry.tl"
    "(module lazy.stdlib.vector.module.macro.entry)
(import stdlib.vector)
(import (stdlib.vector.vector i64) as vec)
(define (main) : i64 42)")
  (let
    [cfgs : sym_i64_env.SymI64Env (cfg.compiler-cfg-empty)]
    (match (load.compiler-load-file-with-paths-and-roots-cfg
      "target/cl_lazy_stdlib_vector_module_macro/entry.tl"
      (sym_i64_env.sym-i64-empty)
      (& (svec.new))
      cfgs)
      [(Ok _ _ _ seen)
        (and
          (= (load_tests.compiler-load-lazy-import-skip-count) 0)
          (load_tests.compiler-load-test-seen-contains?
            seen
            "lazy.stdlib.vector.module.macro.entry")
          (load_tests.compiler-load-test-seen-contains? seen "stdlib.vector"))]
      [(Err _) false])))

(define (package-lazy-unused-dotted-import-ok?) : bool
  (load.compiler-load-test-mkdir "target/cl_pkg_lazy_dotted")
  (load.compiler-load-test-mkdir "target/cl_pkg_lazy_dotted/nested")
  (lazy-write-text
    "target/cl_pkg_lazy_dotted/nested/dep.tl"
    "(module nested.dep)
(define (get) : i64 7)")
  (lazy-write-text
    "target/cl_pkg_lazy_dotted/entry.tl"
    "(module pkg.lazy.dotted.entry)
(import nested.dep as dep)
(define (main) : i64 42)")
  (match (load_tests.compiler-load-package-file-with-paths-and-roots
    "target/cl_pkg_lazy_dotted/entry.tl"
    (sym_i64_env.sym-i64-empty)
    (svec.new)
    "target/cl_pkg_lazy_dotted"
    (load.compiler-pkg-deps-empty))
    [(Ok decls _ _ seen)
      (and
        (= (load_tests.compiler-load-lazy-import-skip-count) 1)
        (= (load_tests.compiler-load-decl-list-count decls) 3)
        (load_tests.compiler-load-decl-list-has-import-alias?
          decls
          "nested.dep"
          "dep")
        (load_tests.compiler-load-test-seen-contains?
          seen
          "pkg.lazy.dotted.entry")
        (not (load_tests.compiler-load-test-seen-contains? seen "nested.dep")))]
    [(Err _) false]))

(define (package-lazy-used-dotted-import-ok?) : bool
  (load.compiler-load-test-mkdir "target/cl_pkg_lazy_dotted_used")
  (load.compiler-load-test-mkdir "target/cl_pkg_lazy_dotted_used/nested")
  (lazy-write-text
    "target/cl_pkg_lazy_dotted_used/nested/dep.tl"
    "(module nested.dep)
(define (get) : i64 7)")
  (lazy-write-text
    "target/cl_pkg_lazy_dotted_used/entry.tl"
    "(module pkg.lazy.dotted.used.entry)
(import nested.dep as dep)
(define (main) : i64 (dep.get))")
  (match (load_tests.compiler-load-package-file-with-paths-and-roots
    "target/cl_pkg_lazy_dotted_used/entry.tl"
    (sym_i64_env.sym-i64-empty)
    (svec.new)
    "target/cl_pkg_lazy_dotted_used"
    (load.compiler-pkg-deps-empty))
    [(Ok _ _ _ seen)
      (and
        (= (load_tests.compiler-load-lazy-import-skip-count) 0)
        (load_tests.compiler-load-test-seen-contains?
          seen
          "pkg.lazy.dotted.used.entry")
        (load_tests.compiler-load-test-seen-contains? seen "nested.dep"))]
    [(Err _) false]))

(define (lazy-local-alias-does-not-demand-ok?) : bool
  (load.compiler-load-test-mkdir "target/cl_lazy_local_alias")
  (load.compiler-load-test-mkdir "target/cl_lazy_local_alias/generic")
  (load.compiler-load-test-mkdir "target/cl_lazy_local_alias/generic/local")
  (lazy-write-text
    "target/cl_lazy_local_alias/generic/local/dep.tl"
    "(module generic.local.dep)
(define (get) : i64 7)")
  (lazy-write-text
    "target/cl_lazy_local_alias/entry.tl"
    "(module generic.local.entry)
(import generic.local.dep as dep)
(define (main) : i64
  (let
    [dep : i64 42]
    dep))")
  (match (load_tests.compiler-load-file-with-paths
    "target/cl_lazy_local_alias/entry.tl"
    (sym_i64_env.sym-i64-empty))
    [(Ok _ _ _ seen)
      (and
        (= (load_tests.compiler-load-lazy-import-skip-count) 1)
        (load_tests.compiler-load-test-seen-contains?
          seen
          "generic.local.entry")
        (not
          (load_tests.compiler-load-test-seen-contains?
            seen
            "generic.local.dep")))]
    [(Err _) false]))

(define (lazy-generic-qualified-surface-demand-ok?) : bool
  (load.compiler-load-test-mkdir "target/cl_lazy_generic_surface")
  (load.compiler-load-test-mkdir "target/cl_lazy_generic_surface/generic")
  (load.compiler-load-test-mkdir
    "target/cl_lazy_generic_surface/generic/surface")
  (lazy-write-text
    "target/cl_lazy_generic_surface/generic/surface/dep.tl"
    "(module generic.surface.dep)
(defenum Choice (Empty) (Full i64))
(define (get) : i64 7)
(defmacro (number) : Expr 5)")
  (lazy-write-text
    "target/cl_lazy_generic_surface/entry.tl"
    "(module generic.surface.entry)
(import generic.surface.dep as dep)
(define (score [value : dep.Choice]) : i64
  (match value
    [(dep.Choice.Empty) 0]
    [(dep.Choice.Full n) (+ n (dep.get))]))
(define (main) : i64 (dep.number))")
  (match (load_tests.compiler-load-file-with-paths
    "target/cl_lazy_generic_surface/entry.tl"
    (sym_i64_env.sym-i64-empty))
    [(Ok _ _ _ seen)
      (and
        (= (load_tests.compiler-load-lazy-import-skip-count) 0)
        (load_tests.compiler-load-test-seen-contains?
          seen
          "generic.surface.entry")
        (load_tests.compiler-load-test-seen-contains?
          seen
          "generic.surface.dep"))]
    [(Err _) false]))

(define (lazy-generic-direct-surface-demand-ok?) : bool
  (load.compiler-load-test-mkdir "target/cl_lazy_generic_direct")
  (load.compiler-load-test-mkdir "target/cl_lazy_generic_direct/generic")
  (load.compiler-load-test-mkdir "target/cl_lazy_generic_direct/generic/direct")
  (lazy-write-text
    "target/cl_lazy_generic_direct/generic/direct/dep.tl"
    "(module generic.direct.dep)
(define (get) : i64 7)")
  (lazy-write-text
    "target/cl_lazy_generic_direct/entry.tl"
    "(module generic.direct.entry)
(import generic.direct.dep as dep)
(define (main) : i64 (get))")
  (match (load_tests.compiler-load-file-with-paths
    "target/cl_lazy_generic_direct/entry.tl"
    (sym_i64_env.sym-i64-empty))
    [(Ok _ _ _ seen)
      (and
        (= (load_tests.compiler-load-lazy-import-skip-count) 0)
        (load_tests.compiler-load-test-seen-contains?
          seen
          "generic.direct.entry")
        (load_tests.compiler-load-test-seen-contains? seen "generic.direct.dep"))]
    [(Err _) false]))

(define (lazy-cfg-selected-surface-demand-ok?) : bool
  (load.compiler-load-test-mkdir "target/cl_lazy_cfg_surface")
  (load.compiler-load-test-mkdir "target/cl_lazy_cfg_surface/generic")
  (load.compiler-load-test-mkdir "target/cl_lazy_cfg_surface/generic/cfg")
  (lazy-write-text
    "target/cl_lazy_cfg_surface/generic/cfg/dep.tl"
    "(module generic.cfg.dep)
(cfg feature (define (get) : i64 7))")
  (lazy-write-text
    "target/cl_lazy_cfg_surface/entry.tl"
    "(module generic.cfg.entry)
(import generic.cfg.dep as dep)
(cfg feature (define (main) : i64 (dep.get)))")
  (let
    [cfgs : sym_i64_env.SymI64Env
      (cfg.compiler-cfg-enable (cfg.compiler-cfg-empty) "feature")]
    (match (load.compiler-load-file-with-paths-and-roots-cfg
      "target/cl_lazy_cfg_surface/entry.tl"
      (sym_i64_env.sym-i64-empty)
      (& (svec.new))
      cfgs)
      [(Ok _ _ _ seen)
        (and
          (= (load_tests.compiler-load-lazy-import-skip-count) 0)
          (load_tests.compiler-load-test-seen-contains?
            seen
            "generic.cfg.entry")
          (load_tests.compiler-load-test-seen-contains? seen "generic.cfg.dep"))]
      [(Err _) false])))

(define (structural-member-demand-source [source : String] [alias : i64]) : load_tests.CompilerLoadStructuralMemberDemand
  (match (load.compiler-load-parse-source-diagnostic-escaping
    "src/structural_member_demand.tl"
    (& source)
    (cfg.compiler-cfg-empty))
    [(ResultAstProgramDiagnostic.Ok (Program decls))
      (load_tests.compiler-load-structural-member-demand (deref decls) alias)]
    [(ResultAstProgramDiagnostic.Err _) (CompilerLoadStructuralFullDemand)]))

(define (structural-member-demand-no-use-ok?) : bool
  (match (structural-member-demand-source
    "(module demand.none)
(define (main) : i64 42)"
    cbi.compiler-builtin-id-fix-subject)
    [(CompilerLoadStructuralNoDemand) true]
    [_ false]))

(define (structural-member-demand-one-ok?) : bool
  (let
    [demand : load_tests.CompilerLoadStructuralMemberDemand
      (structural-member-demand-source
        "(module demand.one)
(define (main) : i64 (subject.value))"
        cbi.compiler-builtin-id-fix-subject)]
    (and
      (= (load_tests.compiler-load-structural-member-demand-count demand) 1)
      (load_tests.compiler-load-structural-member-demand-contains?
        demand
        cbi.compiler-builtin-id-fix-value))))

(define (structural-member-demand-union-ok?) : bool
  (let
    [demand : load_tests.CompilerLoadStructuralMemberDemand
      (structural-member-demand-source
        "(module demand.union)
(define (main) : i64
  (begin
    (subject.left)
    (subject/right)
    (subject.left)))"
        cbi.compiler-builtin-id-fix-subject)]
    (and
      (= (load_tests.compiler-load-structural-member-demand-count demand) 2)
      (load_tests.compiler-load-structural-member-demand-contains?
        demand
        cbi.compiler-builtin-id-fix-left)
      (load_tests.compiler-load-structural-member-demand-contains?
        demand
        cbi.compiler-builtin-id-fix-right))))

(define (structural-member-demand-shadowing-ok?) : bool
  (and
    (match (structural-member-demand-source
      "(module demand.local)
(define (main) : i64 (let [subject : i64 42] subject))"
      cbi.compiler-builtin-id-fix-subject)
      [(CompilerLoadStructuralNoDemand) true]
      [_ false])
    (match (structural-member-demand-source
      "(module demand.param)
(define (use [subject : i64]) : i64 subject)"
      cbi.compiler-builtin-id-fix-subject)
      [(CompilerLoadStructuralNoDemand) true]
      [_ false])
    (match (structural-member-demand-source
      "(module demand.pattern)
(define (main) : i64 (match 42 [subject subject]))"
      cbi.compiler-builtin-id-fix-subject)
      [(CompilerLoadStructuralNoDemand) true]
      [_ false])))

(define (structural-member-demand-nested-scope-ok?) : bool
  (let
    [demand : load_tests.CompilerLoadStructuralMemberDemand
      (structural-member-demand-source
        "(module demand.nested)
(module local.scope
  (define (shadow [api : i64]) : i64 api))
(define (main) : i64
  (begin
    ((lambda ([subject : i64]) : i64 subject) 1)
    (subject.same)))"
        cbi.compiler-builtin-id-fix-subject)]
    (and
      (= (load_tests.compiler-load-structural-member-demand-count demand) 1)
      (load_tests.compiler-load-structural-member-demand-contains?
        demand
        cbi.compiler-builtin-id-fix-same))))

(define (structural-member-demand-aggregate-ok?) : bool
  ;; Local type declarations demand only the members their types name (#9682).
  (and
    (match (structural-member-demand-source
      "(module demand.aggregate.none)
(defstruct Aggregate (value i64))
(defenum Choice (One i64) (None))"
      cbi.compiler-builtin-id-fix-subject)
      [(CompilerLoadStructuralNoDemand) true]
      [_ false])
    (let
      [demand : load_tests.CompilerLoadStructuralMemberDemand
        (structural-member-demand-source
          "(module demand.aggregate.members)
(defenum Choice (One subject.value) (Two subject.left))"
          cbi.compiler-builtin-id-fix-subject)]
      (and
        (= (load_tests.compiler-load-structural-member-demand-count demand) 2)
        (load_tests.compiler-load-structural-member-demand-contains?
          demand
          cbi.compiler-builtin-id-fix-value)
        (load_tests.compiler-load-structural-member-demand-contains?
          demand
          cbi.compiler-builtin-id-fix-left)))))

(define (structural-member-demand-unknown-ok?) : bool
  ;; A local macro stays an eager fence (#9682).
  (match (load.compiler-load-parse-source-diagnostic-escaping
    "src/structural_member_demand_unknown.tl"
    "(module demand.unknown)
(defmacro (one) : Expr (expr-int 1))"
    (cfg.compiler-cfg-empty))
    [(ResultAstProgramDiagnostic.Ok (Program decls))
      (match (load_tests.compiler-load-structural-member-demand
        (deref decls)
        cbi.compiler-builtin-id-fix-subject)
        [(CompilerLoadStructuralFullDemand) true]
        [_ false])]
    [(ResultAstProgramDiagnostic.Err _) false]))

(define (lazy-preload-observer-state-isolation-ok?) : bool
  (match (load.compiler-load-parse-source-diagnostic-escaping
    "src/lazy_preload_observer_state_isolation.tl"
    "(module demand.isolation)
(define (main) : i64 (subject.same))"
    (cfg.compiler-cfg-empty))
    [(ResultAstProgramDiagnostic.Ok (Program decls))
      (let
        [previous-state : load.CompilerLoadSessionState
          (load.compiler-load-active-session-state-shared-view)]
        [state-a : load.CompilerLoadSessionState
          (load.compiler-load-session-state-new)]
        [state-b : load.CompilerLoadSessionState
          (load.compiler-load-session-state-new)]
        [alias : i64 cbi.compiler-builtin-id-fix-subject]
        [member : i64 cbi.compiler-builtin-id-fix-same]
        [pools : ast.AstNodePoolContext
          (ast.ast-node-pool-context-capture-active)]
        [_select-b : unit
          (let
            [state (load.compiler-load-session-state-shared-view (& state-b))]
            (load.compiler-load-session-state-use! state))]
        [_begin-a : unit
          (load_tests.compiler-load-session-state-lazy-qualified-observer-begin-pair!
            (&mut state-a)
            alias
            cbi.compiler-builtin-id-fix-empty)]
        [_begin-b : unit
          (load_tests.compiler-load-session-state-lazy-qualified-observer-begin-pair!
            (&mut state-b)
            alias
            cbi.compiler-builtin-id-fix-empty)]
        [demand : load.CompilerLoadLazyAliasDemand
          (load.compiler-load-session-state-lazy-import-preload-demand
            (& (load.compiler-load-session-state-shared-view (& state-a)))
            true
            (Some alias)
            (& (deref decls))
            pools)]
        [observed-a : load_tests.CompilerLoadLazyQualifiedObserverResult
          (load_tests.compiler-load-session-state-lazy-qualified-observer-end-pair!
            (&mut state-a))]
        [b-still-active : bool
          (load.compiler-load-session-state-lazy-qualified-observer-active?
            (& state-b))]
        [observed-b : load_tests.CompilerLoadLazyQualifiedObserverResult
          (load_tests.compiler-load-session-state-lazy-qualified-observer-end-pair!
            (&mut state-b))]
        [ok : bool
          (and
            demand.qualified
            (not demand.unknown)
            (sym_i64_env.sym-i64-contains-id demand.members member)
            (sym_i64_env.sym-i64-contains-id observed-a.primary-members member)
            b-still-active
            (not
              (sym_i64_env.sym-i64-contains-id
                observed-b.primary-members
                member)))]
        (load.compiler-load-session-state-use! previous-state)
        ok)]
    [(ResultAstProgramDiagnostic.Err _) false]))

(define (lazy-semantic-origin-same-defstruct-ok?
  [decls : (& decls ast.AstDeclList)]) : bool
  (match (parser.compiler-parse-semantic-origin-run decls 0)
    [(Some run)
      (let
        [type-origin : parser.CompilerParseSemanticOrigin
          (parser.compiler-parse-semantic-origin-run-get
            (& run)
            0
            (parser.compiler-parse-semantic-origin-fallback))]
        [field-origin : parser.CompilerParseSemanticOrigin
          (parser.compiler-parse-semantic-origin-run-get
            (& run)
            1
            (parser.compiler-parse-semantic-origin-fallback))]
        [type-span : ast.AstSourceSpan type-origin.span]
        [field-span : ast.AstSourceSpan field-origin.span]
        (and
          (= (parser.compiler-parse-semantic-origin-run-len (& run)) 4)
          (=
            (parser.compiler-parse-semantic-origin-kind-tag type-origin.kind)
            0)
          (string.eq (ci.intern-str type-origin.written-name) "Same")
          (= (ast.ast-source-span-start-line type-span) 3)
          (= (ast.ast-source-span-start-col type-span) 12)
          (= (ast.ast-source-span-end-line type-span) 3)
          (= (ast.ast-source-span-end-col type-span) 16)
          (=
            (parser.compiler-parse-semantic-origin-kind-tag field-origin.kind)
            2)
          (string.eq (ci.intern-str field-origin.written-name) "same-field")
          (= (ast.ast-source-span-start-line field-span) 3)
          (= (ast.ast-source-span-start-col field-span) 18)
          (= (ast.ast-source-span-end-line field-span) 3)
          (= (ast.ast-source-span-end-col field-span) 28)))]
    [(None) false]))

(define (lazy-semantic-origin-same-count
  [decls : ast.AstDeclList]
  [count : i64]) : i64
  (match (ast.ast-decl-list-step decls)
    [(Nil) count]
    [(Cons decl rest)
      (let
        [rest : ast.AstDeclList rest]
        (match decl
          [(DefStruct _ name _ _ _)
            (if (string.eq (ci.intern-str name) "Same")
              (if (lazy-semantic-origin-same-defstruct-ok? (& decls))
                (lazy-semantic-origin-same-count rest (+ count 1))
                -100)
              (lazy-semantic-origin-same-count rest count))]
          [_ (lazy-semantic-origin-same-count rest count)]))]))

(define (lazy-semantic-origin-import-flatten-ok?) : bool
  (let
    [mark : i64 (reader.sp-node-pool-len)]
    [ok : bool false]
    (lazy-write-text
      "target/cl_semantic_origin_dep.tl"
      "(module cl_semantic_origin_dep)
(define dep-padding : i64 0)
(defstruct Same (same-field Shared.Type))")
    (lazy-write-text
      "target/cl_semantic_origin_entry.tl"
      "(module cl_semantic_origin_entry)
(import cl_semantic_origin_dep as dep)
(defstruct Same (same-field Shared.Type))
(define dep-use : i64 dep.dep-padding)")
    (match (load_tests.compiler-load-file-with-paths
      "target/cl_semantic_origin_entry.tl"
      (sym_i64_env.sym-i64-empty))
      [(Ok decls _ _ _)
        (set! ok (= (lazy-semantic-origin-same-count decls 0) 2))]
      [(Err _) unit])
    (reader.sp-node-pool-truncate! mark)
    (parser.compiler-parse-standalone-origin-reset!)
    ok))

(define (main) : i64
  (unless
    (lazy-unused-dotted-import-ok?)
    (return (io.panic "lazy unused dotted import smoke mismatch")))
  (unless
    (lazy-used-dotted-import-ok?)
    (return (io.panic "lazy used dotted import smoke mismatch")))
  (unless
    (lazy-selected-after-summary-ok?)
    (return (io.panic "lazy selected import after summary smoke mismatch")))
  (unless
    (lazy-removed-array-module-rejected?)
    (return (io.panic "removed array module import was accepted")))
  (unless
    (lazy-stdlib-result-macro-import-ok?)
    (return (io.panic "lazy stdlib.result macro import smoke mismatch")))
  (unless
    (lazy-direct-module-macro-demand-ok?)
    (return (io.panic "lazy direct module macro demand smoke mismatch")))
  (unless
    (lazy-canonical-path-demand-ok?)
    (return (io.panic "lazy canonical module path demand smoke mismatch")))
  (unless
    (lazy-local-decl-demand-ok?)
    (return (io.panic "lazy local declaration demand smoke mismatch")))
  (unless
    (lazy-unused-macro-only-import-ok?)
    (return (io.panic "lazy unused macro-only import smoke mismatch")))
  (unless
    (lazy-unused-module-macro-import-ok?)
    (return (io.panic "lazy unused module macro import smoke mismatch")))
  (unless
    (lazy-aliased-module-macro-demand-ok?)
    (return (io.panic "lazy aliased module macro demand smoke mismatch")))
  (unless
    (lazy-qualified-module-macro-demand-ok?)
    (return (io.panic "lazy qualified module macro demand smoke mismatch")))
  (unless
    (lazy-stdlib-vector-qualified-module-macro-demand-ok?)
    (return
      (io.panic
        "lazy stdlib.vector qualified module macro demand smoke mismatch")))
  (unless
    (package-lazy-unused-dotted-import-ok?)
    (return (io.panic "package lazy unused dotted import smoke mismatch")))
  (unless
    (package-lazy-used-dotted-import-ok?)
    (return (io.panic "package lazy used dotted import smoke mismatch")))
  (unless
    (lazy-local-alias-does-not-demand-ok?)
    (return (io.panic "lazy local alias demand smoke mismatch")))
  (unless
    (lazy-generic-qualified-surface-demand-ok?)
    (return (io.panic "lazy generic qualified surface demand smoke mismatch")))
  (unless
    (lazy-generic-direct-surface-demand-ok?)
    (return (io.panic "lazy generic direct surface demand smoke mismatch")))
  (unless
    (lazy-cfg-selected-surface-demand-ok?)
    (return (io.panic "lazy cfg-selected surface demand smoke mismatch")))
  (unless
    (structural-member-demand-no-use-ok?)
    (return (io.panic "structural member no-use demand mismatch")))
  (unless
    (structural-member-demand-one-ok?)
    (return (io.panic "structural member one demand mismatch")))
  (unless
    (structural-member-demand-union-ok?)
    (return (io.panic "structural member union demand mismatch")))
  (unless
    (structural-member-demand-shadowing-ok?)
    (return (io.panic "structural member shadowing demand mismatch")))
  (unless
    (structural-member-demand-nested-scope-ok?)
    (return (io.panic "structural member nested-scope demand mismatch")))
  (unless
    (structural-member-demand-aggregate-ok?)
    (return (io.panic "structural member aggregate demand mismatch")))
  (unless
    (structural-member-demand-unknown-ok?)
    (return (io.panic "structural member unknown demand mismatch")))
  (unless
    (lazy-preload-observer-state-isolation-ok?)
    (return (io.panic "lazy preload observer isolation smoke mismatch")))
  (unless
    (lazy-semantic-origin-import-flatten-ok?)
    (return (io.panic "lazy semantic origin import flatten smoke mismatch")))
  (unless
    (load_tests.compiler-load-lazy-qualified-observer-dense-stack-ok?)
    (return (io.panic "lazy observer dense stack smoke mismatch")))
  42)