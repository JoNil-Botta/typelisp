;; compiler_load.tl - Shared selfhost compiler source/import loader.
(import stdlib.arena)
(import stdlib.array)
(import stdlib.byte_buf)
(import stdlib.io)
(import compiler_parse_core as parser)
(import compiler_ast_types as ast)
(import compiler_builtin_ids as cbi)
(import compiler_diagnostic as cdiag)
(import lex as lexer)
(import read as reader)
(import compiler_intern as ci)
(import compiler_intern_state as cis)
(import compiler_cfg_core as cfg_core)
(import compiler_build_identity as build_identity)
(import compiler_surface_facts as surface_facts)
(import compiler_surface_hydrate as surface_hydrate)
(import compiler_surface_ast as surface_ast)
(import compiler_surface_identity as surface_identity)
(import sym_i64_env)
(import stdlib.env)
(import stdlib.fs)
(import stdlib.hashmap)
(import (hashmap.hashmap i64 i64) as load_i64_i64_map)
(import stdlib.vector)
(import (vector.vector String) as svec)
(import compiler_embedded_stdlib as ces)
(import compiler_ctfe as ctfe)
(import stdlib.string)
(import stdlib.str_cat_runtime as str_cat)
(import token)
(import tlci_core as tlci)
(import tlci_loader as tlci_loader_support)
(import compiler_owned_view as owned_view)

(defmacro (compiler-load-global-shared-view [place : Expr]) : Expr
  (cfg
    stage0-seed-bootstrap
    place
    `(unsafe
      (ptr-read (ptr-addr-of ,place)))))

(defmacro (compiler-load-global-array-element-shared-view
  [items : Expr]
  [index : Expr]) : Expr
  (cfg
    stage0-seed-bootstrap
    `(array-ref ,items ,index)
    `(unsafe
      (ptr-read (ptr-offset (__tl_array-data ,items) ,index)))))

;; Sources, manifests, and include payloads are interpreted as text here.
;; Make that conversion explicit at the binary IO boundary.
(define (compiler-load-read-file-text [path : (& path str)]) : String
  (let
    [contents : byte_buf.ByteBuf (io.read-file (string.copy path))]
    [count : i64 (byte_buf.len contents)]
    (if (= count 0)
      ""
      ;; `contents` is a fresh, unaliased read result and is never mutated or
      ;; exposed after this point. Transfer its active-arena backing storage
      ;; into the immutable String view instead of copying every source byte a
      ;; second time through the general-purpose `ByteBuf.to-string` boundary.
      (unsafe
        (string-from-bytes
          (byte_buf.bytes-data (byte_buf.as-bytes (& contents)))
          count)))))

(define (compiler-load-write-file-text [path : String] [contents : String]) : unit
  (io.write-file path (byte_buf.str-as-bytes (& contents))))

(define (compiler-load-try-read-file-text [path : (& source str)]) : io.ResultIoString
  (match (io.try-read-file path)
    [(io.OkIoBytes contents) (io.OkIoString (byte_buf.to-string contents))]
    [(io.ErrIoBytes error) (io.ErrIoString error)]))

(define (compiler-load-try-write-file-text
  [path : (& source str)]
  [contents : (& content str)]) : io.ResultIoUnit
  (io.try-write-file path (byte_buf.str-as-bytes contents)))

(define (compiler-load-lex-token-buffer-arena-handle) : i64
  (lexer.spanned-token-buffer-arena-handle-value))

(define (compiler-load-reader-node-pool-arena-handle) : i64
  (reader.sp-node-pool-base-arena-handle-value))

(define (compiler-load-reader-sexpr-pool-arena-handle) : i64
  (reader.sexpr-node-pool-base-arena-handle-value))

;; Retire the frontend scanning storage once a whole-program load has returned
;; its `ast.AstDeclList`. Both owners are pure scan scratch whose contents were
;; already copied out by value; see the no-dangling arguments at their release
;; sites in `lex.tl` and `read.tl`. Only single-entry compile paths call this:
;; a session that reuses loader state across jobs would just pay the regrow.
;;
;; The spanned reader pool (`reader-node-pool`) is deliberately NOT released
;; here. It doubles as the declaration/member origin side table: the parser
;; compacts `__tl_decl_origin` and `__tl_member_origin` runs below each form's
;; mark, and `compiler_symbols.tl`, `compiler_semantic_index.tl`, and the
;; `tc-typecheck-diag-with-*path` error paths in `compiler_typecheck_core.tl`
;; scan those records long after load. Releasing it would silently downgrade
;; every origin lookup to `None`, so those records must live as long as the
;; declarations they describe.
(define (compiler-load-release-frontend-scan-arenas!) : unit
  (begin
    (lexer.spanned-token-buffer-release!)
    (reader.sexpr-node-pool-release!)))

(defenum ResultCompilerLoad
  (Ok ast.AstDeclList sym_i64_env.SymI64Env)
  (Err (Box cdiag.CompilerDiagnostic)))

(defenum ResultCompilerLoadWithPaths
  (Ok
    ast.AstDeclList
    ast.AstDeclPathList
    ast.AstDeclModuleList
    sym_i64_env.SymI64Env)
  (Err (Box cdiag.CompilerDiagnostic)))

(defenum CompilerLoadMaybePath
  (CompilerLoadNoPath)
  (CompilerLoadSomePath String))

(defenum CompilerLoadMaybeString
  (CompilerLoadNoString)
  (CompilerLoadSomeString String))

(defenum ResultPkgResolve
  (Ok String)
  (Err String))

(defstruct CompilerLoadResolvedImport
  (resolved String)
  (kind ast.AstImportKind)
  ;; Canonical dotted identity of the file-backed module, without a selected
  ;; item or wildcard suffix.
  (module-name String)
  (expected-module ast.AstMaybeModuleName)
  (alias ast.AstMaybeImportAlias))

(defenum ResultCompilerLoadResolvedImport
  (Ok CompilerLoadResolvedImport)
  (Err String))

(defstruct CompilerLoadPackageEntry
  (entry-path String)
  (manifest-dir String)
  (owner String)
  (version String))

(defenum ResultCompilerLoadPackageEntry
  (Ok CompilerLoadPackageEntry)
  (Err String))

(defenum CompilerLoadPackageSpmdInterface
  (Unavailable)
  (Available tlci.TlciSpmdCallables))

(defenum ResultCompilerLoadPackageSpmdInterface
  (Ok CompilerLoadPackageSpmdInterface)
  (Err String))

;; Package dependency artifacts use the build profile selected by the package
;; driver. Other compiler entry points retain the release default and can still
;; typecheck source dependencies when no artifact has been built yet.
(define compiler-load-package-artifact-profile : String
  "release")

(define (compiler-load-set-package-artifact-profile! [profile : String]) : unit
  (set! compiler-load-package-artifact-profile profile))

(defenum CompilerLoadMaybeModuleId
  (CompilerLoadNoModuleId)
  (CompilerLoadSomeModuleId String i64))

(defenum CompilerLoadMaybeDecl
  (CompilerLoadNoDecl)
  (CompilerLoadSomeDecl ast.AstDecl))

(defenum ResultCompilerLoadInclude
  (Ok ast.AstDecl)
  (Err (Box cdiag.CompilerDiagnostic)))

(defenum ResultCompilerLoadModuleId
  (Ok String i64)
  (Err (Box cdiag.CompilerDiagnostic)))

(defstruct CompilerLoadParseIdentity
  (source-path-id i64)
  (module-fallback-id i64)
  (decl-owner-id i64))

(defenum ResultCompilerLoadAliasCheck
  (Ok)
  (Err (Box cdiag.CompilerDiagnostic)))

(defstruct CompilerLoadImportAliasCollision
  (alias String)
  (first-import String)
  (second-import String)
  (span ast.AstSourceSpan))

(defenum CompilerLoadMaybeImportAliasCollision
  (No)
  (Some CompilerLoadImportAliasCollision))

(defstruct CompilerLoadUnqualifiedImportState
  (source-ids load_i64_i64_map.Map)
  (source-modules load_i64_i64_map.Map))

(defstruct CompilerLoadUnqualifiedImportCollision
  (name String)
  (first-module String)
  (second-module String)
  (path String)
  (span ast.AstSourceSpan))

(defenum CompilerLoadUnqualifiedImportStep
  (Ok)
  (Collision CompilerLoadUnqualifiedImportCollision))

(defenum CompilerLoadSurfaceMaybeString
  (CompilerLoadSurfaceNoString)
  (CompilerLoadSurfaceSomeString String))

(defenum CompilerLoadSurfaceImportKind
  (CompilerLoadSurfaceImportModule)
  (CompilerLoadSurfaceImportMacro)
  (CompilerLoadSurfaceImportMacroDecls))

(defstruct CompilerLoadSurfaceImport
  (kind CompilerLoadSurfaceImportKind)
  ;; The lexical module that owns this import. Surface summaries can contain
  ;; nested module bodies, so the source path alone is not enough to recover
  ;; the definition environment of a retained macro body.
  (module i64)
  (source-path String)
  (import-path String)
  (module-name CompilerLoadSurfaceMaybeString)
  (alias CompilerLoadSurfaceMaybeString)
  (default-alias CompilerLoadSurfaceMaybeString)
  (span ast.AstSourceSpan))

(defstruct CompilerLoadSurfaceImportList
  ;; Surface builders count first and retain a right-sized array in source
  ;; order. `len` stays explicit so consumers never derive logical shape from
  ;; a boxed tail.
  (slots (__tl_dyn-array CompilerLoadSurfaceImport))
  (len i64))

(defenum CompilerLoadSurfaceMacroResultKind
  (CompilerLoadSurfaceMacroExpr)
  (CompilerLoadSurfaceMacroModule)
  (CompilerLoadSurfaceMacroDecls)
  (CompilerLoadSurfaceMacroOther))

;; A summary determines which structurally-observed uses make a lazy alias
;; materialize. Ordinary module surfaces need either an alias-qualified use or
;; a visible declaration name; a declaration-macro-only surface needs an
;; alias-qualified use, while all observable surfaces stay eager.
(defenum CompilerLoadLazyImportPolicy
  (CompilerLoadLazyImportEager)
  (CompilerLoadLazyImportQualified)
  (CompilerLoadLazyImportDirect))

;; Exact structural demand is reusable by generated-module materializers. The
;; set maps interned member names to a sentinel value and is deduplicated while
;; the importer AST is walked.
(defenum CompilerLoadStructuralMemberDemand
  (CompilerLoadStructuralNoDemand)
  (CompilerLoadStructuralExactMembers sym_i64_env.SymI64Env)
  (CompilerLoadStructuralFullDemand))

;; This remains the loader's compact observation. In addition to its existing
;; policy bits, it carries the exact first member of each qualified use. Direct
;; or unresolved observations convert to conservative full structural demand.
(defstruct CompilerLoadLazyAliasDemand
  (qualified bool)
  (direct bool)
  (unknown bool)
  (members sym_i64_env.SymI64Env))

(defenum CompilerLoadSurfaceDeclKind
  (CompilerLoadSurfaceValue)
  (CompilerLoadSurfaceFunction)
  (CompilerLoadSurfaceExtern)
  (CompilerLoadSurfaceStruct)
  (CompilerLoadSurfaceEnum)
  (CompilerLoadSurfaceMacro)
  (CompilerLoadSurfaceDispatch)
  (CompilerLoadSurfaceTest)
  (CompilerLoadSurfaceIncludeStr)
  (CompilerLoadSurfaceIncludeStrComptime)
  (CompilerLoadSurfaceIncludeBin))

(defenum CompilerLoadSurfaceSignature
  (CompilerLoadSurfaceNoSignature)
  (CompilerLoadSurfaceValueSignature ast.AstMaybeType)
  (CompilerLoadSurfaceFunctionSignature ast.AstParamList ast.AstType)
  (CompilerLoadSurfaceExternSignature
    ast.AstExternKind
    ast.AstExternMetadata
    ast.AstType)
  (CompilerLoadSurfaceStructSignature
    ast.AstLifetimeList
    ast.AstStructRepr
    ast.AstStructCleanup
    ast.AstFieldDefList)
  (CompilerLoadSurfaceEnumSignature
    ast.AstLifetimeList
    ast.AstEnumCleanup
    ast.AstVariantDefList)
  (CompilerLoadSurfaceMacroSignature ast.AstMacroParamList ast.AstType i64)
  (CompilerLoadSurfaceDispatchSignature ast.AstDispatchVariantList))

(defstruct CompilerLoadSurfaceDecl
  (kind CompilerLoadSurfaceDeclKind)
  (name i64)
  (module i64)
  (signature CompilerLoadSurfaceSignature)
  (macro-result CompilerLoadSurfaceMacroResultKind)
  (has-cleanup bool)
  (has-export bool)
  (has-generated-meta bool)
  (was-unsafe bool)
  (span ast.AstSourceSpan))

(defstruct CompilerLoadSurfaceDeclList
  ;; Declarations are stored in source order, including declarations flattened
  ;; from nested module bodies.
  (slots (__tl_dyn-array CompilerLoadSurfaceDecl))
  (len i64))

(defstruct CompilerLoadSurfaceBuild
  (import-slots (__tl_dyn-array CompilerLoadSurfaceImport))
  (import-len i64)
  (decl-slots (__tl_dyn-array CompilerLoadSurfaceDecl))
  (decl-len i64)
  (has-tests bool)
  (has-export-metadata bool)
  (has-generated-decls bool)
  (has-decl-emitting-macro bool))

(defstruct CompilerLoadSurfaceCounts
  (imports i64)
  (decls i64))

(defstruct CompilerLoadSurfaceSummary
  ;; `module-id` is the load/dedup identity; aliases target the separate
  ;; `declaration-module-id` when a source declares an explicit module.
  (module-id i64)
  (declaration-module-id i64)
  (explicit-module bool)
  ;; True when this source was established through a module-qualified identity.
  (qualified-load bool)
  (source-path-id i64)
  (source-path String)
  (root-id String)
  (imports CompilerLoadSurfaceImportList)
  (decls CompilerLoadSurfaceDeclList)
  (has-tests bool)
  (has-export-metadata bool)
  (has-generated-decls bool)
  (has-decl-emitting-macro bool)
  (lazy-policy CompilerLoadLazyImportPolicy))

(defstruct CompilerLoadSurfaceSummaryList
  ;; Physical order is oldest-to-newest so recording is amortized O(1).
  ;; Accessors expose the previous logical newest-to-oldest order.
  (slots (__tl_dyn-array CompilerLoadSurfaceSummary))
  (len i64))

(define (compiler-load-surface-import-list-empty) : CompilerLoadSurfaceImportList
  (CompilerLoadSurfaceImportList
    (array.make-array CompilerLoadSurfaceImport 0)
    0))

(define (compiler-load-surface-import-list-count
  [imports : (& imports CompilerLoadSurfaceImportList)]) : i64
  imports.len)

(define (compiler-load-surface-import-list-at
  [imports : (& imports CompilerLoadSurfaceImportList)]
  [index : i64]) : CompilerLoadSurfaceImport
  (clone (array-ref imports.slots index)))

(define (compiler-load-surface-decl-list-empty) : CompilerLoadSurfaceDeclList
  (CompilerLoadSurfaceDeclList (array.make-array CompilerLoadSurfaceDecl 0) 0))

(define (compiler-load-surface-decl-list-count
  [decls : (& decls CompilerLoadSurfaceDeclList)]) : i64
  decls.len)

(define (compiler-load-surface-decl-list-at
  [decls : (& decls CompilerLoadSurfaceDeclList)]
  [index : i64]) : CompilerLoadSurfaceDecl
  (clone (array-ref decls.slots index)))

(define (compiler-load-surface-summary-list-empty) : CompilerLoadSurfaceSummaryList
  (CompilerLoadSurfaceSummaryList
    (array.make-array CompilerLoadSurfaceSummary 0)
    0))

(define (compiler-load-surface-summary-list-count
  [summaries : CompilerLoadSurfaceSummaryList]) : i64
  summaries.len)

(define (compiler-load-surface-summary-list-at
  [summaries : CompilerLoadSurfaceSummaryList]
  [index : i64]) : CompilerLoadSurfaceSummary
  (compiler-load-global-array-element-shared-view
    summaries.slots
    (- (- summaries.len index) 1)))

(defenum ResultCompilerLoadSurfaceSummary
  (Ok CompilerLoadSurfaceSummary)
  (Err (Box cdiag.CompilerDiagnostic)))

(defenum CompilerLoadMaybeSurfaceSummary
  (CompilerLoadNoSurfaceSummary)
  (CompilerLoadSomeSurfaceSummary CompilerLoadSurfaceSummary))

(defenum CompilerLoadPreludeCacheLookup
  (CompilerLoadPreludeCacheMiss)
  (CompilerLoadPreludeCacheHit
    ast.AstDeclList
    ast.AstDeclPathList
    ast.AstDeclModuleList
    sym_i64_env.SymI64Env))

(defstruct CompilerLoadInternIdSeq
  (slots (__tl_dyn-array i64))
  (len i64))

(defstruct CompilerLoadPreludeCacheKey
  (root-ids CompilerLoadInternIdSeq)
  (cfgs sym_i64_env.SymI64Env))

(defenum CompilerLoadPreludeCacheSlot
  (CompilerLoadPreludeCacheEmpty)
  (CompilerLoadPreludeCacheFull
    CompilerLoadPreludeCacheKey
    ast.AstDeclList
    ast.AstDeclPathList
    ast.AstDeclModuleList
    sym_i64_env.SymI64Env))

(defenum CompilerLoadProgramCacheLookup
  (CompilerLoadProgramCacheMiss)
  (CompilerLoadProgramCacheHit ast.AstProgram))

(defenum CompilerLoadProgramSourceKind
  (CompilerLoadProgramFile)
  (CompilerLoadProgramEmbedded))

(defstruct CompilerLoadProgramCacheKey
  (kind CompilerLoadProgramSourceKind)
  (path-id i64)
  (cfgs sym_i64_env.SymI64Env))

(defenum CompilerLoadProgramCacheSlot
  (CompilerLoadProgramCacheEmpty)
  (CompilerLoadProgramCacheFull CompilerLoadProgramCacheKey ast.AstProgram))

(defenum CompilerLoadProgramAdmissionSlot
  (CompilerLoadProgramAdmissionEmpty)
  (CompilerLoadProgramAdmissionFull CompilerLoadProgramCacheKey))

(define compiler-load-program-cache-capacity : i64
  256)
(define compiler-load-local-program-cache-node-limit : i64
  2048)
(define compiler-load-runtime-prelude-cache-capacity : i64
  16)
(define compiler-load-dotted-path-cache-capacity : i64
  256)

(defstruct CompilerLoadLazyQualifiedObserverFrame
  (active bool)
  (exhaustive bool)
  (root-id i64)
  (members sym_i64_env.SymI64Env)
  (secondary-root-id i64)
  (secondary-members sym_i64_env.SymI64Env)
  (secondary-qualified bool)
  (secondary-direct bool))

;; Strict-LIFO observer snapshots. The contiguous `slots[0 .. len)` prefix is
;; live and ordered oldest-to-newest; the newest frame is always `len - 1`.
;; Reset replaces this value instead of retaining capacity because traversal
;; slots may belong to the just-reclaimed entry arena.
(defstruct CompilerLoadLazyQualifiedObserverStack
  (slots (__tl_dyn-array CompilerLoadLazyQualifiedObserverFrame))
  (len i64))

(defstruct CompilerLoadLazyQualifiedObserverState
  ;; flags: active, exhaustive, secondary-qualified, secondary-direct.
  (flags (__tl_dyn-array bool))
  ;; root-ids/member-sets: primary, secondary.
  (root-ids (__tl_dyn-array i64))
  (member-sets (__tl_dyn-array sym_i64_env.SymI64Env))
  (stack (__tl_dyn-array CompilerLoadLazyQualifiedObserverStack)))

;; A dependency catalog is admitted once for the load job and then selected by
;; the defining declaration's physical source provenance. The stable key keeps
;; reuse conservative across package builds, source edits, artifact rewrites,
;; hosts, callback ABIs, and producer compilers.
(defstruct CompilerLoadDependencyCatalogKey
  (canonical-root String)
  (package-name String)
  (package-version String)
  (artifact-path String)
  (source-digest i64)
  (image-content-hash i64)
  (host-platform i64)
  (callback-abi-version i64)
  (compiler-identity String))

(defenum CompilerLoadDependencyCatalogFailure
  (Missing String)
  (StaleSource i64 i64)
  (PackageMismatch String String String String)
  (WrongPlatform i64 i64)
  (Unsupported String)
  (Malformed String)
  (MappingFailure String))

(defenum CompilerLoadDependencyCatalogImage
  (None)
  (Some tlci.TlciImage))

(defenum CompilerLoadDependencyCatalogStatus
  (Unavailable CompilerLoadDependencyCatalogFailure)
  (TrustedMetadataOnly)
  (TrustedCode tlci_loader_support.TlciLoadedImage))

(defstruct CompilerLoadDependencyCatalogEntry
  (key CompilerLoadDependencyCatalogKey)
  (image CompilerLoadDependencyCatalogImage)
  ;; Metadata parser strings are reader-session views. Admission deep-copies
  ;; the SPMD interface into the registry owner before that session retires.
  (spmd-callables tlci.TlciSpmdCallables)
  (status CompilerLoadDependencyCatalogStatus))

(defstruct CompilerLoadDependencyCatalogList
  (slots (__tl_dyn-array CompilerLoadDependencyCatalogEntry))
  (len i64))

(defstruct CompilerLoadDependencyCatalogRegistry
  ;; The registry owns parsed image/key storage. Native mappings must be
  ;; released before this arena is destroyed.
  (owner-arena (__tl_dyn-array i64))
  (entries (__tl_dyn-array CompilerLoadDependencyCatalogList))
  (generation (__tl_dyn-array i64)))

;; Hydrated frontend fragments are a derived view of the admitted catalog, not
;; a second image registry. They retain catalog slot ordering and are rebuilt
;; whenever the session interner generation or target cfg changes. Each view
;; owns private AST storage so decoding cannot alias the parsed image arena.
(defenum CompilerLoadDependencySurfaceFragment
  (Unavailable)
  (Ready surface_hydrate.CompilerSurfaceHydration tlci.TlciSpmdCallables))

(defstruct CompilerLoadDependencySurfaceList
  (slots (__tl_dyn-array CompilerLoadDependencySurfaceFragment))
  (imported (__tl_dyn-array bool))
  (len i64))

(defenum CompilerLoadDependencySurfaceBaseFacts
  (None)
  (Some surface_facts.SurfaceTypecheckFacts))

(defstruct CompilerLoadDependencySurfaceState
  (intern-generation (__tl_dyn-array i64))
  (configuration (__tl_dyn-array String))
  (prepared (__tl_dyn-array bool))
  (enabled (__tl_dyn-array bool))
  (fragments (__tl_dyn-array CompilerLoadDependencySurfaceList))
  (base-facts (__tl_dyn-array CompilerLoadDependencySurfaceBaseFacts))
  (facts-builder (__tl_dyn-array surface_facts.SurfaceTypecheckFactsBuilder))
  (surface-decl-count (__tl_dyn-array i64))
  (surface-provenance-count (__tl_dyn-array i64))
  (hit-count (__tl_dyn-array i64))
  (fallback-count (__tl_dyn-array i64))
  (macro-skip-count (__tl_dyn-array i64))
  (typecheck-skip-count (__tl_dyn-array i64)))

;; Small lifetime-bound capability used by typechecking after dependency
;; discovery is complete. The address points at the registry's stable one-slot
;; `entries` and `generation` cells; it avoids embedding the much wider
;; load-session value in the hot macro-walk record while retaining the session
;; ownership boundary.
(defstruct CompilerLoadDependencyCatalogHandle
  (entries-address i64)
  (generation-address i64))

;; A resolved entry is meaningful only inside the exact registry generation
;; and stable package image that produced it. Keep that complete capability
;; together until dispatch; the registry-owned APIs below revalidate every
;; component before reading the mapping.
(defstruct CompilerLoadDependencyCatalogCapability
  (handle CompilerLoadDependencyCatalogHandle)
  (slot i64)
  (key CompilerLoadDependencyCatalogKey)
  (registry-generation i64)
  ;; Diagnostic spellings use the compiler job's intern owner rather than the
  ;; catalog arena, so stale/released capabilities can fail without reading a
  ;; key whose mapping owner has already been retired.
  (package-name-id i64)
  (package-version-id i64)
  (artifact-path-id i64)
  (resolved tlci_loader_support.TlciResolvedMacroEntry))

(defenum CompilerLoadDependencyCatalogLookup
  (NoCatalog)
  (MetadataOnly)
  (Resolved CompilerLoadDependencyCatalogCapability)
  (Shell CompilerLoadDependencyCatalogCapability)
  (Missing)
  (Unavailable CompilerLoadDependencyCatalogFailure))

(defenum CompilerLoadDependencyCatalogAdmittedImage
  (NoCatalog)
  (Unavailable CompilerLoadDependencyCatalogFailure)
  (TrustedMetadataOnly tlci.TlciImage)
  (TrustedCode tlci.TlciImage tlci_loader_support.TlciLoadedImage))

;; Stable verification summary for a job-owned dependency catalog. Besides
;; keeping package gates independent of registry storage, the executable
;; section totals make the metadata-only no-map boundary non-vacuous: every
;; admitted metadata image must contribute zero code/fixup/entry/import bytes.
(defstruct CompilerLoadDependencyCatalogObservation
  (entries i64)
  (generation i64)
  (unavailable i64)
  (metadata-only i64)
  (trusted-code i64)
  (code-bytes i64)
  (fixup-bytes i64)
  (entry-bytes i64)
  (import-bytes i64)
  (surface-enabled bool)
  (surface-fragments i64)
  (surface-hits i64)
  (surface-fallbacks i64)
  (surface-decls i64)
  (surface-macro-skipped i64)
  (surface-typecheck-skipped i64))

(defenum ResultCompilerLoadDependencyCatalogUnit
  (Ok)
  (Err String))

(define compiler-load-dependency-catalog-empty-slots : (__tl_dyn-array
    CompilerLoadDependencyCatalogEntry)
  (array.make-array CompilerLoadDependencyCatalogEntry 0))

(define (compiler-load-dependency-catalog-empty-list) : CompilerLoadDependencyCatalogList
  (CompilerLoadDependencyCatalogList
    (compiler-load-global-shared-view
      compiler-load-dependency-catalog-empty-slots)
    0))

(define (compiler-load-dependency-catalog-registry-new) : CompilerLoadDependencyCatalogRegistry
  (CompilerLoadDependencyCatalogRegistry
    (__tl_make-array 0)
    (__tl_make-array (compiler-load-dependency-catalog-empty-list))
    (__tl_make-array 0)))

(define (compiler-load-dependency-surface-list-empty) : CompilerLoadDependencySurfaceList
  (CompilerLoadDependencySurfaceList
    (__tl_make-array CompilerLoadDependencySurfaceFragment 0)
    (__tl_make-array bool 0)
    0))

(define (compiler-load-dependency-surface-state-new) : CompilerLoadDependencySurfaceState
  (CompilerLoadDependencySurfaceState
    (__tl_make-array -1)
    (__tl_make-array "")
    (__tl_make-array false)
    (__tl_make-array false)
    (__tl_make-array (compiler-load-dependency-surface-list-empty))
    (__tl_make-array CompilerLoadDependencySurfaceBaseFacts.None)
    (__tl_make-array (surface_facts.surface-typecheck-facts-builder-empty))
    (__tl_make-array 0)
    (__tl_make-array 0)
    (__tl_make-array 0)
    (__tl_make-array 0)
    (__tl_make-array 0)
    (__tl_make-array 0)))

(cfg
  dependency-tlci-verification
  (define (compiler-load-dependency-surface-verify-reject-last?) : bool
    (let
      [name : String "TYPELISP_DEPENDENCY_TLCI_VERIFY_SURFACE_REJECT_LAST"]
      (match (env.get (& name))
        [(env.EnvSomeString value) (string.eq value "1")]
        [(env.EnvNoString) false]))))

;; Loader cache and traversal data is owned by an explicit session state. The
;; no-argument compatibility helpers below are serial/test-only adapters over
;; the active state pointer. State-owned driver reset paths use the explicit
;; APIs so resetting one job cannot mutate another job's storage.
(defstruct CompilerLoadSessionState
  (cache-enabled (__tl_dyn-array bool))
  (program-cache-enabled (__tl_dyn-array bool))
  (ast-floor (__tl_dyn-array i64))
  (ty-floor (__tl_dyn-array i64))
  (intern-floor (__tl_dyn-array i64))
  (program-cache (__tl_dyn-array CompilerLoadProgramCacheSlot))
  (program-admission (__tl_dyn-array CompilerLoadProgramAdmissionSlot))
  (program-cache-ready (__tl_dyn-array bool))
  (program-admission-ready (__tl_dyn-array bool))
  (program-cache-hit-count (__tl_dyn-array i64))
  (program-cache-miss-count (__tl_dyn-array i64))
  (program-cache-store-count (__tl_dyn-array i64))
  (runtime-prelude-cache (__tl_dyn-array CompilerLoadPreludeCacheSlot))
  (runtime-prelude-cache-ready (__tl_dyn-array bool))
  (dotted-path-cache-ready (__tl_dyn-array bool))
  (dotted-path-cache-keys (__tl_dyn-array i64))
  (dotted-path-cache-values (__tl_dyn-array String))
  (dotted-path-cache-generation (__tl_dyn-array i64))
  (surface-summaries (__tl_dyn-array CompilerLoadSurfaceSummaryList))
  (surface-summary-load-depth (__tl_dyn-array i64))
  (lazy-import-skip-record-count (__tl_dyn-array i64))
  (lazy-qualified-observer CompilerLoadLazyQualifiedObserverState)
  (dependency-catalog CompilerLoadDependencyCatalogRegistry)
  (dependency-surfaces CompilerLoadDependencySurfaceState)
  ;; Verification policy is snapshotted per package build before admission.
  ;; A process environment lookup must never become mutable route state shared
  ;; by interleaved compiler jobs.
  (dependency-tlci-force-source (__tl_dyn-array bool))
  ;; Intern table this session's floor bookkeeping is bound to once
  ;; `compiler-load-session-state-use-with-intern-state!` installs it; the
  ;; ready flag keeps legacy sessions on the compatibility-global floor path.
  (intern-state (__tl_dyn-array ci.InternCompatState))
  (intern-state-ready (__tl_dyn-array bool))
  ;; Standalone tools own the compatibility default session and may retire all
  ;; of its process-global state before compiling. Driver-owned sessions must
  ;; instead keep every id-keyed cache valid until the driver retires them.
  (standalone-reset-safe (__tl_dyn-array bool))
  ;; Stable arena address of the canonical shallow state record. Every field
  ;; is itself an arena-backed handle, so reading this record preserves the
  ;; session identity without a reference-typed temporary during bootstrap.
  (shared-address u64))

;; Per-source traversal data stays explicit without widening the hot recursive
;; declaration-loader call for each independently owned field.
(defstruct CompilerLoadTraversalContext
  (load-state CompilerLoadSessionState)
  (importer-path-id i64)
  (importer-decl-owner-id i64))

(define (compiler-load-session-state-bool-cell [value : bool]) : (__tl_dyn-array
    bool)
  (__tl_make-array value))

(define (compiler-load-session-state-flags-new) : (__tl_dyn-array bool)
  ;; Slot 0 is cache-enabled; slot 1 records embedded-stdlib source use; slot 2
  ;; enables lazy imports. Keep the flags in one allocation so the published
  ;; seed backend does not cross its per-function aggregate-allocation label
  ;; limit here.
  (let
    [flags : (__tl_dyn-array bool) (array.make-array bool 3)]
    (begin
      (set! (array-ref flags 2) true)
      flags)))

(define (compiler-load-session-state-i64-cell [value : i64]) : (__tl_dyn-array
    i64)
  (__tl_make-array value))

(define (compiler-load-lazy-qualified-observer-stack-empty) : CompilerLoadLazyQualifiedObserverStack
  (CompilerLoadLazyQualifiedObserverStack
    (array.make-array CompilerLoadLazyQualifiedObserverFrame 0)
    0))

(define (compiler-load-lazy-qualified-observer-stack-count
  [stack : (& stack CompilerLoadLazyQualifiedObserverStack)]) : i64
  stack.len)

(define (compiler-load-lazy-qualified-observer-stack-push
  [stack : CompilerLoadLazyQualifiedObserverStack]
  [frame : CompilerLoadLazyQualifiedObserverFrame]) : CompilerLoadLazyQualifiedObserverStack
  (let
    [len : i64 stack.len]
    [slots : (__tl_dyn-array CompilerLoadLazyQualifiedObserverFrame)
      stack.slots]
    (begin
      (if (< len (array-length slots))
        unit
        (let
          [capacity : i64
            (if (= (array-length slots) 0)
              1
              (* (array-length slots) 2))]
          [bigger : (__tl_dyn-array CompilerLoadLazyQualifiedObserverFrame)
            (array.make-array CompilerLoadLazyQualifiedObserverFrame capacity)]
          [index : i64 0]
          (begin
            (while (< index len)
              (begin
                (set! (array-ref bigger index) (array-ref slots index))
                (set! index (+ index 1))))
            (set! slots bigger))))
      (set! (array-ref slots len) frame)
      (CompilerLoadLazyQualifiedObserverStack slots (+ len 1)))))

(define (compiler-load-lazy-qualified-observer-state-new) : CompilerLoadLazyQualifiedObserverState
  (let
    [flags : (__tl_dyn-array bool) (array.make-array bool 4)]
    [root-ids : (__tl_dyn-array i64) (array.make-array i64 2)]
    [member-sets : (__tl_dyn-array sym_i64_env.SymI64Env)
      (array.make-array sym_i64_env.SymI64Env 2)]
    [stack : (__tl_dyn-array CompilerLoadLazyQualifiedObserverStack)
      (__tl_make-array (compiler-load-lazy-qualified-observer-stack-empty))]
    (begin
      (set! (array-ref member-sets 0) (sym_i64_env.sym-i64-empty))
      (set! (array-ref member-sets 1) (sym_i64_env.sym-i64-empty))
      (CompilerLoadLazyQualifiedObserverState flags root-ids member-sets stack))))

(define (compiler-load-session-state-bool-cell-get
  [cell : (& cell (__tl_dyn-array bool))]) : bool
  (array-ref cell 0))

(define (compiler-load-session-state-bool-cell-set!
  [cell : (__tl_dyn-array bool)]
  [value : bool]) : unit
  (set! (array-ref cell 0) value))

(define (compiler-load-session-state-new-with-standalone-reset-safety
  [standalone-reset-safe : bool]) : CompilerLoadSessionState
  (let
    [surface-summaries : (__tl_dyn-array CompilerLoadSurfaceSummaryList)
      (__tl_make-array (compiler-load-surface-summary-list-empty))]
    [surface-summary-load-depth : (__tl_dyn-array i64)
      (compiler-load-session-state-i64-cell 0)]
    [lazy-import-skip-record-count : (__tl_dyn-array i64)
      (compiler-load-session-state-i64-cell 0)]
    [lazy-qualified-observer : CompilerLoadLazyQualifiedObserverState
      (compiler-load-lazy-qualified-observer-state-new)]
    [initial : CompilerLoadSessionState
      (CompilerLoadSessionState
        (compiler-load-session-state-flags-new)
        (compiler-load-session-state-bool-cell true)
        (compiler-load-session-state-i64-cell 0)
        (compiler-load-session-state-i64-cell 0)
        (compiler-load-session-state-i64-cell 0)
        (__tl_make-array CompilerLoadProgramCacheSlot 256)
        (__tl_make-array CompilerLoadProgramAdmissionSlot 256)
        (compiler-load-session-state-bool-cell false)
        (compiler-load-session-state-bool-cell false)
        (compiler-load-session-state-i64-cell 0)
        (compiler-load-session-state-i64-cell 0)
        (compiler-load-session-state-i64-cell 0)
        (__tl_make-array CompilerLoadPreludeCacheSlot 16)
        (compiler-load-session-state-bool-cell false)
        (__tl_make-array bool compiler-load-dotted-path-cache-capacity)
        (__tl_make-array i64 compiler-load-dotted-path-cache-capacity)
        (__tl_make-array String compiler-load-dotted-path-cache-capacity)
        (compiler-load-session-state-i64-cell 0)
        surface-summaries
        surface-summary-load-depth
        lazy-import-skip-record-count
        lazy-qualified-observer
        (compiler-load-dependency-catalog-registry-new)
        (compiler-load-dependency-surface-state-new)
        (compiler-load-session-state-bool-cell false)
        (array.make-array ci.InternCompatState 1)
        (compiler-load-session-state-bool-cell false)
        (compiler-load-session-state-bool-cell standalone-reset-safe)
        0)]
    [cell : (__tl_dyn-array CompilerLoadSessionState) (__tl_make-array initial)]
    [address : u64
      (unsafe
        (ptr->int (__tl_array-data cell)))]
    [canonical : CompilerLoadSessionState
      (compiler-load-global-array-element-shared-view cell 0)]
    (begin
      (set! canonical.shared-address address)
      (set! (array-ref cell 0) canonical)
      (compiler-load-global-array-element-shared-view cell 0))))

(define (compiler-load-session-state-new) : CompilerLoadSessionState
  (compiler-load-session-state-new-with-standalone-reset-safety false))

(define (compiler-load-standalone-session-state-new) : CompilerLoadSessionState
  (compiler-load-session-state-new-with-standalone-reset-safety true))

(define (compiler-load-session-state-dependency-catalog
  [state : CompilerLoadSessionState]) : CompilerLoadDependencyCatalogRegistry
  state.dependency-catalog)

(define (compiler-load-session-state-set-dependency-tlci-force-source!
  [state : CompilerLoadSessionState]
  [force-source : bool]) : unit
  (compiler-load-session-state-bool-cell-set!
    state.dependency-tlci-force-source
    force-source))

(define (compiler-load-session-state-dependency-tlci-force-source?
  [state : (& state CompilerLoadSessionState)]) : bool
  (compiler-load-session-state-bool-cell-get state.dependency-tlci-force-source))

(define (compiler-load-session-state-dependency-catalog-handle
  [state : CompilerLoadSessionState]) : CompilerLoadDependencyCatalogHandle
  (CompilerLoadDependencyCatalogHandle
    (cast
      (unsafe
        (ptr->int
          (ptr-cast
            (__tl_array-data state.dependency-catalog.entries)
            : (Ptr CompilerLoadDependencyCatalogList))))
      : i64)
    (cast
      (unsafe
        (ptr->int
          (ptr-cast
            (__tl_array-data state.dependency-catalog.generation)
            : (Ptr i64))))
      : i64)))

(define (compiler-load-dependency-catalog-handle-items
  [handle : CompilerLoadDependencyCatalogHandle]) : CompilerLoadDependencyCatalogList
  (unsafe
    (ptr-read
      (int->ptr
        (cast handle.entries-address : u64)
        : (Ptr CompilerLoadDependencyCatalogList)))))

(define (compiler-load-dependency-catalog-handle-generation
  [handle : CompilerLoadDependencyCatalogHandle]) : i64
  (unsafe
    (ptr-read (int->ptr (cast handle.generation-address : u64) : (Ptr i64)))))

(define (compiler-load-dependency-catalog-owner-arena
  [state : CompilerLoadSessionState]) : i64
  (array-ref state.dependency-catalog.owner-arena 0))

(define (compiler-load-dependency-catalog-owner-arena-ensure!
  [state : CompilerLoadSessionState]) : i64
  (let
    [owner : i64
      (compiler-load-dependency-catalog-owner-arena
        (owned_view.compiler-owned-shared-view state))]
    (if (> owner 0)
      owner
      (let
        [next : i64 (arena.tl_arena_make_small)]
        (begin
          (set! (array-ref state.dependency-catalog.owner-arena 0) next)
          next)))))

(define (compiler-load-dependency-catalog-key-eq?
  [left : CompilerLoadDependencyCatalogKey]
  [right : CompilerLoadDependencyCatalogKey]) : bool
  (and
    (string.eq left.canonical-root right.canonical-root)
    (string.eq left.package-name right.package-name)
    (string.eq left.package-version right.package-version)
    (string.eq left.artifact-path right.artifact-path)
    (= left.source-digest right.source-digest)
    (= left.image-content-hash right.image-content-hash)
    (= left.host-platform right.host-platform)
    (= left.callback-abi-version right.callback-abi-version)
    (string.eq left.compiler-identity right.compiler-identity)))

(define (compiler-load-dependency-catalog-entry-release-mapping!
  [entry : CompilerLoadDependencyCatalogEntry]) : ResultCompilerLoadDependencyCatalogUnit
  (match entry.status
    [(CompilerLoadDependencyCatalogStatus.TrustedCode loaded)
      (match (tlci_loader_support.tlci-loader-release loaded)
        [(tlci_loader_support.ResultTlciLoaderUnit.Ok)
          ResultCompilerLoadDependencyCatalogUnit.Ok]
        [(tlci_loader_support.ResultTlciLoaderUnit.Err message)
          (ResultCompilerLoadDependencyCatalogUnit.Err message)])]
    [_ ResultCompilerLoadDependencyCatalogUnit.Ok]))

(define (compiler-load-dependency-catalog-find-root-slot
  [items : CompilerLoadDependencyCatalogList]
  [canonical-root : String]) : i64
  (let
    [index : i64 0]
    (begin
      (while (< index items.len)
        (let
          [entry : CompilerLoadDependencyCatalogEntry
            (owned_view.compiler-owned-array-element-shared-view
              items.slots
              index)]
          (if (string.eq
            (owned_view.compiler-owned-shared-view entry.key.canonical-root)
            (owned_view.compiler-owned-shared-view canonical-root))
            (return index)
            (set! index (+ index 1)))))
      -1)))

(define (compiler-load-dependency-catalog-find-key-slot
  [state : CompilerLoadSessionState]
  [key : CompilerLoadDependencyCatalogKey]) : i64
  (let
    [items : CompilerLoadDependencyCatalogList
      (owned_view.compiler-owned-array-element-shared-view
        state.dependency-catalog.entries
        0)]
    [slot : i64
      (compiler-load-dependency-catalog-find-root-slot
        (owned_view.compiler-owned-shared-view items)
        (owned_view.compiler-owned-shared-view key.canonical-root))]
    (if (and
      (>= slot 0)
      (let
        [entry : CompilerLoadDependencyCatalogEntry
          (owned_view.compiler-owned-array-element-shared-view items.slots slot)]
        (compiler-load-dependency-catalog-key-eq?
          (owned_view.compiler-owned-shared-view entry.key)
          key)))
      slot
      -1)))

(define (compiler-load-dependency-catalog-grow
  [owner : i64]
  [items : CompilerLoadDependencyCatalogList]) : CompilerLoadDependencyCatalogList
  (let
    [old-capacity : i64 (array-length items.slots)]
    [capacity : i64
      (if (< old-capacity 4)
        4
        (* old-capacity 2))]
    [slots : (__tl_dyn-array CompilerLoadDependencyCatalogEntry)
      (in-arena
        (arena.Arena owner)
        (array.make-array CompilerLoadDependencyCatalogEntry capacity))]
    [index : i64 0]
    (begin
      (while (< index items.len)
        (begin
          (set!
            (array-ref slots index)
            (owned_view.compiler-owned-array-element-shared-view
              items.slots
              index))
          (set! index (+ index 1))))
      (CompilerLoadDependencyCatalogList slots items.len))))

;; `entry` and everything reachable from it must be allocated in the owner
;; arena returned by `compiler-load-dependency-catalog-owner-arena-ensure!`.
;; Exact stable-key matches reuse an existing mapping. A changed artifact for
;; the same package root replaces it only after releasing the old mapping.
(define (compiler-load-dependency-catalog-record-owned!
  [state : CompilerLoadSessionState]
  [entry : CompilerLoadDependencyCatalogEntry]) : i64
  (let
    [registry : CompilerLoadDependencyCatalogRegistry
      (owned_view.compiler-owned-shared-view state.dependency-catalog)]
    [items : CompilerLoadDependencyCatalogList
      (owned_view.compiler-owned-array-element-shared-view registry.entries 0)]
    [slot : i64
      (compiler-load-dependency-catalog-find-root-slot
        (owned_view.compiler-owned-shared-view items)
        (owned_view.compiler-owned-shared-view entry.key.canonical-root))]
    (if (>= slot 0)
      (let
        [old : CompilerLoadDependencyCatalogEntry
          (owned_view.compiler-owned-array-element-shared-view items.slots slot)]
        (if (compiler-load-dependency-catalog-key-eq?
          (owned_view.compiler-owned-shared-view old.key)
          (owned_view.compiler-owned-shared-view entry.key))
          slot
          (begin
            (match (compiler-load-dependency-catalog-entry-release-mapping!
              (owned_view.compiler-owned-shared-view old))
              [(ResultCompilerLoadDependencyCatalogUnit.Ok) unit]
              [(ResultCompilerLoadDependencyCatalogUnit.Err _) unit])
            (set! (array-ref items.slots slot) entry)
            (set!
              (array-ref registry.generation 0)
              (+ (array-ref registry.generation 0) 1))
            slot)))
      (let
        [owner : i64
          (compiler-load-dependency-catalog-owner-arena-ensure!
            (owned_view.compiler-owned-shared-view state))]
        [ready : CompilerLoadDependencyCatalogList
          (if (< items.len (array-length items.slots))
            items
            (compiler-load-dependency-catalog-grow owner items))]
        [next-slot : i64 ready.len]
        (begin
          (set! (array-ref ready.slots next-slot) entry)
          (set! ready.len (+ ready.len 1))
          (set! (array-ref registry.entries 0) ready)
          (set!
            (array-ref registry.generation 0)
            (+ (array-ref registry.generation 0) 1))
          next-slot)))))

(define (compiler-load-dependency-catalog-release-from!
  [items : CompilerLoadDependencyCatalogList]
  [index : i64]
  [first-error : String]) : String
  (if (>= index items.len)
    first-error
    (match (compiler-load-dependency-catalog-entry-release-mapping!
      (owned_view.compiler-owned-array-element-shared-view items.slots index))
      [(ResultCompilerLoadDependencyCatalogUnit.Ok)
        (compiler-load-dependency-catalog-release-from!
          (owned_view.compiler-owned-shared-view items)
          (+ index 1)
          (owned_view.compiler-owned-shared-view first-error))]
      [(ResultCompilerLoadDependencyCatalogUnit.Err message)
        (compiler-load-dependency-catalog-release-from!
          (owned_view.compiler-owned-shared-view items)
          (+ index 1)
          (if (= (string.string-length first-error) 0)
            message
            first-error))])))

(define (compiler-load-session-state-dependency-catalog-release!
  [state : CompilerLoadSessionState]) : ResultCompilerLoadDependencyCatalogUnit
  (let
    [registry : CompilerLoadDependencyCatalogRegistry
      (owned_view.compiler-owned-shared-view state.dependency-catalog)]
    [surface-state : CompilerLoadDependencySurfaceState
      (owned_view.compiler-owned-shared-view state.dependency-surfaces)]
    [items : CompilerLoadDependencyCatalogList
      (owned_view.compiler-owned-array-element-shared-view registry.entries 0)]
    [owner : i64 (array-ref registry.owner-arena 0)]
    [error : String (compiler-load-dependency-catalog-release-from! items 0 "")]
    (begin
      (compiler-load-dependency-surface-list-destroy-storage!
        (owned_view.compiler-owned-array-element-shared-view
          surface-state.fragments
          0))
      (if (> owner 0)
        (unsafe
          (arena.tl_arena_destroy owner))
        unit)
      (set! (array-ref registry.owner-arena 0) 0)
      (set!
        (array-ref registry.entries 0)
        (compiler-load-dependency-catalog-empty-list))
      (set!
        (array-ref registry.generation 0)
        (+ (array-ref registry.generation 0) 1))
      (set!
        (array-ref surface-state.fragments 0)
        (compiler-load-dependency-surface-list-empty))
      (set! (array-ref surface-state.prepared 0) false)
      (set! (array-ref surface-state.enabled 0) false)
      (set! (array-ref surface-state.intern-generation 0) -1)
      (set! (array-ref surface-state.configuration 0) "")
      (set!
        (array-ref surface-state.base-facts 0)
        CompilerLoadDependencySurfaceBaseFacts.None)
      (set!
        (array-ref surface-state.facts-builder 0)
        (surface_facts.surface-typecheck-facts-builder-empty))
      (set! (array-ref surface-state.surface-decl-count 0) 0)
      (set! (array-ref surface-state.surface-provenance-count 0) 0)
      (set! (array-ref surface-state.macro-skip-count 0) 0)
      (set! (array-ref surface-state.typecheck-skip-count 0) 0)
      (if (= (string.string-length error) 0)
        ResultCompilerLoadDependencyCatalogUnit.Ok
        (ResultCompilerLoadDependencyCatalogUnit.Err error)))))

(define (compiler-load-canonical-path [path : String]) : String
  (let
    [normalized : String (compiler-load-normalize-path path)]
    (if (fs.path-absolute? (& normalized))
      normalized
      (compiler-load-normalize-path
        (compiler-load-join-root-path (fs.current-dir) normalized)))))

(define (compiler-load-dependency-catalog-slot-for-provenance-id
  [state : CompilerLoadSessionState]
  [provenance-id : i64]) : i64
  (compiler-load-dependency-catalog-handle-slot-for-provenance-id
    (compiler-load-session-state-dependency-catalog-handle state)
    provenance-id))

(define (compiler-load-dependency-catalog-handle-slot-for-provenance-path
  [handle : CompilerLoadDependencyCatalogHandle]
  [provenance-path : String]) : i64
  (let
    [path : String (compiler-load-canonical-path provenance-path)]
    [items : CompilerLoadDependencyCatalogList
      (compiler-load-dependency-catalog-handle-items handle)]
    [index : i64 0]
    [best : i64 -1]
    [best-len : i64 -1]
    (begin
      (while (< index items.len)
        (let
          [entry : CompilerLoadDependencyCatalogEntry
            (owned_view.compiler-owned-array-element-shared-view
              items.slots
              index)]
          [root : String
            (owned_view.compiler-owned-shared-view entry.key.canonical-root)]
          [root-len : i64 (string.string-length root)]
          (begin
            (if (and
              (> root-len best-len)
              (or
                (string.eq
                  (owned_view.compiler-owned-shared-view path)
                  (owned_view.compiler-owned-shared-view root))
                (compiler-load-path-under-root?
                  (owned_view.compiler-owned-shared-view path)
                  (owned_view.compiler-owned-shared-view root))))
              (begin
                (set! best index)
                (set! best-len root-len))
              unit)
            (set! index (+ index 1)))))
      best)))

(define (compiler-load-dependency-catalog-handle-slot-for-provenance-id
  [handle : CompilerLoadDependencyCatalogHandle]
  [provenance-id : i64]) : i64
  (if (< provenance-id 0)
    -1
    (compiler-load-dependency-catalog-handle-slot-for-provenance-path
      handle
      (ci.intern-str provenance-id))))

(define (compiler-load-dependency-catalog-lookup-macro
  [state : CompilerLoadSessionState]
  [slot : i64]
  [identity : String]) : CompilerLoadDependencyCatalogLookup
  (compiler-load-dependency-catalog-handle-lookup-macro
    (compiler-load-session-state-dependency-catalog-handle state)
    slot
    identity))

(define (compiler-load-dependency-catalog-handle-lookup-macro
  [handle : CompilerLoadDependencyCatalogHandle]
  [slot : i64]
  [identity : String]) : CompilerLoadDependencyCatalogLookup
  (let
    [items : CompilerLoadDependencyCatalogList
      (compiler-load-dependency-catalog-handle-items handle)]
    (if (or (< slot 0) (>= slot items.len))
      CompilerLoadDependencyCatalogLookup.NoCatalog
      (let
        [entry : CompilerLoadDependencyCatalogEntry
          (owned_view.compiler-owned-array-element-shared-view items.slots slot)]
        (match entry.status
          [(CompilerLoadDependencyCatalogStatus.Unavailable failure)
            (CompilerLoadDependencyCatalogLookup.Unavailable failure)]
          [(CompilerLoadDependencyCatalogStatus.TrustedMetadataOnly)
            CompilerLoadDependencyCatalogLookup.MetadataOnly]
          [(CompilerLoadDependencyCatalogStatus.TrustedCode loaded)
            (let
              [generation : i64
                (compiler-load-dependency-catalog-handle-generation handle)]
              [package-name-id : i64
                (ci.intern
                  (owned_view.compiler-owned-shared-view entry.key.package-name))]
              [package-version-id : i64
                (ci.intern
                  (owned_view.compiler-owned-shared-view
                    entry.key.package-version))]
              [artifact-path-id : i64
                (ci.intern
                  (owned_view.compiler-owned-shared-view
                    entry.key.artifact-path))]
              (match (tlci_loader_support.tlci-loader-resolve-macro-entry
                (& loaded)
                identity)
                [(tlci_loader_support.TlciMacroEntryLookup.Resolved resolved)
                  (CompilerLoadDependencyCatalogLookup.Resolved
                    (CompilerLoadDependencyCatalogCapability
                      handle
                      slot
                      entry.key
                      generation
                      package-name-id
                      package-version-id
                      artifact-path-id
                      resolved))]
                [(tlci_loader_support.TlciMacroEntryLookup.Shell resolved)
                  (CompilerLoadDependencyCatalogLookup.Shell
                    (CompilerLoadDependencyCatalogCapability
                      handle
                      slot
                      entry.key
                      generation
                      package-name-id
                      package-version-id
                      artifact-path-id
                      resolved))]
                [(tlci_loader_support.TlciMacroEntryLookup.Missing)
                  CompilerLoadDependencyCatalogLookup.Missing]
                [(tlci_loader_support.TlciMacroEntryLookup.Err message)
                  (CompilerLoadDependencyCatalogLookup.Unavailable
                    (CompilerLoadDependencyCatalogFailure.MappingFailure
                      message))]))])))))

(define (compiler-load-dependency-catalog-capability-error
  [capability : CompilerLoadDependencyCatalogCapability]
  [identity : String]
  [message : String]) : String
  (str_cat.str-cat
    "dependency tlci: package "
    (ci.intern-str capability.package-name-id)
    "@"
    (ci.intern-str capability.package-version-id)
    ", image "
    (ci.intern-str capability.artifact-path-id)
    ", macro "
    identity
    ": "
    message))

(define (compiler-load-dependency-catalog-capability-current?
  [capability : CompilerLoadDependencyCatalogCapability]) : bool
  (if (not
    (=
      (compiler-load-dependency-catalog-handle-generation capability.handle)
      capability.registry-generation))
    false
    (let
      [items : CompilerLoadDependencyCatalogList
        (compiler-load-dependency-catalog-handle-items capability.handle)]
      (and
        (>= capability.slot 0)
        (< capability.slot items.len)
        (let
          [entry : CompilerLoadDependencyCatalogEntry
            (owned_view.compiler-owned-array-element-shared-view
              items.slots
              capability.slot)]
          (compiler-load-dependency-catalog-key-eq?
            (owned_view.compiler-owned-shared-view entry.key)
            capability.key))))))

;; Revalidate the complete registry capability immediately before entering
;; mapped code. No loaded-image value crosses this API boundary.
(define (compiler-load-dependency-catalog-capability-dispatch
  [capability : CompilerLoadDependencyCatalogCapability]
  [identity : String]
  [session-cookie : i64]) : tlci_loader_support.ResultTlciMacroDispatch
  (if (not
    (compiler-load-dependency-catalog-capability-current?
      (compiler-load-global-shared-view capability)))
    (tlci_loader_support.ResultTlciMacroDispatch.Err
      (compiler-load-dependency-catalog-capability-error
        (compiler-load-global-shared-view capability)
        (compiler-load-global-shared-view identity)
        "selected catalog capability is stale"))
    (let
      [items : CompilerLoadDependencyCatalogList
        (compiler-load-dependency-catalog-handle-items capability.handle)]
      [entry : CompilerLoadDependencyCatalogEntry
        (owned_view.compiler-owned-array-element-shared-view
          items.slots
          capability.slot)]
      (match entry.status
        [(CompilerLoadDependencyCatalogStatus.TrustedCode loaded)
          (match (tlci_loader_support.tlci-loader-dispatch-resolved-macro
            (& loaded)
            capability.resolved
            session-cookie
            (array.make-array i64 0)
            0)
            [(tlci_loader_support.ResultTlciMacroDispatch.Ok dispatch)
              (tlci_loader_support.ResultTlciMacroDispatch.Ok dispatch)]
            [(tlci_loader_support.ResultTlciMacroDispatch.Err message)
              (tlci_loader_support.ResultTlciMacroDispatch.Err
                (compiler-load-dependency-catalog-capability-error
                  (compiler-load-global-shared-view capability)
                  (compiler-load-global-shared-view identity)
                  message))])]
        [_
          (tlci_loader_support.ResultTlciMacroDispatch.Err
            (compiler-load-dependency-catalog-capability-error
              (compiler-load-global-shared-view capability)
              (compiler-load-global-shared-view identity)
              "selected catalog is no longer executable"))]))))

(define (compiler-load-dependency-catalog-capability-mark-shell!
  [capability : CompilerLoadDependencyCatalogCapability]
  [identity : String]) : tlci_loader_support.ResultTlciLoaderUnit
  (if (not
    (compiler-load-dependency-catalog-capability-current?
      (compiler-load-global-shared-view capability)))
    (tlci_loader_support.ResultTlciLoaderUnit.Err
      (compiler-load-dependency-catalog-capability-error
        (compiler-load-global-shared-view capability)
        (compiler-load-global-shared-view identity)
        "selected catalog capability is stale"))
    (let
      [items : CompilerLoadDependencyCatalogList
        (compiler-load-dependency-catalog-handle-items capability.handle)]
      [entry : CompilerLoadDependencyCatalogEntry
        (owned_view.compiler-owned-array-element-shared-view
          items.slots
          capability.slot)]
      (match entry.status
        [(CompilerLoadDependencyCatalogStatus.TrustedCode loaded)
          (match (tlci_loader_support.tlci-loader-mark-macro-entry-shell!
            (& loaded)
            capability.resolved)
            [(tlci_loader_support.ResultTlciLoaderUnit.Ok)
              tlci_loader_support.ResultTlciLoaderUnit.Ok]
            [(tlci_loader_support.ResultTlciLoaderUnit.Err message)
              (tlci_loader_support.ResultTlciLoaderUnit.Err
                (compiler-load-dependency-catalog-capability-error
                  (compiler-load-global-shared-view capability)
                  (compiler-load-global-shared-view identity)
                  message))])]
        [_
          (tlci_loader_support.ResultTlciLoaderUnit.Err
            (compiler-load-dependency-catalog-capability-error
              (compiler-load-global-shared-view capability)
              (compiler-load-global-shared-view identity)
              "selected catalog is no longer executable"))]))))

(define (compiler-load-dependency-catalog-admitted-image
  [state : CompilerLoadSessionState]
  [slot : i64]) : CompilerLoadDependencyCatalogAdmittedImage
  (let
    [items : CompilerLoadDependencyCatalogList
      (owned_view.compiler-owned-array-element-shared-view
        state.dependency-catalog.entries
        0)]
    (if (or (< slot 0) (>= slot items.len))
      CompilerLoadDependencyCatalogAdmittedImage.NoCatalog
      (let
        [entry : CompilerLoadDependencyCatalogEntry
          (owned_view.compiler-owned-array-element-shared-view items.slots slot)]
        (match entry.status
          [(CompilerLoadDependencyCatalogStatus.Unavailable failure)
            (CompilerLoadDependencyCatalogAdmittedImage.Unavailable failure)]
          [(CompilerLoadDependencyCatalogStatus.TrustedMetadataOnly)
            (match entry.image
              [(CompilerLoadDependencyCatalogImage.Some image)
                (CompilerLoadDependencyCatalogAdmittedImage.TrustedMetadataOnly
                  image)]
              [(CompilerLoadDependencyCatalogImage.None)
                (CompilerLoadDependencyCatalogAdmittedImage.Unavailable
                  (CompilerLoadDependencyCatalogFailure.Malformed
                    "dependency catalog: trusted metadata entry has no image"))])]
          [(CompilerLoadDependencyCatalogStatus.TrustedCode loaded)
            (match entry.image
              [(CompilerLoadDependencyCatalogImage.Some image)
                (CompilerLoadDependencyCatalogAdmittedImage.TrustedCode
                  image
                  loaded)]
              [(CompilerLoadDependencyCatalogImage.None)
                (CompilerLoadDependencyCatalogAdmittedImage.Unavailable
                  (CompilerLoadDependencyCatalogFailure.Malformed
                    "dependency catalog: trusted code entry has no image"))])])))))

(define (compiler-load-dependency-surface-configuration
  [cfgs : sym_i64_env.SymI64Env]) : String
  (let
    [windows-id : i64 (ci.intern "windows")]
    [linux-id : i64 (ci.intern "linux")]
    (cond
      [(cfg_core.compiler-cfg-enabled? cfgs windows-id) "windows-x86_64"]
      [(cfg_core.compiler-cfg-enabled? cfgs linux-id) "linux-x86_64"]
      [else ""])))

(define (compiler-load-dependency-surface-list-destroy-storage!
  [surfaces : CompilerLoadDependencySurfaceList]) : unit
  (let
    [index : i64 0]
    (while (< index surfaces.len)
      (begin
        (match (owned_view.compiler-owned-array-element-shared-view
          surfaces.slots
          index)
          [(CompilerLoadDependencySurfaceFragment.Ready hydration _)
            (let
              [pools : ast.AstNodePoolContext
                (owned_view.compiler-owned-shared-view hydration.ast.pools)]
              [base-arena : i64
                (ast.ast-node-pool-context-base-arena
                  (owned_view.compiler-owned-shared-view pools))]
              (begin
                (ast.ast-node-pool-context-destroy-storage! pools)
                (unsafe
                  (arena.tl_arena_destroy base-arena))))]
          [(CompilerLoadDependencySurfaceFragment.Unavailable) unit])
        (set! index (+ index 1))))))

(define (compiler-load-dependency-surface-reset-use!
  [state : CompilerLoadSessionState]) : unit
  (let
    [surface-state : CompilerLoadDependencySurfaceState
      state.dependency-surfaces]
    [fragments : CompilerLoadDependencySurfaceList
      (owned_view.compiler-owned-array-element-shared-view
        surface-state.fragments
        0)]
    [base-facts : CompilerLoadDependencySurfaceBaseFacts
      (if (and
        (surface_facts.surface-typecheck-facts-active?)
        (not (surface_facts.surface-typecheck-facts-composite-active?)))
        (CompilerLoadDependencySurfaceBaseFacts.Some
          (surface_facts.surface-typecheck-facts-current))
        CompilerLoadDependencySurfaceBaseFacts.None)]
    [base-builder : surface_facts.SurfaceTypecheckFactsBuilder
      (match (owned_view.compiler-owned-shared-view base-facts)
        [(CompilerLoadDependencySurfaceBaseFacts.None)
          (surface_facts.surface-typecheck-facts-builder-empty)]
        [(CompilerLoadDependencySurfaceBaseFacts.Some facts)
          (match (surface_facts.surface-typecheck-facts-builder-append
            (surface_facts.surface-typecheck-facts-builder-empty)
            facts)
            [(surface_facts.ResultSurfaceTypecheckFactsBuilder.Ok next) next]
            [(surface_facts.ResultSurfaceTypecheckFactsBuilder.Err _)
              (surface_facts.surface-typecheck-facts-builder-empty)])])]
    [index : i64 0]
    (begin
      (while (< index fragments.len)
        (begin
          (set! (array-ref fragments.imported index) false)
          (set! index (+ index 1))))
      (set! (array-ref surface-state.base-facts 0) base-facts)
      (set! (array-ref surface-state.facts-builder 0) base-builder)
      (set! (array-ref surface-state.surface-decl-count 0) 0)
      (set! (array-ref surface-state.surface-provenance-count 0) 0)
      (set! (array-ref surface-state.hit-count 0) 0)
      (set! (array-ref surface-state.macro-skip-count 0) 0)
      (set! (array-ref surface-state.typecheck-skip-count 0) 0)
      (if (surface_facts.surface-typecheck-facts-composite-active?)
        (surface_facts.surface-typecheck-facts-clear!)
        unit))))

(define (compiler-load-dependency-surface-key-current?
  [catalog-key : CompilerLoadDependencyCatalogKey]
  [surface-key : surface_identity.SurfaceIdentityKey]
  [configuration : String]) : bool
  (and
    (string.eq surface-key.package-name catalog-key.package-name)
    (string.eq
      surface-key.source-hash
      (string.int->string catalog-key.source-digest))
    (string.eq surface-key.compiler-build catalog-key.compiler-identity)
    (string.eq surface-key.configuration configuration)
    (match (tlci.tlci-producer-identity-admit
      catalog-key.compiler-identity
      (build_identity.compiler-build-git-hash-shared-view))
      [(tlci.TlciProducerIdentityAdmission.ExactMatch) true]
      [_ false])))

(define (compiler-load-dependency-surface-copy-specializations
  [source : tlci.TlciSpmdSpecializations]) : tlci.TlciSpmdSpecializations
  (let
    [count : i64 (tlci.tlci-spmd-specializations-len source)]
    [out : tlci.TlciSpmdSpecializations
      (tlci.tlci-spmd-specializations-with-capacity count)]
    [index : i64 0]
    (begin
      (while (< index count)
        (let
          [item : tlci.TlciSpmdSpecialization
            (tlci.tlci-spmd-specializations-ref source index)]
          (begin
            (tlci.tlci-spmd-specializations-push!
              (&mut out)
              (tlci.TlciSpmdSpecialization
                (string.copy (& item.abi))
                (string.copy (& item.backend))
                item.lanes
                (string.copy (& item.args))
                (string.copy (& item.result))
                item.index-param
                (string.copy (& item.symbol))))
            (set! index (+ index 1)))))
      out)))

(define (compiler-load-dependency-surface-copy-spmd-callables
  [source : tlci.TlciSpmdCallables]) : tlci.TlciSpmdCallables
  (let
    [count : i64 (tlci.tlci-spmd-callables-len source)]
    [out : tlci.TlciSpmdCallables
      (tlci.tlci-spmd-callables-with-capacity count)]
    [index : i64 0]
    (begin
      (while (< index count)
        (let
          [item : tlci.TlciSpmdCallable
            (tlci.tlci-spmd-callables-ref source index)]
          (begin
            (tlci.tlci-spmd-callables-push!
              (&mut out)
              (tlci.TlciSpmdCallable
                (string.copy (& item.name))
                (string.copy (& item.signature))
                (compiler-load-dependency-surface-copy-specializations
                  item.specializations)))
            (set! index (+ index 1)))))
      out)))

(define (compiler-load-dependency-surface-hydrate-entry
  [_owner : i64]
  [entry : CompilerLoadDependencyCatalogEntry]
  [configuration : String]
  [structural-session : cis.InternStructuralSessionHandle]) : CompilerLoadDependencySurfaceFragment
  (match entry.status
    [(CompilerLoadDependencyCatalogStatus.Unavailable _)
      CompilerLoadDependencySurfaceFragment.Unavailable]
    [_
      (match entry.image
        [(CompilerLoadDependencyCatalogImage.None)
          CompilerLoadDependencySurfaceFragment.Unavailable]
        [(CompilerLoadDependencyCatalogImage.Some image)
          (match (surface_hydrate.compiler-surface-key
            (owned_view.compiler-owned-shared-view image.rodata))
            [(surface_hydrate.ResultCompilerSurfaceKey.Missing)
              CompilerLoadDependencySurfaceFragment.Unavailable]
            [(surface_hydrate.ResultCompilerSurfaceKey.Err _)
              CompilerLoadDependencySurfaceFragment.Unavailable]
            [(surface_hydrate.ResultCompilerSurfaceKey.Ok key)
              (if (not
                (compiler-load-dependency-surface-key-current?
                  entry.key
                  (owned_view.compiler-owned-shared-view key)
                  configuration))
                CompilerLoadDependencySurfaceFragment.Unavailable
                (let
                  [pool-arena : i64 (ast.ast-node-pool-arena-make)]
                  [pools : ast.AstNodePoolContext
                    (in-arena
                      (arena.Arena pool-arena)
                      (ast.ast-node-pool-context-new-with-capacities-in-arena
                        1
                        1
                        pool-arena))]
                  [spmd-callables : tlci.TlciSpmdCallables
                    (in-arena
                      (arena.Arena
                        (ast.ast-node-pool-context-base-arena
                          (owned_view.compiler-owned-shared-view pools)))
                      (compiler-load-dependency-surface-copy-spmd-callables
                        entry.spmd-callables))]
                  [hydrated : surface_hydrate.ResultCompilerSurfaceHydration
                    (in-arena
                      (arena.Arena
                        (ast.ast-node-pool-context-base-arena
                          (owned_view.compiler-owned-shared-view pools)))
                      (surface_hydrate.compiler-surface-hydrate
                        image.rodata
                        key
                        structural-session
                        (owned_view.compiler-owned-shared-view pools)))]
                  (match hydrated
                    [(surface_hydrate.ResultCompilerSurfaceHydration.Ok
                        hydration)
                      (CompilerLoadDependencySurfaceFragment.Ready
                        hydration
                        spmd-callables)]
                    [_
                      (let
                        [base-arena : i64
                          (ast.ast-node-pool-context-base-arena
                            (owned_view.compiler-owned-shared-view pools))]
                        (begin
                          (ast.ast-node-pool-context-destroy-storage! pools)
                          (unsafe
                            (arena.tl_arena_destroy base-arena))
                          CompilerLoadDependencySurfaceFragment.Unavailable))])))])])]))

(define (compiler-load-session-state-structural-session
  [state : CompilerLoadSessionState]) : cis.InternStructuralSessionHandle
  (if (array-ref state.intern-state-ready 0)
    (let
      [intern-state : ci.InternCompatState
        (owned_view.compiler-owned-array-element-shared-view
          state.intern-state
          0)]
      (cis.intern-structural-session-handle-from-source-names
        (ci.intern-source-name-session-handle-from-state (& intern-state))))
    (cis.InternStructuralSessionHandle 0)))

(define (compiler-load-dependency-surfaces-build-cache!
  [state : CompilerLoadSessionState]
  [configuration : String]) : bool
  (let
    [surface-state : CompilerLoadDependencySurfaceState
      (owned_view.compiler-owned-shared-view state.dependency-surfaces)]
    [catalog : CompilerLoadDependencyCatalogList
      (owned_view.compiler-owned-array-element-shared-view
        state.dependency-catalog.entries
        0)]
    [owner : i64
      (compiler-load-dependency-catalog-owner-arena-ensure!
        (owned_view.compiler-owned-shared-view state))]
    [prior : CompilerLoadDependencySurfaceList
      (owned_view.compiler-owned-array-element-shared-view
        surface-state.fragments
        0)]
    [structural-session : cis.InternStructuralSessionHandle
      (compiler-load-session-state-structural-session state)]
    [verify-reject-last : bool
      (cfg
        dependency-tlci-verification
        (compiler-load-dependency-surface-verify-reject-last?)
        false)]
    (begin
      (compiler-load-dependency-surface-list-destroy-storage! prior)
      (in-arena
        (arena.Arena owner)
        (let
          [slots : (__tl_dyn-array CompilerLoadDependencySurfaceFragment)
            (__tl_make-array CompilerLoadDependencySurfaceFragment catalog.len)]
          [imported : (__tl_dyn-array bool) (__tl_make-array bool catalog.len)]
          [index : i64 0]
          [ok : bool (> catalog.len 0)]
          [preflight-facts : surface_facts.SurfaceTypecheckFactsBuilder
            (surface_facts.surface-typecheck-facts-builder-empty)]
          (begin
            (while (< index catalog.len)
              (let
                [fragment : CompilerLoadDependencySurfaceFragment
                  (if (and
                    verify-reject-last
                    (> catalog.len 1)
                    (= index (- catalog.len 1)))
                    CompilerLoadDependencySurfaceFragment.Unavailable
                    (compiler-load-dependency-surface-hydrate-entry
                      owner
                      (owned_view.compiler-owned-array-element-shared-view
                        catalog.slots
                        index)
                      (owned_view.compiler-owned-shared-view configuration)
                      structural-session))]
                (begin
                  (set! (array-ref slots index) fragment)
                  (match fragment
                    [(CompilerLoadDependencySurfaceFragment.Unavailable)
                      (set! ok false)]
                    [(CompilerLoadDependencySurfaceFragment.Ready hydration _)
                      (match (surface_facts.surface-typecheck-facts-builder-append
                        (owned_view.compiler-owned-shared-view preflight-facts)
                        (owned_view.compiler-owned-shared-view hydration.facts))
                        [(surface_facts.ResultSurfaceTypecheckFactsBuilder.Err
                            _)
                          (set! ok false)]
                        [(surface_facts.ResultSurfaceTypecheckFactsBuilder.Ok
                            next)
                          (set! preflight-facts next)])])
                  (set! index (+ index 1)))))
            (set!
              (array-ref surface-state.fragments 0)
              (CompilerLoadDependencySurfaceList slots imported catalog.len))
            (set!
              (array-ref surface-state.intern-generation 0)
              (ci.intern-generation))
            (set!
              (array-ref surface-state.configuration 0)
              (string.copy (& configuration)))
            (set! (array-ref surface-state.prepared 0) true)
            (set! (array-ref surface-state.enabled 0) ok)
            (if ok
              unit
              (set!
                (array-ref surface-state.fallback-count 0)
                (+ (array-ref surface-state.fallback-count 0) 1)))
            ok))))))

(define (compiler-load-dependency-surfaces-prepare!
  [state : CompilerLoadSessionState]
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]) : bool
  (let
    [surface-state : CompilerLoadDependencySurfaceState
      (owned_view.compiler-owned-shared-view state.dependency-surfaces)]
    [configuration : String
      (compiler-load-dependency-surface-configuration cfgs)]
    (begin
      (compiler-load-dependency-surface-reset-use!
        (owned_view.compiler-owned-shared-view state))
      (if (or
        (compiler-load-stdlib-root-configured? stdlib-roots)
        (= (string.string-length configuration) 0)
        (= (array-ref state.dependency-catalog.entries 0).len 0))
        (begin
          (set! (array-ref surface-state.enabled 0) false)
          false)
        (if (and
          (array-ref surface-state.prepared 0)
          (=
            (array-ref surface-state.intern-generation 0)
            (ci.intern-generation))
          (string.eq (array-ref surface-state.configuration 0) configuration)
          (=
            (array-ref surface-state.fragments 0).len
            (array-ref state.dependency-catalog.entries 0).len))
          (array-ref surface-state.enabled 0)
          (compiler-load-dependency-surfaces-build-cache! state configuration))))))

(define (compiler-load-dependency-catalog-observe
  [state : CompilerLoadSessionState]) : CompilerLoadDependencyCatalogObservation
  (let
    [registry : CompilerLoadDependencyCatalogRegistry
      (compiler-load-session-state-dependency-catalog
        (owned_view.compiler-owned-shared-view state))]
    [items : CompilerLoadDependencyCatalogList
      (owned_view.compiler-owned-array-element-shared-view registry.entries 0)]
    [index : i64 0]
    [unavailable : i64 0]
    [metadata-only : i64 0]
    [trusted-code : i64 0]
    [code-bytes : i64 0]
    [fixup-bytes : i64 0]
    [entry-bytes : i64 0]
    [import-bytes : i64 0]
    (begin
      (while (< index items.len)
        (begin
          (match (compiler-load-dependency-catalog-admitted-image
            (owned_view.compiler-owned-shared-view state)
            index)
            [(CompilerLoadDependencyCatalogAdmittedImage.NoCatalog) unit]
            [(CompilerLoadDependencyCatalogAdmittedImage.Unavailable _)
              (set! unavailable (+ unavailable 1))]
            [(CompilerLoadDependencyCatalogAdmittedImage.TrustedMetadataOnly
                image)
              (begin
                (set! metadata-only (+ metadata-only 1))
                (set! code-bytes (+ code-bytes (array-length image.code)))
                (set! fixup-bytes (+ fixup-bytes (array-length image.fixups)))
                (set! entry-bytes (+ entry-bytes (array-length image.entries)))
                (set!
                  import-bytes
                  (+ import-bytes (array-length image.imports))))]
            [(CompilerLoadDependencyCatalogAdmittedImage.TrustedCode image _)
              (begin
                (set! trusted-code (+ trusted-code 1))
                (set! code-bytes (+ code-bytes (array-length image.code)))
                (set! fixup-bytes (+ fixup-bytes (array-length image.fixups)))
                (set! entry-bytes (+ entry-bytes (array-length image.entries)))
                (set!
                  import-bytes
                  (+ import-bytes (array-length image.imports))))])
          (set! index (+ index 1))))
      (CompilerLoadDependencyCatalogObservation
        items.len
        (array-ref registry.generation 0)
        unavailable
        metadata-only
        trusted-code
        code-bytes
        fixup-bytes
        entry-bytes
        import-bytes
        (array-ref state.dependency-surfaces.enabled 0)
        (array-ref state.dependency-surfaces.fragments 0).len
        (array-ref state.dependency-surfaces.hit-count 0)
        (array-ref state.dependency-surfaces.fallback-count 0)
        (array-ref state.dependency-surfaces.surface-decl-count 0)
        (array-ref state.dependency-surfaces.macro-skip-count 0)
        (array-ref state.dependency-surfaces.typecheck-skip-count 0)))))

(define compiler-load-default-session-state : (__tl_dyn-array
    CompilerLoadSessionState)
  (__tl_make-array (compiler-load-standalone-session-state-new)))

;; Serial/test compatibility selector. Production call sites are migrated to
;; explicit state APIs incrementally; do not add new compile-job dependencies.
(define compiler-load-active-session-state : CompilerLoadSessionState
  (compiler-load-standalone-session-state-new))

;; Serial compatibility adapters intentionally share this process-lifetime
;; state. Stage0 keeps its historical shallow read while the current compiler
;; requires the equivalent operation to be visibly unsafe.
(define (compiler-load-active-session-state-shared-view) : CompilerLoadSessionState
  (cfg
    stage0-seed-bootstrap
    compiler-load-active-session-state
    (unsafe
      (ptr-read (ptr-addr-of compiler-load-active-session-state)))))

(define (compiler-load-session-state-shared-view
  [state : (& state CompilerLoadSessionState)]) : CompilerLoadSessionState
  (unsafe
    (ptr-read (int->ptr state.shared-address : (Ptr CompilerLoadSessionState)))))

;; Serial/test compatibility accessor. Production jobs pass their owned state
;; directly; adapters that cannot yet own a job context use this accessor so
;; stateful compiler modules do not depend on the selector variable itself.
(define (compiler-load-serial-test-session-state) : CompilerLoadSessionState
  (compiler-load-active-session-state-shared-view))

(define (compiler-load-session-state-standalone-reset-safe?
  [state : CompilerLoadSessionState]) : bool
  (compiler-load-session-state-bool-cell-get state.standalone-reset-safe))

;; Resetting compiler entries own the compatibility default session. Running
;; one while a driver-owned session is selected would invalidate the driver's
;; intern-id keyed caches and floors behind its back.
(define (compiler-load-active-session-live?) : bool
  (not
    (compiler-load-session-state-standalone-reset-safe?
      (compiler-load-active-session-state-shared-view))))

;; Global compatibility entry points must not retain a state-owned session
;; after its driver arena is retired. Stateful driver paths install their own
;; session explicitly; legacy resets return to this process-lifetime owner.
(define (compiler-load-default-session-use!) : unit
  (set!
    compiler-load-active-session-state
    (compiler-load-global-array-element-shared-view
      compiler-load-default-session-state
      0)))

(define (compiler-load-session-state-cache-enabled?
  [state : (& state CompilerLoadSessionState)]) : bool
  (compiler-load-session-state-bool-cell-get state.cache-enabled))

(define (compiler-load-session-state-cache-set-enabled!
  [state : CompilerLoadSessionState]
  [enabled : bool]) : unit
  (compiler-load-session-state-bool-cell-set! state.cache-enabled enabled))

(define (compiler-load-session-state-cache-enable!
  [state : CompilerLoadSessionState]) : unit
  (compiler-load-session-state-cache-set-enabled! state true))

(define (compiler-load-session-state-program-cache-set-enabled-cell!
  [state : CompilerLoadSessionState]
  [enabled : bool]) : unit
  (compiler-load-session-state-bool-cell-set!
    state.program-cache-enabled
    enabled))

(define (compiler-load-session-state-program-cache-fill!
  [state : CompilerLoadSessionState]
  [index : i64]) : unit
  (if (>= index compiler-load-program-cache-capacity)
    unit
    (begin
      (set!
        (array-ref state.program-cache index)
        (CompilerLoadProgramCacheEmpty))
      (compiler-load-session-state-program-cache-fill! state (+ index 1)))))

(define (compiler-load-session-state-program-cache-stats-reset!
  [state : CompilerLoadSessionState]) : unit
  (begin
    (set! (array-ref state.program-cache-hit-count 0) 0)
    (set! (array-ref state.program-cache-miss-count 0) 0)
    (set! (array-ref state.program-cache-store-count 0) 0)))

(define (compiler-load-session-state-program-cache-clear!
  [state : CompilerLoadSessionState]) : unit
  (begin
    (compiler-load-session-state-program-cache-fill!
      (compiler-load-session-state-shared-view (& state))
      0)
    (set! (array-ref state.program-cache-ready 0) true)
    (compiler-load-session-state-program-admission-clear!
      (compiler-load-session-state-shared-view (& state)))
    (compiler-load-session-state-program-cache-stats-reset! state)))

(define (compiler-load-program-cache-clear!) : unit
  (compiler-load-session-state-program-cache-clear!
    (compiler-load-active-session-state-shared-view)))

(define (compiler-load-session-state-program-cache-ensure!
  [state : CompilerLoadSessionState]) : unit
  (if (array-ref state.program-cache-ready 0)
    unit
    (compiler-load-session-state-program-cache-clear! state)))

(define (compiler-load-session-state-program-cache-note-hit!
  [state : CompilerLoadSessionState]) : unit
  (set!
    (array-ref state.program-cache-hit-count 0)
    (+ (compiler-load-session-state-program-cache-hit-count-value state) 1)))

(define (compiler-load-program-cache-note-hit!) : unit
  (compiler-load-session-state-program-cache-note-hit!
    (compiler-load-active-session-state-shared-view)))

(define (compiler-load-session-state-program-cache-note-miss!
  [state : CompilerLoadSessionState]) : unit
  (set!
    (array-ref state.program-cache-miss-count 0)
    (+ (compiler-load-session-state-program-cache-miss-count-value state) 1)))

(define (compiler-load-program-cache-note-miss!) : unit
  (compiler-load-session-state-program-cache-note-miss!
    (compiler-load-active-session-state-shared-view)))

(define (compiler-load-session-state-program-cache-note-store!
  [state : CompilerLoadSessionState]) : unit
  (set!
    (array-ref state.program-cache-store-count 0)
    (+ (compiler-load-session-state-program-cache-store-count-value state) 1)))

(define (compiler-load-session-state-program-cache-hit-count-value
  [state : (& state CompilerLoadSessionState)]) : i64
  (array-ref state.program-cache-hit-count 0))

(define (compiler-load-program-cache-hit-count-value) : i64
  (let
    [state : CompilerLoadSessionState
      (compiler-load-active-session-state-shared-view)]
    (compiler-load-session-state-program-cache-hit-count-value state)))

(define (compiler-load-session-state-program-cache-miss-count-value
  [state : (& state CompilerLoadSessionState)]) : i64
  (array-ref state.program-cache-miss-count 0))

(define (compiler-load-session-state-program-cache-store-count-value
  [state : (& state CompilerLoadSessionState)]) : i64
  (array-ref state.program-cache-store-count 0))

(define (compiler-load-program-cache-store-count-value) : i64
  (let
    [state : CompilerLoadSessionState
      (compiler-load-active-session-state-shared-view)]
    (compiler-load-session-state-program-cache-store-count-value state)))

(define (compiler-load-cfg-key-equal?
  [left : (& left sym_i64_env.SymI64Env)]
  [right : (& right sym_i64_env.SymI64Env)]) : bool
  (match (sym_i64_env.sym-i64-view (sym_i64_env.sym-i64-shared-view left))
    [(sym_i64_env.SymI64ViewNil)
      (match (sym_i64_env.sym-i64-view (sym_i64_env.sym-i64-shared-view right))
        [(sym_i64_env.SymI64ViewNil) true]
        [(sym_i64_env.SymI64ViewBind _ _ _) false])]
    [(sym_i64_env.SymI64ViewBind left-key left-value left-rest)
      (match (sym_i64_env.sym-i64-view (sym_i64_env.sym-i64-shared-view right))
        [(sym_i64_env.SymI64ViewNil) false]
        [(sym_i64_env.SymI64ViewBind right-key right-value right-rest)
          (and
            (= left-key right-key)
            (= left-value right-value)
            (compiler-load-cfg-key-equal? left-rest right-rest))])]))

(define (compiler-load-program-source-kind-equal?
  [left : CompilerLoadProgramSourceKind]
  [right : CompilerLoadProgramSourceKind]) : bool
  (match left
    [(CompilerLoadProgramFile)
      (match right
        [(CompilerLoadProgramFile) true]
        [(CompilerLoadProgramEmbedded) false])]
    [(CompilerLoadProgramEmbedded)
      (match right
        [(CompilerLoadProgramFile) false]
        [(CompilerLoadProgramEmbedded) true])]))

(define (compiler-load-program-cache-key-equal?
  [left : (& left CompilerLoadProgramCacheKey)]
  [right : (& right CompilerLoadProgramCacheKey)]) : bool
  (and
    (compiler-load-program-source-kind-equal?
      (clone left.kind)
      (clone right.kind))
    (= left.path-id right.path-id)
    (compiler-load-cfg-key-equal? left.cfgs right.cfgs)))

(define (compiler-load-cfg-key-copy [cfgs : sym_i64_env.SymI64Env]) : sym_i64_env.SymI64Env
  (match (sym_i64_env.sym-i64-view cfgs)
    [(sym_i64_env.SymI64ViewNil) (sym_i64_env.sym-i64-empty)]
    [(sym_i64_env.SymI64ViewBind key value rest)
      (sym_i64_env.sym-i64-bind-id (compiler-load-cfg-key-copy rest) key value)]))

(define (compiler-load-program-cache-key-copy
  [key : (& key CompilerLoadProgramCacheKey)]) : CompilerLoadProgramCacheKey
  (CompilerLoadProgramCacheKey
    (clone key.kind)
    (clone key.path-id)
    (compiler-load-cfg-key-copy (sym_i64_env.sym-i64-shared-view (& key.cfgs)))))

(define (compiler-load-session-state-program-cache-lookup-from
  [state : CompilerLoadSessionState]
  [key : (& key CompilerLoadProgramCacheKey)]
  [index : i64]) : CompilerLoadProgramCacheLookup
  (if (>= index compiler-load-program-cache-capacity)
    (CompilerLoadProgramCacheMiss)
    (match (clone (array-ref state.program-cache index))
      [(CompilerLoadProgramCacheEmpty) (CompilerLoadProgramCacheMiss)]
      [(CompilerLoadProgramCacheFull slot-key program)
        (if (compiler-load-program-cache-key-equal? slot-key key)
          (CompilerLoadProgramCacheHit program)
          (compiler-load-session-state-program-cache-lookup-from
            state
            key
            (+ index 1)))])))

(define (compiler-load-session-state-program-cache-lookup
  [state : CompilerLoadSessionState]
  [key : (& key CompilerLoadProgramCacheKey)]) : CompilerLoadProgramCacheLookup
  (begin
    (compiler-load-session-state-program-cache-ensure!
      (compiler-load-session-state-shared-view (& state)))
    (compiler-load-session-state-program-cache-lookup-from state key 0)))

(define (compiler-load-program-cache-lookup
  [key : (& key CompilerLoadProgramCacheKey)]) : CompilerLoadProgramCacheLookup
  (compiler-load-session-state-program-cache-lookup
    (compiler-load-active-session-state-shared-view)
    key))

(define (compiler-load-session-state-program-cache-store-at
  [state : CompilerLoadSessionState]
  [key : CompilerLoadProgramCacheKey]
  [program : ast.AstProgram]
  [index : i64]) : bool
  (if (>= index compiler-load-program-cache-capacity)
    false
    (match (clone (array-ref state.program-cache index))
      [(CompilerLoadProgramCacheEmpty)
        (begin
          (set!
            (array-ref state.program-cache index)
            (CompilerLoadProgramCacheFull key program))
          (compiler-load-session-state-program-cache-note-store! state)
          true)]
      [(CompilerLoadProgramCacheFull slot-key _)
        (if (compiler-load-program-cache-key-equal? slot-key key)
          (begin
            (set!
              (array-ref state.program-cache index)
              (CompilerLoadProgramCacheFull key program))
            (compiler-load-session-state-program-cache-note-store! state)
            true)
          (compiler-load-session-state-program-cache-store-at
            state
            key
            program
            (+ index 1)))])))

(define (compiler-load-session-state-program-cache-store
  [state : CompilerLoadSessionState]
  [key : CompilerLoadProgramCacheKey]
  [program : ast.AstProgram]) : bool
  (begin
    (compiler-load-session-state-program-cache-ensure!
      (compiler-load-session-state-shared-view (& state)))
    (compiler-load-session-state-program-cache-store-at state key program 0)))

(define (compiler-load-program-cache-store
  [key : CompilerLoadProgramCacheKey]
  [program : ast.AstProgram]) : bool
  (compiler-load-session-state-program-cache-store
    (compiler-load-active-session-state-shared-view)
    key
    program))

(define (compiler-load-session-state-program-cache-can-store-at
  [state : CompilerLoadSessionState]
  [key : (& key CompilerLoadProgramCacheKey)]
  [index : i64]) : bool
  (if (>= index compiler-load-program-cache-capacity)
    false
    (match (clone (array-ref state.program-cache index))
      [(CompilerLoadProgramCacheEmpty) true]
      [(CompilerLoadProgramCacheFull slot-key _)
        (if (compiler-load-program-cache-key-equal? slot-key key)
          true
          (compiler-load-session-state-program-cache-can-store-at
            state
            key
            (+ index 1)))])))

(define (compiler-load-session-state-program-cache-can-store
  [state : CompilerLoadSessionState]
  [key : (& key CompilerLoadProgramCacheKey)]) : bool
  (begin
    (compiler-load-session-state-program-cache-ensure!
      (compiler-load-session-state-shared-view (& state)))
    (compiler-load-session-state-program-cache-can-store-at state key 0)))

(define (compiler-load-program-cache-can-store
  [key : (& key CompilerLoadProgramCacheKey)]) : bool
  (compiler-load-session-state-program-cache-can-store
    (compiler-load-active-session-state-shared-view)
    key))

(define (compiler-load-session-state-program-admission-fill!
  [state : CompilerLoadSessionState]
  [index : i64]) : unit
  (if (>= index compiler-load-program-cache-capacity)
    unit
    (begin
      (set!
        (array-ref state.program-admission index)
        (CompilerLoadProgramAdmissionEmpty))
      (compiler-load-session-state-program-admission-fill! state (+ index 1)))))

(define (compiler-load-session-state-program-admission-clear!
  [state : CompilerLoadSessionState]) : unit
  (begin
    (compiler-load-session-state-program-admission-fill!
      (compiler-load-session-state-shared-view (& state))
      0)
    (set! (array-ref state.program-admission-ready 0) true)))

(define (compiler-load-session-state-program-admission-ensure!
  [state : CompilerLoadSessionState]) : unit
  (if (array-ref state.program-admission-ready 0)
    unit
    (compiler-load-session-state-program-admission-clear! state)))

(define (compiler-load-session-state-program-admission-contains-from?
  [state : CompilerLoadSessionState]
  [key : (& key CompilerLoadProgramCacheKey)]
  [index : i64]) : bool
  (if (>= index compiler-load-program-cache-capacity)
    false
    (match (clone (array-ref state.program-admission index))
      [(CompilerLoadProgramAdmissionEmpty) false]
      [(CompilerLoadProgramAdmissionFull slot-key)
        (if (compiler-load-program-cache-key-equal? slot-key key)
          true
          (compiler-load-session-state-program-admission-contains-from?
            state
            key
            (+ index 1)))])))

(define (compiler-load-session-state-program-admission-contains?
  [state : CompilerLoadSessionState]
  [key : (& key CompilerLoadProgramCacheKey)]) : bool
  (begin
    (compiler-load-session-state-program-admission-ensure!
      (compiler-load-session-state-shared-view (& state)))
    (compiler-load-session-state-program-admission-contains-from? state key 0)))

(define (compiler-load-program-admission-contains?
  [key : CompilerLoadProgramCacheKey]) : bool
  (compiler-load-session-state-program-admission-contains?
    (compiler-load-active-session-state-shared-view)
    key))

(define (compiler-load-session-state-program-admission-record-at
  [state : CompilerLoadSessionState]
  [key : CompilerLoadProgramCacheKey]
  [index : i64]) : bool
  (if (>= index compiler-load-program-cache-capacity)
    false
    (match (clone (array-ref state.program-admission index))
      [(CompilerLoadProgramAdmissionEmpty)
        (begin
          (set!
            (array-ref state.program-admission index)
            (CompilerLoadProgramAdmissionFull key))
          true)]
      [(CompilerLoadProgramAdmissionFull slot-key)
        (if (compiler-load-program-cache-key-equal? slot-key key)
          true
          (compiler-load-session-state-program-admission-record-at
            state
            key
            (+ index 1)))])))

(define (compiler-load-session-state-program-admission-record
  [state : CompilerLoadSessionState]
  [key : CompilerLoadProgramCacheKey]) : bool
  (begin
    (compiler-load-session-state-program-admission-ensure!
      (compiler-load-session-state-shared-view (& state)))
    (compiler-load-session-state-program-admission-record-at state key 0)))

(define (compiler-load-session-state-program-admission-record-persistent
  [state : CompilerLoadSessionState]
  [key : CompilerLoadProgramCacheKey]) : bool
  (if (compiler-load-session-state-program-admission-contains?
    (compiler-load-session-state-shared-view (& state))
    key)
    true
    (let
      [persistent-key : CompilerLoadProgramCacheKey
        (in-arena
          (arena.Arena ast.node-pool-base-arena)
          (compiler-load-program-cache-key-copy key))]
      (compiler-load-session-state-program-admission-record
        state
        persistent-key))))

(define (compiler-load-program-admission-record-persistent
  [key : CompilerLoadProgramCacheKey]) : bool
  (compiler-load-session-state-program-admission-record-persistent
    (compiler-load-active-session-state-shared-view)
    key))

;; Refresh the session's intern floor when the bound table grew past it. A
;; session wired to an intern state reads that state's own cells, so floor
;; bookkeeping for a non-installed state never consults whichever table is
;; globally active; when the wired state is the installed one the live
;; compatibility count is authoritative for it, matching the legacy path
;; exactly. Legacy (unwired) sessions keep the compatibility-global path.
(define (compiler-load-session-state-intern-floor-refresh!
  [state : CompilerLoadSessionState]
  [old-intern-floor : i64]) : unit
  (if (array-ref state.intern-state-ready 0)
    (let
      [interns : (&mut state ci.InternCompatState)
        (&mut (array-ref state.intern-state 0))]
      [new-intern-floor : i64
        (if (=
          (ci.intern-active-table-id)
          (ci.intern-compat-state-table-id interns))
          (ci.intern-pool-len)
          (ci.intern-compat-state-pool-len interns))]
      (if (> new-intern-floor old-intern-floor)
        (begin
          (ci.intern-compat-state-persistent-arena-floor-refresh! interns)
          (set! (array-ref state.intern-floor 0) new-intern-floor))
        unit))
    (let
      [new-intern-floor : i64 (ci.intern-pool-len)]
      (if (> new-intern-floor old-intern-floor)
        (begin
          (ci.intern-persistent-arena-floor-refresh!)
          (set! (array-ref state.intern-floor 0) new-intern-floor))
        unit))))

(define (compiler-load-session-state-note-persistent!
  [state : CompilerLoadSessionState]) : unit
  (begin
    (if (>
      (ast.ast-node-pool-len)
      (compiler-load-session-state-ast-floor-value state))
      (set! (array-ref state.ast-floor 0) (ast.ast-node-pool-len))
      unit)
    (if (>
      (ast.ty-node-pool-len)
      (compiler-load-session-state-ty-floor-value state))
      (set! (array-ref state.ty-floor 0) (ast.ty-node-pool-len))
      unit)
    (compiler-load-session-state-intern-floor-refresh!
      (compiler-load-session-state-shared-view (& state))
      (compiler-load-session-state-intern-floor-value state))))

(define (compiler-load-session-note-persistent!) : unit
  (compiler-load-session-state-note-persistent!
    (compiler-load-active-session-state-shared-view)))

(define (compiler-load-session-state-note-persistent-interns!
  [state : CompilerLoadSessionState]) : unit
  (compiler-load-session-state-intern-floor-refresh!
    (compiler-load-session-state-shared-view (& state))
    (compiler-load-session-state-intern-floor-value state)))

(define (compiler-load-session-state-note-persistent-with-pools!
  [state : CompilerLoadSessionState]
  [pools : ast.AstNodePoolContext]) : unit
  (begin
    (if (>
      (ast.ast-node-pool-context-expr-len pools)
      (compiler-load-session-state-ast-floor-value state))
      (set!
        (array-ref state.ast-floor 0)
        (ast.ast-node-pool-context-expr-len pools))
      unit)
    (if (>
      (ast.ast-node-pool-context-type-len pools)
      (compiler-load-session-state-ty-floor-value state))
      (set!
        (array-ref state.ty-floor 0)
        (ast.ast-node-pool-context-type-len pools))
      unit)
    (compiler-load-session-state-intern-floor-refresh!
      (compiler-load-session-state-shared-view (& state))
      (compiler-load-session-state-intern-floor-value state))))

(define (compiler-load-session-state-ast-floor-value
  [state : (& state CompilerLoadSessionState)]) : i64
  (array-ref state.ast-floor 0))

(define (compiler-load-session-ast-floor-value) : i64
  (let
    [state : CompilerLoadSessionState
      (compiler-load-active-session-state-shared-view)]
    (compiler-load-session-state-ast-floor-value state)))

(define (compiler-load-session-state-ty-floor-value
  [state : (& state CompilerLoadSessionState)]) : i64
  (array-ref state.ty-floor 0))

(define (compiler-load-session-ty-floor-value) : i64
  (let
    [state : CompilerLoadSessionState
      (compiler-load-active-session-state-shared-view)]
    (compiler-load-session-state-ty-floor-value state)))

(define (compiler-load-session-state-intern-floor-value
  [state : (& state CompilerLoadSessionState)]) : i64
  (array-ref state.intern-floor 0))

(define (compiler-load-session-intern-floor-value) : i64
  (let
    [state : CompilerLoadSessionState
      (compiler-load-active-session-state-shared-view)]
    (compiler-load-session-state-intern-floor-value state)))

(define (compiler-load-session-state-floors-set!
  [state : CompilerLoadSessionState]
  [ast-floor : i64]
  [ty-floor : i64]
  [intern-floor : i64]) : unit
  (begin
    (set! (array-ref state.ast-floor 0) ast-floor)
    (set! (array-ref state.ty-floor 0) ty-floor)
    (set! (array-ref state.intern-floor 0) intern-floor)))

(define (compiler-load-session-floors-set!
  [ast-floor : i64]
  [ty-floor : i64]
  [intern-floor : i64]) : unit
  (compiler-load-session-state-floors-set!
    (compiler-load-active-session-state-shared-view)
    ast-floor
    ty-floor
    intern-floor))

(define (compiler-load-session-state-use! [state : CompilerLoadSessionState]) : unit
  (begin
    (set! (array-ref state.intern-state-ready 0) false)
    (set! compiler-load-active-session-state state)))

(define (compiler-load-session-state-use-with-intern-state!
  [state : CompilerLoadSessionState]
  [intern-state : ci.InternCompatState]) : unit
  (begin
    (set! (array-ref state.intern-state 0) intern-state)
    (set! (array-ref state.intern-state-ready 0) true)
    (set! compiler-load-active-session-state state)))

(define (compiler-load-session-cache-enable!) : unit
  (set!
    (array-ref
      (__tl-project-field compiler-load-active-session-state cache-enabled)
      0)
    true))

(define (compiler-load-session-program-cache-enable!) : unit
  (set!
    (array-ref
      (__tl-project-field
        compiler-load-active-session-state
        program-cache-enabled)
      0)
    true))

(define (compiler-load-session-state-program-cache-disable!
  [state : CompilerLoadSessionState]) : unit
  (begin
    (compiler-load-session-state-program-cache-set-enabled-cell!
      (compiler-load-session-state-shared-view (& state))
      false)
    (set! (array-ref state.program-cache-ready 0) false)
    (set! (array-ref state.program-admission-ready 0) false)
    (set! (array-ref state.program-cache-hit-count 0) 0)
    (set! (array-ref state.program-cache-miss-count 0) 0)
    (set! (array-ref state.program-cache-store-count 0) 0)))

(define (compiler-load-session-program-cache-disable!) : unit
  (begin
    (set!
      (array-ref
        (__tl-project-field
          compiler-load-active-session-state
          program-cache-enabled)
        0)
      false)
    (compiler-load-program-cache-clear!)))

(define (compiler-load-session-state-program-cache-enabled?
  [state : (& state CompilerLoadSessionState)]) : bool
  (array-ref state.program-cache-enabled 0))

(define (compiler-load-session-program-cache-enabled?) : bool
  (let
    [state : CompilerLoadSessionState
      (compiler-load-active-session-state-shared-view)]
    (compiler-load-session-state-program-cache-enabled? state)))

(define (compiler-load-session-cache-disable-for-test!) : unit
  (begin
    (set!
      compiler-load-active-session-state
      (compiler-load-standalone-session-state-new))
    (set!
      (array-ref
        (__tl-project-field compiler-load-active-session-state cache-enabled)
        0)
      false)
    (set!
      (array-ref
        (__tl-project-field
          compiler-load-active-session-state
          program-cache-enabled)
        0)
      true)
    (compiler-load-session-floors-set! 0 0 0)
    (compiler-load-program-cache-clear!)
    (compiler-load-runtime-prelude-cache-clear!)))

;; Retire every cache and floor owned by the active serial compiler session.
;; The replacement state is installed before the global pool/intern reset so
;; those resets cannot preserve the old session's floors. Callers must invoke
;; this while allocating in the arena that will outlive the retired session.
(define (compiler-load-session-fresh-reset!) : unit
  (begin
    (set!
      compiler-load-active-session-state
      (compiler-load-standalone-session-state-new))
    (compiler-load-session-reset-pools!)
    ;; Fresh sessions retire every cached AST owner, so no declaration-origin
    ;; sidecar keyed by a retired storage address may survive into the next run.
    (reader.sp-node-pool-reset!)
    (compiler-load-session-reset-interns!)
    (ci.intern-persistent-arena-reset!)
    (compiler-load-session-floors-set! 0 0 0)
    (compiler-load-program-cache-clear!)
    (compiler-load-runtime-prelude-cache-clear!)))

(define (compiler-load-session-cache-enabled?) : bool
  (array-ref
    (__tl-project-field compiler-load-active-session-state cache-enabled)
    0))

(define (compiler-load-session-state-embedded-stdlib-source-used?
  [state : CompilerLoadSessionState]) : bool
  (array-ref state.cache-enabled 1))

(define (compiler-load-session-state-note-embedded-stdlib-source!
  [state : CompilerLoadSessionState]) : unit
  (set! (array-ref state.cache-enabled 1) true))

;; Canonical ids of modules whose source matches the embedded stdlib payload
;; in this process. The tlci macro route consults this per defining module:
;; embedded source and byte-identical disk source may use the catalog, while
;; modified or otherwise untrusted roots must expand from their own source.
(define compiler-load-provenance-arena-handle : i64
  0)

(define (compiler-load-provenance-arena-handle-value) : i64
  compiler-load-provenance-arena-handle)

;: Arena for the embedded-provenance set and the content-equivalence cache.
;: These outlive every session floor reset (their contents are re-derived
;: per session, but the bindings must never point into memory another reset
;: can free), so they get their own arena that is created once and only grows.
;: The retained payload is small even for selfhost; start with the runtime's
;: small reservation while preserving the ordinary overflow path.
(define (compiler-load-provenance-arena) : i64
  (begin
    (if (= compiler-load-provenance-arena-handle 0)
      (begin
        (set! compiler-load-provenance-arena-handle (arena.tl_arena_make_small))
        (ast.compiler-arena-debug-protect-never-reset!
          compiler-load-provenance-arena-handle))
      unit)
    ;; Re-enter the root-tracked newest segment after an overflow. Selecting
    ;; the full root again would fork an unreachable sibling chain.
    (let
      [head : i64
        (unsafe
          (ptr-read
            (ptr-offset
              (int->ptr compiler-load-provenance-arena-handle : (Ptr i64))
              7)))]
      (if (= head 0)
        compiler-load-provenance-arena-handle
        head))))

(define compiler-load-embedded-module-ids : sym_i64_env.SymI64Env
  (sym_i64_env.sym-i64-empty))

;; Batch entries reset and rebuild their intern table while retaining parsed
;; stdlib programs. Keep the trusted module identities structurally as well as
;; in the fast symbol-id set so a cached module remains trusted after its old
;; numeric id is retired. The strings and vector storage live in the dedicated
;; provenance arena for the same reason as the id set.
(define compiler-load-embedded-module-names : svec.Vec
  (svec.new))

(define (compiler-load-embedded-module-ids-shared-view) : sym_i64_env.SymI64Env
  (cfg
    stage0-seed-bootstrap
    compiler-load-embedded-module-ids
    (unsafe
      (ptr-read (ptr-addr-of compiler-load-embedded-module-ids)))))

(define (compiler-load-embedded-module-names-shared-view) : svec.Vec
  (compiler-load-global-shared-view compiler-load-embedded-module-names))

(define (compiler-load-embedded-module-id-cache-reset!) : unit
  (set! compiler-load-embedded-module-ids (sym_i64_env.sym-i64-empty)))

(define (compiler-load-embedded-module-ids-reset!) : unit
  (begin
    (compiler-load-embedded-module-id-cache-reset!)
    (set! compiler-load-embedded-module-names (svec.new))))

(define (compiler-load-note-embedded-module! [path : String]) : unit
  (let
    [module : String (compiler-load-canonical-module-id-from-path path)]
    [id : i64 (ci.intern (clone module))]
    [names : svec.Vec (compiler-load-embedded-module-names-shared-view)]
    ;; The set outlives every load-scoped scratch arena and every intern
    ;; floor reset; bind its nodes in the dedicated provenance arena.
    (in-arena
      (arena.Arena (compiler-load-provenance-arena))
      (begin
        (unless
          (svec.contains? (& names) (clone module))
          (set!
            compiler-load-embedded-module-names
            (compiler-load-string-vec-push-copy
              (compiler-load-embedded-module-names-shared-view)
              (string.copy (& module)))))
        (set!
          compiler-load-embedded-module-ids
          (sym_i64_env.sym-i64-bind-id
            (compiler-load-embedded-module-ids-shared-view)
            id
            1))))))

(define compiler-load-embedded-equivalence-cache : sym_i64_env.SymI64Env
  (sym_i64_env.sym-i64-empty))

(define (compiler-load-embedded-equivalence-cache-shared-view) : sym_i64_env.SymI64Env
  (cfg
    stage0-seed-bootstrap
    compiler-load-embedded-equivalence-cache
    (unsafe
      (ptr-read (ptr-addr-of compiler-load-embedded-equivalence-cache)))))

(define compiler-load-embedded-provenance-noted : bool
  false)

(define (compiler-load-embedded-provenance-noted?) : bool
  compiler-load-embedded-provenance-noted)

(define (compiler-load-embedded-provenance-observer-ok?) : bool
  (let
    [previous : bool compiler-load-embedded-provenance-noted]
    [false-ok : bool
      (begin
        (set! compiler-load-embedded-provenance-noted false)
        (not (compiler-load-embedded-provenance-noted?)))]
    [true-ok : bool
      (begin
        (set! compiler-load-embedded-provenance-noted true)
        (compiler-load-embedded-provenance-noted?))]
    (begin
      (set! compiler-load-embedded-provenance-noted previous)
      (and false-ok true-ok))))

;: A stdlib module resolved from a root (or the working directory) whose
;: source is byte-identical to the embedded payload's copy carries embedded
;: provenance for the macro route: the source-bound catalog is exact for it
;: by construction, and any user modification breaks the equality and keeps
;: that module on source interpretation. Cached per suffix; the compare runs
;: once per module per session.
(define (compiler-load-note-embedded-equivalent-if-matching!
  [suffix : String]
  [disk-path : String]) : unit
  (let
    [key : i64 (ci.intern (clone suffix))]
    [cache : sym_i64_env.SymI64Env
      (compiler-load-embedded-equivalence-cache-shared-view)]
    (if (sym_i64_env.sym-i64-contains-id cache key)
      unit
      (let
        [outcome : i64
          (match (compiler-load-embedded-stdlib-source (clone suffix))
            [(ces.CompilerEmbeddedStdlibSource.CompilerEmbeddedStdlibSomeSource
                embedded-text)
              (let
                [disk-text : String (compiler-load-read-file-text disk-path)]
                (if (and
                  (=
                    (string.string-length disk-text)
                    (string.string-length embedded-text))
                  (string.eq disk-text embedded-text))
                  1
                  -1))]
            [(ces.CompilerEmbeddedStdlibSource.CompilerEmbeddedStdlibNoSource)
              -1])]
        (begin
          (in-arena
            (arena.Arena (compiler-load-provenance-arena))
            (set!
              compiler-load-embedded-equivalence-cache
              (sym_i64_env.sym-i64-bind-id
                (compiler-load-embedded-equivalence-cache-shared-view)
                key
                outcome)))
          (if (= outcome 1)
            (begin
              (compiler-load-note-embedded-module!
                (str_cat.str-cat "stdlib/" suffix))
              (set! compiler-load-embedded-provenance-noted true))
            unit))))))

(define (compiler-load-embedded-stdlib-module-id? [module : String]) : bool
  (let
    [id : i64 (ci.intern (clone module))]
    [ids : sym_i64_env.SymI64Env
      (compiler-load-embedded-module-ids-shared-view)]
    (if (sym_i64_env.sym-i64-contains-id ids id)
      true
      (let
        [names : svec.Vec (compiler-load-embedded-module-names-shared-view)]
        (if (not (svec.contains? (& names) module))
          false
          ;; The structural identity survived a job-local intern reset. Rebind
          ;; its current numeric id so subsequent macro dispatches stay O(1).
          (in-arena
            (arena.Arena (compiler-load-provenance-arena))
            (begin
              (set!
                compiler-load-embedded-module-ids
                (sym_i64_env.sym-i64-bind-id
                  (compiler-load-embedded-module-ids-shared-view)
                  id
                  1))
              true)))))))

(define (compiler-load-session-note-embedded-stdlib-source!) : unit
  (compiler-load-session-state-note-embedded-stdlib-source!
    (compiler-load-active-session-state-shared-view)))

(define (compiler-load-session-reset-pools!) : unit
  (begin
    (parser.compiler-parse-decl-origin-cache-reset!)
    (reader.sexpr-node-pool-reset!)
    ;; Global resets do not own the previously installed context cells. Detach
    ;; before truncating so stale scratch-owned cells are not updated.
    (ast.ast-node-pool-active-context-clear!)
    (compiler-load-surface-summaries-reset!)
    (compiler-load-lazy-qualified-observer-reset!)
    (set!
      (array-ref
        (__tl-project-field
          compiler-load-active-session-state
          surface-summary-load-depth)
        0)
      0)
    (if (compiler-load-session-cache-enabled?)
      (begin
        (ast.ast-node-pool-reset-to! (compiler-load-session-ast-floor-value))
        (ast.ty-node-pool-reset-to! (compiler-load-session-ty-floor-value)))
      (begin
        ;; Standalone sessions own no cached AST whose cold parse sidecars must
        ;; survive. Clear the spanned reader pool before their arena is retired,
        ;; matching compiler-load-session-state-reset-pools-with-pools! below.
        (reader.sp-node-pool-reset!)
        (ast.ast-node-pool-reset!)
        (ast.ty-node-pool-reset!)))))

(define (compiler-load-session-state-reset-pools-with-pools!
  [state : CompilerLoadSessionState]
  [pools : ast.AstNodePoolContext]) : unit
  (begin
    (parser.compiler-parse-decl-origin-cache-reset!)
    (reader.sexpr-node-pool-reset!)
    (compiler-load-session-state-surface-summaries-reset!
      (compiler-load-session-state-shared-view (& state)))
    (compiler-load-session-state-lazy-qualified-observer-reset! state)
    (set! (array-ref state.surface-summary-load-depth 0) 0)
    (if (compiler-load-session-state-cache-enabled? state)
      (ast.ast-node-pool-context-reset-to!
        pools
        (compiler-load-session-state-ast-floor-value state)
        (compiler-load-session-state-ty-floor-value state))
      (begin
        (reader.sp-node-pool-reset!)
        (ast.ast-node-pool-context-reset-to! pools 0 0)))))

(define (compiler-load-session-reset-interns!) : unit
  (begin
    (compiler-load-embedded-module-ids-reset!)
    (set! compiler-load-embedded-equivalence-cache (sym_i64_env.sym-i64-empty))
    (set! compiler-load-embedded-provenance-noted false)
    (compiler-load-surface-summaries-reset!)
    (compiler-load-lazy-qualified-observer-reset!)
    (set!
      (array-ref
        (__tl-project-field
          compiler-load-active-session-state
          surface-summary-load-depth)
        0)
      0)
    (if (compiler-load-session-cache-enabled?)
      (begin
        (ci.intern-reset-to! (compiler-load-session-intern-floor-value))
        (ci.intern-persistent-arena-reset-to-floor!))
      (ci.intern-reset!))))

(define (compiler-load-session-state-reset-interns-with-state!
  [load-state : CompilerLoadSessionState]
  [intern-state : (&mut intern-state ci.InternCompatState)]) : unit
  (begin
    ;; Numeric intern ids are job-local. Retain the structural trusted-module
    ;; names for cached ASTs, but discard all id-keyed caches before recycling
    ;; the interner so stale ids cannot alias unrelated symbols in the next job.
    (compiler-load-embedded-module-id-cache-reset!)
    (set! compiler-load-embedded-equivalence-cache (sym_i64_env.sym-i64-empty))
    (compiler-load-session-state-surface-summaries-reset!
      (compiler-load-session-state-shared-view (& load-state)))
    (compiler-load-session-state-lazy-qualified-observer-reset! load-state)
    (set! (array-ref load-state.surface-summary-load-depth 0) 0)
    (if (compiler-load-session-state-cache-enabled? load-state)
      (begin
        (ci.intern-compat-state-reset-to!
          intern-state
          (compiler-load-session-state-intern-floor-value load-state))
        (ci.intern-compat-state-persistent-arena-reset-to-floor! intern-state))
      (ci.intern-compat-state-reset! intern-state))))

(define (compiler-load-session-state-runtime-prelude-cache-fill!
  [state : CompilerLoadSessionState]
  [index : i64]) : unit
  (if (>= index compiler-load-runtime-prelude-cache-capacity)
    unit
    (begin
      (set!
        (array-ref state.runtime-prelude-cache index)
        (CompilerLoadPreludeCacheEmpty))
      (compiler-load-session-state-runtime-prelude-cache-fill!
        state
        (+ index 1)))))

(define (compiler-load-session-state-runtime-prelude-cache-clear!
  [state : CompilerLoadSessionState]) : unit
  (begin
    (compiler-load-session-state-runtime-prelude-cache-fill!
      (compiler-load-session-state-shared-view (& state))
      0)
    (set! (array-ref state.runtime-prelude-cache-ready 0) true)))

(define (compiler-load-runtime-prelude-cache-clear!) : unit
  (compiler-load-session-state-runtime-prelude-cache-clear!
    (compiler-load-active-session-state-shared-view)))

(define (compiler-load-session-state-runtime-prelude-cache-ensure!
  [state : CompilerLoadSessionState]) : unit
  (if (array-ref state.runtime-prelude-cache-ready 0)
    unit
    (compiler-load-session-state-runtime-prelude-cache-clear! state)))

(define (compiler-load-intern-id-seq-equal?
  [left : (& left CompilerLoadInternIdSeq)]
  [right : (& right CompilerLoadInternIdSeq)]) : bool
  (let
    [count : i64 left.len]
    [same : bool (= count right.len)]
    [index : i64 0]
    (begin
      (while (and same (< index count))
        (begin
          (set!
            same
            (= (array-ref left.slots index) (array-ref right.slots index)))
          (set! index (+ index 1))))
      same)))

;; The copy runs under whichever arena the caller made current, so the cached
;; key's ids land in the same long-lived arena the cons spine used to.
(define (compiler-load-intern-id-seq-copy [ids : CompilerLoadInternIdSeq]) : CompilerLoadInternIdSeq
  (let
    [count : i64 ids.len]
    [slots : (__tl_dyn-array i64) (array.make-array i64 count)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (set! (array-ref slots index) (array-ref ids.slots index))
          (set! index (+ index 1))))
      (CompilerLoadInternIdSeq slots count))))

(define (compiler-load-prelude-cache-key-equal?
  [left : (& left CompilerLoadPreludeCacheKey)]
  [right : (& right CompilerLoadPreludeCacheKey)]) : bool
  (and
    (compiler-load-intern-id-seq-equal? left.root-ids right.root-ids)
    (compiler-load-cfg-key-equal? left.cfgs right.cfgs)))

(define (compiler-load-prelude-cache-key-copy
  [key : CompilerLoadPreludeCacheKey]) : CompilerLoadPreludeCacheKey
  (CompilerLoadPreludeCacheKey
    (compiler-load-intern-id-seq-copy key.root-ids)
    (compiler-load-cfg-key-copy key.cfgs)))

(define (compiler-load-session-state-runtime-prelude-cache-lookup-from
  [state : CompilerLoadSessionState]
  [key : (& key CompilerLoadPreludeCacheKey)]
  [index : i64]) : CompilerLoadPreludeCacheLookup
  (if (>= index compiler-load-runtime-prelude-cache-capacity)
    (CompilerLoadPreludeCacheMiss)
    (match (clone (array-ref state.runtime-prelude-cache index))
      [(CompilerLoadPreludeCacheEmpty) (CompilerLoadPreludeCacheMiss)]
      [(CompilerLoadPreludeCacheFull slot-key decls paths modules seen)
        (if (compiler-load-prelude-cache-key-equal? slot-key key)
          (CompilerLoadPreludeCacheHit decls paths modules seen)
          (compiler-load-session-state-runtime-prelude-cache-lookup-from
            state
            key
            (+ index 1)))])))

(define (compiler-load-session-state-runtime-prelude-cache-lookup
  [state : CompilerLoadSessionState]
  [key : (& key CompilerLoadPreludeCacheKey)]) : CompilerLoadPreludeCacheLookup
  (begin
    (compiler-load-session-state-runtime-prelude-cache-ensure!
      (compiler-load-session-state-shared-view (& state)))
    (compiler-load-session-state-runtime-prelude-cache-lookup-from state key 0)))

(define (compiler-load-session-state-runtime-prelude-cache-store-at
  [state : CompilerLoadSessionState]
  [key : CompilerLoadPreludeCacheKey]
  [decls : ast.AstDeclList]
  [paths : ast.AstDeclPathList]
  [modules : ast.AstDeclModuleList]
  [seen : sym_i64_env.SymI64Env]
  [index : i64]) : unit
  (if (>= index compiler-load-runtime-prelude-cache-capacity)
    unit
    (match (clone (array-ref state.runtime-prelude-cache index))
      [(CompilerLoadPreludeCacheEmpty)
        (set!
          (array-ref state.runtime-prelude-cache index)
          (CompilerLoadPreludeCacheFull key decls paths modules seen))]
      [(CompilerLoadPreludeCacheFull slot-key _ _ _ _)
        (if (compiler-load-prelude-cache-key-equal? slot-key key)
          (set!
            (array-ref state.runtime-prelude-cache index)
            (CompilerLoadPreludeCacheFull key decls paths modules seen))
          (compiler-load-session-state-runtime-prelude-cache-store-at
            state
            key
            decls
            paths
            modules
            seen
            (+ index 1)))])))

(define (compiler-load-session-state-runtime-prelude-cache-store
  [state : CompilerLoadSessionState]
  [key : CompilerLoadPreludeCacheKey]
  [decls : ast.AstDeclList]
  [paths : ast.AstDeclPathList]
  [modules : ast.AstDeclModuleList]
  [seen : sym_i64_env.SymI64Env]) : unit
  (begin
    (compiler-load-session-state-runtime-prelude-cache-ensure!
      (compiler-load-session-state-shared-view (& state)))
    (compiler-load-session-state-runtime-prelude-cache-store-at
      (compiler-load-session-state-shared-view (& state))
      key
      decls
      paths
      modules
      seen
      0)
    (compiler-load-session-state-note-persistent! state)))

(define (compiler-load-session-state-runtime-prelude-cache-store-with-pools
  [state : CompilerLoadSessionState]
  [key : CompilerLoadPreludeCacheKey]
  [decls : ast.AstDeclList]
  [paths : ast.AstDeclPathList]
  [modules : ast.AstDeclModuleList]
  [seen : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]) : unit
  (begin
    (compiler-load-session-state-runtime-prelude-cache-ensure!
      (compiler-load-session-state-shared-view (& state)))
    (compiler-load-session-state-runtime-prelude-cache-store-at
      (compiler-load-session-state-shared-view (& state))
      key
      decls
      paths
      modules
      seen
      0)
    (compiler-load-session-state-note-persistent-with-pools! state pools)))

(define (compiler-load-root-cache-ids-from
  [roots : (& roots svec.Vec)]
  [index : i64]
  [count : i64]) : CompilerLoadInternIdSeq
  (let
    [len : i64
      (if (< index count)
        (- count index)
        0)]
    [slots : (__tl_dyn-array i64) (array.make-array i64 len)]
    [cursor : i64 0]
    (begin
      (while (< cursor len)
        (let
          [root : String
            (compiler-load-normalize-path (svec.get roots (+ index cursor) ""))]
          (begin
            (set! (array-ref slots cursor) (compiler-load-source-path-id root))
            (set! cursor (+ cursor 1)))))
      (CompilerLoadInternIdSeq slots len))))

(define (compiler-load-session-state-runtime-prelude-cache-key
  [state : CompilerLoadSessionState]
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]) : CompilerLoadPreludeCacheKey
  (let
    [effective-roots : svec.Vec (compiler-load-roots-with-env stdlib-roots)]
    [root-ids : CompilerLoadInternIdSeq
      (compiler-load-root-cache-ids-from
        effective-roots
        0
        (svec.len (& effective-roots)))]
    [_persist-root-ids : unit
      (compiler-load-session-state-note-persistent-interns! state)]
    (CompilerLoadPreludeCacheKey root-ids cfgs)))

(define (compiler-load-runtime-prelude-cache-key
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]) : CompilerLoadPreludeCacheKey
  (compiler-load-session-state-runtime-prelude-cache-key
    (compiler-load-active-session-state-shared-view)
    stdlib-roots
    cfgs))

(define (compiler-load-roots-cache-key-from
  [roots : (& roots svec.Vec)]
  [index : i64]
  [count : i64]
  [out : String]) : String
  (if (>= index count)
    out
    (let
      [root : String (svec.get roots index "")]
      (compiler-load-roots-cache-key-from
        roots
        (+ index 1)
        count
        (str_cat.str-cat
          out
          (string.int->string (string.string-length root))
          ":"
          root
          ";")))))

(define (compiler-load-roots-cache-key [roots : (& roots svec.Vec)]) : String
  (compiler-load-roots-cache-key-from roots 0 (svec.len roots) ""))

(define (compiler-load-cfg-cache-key-from
  [cfgs : sym_i64_env.SymI64Env]
  [out : String]) : String
  (match (sym_i64_env.sym-i64-view cfgs)
    [(sym_i64_env.SymI64ViewNil) out]
    [(sym_i64_env.SymI64ViewBind key value rest)
      (if (< key 0)
        (compiler-load-cfg-cache-key-from rest out)
        (compiler-load-cfg-cache-key-from
          rest
          (str_cat.str-cat
            out
            (cfg_core.compiler-cfg-key-name key)
            "="
            (string.int->string value)
            ";")))]))

(define (compiler-load-cfg-cache-key [cfgs : sym_i64_env.SymI64Env]) : String
  (compiler-load-cfg-cache-key-from cfgs ""))

(define (compiler-load-prelude-cache-key
  [kind : String]
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]) : String
  (let
    [effective-roots : svec.Vec (compiler-load-roots-with-env stdlib-roots)]
    (str_cat.str-cat
      kind
      "|roots:"
      (compiler-load-roots-cache-key effective-roots)
      "|cfg:"
      (compiler-load-cfg-cache-key cfgs))))

(define (compiler-load-session-state-program-cache-key-id
  [state : CompilerLoadSessionState]
  [kind : CompilerLoadProgramSourceKind]
  [path-id : i64]
  [cfgs : sym_i64_env.SymI64Env]) : CompilerLoadProgramCacheKey
  (let
    [_persist-path-id : unit
      (compiler-load-session-state-note-persistent-interns! state)]
    (CompilerLoadProgramCacheKey kind path-id cfgs)))

(define (compiler-load-program-cache-key-id
  [kind : CompilerLoadProgramSourceKind]
  [path-id : i64]
  [cfgs : sym_i64_env.SymI64Env]) : CompilerLoadProgramCacheKey
  (compiler-load-session-state-program-cache-key-id
    (compiler-load-active-session-state-shared-view)
    kind
    path-id
    cfgs))

(define (compiler-load-char-code-at [text : (& text str)] [idx : i64]) : i64
  (cast (string.string-ref text idx) : i64))

(define (compiler-load-path-separator? [c : char]) : bool
  (fs.path-separator? c))

(define (compiler-load-absolute-path? [path : (& path str)]) : bool
  (fs.path-absolute? path))

(define (compiler-load-dirname [path : (& path str)]) : String
  (let
    [n : i64 (string.string-length path)]
    [i : i64 0]
    [last : i64 -1]
    (begin
      (while (< i n)
        (begin
          (if (compiler-load-path-separator? (string.string-ref path i))
            (set! last i)
            (set! last last))
          (set! i (+ i 1))))
      (if (< last 0)
        ""
        (string.substring path 0 (+ last 1))))))

(define (compiler-load-join-import-path
  [importer-path : String]
  [import-path : String]) : String
  (if (compiler-load-absolute-path? import-path)
    import-path
    (str_cat.str-cat (compiler-load-dirname importer-path) import-path)))

(define (compiler-load-normalize-path [path : (& path str)]) : String
  (fs.path-normalize path))

(define (compiler-load-safe-relative? [path : (& path str)]) : bool
  (fs.path-safe-relative? path))

(define (compiler-load-string-prefix-at?
  [text : (& text str)]
  [prefix : (& prefix str)]
  [start : i64]) : bool
  (let
    [text-len : i64 (string.string-length text)]
    [prefix-len : i64 (string.string-length prefix)]
    (if (< start 0)
      false
      (if (> (+ start prefix-len) text-len)
        false
        (let
          [i : i64 0]
          [ok : bool true]
          (begin
            (while ok
              (if (< i prefix-len)
                (if (=
                  (compiler-load-char-code-at text (+ start i))
                  (compiler-load-char-code-at prefix i))
                  (set! i (+ i 1))
                  (set! ok false))
                (set! ok false)))
            (= i prefix-len)))))))

(define (compiler-load-string-contains-from?
  [text : (& text str)]
  [needle : (& needle str)]
  [start : i64]) : bool
  (let
    [text-len : i64 (string.string-length text)]
    [needle-len : i64 (string.string-length needle)]
    [i : i64 start]
    [found : bool false]
    (begin
      (while (and (not found) (<= (+ i needle-len) text-len))
        (if (compiler-load-string-prefix-at? text needle i)
          (set! found true)
          (set! i (+ i 1))))
      found)))

(define (compiler-load-string-contains?
  [text : (& text str)]
  [needle : (& needle str)]) : bool
  (compiler-load-string-contains-from? text needle 0))

(define (compiler-load-lazy-env-disabled? [name : String]) : bool
  (match (env.get (& name))
    [(env.EnvSomeString value)
      (or
        (string.eq value "0")
        (string.eq value "false")
        (string.eq value "off"))]
    [(env.EnvNoString) false]))

(define (compiler-load-session-state-lazy-import-mode-enabled?
  [state : CompilerLoadSessionState]) : bool
  (array-ref state.cache-enabled 2))

(define (compiler-load-session-lazy-import-mode-enabled?) : bool
  (compiler-load-session-state-lazy-import-mode-enabled?
    (compiler-load-active-session-state-shared-view)))

(define (compiler-load-session-state-lazy-import-mode-set-enabled!
  [state : CompilerLoadSessionState]
  [enabled : bool]) : unit
  (set! (array-ref state.cache-enabled 2) enabled))

(define (compiler-load-session-lazy-import-mode-set-enabled! [enabled : bool]) : unit
  (compiler-load-session-state-lazy-import-mode-set-enabled!
    (compiler-load-active-session-state-shared-view)
    enabled))

(define (compiler-load-session-state-lazy-imports-enabled?
  [state : CompilerLoadSessionState]) : bool
  (and
    (compiler-load-session-state-lazy-import-mode-enabled? state)
    (not
      (or
        (compiler-load-lazy-env-disabled? "TYPELISP_LAZY_IMPORTS")
        (compiler-load-lazy-env-disabled? "TYPELISP_LAZY_DOTTED_IMPORTS")))))

(define (compiler-load-prelude-importer? [path : String]) : bool
  (let
    [normalized : String (compiler-load-normalize-path path)]
    (or
      (string.eq normalized (compiler-load-normalize-path "stdlib/runtime.tl"))
      (string.eq
        normalized
        (compiler-load-normalize-path
          (string.copy (& compiler-load-core-macro-prelude-path)))))))

(define (compiler-load-stdlib-import? [path : (& path str)]) : bool
  (or
    (compiler-load-string-prefix-at? path "stdlib/" 0)
    (compiler-load-string-prefix-at? path "stdlib\\" 0)))

(define (compiler-load-stdlib-test-import? [path : (& path str)]) : bool
  (or
    (compiler-load-string-prefix-at? path "stdlib/tests/" 0)
    (compiler-load-string-prefix-at? path "stdlib\\tests\\" 0)))

(define (compiler-load-stdlib-source-module-import? [path : (& path str)]) : bool
  (and
    (compiler-load-stdlib-import? path)
    (not (compiler-load-stdlib-test-import? path))))

(define (compiler-load-stdlib-suffix [path : (& path str)]) : String
  (string.substring path 7 (- (string.string-length path) 7)))

(define (compiler-load-join-root-path [root : String] [suffix : String]) : String
  (let
    [n : i64 (string.string-length root)]
    (if (= n 0)
      suffix
      (let
        [last : char (string.string-ref root (- n 1))]
        (if (compiler-load-path-separator? last)
          (str_cat.str-cat root suffix)
          (str_cat.str-cat root "/" suffix))))))

(define (compiler-load-string-vec-push-copy [roots : svec.Vec] [root : String]) : svec.Vec
  (let
    [next-roots : svec.Vec (owned_view.compiler-owned-shared-view roots)]
    (begin
      (svec.push-ref! (&mut next-roots) root)
      next-roots)))

(define (compiler-load-string-vec-one [root : String]) : svec.Vec
  (compiler-load-string-vec-push-copy (svec.new) root))

(define (compiler-load-string-vec-two [left : String] [right : String]) : svec.Vec
  (compiler-load-string-vec-push-copy (compiler-load-string-vec-one left) right))

(define (compiler-load-roots-with-env [roots : svec.Vec]) : svec.Vec
  (let
    [name : String "TYPELISP_STDLIB_ROOT"]
    (match (env.get (& name))
      [(env.EnvNoString) roots]
      [(env.EnvSomeString root)
        (if (= (string.string-length root) 0)
          roots
          (compiler-load-string-vec-push-copy roots root))])))

(define (compiler-load-stdlib-root-configured? [roots : svec.Vec]) : bool
  (let
    [effective-roots : svec.Vec (compiler-load-roots-with-env roots)]
    (> (svec.len (& effective-roots)) 0)))

(define (compiler-load-cache-root-prefix [root : String]) : String
  (compiler-load-join-root-path (compiler-load-normalize-path root) ""))

(define (compiler-load-cache-path-under-root?
  [normalized-path : (& normalized-path str)]
  [root : String]) : bool
  (if (= (string.string-length root) 0)
    false
    (compiler-load-string-prefix-at?
      normalized-path
      (compiler-load-cache-root-prefix root)
      0)))

(define (compiler-load-path-under-roots-from?
  [normalized-path : (& normalized-path str)]
  [roots : svec.Vec]
  [index : i64]
  [count : i64]) : bool
  (if (>= index count)
    false
    (if (compiler-load-cache-path-under-root?
      normalized-path
      (svec.get (& roots) index ""))
      true
      (compiler-load-path-under-roots-from?
        normalized-path
        roots
        (+ index 1)
        count))))

(define (compiler-load-session-file-cacheable?
  [path : String]
  [_stdlib-roots : svec.Vec]) : bool
  ;; Entry files opt out before this helper. Resolved import files are safe to
  ;; cache by path + cfg, including local and package-owned modules.
  (> (string.string-length (compiler-load-normalize-path path)) 0))

(define (compiler-load-session-file-cache-immediate?
  [path : String]
  [stdlib-roots : svec.Vec]) : bool
  (let
    [normalized : String (compiler-load-normalize-path path)]
    (if (compiler-load-stdlib-import? normalized)
      true
      (let
        [effective-roots : svec.Vec (compiler-load-roots-with-env stdlib-roots)]
        (compiler-load-path-under-roots-from?
          normalized
          (ast.ast-place-shared-view effective-roots)
          0
          (svec.len (& effective-roots)))))))

(define (compiler-load-resolve-stdlib-root-raw
  [suffix : String]
  [roots : svec.Vec]) : CompilerLoadMaybePath
  (if (compiler-load-safe-relative? suffix)
    (let
      [i : i64 0]
      [n : i64 (svec.len (& roots))]
      [found : bool false]
      [found-path : String ""]
      (begin
        (while (and (not found) (< i n))
          (let
            [root : String (svec.get (& roots) i "")]
            [candidate : String
              (compiler-load-join-root-path root (clone suffix))]
            (if (io.file-exists? (clone candidate))
              (begin
                (set! found true)
                (set! found-path candidate))
              (set! i (+ i 1)))))
        (if found
          (CompilerLoadSomePath found-path)
          (CompilerLoadNoPath))))
    (CompilerLoadNoPath)))

(define (compiler-load-resolve-stdlib-root [suffix : String] [roots : svec.Vec]) : CompilerLoadMaybePath
  (compiler-load-resolve-stdlib-root-raw
    suffix
    (compiler-load-roots-with-env roots)))

(define (compiler-load-embedded-stdlib-source [suffix : String]) : ces.CompilerEmbeddedStdlibSource
  (if (compiler-load-safe-relative? suffix)
    (ces.compiler-embedded-stdlib-lookup suffix)
    (ces.CompilerEmbeddedStdlibSource.CompilerEmbeddedStdlibNoSource)))

(define (compiler-load-embedded-stdlib-path [suffix : String]) : CompilerLoadMaybePath
  (match (compiler-load-embedded-stdlib-source (clone suffix))
    [(ces.CompilerEmbeddedStdlibSource.CompilerEmbeddedStdlibSomeSource _)
      (CompilerLoadSomePath (str_cat.str-cat "stdlib/" suffix))]
    [(ces.CompilerEmbeddedStdlibSource.CompilerEmbeddedStdlibNoSource)
      (CompilerLoadNoPath)]))

(define (compiler-load-embedded-stdlib-source-for-path [path : String]) : ces.CompilerEmbeddedStdlibSource
  (if (compiler-load-stdlib-import? path)
    (compiler-load-embedded-stdlib-source (compiler-load-stdlib-suffix path))
    (ces.CompilerEmbeddedStdlibSource.CompilerEmbeddedStdlibNoSource)))

(define (compiler-load-resolve-import-with-roots
  [importer-path : String]
  [import-path : String]
  [stdlib-roots : svec.Vec]) : String
  (match (compiler-load-resolve-import-result-with-roots
    (clone importer-path)
    (clone import-path)
    (clone stdlib-roots))
    [(ResultPkgResolve.Ok resolved) resolved]
    [(ResultPkgResolve.Err _) import-path]))

(define (compiler-load-resolve-import-result-with-roots
  [importer-path : String]
  [import-path : String]
  [stdlib-roots : svec.Vec]) : ResultPkgResolve
  (if (compiler-load-pkg-import? (clone import-path))
    (compiler-load-resolve-pkg-import-from-disk importer-path import-path)
    (let
      [primary : String
        (compiler-load-join-import-path
          (clone importer-path)
          (clone import-path))]
      [resolved : String
        (if (io.file-exists? (clone primary))
          primary
          (if (compiler-load-stdlib-import? import-path)
            (let
              [suffix : String
                (compiler-load-stdlib-suffix (clone import-path))]
              (match (compiler-load-resolve-stdlib-root
                (clone suffix)
                stdlib-roots)
                [(CompilerLoadSomePath root-path) root-path]
                [(CompilerLoadNoPath)
                  (if (io.file-exists? (clone import-path))
                    import-path
                    (match (compiler-load-embedded-stdlib-path suffix)
                      [(CompilerLoadSomePath embedded-path) embedded-path]
                      [(CompilerLoadNoPath) primary]))]))
            primary))]
      (ResultPkgResolve.Ok (compiler-load-normalize-path resolved)))))

(define (compiler-load-session-state-dotted-path-cache-clear-ready!
  [state : CompilerLoadSessionState]
  [index : i64]) : unit
  (if (>= index compiler-load-dotted-path-cache-capacity)
    unit
    (begin
      (set! (array-ref state.dotted-path-cache-ready index) false)
      (compiler-load-session-state-dotted-path-cache-clear-ready!
        state
        (+ index 1)))))

(define (compiler-load-session-state-dotted-path-cache-reset!
  [state : CompilerLoadSessionState]) : unit
  (begin
    (compiler-load-session-state-dotted-path-cache-clear-ready!
      (compiler-load-session-state-shared-view (& state))
      0)
    (set!
      (array-ref state.dotted-path-cache-generation 0)
      (ci.intern-generation))))

(define (compiler-load-dotted-path-cache-reset!) : unit
  (compiler-load-session-state-dotted-path-cache-reset!
    (compiler-load-active-session-state-shared-view)))

(define (compiler-load-session-state-dotted-path-cache-ensure!
  [state : CompilerLoadSessionState]) : unit
  (if (=
    (array-ref state.dotted-path-cache-generation 0)
    (ci.intern-generation))
    unit
    (compiler-load-session-state-dotted-path-cache-reset! state)))

(define (compiler-load-dotted-path-cache-bucket [module-id : i64]) : i64
  (bit-and module-id (- compiler-load-dotted-path-cache-capacity 1)))

(define (compiler-load-session-state-dotted-path-cache-lookup
  [state : CompilerLoadSessionState]
  [module-id : i64]) : CompilerLoadMaybeString
  (let
    [bucket : i64 (compiler-load-dotted-path-cache-bucket module-id)]
    (if (if (array-ref state.dotted-path-cache-ready bucket)
      (= (array-ref state.dotted-path-cache-keys bucket) module-id)
      false)
      (CompilerLoadSomeString
        (clone (array-ref state.dotted-path-cache-values bucket)))
      (CompilerLoadNoString))))

(define (compiler-load-dotted-path-cache-lookup [module-id : i64]) : CompilerLoadMaybeString
  (compiler-load-session-state-dotted-path-cache-lookup
    (compiler-load-active-session-state-shared-view)
    module-id))

(define (compiler-load-session-state-dotted-path-cache-store!
  [state : CompilerLoadSessionState]
  [module-id : i64]
  [path : String]) : unit
  (let
    [bucket : i64 (compiler-load-dotted-path-cache-bucket module-id)]
    (begin
      (set! (array-ref state.dotted-path-cache-ready bucket) true)
      (set! (array-ref state.dotted-path-cache-keys bucket) module-id)
      (set! (array-ref state.dotted-path-cache-values bucket) path))))

(define (compiler-load-dotted-module-path-uncached [module-name : String]) : String
  (let
    [n : i64 (string.string-length module-name)]
    [i : i64 0]
    [out : String ""]
    (begin
      (while (< i n)
        (begin
          (if (string.char-eq (string.string-ref module-name i) '.')
            (set! out (str_cat.str-cat out "/" ""))
            (set!
              out
              (str_cat.str-cat out (string.substring module-name i 1) "")))
          (set! i (+ i 1))))
      (str_cat.str-cat out ".tl" ""))))

(define (compiler-load-session-state-dotted-module-path-id
  [state : CompilerLoadSessionState]
  [module-id : i64]
  [module-name : String]) : String
  (begin
    (compiler-load-session-state-dotted-path-cache-ensure!
      (compiler-load-session-state-shared-view (& state)))
    (match (compiler-load-session-state-dotted-path-cache-lookup
      (compiler-load-session-state-shared-view (& state))
      module-id)
      [(CompilerLoadSomeString path) path]
      [(CompilerLoadNoString)
        ;; Cache values must never point into an arena a caller can rewind
        ;; (a top-level `with-arena` can mark/reset the pool base arena, and
        ;; the next request would read the freed path back on a cache hit),
        ;; so allocate them in the never-reset provenance arena.
        (in-arena
          (arena.Arena (compiler-load-provenance-arena))
          (let
            [path : String
              (compiler-load-dotted-module-path-uncached module-name)]
            (begin
              (compiler-load-session-state-dotted-path-cache-store!
                (compiler-load-session-state-shared-view (& state))
                module-id
                (clone path))
              path)))])))

(define (compiler-load-dotted-module-path-id
  [module-id : i64]
  [module-name : String]) : String
  (compiler-load-session-state-dotted-module-path-id
    (compiler-load-active-session-state-shared-view)
    module-id
    module-name))

(define (compiler-load-dotted-module-path [module-name : String]) : String
  (compiler-load-dotted-module-path-uncached module-name))

(define (compiler-load-dotted-module-path-from-ast
  [module-name : String]
  [expected-module : ast.AstMaybeModuleName]) : String
  (match expected-module
    [(ast.AstMaybeModuleName.Some module-id)
      (compiler-load-dotted-module-path-id module-id module-name)]
    [(ast.AstMaybeModuleName.No)
      (compiler-load-dotted-module-path-uncached module-name)]))

(define (compiler-load-dotted-module-first-len [module-name : String]) : i64
  (let
    [n : i64 (string.string-length module-name)]
    [i : i64 0]
    [done : bool false]
    (begin
      (while (and (not done) (< i n))
        (if (string.char-eq (string.string-ref module-name i) '.')
          (set! done true)
          (set! i (+ i 1))))
      i)))

(define (compiler-load-dotted-module-first [module-name : String]) : String
  (let
    [first-len : i64
      (compiler-load-dotted-module-first-len (clone module-name))]
    (string.substring module-name 0 first-len)))

(define (compiler-load-dotted-module-rest
  [module-name : String]
  [first-len : i64]) : String
  (let
    [n : i64 (string.string-length module-name)]
    [rest-start : i64 (+ first-len 1)]
    (if (>= rest-start n)
      ""
      (string.substring module-name rest-start (- n rest-start)))))

(define (compiler-load-dotted-module-last-dot [module-name : String]) : i64
  (let
    [index : i64 (- (string.string-length module-name) 1)]
    [found : i64 -1]
    (begin
      (while (and (< found 0) (>= index 0))
        (if (string.char-eq (string.string-ref module-name index) '.')
          (set! found index)
          (set! index (- index 1))))
      found)))

(define (compiler-load-resolved-source-exists? [path : String]) : bool
  (or
    (io.file-exists? (owned_view.compiler-owned-shared-view path))
    (match (compiler-load-embedded-stdlib-source-for-path
      (owned_view.compiler-owned-shared-view path))
      [(ces.CompilerEmbeddedStdlibSource.CompilerEmbeddedStdlibSomeSource _)
        true]
      [(ces.CompilerEmbeddedStdlibSource.CompilerEmbeddedStdlibNoSource) false])))

(define (compiler-load-import-module-id [module-name : String]) : i64
  (compiler-load-parse-context-name-id module-name))

(define (compiler-load-selected-item-id
  [expected-module : ast.AstMaybeModuleName]
  [fallback : String]) : i64
  (match expected-module
    [(ast.AstMaybeModuleName.Some full-import-id)
      (ci.intern-dotted-final-id full-import-id)]
    [(ast.AstMaybeModuleName.No) (compiler-load-import-module-id fallback)]))

(define (compiler-load-resolved-import
  [resolved : String]
  [kind : ast.AstImportKind]
  [module-name : String]
  [alias : ast.AstMaybeImportAlias]) : ResultCompilerLoadResolvedImport
  (let
    [module-id : i64
      (compiler-load-import-module-id
        (owned_view.compiler-owned-shared-view module-name))]
    (ResultCompilerLoadResolvedImport.Ok
      (CompilerLoadResolvedImport
        resolved
        kind
        module-name
        (ast.AstMaybeModuleName.Some module-id)
        alias))))

(define (compiler-load-invalid-selected-import-message
  [import-path : String]
  [module-name : String]) : String
  (str_cat.str-cat
    "compiler-load: import '"
    import-path
    (str_cat.str-cat
      "' leaves more than one segment after loadable module '"
      module-name
      "'; only one selected item is supported")))

(define (compiler-load-resolve-stdlib-module-path
  [module-path : String]
  [stdlib-roots : svec.Vec]) : String
  (let
    [suffix : String (compiler-load-stdlib-suffix (clone module-path))]
    (if (io.file-exists? (clone module-path))
      (begin
        (compiler-load-note-embedded-equivalent-if-matching!
          suffix
          (clone module-path))
        (clone module-path))
      (match (compiler-load-resolve-stdlib-root (clone suffix) stdlib-roots)
        [(CompilerLoadSomePath root-path)
          (begin
            (compiler-load-note-embedded-equivalent-if-matching!
              suffix
              (clone root-path))
            root-path)]
        [(CompilerLoadNoPath)
          (match (compiler-load-embedded-stdlib-path suffix)
            [(CompilerLoadSomePath embedded-path) embedded-path]
            [(CompilerLoadNoPath) module-path])]))))

(define (compiler-load-resolve-root-module-path
  [module-path : String]
  [stdlib-roots : svec.Vec]) : CompilerLoadMaybePath
  (compiler-load-resolve-stdlib-root-raw module-path stdlib-roots))

(define (compiler-load-nested-import-root? [root : (& root str)]) : bool
  (or
    (compiler-load-string-contains? root "/")
    (compiler-load-string-contains? root "\\")))

(define (compiler-load-resolve-module-path-with-roots
  [importer-path : String]
  [import-root : String]
  [module-path : String]
  [stdlib-roots : svec.Vec]) : ResultPkgResolve
  (if (compiler-load-stdlib-import? module-path)
    (ResultPkgResolve.Ok
      (compiler-load-resolve-stdlib-module-path module-path stdlib-roots))
    (let
      [root-primary : String
        (compiler-load-normalize-path
          (compiler-load-join-root-path (clone import-root) (clone module-path)))]
      (if (compiler-load-nested-import-root? import-root)
        (if (io.file-exists? (clone root-primary))
          (ResultPkgResolve.Ok root-primary)
          (let
            [importer-dir : String (compiler-load-dirname importer-path)]
            [importer-primary : String
              (compiler-load-normalize-path
                (compiler-load-join-root-path
                  (clone importer-dir)
                  (clone module-path)))]
            (if (and
              (not (string.eq importer-dir import-root))
              (compiler-load-nested-import-root? importer-dir)
              (io.file-exists? (clone importer-primary)))
              (ResultPkgResolve.Ok importer-primary)
              (match (compiler-load-resolve-root-module-path
                module-path
                stdlib-roots)
                [(CompilerLoadSomePath root-path)
                  (ResultPkgResolve.Ok root-path)]
                [(CompilerLoadNoPath) (ResultPkgResolve.Ok root-primary)]))))
        (match (compiler-load-resolve-root-module-path module-path stdlib-roots)
          [(CompilerLoadSomePath root-path) (ResultPkgResolve.Ok root-path)]
          [(CompilerLoadNoPath) (ResultPkgResolve.Ok root-primary)])))))

(define (compiler-load-resolve-module-import-with-roots
  [importer-path : String]
  [import-root : String]
  [module-name : String]
  [stdlib-roots : svec.Vec]) : ResultPkgResolve
  (compiler-load-resolve-module-path-with-roots
    importer-path
    import-root
    (compiler-load-dotted-module-path-uncached module-name)
    stdlib-roots))

(define (compiler-load-resolve-dotted-import-spec-with-roots
  [importer-path : String]
  [import-root : String]
  [import-path : String]
  [expected-module : ast.AstMaybeModuleName]
  [stdlib-roots : svec.Vec]) : ResultPkgResolve
  (let
    [module-path : String
      (compiler-load-dotted-module-path-from-ast
        (clone import-path)
        expected-module)]
    [first-len : i64
      (compiler-load-dotted-module-first-len (clone import-path))]
    [first : String (string.substring (clone import-path) 0 first-len)]
    [rest : String
      (compiler-load-dotted-module-rest (clone import-path) first-len)]
    (if (or
      (compiler-load-stdlib-import? (clone module-path))
      (= (string.string-length rest) 0))
      ;; stdlib or a bare single-segment (local) import: local/roots resolution.
      (compiler-load-resolve-module-path-with-roots
        importer-path
        import-root
        module-path
        stdlib-roots)
      ;; A nested dotted import whose first segment may be a package alias:
      ;; consult the nearest manifest's deps before local/roots resolution so
      ;; dependency sources can import their own dependencies (#2453).
      (match (compiler-load-discover-manifest (clone importer-path))
        [(CompilerLoadNoPath)
          (compiler-load-resolve-module-path-with-roots
            importer-path
            import-root
            module-path
            stdlib-roots)]
        [(CompilerLoadSomePath manifest-path)
          (match (compiler-load-parse-manifest-diagnostic
            (clone manifest-path)
            (compiler-load-read-file-text manifest-path))
            [(ResultCompilerPkgManifestDiagnostic.Err _)
              (compiler-load-resolve-module-path-with-roots
                importer-path
                import-root
                module-path
                stdlib-roots)]
            [(ResultCompilerPkgManifestDiagnostic.Ok manifest)
              (match (compiler-load-pkg-dep-lookup manifest.deps (clone first))
                [(CompilerLoadNoPath)
                  (compiler-load-resolve-module-path-with-roots
                    importer-path
                    import-root
                    module-path
                    stdlib-roots)]
                [(CompilerLoadSomePath dep-path)
                  (if (compiler-load-github-dependency-path? (clone dep-path))
                    (ResultPkgResolve.Err
                      (str_cat.str-cat
                        "compiler-load: GitHub dependency '"
                        first
                        "' requires fetch support: "
                        import-path))
                    (ResultPkgResolve.Ok
                      (compiler-load-normalize-path
                        (compiler-load-join-root-path
                          (compiler-load-join-root-path
                            (compiler-load-dirname manifest-path)
                            dep-path)
                          (compiler-load-dotted-module-path-uncached rest)))))])])]))))

(define (compiler-load-resolve-import-spec-with-roots
  [importer-path : String]
  [import-root : String]
  [kind : ast.AstImportKind]
  [import-path : String]
  [expected-module : ast.AstMaybeModuleName]
  [stdlib-roots : svec.Vec]) : ResultPkgResolve
  (match kind
    [(ast.AstImportKind.Module)
      (compiler-load-resolve-dotted-import-spec-with-roots
        importer-path
        import-root
        import-path
        expected-module
        stdlib-roots)]
    [(ast.AstImportKind.ModuleAll)
      (compiler-load-resolve-dotted-import-spec-with-roots
        importer-path
        import-root
        import-path
        expected-module
        stdlib-roots)]
    [(ast.AstImportKind.ModuleItem _)
      (compiler-load-resolve-dotted-import-spec-with-roots
        importer-path
        import-root
        import-path
        expected-module
        stdlib-roots)]
    [(ast.AstImportKind.Macro _ _)
      (ResultPkgResolve.Err
        "compiler-load: module macro imports must be expanded before import resolution")]
    [(ast.AstImportKind.MacroDecls _ _)
      (ResultPkgResolve.Err
        "compiler-load: module macro imports must be expanded before import resolution")]))

(define (compiler-load-search-import-prefix-with-roots
  [importer-path : String]
  [import-root : String]
  [original-import-path : String]
  [candidate : String]
  [selected-item : i64]
  [remaining-segments : i64]
  [alias : ast.AstMaybeImportAlias]
  [stdlib-roots : svec.Vec]) : ResultCompilerLoadResolvedImport
  (let
    [candidate-id : i64
      (compiler-load-import-module-id
        (owned_view.compiler-owned-shared-view candidate))]
    (match (compiler-load-resolve-dotted-import-spec-with-roots
      (owned_view.compiler-owned-shared-view importer-path)
      (owned_view.compiler-owned-shared-view import-root)
      (owned_view.compiler-owned-shared-view candidate)
      (ast.AstMaybeModuleName.Some candidate-id)
      (owned_view.compiler-owned-shared-view stdlib-roots))
      [(ResultPkgResolve.Ok resolved)
        (if (compiler-load-resolved-source-exists?
          (owned_view.compiler-owned-shared-view resolved))
          (if (= remaining-segments 1)
            (compiler-load-resolved-import
              resolved
              (ast.AstImportKind.ModuleItem selected-item)
              candidate
              alias)
            (ResultCompilerLoadResolvedImport.Err
              (compiler-load-invalid-selected-import-message
                original-import-path
                candidate)))
          (let
            [dot : i64
              (compiler-load-dotted-module-last-dot
                (owned_view.compiler-owned-shared-view candidate))]
            (if (< dot 0)
              (ResultCompilerLoadResolvedImport.Err "")
              (compiler-load-search-import-prefix-with-roots
                importer-path
                import-root
                original-import-path
                (string.substring candidate 0 dot)
                selected-item
                (+ remaining-segments 1)
                alias
                stdlib-roots))))]
      [(ResultPkgResolve.Err _)
        (let
          [dot : i64
            (compiler-load-dotted-module-last-dot
              (owned_view.compiler-owned-shared-view candidate))]
          (if (< dot 0)
            (ResultCompilerLoadResolvedImport.Err "")
            (compiler-load-search-import-prefix-with-roots
              importer-path
              import-root
              original-import-path
              (string.substring candidate 0 dot)
              selected-item
              (+ remaining-segments 1)
              alias
              stdlib-roots)))])))

(define (compiler-load-resolve-import-spec-with-roots-classified
  [importer-path : String]
  [import-root : String]
  [kind : ast.AstImportKind]
  [import-path : String]
  [expected-module : ast.AstMaybeModuleName]
  [alias : ast.AstMaybeImportAlias]
  [stdlib-roots : svec.Vec]) : ResultCompilerLoadResolvedImport
  (match kind
    [(ast.AstImportKind.ModuleAll)
      (match (compiler-load-resolve-dotted-import-spec-with-roots
        (owned_view.compiler-owned-shared-view importer-path)
        (owned_view.compiler-owned-shared-view import-root)
        (owned_view.compiler-owned-shared-view import-path)
        (owned_view.compiler-owned-shared-view expected-module)
        (owned_view.compiler-owned-shared-view stdlib-roots))
        [(ResultPkgResolve.Ok resolved)
          (compiler-load-resolved-import
            resolved
            ast.AstImportKind.ModuleAll
            import-path
            alias)]
        [(ResultPkgResolve.Err message)
          (ResultCompilerLoadResolvedImport.Err message)])]
    [(ast.AstImportKind.ModuleItem _)
      (match (compiler-load-resolve-dotted-import-spec-with-roots
        (owned_view.compiler-owned-shared-view importer-path)
        (owned_view.compiler-owned-shared-view import-root)
        (owned_view.compiler-owned-shared-view import-path)
        (owned_view.compiler-owned-shared-view expected-module)
        (owned_view.compiler-owned-shared-view stdlib-roots))
        [(ResultPkgResolve.Ok resolved)
          (compiler-load-resolved-import resolved kind import-path alias)]
        [(ResultPkgResolve.Err message)
          (ResultCompilerLoadResolvedImport.Err message)])]
    [(ast.AstImportKind.Module)
      (let
        [original : ResultPkgResolve
          (compiler-load-resolve-dotted-import-spec-with-roots
            (owned_view.compiler-owned-shared-view importer-path)
            (owned_view.compiler-owned-shared-view import-root)
            (owned_view.compiler-owned-shared-view import-path)
            (owned_view.compiler-owned-shared-view expected-module)
            (owned_view.compiler-owned-shared-view stdlib-roots))]
        (match original
          [(ResultPkgResolve.Ok resolved)
            (if (compiler-load-resolved-source-exists?
              (owned_view.compiler-owned-shared-view resolved))
              (compiler-load-resolved-import
                resolved
                ast.AstImportKind.Module
                import-path
                alias)
              (let
                [dot : i64
                  (compiler-load-dotted-module-last-dot
                    (owned_view.compiler-owned-shared-view import-path))]
                (if (< dot 0)
                  (compiler-load-resolved-import
                    resolved
                    ast.AstImportKind.Module
                    import-path
                    alias)
                  (let
                    [item-text : String
                      (string.substring
                        (owned_view.compiler-owned-shared-view import-path)
                        (+ dot 1)
                        (-
                          (string.string-length
                            (owned_view.compiler-owned-shared-view import-path))
                          (+ dot 1)))]
                    (match (compiler-load-search-import-prefix-with-roots
                      (owned_view.compiler-owned-shared-view importer-path)
                      (owned_view.compiler-owned-shared-view import-root)
                      (owned_view.compiler-owned-shared-view import-path)
                      (string.substring
                        (owned_view.compiler-owned-shared-view import-path)
                        0
                        dot)
                      (compiler-load-selected-item-id expected-module item-text)
                      1
                      (owned_view.compiler-owned-shared-view alias)
                      (owned_view.compiler-owned-shared-view stdlib-roots))
                      [(ResultCompilerLoadResolvedImport.Ok selected)
                        (ResultCompilerLoadResolvedImport.Ok selected)]
                      [(ResultCompilerLoadResolvedImport.Err message)
                        (if (=
                          (string.string-length
                            (owned_view.compiler-owned-shared-view message))
                          0)
                          (compiler-load-resolved-import
                            resolved
                            ast.AstImportKind.Module
                            import-path
                            alias)
                          (ResultCompilerLoadResolvedImport.Err message))])))))]
          [(ResultPkgResolve.Err original-message)
            (let
              [dot : i64
                (compiler-load-dotted-module-last-dot
                  (owned_view.compiler-owned-shared-view import-path))]
              (if (< dot 0)
                (ResultCompilerLoadResolvedImport.Err original-message)
                (let
                  [item-text : String
                    (string.substring
                      (owned_view.compiler-owned-shared-view import-path)
                      (+ dot 1)
                      (-
                        (string.string-length
                          (owned_view.compiler-owned-shared-view import-path))
                        (+ dot 1)))]
                  (match (compiler-load-search-import-prefix-with-roots
                    (owned_view.compiler-owned-shared-view importer-path)
                    (owned_view.compiler-owned-shared-view import-root)
                    (owned_view.compiler-owned-shared-view import-path)
                    (string.substring
                      (owned_view.compiler-owned-shared-view import-path)
                      0
                      dot)
                    (compiler-load-selected-item-id expected-module item-text)
                    1
                    alias
                    stdlib-roots)
                    [(ResultCompilerLoadResolvedImport.Ok selected)
                      (ResultCompilerLoadResolvedImport.Ok selected)]
                    [(ResultCompilerLoadResolvedImport.Err message)
                      (if (=
                        (string.string-length
                          (owned_view.compiler-owned-shared-view message))
                        0)
                        (ResultCompilerLoadResolvedImport.Err original-message)
                        (ResultCompilerLoadResolvedImport.Err message))]))))]))]
    [(ast.AstImportKind.Macro _ _)
      (ResultCompilerLoadResolvedImport.Err
        "compiler-load: module macro imports must be expanded before import resolution")]
    [(ast.AstImportKind.MacroDecls _ _)
      (ResultCompilerLoadResolvedImport.Err
        "compiler-load: module macro imports must be expanded before import resolution")]))

(define (compiler-load-resolve-package-module-import
  [module-name : String]
  [expected-module : ast.AstMaybeModuleName]
  [importer-path : String]
  [manifest-dir : String]
  [deps : CompilerPkgDeps]
  [stdlib-roots : svec.Vec]) : ResultPkgResolve
  (let
    [first-len : i64
      (compiler-load-dotted-module-first-len (clone module-name))]
    [first : String (string.substring module-name 0 first-len)]
    [module-path : String
      (compiler-load-dotted-module-path-from-ast
        (clone module-name)
        expected-module)]
    (if (compiler-load-stdlib-import? (clone module-path))
      (ResultPkgResolve.Ok
        (compiler-load-resolve-stdlib-module-path module-path stdlib-roots))
      (let
        [rest : String
          (compiler-load-dotted-module-rest (clone module-name) first-len)]
        [importer-dir : String (compiler-load-dirname importer-path)]
        [primary : String
          (compiler-load-normalize-path
            (compiler-load-join-root-path
              (clone importer-dir)
              (clone module-path)))]
        [fallback : String
          (compiler-load-normalize-path
            (compiler-load-join-root-path
              (clone manifest-dir)
              (clone module-path)))]
        (if (= (string.string-length rest) 0)
          ;; A bare single-segment import names a local module first; the
          ;; package alias only disambiguates nested paths.
          (if (and
            (compiler-load-nested-import-root? importer-dir)
            (io.file-exists? (clone primary)))
            (ResultPkgResolve.Ok primary)
            (if (io.file-exists? (clone fallback))
              (ResultPkgResolve.Ok fallback)
              (match (compiler-load-resolve-root-module-path
                module-path
                stdlib-roots)
                [(CompilerLoadSomePath root-path)
                  (ResultPkgResolve.Ok root-path)]
                [(CompilerLoadNoPath)
                  (ResultPkgResolve.Err
                    (str_cat.str-cat
                      "compiler-load: dotted import missing module segment after package alias: "
                      module-name))])))
          (match (compiler-load-pkg-dep-lookup
            (ast.ast-place-shared-view deps)
            (clone first))
            [(CompilerLoadNoPath)
              (cond
                [(and
                    (compiler-load-nested-import-root? importer-dir)
                    (io.file-exists? (clone primary)))
                  (ResultPkgResolve.Ok primary)]
                [(io.file-exists? (clone fallback))
                  (ResultPkgResolve.Ok fallback)]
                [else
                  (match (compiler-load-resolve-root-module-path
                    (clone module-path)
                    stdlib-roots)
                    [(CompilerLoadSomePath root-path)
                      (ResultPkgResolve.Ok root-path)]
                    [(CompilerLoadNoPath)
                      (if (= (compiler-pkg-deps-count deps) 0)
                        ;; A dotted alias with no declared dependencies and no
                        ;; local or root module is an unknown package alias;
                        ;; with a deps graph the name may be a vendored local
                        ;; source module.
                        (ResultPkgResolve.Err
                          (str_cat.str-cat
                            "compiler-load: unknown package alias '"
                            first
                            "': pkg:"
                            module-path))
                        (ResultPkgResolve.Ok fallback))])])]
            [(CompilerLoadSomePath dep-path)
              (if (compiler-load-github-dependency-path? (clone dep-path))
                (ResultPkgResolve.Err
                  (str_cat.str-cat
                    "compiler-load: GitHub dependency '"
                    first
                    "' requires fetch support: "
                    module-name))
                (ResultPkgResolve.Ok
                  (compiler-load-normalize-path
                    (compiler-load-join-root-path
                      (compiler-load-join-root-path manifest-dir dep-path)
                      (compiler-load-dotted-module-path-uncached rest)))))]))))))

(define (compiler-load-resolve-package-import-spec
  [importer-path : String]
  [kind : ast.AstImportKind]
  [import-path : String]
  [expected-module : ast.AstMaybeModuleName]
  [stdlib-roots : svec.Vec]
  [manifest-dir : String]
  [deps : CompilerPkgDeps]) : ResultPkgResolve
  (match kind
    [(ast.AstImportKind.Module)
      (compiler-load-resolve-package-module-import
        import-path
        expected-module
        importer-path
        manifest-dir
        deps
        stdlib-roots)]
    [(ast.AstImportKind.ModuleAll)
      (compiler-load-resolve-package-module-import
        import-path
        expected-module
        importer-path
        manifest-dir
        deps
        stdlib-roots)]
    [(ast.AstImportKind.ModuleItem _)
      (compiler-load-resolve-package-module-import
        import-path
        expected-module
        importer-path
        manifest-dir
        deps
        stdlib-roots)]
    [(ast.AstImportKind.Macro _ _)
      (ResultPkgResolve.Err
        "compiler-load: module macro imports must be expanded before import resolution")]
    [(ast.AstImportKind.MacroDecls _ _)
      (ResultPkgResolve.Err
        "compiler-load: module macro imports must be expanded before import resolution")]))

(define (compiler-load-search-package-import-prefix
  [importer-path : String]
  [original-import-path : String]
  [candidate : String]
  [selected-item : i64]
  [remaining-segments : i64]
  [alias : ast.AstMaybeImportAlias]
  [stdlib-roots : svec.Vec]
  [manifest-dir : String]
  [deps : CompilerPkgDeps]) : ResultCompilerLoadResolvedImport
  (let
    [candidate-id : i64
      (compiler-load-import-module-id
        (owned_view.compiler-owned-shared-view candidate))]
    (match (compiler-load-resolve-package-module-import
      (owned_view.compiler-owned-shared-view candidate)
      (ast.AstMaybeModuleName.Some candidate-id)
      (owned_view.compiler-owned-shared-view importer-path)
      (owned_view.compiler-owned-shared-view manifest-dir)
      (owned_view.compiler-owned-shared-view deps)
      (owned_view.compiler-owned-shared-view stdlib-roots))
      [(ResultPkgResolve.Ok resolved)
        (if (compiler-load-resolved-source-exists?
          (owned_view.compiler-owned-shared-view resolved))
          (if (= remaining-segments 1)
            (compiler-load-resolved-import
              resolved
              (ast.AstImportKind.ModuleItem selected-item)
              candidate
              alias)
            (ResultCompilerLoadResolvedImport.Err
              (compiler-load-invalid-selected-import-message
                original-import-path
                candidate)))
          (let
            [dot : i64
              (compiler-load-dotted-module-last-dot
                (owned_view.compiler-owned-shared-view candidate))]
            (if (< dot 0)
              (ResultCompilerLoadResolvedImport.Err "")
              (compiler-load-search-package-import-prefix
                importer-path
                original-import-path
                (string.substring candidate 0 dot)
                selected-item
                (+ remaining-segments 1)
                alias
                stdlib-roots
                manifest-dir
                deps))))]
      [(ResultPkgResolve.Err _)
        (let
          [dot : i64
            (compiler-load-dotted-module-last-dot
              (owned_view.compiler-owned-shared-view candidate))]
          (if (< dot 0)
            (ResultCompilerLoadResolvedImport.Err "")
            (compiler-load-search-package-import-prefix
              importer-path
              original-import-path
              (string.substring candidate 0 dot)
              selected-item
              (+ remaining-segments 1)
              alias
              stdlib-roots
              manifest-dir
              deps)))])))

(define (compiler-load-resolve-package-import-spec-classified
  [importer-path : String]
  [kind : ast.AstImportKind]
  [import-path : String]
  [expected-module : ast.AstMaybeModuleName]
  [alias : ast.AstMaybeImportAlias]
  [stdlib-roots : svec.Vec]
  [manifest-dir : String]
  [deps : CompilerPkgDeps]) : ResultCompilerLoadResolvedImport
  (match kind
    [(ast.AstImportKind.ModuleAll)
      (match (compiler-load-resolve-package-module-import
        (owned_view.compiler-owned-shared-view import-path)
        (owned_view.compiler-owned-shared-view expected-module)
        (owned_view.compiler-owned-shared-view importer-path)
        (owned_view.compiler-owned-shared-view manifest-dir)
        (owned_view.compiler-owned-shared-view deps)
        (owned_view.compiler-owned-shared-view stdlib-roots))
        [(ResultPkgResolve.Ok resolved)
          (compiler-load-resolved-import
            resolved
            ast.AstImportKind.ModuleAll
            import-path
            alias)]
        [(ResultPkgResolve.Err message)
          (ResultCompilerLoadResolvedImport.Err message)])]
    [(ast.AstImportKind.ModuleItem _)
      (match (compiler-load-resolve-package-module-import
        (owned_view.compiler-owned-shared-view import-path)
        (owned_view.compiler-owned-shared-view expected-module)
        (owned_view.compiler-owned-shared-view importer-path)
        (owned_view.compiler-owned-shared-view manifest-dir)
        (owned_view.compiler-owned-shared-view deps)
        (owned_view.compiler-owned-shared-view stdlib-roots))
        [(ResultPkgResolve.Ok resolved)
          (compiler-load-resolved-import resolved kind import-path alias)]
        [(ResultPkgResolve.Err message)
          (ResultCompilerLoadResolvedImport.Err message)])]
    [(ast.AstImportKind.Module)
      (let
        [original : ResultPkgResolve
          (compiler-load-resolve-package-module-import
            (owned_view.compiler-owned-shared-view import-path)
            (owned_view.compiler-owned-shared-view expected-module)
            (owned_view.compiler-owned-shared-view importer-path)
            (owned_view.compiler-owned-shared-view manifest-dir)
            (owned_view.compiler-owned-shared-view deps)
            (owned_view.compiler-owned-shared-view stdlib-roots))]
        (match original
          [(ResultPkgResolve.Ok resolved)
            (if (compiler-load-resolved-source-exists?
              (owned_view.compiler-owned-shared-view resolved))
              (compiler-load-resolved-import
                resolved
                ast.AstImportKind.Module
                import-path
                alias)
              (let
                [dot : i64
                  (compiler-load-dotted-module-last-dot
                    (owned_view.compiler-owned-shared-view import-path))]
                (if (< dot 0)
                  (compiler-load-resolved-import
                    resolved
                    ast.AstImportKind.Module
                    import-path
                    alias)
                  (let
                    [item-text : String
                      (string.substring
                        (owned_view.compiler-owned-shared-view import-path)
                        (+ dot 1)
                        (-
                          (string.string-length
                            (owned_view.compiler-owned-shared-view import-path))
                          (+ dot 1)))]
                    (match (compiler-load-search-package-import-prefix
                      (owned_view.compiler-owned-shared-view importer-path)
                      (owned_view.compiler-owned-shared-view import-path)
                      (string.substring
                        (owned_view.compiler-owned-shared-view import-path)
                        0
                        dot)
                      (compiler-load-selected-item-id expected-module item-text)
                      1
                      (owned_view.compiler-owned-shared-view alias)
                      (owned_view.compiler-owned-shared-view stdlib-roots)
                      (owned_view.compiler-owned-shared-view manifest-dir)
                      (owned_view.compiler-owned-shared-view deps))
                      [(ResultCompilerLoadResolvedImport.Ok selected)
                        (ResultCompilerLoadResolvedImport.Ok selected)]
                      [(ResultCompilerLoadResolvedImport.Err message)
                        (if (=
                          (string.string-length
                            (owned_view.compiler-owned-shared-view message))
                          0)
                          (compiler-load-resolved-import
                            resolved
                            ast.AstImportKind.Module
                            import-path
                            alias)
                          (ResultCompilerLoadResolvedImport.Err message))])))))]
          [(ResultPkgResolve.Err original-message)
            (let
              [dot : i64
                (compiler-load-dotted-module-last-dot
                  (owned_view.compiler-owned-shared-view import-path))]
              (if (< dot 0)
                (ResultCompilerLoadResolvedImport.Err original-message)
                (let
                  [item-text : String
                    (string.substring
                      (owned_view.compiler-owned-shared-view import-path)
                      (+ dot 1)
                      (-
                        (string.string-length
                          (owned_view.compiler-owned-shared-view import-path))
                        (+ dot 1)))]
                  (match (compiler-load-search-package-import-prefix
                    (owned_view.compiler-owned-shared-view importer-path)
                    (owned_view.compiler-owned-shared-view import-path)
                    (string.substring
                      (owned_view.compiler-owned-shared-view import-path)
                      0
                      dot)
                    (compiler-load-selected-item-id expected-module item-text)
                    1
                    (owned_view.compiler-owned-shared-view alias)
                    (owned_view.compiler-owned-shared-view stdlib-roots)
                    (owned_view.compiler-owned-shared-view manifest-dir)
                    (owned_view.compiler-owned-shared-view deps))
                    [(ResultCompilerLoadResolvedImport.Ok selected)
                      (ResultCompilerLoadResolvedImport.Ok selected)]
                    [(ResultCompilerLoadResolvedImport.Err message)
                      (if (=
                        (string.string-length
                          (owned_view.compiler-owned-shared-view message))
                        0)
                        (ResultCompilerLoadResolvedImport.Err original-message)
                        (ResultCompilerLoadResolvedImport.Err message))]))))]))]
    [(ast.AstImportKind.Macro _ _)
      (ResultCompilerLoadResolvedImport.Err
        "compiler-load: module macro imports must be expanded before import resolution")]
    [(ast.AstImportKind.MacroDecls _ _)
      (ResultCompilerLoadResolvedImport.Err
        "compiler-load: module macro imports must be expanded before import resolution")]))

(define (compiler-load-package-import-externs?
  [kind : ast.AstImportKind]
  [import-path : String]
  [expected-module : ast.AstMaybeModuleName]
  [deps : CompilerPkgDeps]) : bool
  (match kind
    [(ast.AstImportKind.Module)
      (let
        [module-path : String
          (compiler-load-dotted-module-path-from-ast
            (clone import-path)
            expected-module)]
        [first : String (compiler-load-dotted-module-first (clone import-path))]
        [rest : String
          (compiler-load-dotted-module-rest
            (clone import-path)
            (compiler-load-dotted-module-first-len import-path))]
        ;; A bare single-segment import names a local module first; only a
        ;; nested path under a dependency alias is package-extern.
        (if (or
          (compiler-load-stdlib-import? module-path)
          (= (string.string-length rest) 0))
          false
          (match (compiler-load-pkg-dep-lookup deps first)
            [(CompilerLoadSomePath _) true]
            [(CompilerLoadNoPath) false])))]
    [(ast.AstImportKind.ModuleAll)
      (compiler-load-package-import-externs?
        ast.AstImportKind.Module
        import-path
        expected-module
        deps)]
    [(ast.AstImportKind.ModuleItem _)
      (compiler-load-package-import-externs?
        ast.AstImportKind.Module
        import-path
        expected-module
        deps)]
    [(ast.AstImportKind.Macro _ _) false]
    [(ast.AstImportKind.MacroDecls _ _) false]))

(define (compiler-load-package-source-expected-module
  [kind : ast.AstImportKind]
  [expected-module : ast.AstMaybeModuleName]
  [package-externs : bool]) : ast.AstMaybeModuleName
  (if package-externs
    (match kind
      ;; A dependency alias selects a package root and source path; it is not
      ;; the dependency source's public module identity. Let an explicit module
      ;; declaration win, while a moduleless source keeps the dotted fallback.
      [(ast.AstImportKind.Module) ast.AstMaybeModuleName.No]
      [(ast.AstImportKind.ModuleAll) ast.AstMaybeModuleName.No]
      [(ast.AstImportKind.ModuleItem _) ast.AstMaybeModuleName.No]
      [_ expected-module])
    expected-module))

(define (compiler-load-macro-import-kind? [kind : ast.AstImportKind]) : bool
  (match kind
    [(ast.AstImportKind.Macro _ _) true]
    [(ast.AstImportKind.MacroDecls _ _) true]
    [_ false]))

(define (compiler-load-include-str-def [name : i64] [contents : String]) : ast.AstDecl
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [decl : ast.AstDecl
      (compiler-load-include-str-def-with-pools
        (ast.ast-place-shared-view pools)
        name
        contents)]
    (begin
      (ast.ast-node-pool-context-install! pools)
      decl)))

(define (compiler-load-include-str-def-with-pools
  [pools : ast.AstNodePoolContext]
  [name : i64]
  [contents : String]) : ast.AstDecl
  (ast.ast-decl-def-id
    name
    (ast.AstMaybeType.Some (ast.AstType.String))
    (ast.ast-node-pool-context-expr-push
      pools
      (ast.AstExpr.Literal (ast.ast-lit-generated-string contents)))))

;; A comptime include becomes a zero-argument macro whose expansion is a string
;; literal. The file bytes therefore exist only while the transformer runs;
;; unlike `include-str`, no runtime definition or static string is emitted.
(define (compiler-load-include-str-comptime-def-with-pools
  [pools : ast.AstNodePoolContext]
  [name : i64]
  [contents : String]) : ast.AstDecl
  (let
    [args : ast.AstExprList (ast.ast-expr-list-with-capacity 1)]
    [literal : i64
      (ast.ast-node-pool-context-expr-push
        (ast.ast-place-shared-view pools)
        (ast.AstExpr.Literal (ast.ast-lit-generated-string contents)))]
    (begin
      (ast.ast-expr-list-push (&mut args) literal)
      (ast.ast-decl-def-macro-id
        name
        (ast.ast-macro-param-list-new)
        (ast.AstType.String)
        (ast.ast-node-pool-context-expr-push
          (ast.ast-place-shared-view pools)
          (ast.AstExpr.Call
            (ast.ast-node-pool-context-expr-push
              (ast.ast-place-shared-view pools)
              (ast.AstExpr.Var (cbi.compiler-builtin-ctfe-ref 29)))
            args))))))

(define (compiler-load-include-str-lzss-def-with-pools
  [pools : ast.AstNodePoolContext]
  [name : i64]
  [contents : String]) : ast.AstDecl
  (let
    [compressed : String (ctfe.ctfe-embedded-stdlib-binary-data-bytes contents)]
    (ast.ast-decl-def-id
      name
      (ast.AstMaybeType.Some
        (ast.ast-ty-dyn-array-with-pools
          (ast.ast-place-shared-view pools)
          (ast.AstType.U8)))
      (ast.ast-node-pool-context-expr-push
        pools
        (ast.AstExpr.BinaryData compressed)))))

(define (compiler-load-include-bin-def [name : i64] [contents : String]) : ast.AstDecl
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [decl : ast.AstDecl
      (compiler-load-include-bin-def-with-pools
        (ast.ast-place-shared-view pools)
        name
        contents)]
    (begin
      (ast.ast-node-pool-context-install! pools)
      decl)))

(define (compiler-load-include-bin-def-with-pools
  [pools : ast.AstNodePoolContext]
  [name : i64]
  [contents : String]) : ast.AstDecl
  (ast.ast-decl-def-id
    name
    (ast.AstMaybeType.Some
      (ast.ast-ty-dyn-array-with-pools
        (ast.ast-place-shared-view pools)
        (ast.AstType.U8)))
    (ast.ast-node-pool-context-expr-push
      pools
      (ast.AstExpr.BinaryData contents))))

(define (compiler-load-include-str-read-error
  [importer-path : String]
  [include-path : String]
  [resolved : String]) : cdiag.CompilerDiagnostic
  (cdiag.compiler-diagnostic-at-start
    (clone importer-path)
    (str_cat.str-cat
      "compiler-load: cannot read include-str "
      include-path
      " from "
      importer-path
      " (resolved "
      resolved
      ")")))

(define (compiler-load-include-str-from-resolved
  [importer-path : String]
  [include-path : String]
  [resolved : String]
  [name : i64]) : ResultCompilerLoadInclude
  (if (io.file-exists? (clone resolved))
    (ResultCompilerLoadInclude.Ok
      (compiler-load-include-str-def
        name
        (compiler-load-read-file-text resolved)))
    (match (compiler-load-embedded-stdlib-source-for-path (clone resolved))
      [(ces.CompilerEmbeddedStdlibSource.CompilerEmbeddedStdlibSomeSource
          source)
        (ResultCompilerLoadInclude.Ok
          (compiler-load-include-str-def name source))]
      [(ces.CompilerEmbeddedStdlibSource.CompilerEmbeddedStdlibNoSource)
        (ResultCompilerLoadInclude.Err
          (box
            (compiler-load-include-str-read-error
              importer-path
              include-path
              resolved)))])))

(define (compiler-load-include-str-from-resolved-with-pools
  [importer-path : String]
  [include-path : String]
  [resolved : String]
  [name : i64]
  [pools : ast.AstNodePoolContext]) : ResultCompilerLoadInclude
  (if (io.file-exists? (clone resolved))
    (ResultCompilerLoadInclude.Ok
      (compiler-load-include-str-def-with-pools
        pools
        name
        (compiler-load-read-file-text resolved)))
    (match (compiler-load-embedded-stdlib-source-for-path (clone resolved))
      [(ces.CompilerEmbeddedStdlibSource.CompilerEmbeddedStdlibSomeSource
          source)
        (ResultCompilerLoadInclude.Ok
          (compiler-load-include-str-def-with-pools pools name source))]
      [(ces.CompilerEmbeddedStdlibSource.CompilerEmbeddedStdlibNoSource)
        (ResultCompilerLoadInclude.Err
          (box
            (compiler-load-include-str-read-error
              importer-path
              include-path
              resolved)))])))

(define (compiler-load-include-str-comptime-from-resolved-with-pools
  [importer-path : String]
  [include-path : String]
  [resolved : String]
  [name : i64]
  [pools : ast.AstNodePoolContext]) : ResultCompilerLoadInclude
  (if (io.file-exists? (clone resolved))
    (ResultCompilerLoadInclude.Ok
      (compiler-load-include-str-comptime-def-with-pools
        pools
        name
        (compiler-load-read-file-text resolved)))
    (match (compiler-load-embedded-stdlib-source-for-path (clone resolved))
      [(ces.CompilerEmbeddedStdlibSource.CompilerEmbeddedStdlibSomeSource
          source)
        (ResultCompilerLoadInclude.Ok
          (compiler-load-include-str-comptime-def-with-pools pools name source))]
      [(ces.CompilerEmbeddedStdlibSource.CompilerEmbeddedStdlibNoSource)
        (ResultCompilerLoadInclude.Err
          (box
            (compiler-load-include-str-read-error
              importer-path
              include-path
              resolved)))])))

(define (compiler-load-include-str-lzss-from-resolved-with-pools
  [importer-path : String]
  [include-path : String]
  [resolved : String]
  [name : i64]
  [pools : ast.AstNodePoolContext]) : ResultCompilerLoadInclude
  (if (io.file-exists? (clone resolved))
    (ResultCompilerLoadInclude.Ok
      (compiler-load-include-str-lzss-def-with-pools
        pools
        name
        (compiler-load-read-file-text resolved)))
    (match (compiler-load-embedded-stdlib-source-for-path (clone resolved))
      [(ces.CompilerEmbeddedStdlibSource.CompilerEmbeddedStdlibSomeSource
          source)
        (ResultCompilerLoadInclude.Ok
          (compiler-load-include-str-lzss-def-with-pools pools name source))]
      [(ces.CompilerEmbeddedStdlibSource.CompilerEmbeddedStdlibNoSource)
        (ResultCompilerLoadInclude.Err
          (box
            (compiler-load-include-str-read-error
              importer-path
              include-path
              resolved)))])))

(define (compiler-load-include-str-lzss-from-resolved
  [importer-path : String]
  [include-path : String]
  [resolved : String]
  [name : i64]) : ResultCompilerLoadInclude
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [result : ResultCompilerLoadInclude
      (compiler-load-include-str-lzss-from-resolved-with-pools
        importer-path
        include-path
        resolved
        name
        (ast.ast-place-shared-view pools))]
    (begin
      (ast.ast-node-pool-context-install! pools)
      result)))

(define (compiler-load-include-bin-read-error
  [importer-path : String]
  [include-path : String]
  [resolved : String]) : cdiag.CompilerDiagnostic
  (cdiag.compiler-diagnostic-at-start
    (clone importer-path)
    (str_cat.str-cat
      "compiler-load: cannot read include-bin "
      include-path
      " from "
      importer-path
      " (resolved "
      resolved
      ")")))

(define (compiler-load-include-bin-from-resolved
  [importer-path : String]
  [include-path : String]
  [resolved : String]
  [name : i64]) : ResultCompilerLoadInclude
  (if (io.file-exists? (clone resolved))
    (ResultCompilerLoadInclude.Ok
      (compiler-load-include-bin-def
        name
        (compiler-load-read-file-text resolved)))
    (match (compiler-load-embedded-stdlib-source-for-path (clone resolved))
      [(ces.CompilerEmbeddedStdlibSource.CompilerEmbeddedStdlibSomeSource
          source)
        (ResultCompilerLoadInclude.Ok
          (compiler-load-include-bin-def name source))]
      [(ces.CompilerEmbeddedStdlibSource.CompilerEmbeddedStdlibNoSource)
        (ResultCompilerLoadInclude.Err
          (box
            (compiler-load-include-bin-read-error
              importer-path
              include-path
              resolved)))])))

(define (compiler-load-include-bin-from-resolved-with-pools
  [importer-path : String]
  [include-path : String]
  [resolved : String]
  [name : i64]
  [pools : ast.AstNodePoolContext]) : ResultCompilerLoadInclude
  (if (io.file-exists? (clone resolved))
    (ResultCompilerLoadInclude.Ok
      (compiler-load-include-bin-def-with-pools
        pools
        name
        (compiler-load-read-file-text resolved)))
    (match (compiler-load-embedded-stdlib-source-for-path (clone resolved))
      [(ces.CompilerEmbeddedStdlibSource.CompilerEmbeddedStdlibSomeSource
          source)
        (ResultCompilerLoadInclude.Ok
          (compiler-load-include-bin-def-with-pools pools name source))]
      [(ces.CompilerEmbeddedStdlibSource.CompilerEmbeddedStdlibNoSource)
        (ResultCompilerLoadInclude.Err
          (box
            (compiler-load-include-bin-read-error
              importer-path
              include-path
              resolved)))])))

(define (compiler-load-expand-include-str-with-pools
  [importer-path : String]
  [include-path : String]
  [name : i64]
  [stdlib-roots : svec.Vec]
  [pools : ast.AstNodePoolContext]) : ResultCompilerLoadInclude
  (match (compiler-load-resolve-import-result-with-roots
    (clone importer-path)
    (clone include-path)
    stdlib-roots)
    [(ResultPkgResolve.Ok resolved)
      (compiler-load-include-str-from-resolved-with-pools
        importer-path
        include-path
        resolved
        name
        (ast.ast-place-shared-view pools))]
    [(ResultPkgResolve.Err message)
      (ResultCompilerLoadInclude.Err
        (box (cdiag.compiler-diagnostic-at-start importer-path message)))]))

(define (compiler-load-expand-include-str-comptime-with-pools
  [importer-path : String]
  [include-path : String]
  [name : i64]
  [stdlib-roots : svec.Vec]
  [pools : ast.AstNodePoolContext]) : ResultCompilerLoadInclude
  (match (compiler-load-resolve-import-result-with-roots
    (clone importer-path)
    (clone include-path)
    stdlib-roots)
    [(ResultPkgResolve.Ok resolved)
      (compiler-load-include-str-comptime-from-resolved-with-pools
        importer-path
        include-path
        resolved
        name
        pools)]
    [(ResultPkgResolve.Err message)
      (ResultCompilerLoadInclude.Err
        (box (cdiag.compiler-diagnostic-at-start importer-path message)))]))

(define (compiler-load-expand-include-str-lzss-with-pools
  [importer-path : String]
  [include-path : String]
  [name : i64]
  [stdlib-roots : svec.Vec]
  [pools : ast.AstNodePoolContext]) : ResultCompilerLoadInclude
  (match (compiler-load-resolve-import-result-with-roots
    (clone importer-path)
    (clone include-path)
    stdlib-roots)
    [(ResultPkgResolve.Ok resolved)
      (compiler-load-include-str-lzss-from-resolved-with-pools
        importer-path
        include-path
        resolved
        name
        pools)]
    [(ResultPkgResolve.Err message)
      (ResultCompilerLoadInclude.Err
        (box (cdiag.compiler-diagnostic-at-start importer-path message)))]))

(define (compiler-load-expand-include-bin-with-pools
  [importer-path : String]
  [include-path : String]
  [name : i64]
  [stdlib-roots : svec.Vec]
  [pools : ast.AstNodePoolContext]) : ResultCompilerLoadInclude
  (match (compiler-load-resolve-import-result-with-roots
    (clone importer-path)
    (clone include-path)
    stdlib-roots)
    [(ResultPkgResolve.Ok resolved)
      (compiler-load-include-bin-from-resolved-with-pools
        importer-path
        include-path
        resolved
        name
        pools)]
    [(ResultPkgResolve.Err message)
      (ResultCompilerLoadInclude.Err
        (box (cdiag.compiler-diagnostic-at-start importer-path message)))]))

(define (compiler-load-decl-list-prepend-with-origin
  [head : ast.AstDecl]
  [origin : parser.CompilerParseMaybeDeclSpan]
  [rest : ast.AstDeclList]) : ast.AstDeclList
  (let
    [rest-key : i64 (parser.compiler-parse-decl-list-storage-key (& rest))]
    [out : ast.AstDeclList
      (ast.ast-decl-list-prepend-builder head (ast.ast-place-shared-view rest))]
    [same-storage : bool
      (= rest-key (parser.compiler-parse-decl-list-storage-key (& out)))]
    (if same-storage
      (begin
        (parser.compiler-parse-decl-origin-register-maybe! (& out) 0 origin)
        out)
      (begin
        (parser.compiler-parse-decl-origin-register-maybe! (& out) 0 origin)
        (parser.compiler-parse-decl-origin-register-list-aliases!
          (& out)
          1
          rest)
        out))))

(define (compiler-load-decl-list-prepend-from-source
  [head : ast.AstDecl]
  [source : ast.AstDeclList]
  [rest : ast.AstDeclList]) : ast.AstDeclList
  (let
    [rest-key : i64 (parser.compiler-parse-decl-list-storage-key (& rest))]
    [out : ast.AstDeclList
      (ast.ast-decl-list-prepend-builder head (ast.ast-place-shared-view rest))]
    [same-storage : bool
      (= rest-key (parser.compiler-parse-decl-list-storage-key (& out)))]
    (begin
      ;; Normal source aliases are cheap and may carry a semantic sidecar even
      ;; when their declaration kind has no declaration-span record. Recording
      ;; the alias unconditionally avoids scanning every prior semantic run for
      ;; each declaration flattened by the loader.
      (parser.compiler-parse-decl-origin-register-alias-record!
        (& out)
        0
        1
        (parser.compiler-parse-decl-list-storage-key (& source))
        source.offset
        false)
      (if same-storage
        unit
        (parser.compiler-parse-decl-origin-register-list-aliases!
          (& out)
          1
          rest))
      out)))

(define (compiler-load-decl-list-prepend
  [head : ast.AstDecl]
  [rest : ast.AstDeclList]) : ast.AstDeclList
  (compiler-load-decl-list-prepend-with-origin
    head
    (parser.CompilerParseMaybeDeclSpan.None)
    rest))

(define (compiler-load-decl-list-append
  [left : ast.AstDeclList]
  [right : ast.AstDeclList]) : ast.AstDeclList
  (let
    [out : ast.AstDeclList
      (ast.ast-decl-list-with-capacity
        (+ (ast.ast-decl-list-len (& left)) (ast.ast-decl-list-len (& right))))]
    (begin
      (ast.ast-decl-list-append-from (&mut out) (& left) 0)
      (ast.ast-decl-list-append-from (&mut out) (& right) 0)
      (parser.compiler-parse-decl-origin-register-list-aliases!
        (& out)
        0
        (ast.ast-place-shared-view left))
      (parser.compiler-parse-decl-origin-register-list-aliases!
        (& out)
        (ast.ast-decl-list-len (& left))
        right)
      out)))

(define (compiler-load-decl-list-append-onto
  [left : ast.AstDeclList]
  [right : ast.AstDeclList]) : ast.AstDeclList
  (let
    [left-len : i64 (ast.ast-decl-list-len (& left))]
    [right-len : i64 (ast.ast-decl-list-len (& right))]
    [right-key : i64 (parser.compiler-parse-decl-list-storage-key (& right))]
    [right-slots : (__tl_dyn-array ast.AstDecl)
      (ast.ast-place-shared-view right.slots)]
    [out : ast.AstDeclList
      (if (and
        (<= left-len right.offset)
        right.prependable
        (not
          (unsafe
            (=
              (ptr->int (ptr-cast (__tl_array-data left.slots) : (Ptr u8)))
              (ptr->int (ptr-cast (__tl_array-data right.slots) : (Ptr u8)))))))
        (let
          [new-offset : i64 (- right.offset left-len)]
          (begin
            (ast.ast-decl-list-copy-to
              (&mut right-slots)
              (& left.slots)
              left.offset
              new-offset
              0
              left-len)
            (ast.AstDeclList right-slots new-offset (+ left-len right-len) true)))
        (let
          [out : ast.AstDeclList
            (ast.ast-decl-list-with-capacity (+ left-len right-len))]
          (begin
            (ast.ast-decl-list-append-from (&mut out) (& left) 0)
            (ast.ast-decl-list-append-from (&mut out) (& right) 0)
            out)))]
    [same-storage : bool
      (= right-key (parser.compiler-parse-decl-list-storage-key (& out)))]
    (begin
      (parser.compiler-parse-decl-origin-register-list-aliases!
        (& out)
        0
        (ast.ast-place-shared-view left))
      (if same-storage
        unit
        (parser.compiler-parse-decl-origin-register-list-aliases!
          (& out)
          left-len
          right))
      out)))

(define (compiler-load-decl-path-list-append
  [left : ast.AstDeclPathList]
  [right : ast.AstDeclPathList]) : ast.AstDeclPathList
  (let
    [out : ast.AstDeclPathList
      (ast.ast-decl-path-list-with-capacity
        (+
          (ast.ast-decl-path-list-len (& left))
          (ast.ast-decl-path-list-len (& right))))]
    (begin
      (ast.ast-decl-path-list-append-from (&mut out) (& left) 0)
      (ast.ast-decl-path-list-append-from (&mut out) (& right) 0)
      out)))

(define (compiler-load-decl-path-list-append-onto
  [left : ast.AstDeclPathList]
  [right : ast.AstDeclPathList]) : ast.AstDeclPathList
  (let
    [left-len : i64 (ast.ast-decl-path-list-len (& left))]
    [right-len : i64 (ast.ast-decl-path-list-len (& right))]
    [right-slots : (__tl_dyn-array String)
      (ast.ast-place-shared-view right.slots)]
    [right-owner-ids : (__tl_dyn-array i64)
      (ast.ast-place-shared-view right.owner-ids)]
    [left-capacity : i64 (array-length left.slots)]
    [right-capacity : i64 (array-length right.slots)]
    (if (and
      (<= left-len right.offset)
      right.prependable
      (not
        (unsafe
          (=
            (ptr->int (ptr-cast (__tl_array-data left.slots) : (Ptr u8)))
            (ptr->int (ptr-cast (__tl_array-data right.slots) : (Ptr u8)))))))
      (let
        [new-offset : i64 (- right.offset left-len)]
        (begin
          (ast.ast-decl-path-list-copy-to
            (&mut right-slots)
            (& left.slots)
            left.offset
            new-offset
            0
            left-len)
          (ast.ast-decl-module-list-copy-to
            (&mut right-owner-ids)
            (& left.owner-ids)
            left.offset
            new-offset
            0
            left-len)
          (ast.ast-decl-module-list-copy-to
            (&mut right-owner-ids)
            (& left.owner-ids)
            (+ left-capacity left.offset)
            (+ right-capacity new-offset)
            0
            left-len)
          (ast.AstDeclPathList
            right-slots
            right-owner-ids
            new-offset
            (+ left-len right-len)
            true)))
      (let
        [out : ast.AstDeclPathList
          (ast.ast-decl-path-list-with-capacity (+ left-len right-len))]
        (begin
          (ast.ast-decl-path-list-append-from (&mut out) (& left) 0)
          (ast.ast-decl-path-list-append-from (&mut out) (& right) 0)
          out)))))

(define (compiler-load-decl-module-list-append
  [left : ast.AstDeclModuleList]
  [right : ast.AstDeclModuleList]) : ast.AstDeclModuleList
  (let
    [out : ast.AstDeclModuleList
      (ast.ast-decl-module-list-with-capacity
        (+
          (ast.ast-decl-module-list-len (& left))
          (ast.ast-decl-module-list-len (& right))))]
    (begin
      (ast.ast-decl-module-list-append-from (&mut out) (& left) 0)
      (ast.ast-decl-module-list-append-from (&mut out) (& right) 0)
      out)))

(define (compiler-load-decl-module-list-append-onto
  [left : ast.AstDeclModuleList]
  [right : ast.AstDeclModuleList]) : ast.AstDeclModuleList
  (let
    [left-len : i64 (ast.ast-decl-module-list-len (& left))]
    [right-len : i64 (ast.ast-decl-module-list-len (& right))]
    [right-slots : (__tl_dyn-array i64) (ast.ast-place-shared-view right.slots)]
    (if (and
      (<= left-len right.offset)
      right.prependable
      (not
        (unsafe
          (=
            (ptr->int (ptr-cast (__tl_array-data left.slots) : (Ptr u8)))
            (ptr->int (ptr-cast (__tl_array-data right.slots) : (Ptr u8)))))))
      (let
        [new-offset : i64 (- right.offset left-len)]
        (begin
          (ast.ast-decl-module-list-copy-to
            (&mut right-slots)
            (& left.slots)
            left.offset
            new-offset
            0
            left-len)
          (ast.AstDeclModuleList
            right-slots
            new-offset
            (+ left-len right-len)
            true)))
      (let
        [out : ast.AstDeclModuleList
          (ast.ast-decl-module-list-with-capacity (+ left-len right-len))]
        (begin
          (ast.ast-decl-module-list-append-from (&mut out) (& left) 0)
          (ast.ast-decl-module-list-append-from (&mut out) (& right) 0)
          out)))))

(define compiler-load-core-macro-prelude-path : String
  "stdlib/core_macros.tl")
(define compiler-load-clone-prelude-path : String
  "stdlib/clone.tl")
(define compiler-load-runtime-prelude-path : String
  "stdlib/runtime.tl")

(define (compiler-load-core-macro-prelude-path-shared-view) : String
  (compiler-load-global-shared-view compiler-load-core-macro-prelude-path))

(define (compiler-load-clone-prelude-path-shared-view) : String
  (compiler-load-global-shared-view compiler-load-clone-prelude-path))

(define (compiler-load-runtime-prelude-path-shared-view) : String
  (compiler-load-global-shared-view compiler-load-runtime-prelude-path))

;; Prelude source selection is physical, but its loader path is deliberately
;; canonical. That keeps module identity, import restoration, diagnostics, and
;; deduplication independent of the absolute/relative spelling of a stdlib root.
(define (compiler-load-stdlib-prelude-source-with-roots-cfg
  [path : String]
  [source : String]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]) : ResultCompilerLoadWithPaths
  (compiler-load-source-with-paths-and-roots-expect-cfg
    path
    source
    seen
    stdlib-roots
    ast.AstMaybeModuleName.No
    cfgs))

(define (compiler-load-stdlib-prelude-file-with-roots-cfg
  [path : String]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]) : ResultCompilerLoadWithPaths
  (let
    [suffix : String (compiler-load-stdlib-suffix (clone path))]
    (match (compiler-load-resolve-stdlib-root
      (clone suffix)
      (ast.ast-place-shared-view stdlib-roots))
      [(CompilerLoadSomePath source-path)
        (begin
          (compiler-load-note-embedded-equivalent-if-matching!
            suffix
            (clone source-path))
          (compiler-load-stdlib-prelude-source-with-roots-cfg
            (clone path)
            (compiler-load-read-file-text source-path)
            seen
            stdlib-roots
            cfgs))]
      [(CompilerLoadNoPath)
        (match (compiler-load-embedded-stdlib-source suffix)
          [(ces.CompilerEmbeddedStdlibSource.CompilerEmbeddedStdlibSomeSource
              source)
            (begin
              (compiler-load-note-embedded-module! (clone path))
              (compiler-load-session-note-embedded-stdlib-source!)
              (compiler-load-stdlib-prelude-source-with-roots-cfg
                (clone path)
                source
                seen
                stdlib-roots
                cfgs))]
          [(ces.CompilerEmbeddedStdlibSource.CompilerEmbeddedStdlibNoSource)
            (compiler-load-file-with-paths-and-roots-cfg
              path
              seen
              stdlib-roots
              cfgs)])])))

(define (compiler-load-stdlib-prelude-source-with-roots-cfg-with-pools
  [load-state : CompilerLoadSessionState]
  [path : String]
  [source : String]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]) : ResultCompilerLoadWithPaths
  (compiler-load-source-with-paths-and-roots-expect-cfg-with-pools
    load-state
    path
    source
    seen
    stdlib-roots
    ast.AstMaybeModuleName.No
    cfgs
    pools))

(define (compiler-load-stdlib-prelude-file-with-roots-cfg-with-pools
  [load-state : CompilerLoadSessionState]
  [path : String]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]) : ResultCompilerLoadWithPaths
  (let
    [suffix : String (compiler-load-stdlib-suffix (clone path))]
    (match (compiler-load-resolve-stdlib-root
      (clone suffix)
      (ast.ast-place-shared-view stdlib-roots))
      [(CompilerLoadSomePath source-path)
        (begin
          (compiler-load-note-embedded-equivalent-if-matching!
            suffix
            (clone source-path))
          (compiler-load-stdlib-prelude-source-with-roots-cfg-with-pools
            load-state
            (clone path)
            (compiler-load-read-file-text source-path)
            seen
            stdlib-roots
            cfgs
            pools))]
      [(CompilerLoadNoPath)
        (match (compiler-load-embedded-stdlib-source suffix)
          [(ces.CompilerEmbeddedStdlibSource.CompilerEmbeddedStdlibSomeSource
              source)
            (begin
              (compiler-load-note-embedded-module! (clone path))
              (compiler-load-session-state-note-embedded-stdlib-source!
                (compiler-load-session-state-shared-view (& load-state)))
              (compiler-load-stdlib-prelude-source-with-roots-cfg-with-pools
                load-state
                path
                source
                seen
                stdlib-roots
                cfgs
                pools))]
          [(ces.CompilerEmbeddedStdlibSource.CompilerEmbeddedStdlibNoSource)
            (compiler-load-file-with-paths-and-roots-cfg-with-pools
              load-state
              path
              seen
              stdlib-roots
              cfgs
              pools)])])))

;; `stdlib/core_macros.tl` infers as `stdlib.core_macros`. Add a root module
;; marker after loading it so the following entry resumes in the root module,
;; matching import restoration and keeping module-less `main` discoverable.
(define (compiler-load-append-root-module-marker
  [loaded : ResultCompilerLoadWithPaths]) : ResultCompilerLoadWithPaths
  (match loaded
    [(ResultCompilerLoadWithPaths.Ok decls paths modules seen)
      (ResultCompilerLoadWithPaths.Ok
        (compiler-load-decl-list-append
          decls
          (ast.ast-decl-cons
            (ast.ast-decl-module-id cbi.compiler-builtin-id-fix-empty)
            (ast.ast-decl-list-new)))
        (compiler-load-decl-path-list-append
          (ast.ast-place-shared-view paths)
          (ast.ast-decl-path-list-prepend-builder-with-owner-id
            (string.copy (& compiler-load-core-macro-prelude-path))
            (ast.ast-decl-path-list-owner-id
              (& paths)
              0
              cbi.compiler-builtin-id-fix-empty)
            (ast.ast-decl-path-list-new)))
        (compiler-load-decl-module-list-append
          modules
          (ast.ast-decl-module-cons-id
            cbi.compiler-builtin-id-fix-empty
            (ast.ast-decl-module-list-new)))
        seen)]
    [(ResultCompilerLoadWithPaths.Err diag)
      (ResultCompilerLoadWithPaths.Err diag)]))

(define (compiler-load-core-macro-prelude-with-roots-cfg
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]) : ResultCompilerLoadWithPaths
  (compiler-load-append-root-module-marker
    (compiler-load-stdlib-prelude-file-with-roots-cfg
      (string.copy (& compiler-load-core-macro-prelude-path))
      seen
      stdlib-roots
      cfgs)))

(define (compiler-load-core-macro-prelude-with-roots-cfg-with-pools
  [load-state : CompilerLoadSessionState]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]) : ResultCompilerLoadWithPaths
  (compiler-load-append-root-module-marker
    (compiler-load-stdlib-prelude-file-with-roots-cfg-with-pools
      load-state
      (string.copy (& compiler-load-core-macro-prelude-path))
      seen
      stdlib-roots
      cfgs
      pools)))

(define (compiler-load-drop-paths [result : ResultCompilerLoadWithPaths]) : ResultCompilerLoad
  (match result
    [(ResultCompilerLoadWithPaths.Ok decls _ _ seen)
      (ResultCompilerLoad.Ok decls seen)]
    [(ResultCompilerLoadWithPaths.Err diag) (ResultCompilerLoad.Err diag)]))

(define (compiler-load-parse-context-name-id [name : (& name str)]) : i64
  (ci.intern-source-slice name 0 (ci.intern-private-string-length name)))

(define (compiler-load-source-path-id [path : (& path str)]) : i64
  (ci.intern-source-slice path 0 (ci.intern-private-string-length path)))

(define (compiler-load-seen-module-contains?
  [seen : sym_i64_env.SymI64Env]
  [_name : String]
  [name-id : i64]) : bool
  (sym_i64_env.sym-i64-contains-id seen name-id))

(define (compiler-load-seen-module-bind
  [seen : sym_i64_env.SymI64Env]
  [_name : String]
  [name-id : i64]) : sym_i64_env.SymI64Env
  (sym_i64_env.sym-i64-bind-id seen name-id 1))

(define (compiler-load-decls-module-id-loop
  [path : String]
  [decls : ast.AstDeclList]
  [fallback : String]
  [fallback-id : i64]
  [found : CompilerLoadMaybeModuleId]) : ResultCompilerLoadModuleId
  (match (ast.ast-decl-list-step (ast.ast-place-shared-view decls))
    [(ast.AstDeclListStep.Nil)
      (match found
        [(CompilerLoadNoModuleId)
          (ResultCompilerLoadModuleId.Ok fallback fallback-id)]
        [(CompilerLoadSomeModuleId name name-id)
          (ResultCompilerLoadModuleId.Ok name name-id)])]
    [(ast.AstDeclListStep.Cons decl rest)
      (let
        [rest : ast.AstDeclList rest]
        (match (clone decl)
          [(ast.AstDecl.Module name)
            (match found
              [(CompilerLoadNoModuleId)
                (compiler-load-decls-module-id-loop
                  path
                  rest
                  fallback
                  fallback-id
                  (CompilerLoadSomeModuleId (ci.intern-str name) name))]
              [(CompilerLoadSomeModuleId _ _)
                (ResultCompilerLoadModuleId.Err
                  (box
                    (cdiag.compiler-diagnostic-at-start
                      path
                      "compiler-load: duplicate module declaration")))])]
          [_
            (compiler-load-decls-module-id-loop
              path
              rest
              fallback
              fallback-id
              found)]))]))

(define (compiler-load-decls-module-id
  [path : String]
  [decls : ast.AstDeclList]
  [fallback-id : i64]) : ResultCompilerLoadModuleId
  (let
    [fallback : String
      (compiler-load-canonical-module-id-from-path (clone path))]
    (compiler-load-decls-module-id-loop
      path
      decls
      fallback
      fallback-id
      CompilerLoadNoModuleId)))

(define (compiler-load-decls-module-id-with-fallback
  [path : String]
  [decls : ast.AstDeclList]
  [fallback : String]
  [fallback-id : i64]) : ResultCompilerLoadModuleId
  (compiler-load-decls-module-id-loop
    path
    decls
    fallback
    fallback-id
    CompilerLoadNoModuleId))

(define (compiler-load-check-expected-module
  [path : String]
  [expected : ast.AstMaybeModuleName]
  [actual : String]
  [actual-id : i64]) : ResultCompilerLoadModuleId
  (match expected
    [(ast.AstMaybeModuleName.No)
      (ResultCompilerLoadModuleId.Ok actual actual-id)]
    [(ast.AstMaybeModuleName.Some want)
      (let
        [checked-actual-id : i64
          (if (>= actual-id 0)
            actual-id
            (compiler-load-parse-context-name-id (clone actual)))]
        (if (= want checked-actual-id)
          (ResultCompilerLoadModuleId.Ok actual checked-actual-id)
          (ResultCompilerLoadModuleId.Err
            (box
              (cdiag.compiler-diagnostic-at-start
                (clone path)
                (str_cat.str-cat
                  "compiler-load: import expected module "
                  (ci.intern-str want)
                  " but loaded "
                  actual))))))]))

(define (compiler-load-no-expected-module? [expected : ast.AstMaybeModuleName]) : bool
  (match expected
    [(ast.AstMaybeModuleName.No) true]
    [(ast.AstMaybeModuleName.Some _) false]))

(define (compiler-load-module-fallback-id-for-parse
  [fallback : String]
  [expected : ast.AstMaybeModuleName]) : i64
  (let
    [fallback-id : i64 (compiler-load-parse-context-name-id fallback)]
    (match expected
      [(ast.AstMaybeModuleName.Some module-id)
        (if (= module-id fallback-id)
          module-id
          fallback-id)]
      [(ast.AstMaybeModuleName.No) fallback-id])))

(define (compiler-load-parse-identity
  [path : String]
  [module-fallback : String]
  [expected : ast.AstMaybeModuleName]) : CompilerLoadParseIdentity
  (CompilerLoadParseIdentity
    (compiler-load-source-path-id path)
    (compiler-load-module-fallback-id-for-parse module-fallback expected)
    cbi.compiler-builtin-id-fix-empty))

(define (compiler-load-seen-path-key-id
  [source-path-id : i64]
  [context-module-id : i64]) : i64
  (ci.intern-composite-pair-id source-path-id context-module-id))

(define (compiler-load-strip-tl-extension [path : String]) : String
  (let
    [n : i64 (string.string-length path)]
    (if (and (>= n 3) (string.eq (string.substring path (- n 3) 3) ".tl"))
      (string.substring path 0 (- n 3))
      path)))

(define (compiler-load-module-id-from-path-text [path : (& path str)]) : String
  (let
    [normalized : String
      (compiler-load-strip-tl-extension (compiler-load-normalize-path path))]
    [n : i64 (string.string-length normalized)]
    [i : i64 0]
    [out : String ""]
    (begin
      (while (< i n)
        (let
          [c : char (string.string-ref normalized i)]
          (begin
            (if (compiler-load-path-separator? c)
              (set! out (str_cat.str-cat out "." ""))
              (set!
                out
                (str_cat.str-cat out (string.substring normalized i 1) "")))
            (set! i (+ i 1)))))
      out)))

(define (compiler-load-canonical-module-id-from-path [path : (& path str)]) : String
  (compiler-load-module-id-from-path-text path))

(define (compiler-load-root-relative-path [root : String] [path : String]) : String
  (let
    [normalized-path : String (compiler-load-normalize-path path)]
    [prefix : String (compiler-load-root-prefix root)]
    [prefix-len : i64 (string.string-length prefix)]
    [path-len : i64 (string.string-length normalized-path)]
    (if (and
      (> prefix-len 0)
      (compiler-load-string-prefix-at? normalized-path prefix 0))
      (string.substring normalized-path prefix-len (- path-len prefix-len))
      normalized-path)))

;; Dotted imports carry their canonical module identity directly. Macro imports
;; are expanded before resolution and retain the resolved-path fallback here.
(define (compiler-load-canonical-module-id-from-import-rooted
  [kind : ast.AstImportKind]
  [import-path : String]
  [resolved-path : String]
  [_ : String]) : String
  (match kind
    [(ast.AstImportKind.Module) import-path]
    [(ast.AstImportKind.ModuleAll) import-path]
    [(ast.AstImportKind.ModuleItem _) import-path]
    [_ (compiler-load-canonical-module-id-from-path resolved-path)]))

(define (compiler-load-canonical-module-id-from-import
  [kind : ast.AstImportKind]
  [import-path : String]
  [resolved-path : String]) : String
  (compiler-load-canonical-module-id-from-import-rooted
    kind
    import-path
    resolved-path
    ""))

;; Linkage ownership for a moduleless entry follows its path relative to the
;; entry root.
(define (compiler-load-decl-owner-id-from-root [root : String] [path : String]) : i64
  (let
    [normalized-path : String (compiler-load-normalize-path path)]
    [prefix : String (compiler-load-root-prefix root)]
    [prefix-len : i64 (string.string-length prefix)]
    [path-len : i64 (string.string-length normalized-path)]
    [relative : String
      (if (and
        (> prefix-len 0)
        (compiler-load-string-prefix-at? normalized-path prefix 0))
        (string.substring normalized-path prefix-len (- path-len prefix-len))
        normalized-path)]
    (ci.intern-generated-canonical-name
      (compiler-load-module-id-from-path-text relative))))

(define (compiler-load-canonical-source-module-from-import
  [kind : ast.AstImportKind]
  [import-path : String]
  [resolved-path : String]
  [_ : ast.AstMaybeModuleName]
  [_ : String]) : String
  (let
    [fallback : String
      (compiler-load-canonical-module-id-from-import
        kind
        import-path
        resolved-path)]
    fallback))

(define (compiler-load-decls-source-module [decls : ast.AstDeclList]) : String
  (match (ast.ast-decl-list-step decls)
    [(ast.AstDeclListStep.Nil) ""]
    [(ast.AstDeclListStep.Cons decl rest)
      (let
        [rest : ast.AstDeclList rest]
        (match (clone decl)
          [(ast.AstDecl.Module name) (ci.intern-str name)]
          [_ (compiler-load-decls-source-module rest)]))]))

(define (compiler-load-decls-source-module-id [decls : ast.AstDeclList]) : i64
  (match (ast.ast-decl-list-step decls)
    [(ast.AstDeclListStep.Nil) cbi.compiler-builtin-id-fix-empty]
    [(ast.AstDeclListStep.Cons decl rest)
      (let
        [rest : ast.AstDeclList rest]
        (match decl
          [(ast.AstDecl.Module name) name]
          [_ (compiler-load-decls-source-module-id rest)]))]))

(define (compiler-load-decls-source-module-or
  [decls : ast.AstDeclList]
  [fallback : String]) : String
  (match (ast.ast-decl-list-step decls)
    [(ast.AstDeclListStep.Nil) fallback]
    [(ast.AstDeclListStep.Cons decl rest)
      (let
        [rest : ast.AstDeclList rest]
        (match decl
          [(ast.AstDecl.Module name) (ci.intern-str name)]
          [_ (compiler-load-decls-source-module-or rest fallback)]))]))

;; Tag-only predicate: an index cursor reads the tag word through a borrow
;; instead of copying a 104 B row and a 144 B step result per declaration.
(define (compiler-load-decl-list-has-module? [decls : ast.AstDeclList]) : bool
  (let
    [count : i64 (ast.ast-decl-list-len (& decls))]
    [index : i64 0]
    [found : bool false]
    (begin
      (while (and (not found) (< index count))
        (begin
          (match (ast.ast-decl-list-ref-borrowed (& decls) index)
            [(ast.AstDecl.Module _) (set! found true)]
            [_ unit])
          (set! index (+ index 1))))
      found)))

(define (compiler-load-decl-list-has-module-id?
  [decls : ast.AstDeclList]
  [want : i64]) : bool
  (let
    [count : i64 (ast.ast-decl-list-len (& decls))]
    [index : i64 0]
    (begin
      (while (< index count)
        (let
          [decl : ast.AstDecl
            (ast.ast-decl-list-get (& decls) index (ast.ast-decl-fallback))]
          (begin
            (match (ast.ast-place-shared-view decl)
              [(ast.AstDecl.Module name) (when (= name want) (return true))]
              [(ast.AstDecl.ModuleBody name body-box)
                (when
                  (or
                    (= name want)
                    (compiler-load-decl-list-has-module-id?
                      (ast.ast-decl-list-box-shared-view body-box)
                      want))
                  (return true))]
              [_ unit])
            (set! index (+ index 1)))))
      false)))

(define (compiler-load-decl-list-has-extern-symbol?
  [decls : ast.AstDeclList]
  [want : String]) : bool
  (let
    [count : i64 (ast.ast-decl-list-len (& decls))]
    [index : i64 0]
    (begin
      (while (< index count)
        (let
          [decl : ast.AstDecl
            (ast.ast-decl-list-get (& decls) index (ast.ast-decl-fallback))]
          (begin
            (match decl
              [(ast.AstDecl.Extern _ _ _ metadata _)
                (when
                  (string.eq
                    (ast.ast-extern-metadata-symbol
                      (ast.ast-extern-metadata-box-shared-view metadata))
                    (clone want))
                  (return true))]
              [_ unit])
            (set! index (+ index 1)))))
      false)))

(define (compiler-load-contextual-moduleless-decls
  [decls : ast.AstDeclList]
  [source-module : String]
  [source-module-id : i64]) : ast.AstDeclList
  (if (and
    (> (string.string-length source-module) 0)
    (not
      (compiler-load-decl-list-has-module? (ast.ast-place-shared-view decls))))
    (ast.ast-decl-cons (ast.ast-decl-module-id source-module-id) decls)
    decls))

(define (compiler-load-seen-module-with-paths
  [path : String]
  [path-id : i64]
  [_ : String]
  [module-name-id : i64]
  [decls : ast.AstDeclList]
  [seen : sym_i64_env.SymI64Env]) : ResultCompilerLoadWithPaths
  (if (compiler-load-decl-list-has-module? decls)
    (ResultCompilerLoadWithPaths.Ok
      (ast.ast-decl-cons
        (ast.ast-decl-module-id module-name-id)
        (ast.ast-decl-list-new))
      (ast.ast-decl-path-list-prepend-builder-with-owner-id
        (clone path)
        path-id
        (ast.ast-decl-path-list-new))
      (ast.ast-decl-module-cons-id
        module-name-id
        (ast.ast-decl-module-list-new))
      seen)
    (ResultCompilerLoadWithPaths.Ok
      (ast.ast-decl-list-new)
      (ast.ast-decl-path-list-new)
      (ast.ast-decl-module-list-new)
      seen)))

(define (compiler-load-after-import-expected-module
  [state : CompilerLoadSessionState]
  [source-path-id : i64]
  [kind : ast.AstImportKind]
  [expected : ast.AstMaybeModuleName]
  [_ : ast.AstMaybeImportAlias]
  [imported-decls : ast.AstDeclList]) : ast.AstMaybeModuleName
  (match kind
    [(ast.AstImportKind.Module)
      (match (compiler-load-session-state-surface-summary-find-source
        state
        source-path-id)
        [(CompilerLoadSomeSurfaceSummary summary)
          (ast.AstMaybeModuleName.Some summary.declaration-module-id)]
        [(CompilerLoadNoSurfaceSummary)
          (if (compiler-load-decl-list-has-module?
            (ast.ast-place-shared-view imported-decls))
            (ast.AstMaybeModuleName.Some
              (compiler-load-decls-source-module-id imported-decls))
            expected)])]
    [(ast.AstImportKind.ModuleAll)
      (match (compiler-load-session-state-surface-summary-find-source
        state
        source-path-id)
        [(CompilerLoadSomeSurfaceSummary summary)
          (ast.AstMaybeModuleName.Some summary.declaration-module-id)]
        [(CompilerLoadNoSurfaceSummary)
          (if (compiler-load-decl-list-has-module?
            (ast.ast-place-shared-view imported-decls))
            (ast.AstMaybeModuleName.Some
              (compiler-load-decls-source-module-id imported-decls))
            expected)])]
    [(ast.AstImportKind.ModuleItem _)
      (match (compiler-load-session-state-surface-summary-find-source
        state
        source-path-id)
        [(CompilerLoadSomeSurfaceSummary summary)
          (ast.AstMaybeModuleName.Some summary.declaration-module-id)]
        [(CompilerLoadNoSurfaceSummary)
          (if (compiler-load-decl-list-has-module?
            (ast.ast-place-shared-view imported-decls))
            (ast.AstMaybeModuleName.Some
              (compiler-load-decls-source-module-id imported-decls))
            expected)])]
    [_ expected]))

(define (compiler-load-after-import-alias
  [_ : CompilerLoadSessionState]
  [_ : i64]
  [_ : ast.AstImportKind]
  [_ : ast.AstMaybeModuleName]
  [alias : ast.AstMaybeImportAlias]
  [_ : ast.AstDeclList]) : ast.AstMaybeImportAlias
  alias)

(define (compiler-load-dotted-import-alias-key
  [module-id : i64]
  [alias-id : i64]) : i64
  (ci.intern-composite-pair-id module-id alias-id))

(define (compiler-load-duplicate-dotted-import-alias-loop
  [decls : ast.AstDeclList]
  [current-module : i64]
  [seen : sym_i64_env.SymI64Env]) : CompilerLoadMaybeImportAliasCollision
  (match (ast.ast-decl-list-step decls)
    [(ast.AstDeclListStep.Nil) (CompilerLoadMaybeImportAliasCollision.No)]
    [(ast.AstDeclListStep.Cons decl rest)
      (let
        [rest : ast.AstDeclList rest]
        (match decl
          [(ast.AstDecl.Module name)
            (compiler-load-duplicate-dotted-import-alias-loop rest name seen)]
          [(ast.AstDecl.Import
              decl-meta
              (ast.AstImportSpec.Spec
                (ast.AstImportKind.Module)
                import-name
                _
                (ast.AstMaybeImportAlias.Some alias)
                span))
            (let
              [key : i64
                (compiler-load-dotted-import-alias-key current-module alias)]
              ;; Re-importing the same module under the same alias is
              ;; idempotent; only a different module under a repeated alias is
              ;; ambiguous.
              (if (sym_i64_env.sym-i64-contains-id seen key)
                (if (=
                  (sym_i64_env.sym-i64-lookup-id-or seen key -1)
                  (ci.intern
                    (owned_view.compiler-owned-shared-view import-name)))
                  (compiler-load-duplicate-dotted-import-alias-loop
                    rest
                    current-module
                    seen)
                  (CompilerLoadMaybeImportAliasCollision.Some
                    (CompilerLoadImportAliasCollision
                      (ci.intern-str alias)
                      (ci.intern-str
                        (sym_i64_env.sym-i64-lookup-id-or seen key -1))
                      import-name
                      (__tl-box-place span))))
                (compiler-load-duplicate-dotted-import-alias-loop
                  rest
                  current-module
                  (sym_i64_env.sym-i64-bind-id seen key (ci.intern import-name)))))]
          [_
            (compiler-load-duplicate-dotted-import-alias-loop
              rest
              current-module
              seen)]))]))

(define (compiler-load-check-dotted-import-aliases
  [path : String]
  [decls : ast.AstDeclList]
  [_source-module : String]) : ResultCompilerLoadAliasCheck
  (match (compiler-load-duplicate-dotted-import-alias-loop
    (ast.ast-place-shared-view decls)
    (compiler-load-decls-source-module-id decls)
    (sym_i64_env.sym-i64-empty))
    [(CompilerLoadMaybeImportAliasCollision.No)
      (ResultCompilerLoadAliasCheck.Ok)]
    [(CompilerLoadMaybeImportAliasCollision.Some collision)
      (ResultCompilerLoadAliasCheck.Err
        (box
          (cdiag.compiler-diagnostic-from-ast-span
            path
            collision.span
            (str_cat.str-cat
              "compiler-load: ambiguous import alias '"
              (str_cat.str-cat
                collision.alias
                (str_cat.str-cat
                  "' between '"
                  (str_cat.str-cat
                    collision.first-import
                    (str_cat.str-cat
                      "' and '"
                      (str_cat.str-cat
                        collision.second-import
                        "'; use distinct aliases or qualified access")))))))))]))

(define (compiler-load-unqualified-import-note
  [state : (&mut state CompilerLoadUnqualifiedImportState)]
  [importer-module : i64]
  [local-name : i64]
  [source-module : i64]
  [source-item : i64]
  [path : String]
  [span : ast.AstSourceSpan]) : CompilerLoadUnqualifiedImportStep
  (let
    [key : i64 (ci.intern-composite-pair-id importer-module local-name)]
    [source-id : i64 (ci.intern-composite-pair-id source-module source-item)]
    (match (load_i64_i64_map.get (& state.source-ids) key)
      [(load_i64_i64_map.LookupFound prior-source-id)
        (if (= prior-source-id source-id)
          (CompilerLoadUnqualifiedImportStep.Ok)
          (CompilerLoadUnqualifiedImportStep.Collision
            (CompilerLoadUnqualifiedImportCollision
              (ci.intern-str local-name)
              (ci.intern-str
                (match (load_i64_i64_map.get (& state.source-modules) key)
                  [(load_i64_i64_map.LookupFound prior-module) prior-module]
                  [(load_i64_i64_map.LookupMissing)
                    cbi.compiler-builtin-id-fix-empty]))
              (ci.intern-str source-module)
              path
              span)))]
      [(load_i64_i64_map.LookupMissing)
        (begin
          (load_i64_i64_map.insert-ref! (&mut state.source-ids) key source-id)
          (load_i64_i64_map.insert-ref!
            (&mut state.source-modules)
            key
            source-module)
          (CompilerLoadUnqualifiedImportStep.Ok))])))

(define (compiler-load-unqualified-import-note-variants
  [state : (&mut state CompilerLoadUnqualifiedImportState)]
  [importer-module : i64]
  [source-module : i64]
  [variants : (& variants ast.AstVariantDefList)]
  [index : i64]
  [path : String]
  [span : ast.AstSourceSpan]) : CompilerLoadUnqualifiedImportStep
  (if (>= index (ast.ast-variant-def-list-len variants))
    (CompilerLoadUnqualifiedImportStep.Ok)
    (match (ast.ast-variant-def-list-get
      variants
      index
      (ast.ast-variant-def-fallback))
      [(ast.AstVariantDef.Def name _ _)
        (match (compiler-load-unqualified-import-note
          state
          importer-module
          name
          source-module
          name
          (owned_view.compiler-owned-shared-view path)
          span)
          [(CompilerLoadUnqualifiedImportStep.Ok)
            (compiler-load-unqualified-import-note-variants
              state
              importer-module
              source-module
              variants
              (+ index 1)
              path
              span)]
          [(CompilerLoadUnqualifiedImportStep.Collision collision)
            (CompilerLoadUnqualifiedImportStep.Collision collision)])])))

(define (compiler-load-unqualified-import-note-decl
  [state : (&mut state CompilerLoadUnqualifiedImportState)]
  [importer-module : i64]
  [source-module : i64]
  [decl : ast.AstDecl]
  [path : String]
  [span : ast.AstSourceSpan]) : CompilerLoadUnqualifiedImportStep
  (match (ast.ast-decl-unwrapped decl)
    [(ast.AstDecl.Def _ name _ _)
      (compiler-load-unqualified-import-note
        state
        importer-module
        name
        source-module
        name
        path
        span)]
    [(ast.AstDecl.DefFn _ name _ _ _ _)
      (compiler-load-unqualified-import-note
        state
        importer-module
        name
        source-module
        name
        path
        span)]
    [(ast.AstDecl.DefMacro _ name _ _ _)
      (compiler-load-unqualified-import-note
        state
        importer-module
        name
        source-module
        name
        path
        span)]
    [(ast.AstDecl.DefDispatch _ name _)
      (compiler-load-unqualified-import-note
        state
        importer-module
        name
        source-module
        name
        path
        span)]
    [(ast.AstDecl.Extern _ name _ _ _)
      (compiler-load-unqualified-import-note
        state
        importer-module
        name
        source-module
        name
        path
        span)]
    [(ast.AstDecl.DefStruct _ name _ _ _)
      (compiler-load-unqualified-import-note
        state
        importer-module
        name
        source-module
        name
        path
        span)]
    [(ast.AstDecl.DefStructLifetimes _ name _ _ _ _)
      (compiler-load-unqualified-import-note
        state
        importer-module
        name
        source-module
        name
        path
        span)]
    [(ast.AstDecl.DefEnum _ name _ variants)
      (match (compiler-load-unqualified-import-note
        state
        importer-module
        name
        source-module
        name
        (owned_view.compiler-owned-shared-view path)
        span)
        [(CompilerLoadUnqualifiedImportStep.Ok)
          (compiler-load-unqualified-import-note-variants
            state
            importer-module
            source-module
            (& variants)
            0
            path
            span)]
        [(CompilerLoadUnqualifiedImportStep.Collision collision)
          (CompilerLoadUnqualifiedImportStep.Collision collision)])]
    [(ast.AstDecl.DefEnumLifetimes _ name _ _ variants)
      (match (compiler-load-unqualified-import-note
        state
        importer-module
        name
        source-module
        name
        (owned_view.compiler-owned-shared-view path)
        span)
        [(CompilerLoadUnqualifiedImportStep.Ok)
          (compiler-load-unqualified-import-note-variants
            state
            importer-module
            source-module
            (& variants)
            0
            path
            span)]
        [(CompilerLoadUnqualifiedImportStep.Collision collision)
          (CompilerLoadUnqualifiedImportStep.Collision collision)])]
    [_ (CompilerLoadUnqualifiedImportStep.Ok)]))

(define (compiler-load-unqualified-import-note-wildcard
  [state : (&mut state CompilerLoadUnqualifiedImportState)]
  [decls : ast.AstDeclList]
  [importer-module : i64]
  [source-module : i64]
  [path : String]
  [span : ast.AstSourceSpan]) : CompilerLoadUnqualifiedImportStep
  (let
    [cur-module : i64 cbi.compiler-builtin-id-fix-empty]
    [count : i64 (ast.ast-decl-list-len (& decls))]
    [index : i64 0]
    (begin
      (while (< index count)
        (let
          [decl : ast.AstDecl
            (ast.ast-array-shared-view decls.slots (+ decls.offset index))]
          (begin
            (match (ast.ast-place-shared-view decl)
              [(ast.AstDecl.Module next-module) (set! cur-module next-module)]
              [_
                (when
                  (= cur-module source-module)
                  (match (compiler-load-unqualified-import-note-decl
                    state
                    importer-module
                    source-module
                    decl
                    (owned_view.compiler-owned-shared-view path)
                    span)
                    [(CompilerLoadUnqualifiedImportStep.Ok) unit]
                    [(CompilerLoadUnqualifiedImportStep.Collision collision)
                      (return
                        (CompilerLoadUnqualifiedImportStep.Collision collision))]))])
            (set! index (+ index 1)))))
      (CompilerLoadUnqualifiedImportStep.Ok))))

(define (compiler-load-unqualified-import-collision-message
  [collision : CompilerLoadUnqualifiedImportCollision]) : String
  (str_cat.str-cat
    "compiler-load: ambiguous unqualified import '"
    (str_cat.str-cat
      collision.name
      (str_cat.str-cat
        "' between modules '"
        (str_cat.str-cat
          collision.first-module
          (str_cat.str-cat
            "' and '"
            (str_cat.str-cat
              collision.second-module
              "'; use explicit selected aliases or qualified access")))))))

(define (compiler-load-unqualified-import-collision-result
  [collision : CompilerLoadUnqualifiedImportCollision]) : ResultCompilerLoadAliasCheck
  (let
    [message : String
      (compiler-load-unqualified-import-collision-message
        (owned_view.compiler-owned-shared-view collision))]
    (ResultCompilerLoadAliasCheck.Err
      (box
        (cdiag.compiler-diagnostic-from-ast-span
          collision.path
          collision.span
          message)))))

(define (compiler-load-check-unqualified-import-collisions
  [fallback-path : String]
  [decls : ast.AstDeclList]
  [paths : ast.AstDeclPathList]) : ResultCompilerLoadAliasCheck
  (let
    [state : CompilerLoadUnqualifiedImportState
      (CompilerLoadUnqualifiedImportState
        (load_i64_i64_map.with-capacity 64)
        (load_i64_i64_map.with-capacity 64))]
    [cur-module : i64 cbi.compiler-builtin-id-fix-empty]
    [count : i64 (ast.ast-decl-list-len (& decls))]
    [index : i64 0]
    (begin
      (while (< index count)
        (let
          [decl : ast.AstDecl
            (ast.ast-array-shared-view decls.slots (+ decls.offset index))]
          [path : String
            (ast.ast-decl-path-list-get
              (& paths)
              index
              (owned_view.compiler-owned-shared-view fallback-path))]
          (begin
            (match decl
              [(ast.AstDecl.Module next-module) (set! cur-module next-module)]
              [(ast.AstDecl.Import
                  _
                  (ast.AstImportSpec.Spec
                    (ast.AstImportKind.ModuleAll)
                    _
                    (ast.AstMaybeModuleName.Some source-module)
                    _
                    span))
                (match (compiler-load-unqualified-import-note-wildcard
                  (&mut state)
                  (ast.ast-place-shared-view decls)
                  cur-module
                  source-module
                  path
                  (__tl-box-place span))
                  [(CompilerLoadUnqualifiedImportStep.Ok) unit]
                  [(CompilerLoadUnqualifiedImportStep.Collision collision)
                    (return
                      (compiler-load-unqualified-import-collision-result
                        collision))])]
              [(ast.AstDecl.Import
                  _
                  (ast.AstImportSpec.Spec
                    (ast.AstImportKind.ModuleItem source-item)
                    _
                    (ast.AstMaybeModuleName.Some source-module)
                    (ast.AstMaybeImportAlias.Some alias)
                    span))
                (match (compiler-load-unqualified-import-note
                  (&mut state)
                  cur-module
                  alias
                  source-module
                  source-item
                  path
                  (__tl-box-place span))
                  [(CompilerLoadUnqualifiedImportStep.Ok) unit]
                  [(CompilerLoadUnqualifiedImportStep.Collision collision)
                    (return
                      (compiler-load-unqualified-import-collision-result
                        collision))])]
              [_ unit])
            (set! index (+ index 1)))))
      (ResultCompilerLoadAliasCheck.Ok))))

(define (compiler-load-session-state-surface-summaries-reset!
  [state : CompilerLoadSessionState]) : unit
  (begin
    (set!
      (array-ref state.surface-summaries 0)
      (compiler-load-surface-summary-list-empty))
    (set! (array-ref state.lazy-import-skip-record-count 0) 0)))

(define (compiler-load-surface-summaries-reset!) : unit
  (compiler-load-session-state-surface-summaries-reset!
    (compiler-load-active-session-state-shared-view)))

(define (compiler-load-session-state-surface-summary-load-enter!
  [state : CompilerLoadSessionState]) : unit
  (let
    [depth : i64 (array-ref state.surface-summary-load-depth 0)]
    (begin
      (if (= depth 0)
        (compiler-load-session-state-surface-summaries-reset!
          (compiler-load-session-state-shared-view (& state)))
        unit)
      (set! (array-ref state.surface-summary-load-depth 0) (+ depth 1)))))

(define (compiler-load-surface-summary-load-enter!) : unit
  (compiler-load-session-state-surface-summary-load-enter!
    (compiler-load-active-session-state-shared-view)))

(define (compiler-load-session-state-surface-summary-load-exit!
  [state : CompilerLoadSessionState]) : unit
  (set!
    (array-ref state.surface-summary-load-depth 0)
    (- (array-ref state.surface-summary-load-depth 0) 1)))

(define (compiler-load-surface-summary-load-exit!) : unit
  (compiler-load-session-state-surface-summary-load-exit!
    (compiler-load-active-session-state-shared-view)))

(define (compiler-load-session-state-surface-summaries
  [state : (& state CompilerLoadSessionState)]) : CompilerLoadSurfaceSummaryList
  (compiler-load-global-array-element-shared-view state.surface-summaries 0))

(define (compiler-load-surface-summaries) : CompilerLoadSurfaceSummaryList
  (let
    [state : CompilerLoadSessionState
      (compiler-load-active-session-state-shared-view)]
    (compiler-load-session-state-surface-summaries state)))

(define (compiler-load-session-state-lazy-import-skip-count
  [state : CompilerLoadSessionState]) : i64
  (array-ref state.lazy-import-skip-record-count 0))

(define (compiler-load-lazy-import-skip-count) : i64
  (compiler-load-session-state-lazy-import-skip-count
    (compiler-load-active-session-state-shared-view)))

(define (compiler-load-session-state-lazy-import-record-skip!
  [state : CompilerLoadSessionState]) : unit
  (set!
    (array-ref state.lazy-import-skip-record-count 0)
    (+ (compiler-load-session-state-lazy-import-skip-count state) 1)))

(define (compiler-load-lazy-import-record-skip!) : unit
  (compiler-load-session-state-lazy-import-record-skip!
    (compiler-load-active-session-state-shared-view)))

(define (compiler-load-surface-summary-source-active?
  [summaries : CompilerLoadSurfaceSummaryList]
  [source-path-id : i64]) : bool
  (let
    [index : i64 0]
    (begin
      (while (<
        index
        (compiler-load-surface-summary-list-count
          (ast.ast-place-shared-view summaries)))
        (if (=
          (__tl-project-field
            (compiler-load-surface-summary-list-at
              (ast.ast-place-shared-view summaries)
              index)
            source-path-id)
          source-path-id)
          (return true)
          (set! index (+ index 1))))
      false)))

(define (compiler-load-surface-summary-list-record
  [summaries : CompilerLoadSurfaceSummaryList]
  [summary : CompilerLoadSurfaceSummary]) : CompilerLoadSurfaceSummaryList
  (let
    [len : i64
      (compiler-load-surface-summary-list-count
        (ast.ast-place-shared-view summaries))]
    [slots : (__tl_dyn-array CompilerLoadSurfaceSummary)
      (ast.ast-place-shared-view summaries.slots)]
    (begin
      (if (< len (array-length slots))
        unit
        (let
          [capacity : i64
            (if (= (array-length slots) 0)
              1
              (* (array-length slots) 2))]
          [bigger : (__tl_dyn-array CompilerLoadSurfaceSummary)
            (array.make-array CompilerLoadSurfaceSummary capacity)]
          [index : i64 0]
          (begin
            (while (< index len)
              (begin
                (set! (array-ref bigger index) (array-ref slots index))
                (set! index (+ index 1))))
            (set! slots bigger))))
      (set! (array-ref slots len) summary)
      (CompilerLoadSurfaceSummaryList slots (+ len 1)))))

(define (compiler-load-session-state-record-surface-summary!
  [state : (& state CompilerLoadSessionState)]
  [summary : CompilerLoadSurfaceSummary]) : unit
  (if (compiler-load-surface-summary-source-active?
    (compiler-load-session-state-surface-summaries state)
    summary.source-path-id)
    unit
    (set!
      (array-ref state.surface-summaries 0)
      (compiler-load-surface-summary-list-record
        (compiler-load-session-state-surface-summaries state)
        summary))))

(define (compiler-load-record-surface-summary!
  [summary : CompilerLoadSurfaceSummary]) : unit
  (let
    [state : CompilerLoadSessionState
      (compiler-load-active-session-state-shared-view)]
    (compiler-load-session-state-record-surface-summary! state summary)))

(define (compiler-load-surface-summary-find-source-in
  [summaries : CompilerLoadSurfaceSummaryList]
  [source-path-id : i64]) : CompilerLoadMaybeSurfaceSummary
  (let
    [index : i64 0]
    (begin
      (while (<
        index
        (compiler-load-surface-summary-list-count
          (ast.ast-place-shared-view summaries)))
        (let
          [summary : CompilerLoadSurfaceSummary
            (compiler-load-surface-summary-list-at
              (ast.ast-place-shared-view summaries)
              index)]
          (if (= summary.source-path-id source-path-id)
            (return (CompilerLoadSomeSurfaceSummary summary))
            (set! index (+ index 1)))))
      (CompilerLoadNoSurfaceSummary))))

(define (compiler-load-session-state-surface-summary-find-source
  [state : (& state CompilerLoadSessionState)]
  [source-path-id : i64]) : CompilerLoadMaybeSurfaceSummary
  (compiler-load-surface-summary-find-source-in
    (compiler-load-session-state-surface-summaries state)
    source-path-id))

(define (compiler-load-surface-summary-find-module-in
  [summaries : CompilerLoadSurfaceSummaryList]
  [module-id : i64]) : CompilerLoadMaybeSurfaceSummary
  (let
    [index : i64 0]
    (begin
      (while (<
        index
        (compiler-load-surface-summary-list-count
          (ast.ast-place-shared-view summaries)))
        (let
          [summary : CompilerLoadSurfaceSummary
            (compiler-load-surface-summary-list-at
              (ast.ast-place-shared-view summaries)
              index)]
          (if (= summary.module-id module-id)
            (return (CompilerLoadSomeSurfaceSummary summary))
            (set! index (+ index 1)))))
      (CompilerLoadNoSurfaceSummary))))

(define (compiler-load-session-state-surface-summary-find-module
  [state : (& state CompilerLoadSessionState)]
  [module-id : i64]) : CompilerLoadMaybeSurfaceSummary
  (compiler-load-surface-summary-find-module-in
    (compiler-load-session-state-surface-summaries state)
    module-id))

(define (compiler-load-surface-summary-find-module [module-id : i64]) : CompilerLoadMaybeSurfaceSummary
  (let
    [state : CompilerLoadSessionState
      (compiler-load-active-session-state-shared-view)]
    (compiler-load-session-state-surface-summary-find-module state module-id)))

(define (compiler-load-session-state-surface-summary-seen-expected-module?
  [state : CompilerLoadSessionState]
  [source-path-id : i64]
  [expected-module : ast.AstMaybeModuleName]
  [seen : sym_i64_env.SymI64Env]) : bool
  (match (compiler-load-session-state-surface-summary-find-source
    state
    source-path-id)
    [(CompilerLoadNoSurfaceSummary) false]
    [(CompilerLoadSomeSurfaceSummary summary)
      (and
        (match expected-module
          [(ast.AstMaybeModuleName.Some _)
            ;; A qualified alias requires a concrete declaration module.
            (not
              (=
                summary.declaration-module-id
                cbi.compiler-builtin-id-fix-empty))]
          [(ast.AstMaybeModuleName.No) summary.qualified-load])
        (compiler-load-seen-module-contains? seen "" summary.module-id))]))

(define (compiler-load-surface-summary-seen-expected-module?
  [source-path-id : i64]
  [expected-module : ast.AstMaybeModuleName]
  [seen : sym_i64_env.SymI64Env]) : bool
  (compiler-load-session-state-surface-summary-seen-expected-module?
    (compiler-load-active-session-state-shared-view)
    source-path-id
    expected-module
    seen))

(define (compiler-load-seen-expected-module-with-paths
  [state : CompilerLoadSessionState]
  [path : String]
  [source-path-id : i64]
  [expected-module : ast.AstMaybeModuleName]
  [seen : sym_i64_env.SymI64Env]) : ResultCompilerLoadWithPaths
  (match (compiler-load-session-state-surface-summary-find-source
    state
    source-path-id)
    [(CompilerLoadNoSurfaceSummary)
      (ResultCompilerLoadWithPaths.Ok
        (ast.ast-decl-list-new)
        (ast.ast-decl-path-list-new)
        (ast.ast-decl-module-list-new)
        seen)]
    [(CompilerLoadSomeSurfaceSummary summary)
      (let
        [module-id : i64 summary.module-id]
        (match expected-module
          [(ast.AstMaybeModuleName.Some expected-id)
            (when
              (and summary.explicit-module (not (= module-id expected-id)))
              (return
                (ResultCompilerLoadWithPaths.Err
                  (box
                    (cdiag.compiler-diagnostic-at-start
                      (clone path)
                      (str_cat.str-cat
                        "compiler-load: import expected module "
                        (ci.intern-str expected-id)
                        " but loaded "
                        (ci.intern-syntax-name-text-or
                          module-id
                          "<structural-module>")))))))]
          [(ast.AstMaybeModuleName.No) unit])
        (if (match expected-module
          [(ast.AstMaybeModuleName.Some expected-id) (= module-id expected-id)]
          [(ast.AstMaybeModuleName.No) false])
          (ResultCompilerLoadWithPaths.Ok
            (ast.ast-decl-cons
              (ast.ast-decl-module-id module-id)
              (ast.ast-decl-list-new))
            (ast.ast-decl-path-list-prepend-builder-with-owner-id
              path
              source-path-id
              (ast.ast-decl-path-list-new))
            (ast.ast-decl-module-cons-id
              module-id
              (ast.ast-decl-module-list-new))
            seen)
          (ResultCompilerLoadWithPaths.Ok
            (ast.ast-decl-list-new)
            (ast.ast-decl-path-list-new)
            (ast.ast-decl-module-list-new)
            seen)))]))

(define (compiler-load-resolved-path-id-for-generated-import-with-state
  [state : CompilerLoadSessionState]
  [resolved : String]
  [expected-module : ast.AstMaybeModuleName]) : i64
  (match expected-module
    [(ast.AstMaybeModuleName.No) (ci.intern-generated-canonical-name resolved)]
    [(ast.AstMaybeModuleName.Some module-id)
      (match (compiler-load-session-state-surface-summary-find-module
        state
        module-id)
        [(CompilerLoadNoSurfaceSummary)
          (ci.intern-generated-canonical-name resolved)]
        [(CompilerLoadSomeSurfaceSummary summary)
          (if (string.eq
            summary.source-path
            (compiler-load-normalize-path resolved))
            summary.source-path-id
            (ci.intern-generated-canonical-name resolved))])]))

;; Serial/test compatibility adapter.
(define (compiler-load-surface-summary-remove-source-in
  [summaries : CompilerLoadSurfaceSummaryList]
  [source-path-id : i64]) : CompilerLoadSurfaceSummaryList
  (let
    [len : i64
      (compiler-load-surface-summary-list-count
        (ast.ast-place-shared-view summaries))]
    [kept : i64 0]
    [physical-index : i64 0]
    (begin
      (while (< physical-index len)
        (begin
          (if (not
            (=
              (__tl-project-field
                (array-ref summaries.slots physical-index)
                source-path-id)
              source-path-id))
            (set! kept (+ kept 1))
            unit)
          (set! physical-index (+ physical-index 1))))
      (if (= kept len)
        summaries
        (let
          [slots : (__tl_dyn-array CompilerLoadSurfaceSummary)
            (array.make-array CompilerLoadSurfaceSummary kept)]
          [read-index : i64 0]
          [write-index : i64 0]
          (begin
            (while (< read-index len)
              (let
                [summary : CompilerLoadSurfaceSummary
                  (clone (array-ref summaries.slots read-index))]
                (begin
                  (if (not (= summary.source-path-id source-path-id))
                    (begin
                      (set! (array-ref slots write-index) summary)
                      (set! write-index (+ write-index 1)))
                    unit)
                  (set! read-index (+ read-index 1)))))
            (CompilerLoadSurfaceSummaryList slots kept)))))))

(define (compiler-load-session-state-surface-summary-remove-source!
  [state : CompilerLoadSessionState]
  [source-path-id : i64]) : unit
  (set!
    (array-ref state.surface-summaries 0)
    (compiler-load-surface-summary-remove-source-in
      (compiler-load-session-state-surface-summaries state)
      source-path-id)))

(define (compiler-load-surface-summary-remove-source! [source-path-id : i64]) : unit
  (compiler-load-session-state-surface-summary-remove-source!
    (compiler-load-active-session-state-shared-view)
    source-path-id))

(define (compiler-load-surface-summary-load-with-pools
  [load-state : CompilerLoadSessionState]
  [path : String]
  [parse-identity : CompilerLoadParseIdentity]
  [stdlib-roots : svec.Vec]
  [expected-module : ast.AstMaybeModuleName]
  [import-root : String]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]) : unit
  (let
    [parse-cfgs : sym_i64_env.SymI64Env cfgs]
    [source-path-id : i64 parse-identity.source-path-id]
    [fallback-id : i64 parse-identity.module-fallback-id]
    (match (if (io.file-exists? (clone path))
      (compiler-load-parse-file-diagnostic-session-id-with-pools
        (compiler-load-session-state-shared-view (& load-state))
        (clone path)
        source-path-id
        (ast.ast-place-shared-view stdlib-roots)
        (sym_i64_env.sym-i64-shared-view (& parse-cfgs))
        (ast.ast-place-shared-view pools))
      (match (compiler-load-embedded-stdlib-source-for-path (clone path))
        [(ces.CompilerEmbeddedStdlibSource.CompilerEmbeddedStdlibSomeSource
            source)
          (compiler-load-parse-embedded-source-diagnostic-session-id-with-pools
            (compiler-load-session-state-shared-view (& load-state))
            (clone path)
            source-path-id
            source
            (sym_i64_env.sym-i64-shared-view (& parse-cfgs))
            (ast.ast-place-shared-view pools))]
        [(ces.CompilerEmbeddedStdlibSource.CompilerEmbeddedStdlibNoSource)
          (parser.ResultAstProgramDiagnostic.Err
            (box
              (cdiag.compiler-diagnostic-at-start
                (clone path)
                (str_cat.str-cat
                  "compiler-load: cannot read import "
                  (clone path)))))]))
      [(parser.ResultAstProgramDiagnostic.Ok program)
        (match (compiler-load-surface-summary-build
          (clone path)
          source-path-id
          import-root
          program
          fallback-id
          (not (compiler-load-no-expected-module? expected-module)))
          [(ResultCompilerLoadSurfaceSummary.Ok summary)
            (compiler-load-session-state-record-surface-summary!
              load-state
              summary)]
          [(ResultCompilerLoadSurfaceSummary.Err _) unit])]
      [(parser.ResultAstProgramDiagnostic.Err _) unit])))

(define (compiler-load-surface-summary-ensure-with-pools
  [load-state : CompilerLoadSessionState]
  [path : String]
  [source-path-id : i64]
  [stdlib-roots : svec.Vec]
  [expected-module : ast.AstMaybeModuleName]
  [import-root : String]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]) : unit
  (let
    [fallback : String (compiler-load-canonical-module-id-from-path path)]
    [parse-identity : CompilerLoadParseIdentity
      (CompilerLoadParseIdentity
        source-path-id
        (compiler-load-module-fallback-id-for-parse fallback expected-module)
        cbi.compiler-builtin-id-fix-empty)]
    (match (compiler-load-session-state-surface-summary-find-source
      load-state
      parse-identity.source-path-id)
      [(CompilerLoadSomeSurfaceSummary _) unit]
      [(CompilerLoadNoSurfaceSummary)
        (compiler-load-surface-summary-load-with-pools
          load-state
          path
          parse-identity
          stdlib-roots
          expected-module
          import-root
          cfgs
          pools)])))

(define (compiler-load-surface-summary-refresh-with-state-and-pools
  [load-state : CompilerLoadSessionState]
  [path : String]
  [source-path-id : i64]
  [stdlib-roots : svec.Vec]
  [expected-module : ast.AstMaybeModuleName]
  [import-root : String]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]) : unit
  (let
    [fallback : String (compiler-load-canonical-module-id-from-path path)]
    [parse-identity : CompilerLoadParseIdentity
      (CompilerLoadParseIdentity
        source-path-id
        (compiler-load-module-fallback-id-for-parse fallback expected-module)
        cbi.compiler-builtin-id-fix-empty)]
    (begin
      (compiler-load-session-state-surface-summary-remove-source!
        (compiler-load-session-state-shared-view (& load-state))
        parse-identity.source-path-id)
      (compiler-load-surface-summary-load-with-pools
        (compiler-load-session-state-shared-view (& load-state))
        path
        parse-identity
        stdlib-roots
        expected-module
        import-root
        cfgs
        pools))))

(define (compiler-load-surface-summary-refresh-with-pools
  [path : String]
  [source-path-id : i64]
  [stdlib-roots : svec.Vec]
  [expected-module : ast.AstMaybeModuleName]
  [import-root : String]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]) : unit
  ;; Typecheck/package compatibility path; driver-owned loading calls the
  ;; state-taking traversal functions above.
  (compiler-load-surface-summary-refresh-with-state-and-pools
    (compiler-load-active-session-state-shared-view)
    path
    source-path-id
    stdlib-roots
    expected-module
    import-root
    cfgs
    pools))

(define (compiler-load-surface-summary-decl-requires-eager?
  [decl : CompilerLoadSurfaceDecl]) : bool
  (or
    (match decl.kind
      [(CompilerLoadSurfaceExtern) true]
      [_ false])
    decl.has-cleanup
    decl.has-export
    decl.has-generated-meta))

(define (compiler-load-surface-summary-decls-require-eager?
  [decls : (& decls CompilerLoadSurfaceDeclList)]) : bool
  (let
    [index : i64 0]
    (begin
      (while (< index (compiler-load-surface-decl-list-count decls))
        (if (compiler-load-surface-summary-decl-requires-eager?
          (compiler-load-surface-decl-list-at decls index))
          (return true)
          (set! index (+ index 1))))
      false)))

(define (compiler-load-surface-summary-requires-eager?
  [summary : CompilerLoadSurfaceSummary]) : bool
  (or
    summary.has-tests
    summary.has-export-metadata
    summary.has-generated-decls
    summary.has-decl-emitting-macro
    (compiler-load-surface-summary-decls-require-eager? summary.decls)))

(define (compiler-load-lazy-alias-demand-none) : CompilerLoadLazyAliasDemand
  (CompilerLoadLazyAliasDemand false false false (sym_i64_env.sym-i64-empty)))

(define (compiler-load-lazy-alias-demand-qualified [member : i64]) : CompilerLoadLazyAliasDemand
  (CompilerLoadLazyAliasDemand
    true
    false
    false
    (sym_i64_env.sym-i64-bind-id (sym_i64_env.sym-i64-empty) member 1)))

(define (compiler-load-lazy-alias-demand-direct) : CompilerLoadLazyAliasDemand
  (CompilerLoadLazyAliasDemand false true false (sym_i64_env.sym-i64-empty)))

(define (compiler-load-lazy-alias-demand-unknown) : CompilerLoadLazyAliasDemand
  (CompilerLoadLazyAliasDemand false false true (sym_i64_env.sym-i64-empty)))

(define (compiler-load-structural-member-set-add-id
  [members : sym_i64_env.SymI64Env]
  [member-id : i64]) : sym_i64_env.SymI64Env
  (if (sym_i64_env.sym-i64-contains-id members member-id)
    members
    (sym_i64_env.sym-i64-bind-id members member-id 1)))

(define (compiler-load-structural-member-set-union-from
  [members : sym_i64_env.SymI64Env]
  [additions : sym_i64_env.SymI64Env]) : sym_i64_env.SymI64Env
  (match (sym_i64_env.sym-i64-view additions)
    [(sym_i64_env.SymI64ViewNil) members]
    [(sym_i64_env.SymI64ViewBind member-id _ rest)
      (compiler-load-structural-member-set-add-id
        (compiler-load-structural-member-set-union-from members rest)
        member-id)]))

(define (compiler-load-structural-member-set-union
  [left : sym_i64_env.SymI64Env]
  [right : sym_i64_env.SymI64Env]) : sym_i64_env.SymI64Env
  (match (sym_i64_env.sym-i64-view (sym_i64_env.sym-i64-shared-view (& left)))
    [(sym_i64_env.SymI64ViewNil) right]
    [_
      (match (sym_i64_env.sym-i64-view
        (sym_i64_env.sym-i64-shared-view (& right)))
        [(sym_i64_env.SymI64ViewNil) left]
        [_ (compiler-load-structural-member-set-union-from left right)])]))

(define (compiler-load-lazy-alias-demand-merge
  [left : CompilerLoadLazyAliasDemand]
  [right : CompilerLoadLazyAliasDemand]) : CompilerLoadLazyAliasDemand
  (CompilerLoadLazyAliasDemand
    (or left.qualified right.qualified)
    (or left.direct right.direct)
    (or left.unknown right.unknown)
    (compiler-load-structural-member-set-union left.members right.members)))

(define (compiler-load-lazy-dotted-tail-after-prefix-id
  [name : i64]
  [prefix : i64]) : i64
  (if (ci.intern-dotted? prefix)
    (if (and
      (ci.intern-dotted? name)
      (= (ci.intern-leading-dot-id name) (ci.intern-leading-dot-id prefix)))
      (compiler-load-lazy-dotted-tail-after-prefix-id
        (ci.intern-dotted-tail-id name)
        (ci.intern-dotted-tail-id prefix))
      -1)
    (if (and
      (ci.intern-dotted? name)
      (= (ci.intern-leading-dot-id name) prefix))
      (ci.intern-dotted-tail-id name)
      -1)))

(define (compiler-load-lazy-tail-after-prefix-id [name : i64] [alias : i64]) : i64
  (unless
    (and (ci.intern-renderable-id? name) (ci.intern-renderable-id? alias))
    (return -1))
  (if (ci.intern-qualified? name)
    (if (= (ci.intern-qualified-module-id name) alias)
      (ci.intern-qualified-base-id name)
      -1)
    (compiler-load-lazy-dotted-tail-after-prefix-id name alias)))

;; A catalog selector can ask one existing structural demand walk to retain the
;; first member below an alias root for every qualified use it sees. This keeps
;; the ordinary three-bit result intact while avoiding one whole-program walk
;; per candidate member of a generated Module catalog. The observer is strictly
;; dynamic and single-threaded. Nested demand queries save only an active outer
;; observer; a top-level query clears the stack without copying inactive state
;; that may belong to a reclaimed batch-entry arena.
;; The primary root drives the ordinary demand result; a second root is observed
;; opportunistically during that same walk so generated-catalog selection does
;; not traverse the importer program a second time for its canonical module.
(defstruct CompilerLoadLazyQualifiedObserverResult
  (primary-members sym_i64_env.SymI64Env)
  (secondary-members sym_i64_env.SymI64Env)
  (secondary-qualified bool)
  (secondary-direct bool))

(define (compiler-load-session-state-lazy-qualified-observer
  [state : (& state CompilerLoadSessionState)]) : (&
    state
    CompilerLoadLazyQualifiedObserverState)
  (& state.lazy-qualified-observer))

(define (compiler-load-lazy-qualified-observer-flag
  [observer : (& observer CompilerLoadLazyQualifiedObserverState)]
  [index : i64]) : bool
  (array-ref observer.flags index))

(define (compiler-load-lazy-qualified-observer-flag-set!
  [observer : (& observer CompilerLoadLazyQualifiedObserverState)]
  [index : i64]
  [value : bool]) : unit
  (set! (array-ref observer.flags index) value))

(define (compiler-load-lazy-qualified-observer-root-id
  [observer : (& observer CompilerLoadLazyQualifiedObserverState)]
  [index : i64]) : i64
  (array-ref observer.root-ids index))

(define (compiler-load-lazy-qualified-observer-root-id-set!
  [observer : (& observer CompilerLoadLazyQualifiedObserverState)]
  [index : i64]
  [value : i64]) : unit
  (set! (array-ref observer.root-ids index) value))

(define (compiler-load-lazy-qualified-observer-members
  [observer : (& observer CompilerLoadLazyQualifiedObserverState)]
  [index : i64]) : sym_i64_env.SymI64Env
  (sym_i64_env.sym-i64-shared-view (& (array-ref observer.member-sets index))))

(define (compiler-load-lazy-qualified-observer-members-set!
  [observer : (& observer CompilerLoadLazyQualifiedObserverState)]
  [index : i64]
  [value : sym_i64_env.SymI64Env]) : unit
  (set! (array-ref observer.member-sets index) value))

(define (compiler-load-session-state-lazy-qualified-observer-active?
  [state : (& state CompilerLoadSessionState)]) : bool
  (let
    [observer : (& state CompilerLoadLazyQualifiedObserverState)
      (compiler-load-session-state-lazy-qualified-observer state)]
    (compiler-load-lazy-qualified-observer-flag observer 0)))

(define (compiler-load-session-state-lazy-qualified-observer-exhaustive?
  [state : (& state CompilerLoadSessionState)]) : bool
  (let
    [observer : (& state CompilerLoadLazyQualifiedObserverState)
      (compiler-load-session-state-lazy-qualified-observer state)]
    (compiler-load-lazy-qualified-observer-flag observer 1)))

;; Serial/test compatibility adapters. Production demand walks receive their
;; owning session explicitly and must not observe the active selector.
;; Catalog observers only need lexical bindings that shadow either observed
;; root. Avoid allocating a lexical environment spine for every unrelated
;; parameter, binding, and pattern during those full scans while preserving
;; exact treatment of a local alias-name binding.
(define (compiler-load-session-state-lazy-demand-bind-local-exhaustive
  [state : (& state CompilerLoadSessionState)]
  [locals : sym_i64_env.SymI64Env]
  [name : i64]) : sym_i64_env.SymI64Env
  (let
    [observer : (& state CompilerLoadLazyQualifiedObserverState)
      (compiler-load-session-state-lazy-qualified-observer state)]
    (if (or
      (= name (compiler-load-lazy-qualified-observer-root-id observer 0))
      (= name (compiler-load-lazy-qualified-observer-root-id observer 1)))
      (sym_i64_env.sym-i64-bind-id locals name 1)
      locals)))

(define (compiler-load-session-state-lazy-qualified-observer-reset!
  [state : (& state CompilerLoadSessionState)]) : unit
  (let
    [observer : (& state CompilerLoadLazyQualifiedObserverState)
      (compiler-load-session-state-lazy-qualified-observer state)]
    (begin
      (compiler-load-lazy-qualified-observer-flag-set! observer 0 false)
      (compiler-load-lazy-qualified-observer-flag-set! observer 1 false)
      (compiler-load-lazy-qualified-observer-root-id-set! observer 0 0)
      (compiler-load-lazy-qualified-observer-members-set!
        observer
        0
        (sym_i64_env.sym-i64-empty))
      (compiler-load-lazy-qualified-observer-root-id-set! observer 1 0)
      (compiler-load-lazy-qualified-observer-members-set!
        observer
        1
        (sym_i64_env.sym-i64-empty))
      (compiler-load-lazy-qualified-observer-flag-set! observer 2 false)
      (compiler-load-lazy-qualified-observer-flag-set! observer 3 false)
      (set!
        (array-ref observer.stack 0)
        (compiler-load-lazy-qualified-observer-stack-empty)))))

(define (compiler-load-lazy-qualified-observer-reset!) : unit
  (let
    [state : CompilerLoadSessionState
      (compiler-load-active-session-state-shared-view)]
    (compiler-load-session-state-lazy-qualified-observer-reset! state)))

(define (compiler-load-session-state-lazy-qualified-observer-begin-pair!
  [state : (& state CompilerLoadSessionState)]
  [root-id : i64]
  [secondary-root-id : i64]) : unit
  (let
    [observer : (& state CompilerLoadLazyQualifiedObserverState)
      (compiler-load-session-state-lazy-qualified-observer state)]
    (begin
      ;; A top-level query may follow a completed batch entry whose inactive
      ;; observer frame belonged to the reclaimed entry arena. Clear it before
      ;; preserving the ordinary push/pop semantics used by the demand walker.
      (if (compiler-load-session-state-lazy-qualified-observer-active? state)
        unit
        (compiler-load-session-state-lazy-qualified-observer-reset! state))
      (set!
        (array-ref observer.stack 0)
        (compiler-load-lazy-qualified-observer-stack-push
          (compiler-load-global-array-element-shared-view observer.stack 0)
          (CompilerLoadLazyQualifiedObserverFrame
            (compiler-load-lazy-qualified-observer-flag observer 0)
            (compiler-load-lazy-qualified-observer-flag observer 1)
            (compiler-load-lazy-qualified-observer-root-id observer 0)
            (compiler-load-lazy-qualified-observer-members observer 0)
            (compiler-load-lazy-qualified-observer-root-id observer 1)
            (compiler-load-lazy-qualified-observer-members observer 1)
            (compiler-load-lazy-qualified-observer-flag observer 2)
            (compiler-load-lazy-qualified-observer-flag observer 3))))
      (compiler-load-lazy-qualified-observer-flag-set! observer 1 true)
      (compiler-load-lazy-qualified-observer-flag-set! observer 0 true)
      (compiler-load-lazy-qualified-observer-root-id-set! observer 0 root-id)
      (compiler-load-lazy-qualified-observer-members-set!
        observer
        0
        (sym_i64_env.sym-i64-empty))
      (compiler-load-lazy-qualified-observer-root-id-set!
        observer
        1
        secondary-root-id)
      (compiler-load-lazy-qualified-observer-members-set!
        observer
        1
        (sym_i64_env.sym-i64-empty))
      (compiler-load-lazy-qualified-observer-flag-set! observer 2 false)
      (compiler-load-lazy-qualified-observer-flag-set! observer 3 false))))

(define (compiler-load-lazy-qualified-observer-members-with-note
  [name : i64]
  [root-id : i64]
  [members : sym_i64_env.SymI64Env]) : sym_i64_env.SymI64Env
  (let
    [member-id : i64 (compiler-load-lazy-qualified-member-id name root-id)]
    (if (< member-id 0)
      members
      (compiler-load-structural-member-set-add-id members member-id))))

(define (compiler-load-session-state-lazy-qualified-observer-note!
  [state : (& state CompilerLoadSessionState)]
  [name : i64]) : unit
  (let
    [observer : (& state CompilerLoadLazyQualifiedObserverState)
      (compiler-load-session-state-lazy-qualified-observer state)]
    (compiler-load-lazy-qualified-observer-members-set!
      observer
      0
      (compiler-load-lazy-qualified-observer-members-with-note
        name
        (compiler-load-lazy-qualified-observer-root-id observer 0)
        (compiler-load-lazy-qualified-observer-members observer 0)))))

(define (compiler-load-session-state-lazy-qualified-observer-note-secondary!
  [state : (& state CompilerLoadSessionState)]
  [name : i64]
  [locals : sym_i64_env.SymI64Env]) : unit
  (let
    [observer : (& state CompilerLoadLazyQualifiedObserverState)
      (compiler-load-session-state-lazy-qualified-observer state)]
    [secondary-root-id : i64
      (compiler-load-lazy-qualified-observer-root-id observer 1)]
    (begin
      (if (compiler-load-lazy-name-qualified-by-id? name secondary-root-id)
        (begin
          (compiler-load-lazy-qualified-observer-flag-set! observer 2 true)
          (compiler-load-lazy-qualified-observer-members-set!
            observer
            1
            (compiler-load-lazy-qualified-observer-members-with-note
              name
              secondary-root-id
              (compiler-load-lazy-qualified-observer-members observer 1))))
        (if (and
          (not (sym_i64_env.sym-i64-contains-id locals name))
          (= name secondary-root-id))
          (compiler-load-lazy-qualified-observer-flag-set! observer 3 true)
          unit))
      unit)))

(define (compiler-load-session-state-lazy-qualified-observer-end-pair!
  [state : (& state CompilerLoadSessionState)]) : CompilerLoadLazyQualifiedObserverResult
  (let
    [observer : (& state CompilerLoadLazyQualifiedObserverState)
      (compiler-load-session-state-lazy-qualified-observer state)]
    [out : CompilerLoadLazyQualifiedObserverResult
      (CompilerLoadLazyQualifiedObserverResult
        (compiler-load-lazy-qualified-observer-members observer 0)
        (compiler-load-lazy-qualified-observer-members observer 1)
        (compiler-load-lazy-qualified-observer-flag observer 2)
        (compiler-load-lazy-qualified-observer-flag observer 3))]
    [stack : CompilerLoadLazyQualifiedObserverStack
      (compiler-load-global-array-element-shared-view observer.stack 0)]
    [len : i64 (compiler-load-lazy-qualified-observer-stack-count stack)]
    (begin
      (if (= len 0)
        ;; Preserve the historical empty-pop behavior: return the current
        ;; observation above, then leave the observer fully inactive.
        (compiler-load-session-state-lazy-qualified-observer-reset! state)
        (let
          [frame : CompilerLoadLazyQualifiedObserverFrame
            (clone (array-ref stack.slots (- len 1)))]
          (begin
            (set!
              (array-ref observer.stack 0)
              (CompilerLoadLazyQualifiedObserverStack stack.slots (- len 1)))
            (compiler-load-lazy-qualified-observer-flag-set!
              observer
              0
              frame.active)
            (compiler-load-lazy-qualified-observer-flag-set!
              observer
              1
              frame.exhaustive)
            (compiler-load-lazy-qualified-observer-root-id-set!
              observer
              0
              frame.root-id)
            (compiler-load-lazy-qualified-observer-members-set!
              observer
              0
              frame.members)
            (compiler-load-lazy-qualified-observer-root-id-set!
              observer
              1
              frame.secondary-root-id)
            (compiler-load-lazy-qualified-observer-members-set!
              observer
              1
              frame.secondary-members)
            (compiler-load-lazy-qualified-observer-flag-set!
              observer
              2
              frame.secondary-qualified)
            (compiler-load-lazy-qualified-observer-flag-set!
              observer
              3
              frame.secondary-direct))))
      out)))

(define (compiler-load-lazy-name-qualified-by-id? [name : i64] [alias : i64]) : bool
  (>= (compiler-load-lazy-tail-after-prefix-id name alias) 0))

(define (compiler-load-lazy-qualified-member-id [name : i64] [alias : i64]) : i64
  (let
    [base : i64 (compiler-load-lazy-tail-after-prefix-id name alias)]
    (if (ci.intern-dotted? base)
      (ci.intern-leading-dot-id base)
      base)))

(define (compiler-load-lazy-surface-variant-direct-name?
  [variants : ast.AstVariantDefList]
  [name : i64]) : bool
  (compiler-load-lazy-surface-variant-direct-name-at? (& variants) name 0))

(define (compiler-load-lazy-surface-variant-direct-name-at?
  [variants : (& variants ast.AstVariantDefList)]
  [name : i64]
  [index : i64]) : bool
  (if (>= index (ast.ast-variant-def-list-len variants))
    false
    (match (ast.ast-variant-def-list-get
      variants
      index
      (ast.ast-variant-def-fallback))
      [(ast.AstVariantDef.Def variant-name _ _)
        (or
          (= variant-name name)
          (compiler-load-lazy-surface-variant-direct-name-at?
            variants
            name
            (+ index 1)))])))

(define (compiler-load-lazy-surface-decl-direct-name?
  [decl : CompilerLoadSurfaceDecl]
  [name : i64]) : bool
  (or
    (= decl.name name)
    (match decl.signature
      [(CompilerLoadSurfaceEnumSignature _ _ variants)
        (compiler-load-lazy-surface-variant-direct-name? variants name)]
      [_ false])))

(define (compiler-load-lazy-surface-decls-direct-name?
  [decls : CompilerLoadSurfaceDeclList]
  [name : i64]) : bool
  (let
    [index : i64 0]
    (begin
      (while (< index (compiler-load-surface-decl-list-count decls))
        (if (compiler-load-lazy-surface-decl-direct-name?
          (compiler-load-surface-decl-list-at decls index)
          name)
          (return true)
          (set! index (+ index 1))))
      false)))

(define (compiler-load-session-state-lazy-name-demand
  [state : CompilerLoadSessionState]
  [name : i64]
  [alias : i64]
  [summary : CompilerLoadSurfaceSummary]
  [locals : sym_i64_env.SymI64Env]) : CompilerLoadLazyAliasDemand
  (begin
    (if (compiler-load-session-state-lazy-qualified-observer-active? state)
      (compiler-load-session-state-lazy-qualified-observer-note-secondary!
        state
        name
        (sym_i64_env.sym-i64-shared-view (& locals)))
      unit)
    (cond
      [(compiler-load-lazy-name-qualified-by-id? name alias)
        (let
          [member-id : i64 (compiler-load-lazy-qualified-member-id name alias)]
          (if (< member-id 0)
            (compiler-load-lazy-alias-demand-unknown)
            (begin
              (if (compiler-load-session-state-lazy-qualified-observer-active?
                state)
                (compiler-load-session-state-lazy-qualified-observer-note!
                  state
                  name)
                unit)
              (compiler-load-lazy-alias-demand-qualified member-id))))]
      [(sym_i64_env.sym-i64-contains-id locals name)
        (compiler-load-lazy-alias-demand-none)]
      [(or
          (= name alias)
          (compiler-load-lazy-surface-decls-direct-name? summary.decls name))
        (compiler-load-lazy-alias-demand-direct)]
      [else (compiler-load-lazy-alias-demand-none)])))

(define (compiler-load-surface-decl-decl-emitting?
  [decl : CompilerLoadSurfaceDecl]) : bool
  (and
    (match decl.kind
      [(CompilerLoadSurfaceMacro) true]
      [_ false])
    (match decl.macro-result
      [(CompilerLoadSurfaceMacroModule) true]
      [(CompilerLoadSurfaceMacroDecls) true]
      [_ false])))

(define (compiler-load-surface-decls-decl-emitting-only?
  [decls : CompilerLoadSurfaceDeclList]) : bool
  (let
    [len : i64 (compiler-load-surface-decl-list-count decls)]
    [index : i64 0]
    (begin
      (when (= len 0) (return false))
      (while (< index len)
        (if (not
          (compiler-load-surface-decl-decl-emitting?
            (compiler-load-surface-decl-list-at decls index)))
          (return false)
          (set! index (+ index 1))))
      true)))

(define (compiler-load-surface-lazy-policy
  [decls : CompilerLoadSurfaceDeclList]
  [has-tests : bool]
  [has-export-metadata : bool]
  [has-generated-decls : bool]
  [has-decl-emitting-macro : bool]) : CompilerLoadLazyImportPolicy
  (if (or
    has-tests
    has-export-metadata
    has-generated-decls
    (compiler-load-surface-summary-decls-require-eager? decls))
    (CompilerLoadLazyImportEager)
    (if has-decl-emitting-macro
      (if (compiler-load-surface-decls-decl-emitting-only? decls)
        (CompilerLoadLazyImportQualified)
        (CompilerLoadLazyImportEager))
      (CompilerLoadLazyImportDirect))))

(define (compiler-load-lazy-alias-demand-requires-load?
  [policy : CompilerLoadLazyImportPolicy]
  [demand : CompilerLoadLazyAliasDemand]) : bool
  (match policy
    [(CompilerLoadLazyImportEager) true]
    [(CompilerLoadLazyImportQualified) (or demand.qualified demand.unknown)]
    [(CompilerLoadLazyImportDirect)
      (or demand.qualified demand.direct demand.unknown)]))

(define (compiler-load-session-state-lazy-type-id-demand
  [state : CompilerLoadSessionState]
  [type-id : i64]
  [alias : i64]
  [summary : CompilerLoadSurfaceSummary]
  [locals : sym_i64_env.SymI64Env]) : CompilerLoadLazyAliasDemand
  (compiler-load-session-state-lazy-type-demand
    state
    (ast.ty-node-get type-id)
    alias
    summary
    locals))

(define (compiler-load-session-state-lazy-type-list-demand-at?
  [state : CompilerLoadSessionState]
  [types : (& types ast.AstTypeList)]
  [alias : i64]
  [summary : CompilerLoadSurfaceSummary]
  [locals : sym_i64_env.SymI64Env]
  [index : i64]) : CompilerLoadLazyAliasDemand
  (if (>= index (ast.ast-type-list-len types))
    (compiler-load-lazy-alias-demand-none)
    (compiler-load-lazy-alias-demand-merge
      (compiler-load-session-state-lazy-type-id-demand
        (compiler-load-session-state-shared-view (& state))
        (ast.ast-type-list-get types index (ast.ast-type-id-fallback))
        alias
        (ast.ast-place-shared-view summary)
        (sym_i64_env.sym-i64-shared-view (& locals)))
      (compiler-load-session-state-lazy-type-list-demand-at?
        state
        types
        alias
        summary
        locals
        (+ index 1)))))

(define (compiler-load-session-state-lazy-type-list-demand
  [state : CompilerLoadSessionState]
  [types : ast.AstTypeList]
  [alias : i64]
  [summary : CompilerLoadSurfaceSummary]
  [locals : sym_i64_env.SymI64Env]) : CompilerLoadLazyAliasDemand
  (compiler-load-session-state-lazy-type-list-demand-at?
    state
    (& types)
    alias
    summary
    locals
    0))

(define (compiler-load-session-state-lazy-type-demand
  [state : CompilerLoadSessionState]
  [ty : ast.AstType]
  [alias : i64]
  [summary : CompilerLoadSurfaceSummary]
  [locals : sym_i64_env.SymI64Env]) : CompilerLoadLazyAliasDemand
  (match ty
    [(ast.AstType.Func args ret)
      (compiler-load-lazy-alias-demand-merge
        (compiler-load-session-state-lazy-type-list-demand
          (compiler-load-session-state-shared-view (& state))
          (ast.ast-type-list-box-shared-view args)
          alias
          (ast.ast-place-shared-view summary)
          (sym_i64_env.sym-i64-shared-view (& locals)))
        (compiler-load-session-state-lazy-type-id-demand
          state
          ret
          alias
          summary
          locals))]
    [(ast.AstType.Tuple items)
      (compiler-load-session-state-lazy-type-list-demand
        state
        (ast.ast-type-list-box-shared-view items)
        alias
        summary
        locals)]
    [(ast.AstType.Array elem _)
      (compiler-load-session-state-lazy-type-id-demand
        state
        elem
        alias
        summary
        locals)]
    [(ast.AstType.DynArray elem)
      (compiler-load-session-state-lazy-type-id-demand
        state
        elem
        alias
        summary
        locals)]
    [(ast.AstType.Slice elem)
      (compiler-load-session-state-lazy-type-id-demand
        state
        elem
        alias
        summary
        locals)]
    [(ast.AstType.Box elem)
      (compiler-load-session-state-lazy-type-id-demand
        state
        elem
        alias
        summary
        locals)]
    [(ast.AstType.Region _ inner)
      (compiler-load-session-state-lazy-type-id-demand
        state
        inner
        alias
        summary
        locals)]
    [(ast.AstType.Ref _ inner)
      (compiler-load-session-state-lazy-type-id-demand
        state
        inner
        alias
        summary
        locals)]
    [(ast.AstType.MutRef _ inner)
      (compiler-load-session-state-lazy-type-id-demand
        state
        inner
        alias
        summary
        locals)]
    [(ast.AstType.Enum name)
      (compiler-load-session-state-lazy-name-demand
        state
        name
        alias
        summary
        locals)]
    [(ast.AstType.EnumArgs name _)
      (compiler-load-session-state-lazy-name-demand
        state
        name
        alias
        summary
        locals)]
    [(ast.AstType.Struct name)
      (compiler-load-session-state-lazy-name-demand
        state
        name
        alias
        summary
        locals)]
    [(ast.AstType.StructArgs name _)
      (compiler-load-session-state-lazy-name-demand
        state
        name
        alias
        summary
        locals)]
    [(ast.AstType.Var name)
      (compiler-load-session-state-lazy-name-demand
        state
        name
        alias
        summary
        locals)]
    [(ast.AstType.VarArgs name _)
      (compiler-load-session-state-lazy-name-demand
        state
        name
        alias
        summary
        locals)]
    [(ast.AstType.Ptr inner)
      (compiler-load-session-state-lazy-type-id-demand
        state
        inner
        alias
        summary
        locals)]
    [(ast.AstType.MutPtr inner)
      (compiler-load-session-state-lazy-type-id-demand
        state
        inner
        alias
        summary
        locals)]
    [_ (compiler-load-lazy-alias-demand-none)]))

(define (compiler-load-session-state-lazy-maybe-type-demand
  [state : CompilerLoadSessionState]
  [maybe-ty : ast.AstMaybeType]
  [alias : i64]
  [summary : CompilerLoadSurfaceSummary]
  [locals : sym_i64_env.SymI64Env]) : CompilerLoadLazyAliasDemand
  (match maybe-ty
    [(ast.AstMaybeType.No) (compiler-load-lazy-alias-demand-none)]
    [(ast.AstMaybeType.Some ty)
      (compiler-load-session-state-lazy-type-demand
        state
        ty
        alias
        summary
        locals)]))

(define (compiler-load-session-state-lazy-param-list-demand-at?
  [state : CompilerLoadSessionState]
  [params : (& params ast.AstParamList)]
  [alias : i64]
  [summary : CompilerLoadSurfaceSummary]
  [locals : sym_i64_env.SymI64Env]
  [index : i64]) : CompilerLoadLazyAliasDemand
  (if (>= index (ast.ast-param-list-len params))
    (compiler-load-lazy-alias-demand-none)
    (match (ast.ast-param-list-get params index (ast.ast-param-fallback))
      [(ast.AstParam.Param _ ty _)
        (compiler-load-lazy-alias-demand-merge
          (compiler-load-session-state-lazy-type-demand
            (compiler-load-session-state-shared-view (& state))
            ty
            alias
            (ast.ast-place-shared-view summary)
            (sym_i64_env.sym-i64-shared-view (& locals)))
          (compiler-load-session-state-lazy-param-list-demand-at?
            state
            params
            alias
            summary
            locals
            (+ index 1)))])))

(define (compiler-load-session-state-lazy-param-list-demand
  [state : CompilerLoadSessionState]
  [params : ast.AstParamList]
  [alias : i64]
  [summary : CompilerLoadSurfaceSummary]
  [locals : sym_i64_env.SymI64Env]) : CompilerLoadLazyAliasDemand
  (compiler-load-session-state-lazy-param-list-demand-at?
    state
    (& params)
    alias
    summary
    locals
    0))

(define (compiler-load-session-state-lazy-param-list-locals-at
  [state : CompilerLoadSessionState]
  [params : (& params ast.AstParamList)]
  [locals : sym_i64_env.SymI64Env]
  [index : i64]) : sym_i64_env.SymI64Env
  (if (>= index (ast.ast-param-list-len params))
    locals
    (match (ast.ast-param-list-get params index (ast.ast-param-fallback))
      [(ast.AstParam.Param name _ _)
        (compiler-load-session-state-lazy-param-list-locals-at
          (compiler-load-session-state-shared-view (& state))
          params
          (if (compiler-load-session-state-lazy-qualified-observer-exhaustive?
            state)
            (compiler-load-session-state-lazy-demand-bind-local-exhaustive
              state
              locals
              name)
            (sym_i64_env.sym-i64-bind-id locals name 1))
          (+ index 1))])))

(define (compiler-load-session-state-lazy-param-list-locals
  [state : CompilerLoadSessionState]
  [params : ast.AstParamList]
  [locals : sym_i64_env.SymI64Env]) : sym_i64_env.SymI64Env
  (compiler-load-session-state-lazy-param-list-locals-at
    state
    (& params)
    locals
    0))

;; Module-macro catalog selection shares this structural walker with lazy
;; imports. Keep declaration signatures and generated metadata visible here so
;; an unrelated struct/macro elsewhere in the importer does not become an
;; artificial `unknown` demand for every alias.
(define (compiler-load-session-state-lazy-macro-param-list-demand-at?
  [state : CompilerLoadSessionState]
  [params : (& params ast.AstMacroParamList)]
  [alias : i64]
  [summary : CompilerLoadSurfaceSummary]
  [locals : sym_i64_env.SymI64Env]
  [index : i64]) : CompilerLoadLazyAliasDemand
  (if (>= index (ast.ast-macro-param-list-len params))
    (compiler-load-lazy-alias-demand-none)
    (match (ast.ast-macro-param-list-get
      params
      index
      (ast.ast-macro-param-fallback))
      [(ast.AstMacroParam.Param _ ty _ _)
        (compiler-load-lazy-alias-demand-merge
          (compiler-load-session-state-lazy-type-demand
            (compiler-load-session-state-shared-view (& state))
            ty
            alias
            (ast.ast-place-shared-view summary)
            (sym_i64_env.sym-i64-shared-view (& locals)))
          (compiler-load-session-state-lazy-macro-param-list-demand-at?
            state
            params
            alias
            summary
            locals
            (+ index 1)))])))

(define (compiler-load-session-state-lazy-macro-param-list-demand
  [state : CompilerLoadSessionState]
  [params : ast.AstMacroParamList]
  [alias : i64]
  [summary : CompilerLoadSurfaceSummary]
  [locals : sym_i64_env.SymI64Env]) : CompilerLoadLazyAliasDemand
  (compiler-load-session-state-lazy-macro-param-list-demand-at?
    state
    (& params)
    alias
    summary
    locals
    0))

(define (compiler-load-session-state-lazy-macro-param-list-locals-at
  [state : CompilerLoadSessionState]
  [params : (& params ast.AstMacroParamList)]
  [locals : sym_i64_env.SymI64Env]
  [index : i64]) : sym_i64_env.SymI64Env
  (if (>= index (ast.ast-macro-param-list-len params))
    locals
    (match (ast.ast-macro-param-list-get
      params
      index
      (ast.ast-macro-param-fallback))
      [(ast.AstMacroParam.Param name _ _ _)
        (compiler-load-session-state-lazy-macro-param-list-locals-at
          (compiler-load-session-state-shared-view (& state))
          params
          (if (compiler-load-session-state-lazy-qualified-observer-exhaustive?
            state)
            (compiler-load-session-state-lazy-demand-bind-local-exhaustive
              state
              locals
              name)
            (sym_i64_env.sym-i64-bind-id locals name 1))
          (+ index 1))])))

(define (compiler-load-session-state-lazy-macro-param-list-locals
  [state : CompilerLoadSessionState]
  [params : ast.AstMacroParamList]
  [locals : sym_i64_env.SymI64Env]) : sym_i64_env.SymI64Env
  (compiler-load-session-state-lazy-macro-param-list-locals-at
    state
    (& params)
    locals
    0))

(define (compiler-load-session-state-lazy-field-list-demand-at?
  [state : CompilerLoadSessionState]
  [fields : (& fields ast.AstFieldDefList)]
  [alias : i64]
  [summary : CompilerLoadSurfaceSummary]
  [locals : sym_i64_env.SymI64Env]
  [index : i64]) : CompilerLoadLazyAliasDemand
  (if (>= index (ast.ast-field-def-list-len fields))
    (compiler-load-lazy-alias-demand-none)
    (match (ast.ast-field-def-list-get
      fields
      index
      (ast.ast-field-def-fallback))
      [(ast.AstFieldDef.Def _ ty _)
        (compiler-load-lazy-alias-demand-merge
          (compiler-load-session-state-lazy-type-demand
            (compiler-load-session-state-shared-view (& state))
            ty
            alias
            (ast.ast-place-shared-view summary)
            (sym_i64_env.sym-i64-shared-view (& locals)))
          (compiler-load-session-state-lazy-field-list-demand-at?
            state
            fields
            alias
            summary
            locals
            (+ index 1)))])))

(define (compiler-load-session-state-lazy-field-list-demand
  [state : CompilerLoadSessionState]
  [fields : ast.AstFieldDefList]
  [alias : i64]
  [summary : CompilerLoadSurfaceSummary]
  [locals : sym_i64_env.SymI64Env]) : CompilerLoadLazyAliasDemand
  (compiler-load-session-state-lazy-field-list-demand-at?
    state
    (& fields)
    alias
    summary
    locals
    0))

(define (compiler-load-session-state-lazy-variant-list-demand-at?
  [state : CompilerLoadSessionState]
  [variants : (& variants ast.AstVariantDefList)]
  [alias : i64]
  [summary : CompilerLoadSurfaceSummary]
  [locals : sym_i64_env.SymI64Env]
  [index : i64]) : CompilerLoadLazyAliasDemand
  (if (>= index (ast.ast-variant-def-list-len variants))
    (compiler-load-lazy-alias-demand-none)
    (match (ast.ast-variant-def-list-get
      variants
      index
      (ast.ast-variant-def-fallback))
      [(ast.AstVariantDef.Def _ types _)
        (compiler-load-lazy-alias-demand-merge
          (compiler-load-session-state-lazy-type-list-demand
            (compiler-load-session-state-shared-view (& state))
            types
            alias
            (ast.ast-place-shared-view summary)
            (sym_i64_env.sym-i64-shared-view (& locals)))
          (compiler-load-session-state-lazy-variant-list-demand-at?
            state
            variants
            alias
            summary
            locals
            (+ index 1)))])))

(define (compiler-load-session-state-lazy-variant-list-demand
  [state : CompilerLoadSessionState]
  [variants : ast.AstVariantDefList]
  [alias : i64]
  [summary : CompilerLoadSurfaceSummary]
  [locals : sym_i64_env.SymI64Env]) : CompilerLoadLazyAliasDemand
  (compiler-load-session-state-lazy-variant-list-demand-at?
    state
    (& variants)
    alias
    summary
    locals
    0))

(define (compiler-load-session-state-lazy-pattern-demand
  [state : CompilerLoadSessionState]
  [pattern : ast.AstPattern]
  [alias : i64]
  [summary : CompilerLoadSurfaceSummary]
  [locals : sym_i64_env.SymI64Env]) : CompilerLoadLazyAliasDemand
  (match pattern
    [(ast.AstPattern.Var _ maybe-ty)
      (compiler-load-session-state-lazy-maybe-type-demand
        state
        maybe-ty
        alias
        summary
        locals)]
    [(ast.AstPattern.Tuple patterns)
      (compiler-load-session-state-lazy-pattern-list-demand
        state
        (ast.ast-pattern-list-box-shared-view patterns)
        alias
        summary
        locals)]
    [(ast.AstPattern.Array patterns)
      (compiler-load-session-state-lazy-pattern-list-demand
        state
        (ast.ast-pattern-list-box-shared-view patterns)
        alias
        summary
        locals)]
    [(ast.AstPattern.Variant name patterns)
      (compiler-load-lazy-alias-demand-merge
        (compiler-load-session-state-lazy-name-demand
          (compiler-load-session-state-shared-view (& state))
          name
          alias
          (ast.ast-place-shared-view summary)
          (sym_i64_env.sym-i64-shared-view (& locals)))
        (compiler-load-session-state-lazy-pattern-list-demand
          state
          (ast.ast-pattern-list-box-shared-view patterns)
          alias
          summary
          locals))]
    [(ast.AstPattern.Wildcard) (compiler-load-lazy-alias-demand-none)]
    [(ast.AstPattern.Binding _) (compiler-load-lazy-alias-demand-none)]
    [(ast.AstPattern.Literal _) (compiler-load-lazy-alias-demand-none)]))

(define (compiler-load-session-state-lazy-pattern-list-demand-at?
  [state : CompilerLoadSessionState]
  [patterns : (& patterns ast.AstPatternList)]
  [alias : i64]
  [summary : CompilerLoadSurfaceSummary]
  [locals : sym_i64_env.SymI64Env]
  [index : i64]) : CompilerLoadLazyAliasDemand
  (if (>= index patterns.len)
    (compiler-load-lazy-alias-demand-none)
    (compiler-load-lazy-alias-demand-merge
      (compiler-load-session-state-lazy-pattern-demand
        (compiler-load-session-state-shared-view (& state))
        (ast.ast-pattern-list-get patterns index (ast.ast-pattern-fallback))
        alias
        (ast.ast-place-shared-view summary)
        (sym_i64_env.sym-i64-shared-view (& locals)))
      (compiler-load-session-state-lazy-pattern-list-demand-at?
        state
        patterns
        alias
        summary
        locals
        (+ index 1)))))

(define (compiler-load-session-state-lazy-pattern-list-demand
  [state : CompilerLoadSessionState]
  [patterns : ast.AstPatternList]
  [alias : i64]
  [summary : CompilerLoadSurfaceSummary]
  [locals : sym_i64_env.SymI64Env]) : CompilerLoadLazyAliasDemand
  (compiler-load-session-state-lazy-pattern-list-demand-at?
    state
    (& patterns)
    alias
    summary
    locals
    0))

(define (compiler-load-session-state-lazy-pattern-locals
  [state : CompilerLoadSessionState]
  [pattern : ast.AstPattern]
  [locals : sym_i64_env.SymI64Env]) : sym_i64_env.SymI64Env
  (match pattern
    [(ast.AstPattern.Var name _)
      (if (compiler-load-session-state-lazy-qualified-observer-exhaustive?
        state)
        (compiler-load-session-state-lazy-demand-bind-local-exhaustive
          state
          locals
          name)
        (sym_i64_env.sym-i64-bind-id locals name 1))]
    [(ast.AstPattern.Binding name)
      (if (compiler-load-session-state-lazy-qualified-observer-exhaustive?
        state)
        (compiler-load-session-state-lazy-demand-bind-local-exhaustive
          state
          locals
          name)
        (sym_i64_env.sym-i64-bind-id locals name 1))]
    [(ast.AstPattern.Tuple patterns)
      (compiler-load-session-state-lazy-pattern-list-locals
        state
        (ast.ast-pattern-list-box-shared-view patterns)
        locals)]
    [(ast.AstPattern.Array patterns)
      (compiler-load-session-state-lazy-pattern-list-locals
        state
        (ast.ast-pattern-list-box-shared-view patterns)
        locals)]
    [(ast.AstPattern.Variant _ patterns)
      (compiler-load-session-state-lazy-pattern-list-locals
        state
        (ast.ast-pattern-list-box-shared-view patterns)
        locals)]
    [(ast.AstPattern.Wildcard) locals]
    [(ast.AstPattern.Literal _) locals]))

(define (compiler-load-session-state-lazy-pattern-list-locals-at
  [state : CompilerLoadSessionState]
  [patterns : (& patterns ast.AstPatternList)]
  [locals : sym_i64_env.SymI64Env]
  [index : i64]) : sym_i64_env.SymI64Env
  (if (>= index patterns.len)
    locals
    (compiler-load-session-state-lazy-pattern-list-locals-at
      (compiler-load-session-state-shared-view (& state))
      patterns
      (compiler-load-session-state-lazy-pattern-locals
        state
        (ast.ast-pattern-list-get patterns index (ast.ast-pattern-fallback))
        locals)
      (+ index 1))))

(define (compiler-load-session-state-lazy-pattern-list-locals
  [state : CompilerLoadSessionState]
  [patterns : ast.AstPatternList]
  [locals : sym_i64_env.SymI64Env]) : sym_i64_env.SymI64Env
  (compiler-load-session-state-lazy-pattern-list-locals-at
    state
    (& patterns)
    locals
    0))

(define (compiler-load-session-state-lazy-expr-list-demand-at?
  [state : CompilerLoadSessionState]
  [exprs : (& exprs ast.AstExprList)]
  [alias : i64]
  [summary : CompilerLoadSurfaceSummary]
  [locals : sym_i64_env.SymI64Env]
  [index : i64]) : CompilerLoadLazyAliasDemand
  (if (>= index (ast.ast-expr-list-len exprs))
    (compiler-load-lazy-alias-demand-none)
    (compiler-load-lazy-alias-demand-merge
      (compiler-load-session-state-lazy-expr-demand
        (compiler-load-session-state-shared-view (& state))
        (ast.ast-node-get (ast.ast-expr-list-get exprs index 0))
        alias
        (ast.ast-place-shared-view summary)
        (sym_i64_env.sym-i64-shared-view (& locals)))
      (compiler-load-session-state-lazy-expr-list-demand-at?
        state
        exprs
        alias
        summary
        locals
        (+ index 1)))))

(define (compiler-load-session-state-lazy-expr-list-demand
  [state : CompilerLoadSessionState]
  [exprs : ast.AstExprList]
  [alias : i64]
  [summary : CompilerLoadSurfaceSummary]
  [locals : sym_i64_env.SymI64Env]) : CompilerLoadLazyAliasDemand
  (compiler-load-session-state-lazy-expr-list-demand-at?
    state
    (& exprs)
    alias
    summary
    locals
    0))

(define (compiler-load-session-state-lazy-let-bindings-demand-at?
  [state : CompilerLoadSessionState]
  [bindings : (& bindings ast.AstLetBindingList)]
  [alias : i64]
  [summary : CompilerLoadSurfaceSummary]
  [locals : sym_i64_env.SymI64Env]
  [index : i64]) : CompilerLoadLazyAliasDemand
  (if (>= index (ast.ast-let-binding-list-len bindings))
    (compiler-load-lazy-alias-demand-none)
    (match (ast.ast-let-binding-list-get
      bindings
      index
      (ast.ast-let-binding-fallback))
      [(ast.AstLetBinding.Binding name maybe-ty init)
        (compiler-load-lazy-alias-demand-merge
          (compiler-load-session-state-lazy-maybe-type-demand
            (compiler-load-session-state-shared-view (& state))
            maybe-ty
            alias
            (ast.ast-place-shared-view summary)
            (sym_i64_env.sym-i64-shared-view (& locals)))
          (compiler-load-lazy-alias-demand-merge
            (compiler-load-session-state-lazy-expr-demand
              (compiler-load-session-state-shared-view (& state))
              (ast.ast-node-get init)
              alias
              (ast.ast-place-shared-view summary)
              (sym_i64_env.sym-i64-shared-view (& locals)))
            (compiler-load-session-state-lazy-let-bindings-demand-at?
              (compiler-load-session-state-shared-view (& state))
              bindings
              alias
              summary
              (if (compiler-load-session-state-lazy-qualified-observer-exhaustive?
                state)
                (compiler-load-session-state-lazy-demand-bind-local-exhaustive
                  state
                  locals
                  name)
                (sym_i64_env.sym-i64-bind-id locals name 1))
              (+ index 1))))])))

(define (compiler-load-session-state-lazy-let-bindings-locals-at
  [state : CompilerLoadSessionState]
  [bindings : (& bindings ast.AstLetBindingList)]
  [locals : sym_i64_env.SymI64Env]
  [index : i64]) : sym_i64_env.SymI64Env
  (if (>= index (ast.ast-let-binding-list-len bindings))
    locals
    (match (ast.ast-let-binding-list-get
      bindings
      index
      (ast.ast-let-binding-fallback))
      [(ast.AstLetBinding.Binding name _ _)
        (compiler-load-session-state-lazy-let-bindings-locals-at
          (compiler-load-session-state-shared-view (& state))
          bindings
          (if (compiler-load-session-state-lazy-qualified-observer-exhaustive?
            state)
            (compiler-load-session-state-lazy-demand-bind-local-exhaustive
              state
              locals
              name)
            (sym_i64_env.sym-i64-bind-id locals name 1))
          (+ index 1))])))

(define (compiler-load-session-state-lazy-match-arms-demand-at?
  [state : CompilerLoadSessionState]
  [arms : (& arms ast.AstMatchArmList)]
  [alias : i64]
  [summary : CompilerLoadSurfaceSummary]
  [locals : sym_i64_env.SymI64Env]
  [index : i64]) : CompilerLoadLazyAliasDemand
  (if (>= index (ast.ast-match-arm-list-len arms))
    (compiler-load-lazy-alias-demand-none)
    (match (ast.ast-match-arm-list-get arms index (ast.ast-match-arm-fallback))
      [(ast.AstMatchArm.Arm pattern body)
        (compiler-load-lazy-alias-demand-merge
          (compiler-load-session-state-lazy-pattern-demand
            (compiler-load-session-state-shared-view (& state))
            (clone pattern)
            alias
            (ast.ast-place-shared-view summary)
            (sym_i64_env.sym-i64-shared-view (& locals)))
          (compiler-load-lazy-alias-demand-merge
            (compiler-load-session-state-lazy-expr-demand
              (compiler-load-session-state-shared-view (& state))
              (ast.ast-node-get body)
              alias
              (ast.ast-place-shared-view summary)
              (compiler-load-session-state-lazy-pattern-locals
                (compiler-load-session-state-shared-view (& state))
                pattern
                (sym_i64_env.sym-i64-shared-view (& locals))))
            (compiler-load-session-state-lazy-match-arms-demand-at?
              state
              arms
              alias
              summary
              locals
              (+ index 1))))])))

(define (compiler-load-session-state-lazy-match-arms-demand
  [state : CompilerLoadSessionState]
  [arms : ast.AstMatchArmList]
  [alias : i64]
  [summary : CompilerLoadSurfaceSummary]
  [locals : sym_i64_env.SymI64Env]) : CompilerLoadLazyAliasDemand
  (compiler-load-session-state-lazy-match-arms-demand-at?
    state
    (& arms)
    alias
    summary
    locals
    0))

(define (compiler-load-session-state-lazy-expr-demand
  [state : CompilerLoadSessionState]
  [expr : ast.AstExpr]
  [alias : i64]
  [summary : CompilerLoadSurfaceSummary]
  [locals : sym_i64_env.SymI64Env]) : CompilerLoadLazyAliasDemand
  (match expr
    [(ast.AstExpr.Spanned inner _)
      (compiler-load-session-state-lazy-expr-demand
        state
        (ast.ast-node-get inner)
        alias
        summary
        locals)]
    [(ast.AstExpr.Literal _) (compiler-load-lazy-alias-demand-none)]
    [(ast.AstExpr.Var name)
      (compiler-load-session-state-lazy-name-demand
        state
        name
        alias
        summary
        locals)]
    [(ast.AstExpr.Binary _ left right)
      (compiler-load-lazy-alias-demand-merge
        (compiler-load-session-state-lazy-expr-demand
          (compiler-load-session-state-shared-view (& state))
          (ast.ast-node-get left)
          alias
          (ast.ast-place-shared-view summary)
          (sym_i64_env.sym-i64-shared-view (& locals)))
        (compiler-load-session-state-lazy-expr-demand
          (compiler-load-session-state-shared-view (& state))
          (ast.ast-node-get right)
          alias
          summary
          locals))]
    [(ast.AstExpr.Unary _ inner)
      (compiler-load-session-state-lazy-expr-demand
        state
        (ast.ast-node-get inner)
        alias
        summary
        locals)]
    [(ast.AstExpr.Call func args)
      (compiler-load-lazy-alias-demand-merge
        (compiler-load-session-state-lazy-expr-demand
          (compiler-load-session-state-shared-view (& state))
          (ast.ast-node-get func)
          alias
          (ast.ast-place-shared-view summary)
          (sym_i64_env.sym-i64-shared-view (& locals)))
        (compiler-load-session-state-lazy-expr-list-demand
          state
          args
          alias
          summary
          locals))]
    [(ast.AstExpr.If condition then-branch else-branch)
      (compiler-load-lazy-alias-demand-merge
        (compiler-load-session-state-lazy-expr-demand
          (compiler-load-session-state-shared-view (& state))
          (ast.ast-node-get condition)
          alias
          (ast.ast-place-shared-view summary)
          (sym_i64_env.sym-i64-shared-view (& locals)))
        (compiler-load-lazy-alias-demand-merge
          (compiler-load-session-state-lazy-expr-demand
            (compiler-load-session-state-shared-view (& state))
            (ast.ast-node-get then-branch)
            alias
            (ast.ast-place-shared-view summary)
            (sym_i64_env.sym-i64-shared-view (& locals)))
          (compiler-load-session-state-lazy-expr-demand
            state
            (ast.ast-node-get else-branch)
            alias
            summary
            locals)))]
    [(ast.AstExpr.Let let-box)
      (match (__tl-box-place let-box)
        [(ast.AstLet.Let bindings body)
          (compiler-load-lazy-alias-demand-merge
            (compiler-load-session-state-lazy-let-bindings-demand-at?
              (compiler-load-session-state-shared-view (& state))
              (& bindings)
              alias
              (ast.ast-place-shared-view summary)
              (sym_i64_env.sym-i64-shared-view (& locals))
              0)
            (compiler-load-session-state-lazy-expr-demand
              (compiler-load-session-state-shared-view (& state))
              (ast.ast-node-get body)
              alias
              (ast.ast-place-shared-view summary)
              (compiler-load-session-state-lazy-let-bindings-locals-at
                (compiler-load-session-state-shared-view (& state))
                (& bindings)
                (sym_i64_env.sym-i64-shared-view (& locals))
                0)))])]
    [(ast.AstExpr.Lambda lambda-box)
      (match (__tl-box-place lambda-box)
        [(ast.AstLambda.Lambda params ret body)
          (compiler-load-lazy-alias-demand-merge
            (compiler-load-session-state-lazy-param-list-demand
              (compiler-load-session-state-shared-view (& state))
              (ast.ast-place-shared-view params)
              alias
              (ast.ast-place-shared-view summary)
              (sym_i64_env.sym-i64-shared-view (& locals)))
            (compiler-load-lazy-alias-demand-merge
              (compiler-load-session-state-lazy-maybe-type-demand
                (compiler-load-session-state-shared-view (& state))
                ret
                alias
                (ast.ast-place-shared-view summary)
                (sym_i64_env.sym-i64-shared-view (& locals)))
              (compiler-load-session-state-lazy-expr-demand
                (compiler-load-session-state-shared-view (& state))
                (ast.ast-node-get body)
                alias
                (ast.ast-place-shared-view summary)
                (compiler-load-session-state-lazy-param-list-locals
                  (compiler-load-session-state-shared-view (& state))
                  params
                  locals))))])]
    [(ast.AstExpr.Tuple exprs)
      (compiler-load-session-state-lazy-expr-list-demand
        state
        exprs
        alias
        summary
        locals)]
    [(ast.AstExpr.TupleRef tuple _)
      (compiler-load-session-state-lazy-expr-demand
        state
        (ast.ast-node-get tuple)
        alias
        summary
        locals)]
    [(ast.AstExpr.Array exprs)
      (compiler-load-session-state-lazy-expr-list-demand
        state
        exprs
        alias
        summary
        locals)]
    [(ast.AstExpr.DynArray exprs)
      (compiler-load-session-state-lazy-expr-list-demand
        state
        exprs
        alias
        summary
        locals)]
    [(ast.AstExpr.MakeArray elem-id length)
      (compiler-load-lazy-alias-demand-merge
        (compiler-load-session-state-lazy-type-demand
          (compiler-load-session-state-shared-view (& state))
          (ast.ty-node-get elem-id)
          alias
          (ast.ast-place-shared-view summary)
          (sym_i64_env.sym-i64-shared-view (& locals)))
        (compiler-load-session-state-lazy-expr-demand
          (compiler-load-session-state-shared-view (& state))
          (ast.ast-node-get length)
          alias
          summary
          locals))]
    [(ast.AstExpr.ArrayRef items index)
      (compiler-load-lazy-alias-demand-merge
        (compiler-load-session-state-lazy-expr-demand
          (compiler-load-session-state-shared-view (& state))
          (ast.ast-node-get items)
          alias
          (ast.ast-place-shared-view summary)
          (sym_i64_env.sym-i64-shared-view (& locals)))
        (compiler-load-session-state-lazy-expr-demand
          state
          (ast.ast-node-get index)
          alias
          summary
          locals))]
    [(ast.AstExpr.ArraySet items index value)
      (compiler-load-lazy-alias-demand-merge
        (compiler-load-session-state-lazy-expr-demand
          (compiler-load-session-state-shared-view (& state))
          (ast.ast-node-get items)
          alias
          (ast.ast-place-shared-view summary)
          (sym_i64_env.sym-i64-shared-view (& locals)))
        (compiler-load-lazy-alias-demand-merge
          (compiler-load-session-state-lazy-expr-demand
            (compiler-load-session-state-shared-view (& state))
            (ast.ast-node-get index)
            alias
            (ast.ast-place-shared-view summary)
            (sym_i64_env.sym-i64-shared-view (& locals)))
          (compiler-load-session-state-lazy-expr-demand
            state
            (ast.ast-node-get value)
            alias
            summary
            locals)))]
    [(ast.AstExpr.Replace place replacement)
      (compiler-load-lazy-alias-demand-merge
        (compiler-load-session-state-lazy-expr-demand
          (compiler-load-session-state-shared-view (& state))
          (ast.ast-node-get place)
          alias
          (ast.ast-place-shared-view summary)
          (sym_i64_env.sym-i64-shared-view (& locals)))
        (compiler-load-session-state-lazy-expr-demand
          state
          (ast.ast-node-get replacement)
          alias
          summary
          locals))]
    [(ast.AstExpr.ArrayPush items value)
      (compiler-load-lazy-alias-demand-merge
        (compiler-load-session-state-lazy-expr-demand
          (compiler-load-session-state-shared-view (& state))
          (ast.ast-node-get items)
          alias
          (ast.ast-place-shared-view summary)
          (sym_i64_env.sym-i64-shared-view (& locals)))
        (compiler-load-session-state-lazy-expr-demand
          state
          (ast.ast-node-get value)
          alias
          summary
          locals))]
    [(ast.AstExpr.StringRef text index)
      (compiler-load-lazy-alias-demand-merge
        (compiler-load-session-state-lazy-expr-demand
          (compiler-load-session-state-shared-view (& state))
          (ast.ast-node-get text)
          alias
          (ast.ast-place-shared-view summary)
          (sym_i64_env.sym-i64-shared-view (& locals)))
        (compiler-load-session-state-lazy-expr-demand
          state
          (ast.ast-node-get index)
          alias
          summary
          locals))]
    [(ast.AstExpr.While condition body)
      (compiler-load-lazy-alias-demand-merge
        (compiler-load-session-state-lazy-expr-demand
          (compiler-load-session-state-shared-view (& state))
          (ast.ast-node-get condition)
          alias
          (ast.ast-place-shared-view summary)
          (sym_i64_env.sym-i64-shared-view (& locals)))
        (compiler-load-session-state-lazy-expr-demand
          state
          (ast.ast-node-get body)
          alias
          summary
          locals))]
    [(ast.AstExpr.Begin exprs)
      (compiler-load-session-state-lazy-expr-list-demand
        state
        exprs
        alias
        summary
        locals)]
    [(ast.AstExpr.Unsafe exprs)
      (compiler-load-session-state-lazy-expr-list-demand
        state
        exprs
        alias
        summary
        locals)]
    [(ast.AstExpr.Set target value)
      (compiler-load-lazy-alias-demand-merge
        (compiler-load-session-state-lazy-name-demand
          (compiler-load-session-state-shared-view (& state))
          target
          alias
          (ast.ast-place-shared-view summary)
          (sym_i64_env.sym-i64-shared-view (& locals)))
        (compiler-load-session-state-lazy-expr-demand
          state
          (ast.ast-node-get value)
          alias
          summary
          locals))]
    [(ast.AstExpr.Ann inner ty-id)
      (compiler-load-lazy-alias-demand-merge
        (compiler-load-session-state-lazy-expr-demand
          (compiler-load-session-state-shared-view (& state))
          (ast.ast-node-get inner)
          alias
          (ast.ast-place-shared-view summary)
          (sym_i64_env.sym-i64-shared-view (& locals)))
        (compiler-load-session-state-lazy-type-demand
          state
          (ast.ty-node-get ty-id)
          alias
          summary
          locals))]
    [(ast.AstExpr.Cast inner ty-id)
      (compiler-load-lazy-alias-demand-merge
        (compiler-load-session-state-lazy-expr-demand
          (compiler-load-session-state-shared-view (& state))
          (ast.ast-node-get inner)
          alias
          (ast.ast-place-shared-view summary)
          (sym_i64_env.sym-i64-shared-view (& locals)))
        (compiler-load-session-state-lazy-type-demand
          state
          (ast.ty-node-get ty-id)
          alias
          summary
          locals))]
    [(ast.AstExpr.Borrow _ _ place)
      (compiler-load-session-state-lazy-expr-demand
        state
        (ast.ast-node-get place)
        alias
        summary
        locals)]
    [(ast.AstExpr.Match match-box)
      (match (__tl-box-place match-box)
        [(ast.AstMatch.Match scrutinee arms)
          (compiler-load-lazy-alias-demand-merge
            (compiler-load-session-state-lazy-expr-demand
              (compiler-load-session-state-shared-view (& state))
              (ast.ast-node-get scrutinee)
              alias
              (ast.ast-place-shared-view summary)
              (sym_i64_env.sym-i64-shared-view (& locals)))
            (compiler-load-session-state-lazy-match-arms-demand
              state
              arms
              alias
              summary
              locals))])]
    [(ast.AstExpr.Foreach foreach-box)
      (match (__tl-box-place foreach-box)
        [(ast.AstForeach.Foreach index ty start end body)
          (compiler-load-lazy-alias-demand-merge
            (compiler-load-session-state-lazy-type-demand
              (compiler-load-session-state-shared-view (& state))
              ty
              alias
              (ast.ast-place-shared-view summary)
              (sym_i64_env.sym-i64-shared-view (& locals)))
            (compiler-load-lazy-alias-demand-merge
              (compiler-load-session-state-lazy-expr-demand
                (compiler-load-session-state-shared-view (& state))
                (ast.ast-node-get start)
                alias
                (ast.ast-place-shared-view summary)
                (sym_i64_env.sym-i64-shared-view (& locals)))
              (compiler-load-lazy-alias-demand-merge
                (compiler-load-session-state-lazy-expr-demand
                  (compiler-load-session-state-shared-view (& state))
                  (ast.ast-node-get end)
                  alias
                  (ast.ast-place-shared-view summary)
                  (sym_i64_env.sym-i64-shared-view (& locals)))
                (compiler-load-session-state-lazy-expr-demand
                  (compiler-load-session-state-shared-view (& state))
                  (ast.ast-node-get body)
                  alias
                  summary
                  (if (compiler-load-session-state-lazy-qualified-observer-exhaustive?
                    state)
                    (compiler-load-session-state-lazy-demand-bind-local-exhaustive
                      state
                      locals
                      index)
                    (sym_i64_env.sym-i64-bind-id locals index 1))))))])]
    [(ast.AstExpr.SpmdReduce reduce-box)
      (match (__tl-box-place reduce-box)
        [(ast.AstSpmdReduce.Reduce _ index ty start end init value)
          (compiler-load-lazy-alias-demand-merge
            (compiler-load-session-state-lazy-type-demand
              (compiler-load-session-state-shared-view (& state))
              ty
              alias
              (ast.ast-place-shared-view summary)
              (sym_i64_env.sym-i64-shared-view (& locals)))
            (compiler-load-lazy-alias-demand-merge
              (compiler-load-session-state-lazy-expr-demand
                (compiler-load-session-state-shared-view (& state))
                (ast.ast-node-get start)
                alias
                (ast.ast-place-shared-view summary)
                (sym_i64_env.sym-i64-shared-view (& locals)))
              (compiler-load-lazy-alias-demand-merge
                (compiler-load-session-state-lazy-expr-demand
                  (compiler-load-session-state-shared-view (& state))
                  (ast.ast-node-get end)
                  alias
                  (ast.ast-place-shared-view summary)
                  (sym_i64_env.sym-i64-shared-view (& locals)))
                (compiler-load-lazy-alias-demand-merge
                  (compiler-load-session-state-lazy-expr-demand
                    (compiler-load-session-state-shared-view (& state))
                    (ast.ast-node-get init)
                    alias
                    (ast.ast-place-shared-view summary)
                    (sym_i64_env.sym-i64-shared-view (& locals)))
                  (compiler-load-session-state-lazy-expr-demand
                    (compiler-load-session-state-shared-view (& state))
                    (ast.ast-node-get value)
                    alias
                    summary
                    (if (compiler-load-session-state-lazy-qualified-observer-exhaustive?
                      state)
                      (compiler-load-session-state-lazy-demand-bind-local-exhaustive
                        state
                        locals
                        index)
                      (sym_i64_env.sym-i64-bind-id locals index 1)))))))])]
    [(ast.AstExpr.SpmdScan scan-box)
      (match (__tl-box-place scan-box)
        [(ast.AstSpmdScan.Scan _ index ty start end prefix _ init value body)
          (let
            [value-locals : sym_i64_env.SymI64Env
              (if (compiler-load-session-state-lazy-qualified-observer-exhaustive?
                state)
                (compiler-load-session-state-lazy-demand-bind-local-exhaustive
                  state
                  (sym_i64_env.sym-i64-shared-view (& locals))
                  index)
                (sym_i64_env.sym-i64-bind-id
                  (sym_i64_env.sym-i64-shared-view (& locals))
                  index
                  1))]
            [body-locals : sym_i64_env.SymI64Env
              (if (compiler-load-session-state-lazy-qualified-observer-exhaustive?
                state)
                (compiler-load-session-state-lazy-demand-bind-local-exhaustive
                  state
                  (sym_i64_env.sym-i64-shared-view (& value-locals))
                  prefix)
                (sym_i64_env.sym-i64-bind-id
                  (sym_i64_env.sym-i64-shared-view (& value-locals))
                  prefix
                  1))]
            (compiler-load-lazy-alias-demand-merge
              (compiler-load-session-state-lazy-type-demand
                (compiler-load-session-state-shared-view (& state))
                ty
                alias
                (ast.ast-place-shared-view summary)
                (sym_i64_env.sym-i64-shared-view (& locals)))
              (compiler-load-lazy-alias-demand-merge
                (compiler-load-session-state-lazy-expr-demand
                  (compiler-load-session-state-shared-view (& state))
                  (ast.ast-node-get start)
                  alias
                  (ast.ast-place-shared-view summary)
                  (sym_i64_env.sym-i64-shared-view (& locals)))
                (compiler-load-lazy-alias-demand-merge
                  (compiler-load-session-state-lazy-expr-demand
                    (compiler-load-session-state-shared-view (& state))
                    (ast.ast-node-get end)
                    alias
                    (ast.ast-place-shared-view summary)
                    (sym_i64_env.sym-i64-shared-view (& locals)))
                  (compiler-load-lazy-alias-demand-merge
                    (compiler-load-session-state-lazy-expr-demand
                      (compiler-load-session-state-shared-view (& state))
                      (ast.ast-node-get init)
                      alias
                      (ast.ast-place-shared-view summary)
                      (sym_i64_env.sym-i64-shared-view (& locals)))
                    (compiler-load-lazy-alias-demand-merge
                      (compiler-load-session-state-lazy-expr-demand
                        (compiler-load-session-state-shared-view (& state))
                        (ast.ast-node-get value)
                        alias
                        (ast.ast-place-shared-view summary)
                        (sym_i64_env.sym-i64-shared-view (& value-locals)))
                      (compiler-load-session-state-lazy-expr-demand
                        state
                        (ast.ast-node-get body)
                        alias
                        summary
                        body-locals)))))))])]
    [(ast.AstExpr.SpmdBroadcast value lane)
      (compiler-load-lazy-alias-demand-merge
        (compiler-load-session-state-lazy-expr-demand
          (compiler-load-session-state-shared-view (& state))
          (ast.ast-node-get value)
          alias
          (ast.ast-place-shared-view summary)
          (sym_i64_env.sym-i64-shared-view (& locals)))
        (compiler-load-session-state-lazy-expr-demand
          state
          (ast.ast-node-get lane)
          alias
          summary
          locals))]
    [(ast.AstExpr.SpmdShuffle value lane)
      (compiler-load-lazy-alias-demand-merge
        (compiler-load-session-state-lazy-expr-demand
          (compiler-load-session-state-shared-view (& state))
          (ast.ast-node-get value)
          alias
          (ast.ast-place-shared-view summary)
          (sym_i64_env.sym-i64-shared-view (& locals)))
        (compiler-load-session-state-lazy-expr-demand
          state
          (ast.ast-node-get lane)
          alias
          summary
          locals))]
    [(ast.AstExpr.StructGet receiver _)
      (compiler-load-session-state-lazy-expr-demand
        state
        (ast.ast-node-get receiver)
        alias
        summary
        locals)]
    [(ast.AstExpr.StructSet receiver _ value)
      (compiler-load-lazy-alias-demand-merge
        (compiler-load-session-state-lazy-expr-demand
          (compiler-load-session-state-shared-view (& state))
          (ast.ast-node-get receiver)
          alias
          (ast.ast-place-shared-view summary)
          (sym_i64_env.sym-i64-shared-view (& locals)))
        (compiler-load-session-state-lazy-expr-demand
          state
          (ast.ast-node-get value)
          alias
          summary
          locals))]
    [(ast.AstExpr.WithEscape scratch body)
      (compiler-load-lazy-alias-demand-merge
        (compiler-load-session-state-lazy-expr-demand
          (compiler-load-session-state-shared-view (& state))
          (ast.ast-node-get scratch)
          alias
          (ast.ast-place-shared-view summary)
          (sym_i64_env.sym-i64-shared-view (& locals)))
        (compiler-load-session-state-lazy-expr-list-demand
          state
          body
          alias
          summary
          locals))]
    [(ast.AstExpr.WithScratch body)
      (compiler-load-session-state-lazy-expr-list-demand
        state
        body
        alias
        summary
        locals)]
    [(ast.AstExpr.InArena arena body)
      (compiler-load-lazy-alias-demand-merge
        (compiler-load-session-state-lazy-expr-demand
          (compiler-load-session-state-shared-view (& state))
          (ast.ast-node-get arena)
          alias
          (ast.ast-place-shared-view summary)
          (sym_i64_env.sym-i64-shared-view (& locals)))
        (compiler-load-session-state-lazy-expr-list-demand
          state
          body
          alias
          summary
          locals))]
    [(ast.AstExpr.Box inner)
      (compiler-load-session-state-lazy-expr-demand
        state
        (ast.ast-node-get inner)
        alias
        summary
        locals)]
    [(ast.AstExpr.BoxGet inner)
      (compiler-load-session-state-lazy-expr-demand
        state
        (ast.ast-node-get inner)
        alias
        summary
        locals)]
    [(ast.AstExpr.BoxTake inner)
      (compiler-load-session-state-lazy-expr-demand
        state
        (ast.ast-node-get inner)
        alias
        summary
        locals)]
    [(ast.AstExpr.BoxSet inner value)
      (compiler-load-lazy-alias-demand-merge
        (compiler-load-session-state-lazy-expr-demand
          (compiler-load-session-state-shared-view (& state))
          (ast.ast-node-get inner)
          alias
          (ast.ast-place-shared-view summary)
          (sym_i64_env.sym-i64-shared-view (& locals)))
        (compiler-load-session-state-lazy-expr-demand
          state
          (ast.ast-node-get value)
          alias
          summary
          locals))]
    [(ast.AstExpr.TypeLiteral ty-id)
      (compiler-load-session-state-lazy-type-demand
        state
        (ast.ty-node-get ty-id)
        alias
        summary
        locals)]
    [(ast.AstExpr.Init maybe-ty-id)
      (compiler-load-session-state-lazy-maybe-type-demand
        state
        (ast.ast-maybe-type-from-id maybe-ty-id)
        alias
        summary
        locals)]
    [(ast.AstExpr.Comptime inner)
      (if (compiler-load-session-state-lazy-qualified-observer-exhaustive?
        state)
        (compiler-load-session-state-lazy-expr-demand
          state
          (ast.ast-node-get inner)
          alias
          summary
          locals)
        (compiler-load-lazy-alias-demand-unknown))]
    [(ast.AstExpr.Quote inner)
      (if (compiler-load-session-state-lazy-qualified-observer-exhaustive?
        state)
        (compiler-load-session-state-lazy-expr-demand
          state
          (ast.ast-node-get inner)
          alias
          summary
          locals)
        (compiler-load-lazy-alias-demand-unknown))]
    [(ast.AstExpr.Quasiquote inner)
      (if (compiler-load-session-state-lazy-qualified-observer-exhaustive?
        state)
        (compiler-load-session-state-lazy-expr-demand
          state
          (ast.ast-node-get inner)
          alias
          summary
          locals)
        (compiler-load-lazy-alias-demand-unknown))]
    [(ast.AstExpr.Unquote inner)
      (if (compiler-load-session-state-lazy-qualified-observer-exhaustive?
        state)
        (compiler-load-session-state-lazy-expr-demand
          state
          (ast.ast-node-get inner)
          alias
          summary
          locals)
        (compiler-load-lazy-alias-demand-unknown))]
    [(ast.AstExpr.UnquoteSplicing inner)
      (if (compiler-load-session-state-lazy-qualified-observer-exhaustive?
        state)
        (compiler-load-session-state-lazy-expr-demand
          state
          (ast.ast-node-get inner)
          alias
          summary
          locals)
        (compiler-load-lazy-alias-demand-unknown))]
    [(ast.AstExpr.Try inner)
      (compiler-load-session-state-lazy-expr-demand
        state
        (ast.ast-node-get inner)
        alias
        summary
        locals)]
    [(ast.AstExpr.Return inner)
      (compiler-load-session-state-lazy-expr-demand
        state
        (ast.ast-node-get inner)
        alias
        summary
        locals)]
    [(ast.AstExpr.Break) (compiler-load-lazy-alias-demand-none)]
    [(ast.AstExpr.Continue) (compiler-load-lazy-alias-demand-none)]
    [(ast.AstExpr.PtrNull ty-id)
      (compiler-load-session-state-lazy-type-demand
        state
        (ast.ty-node-get ty-id)
        alias
        summary
        locals)]
    [(ast.AstExpr.PtrNullCheck inner)
      (compiler-load-session-state-lazy-expr-demand
        state
        (ast.ast-node-get inner)
        alias
        summary
        locals)]
    [(ast.AstExpr.BinaryData _) (compiler-load-lazy-alias-demand-none)]
    [(ast.AstExpr.SpmdProgramIndex) (compiler-load-lazy-alias-demand-none)]
    [(ast.AstExpr.SpmdProgramCount) (compiler-load-lazy-alias-demand-none)]
    [(ast.AstExpr.ProgramArgc) (compiler-load-lazy-alias-demand-none)]
    [(ast.AstExpr.ProgramArgv) (compiler-load-lazy-alias-demand-none)]
    [(ast.AstExpr.ProgramEnvp) (compiler-load-lazy-alias-demand-none)]
    ;; Macro-generated and uncommon AST shapes are an explicit eager fence.
    [_ (compiler-load-lazy-alias-demand-unknown)]))

(define (compiler-load-session-state-lazy-module-macro-demand
  [state : CompilerLoadSessionState]
  [call-expr : ast.AstExpr]
  [alias : i64]
  [summary : CompilerLoadSurfaceSummary]
  [locals : sym_i64_env.SymI64Env]) : CompilerLoadLazyAliasDemand
  ;; A module macro can introduce declarations that are not visible in the
  ;; static surface. If its direct macro name belongs to this import (through
  ;; either its local alias or canonical module ID), retain the source module
  ;; instead of assuming a later typechecker fast path can materialize it.
  ;; This keeps arbitrary generated-module macros correct.
  (match call-expr
    [(ast.AstExpr.Spanned inner _)
      (compiler-load-session-state-lazy-module-macro-demand
        state
        (ast.ast-node-get inner)
        alias
        summary
        locals)]
    [(ast.AstExpr.Call func args)
      (let
        [function-demand : CompilerLoadLazyAliasDemand
          (compiler-load-session-state-lazy-module-macro-demand
            (compiler-load-session-state-shared-view (& state))
            (ast.ast-node-get func)
            alias
            (ast.ast-place-shared-view summary)
            (sym_i64_env.sym-i64-shared-view (& locals)))]
        [macro-demand : CompilerLoadLazyAliasDemand
          (if function-demand.direct
            (compiler-load-lazy-alias-demand-unknown)
            function-demand)]
        (compiler-load-lazy-alias-demand-merge
          macro-demand
          (compiler-load-session-state-lazy-expr-list-demand
            state
            args
            alias
            summary
            locals)))]
    [(ast.AstExpr.Var name)
      (let
        [name-demand : CompilerLoadLazyAliasDemand
          (compiler-load-session-state-lazy-name-demand
            state
            name
            alias
            (ast.ast-place-shared-view summary)
            (sym_i64_env.sym-i64-shared-view (& locals)))]
        (if (or
          name-demand.direct
          (compiler-load-lazy-name-qualified-by-id? name summary.module-id))
          (compiler-load-lazy-alias-demand-unknown)
          name-demand))]
    [_ (compiler-load-lazy-alias-demand-unknown)]))

(define (compiler-load-lazy-module-macro-qualified-by?
  [call-expr : ast.AstExpr]
  [module-id : i64]) : bool
  ;; A moduleless source file has a path-derived summary ID, but a caller can
  ;; still invoke its macro through the canonical dotted import ID. Keep that
  ;; import loaded when the macro target uses that spelling.
  (match call-expr
    [(ast.AstExpr.Spanned inner _)
      (compiler-load-lazy-module-macro-qualified-by?
        (ast.ast-node-get inner)
        module-id)]
    [(ast.AstExpr.Call func _)
      (compiler-load-lazy-module-macro-qualified-by?
        (ast.ast-node-get func)
        module-id)]
    [(ast.AstExpr.Var name)
      (compiler-load-lazy-name-qualified-by-id? name module-id)]
    [_ false]))

(define (compiler-load-lazy-decl-module-macro-qualified-by?
  [decl : ast.AstDecl]
  [module-id : i64]) : bool
  (match decl
    [(ast.AstDecl.ModuleBody _ body)
      (compiler-load-lazy-decl-list-module-macro-qualified-by?
        (ast.ast-decl-list-box-shared-view body)
        module-id)]
    [(ast.AstDecl.Import
        decl-meta
        (ast.AstImportSpec.Spec (ast.AstImportKind.Macro call-expr _) _ _ _ _))
      (compiler-load-lazy-module-macro-qualified-by?
        (ast.ast-node-get call-expr)
        module-id)]
    [(ast.AstDecl.Unsafe inner)
      (compiler-load-lazy-decl-module-macro-qualified-by?
        (ast.ast-decl-box-shared-view inner)
        module-id)]
    [_ false]))

(define (compiler-load-lazy-decl-list-module-macro-qualified-by?
  [decls : ast.AstDeclList]
  [module-id : i64]) : bool
  (match (ast.ast-decl-list-step decls)
    [(ast.AstDeclListStep.Nil) false]
    [(ast.AstDeclListStep.Cons decl rest)
      (or
        (compiler-load-lazy-decl-module-macro-qualified-by? decl module-id)
        (compiler-load-lazy-decl-list-module-macro-qualified-by? rest module-id))]))

(define (compiler-load-session-state-lazy-generated-meta-demand
  [state : CompilerLoadSessionState]
  [meta : ast.AstGeneratedDeclMeta]
  [alias : i64]
  [summary : CompilerLoadSurfaceSummary]
  [locals : sym_i64_env.SymI64Env]) : CompilerLoadLazyAliasDemand
  (match meta
    [(ast.AstGeneratedDeclMeta.No) (compiler-load-lazy-alias-demand-none)]
    [(ast.AstGeneratedDeclMeta.Some _ _ args _)
      (compiler-load-session-state-lazy-expr-list-demand
        state
        args
        alias
        summary
        locals)]))

(define (compiler-load-session-state-lazy-decl-demand-inner
  [state : CompilerLoadSessionState]
  [decl : ast.AstDecl]
  [alias : i64]
  [summary : CompilerLoadSurfaceSummary]
  [locals : sym_i64_env.SymI64Env]) : CompilerLoadLazyAliasDemand
  (match decl
    [(ast.AstDecl.Module _) (compiler-load-lazy-alias-demand-none)]
    [(ast.AstDecl.ModuleBody _ body)
      (compiler-load-session-state-lazy-decl-list-demand
        state
        (ast.ast-decl-list-box-shared-view body)
        alias
        summary
        locals)]
    [(ast.AstDecl.Def decl-meta _ maybe-ty body)
      (compiler-load-lazy-alias-demand-merge
        (compiler-load-session-state-lazy-maybe-type-demand
          (compiler-load-session-state-shared-view (& state))
          maybe-ty
          alias
          (ast.ast-place-shared-view summary)
          (sym_i64_env.sym-i64-shared-view (& locals)))
        (compiler-load-session-state-lazy-expr-demand
          state
          (ast.ast-node-get body)
          alias
          summary
          locals))]
    [(ast.AstDecl.DefFn decl-meta _ params ret body _)
      (compiler-load-lazy-alias-demand-merge
        (compiler-load-session-state-lazy-param-list-demand
          (compiler-load-session-state-shared-view (& state))
          (ast.ast-place-shared-view params)
          alias
          (ast.ast-place-shared-view summary)
          (sym_i64_env.sym-i64-shared-view (& locals)))
        (compiler-load-lazy-alias-demand-merge
          (compiler-load-session-state-lazy-type-demand
            (compiler-load-session-state-shared-view (& state))
            ret
            alias
            (ast.ast-place-shared-view summary)
            (sym_i64_env.sym-i64-shared-view (& locals)))
          (compiler-load-session-state-lazy-expr-demand
            (compiler-load-session-state-shared-view (& state))
            (ast.ast-node-get body)
            alias
            (ast.ast-place-shared-view summary)
            (compiler-load-session-state-lazy-param-list-locals
              (compiler-load-session-state-shared-view (& state))
              params
              locals))))]
    [(ast.AstDecl.DefMacro decl-meta _ params ret body)
      (if (compiler-load-session-state-lazy-qualified-observer-exhaustive?
        state)
        (compiler-load-lazy-alias-demand-merge
          (compiler-load-session-state-lazy-macro-param-list-demand
            (compiler-load-session-state-shared-view (& state))
            (ast.ast-place-shared-view params)
            alias
            (ast.ast-place-shared-view summary)
            (sym_i64_env.sym-i64-shared-view (& locals)))
          (compiler-load-lazy-alias-demand-merge
            (compiler-load-session-state-lazy-type-demand
              (compiler-load-session-state-shared-view (& state))
              ret
              alias
              (ast.ast-place-shared-view summary)
              (sym_i64_env.sym-i64-shared-view (& locals)))
            (compiler-load-session-state-lazy-expr-demand
              (compiler-load-session-state-shared-view (& state))
              (ast.ast-node-get body)
              alias
              (ast.ast-place-shared-view summary)
              (compiler-load-session-state-lazy-macro-param-list-locals
                (compiler-load-session-state-shared-view (& state))
                params
                locals))))
        (compiler-load-lazy-alias-demand-unknown))]
    [(ast.AstDecl.Extern decl-meta _ _ _ ty)
      (if (compiler-load-session-state-lazy-qualified-observer-exhaustive?
        state)
        (compiler-load-session-state-lazy-type-demand
          state
          ty
          alias
          summary
          locals)
        (compiler-load-lazy-alias-demand-unknown))]
    [(ast.AstDecl.DefEnum decl-meta _ _ variants)
      (if (compiler-load-session-state-lazy-qualified-observer-exhaustive?
        state)
        (compiler-load-session-state-lazy-variant-list-demand
          state
          variants
          alias
          summary
          locals)
        (compiler-load-lazy-alias-demand-unknown))]
    [(ast.AstDecl.DefEnumLifetimes decl-meta _ _ _ variants)
      (if (compiler-load-session-state-lazy-qualified-observer-exhaustive?
        state)
        (compiler-load-session-state-lazy-variant-list-demand
          state
          variants
          alias
          summary
          locals)
        (compiler-load-lazy-alias-demand-unknown))]
    [(ast.AstDecl.DefStruct decl-meta _ _ _ fields)
      (if (compiler-load-session-state-lazy-qualified-observer-exhaustive?
        state)
        (compiler-load-session-state-lazy-field-list-demand
          state
          fields
          alias
          summary
          locals)
        (compiler-load-lazy-alias-demand-unknown))]
    [(ast.AstDecl.DefStructLifetimes decl-meta _ _ _ _ fields)
      (if (compiler-load-session-state-lazy-qualified-observer-exhaustive?
        state)
        (compiler-load-session-state-lazy-field-list-demand
          state
          fields
          alias
          summary
          locals)
        (compiler-load-lazy-alias-demand-unknown))]
    [(ast.AstDecl.Import
        decl-meta
        (ast.AstImportSpec.Spec (ast.AstImportKind.Macro call-expr _) _ _ _ _))
      (compiler-load-session-state-lazy-module-macro-demand
        state
        (ast.ast-node-get call-expr)
        alias
        summary
        locals)]
    [(ast.AstDecl.Import
        decl-meta
        (ast.AstImportSpec.Spec (ast.AstImportKind.MacroDecls _ _) _ _ _ _))
      (compiler-load-lazy-alias-demand-unknown)]
    [(ast.AstDecl.Import decl-meta _) (compiler-load-lazy-alias-demand-none)]
    [(ast.AstDecl.Test _ body _)
      (compiler-load-session-state-lazy-expr-demand
        state
        (ast.ast-node-get body)
        alias
        summary
        locals)]
    [(ast.AstDecl.Unsafe inner)
      ;; ast-decl-comptime-only? and ast-decl-generated-meta recurse through
      ;; Unsafe, so the outer dispatcher has already accounted for metadata.
      (compiler-load-session-state-lazy-decl-demand-inner
        state
        (ast.ast-decl-box-shared-view inner)
        alias
        summary
        locals)]
    [(ast.AstDecl.DefDispatch decl-meta _ _)
      (compiler-load-lazy-alias-demand-none)]
    [(ast.AstDecl.IncludeStr _ _) (compiler-load-lazy-alias-demand-none)]
    [(ast.AstDecl.IncludeStrComptime _ _)
      (compiler-load-lazy-alias-demand-none)]
    [(ast.AstDecl.IncludeStrLzss _ _) (compiler-load-lazy-alias-demand-none)]
    [(ast.AstDecl.IncludeBin _ _) (compiler-load-lazy-alias-demand-none)]
    ;; A future declaration shape might hide references. Keep it conservative.
    [_ (compiler-load-lazy-alias-demand-unknown)]))

(define (compiler-load-session-state-lazy-decl-demand
  [state : CompilerLoadSessionState]
  [decl : ast.AstDecl]
  [alias : i64]
  [summary : CompilerLoadSurfaceSummary]
  [locals : sym_i64_env.SymI64Env]) : CompilerLoadLazyAliasDemand
  (if (ast.ast-decl-comptime-only? (clone decl))
    (if (compiler-load-session-state-lazy-qualified-observer-exhaustive? state)
      (compiler-load-lazy-alias-demand-merge
        (compiler-load-session-state-lazy-generated-meta-demand
          (compiler-load-session-state-shared-view (& state))
          (ast.ast-decl-generated-meta (clone decl))
          alias
          (ast.ast-place-shared-view summary)
          (sym_i64_env.sym-i64-shared-view (& locals)))
        (compiler-load-session-state-lazy-decl-demand-inner
          state
          decl
          alias
          summary
          locals))
      (compiler-load-lazy-alias-demand-unknown))
    (compiler-load-session-state-lazy-decl-demand-inner
      state
      decl
      alias
      summary
      locals)))

(define (compiler-load-session-state-lazy-decl-list-demand
  [state : CompilerLoadSessionState]
  [decls : ast.AstDeclList]
  [alias : i64]
  [summary : CompilerLoadSurfaceSummary]
  [locals : sym_i64_env.SymI64Env]) : CompilerLoadLazyAliasDemand
  (match (ast.ast-decl-list-step decls)
    [(ast.AstDeclListStep.Nil) (compiler-load-lazy-alias-demand-none)]
    [(ast.AstDeclListStep.Cons decl rest)
      (let
        [head : CompilerLoadLazyAliasDemand
          (compiler-load-session-state-lazy-decl-demand
            (compiler-load-session-state-shared-view (& state))
            decl
            alias
            (ast.ast-place-shared-view summary)
            (sym_i64_env.sym-i64-shared-view (& locals)))]
        (if head.unknown
          head
          (compiler-load-lazy-alias-demand-merge
            head
            (compiler-load-session-state-lazy-decl-list-demand
              state
              rest
              alias
              summary
              locals))))]))

(define (compiler-load-lazy-empty-surface-summary) : CompilerLoadSurfaceSummary
  ;; The first structural pass only decides whether a qualified or unresolved
  ;; use already forces loading. It deliberately has no visible names, so a
  ;; possible direct-name use still asks the real summary cache for policy.
  (CompilerLoadSurfaceSummary
    cbi.compiler-builtin-id-fix-empty
    cbi.compiler-builtin-id-fix-empty
    false
    false
    cbi.compiler-builtin-id-fix-empty
    ""
    ""
    (compiler-load-surface-import-list-empty)
    (compiler-load-surface-decl-list-empty)
    false
    false
    false
    false
    (CompilerLoadLazyImportDirect)))

(define (compiler-load-structural-member-demand-from-lazy
  [demand : CompilerLoadLazyAliasDemand]) : CompilerLoadStructuralMemberDemand
  (if (or demand.direct demand.unknown)
    (CompilerLoadStructuralFullDemand)
    (if demand.qualified
      (CompilerLoadStructuralExactMembers demand.members)
      (CompilerLoadStructuralNoDemand))))

(define (compiler-load-session-state-structural-member-demand-with-pools
  [state : CompilerLoadSessionState]
  [decls : ast.AstDeclList]
  [alias : i64]
  [pools : ast.AstNodePoolContext]) : CompilerLoadStructuralMemberDemand
  (let
    [_install-pools : unit (ast.ast-node-pool-context-install! pools)]
    (compiler-load-structural-member-demand-from-lazy
      (compiler-load-session-state-lazy-decl-list-demand
        state
        decls
        alias
        (compiler-load-lazy-empty-surface-summary)
        (sym_i64_env.sym-i64-empty)))))

;; Serial/test compatibility adapter. Production load jobs pass their owned
;; session state to the stateful entry point above.
(define (compiler-load-structural-member-demand-with-pools
  [decls : ast.AstDeclList]
  [alias : i64]
  [pools : ast.AstNodePoolContext]) : CompilerLoadStructuralMemberDemand
  (compiler-load-session-state-structural-member-demand-with-pools
    (compiler-load-active-session-state-shared-view)
    (ast.ast-place-shared-view decls)
    alias
    pools))

(define (compiler-load-structural-member-demand
  [decls : ast.AstDeclList]
  [alias : i64]) : CompilerLoadStructuralMemberDemand
  (compiler-load-structural-member-demand-with-pools
    decls
    alias
    (ast.ast-node-pool-context-capture-active)))

(define (compiler-load-structural-member-demand-contains?
  [demand : CompilerLoadStructuralMemberDemand]
  [member : i64]) : bool
  (match demand
    [(CompilerLoadStructuralExactMembers members)
      (sym_i64_env.sym-i64-contains-id members member)]
    [_ false]))

(define (compiler-load-structural-member-set-count
  [members : sym_i64_env.SymI64Env]) : i64
  (match (sym_i64_env.sym-i64-view members)
    [(sym_i64_env.SymI64ViewNil) 0]
    [(sym_i64_env.SymI64ViewBind _ _ rest)
      (+ 1 (compiler-load-structural-member-set-count rest))]))

(define (compiler-load-structural-member-demand-count
  [demand : CompilerLoadStructuralMemberDemand]) : i64
  (match demand
    [(CompilerLoadStructuralExactMembers members)
      (compiler-load-structural-member-set-count members)]
    [_ 0]))

(define (compiler-load-session-state-lazy-import-preload-demand
  [state : CompilerLoadSessionState]
  [candidate : bool]
  [alias : ast.AstMaybeImportAlias]
  [rest : ast.AstDeclList]
  [pools : ast.AstNodePoolContext]) : CompilerLoadLazyAliasDemand
  ;; Most real module imports are immediately used through `alias.member`.
  ;; Such use (and any unresolved generated use) must load anyway, so avoid a
  ;; speculative second parse that only creates a summary we cannot use.
  ;; Direct names remain summary-driven because their ownership and policy are
  ;; part of the imported module surface.
  (let
    [_install-pools : unit (ast.ast-node-pool-context-install! pools)]
    (if candidate
      (match alias
        [(ast.AstMaybeImportAlias.Some alias-name)
          (compiler-load-session-state-lazy-decl-list-demand
            state
            rest
            alias-name
            (compiler-load-lazy-empty-surface-summary)
            (sym_i64_env.sym-i64-empty))]
        [(ast.AstMaybeImportAlias.No) (compiler-load-lazy-alias-demand-none)])
      (compiler-load-lazy-alias-demand-none))))

;; Serial/test compatibility adapter. Stateful loader traversal must use
;; compiler-load-session-state-lazy-import-preload-demand directly.
(define (compiler-load-lazy-import-preload-demand
  [candidate : bool]
  [alias : ast.AstMaybeImportAlias]
  [rest : ast.AstDeclList]
  [pools : ast.AstNodePoolContext]) : CompilerLoadLazyAliasDemand
  (compiler-load-session-state-lazy-import-preload-demand
    (compiler-load-active-session-state-shared-view)
    candidate
    alias
    rest
    pools))

(define (compiler-load-session-state-lazy-import-preload-candidate?
  [load-state : CompilerLoadSessionState]
  [importer-path : String]
  [kind : ast.AstImportKind]
  [alias : ast.AstMaybeImportAlias]) : bool
  (and
    (compiler-load-session-state-lazy-imports-enabled? load-state)
    (not (compiler-load-prelude-importer? importer-path))
    (match kind
      [(ast.AstImportKind.Module) true]
      [_ false])
    (match alias
      [(ast.AstMaybeImportAlias.Some _) true]
      [(ast.AstMaybeImportAlias.No) false])))

;; Serial/test compatibility adapter. Stateful loader traversal must use the
;; session-explicit candidate above.
(define (compiler-load-lazy-import-preload-candidate?
  [importer-path : String]
  [kind : ast.AstImportKind]
  [alias : ast.AstMaybeImportAlias]) : bool
  (compiler-load-session-state-lazy-import-preload-candidate?
    (compiler-load-active-session-state-shared-view)
    importer-path
    kind
    alias))

(define (compiler-load-lazy-import-preload-summary-with-state-and-pools
  [load-state : CompilerLoadSessionState]
  [resolved : String]
  [resolved-id : i64]
  [stdlib-roots : svec.Vec]
  [expected-module : ast.AstMaybeModuleName]
  [import-root : String]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]) : unit
  (compiler-load-surface-summary-ensure-with-pools
    load-state
    resolved
    resolved-id
    stdlib-roots
    expected-module
    import-root
    cfgs
    pools))

(define (compiler-load-lazy-import-preload-summary-with-pools
  [resolved : String]
  [resolved-id : i64]
  [stdlib-roots : svec.Vec]
  [expected-module : ast.AstMaybeModuleName]
  [import-root : String]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]) : unit
  (compiler-load-lazy-import-preload-summary-with-state-and-pools
    (compiler-load-active-session-state-shared-view)
    resolved
    resolved-id
    stdlib-roots
    expected-module
    import-root
    cfgs
    pools))

;; A moduleless import target reachable only next to its importer (neither
;; stdlib-prefixed nor under a configured root) is the dotted successor of a
;; legacy string-path import: its declarations belong to the importing
;; compilation and must be typechecked even while nothing references them.
;; Module-declared, stdlib, or root-resident targets are library units that
;; lazy loading may skip while they stay unused.
(define (compiler-load-lazy-import-include-semantics?
  [summary : CompilerLoadSurfaceSummary]
  [resolved : String]
  [stdlib-roots : svec.Vec]) : bool
  (and
    (not summary.explicit-module)
    (not (compiler-load-stdlib-import? summary.source-path))
    (not
      (compiler-load-path-under-roots-from?
        (compiler-load-normalize-path resolved)
        (ast.ast-place-shared-view stdlib-roots)
        0
        (svec.len (& stdlib-roots))))))

(define (compiler-load-lazy-import-skip-with-state?
  [load-state : CompilerLoadSessionState]
  [importer-path : String]
  [kind : ast.AstImportKind]
  [resolved : String]
  [resolved-id : i64]
  [expected-module : ast.AstMaybeModuleName]
  [alias : ast.AstMaybeImportAlias]
  [rest : ast.AstDeclList]
  [pools : ast.AstNodePoolContext]
  [preload-demand : CompilerLoadLazyAliasDemand]
  [stdlib-roots : svec.Vec]) : bool
  (let
    [_install-pools : unit (ast.ast-node-pool-context-install! pools)]
    (if (or
      (not
        (compiler-load-session-state-lazy-imports-enabled?
          (compiler-load-session-state-shared-view (& load-state))))
      (compiler-load-prelude-importer? importer-path))
      false
      (match (compiler-load-session-state-surface-summary-find-source
        load-state
        resolved-id)
        [(CompilerLoadNoSurfaceSummary) false]
        [(CompilerLoadSomeSurfaceSummary summary)
          (if (compiler-load-lazy-import-include-semantics?
            (ast.ast-place-shared-view summary)
            (clone resolved)
            (ast.ast-place-shared-view stdlib-roots))
            false
            (let
              [policy : CompilerLoadLazyImportPolicy summary.lazy-policy]
              (match kind
                [(ast.AstImportKind.Module)
                  (if (compiler-load-lazy-decl-list-module-macro-qualified-by?
                    (ast.ast-place-shared-view rest)
                    (match expected-module
                      [(ast.AstMaybeModuleName.Some module-id) module-id]
                      [(ast.AstMaybeModuleName.No) summary.module-id]))
                    false
                    (match alias
                      [(ast.AstMaybeImportAlias.Some alias-name)
                        (match policy
                          [(CompilerLoadLazyImportEager) false]
                          [(CompilerLoadLazyImportQualified)
                            (not
                              (compiler-load-lazy-alias-demand-requires-load?
                                policy
                                (compiler-load-session-state-lazy-decl-list-demand
                                  load-state
                                  rest
                                  alias-name
                                  summary
                                  (sym_i64_env.sym-i64-empty))))]
                          [(CompilerLoadLazyImportDirect)
                            (if preload-demand.direct
                              false
                              (not
                                (compiler-load-lazy-alias-demand-requires-load?
                                  policy
                                  (compiler-load-session-state-lazy-decl-list-demand
                                    load-state
                                    rest
                                    alias-name
                                    summary
                                    (sym_i64_env.sym-i64-empty)))))])]
                      [(ast.AstMaybeImportAlias.No) false]))]
                [_ false])))]))))

(define (compiler-load-lazy-import-skip?
  [importer-path : String]
  [kind : ast.AstImportKind]
  [resolved : String]
  [resolved-id : i64]
  [expected-module : ast.AstMaybeModuleName]
  [alias : ast.AstMaybeImportAlias]
  [rest : ast.AstDeclList]
  [pools : ast.AstNodePoolContext]
  [preload-demand : CompilerLoadLazyAliasDemand]
  [stdlib-roots : svec.Vec]) : bool
  (compiler-load-lazy-import-skip-with-state?
    (compiler-load-active-session-state-shared-view)
    importer-path
    kind
    resolved
    resolved-id
    expected-module
    alias
    rest
    pools
    preload-demand
    stdlib-roots))

(define (compiler-load-surface-zero-span) : ast.AstSourceSpan
  (ast.ast-source-span 0 0 0 0))

(define (compiler-load-surface-module-maybe
  [module-name : ast.AstMaybeModuleName]) : CompilerLoadSurfaceMaybeString
  (match module-name
    [(ast.AstMaybeModuleName.No) (CompilerLoadSurfaceNoString)]
    [(ast.AstMaybeModuleName.Some name)
      (CompilerLoadSurfaceSomeString (ci.intern-str name))]))

(define (compiler-load-surface-alias-maybe [alias : ast.AstMaybeImportAlias]) : CompilerLoadSurfaceMaybeString
  (match alias
    [(ast.AstMaybeImportAlias.No) (CompilerLoadSurfaceNoString)]
    [(ast.AstMaybeImportAlias.Some name)
      (CompilerLoadSurfaceSomeString (ci.intern-str name))]))

(define (compiler-load-surface-import-kind [kind : ast.AstImportKind]) : CompilerLoadSurfaceImportKind
  (match kind
    [(ast.AstImportKind.Module) (CompilerLoadSurfaceImportModule)]
    [(ast.AstImportKind.ModuleAll) (CompilerLoadSurfaceImportModule)]
    [(ast.AstImportKind.ModuleItem _) (CompilerLoadSurfaceImportModule)]
    [(ast.AstImportKind.Macro _ _) (CompilerLoadSurfaceImportMacro)]
    [(ast.AstImportKind.MacroDecls _ _) (CompilerLoadSurfaceImportMacroDecls)]))

(define (compiler-load-surface-import-decl-emitting? [kind : ast.AstImportKind]) : bool
  (match kind
    [(ast.AstImportKind.MacroDecls _ _) true]
    [_ false]))

(define (compiler-load-surface-import-default-alias
  [kind : ast.AstImportKind]
  [import-path : String]) : CompilerLoadSurfaceMaybeString
  (match kind
    [(ast.AstImportKind.Module)
      (CompilerLoadSurfaceSomeString
        (parser.parse-ast-dotted-import-default-alias import-path))]
    [_ (CompilerLoadSurfaceNoString)]))

(define (compiler-load-surface-macro-result-kind [ret : ast.AstType]) : CompilerLoadSurfaceMacroResultKind
  (match ret
    [(ast.AstType.Expr) (CompilerLoadSurfaceMacroExpr)]
    [(ast.AstType.Var name)
      (cond
        [(or
            (= name cbi.compiler-builtin-id-fix-Expr)
            (= name cbi.compiler-builtin-id-fix-expr))
          (CompilerLoadSurfaceMacroExpr)]
        [(or
            (= name cbi.compiler-builtin-id-fix-Module)
            (= name cbi.compiler-builtin-id-fix-module))
          (CompilerLoadSurfaceMacroModule)]
        [(or
            (= name cbi.compiler-builtin-id-fix-Decls)
            (= name cbi.compiler-builtin-id-fix-decls))
          (CompilerLoadSurfaceMacroDecls)]
        [else (CompilerLoadSurfaceMacroOther)])]
    [_ (CompilerLoadSurfaceMacroOther)]))

(define (compiler-load-surface-macro-result-decl-emitting? [ret : ast.AstType]) : bool
  (match (compiler-load-surface-macro-result-kind ret)
    [(CompilerLoadSurfaceMacroModule) true]
    [(CompilerLoadSurfaceMacroDecls) true]
    [_ false]))

(define (compiler-load-surface-fn-export? [export : ast.AstFnExport]) : bool
  (match export
    [(ast.AstFnExport.No) false]
    [(ast.AstFnExport.Export _) true]))

(define (compiler-load-surface-generated-meta?
  [meta : ast.AstGeneratedDeclMeta]) : bool
  (match meta
    [(ast.AstGeneratedDeclMeta.No) false]
    [(ast.AstGeneratedDeclMeta.Some _ _ _ _) true]))

(define (compiler-load-surface-field-list-cleanup?
  [fields : ast.AstFieldDefList]) : bool
  (compiler-load-surface-field-list-cleanup-at? (& fields) 0))

(define (compiler-load-surface-field-list-cleanup-at?
  [fields : (& fields ast.AstFieldDefList)]
  [index : i64]) : bool
  (if (>= index (ast.ast-field-def-list-len fields))
    false
    (match (ast.ast-field-def-list-get
      fields
      index
      (ast.ast-field-def-fallback))
      [(ast.AstFieldDef.Def _ _ cleanup)
        (or
          (ast.ast-field-cleanup? cleanup)
          (compiler-load-surface-field-list-cleanup-at? fields (+ index 1)))])))

(define (compiler-load-surface-variant-payload-cleanup?
  [cleanups : ast.AstVariantPayloadCleanupList]) : bool
  (compiler-load-surface-variant-payload-cleanup-at? (& cleanups) 0))

(define (compiler-load-surface-variant-payload-cleanup-at?
  [cleanups : (& cleanups ast.AstVariantPayloadCleanupList)]
  [index : i64]) : bool
  (if (>= index (ast.ast-variant-payload-cleanup-list-len cleanups))
    false
    (or
      (ast.ast-variant-payload-cleanup?
        (ast.ast-variant-payload-cleanup-list-get
          cleanups
          index
          (ast.ast-variant-payload-cleanup-fallback)))
      (compiler-load-surface-variant-payload-cleanup-at? cleanups (+ index 1)))))

(define (compiler-load-surface-variant-list-cleanup?
  [variants : ast.AstVariantDefList]) : bool
  (compiler-load-surface-variant-list-cleanup-at? (& variants) 0))

(define (compiler-load-surface-variant-list-cleanup-at?
  [variants : (& variants ast.AstVariantDefList)]
  [index : i64]) : bool
  (if (>= index (ast.ast-variant-def-list-len variants))
    false
    (match (ast.ast-variant-def-list-get
      variants
      index
      (ast.ast-variant-def-fallback))
      [(ast.AstVariantDef.Def _ _ cleanups)
        (or
          (compiler-load-surface-variant-payload-cleanup? cleanups)
          (compiler-load-surface-variant-list-cleanup-at? variants (+ index 1)))])))

(define (compiler-load-surface-counts-add
  [left : CompilerLoadSurfaceCounts]
  [right : CompilerLoadSurfaceCounts]) : CompilerLoadSurfaceCounts
  (CompilerLoadSurfaceCounts
    (+ left.imports right.imports)
    (+ left.decls right.decls)))

(define (compiler-load-surface-count-decl [decl : ast.AstDecl]) : CompilerLoadSurfaceCounts
  (match decl
    [(ast.AstDecl.Import _ _) (CompilerLoadSurfaceCounts 1 0)]
    [(ast.AstDecl.Unsafe inner-box)
      (compiler-load-surface-count-decl
        (ast.ast-decl-box-shared-view inner-box))]
    [(ast.AstDecl.ModuleBody _ body-box)
      (compiler-load-surface-count-decls
        (ast.ast-decl-list-box-shared-view body-box))]
    [(ast.AstDecl.Module _) (CompilerLoadSurfaceCounts 0 0)]
    [_ (CompilerLoadSurfaceCounts 0 1)]))

(define (compiler-load-surface-count-decls [decls : ast.AstDeclList]) : CompilerLoadSurfaceCounts
  (match (ast.ast-decl-list-step decls)
    [(ast.AstDeclListStep.Nil) (CompilerLoadSurfaceCounts 0 0)]
    [(ast.AstDeclListStep.Cons decl rest)
      (compiler-load-surface-counts-add
        (compiler-load-surface-count-decl decl)
        (compiler-load-surface-count-decls rest))]))

(define (compiler-load-surface-build-empty [counts : CompilerLoadSurfaceCounts]) : CompilerLoadSurfaceBuild
  (CompilerLoadSurfaceBuild
    (array.make-array CompilerLoadSurfaceImport counts.imports)
    0
    (array.make-array CompilerLoadSurfaceDecl counts.decls)
    0
    false
    false
    false
    false))

(define (compiler-load-surface-build-add-import
  [build : CompilerLoadSurfaceBuild]
  [import-edge : CompilerLoadSurfaceImport]
  [decl-emitting : bool]) : CompilerLoadSurfaceBuild
  (let
    [index : i64 build.import-len]
    (begin
      (set! (array-ref build.import-slots index) import-edge)
      (CompilerLoadSurfaceBuild
        build.import-slots
        (+ index 1)
        build.decl-slots
        build.decl-len
        build.has-tests
        build.has-export-metadata
        build.has-generated-decls
        (or build.has-decl-emitting-macro decl-emitting)))))

(define (compiler-load-surface-build-add-decl
  [build : CompilerLoadSurfaceBuild]
  [decl : CompilerLoadSurfaceDecl]
  [has-test : bool]
  [has-export : bool]
  [has-generated : bool]
  [decl-emitting : bool]) : CompilerLoadSurfaceBuild
  (let
    [index : i64 build.decl-len]
    (begin
      (set! (array-ref build.decl-slots index) decl)
      (CompilerLoadSurfaceBuild
        build.import-slots
        build.import-len
        build.decl-slots
        (+ index 1)
        (or build.has-tests has-test)
        (or build.has-export-metadata has-export)
        (or build.has-generated-decls has-generated)
        (or build.has-decl-emitting-macro decl-emitting)))))

(define (compiler-load-surface-build-decl-inner
  [source-path : String]
  [module-id : i64]
  [decl : ast.AstDecl]
  [generated : bool]
  [was-unsafe : bool]
  [build : CompilerLoadSurfaceBuild]) : CompilerLoadSurfaceBuild
  (match decl
    [(ast.AstDecl.Import
        decl-meta
        (ast.AstImportSpec.Spec kind import-path module-name alias span))
      (compiler-load-surface-build-add-import
        build
        (CompilerLoadSurfaceImport
          (compiler-load-surface-import-kind kind)
          module-id
          source-path
          (clone import-path)
          (compiler-load-surface-module-maybe module-name)
          (compiler-load-surface-alias-maybe alias)
          (compiler-load-surface-import-default-alias kind import-path)
          (clone (__tl-box-place span)))
        (compiler-load-surface-import-decl-emitting? kind))]
    [(ast.AstDecl.Def decl-meta name maybe-ty _)
      (compiler-load-surface-build-add-decl
        build
        (CompilerLoadSurfaceDecl
          (CompilerLoadSurfaceValue)
          name
          module-id
          (CompilerLoadSurfaceValueSignature maybe-ty)
          (CompilerLoadSurfaceMacroOther)
          false
          false
          generated
          was-unsafe
          (compiler-load-surface-zero-span))
        false
        false
        generated
        false)]
    [(ast.AstDecl.DefFn decl-meta name params ret _ metadata)
      (let
        [has-export : bool
          (compiler-load-surface-fn-export?
            (ast.ast-fn-metadata-export metadata))]
        (compiler-load-surface-build-add-decl
          build
          (CompilerLoadSurfaceDecl
            (CompilerLoadSurfaceFunction)
            name
            module-id
            (CompilerLoadSurfaceFunctionSignature params ret)
            (CompilerLoadSurfaceMacroOther)
            false
            has-export
            generated
            was-unsafe
            (compiler-load-surface-zero-span))
          false
          has-export
          generated
          false))]
    [(ast.AstDecl.Extern decl-meta name kind meta ty)
      (compiler-load-surface-build-add-decl
        build
        (CompilerLoadSurfaceDecl
          (CompilerLoadSurfaceExtern)
          name
          module-id
          (CompilerLoadSurfaceExternSignature
            kind
            (ast.ast-extern-metadata-box-shared-view meta)
            ty)
          (CompilerLoadSurfaceMacroOther)
          false
          false
          generated
          was-unsafe
          (compiler-load-surface-zero-span))
        false
        false
        generated
        false)]
    [(ast.AstDecl.DefStruct decl-meta name repr cleanup fields)
      (let
        [has-cleanup : bool
          (or
            (ast.ast-struct-cleanup? cleanup)
            (compiler-load-surface-field-list-cleanup?
              (ast.ast-place-shared-view fields)))]
        (compiler-load-surface-build-add-decl
          build
          (CompilerLoadSurfaceDecl
            (CompilerLoadSurfaceStruct)
            name
            module-id
            (CompilerLoadSurfaceStructSignature
              (ast.ast-lifetime-list-new)
              repr
              cleanup
              fields)
            (CompilerLoadSurfaceMacroOther)
            has-cleanup
            false
            generated
            was-unsafe
            (compiler-load-surface-zero-span))
          false
          false
          generated
          false))]
    [(ast.AstDecl.DefStructLifetimes
        decl-meta
        name
        lifetimes
        repr
        cleanup
        fields)
      (let
        [has-cleanup : bool
          (or
            (ast.ast-struct-cleanup? cleanup)
            (compiler-load-surface-field-list-cleanup?
              (ast.ast-place-shared-view fields)))]
        (compiler-load-surface-build-add-decl
          build
          (CompilerLoadSurfaceDecl
            (CompilerLoadSurfaceStruct)
            name
            module-id
            (CompilerLoadSurfaceStructSignature lifetimes repr cleanup fields)
            (CompilerLoadSurfaceMacroOther)
            has-cleanup
            false
            generated
            was-unsafe
            (compiler-load-surface-zero-span))
          false
          false
          generated
          false))]
    [(ast.AstDecl.DefEnum decl-meta name cleanup variants)
      (let
        [has-cleanup : bool
          (or
            (ast.ast-enum-cleanup? cleanup)
            (compiler-load-surface-variant-list-cleanup?
              (ast.ast-place-shared-view variants)))]
        (compiler-load-surface-build-add-decl
          build
          (CompilerLoadSurfaceDecl
            (CompilerLoadSurfaceEnum)
            name
            module-id
            (CompilerLoadSurfaceEnumSignature
              (ast.ast-lifetime-list-new)
              cleanup
              variants)
            (CompilerLoadSurfaceMacroOther)
            has-cleanup
            false
            generated
            was-unsafe
            (compiler-load-surface-zero-span))
          false
          false
          generated
          false))]
    [(ast.AstDecl.DefEnumLifetimes decl-meta name lifetimes cleanup variants)
      (let
        [has-cleanup : bool
          (or
            (ast.ast-enum-cleanup? cleanup)
            (compiler-load-surface-variant-list-cleanup?
              (ast.ast-place-shared-view variants)))]
        (compiler-load-surface-build-add-decl
          build
          (CompilerLoadSurfaceDecl
            (CompilerLoadSurfaceEnum)
            name
            module-id
            (CompilerLoadSurfaceEnumSignature lifetimes cleanup variants)
            (CompilerLoadSurfaceMacroOther)
            has-cleanup
            false
            generated
            was-unsafe
            (compiler-load-surface-zero-span))
          false
          false
          generated
          false))]
    [(ast.AstDecl.DefMacro decl-meta name params ret body-box)
      (let
        [result-kind : CompilerLoadSurfaceMacroResultKind
          (compiler-load-surface-macro-result-kind
            (ast.ast-place-shared-view ret))]
        [decl-emitting : bool
          (compiler-load-surface-macro-result-decl-emitting?
            (ast.ast-place-shared-view ret))]
        (compiler-load-surface-build-add-decl
          build
          (CompilerLoadSurfaceDecl
            (CompilerLoadSurfaceMacro)
            name
            module-id
            (CompilerLoadSurfaceMacroSignature params ret body-box)
            result-kind
            false
            false
            generated
            was-unsafe
            (compiler-load-surface-zero-span))
          false
          false
          generated
          decl-emitting))]
    [(ast.AstDecl.DefDispatch decl-meta name variants)
      (compiler-load-surface-build-add-decl
        build
        (CompilerLoadSurfaceDecl
          (CompilerLoadSurfaceDispatch)
          name
          module-id
          (CompilerLoadSurfaceDispatchSignature variants)
          (CompilerLoadSurfaceMacroOther)
          false
          false
          generated
          was-unsafe
          (compiler-load-surface-zero-span))
        false
        false
        generated
        false)]
    [(ast.AstDecl.Test name _ span)
      (compiler-load-surface-build-add-decl
        build
        (CompilerLoadSurfaceDecl
          (CompilerLoadSurfaceTest)
          name
          module-id
          (CompilerLoadSurfaceNoSignature)
          (CompilerLoadSurfaceMacroOther)
          false
          false
          generated
          was-unsafe
          span)
        true
        false
        generated
        false)]
    [(ast.AstDecl.IncludeStr name _)
      (compiler-load-surface-build-add-decl
        build
        (CompilerLoadSurfaceDecl
          (CompilerLoadSurfaceIncludeStr)
          name
          module-id
          (CompilerLoadSurfaceNoSignature)
          (CompilerLoadSurfaceMacroOther)
          false
          false
          generated
          was-unsafe
          (compiler-load-surface-zero-span))
        false
        false
        generated
        false)]
    [(ast.AstDecl.IncludeStrComptime name _)
      (compiler-load-surface-build-add-decl
        build
        (CompilerLoadSurfaceDecl
          (CompilerLoadSurfaceIncludeStrComptime)
          name
          module-id
          (CompilerLoadSurfaceNoSignature)
          (CompilerLoadSurfaceMacroExpr)
          false
          false
          generated
          was-unsafe
          (compiler-load-surface-zero-span))
        false
        false
        generated
        false)]
    [(ast.AstDecl.IncludeStrLzss name _)
      (compiler-load-surface-build-add-decl
        build
        (CompilerLoadSurfaceDecl
          (CompilerLoadSurfaceIncludeBin)
          name
          module-id
          (CompilerLoadSurfaceNoSignature)
          (CompilerLoadSurfaceMacroOther)
          false
          false
          generated
          was-unsafe
          (compiler-load-surface-zero-span))
        false
        false
        generated
        false)]
    [(ast.AstDecl.IncludeBin name _)
      (compiler-load-surface-build-add-decl
        build
        (CompilerLoadSurfaceDecl
          (CompilerLoadSurfaceIncludeBin)
          name
          module-id
          (CompilerLoadSurfaceNoSignature)
          (CompilerLoadSurfaceMacroOther)
          false
          false
          generated
          was-unsafe
          (compiler-load-surface-zero-span))
        false
        false
        generated
        false)]
    [(ast.AstDecl.Unsafe inner-box)
      (compiler-load-surface-build-decl
        source-path
        module-id
        (ast.ast-decl-box-shared-view inner-box)
        generated
        true
        build)]
    [(ast.AstDecl.ModuleBody nested-module body-box)
      (compiler-load-surface-build-decls-into
        source-path
        nested-module
        (ast.ast-decl-list-box-shared-view body-box)
        build)]
    [(ast.AstDecl.Module _) build]
    [_ build]))

(define (compiler-load-surface-build-decl
  [source-path : String]
  [module-id : i64]
  [decl : ast.AstDecl]
  [generated : bool]
  [was-unsafe : bool]
  [build : CompilerLoadSurfaceBuild]) : CompilerLoadSurfaceBuild
  (compiler-load-surface-build-decl-inner
    source-path
    module-id
    (clone decl)
    (or
      generated
      (compiler-load-surface-generated-meta? (ast.ast-decl-generated-meta decl)))
    was-unsafe
    build))

(define (compiler-load-surface-build-decls-into
  [source-path : String]
  [module-id : i64]
  [decls : ast.AstDeclList]
  [build : CompilerLoadSurfaceBuild]) : CompilerLoadSurfaceBuild
  (match (ast.ast-decl-list-step decls)
    [(ast.AstDeclListStep.Nil) build]
    [(ast.AstDeclListStep.Cons decl rest-box)
      (let
        [rest : ast.AstDeclList rest-box]
        (match (clone decl)
          [(ast.AstDecl.Module next-module)
            (compiler-load-surface-build-decls-into
              (clone source-path)
              next-module
              rest
              build)]
          [(ast.AstDecl.ModuleBody nested-module body-box)
            (compiler-load-surface-build-decls-into
              (clone source-path)
              module-id
              rest
              (compiler-load-surface-build-decls-into
                source-path
                nested-module
                (ast.ast-decl-list-box-shared-view body-box)
                build))]
          [_
            (compiler-load-surface-build-decls-into
              (clone source-path)
              module-id
              rest
              (compiler-load-surface-build-decl
                source-path
                module-id
                decl
                false
                false
                build))]))]))

(define (compiler-load-surface-build-decls
  [source-path : String]
  [module-id : i64]
  [decls : ast.AstDeclList]) : CompilerLoadSurfaceBuild
  (compiler-load-surface-build-decls-into
    source-path
    module-id
    (ast.ast-place-shared-view decls)
    (compiler-load-surface-build-empty
      (compiler-load-surface-count-decls decls))))

(define (compiler-load-surface-summary-from-decls
  [path : String]
  [source-path-id : i64]
  [root-id : String]
  [module-id : i64]
  [declaration-module-id : i64]
  [explicit-module : bool]
  [qualified-load : bool]
  [decls : ast.AstDeclList]) : CompilerLoadSurfaceSummary
  (let
    [source-path : String (compiler-load-normalize-path path)]
    [build : CompilerLoadSurfaceBuild
      (compiler-load-surface-build-decls (clone source-path) module-id decls)]
    (CompilerLoadSurfaceSummary
      module-id
      declaration-module-id
      explicit-module
      qualified-load
      source-path-id
      source-path
      (compiler-load-normalize-path root-id)
      (CompilerLoadSurfaceImportList
        (ast.ast-place-shared-view build.import-slots)
        build.import-len)
      (CompilerLoadSurfaceDeclList
        (ast.ast-place-shared-view build.decl-slots)
        build.decl-len)
      build.has-tests
      build.has-export-metadata
      build.has-generated-decls
      build.has-decl-emitting-macro
      (compiler-load-surface-lazy-policy
        (CompilerLoadSurfaceDeclList build.decl-slots build.decl-len)
        build.has-tests
        build.has-export-metadata
        build.has-generated-decls
        build.has-decl-emitting-macro))))

(define (compiler-load-surface-summary-build
  [path : String]
  [source-path-id : i64]
  [root-id : String]
  [program : ast.AstProgram]
  [fallback-id : i64]
  [qualified-load : bool]) : ResultCompilerLoadSurfaceSummary
  (match program
    [(ast.AstProgram.Program decls-box)
      (let
        [decls : ast.AstDeclList (ast.ast-decl-list-box-shared-view decls-box)]
        [source-module : String
          (compiler-load-decls-source-module (ast.ast-place-shared-view decls))]
        (match (compiler-load-decls-module-id
          (clone path)
          (ast.ast-place-shared-view decls)
          fallback-id)
          [(ResultCompilerLoadModuleId.Ok _ module-id)
            (match (compiler-load-check-dotted-import-aliases
              (clone path)
              (ast.ast-place-shared-view decls)
              source-module)
              [(ResultCompilerLoadAliasCheck.Ok)
                (ResultCompilerLoadSurfaceSummary.Ok
                  (compiler-load-surface-summary-from-decls
                    path
                    source-path-id
                    root-id
                    module-id
                    module-id
                    (compiler-load-decl-list-has-module?
                      (ast.ast-place-shared-view decls))
                    qualified-load
                    decls))]
              [(ResultCompilerLoadAliasCheck.Err diag)
                (ResultCompilerLoadSurfaceSummary.Err diag)])]
          [(ResultCompilerLoadModuleId.Err diag)
            (ResultCompilerLoadSurfaceSummary.Err diag)]))]))

(define (compiler-load-decl-defines-selected-item?
  [decl : ast.AstDecl]
  [item : i64]) : bool
  (match (ast.ast-decl-unwrapped decl)
    [(ast.AstDecl.Def decl-meta name _ _) (= name item)]
    [(ast.AstDecl.DefFn decl-meta name _ _ _ _) (= name item)]
    [(ast.AstDecl.DefMacro decl-meta name _ _ _) (= name item)]
    [(ast.AstDecl.DefDispatch decl-meta name _) (= name item)]
    [(ast.AstDecl.Extern decl-meta name _ _ _) (= name item)]
    [(ast.AstDecl.DefEnum decl-meta name _ variants)
      (or
        (= name item)
        (compiler-load-lazy-surface-variant-direct-name? variants item))]
    [(ast.AstDecl.DefEnumLifetimes decl-meta name _ _ variants)
      (or
        (= name item)
        (compiler-load-lazy-surface-variant-direct-name? variants item))]
    [(ast.AstDecl.DefStruct decl-meta name _ _ _) (= name item)]
    [(ast.AstDecl.DefStructLifetimes decl-meta name _ _ _ _) (= name item)]
    [_ false]))

(define (compiler-load-module-defines-selected-item?
  [decls : ast.AstDeclList]
  [target-module : i64]
  [item : i64]) : bool
  (let
    [count : i64 (ast.ast-decl-list-len (& decls))]
    [cur-module : i64 cbi.compiler-builtin-id-fix-empty]
    [index : i64 0]
    (begin
      (while (< index count)
        (let
          [decl : ast.AstDecl
            (ast.ast-array-shared-view decls.slots (+ decls.offset index))]
          (begin
            (match (ast.ast-place-shared-view decl)
              [(ast.AstDecl.Module next-module) (set! cur-module next-module)]
              [_
                (when
                  (and
                    (= cur-module target-module)
                    (compiler-load-decl-defines-selected-item? decl item))
                  (return true))])
            (set! index (+ index 1)))))
      false)))

(define (compiler-load-selected-item-present?
  [kind : ast.AstImportKind]
  [expected-module : ast.AstMaybeModuleName]
  [decls : ast.AstDeclList]) : bool
  (match kind
    [(ast.AstImportKind.ModuleItem item)
      (match expected-module
        [(ast.AstMaybeModuleName.Some target-module)
          (compiler-load-module-defines-selected-item? decls target-module item)]
        [(ast.AstMaybeModuleName.No) false])]
    [_ true]))

(define (compiler-load-expected-module-seen?
  [seen : sym_i64_env.SymI64Env]
  [expected-module : ast.AstMaybeModuleName]) : bool
  (match expected-module
    [(ast.AstMaybeModuleName.Some module-id)
      (sym_i64_env.sym-i64-contains-id seen module-id)]
    [(ast.AstMaybeModuleName.No) false]))

(define (compiler-load-missing-selected-item-message
  [module-name : String]
  [kind : ast.AstImportKind]) : String
  (match kind
    [(ast.AstImportKind.ModuleItem item)
      (str_cat.str-cat
        "compiler-load: module '"
        (str_cat.str-cat
          module-name
          (str_cat.str-cat
            "' has no selected item '"
            (str_cat.str-cat (ci.intern-str item) "'"))))]
    [_ "compiler-load: missing selected import item"]))

(define (compiler-load-alias-decl-list
  [kind : ast.AstImportKind]
  [import-path : String]
  [expected-module : ast.AstMaybeModuleName]
  [alias : ast.AstMaybeImportAlias]
  [span : ast.AstSourceSpan]
  [source : ast.AstDeclList]
  [rest : ast.AstDeclList]) : ast.AstDeclList
  (match alias
    [(ast.AstMaybeImportAlias.Some _)
      (compiler-load-decl-list-prepend-from-source
        (ast.AstDecl.Import
          (ast.ast-decl-meta-runtime-shared-view)
          (ast.AstImportSpec.Spec
            kind
            import-path
            expected-module
            alias
            (box span)))
        source
        rest)]
    [(ast.AstMaybeImportAlias.No) rest]))

(define (compiler-load-alias-path-list
  [importer-path : String]
  [importer-path-id : i64]
  [importer-decl-owner-id : i64]
  [alias : ast.AstMaybeImportAlias]
  [rest : ast.AstDeclPathList]) : ast.AstDeclPathList
  (match alias
    [(ast.AstMaybeImportAlias.Some _)
      (ast.ast-decl-path-list-prepend-builder-with-owner-and-provenance-id
        importer-path
        importer-decl-owner-id
        importer-path-id
        rest)]
    [(ast.AstMaybeImportAlias.No) rest]))

(define (compiler-load-alias-module-list
  [importer-module-id : i64]
  [alias : ast.AstMaybeImportAlias]
  [rest : ast.AstDeclModuleList]) : ast.AstDeclModuleList
  (match alias
    [(ast.AstMaybeImportAlias.Some _)
      (ast.ast-decl-module-list-prepend-builder-id importer-module-id rest)]
    [(ast.AstMaybeImportAlias.No) rest]))

;; Imported module declarations switch the flattened declaration context; restore
;; the importer's source module before the alias marker and remaining decls.
(define (compiler-load-decls-after-import
  [kind : ast.AstImportKind]
  [import-path : String]
  [expected-module : ast.AstMaybeModuleName]
  [alias : ast.AstMaybeImportAlias]
  [span : ast.AstSourceSpan]
  [_importer-source-module : String]
  [importer-source-module-id : i64]
  [source : ast.AstDeclList]
  [imported-decls : ast.AstDeclList]
  [rest : ast.AstDeclList]) : ast.AstDeclList
  (let
    [after-alias : ast.AstDeclList
      (compiler-load-alias-decl-list
        kind
        import-path
        expected-module
        alias
        span
        source
        rest)]
    (if (compiler-load-decl-list-has-module? imported-decls)
      (compiler-load-decl-list-prepend
        (ast.ast-decl-module-id importer-source-module-id)
        after-alias)
      after-alias)))

(define (compiler-load-paths-after-import
  [importer-path : String]
  [importer-path-id : i64]
  [importer-decl-owner-id : i64]
  [alias : ast.AstMaybeImportAlias]
  [imported-decls : ast.AstDeclList]
  [rest : ast.AstDeclPathList]) : ast.AstDeclPathList
  (let
    [after-alias : ast.AstDeclPathList
      (compiler-load-alias-path-list
        (clone importer-path)
        importer-path-id
        importer-decl-owner-id
        alias
        rest)]
    (if (compiler-load-decl-list-has-module? imported-decls)
      (ast.ast-decl-path-list-prepend-builder-with-owner-and-provenance-id
        importer-path
        importer-decl-owner-id
        importer-path-id
        after-alias)
      after-alias)))

(define (compiler-load-modules-after-import
  [importer-module-id : i64]
  [alias : ast.AstMaybeImportAlias]
  [imported-decls : ast.AstDeclList]
  [rest : ast.AstDeclModuleList]) : ast.AstDeclModuleList
  (let
    [after-alias : ast.AstDeclModuleList
      (compiler-load-alias-module-list importer-module-id alias rest)]
    (if (compiler-load-decl-list-has-module? imported-decls)
      (ast.ast-decl-module-list-prepend-builder-id
        importer-module-id
        after-alias)
      after-alias)))

(define (compiler-load-decls-with-module-and-roots-cfg-root-with-pools
  [traversal : CompilerLoadTraversalContext]
  [decls : ast.AstDeclList]
  [importer-path : String]
  [importer-module : String]
  [importer-module-id : i64]
  [importer-source-module : String]
  [importer-source-module-id : i64]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : svec.Vec]
  [import-root : String]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]) : ResultCompilerLoadWithPaths
  (match (ast.ast-decl-list-step (ast.ast-place-shared-view decls))
    [(ast.AstDeclListStep.Nil)
      (ResultCompilerLoadWithPaths.Ok
        (ast.ast-decl-list-new)
        (ast.ast-decl-path-list-new)
        (ast.ast-decl-module-list-new)
        seen)]
    [(ast.AstDeclListStep.Cons decl rest)
      (let
        [rest : ast.AstDeclList rest]
        (match (clone decl)
          [(ast.AstDecl.ModuleBody target-module-id body-box)
            (let
              [target-module : String (ci.intern-str target-module-id)]
              [body : ast.AstDeclList
                (ast.ast-decl-list-box-shared-view body-box)]
              (if (or
                (compiler-load-decl-list-has-module-id?
                  (ast.ast-place-shared-view body)
                  target-module-id)
                (compiler-load-decl-list-has-module-id?
                  (ast.ast-place-shared-view rest)
                  target-module-id))
                (ResultCompilerLoadWithPaths.Err
                  (box
                    (cdiag.compiler-diagnostic-at-start
                      (clone importer-path)
                      "compiler-load: duplicate module declaration")))
                (match (compiler-load-decls-with-module-and-roots-cfg-root-with-pools
                  (CompilerLoadTraversalContext
                    (compiler-load-session-state-shared-view
                      (& traversal.load-state))
                    traversal.importer-path-id
                    target-module-id)
                  body
                  (clone importer-path)
                  (clone target-module)
                  target-module-id
                  target-module
                  target-module-id
                  seen
                  (ast.ast-place-shared-view stdlib-roots)
                  (clone import-root)
                  (sym_i64_env.sym-i64-shared-view (& cfgs))
                  (ast.ast-place-shared-view pools))
                  [(ResultCompilerLoadWithPaths.Ok
                      body-decls
                      body-paths
                      body-modules
                      body-seen)
                    (match (compiler-load-decls-with-module-and-roots-cfg-root-with-pools
                      (ast.ast-place-shared-view traversal)
                      rest
                      (clone importer-path)
                      importer-module
                      importer-module-id
                      importer-source-module
                      importer-source-module-id
                      body-seen
                      stdlib-roots
                      import-root
                      cfgs
                      pools)
                      [(ResultCompilerLoadWithPaths.Ok
                          rest-decls
                          rest-paths
                          rest-modules
                          rest-seen)
                        (ResultCompilerLoadWithPaths.Ok
                          (compiler-load-decl-list-prepend
                            (ast.ast-decl-module-id target-module-id)
                            (compiler-load-decl-list-append-onto
                              body-decls
                              (compiler-load-decl-list-prepend
                                (ast.ast-decl-module-id
                                  importer-source-module-id)
                                rest-decls)))
                          (ast.ast-decl-path-list-prepend-builder-with-owner-and-provenance-id
                            (clone importer-path)
                            target-module-id
                            traversal.importer-path-id
                            (compiler-load-decl-path-list-append-onto
                              body-paths
                              (ast.ast-decl-path-list-prepend-builder-with-owner-and-provenance-id
                                importer-path
                                traversal.importer-decl-owner-id
                                traversal.importer-path-id
                                rest-paths)))
                          (ast.ast-decl-module-list-prepend-builder-id
                            target-module-id
                            (compiler-load-decl-module-list-append-onto
                              body-modules
                              (ast.ast-decl-module-list-prepend-builder-id
                                importer-source-module-id
                                rest-modules)))
                          rest-seen)]
                      [(ResultCompilerLoadWithPaths.Err diag)
                        (ResultCompilerLoadWithPaths.Err diag)])]
                  [(ResultCompilerLoadWithPaths.Err diag)
                    (ResultCompilerLoadWithPaths.Err diag)])))]
          [(ast.AstDecl.Import
              decl-meta
              (ast.AstImportSpec.Spec
                kind
                import-path
                expected-module
                alias
                span))
            (if (compiler-load-macro-import-kind? kind)
              (match (compiler-load-decls-with-module-and-roots-cfg-root-with-pools
                (ast.ast-place-shared-view traversal)
                rest
                (clone importer-path)
                importer-module
                importer-module-id
                importer-source-module
                importer-source-module-id
                seen
                stdlib-roots
                import-root
                cfgs
                pools)
                [(ResultCompilerLoadWithPaths.Ok
                    rest-decls
                    rest-paths
                    rest-modules
                    rest-seen)
                  (ResultCompilerLoadWithPaths.Ok
                    (compiler-load-decl-list-prepend-from-source
                      decl
                      decls
                      rest-decls)
                    (ast.ast-decl-path-list-prepend-builder-with-owner-and-provenance-id
                      (clone importer-path)
                      traversal.importer-decl-owner-id
                      traversal.importer-path-id
                      rest-paths)
                    (ast.ast-decl-module-list-prepend-builder-id
                      importer-source-module-id
                      rest-modules)
                    rest-seen)]
                [(ResultCompilerLoadWithPaths.Err diag)
                  (ResultCompilerLoadWithPaths.Err diag)])
              (match (compiler-load-resolve-import-spec-with-roots-classified
                (owned_view.compiler-owned-shared-view importer-path)
                (owned_view.compiler-owned-shared-view import-root)
                (owned_view.compiler-owned-shared-view kind)
                (owned_view.compiler-owned-shared-view import-path)
                (owned_view.compiler-owned-shared-view expected-module)
                (owned_view.compiler-owned-shared-view alias)
                (owned_view.compiler-owned-shared-view stdlib-roots))
                [(ResultCompilerLoadResolvedImport.Ok import)
                  (let
                    [resolved : String import.resolved]
                    [kind : ast.AstImportKind import.kind]
                    [import-path : String import.module-name]
                    [expected-module : ast.AstMaybeModuleName
                      import.expected-module]
                    [alias : ast.AstMaybeImportAlias import.alias]
                    [resolved-id : i64
                      (compiler-load-source-path-id
                        (owned_view.compiler-owned-shared-view resolved))]
                    [preload-candidate : bool
                      (compiler-load-session-state-lazy-import-preload-candidate?
                        (compiler-load-session-state-shared-view
                          (& traversal.load-state))
                        (clone importer-path)
                        (clone kind)
                        (clone alias))]
                    [preload-demand : CompilerLoadLazyAliasDemand
                      (compiler-load-session-state-lazy-import-preload-demand
                        (compiler-load-session-state-shared-view
                          (& traversal.load-state))
                        preload-candidate
                        (clone alias)
                        (ast.ast-place-shared-view rest)
                        (ast.ast-place-shared-view pools))]
                    [preload-summary-needed : bool
                      (and
                        preload-candidate
                        (not
                          (or preload-demand.qualified preload-demand.unknown)))]
                    [_preload-summary : unit
                      (if preload-summary-needed
                        (compiler-load-lazy-import-preload-summary-with-state-and-pools
                          (compiler-load-session-state-shared-view
                            (& traversal.load-state))
                          (clone resolved)
                          resolved-id
                          (ast.ast-place-shared-view stdlib-roots)
                          (clone expected-module)
                          (clone import-root)
                          (sym_i64_env.sym-i64-shared-view (& cfgs))
                          (ast.ast-place-shared-view pools))
                        unit)]
                    [preload-skip : bool
                      (if preload-summary-needed
                        (compiler-load-lazy-import-skip-with-state?
                          (compiler-load-session-state-shared-view
                            (& traversal.load-state))
                          (clone importer-path)
                          (clone kind)
                          (clone resolved)
                          resolved-id
                          (clone expected-module)
                          (clone alias)
                          (ast.ast-place-shared-view rest)
                          (ast.ast-place-shared-view pools)
                          (clone preload-demand)
                          (ast.ast-place-shared-view stdlib-roots))
                        false)]
                    (match (if preload-skip
                      (ResultCompilerLoadWithPaths.Ok
                        (ast.ast-decl-list-new)
                        (ast.ast-decl-path-list-new)
                        (ast.ast-decl-module-list-new)
                        (sym_i64_env.sym-i64-shared-view (& seen)))
                      (compiler-load-file-with-paths-and-roots-expect-cfg-root-import-with-state-and-pools
                        (compiler-load-session-state-shared-view
                          (& traversal.load-state))
                        (clone resolved)
                        resolved-id
                        (sym_i64_env.sym-i64-shared-view (& seen))
                        (ast.ast-place-shared-view stdlib-roots)
                        (clone kind)
                        (clone import-path)
                        (clone expected-module)
                        (clone import-root)
                        (sym_i64_env.sym-i64-shared-view (& cfgs))
                        (ast.ast-place-shared-view pools)
                        (clone importer-source-module)
                        importer-source-module-id))
                      [(ResultCompilerLoadWithPaths.Ok
                          imported-decls
                          imported-paths
                          imported-modules
                          import-seen)
                        (let
                          [lazy-skip : bool preload-skip]
                          [after-import-seen : sym_i64_env.SymI64Env
                            (if lazy-skip
                              seen
                              import-seen)]
                          [validated-module : ast.AstMaybeModuleName
                            (compiler-load-after-import-expected-module
                              (compiler-load-session-state-shared-view
                                (& traversal.load-state))
                              resolved-id
                              (owned_view.compiler-owned-shared-view kind)
                              (owned_view.compiler-owned-shared-view
                                expected-module)
                              (owned_view.compiler-owned-shared-view alias)
                              (ast.ast-place-shared-view imported-decls))]
                          (begin
                            (when
                              (not
                                (or
                                  (compiler-load-expected-module-seen?
                                    (sym_i64_env.sym-i64-shared-view (& seen))
                                    (owned_view.compiler-owned-shared-view
                                      validated-module))
                                  (compiler-load-selected-item-present?
                                    (owned_view.compiler-owned-shared-view kind)
                                    (owned_view.compiler-owned-shared-view
                                      validated-module)
                                    (ast.ast-place-shared-view imported-decls))))
                              (return
                                (ResultCompilerLoadWithPaths.Err
                                  (box
                                    (cdiag.compiler-diagnostic-from-ast-span
                                      (owned_view.compiler-owned-shared-view
                                        importer-path)
                                      (__tl-box-place span)
                                      (compiler-load-missing-selected-item-message
                                        (owned_view.compiler-owned-shared-view
                                          import-path)
                                        (owned_view.compiler-owned-shared-view
                                          kind)))))))
                            (match (compiler-load-decls-with-module-and-roots-cfg-root-with-pools
                              (ast.ast-place-shared-view traversal)
                              rest
                              (owned_view.compiler-owned-shared-view
                                importer-path)
                              importer-module
                              importer-module-id
                              (owned_view.compiler-owned-shared-view
                                importer-source-module)
                              importer-source-module-id
                              after-import-seen
                              stdlib-roots
                              import-root
                              cfgs
                              pools)
                              [(ResultCompilerLoadWithPaths.Ok
                                  rest-decls
                                  rest-paths
                                  rest-modules
                                  rest-seen)
                                (let
                                  [after-import-expected : ast.AstMaybeModuleName
                                    validated-module]
                                  [after-import-alias : ast.AstMaybeImportAlias
                                    (compiler-load-after-import-alias
                                      (compiler-load-session-state-shared-view
                                        (& traversal.load-state))
                                      resolved-id
                                      (owned_view.compiler-owned-shared-view
                                        kind)
                                      (owned_view.compiler-owned-shared-view
                                        expected-module)
                                      (owned_view.compiler-owned-shared-view
                                        alias)
                                      (ast.ast-place-shared-view imported-decls))]
                                  (if lazy-skip
                                    (begin
                                      (compiler-load-session-state-lazy-import-record-skip!
                                        traversal.load-state)
                                      (ResultCompilerLoadWithPaths.Ok
                                        (compiler-load-decls-after-import
                                          kind
                                          resolved
                                          after-import-expected
                                          (owned_view.compiler-owned-shared-view
                                            after-import-alias)
                                          (__tl-box-place span)
                                          importer-source-module
                                          importer-source-module-id
                                          decls
                                          (ast.ast-decl-list-new)
                                          rest-decls)
                                        (compiler-load-paths-after-import
                                          importer-path
                                          traversal.importer-path-id
                                          traversal.importer-decl-owner-id
                                          after-import-alias
                                          (ast.ast-decl-list-new)
                                          rest-paths)
                                        (compiler-load-modules-after-import
                                          importer-source-module-id
                                          after-import-alias
                                          (ast.ast-decl-list-new)
                                          rest-modules)
                                        rest-seen))
                                    (let
                                      [after-decls : ast.AstDeclList
                                        (compiler-load-decls-after-import
                                          kind
                                          resolved
                                          after-import-expected
                                          (owned_view.compiler-owned-shared-view
                                            after-import-alias)
                                          (__tl-box-place span)
                                          importer-source-module
                                          importer-source-module-id
                                          (ast.ast-place-shared-view decls)
                                          (ast.ast-place-shared-view
                                            imported-decls)
                                          rest-decls)]
                                      [after-paths : ast.AstDeclPathList
                                        (compiler-load-paths-after-import
                                          importer-path
                                          traversal.importer-path-id
                                          traversal.importer-decl-owner-id
                                          (owned_view.compiler-owned-shared-view
                                            after-import-alias)
                                          (ast.ast-place-shared-view
                                            imported-decls)
                                          rest-paths)]
                                      [after-modules : ast.AstDeclModuleList
                                        (compiler-load-modules-after-import
                                          importer-source-module-id
                                          after-import-alias
                                          (ast.ast-place-shared-view
                                            imported-decls)
                                          rest-modules)]
                                      (ResultCompilerLoadWithPaths.Ok
                                        (compiler-load-decl-list-append-onto
                                          imported-decls
                                          after-decls)
                                        (compiler-load-decl-path-list-append-onto
                                          imported-paths
                                          after-paths)
                                        (compiler-load-decl-module-list-append-onto
                                          imported-modules
                                          after-modules)
                                        rest-seen))))]
                              [(ResultCompilerLoadWithPaths.Err diag)
                                (ResultCompilerLoadWithPaths.Err diag)])))]
                      [(ResultCompilerLoadWithPaths.Err diag)
                        (ResultCompilerLoadWithPaths.Err diag)]))]
                [(ResultCompilerLoadResolvedImport.Err message)
                  (ResultCompilerLoadWithPaths.Err
                    (box
                      (cdiag.compiler-diagnostic-from-ast-span
                        importer-path
                        (__tl-box-place span)
                        message)))]))]
          [(ast.AstDecl.IncludeStr name include-path)
            (match (compiler-load-expand-include-str-with-pools
              (clone importer-path)
              include-path
              name
              (ast.ast-place-shared-view stdlib-roots)
              (ast.ast-place-shared-view pools))
              [(ResultCompilerLoadInclude.Ok expanded)
                (match (compiler-load-decls-with-module-and-roots-cfg-root-with-pools
                  (ast.ast-place-shared-view traversal)
                  rest
                  (clone importer-path)
                  importer-module
                  importer-module-id
                  (clone importer-source-module)
                  importer-source-module-id
                  (sym_i64_env.sym-i64-shared-view (& seen))
                  (ast.ast-place-shared-view stdlib-roots)
                  (clone import-root)
                  (sym_i64_env.sym-i64-shared-view (& cfgs))
                  (ast.ast-place-shared-view pools))
                  [(ResultCompilerLoadWithPaths.Ok
                      rest-decls
                      rest-paths
                      rest-modules
                      rest-seen)
                    (ResultCompilerLoadWithPaths.Ok
                      (compiler-load-decl-list-prepend-from-source
                        expanded
                        (ast.ast-place-shared-view decls)
                        rest-decls)
                      (ast.ast-decl-path-list-prepend-builder-with-owner-and-provenance-id
                        (clone importer-path)
                        traversal.importer-decl-owner-id
                        traversal.importer-path-id
                        rest-paths)
                      (ast.ast-decl-module-list-prepend-builder-id
                        importer-source-module-id
                        rest-modules)
                      rest-seen)]
                  [(ResultCompilerLoadWithPaths.Err diag)
                    (ResultCompilerLoadWithPaths.Err diag)])]
              [(ResultCompilerLoadInclude.Err diag)
                (ResultCompilerLoadWithPaths.Err diag)])]
          [(ast.AstDecl.IncludeStrComptime name include-path)
            (match (compiler-load-expand-include-str-comptime-with-pools
              (clone importer-path)
              include-path
              name
              (ast.ast-place-shared-view stdlib-roots)
              (ast.ast-place-shared-view pools))
              [(ResultCompilerLoadInclude.Ok expanded)
                (match (compiler-load-decls-with-module-and-roots-cfg-root-with-pools
                  (ast.ast-place-shared-view traversal)
                  rest
                  (clone importer-path)
                  importer-module
                  importer-module-id
                  (clone importer-source-module)
                  importer-source-module-id
                  (sym_i64_env.sym-i64-shared-view (& seen))
                  (ast.ast-place-shared-view stdlib-roots)
                  (clone import-root)
                  (sym_i64_env.sym-i64-shared-view (& cfgs))
                  (ast.ast-place-shared-view pools))
                  [(ResultCompilerLoadWithPaths.Ok
                      rest-decls
                      rest-paths
                      rest-modules
                      rest-seen)
                    (ResultCompilerLoadWithPaths.Ok
                      (compiler-load-decl-list-prepend-from-source
                        expanded
                        decls
                        rest-decls)
                      (ast.ast-decl-path-list-prepend-builder-with-owner-and-provenance-id
                        (clone importer-path)
                        traversal.importer-decl-owner-id
                        traversal.importer-path-id
                        rest-paths)
                      (ast.ast-decl-module-list-prepend-builder-id
                        importer-source-module-id
                        rest-modules)
                      rest-seen)]
                  [(ResultCompilerLoadWithPaths.Err diag)
                    (ResultCompilerLoadWithPaths.Err diag)])]
              [(ResultCompilerLoadInclude.Err diag)
                (ResultCompilerLoadWithPaths.Err diag)])]
          [(ast.AstDecl.IncludeStrLzss name include-path)
            (match (compiler-load-expand-include-str-lzss-with-pools
              (clone importer-path)
              include-path
              name
              (ast.ast-place-shared-view stdlib-roots)
              (ast.ast-place-shared-view pools))
              [(ResultCompilerLoadInclude.Ok expanded)
                (match (compiler-load-decls-with-module-and-roots-cfg-root-with-pools
                  (ast.ast-place-shared-view traversal)
                  rest
                  (clone importer-path)
                  importer-module
                  importer-module-id
                  (clone importer-source-module)
                  importer-source-module-id
                  (sym_i64_env.sym-i64-shared-view (& seen))
                  (ast.ast-place-shared-view stdlib-roots)
                  (clone import-root)
                  (sym_i64_env.sym-i64-shared-view (& cfgs))
                  (ast.ast-place-shared-view pools))
                  [(ResultCompilerLoadWithPaths.Ok
                      rest-decls
                      rest-paths
                      rest-modules
                      rest-seen)
                    (ResultCompilerLoadWithPaths.Ok
                      (ast.ast-decl-list-prepend-builder expanded rest-decls)
                      (ast.ast-decl-path-list-prepend-builder-with-owner-and-provenance-id
                        (clone importer-path)
                        traversal.importer-decl-owner-id
                        traversal.importer-path-id
                        rest-paths)
                      (ast.ast-decl-module-list-prepend-builder-id
                        importer-source-module-id
                        rest-modules)
                      rest-seen)]
                  [(ResultCompilerLoadWithPaths.Err diag)
                    (ResultCompilerLoadWithPaths.Err diag)])]
              [(ResultCompilerLoadInclude.Err diag)
                (ResultCompilerLoadWithPaths.Err diag)])]
          [(ast.AstDecl.IncludeBin name include-path)
            (match (compiler-load-expand-include-bin-with-pools
              (clone importer-path)
              include-path
              name
              (ast.ast-place-shared-view stdlib-roots)
              (ast.ast-place-shared-view pools))
              [(ResultCompilerLoadInclude.Ok expanded)
                (match (compiler-load-decls-with-module-and-roots-cfg-root-with-pools
                  (ast.ast-place-shared-view traversal)
                  rest
                  (clone importer-path)
                  importer-module
                  importer-module-id
                  (clone importer-source-module)
                  importer-source-module-id
                  (sym_i64_env.sym-i64-shared-view (& seen))
                  (ast.ast-place-shared-view stdlib-roots)
                  (clone import-root)
                  (sym_i64_env.sym-i64-shared-view (& cfgs))
                  (ast.ast-place-shared-view pools))
                  [(ResultCompilerLoadWithPaths.Ok
                      rest-decls
                      rest-paths
                      rest-modules
                      rest-seen)
                    (ResultCompilerLoadWithPaths.Ok
                      (compiler-load-decl-list-prepend-from-source
                        expanded
                        decls
                        rest-decls)
                      (ast.ast-decl-path-list-prepend-builder-with-owner-and-provenance-id
                        (clone importer-path)
                        traversal.importer-decl-owner-id
                        traversal.importer-path-id
                        rest-paths)
                      (ast.ast-decl-module-list-prepend-builder-id
                        importer-source-module-id
                        rest-modules)
                      rest-seen)]
                  [(ResultCompilerLoadWithPaths.Err diag)
                    (ResultCompilerLoadWithPaths.Err diag)])]
              [(ResultCompilerLoadInclude.Err diag)
                (ResultCompilerLoadWithPaths.Err diag)])]
          [_
            (match (compiler-load-decls-with-module-and-roots-cfg-root-with-pools
              (ast.ast-place-shared-view traversal)
              rest
              (clone importer-path)
              importer-module
              importer-module-id
              (clone importer-source-module)
              importer-source-module-id
              (sym_i64_env.sym-i64-shared-view (& seen))
              (ast.ast-place-shared-view stdlib-roots)
              (clone import-root)
              (sym_i64_env.sym-i64-shared-view (& cfgs))
              (ast.ast-place-shared-view pools))
              [(ResultCompilerLoadWithPaths.Ok
                  rest-decls
                  rest-paths
                  rest-modules
                  rest-seen)
                (ResultCompilerLoadWithPaths.Ok
                  (compiler-load-decl-list-prepend-from-source
                    decl
                    (ast.ast-place-shared-view decls)
                    rest-decls)
                  (ast.ast-decl-path-list-prepend-builder-with-owner-and-provenance-id
                    (clone importer-path)
                    traversal.importer-decl-owner-id
                    traversal.importer-path-id
                    rest-paths)
                  (ast.ast-decl-module-list-prepend-builder-id
                    importer-source-module-id
                    rest-modules)
                  rest-seen)]
              [(ResultCompilerLoadWithPaths.Err diag)
                (ResultCompilerLoadWithPaths.Err diag)])]))]))

(define (compiler-load-decls-with-module-and-roots-cfg-root
  [decls : ast.AstDeclList]
  [importer-path : String]
  [importer-path-id : i64]
  [importer-decl-owner-id : i64]
  [importer-module : String]
  [importer-module-id : i64]
  [importer-source-module : String]
  [importer-source-module-id : i64]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : svec.Vec]
  [import-root : String]
  [cfgs : sym_i64_env.SymI64Env]) : ResultCompilerLoadWithPaths
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [result : ResultCompilerLoadWithPaths
      (compiler-load-decls-with-module-and-roots-cfg-root-with-pools
        (CompilerLoadTraversalContext
          (compiler-load-active-session-state-shared-view)
          importer-path-id
          importer-decl-owner-id)
        decls
        importer-path
        importer-module
        importer-module-id
        importer-source-module
        importer-source-module-id
        seen
        stdlib-roots
        import-root
        cfgs
        (ast.ast-place-shared-view pools))]
    (begin
      (ast.ast-node-pool-context-install! pools)
      result)))

(define (compiler-load-program-with-paths-and-roots-expect-cfg
  [path : String]
  [program : ast.AstProgram]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : svec.Vec]
  [expected-module : ast.AstMaybeModuleName]
  [cfgs : sym_i64_env.SymI64Env]
  [parse-identity : CompilerLoadParseIdentity]) : ResultCompilerLoadWithPaths
  (compiler-load-program-with-paths-and-roots-expect-cfg-root
    (clone path)
    program
    seen
    stdlib-roots
    expected-module
    (compiler-load-dirname path)
    cfgs
    parse-identity))

(define (compiler-load-program-with-paths-and-roots-expect-cfg-with-pools
  [load-state : CompilerLoadSessionState]
  [path : String]
  [program : ast.AstProgram]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : svec.Vec]
  [expected-module : ast.AstMaybeModuleName]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [parse-identity : CompilerLoadParseIdentity]) : ResultCompilerLoadWithPaths
  (compiler-load-program-with-paths-and-roots-expect-cfg-root-with-pools
    load-state
    (clone path)
    program
    seen
    stdlib-roots
    expected-module
    (compiler-load-dirname path)
    cfgs
    pools
    parse-identity))

(define (compiler-load-program-with-paths-and-roots-expect-cfg-root-with-pools
  [load-state : CompilerLoadSessionState]
  [path : String]
  [program : ast.AstProgram]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : svec.Vec]
  [expected-module : ast.AstMaybeModuleName]
  [import-root : String]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [parse-identity : CompilerLoadParseIdentity]) : ResultCompilerLoadWithPaths
  (compiler-load-program-with-paths-and-roots-expect-cfg-root-fallback-with-pools
    load-state
    (clone path)
    program
    seen
    stdlib-roots
    expected-module
    import-root
    cfgs
    pools
    (compiler-load-canonical-module-id-from-path path)
    parse-identity
    ""
    cbi.compiler-builtin-id-fix-empty))

(define (compiler-load-program-with-paths-and-roots-expect-cfg-root-fallback-with-pools
  [load-state : CompilerLoadSessionState]
  [path : String]
  [program : ast.AstProgram]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : svec.Vec]
  [expected-module : ast.AstMaybeModuleName]
  [import-root : String]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [module-id-fallback : String]
  [parse-identity : CompilerLoadParseIdentity]
  [source-module-fallback : String]
  [source-module-fallback-id : i64]) : ResultCompilerLoadWithPaths
  (let
    [entry-depth : i64 (array-ref load-state.surface-summary-load-depth 0)]
    [_ : unit
      (compiler-load-session-state-surface-summary-load-enter!
        (compiler-load-session-state-shared-view (& load-state)))]
    [source-path-id : i64 parse-identity.source-path-id]
    [module-id-fallback-id : i64 parse-identity.module-fallback-id]
    [source-path : String (ci.intern-str source-path-id)]
    [loaded : ResultCompilerLoadWithPaths
      (match program
        [(ast.AstProgram.Program decls-box)
          (let
            [decls : ast.AstDeclList
              (ast.ast-decl-list-box-shared-view decls-box)]
            [effective-source-module-fallback : String
              (if (> (string.string-length source-module-fallback) 0)
                source-module-fallback
                (if (compiler-load-stdlib-source-module-import?
                  (compiler-load-normalize-path path))
                  module-id-fallback
                  ""))]
            [source-module : String
              (compiler-load-decls-source-module-or
                (ast.ast-place-shared-view decls)
                (clone effective-source-module-fallback))]
            [source-module-id : i64
              (if (compiler-load-decl-list-has-module?
                (ast.ast-place-shared-view decls))
                (compiler-load-decls-source-module-id
                  (ast.ast-place-shared-view decls))
                (if (>
                  (string.string-length effective-source-module-fallback)
                  0)
                  (if (> (string.string-length source-module-fallback) 0)
                    source-module-fallback-id
                    module-id-fallback-id)
                  cbi.compiler-builtin-id-fix-empty))]
            [load-decls : ast.AstDeclList
              (compiler-load-contextual-moduleless-decls
                (ast.ast-place-shared-view decls)
                (clone source-module)
                source-module-id)]
            (match (compiler-load-decls-module-id-with-fallback
              (clone source-path)
              (ast.ast-place-shared-view decls)
              (clone module-id-fallback)
              module-id-fallback-id)
              [(ResultCompilerLoadModuleId.Ok module-id module-name-id)
                (match (compiler-load-check-expected-module
                  (clone source-path)
                  (clone expected-module)
                  (clone module-id)
                  module-name-id)
                  [(ResultCompilerLoadModuleId.Ok _ _)
                    (if (compiler-load-seen-module-contains?
                      (sym_i64_env.sym-i64-shared-view (& seen))
                      (clone module-id)
                      module-name-id)
                      (compiler-load-seen-module-with-paths
                        (clone source-path)
                        source-path-id
                        (clone module-id)
                        module-name-id
                        (ast.ast-place-shared-view load-decls)
                        (sym_i64_env.sym-i64-shared-view (& seen)))
                      (match (compiler-load-check-dotted-import-aliases
                        (clone source-path)
                        (ast.ast-place-shared-view load-decls)
                        (clone source-module))
                        [(ResultCompilerLoadAliasCheck.Ok)
                          (begin
                            ;; Replace a speculative lazy summary with the
                            ;; identity established by the actual load.
                            (compiler-load-session-state-surface-summary-remove-source!
                              (compiler-load-session-state-shared-view
                                (& load-state))
                              source-path-id)
                            (compiler-load-session-state-record-surface-summary!
                              load-state
                              (compiler-load-surface-summary-from-decls
                                (clone source-path)
                                source-path-id
                                (clone import-root)
                                module-name-id
                                source-module-id
                                (compiler-load-decl-list-has-module?
                                  (ast.ast-place-shared-view decls))
                                (not
                                  (compiler-load-no-expected-module?
                                    (clone expected-module)))
                                (ast.ast-place-shared-view load-decls)))
                            (compiler-load-decls-with-module-and-roots-cfg-root-with-pools
                              (CompilerLoadTraversalContext
                                (compiler-load-session-state-shared-view
                                  (& load-state))
                                source-path-id
                                parse-identity.decl-owner-id)
                              (ast.ast-place-shared-view load-decls)
                              (clone source-path)
                              (clone module-id)
                              module-name-id
                              (clone source-module)
                              source-module-id
                              (compiler-load-seen-module-bind
                                seen
                                module-id
                                module-name-id)
                              stdlib-roots
                              import-root
                              cfgs
                              pools))]
                        [(ResultCompilerLoadAliasCheck.Err diag)
                          (ResultCompilerLoadWithPaths.Err diag)]))]
                  [(ResultCompilerLoadModuleId.Err diag)
                    (ResultCompilerLoadWithPaths.Err diag)])]
              [(ResultCompilerLoadModuleId.Err diag)
                (ResultCompilerLoadWithPaths.Err diag)]))])]
    (begin
      (compiler-load-session-state-surface-summary-load-exit! load-state)
      (if (= entry-depth 0)
        (match loaded
          [(ResultCompilerLoadWithPaths.Ok decls paths modules loaded-seen)
            (match (compiler-load-check-unqualified-import-collisions
              (owned_view.compiler-owned-shared-view source-path)
              (ast.ast-place-shared-view decls)
              (ast.ast-place-shared-view paths))
              [(ResultCompilerLoadAliasCheck.Ok)
                (ResultCompilerLoadWithPaths.Ok decls paths modules loaded-seen)]
              [(ResultCompilerLoadAliasCheck.Err diag)
                (ResultCompilerLoadWithPaths.Err diag)])]
          [(ResultCompilerLoadWithPaths.Err diag)
            (ResultCompilerLoadWithPaths.Err diag)])
        loaded))))

(define (compiler-load-program-with-paths-and-roots-expect-cfg-root
  [path : String]
  [program : ast.AstProgram]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : svec.Vec]
  [expected-module : ast.AstMaybeModuleName]
  [import-root : String]
  [cfgs : sym_i64_env.SymI64Env]
  [parse-identity : CompilerLoadParseIdentity]) : ResultCompilerLoadWithPaths
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [result : ResultCompilerLoadWithPaths
      (compiler-load-program-with-paths-and-roots-expect-cfg-root-with-pools
        (compiler-load-active-session-state-shared-view)
        (clone path)
        program
        seen
        stdlib-roots
        expected-module
        import-root
        cfgs
        (ast.ast-place-shared-view pools)
        parse-identity)]
    (begin
      (ast.ast-node-pool-context-install! pools)
      result)))

(define (compiler-load-source-with-paths
  [path : String]
  [source : String]
  [seen : sym_i64_env.SymI64Env]) : ResultCompilerLoadWithPaths
  (compiler-load-source-with-paths-and-roots path source seen (svec.new)))

(define (compiler-load-source-with-paths-and-roots
  [path : String]
  [source : String]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : svec.Vec]) : ResultCompilerLoadWithPaths
  (compiler-load-source-with-paths-and-roots-expect
    (clone path)
    source
    seen
    stdlib-roots
    ast.AstMaybeModuleName.No))

(define (compiler-load-source-with-paths-and-roots-cfg
  [path : String]
  [source : String]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]) : ResultCompilerLoadWithPaths
  (compiler-load-source-with-paths-and-roots-expect-cfg
    path
    source
    seen
    stdlib-roots
    ast.AstMaybeModuleName.No
    cfgs))

(define (compiler-load-source-with-paths-and-roots-expect
  [path : String]
  [source : String]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : svec.Vec]
  [expected-module : ast.AstMaybeModuleName]) : ResultCompilerLoadWithPaths
  (compiler-load-source-with-paths-and-roots-expect-cfg
    path
    source
    seen
    stdlib-roots
    expected-module
    (parser.compiler-cfg-empty)))

;; Parse a module source directly in the active (program-lifetime) arena.
;;
;; A scratch-arena variant used to parse large files into a throwaway arena and
;; `clone` the result back out to cap cold self-build peak memory. That cannot
;; work with the flat-node AST: `AstExpr`/`AstType`/`SpannedSexpr` nodes live in
;; persistent GLOBAL pools, not the active arena, so destroying the scratch arena
;; left the cloned program pointing at pool slots whose backing list/string data
;; had been freed -- a segfault on the next self-build. The scratch path was
;; already disabled (its size threshold was raised past any real input); it has
;; now been removed. Recovering its memory benefit needs pool-aware reclamation
;; (e.g. truncating the node pools after escaping), not arena destruction.
(define (compiler-load-parse-source-diagnostic-escaping
  [path : String]
  [source : String]
  [cfgs : sym_i64_env.SymI64Env]) : parser.ResultAstProgramDiagnostic
  (parser.parse-ast-source-diagnostic-with-cfg path source cfgs))

(define (compiler-load-parse-source-diagnostic-escaping-with-pools
  [path : String]
  [source : String]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]) : parser.ResultAstProgramDiagnostic
  (parser.parse-ast-source-diagnostic-with-cfg-and-pools path source cfgs pools))

(define (compiler-load-parse-file-diagnostic-escaping
  [path : String]
  [cfgs : sym_i64_env.SymI64Env]) : parser.ResultAstProgramDiagnostic
  (let
    [source : String (compiler-load-read-file-text (clone path))]
    (compiler-load-parse-source-diagnostic-escaping path source cfgs)))

(define (compiler-load-parse-file-diagnostic-escaping-with-pools
  [path : String]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]) : parser.ResultAstProgramDiagnostic
  (let
    [source : String (compiler-load-read-file-text (clone path))]
    (compiler-load-parse-source-diagnostic-escaping-with-pools
      path
      source
      cfgs
      pools)))

;; Parse one uncached file in disposable storage, then copy only its reachable
;; AST into the caller's program-lifetime pools. Lexer tokens, reader forms,
;; source text, parser scratch, and superseded temporary pool arrays are all
;; released before import traversal continues to the next file.
(define (compiler-load-propagate-compacted-decl-origins!
  [source : ast.AstDeclList]
  [dest : ast.AstDeclList]
  [records-start : i64]
  [records-end : i64]) : unit
  (begin
    (parser.compiler-parse-decl-origin-copy-direct-records!
      (ast.ast-place-shared-view source)
      (& dest)
      0
      records-start
      records-end)
    ;; Index cursors rather than two `ast-decl-list-step` walks in lockstep.
    ;; Each step copied a 104 B row and wrote a 144 B result -- twice per
    ;; declaration here -- to answer a tag question; only the `ModuleBody` arm
    ;; reads a payload, and it reads it straight out of the backing slot. The
    ;; walk still stops at the shorter of the two lists, which is what running
    ;; either cursor to `Nil` did.
    (let
      [source-count : i64 (ast.ast-decl-list-len (& source))]
      [dest-count : i64 (ast.ast-decl-list-len (& dest))]
      [count : i64
        (if (< source-count dest-count)
          source-count
          dest-count)]
      [source-slots : (__tl_dyn-array ast.AstDecl) source.slots]
      [source-offset : i64 source.offset]
      [dest-slots : (__tl_dyn-array ast.AstDecl) dest.slots]
      [dest-offset : i64 dest.offset]
      [index : i64 0]
      (while (< index count)
        (begin
          (match (array-ref source-slots (+ source-offset index))
            [(ast.AstDecl.ModuleBody _ source-body-box)
              (match (array-ref dest-slots (+ dest-offset index))
                [(ast.AstDecl.ModuleBody _ dest-body-box)
                  (compiler-load-propagate-compacted-decl-origins!
                    (ast.ast-decl-list-box-shared-view source-body-box)
                    (ast.ast-decl-list-box-shared-view dest-body-box)
                    records-start
                    records-end)]
                [_ unit])]
            [_ unit])
          (set! index (+ index 1)))))))

(define (compiler-load-propagate-compacted-program-origins!
  [source : ast.AstProgram]
  [dest : ast.AstProgram]
  [records-start : i64]
  [records-end : i64]) : unit
  (match source
    [(ast.AstProgram.Program source-decls-box)
      (match dest
        [(ast.AstProgram.Program dest-decls-box)
          (compiler-load-propagate-compacted-decl-origins!
            (ast.ast-decl-list-box-shared-view source-decls-box)
            (ast.ast-decl-list-box-shared-view dest-decls-box)
            records-start
            records-end)])]))

(define (compiler-load-parse-file-diagnostic-detached-with-pools
  [path : String]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]) : parser.ResultAstProgramDiagnostic
  (let
    [caller-arena : i64 (arena.tl_arena_current)]
    [scratch-root : i64 (arena.tl_arena_make)]
    [_use-scratch : unit
      (unsafe
        (arena.tl_arena_set scratch-root))]
    [source : String (compiler-load-read-file-text path)]
    [source-len : i64 (string.string-length source)]
    ;; Source bytes are a useful low-cost predictor for parser node count. A
    ;; modest estimate avoids both a multi-million-node reserve per file and a
    ;; long geometric growth chain for compiler-sized modules.
    [expr-capacity : i64
      (let
        [estimate : i64 (/ source-len 8)]
        (if (< estimate 1024)
          1024
          estimate))]
    [type-capacity : i64
      (let
        [estimate : i64 (/ source-len 128)]
        (if (< estimate 256)
          256
          estimate))]
    [scratch-pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities-in-arena
        expr-capacity
        type-capacity
        scratch-root)]
    [records-start : i64 (reader.sp-node-pool-len)]
    [parsed : parser.ResultAstProgramDiagnostic
      (compiler-load-parse-source-diagnostic-escaping-with-pools
        path
        source
        cfgs
        (ast.ast-place-shared-view scratch-pools))]
    (match parsed
      [(parser.ResultAstProgramDiagnostic.Ok program)
        (match (ast.ast-program-copy-append-with-pools
          (ast.ast-place-shared-view scratch-pools)
          pools
          (ast.ast-place-shared-view program))
          [(ast.AstProgramCompaction out-program _)
            (let
              [records-end : i64 (reader.sp-node-pool-len)]
              [_origins : unit
                (compiler-load-propagate-compacted-program-origins!
                  program
                  (ast.ast-place-shared-view out-program)
                  records-start
                  records-end)]
              [_compact-origin-records : unit
                (parser.compiler-parse-member-records-compact!
                  records-start
                  records-end)]
              [_restore-caller : unit
                (unsafe
                  (arena.tl_arena_set caller-arena))]
              [out : parser.ResultAstProgramDiagnostic
                (parser.ResultAstProgramDiagnostic.Ok out-program)]
              (begin
                (ast.ast-node-pool-context-destroy-storage! scratch-pools)
                (unsafe
                  (arena.tl_arena_destroy scratch-root))
                out))])]
      [(parser.ResultAstProgramDiagnostic.Err diag)
        (let
          [_restore-caller : unit
            (unsafe
              (arena.tl_arena_set caller-arena))]
          [stable-diag : (Box cdiag.CompilerDiagnostic)
            (box
              (cdiag.compiler-diagnostic-copy
                (cdiag.compiler-diagnostic-box-shared-view diag)))]
          [out : parser.ResultAstProgramDiagnostic
            (parser.ResultAstProgramDiagnostic.Err stable-diag)]
          (begin
            (reader.sp-node-pool-truncate! records-start)
            (ast.ast-node-pool-context-destroy-storage! scratch-pools)
            (unsafe
              (arena.tl_arena_destroy scratch-root))
            out))])))

(define (compiler-load-cache-program-result
  [key : CompilerLoadProgramCacheKey]
  [result : parser.ResultAstProgramDiagnostic]) : parser.ResultAstProgramDiagnostic
  (match result
    [(parser.ResultAstProgramDiagnostic.Ok program)
      (begin
        (if (compiler-load-program-cache-store
          key
          (ast.ast-place-shared-view program))
          (compiler-load-session-note-persistent!)
          unit)
        (parser.ResultAstProgramDiagnostic.Ok program))]
    [(parser.ResultAstProgramDiagnostic.Err diag)
      (parser.ResultAstProgramDiagnostic.Err diag)]))

(define (compiler-load-cache-program-result-with-pools
  [load-state : CompilerLoadSessionState]
  [key : CompilerLoadProgramCacheKey]
  [result : parser.ResultAstProgramDiagnostic]
  [pools : ast.AstNodePoolContext]) : parser.ResultAstProgramDiagnostic
  (match result
    [(parser.ResultAstProgramDiagnostic.Ok program)
      (begin
        (if (compiler-load-session-state-program-cache-store
          (compiler-load-session-state-shared-view (& load-state))
          key
          (ast.ast-place-shared-view program))
          (compiler-load-session-state-note-persistent-with-pools!
            load-state
            pools)
          unit)
        (parser.ResultAstProgramDiagnostic.Ok program))]
    [(parser.ResultAstProgramDiagnostic.Err diag)
      (parser.ResultAstProgramDiagnostic.Err diag)]))

;; Carry target-arena-owned cache inputs across `in-arena`'s restoration. Cache
;; table growth and persistent-floor bookkeeping deliberately remain in the
;; caller's arena, matching the former raw switch/restore protocol exactly.
(defstruct CompilerLoadPersistentProgramResult
  (key CompilerLoadProgramCacheKey)
  (result parser.ResultAstProgramDiagnostic))

(define (compiler-load-parse-file-diagnostic-cache-miss
  [key : CompilerLoadProgramCacheKey]
  [path : String]
  [cfgs : sym_i64_env.SymI64Env]) : parser.ResultAstProgramDiagnostic
  (if (compiler-load-program-cache-can-store key)
    (let
      [persistent : CompilerLoadPersistentProgramResult
        (in-arena
          (arena.Arena ast.node-pool-base-arena)
          (CompilerLoadPersistentProgramResult
            (compiler-load-program-cache-key-copy key)
            (compiler-load-parse-file-diagnostic-escaping path cfgs)))]
      (match persistent
        [(CompilerLoadPersistentProgramResult persistent-key parsed)
          (compiler-load-cache-program-result persistent-key parsed)]))
    (compiler-load-parse-file-diagnostic-escaping path cfgs)))

(define (compiler-load-parse-file-diagnostic-cache-miss-with-pools
  [load-state : CompilerLoadSessionState]
  [key : CompilerLoadProgramCacheKey]
  [path : String]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]) : parser.ResultAstProgramDiagnostic
  (if (compiler-load-session-state-program-cache-can-store
    (compiler-load-session-state-shared-view (& load-state))
    key)
    (let
      [persistent : CompilerLoadPersistentProgramResult
        (in-arena
          (arena.Arena (ast.ast-node-pool-context-base-arena pools))
          (CompilerLoadPersistentProgramResult
            (compiler-load-program-cache-key-copy key)
            (compiler-load-parse-file-diagnostic-escaping-with-pools
              path
              cfgs
              (ast.ast-place-shared-view pools))))]
      (match persistent
        [(CompilerLoadPersistentProgramResult persistent-key parsed)
          (compiler-load-cache-program-result-with-pools
            load-state
            persistent-key
            parsed
            pools)]))
    (compiler-load-parse-file-diagnostic-escaping-with-pools path cfgs pools)))

(define (compiler-load-ast-program-result-ok?
  [result : (& result parser.ResultAstProgramDiagnostic)]) : bool
  (match result
    [(parser.ResultAstProgramDiagnostic.Ok _) true]
    [(parser.ResultAstProgramDiagnostic.Err _) false]))

(define (compiler-load-parse-file-diagnostic-cache-miss-local
  [key : CompilerLoadProgramCacheKey]
  [path : String]
  [cfgs : sym_i64_env.SymI64Env]) : parser.ResultAstProgramDiagnostic
  (if (compiler-load-program-cache-can-store key)
    (let
      [start-nodes : i64 (ast.ast-node-pool-len)]
      [cold : parser.ResultAstProgramDiagnostic
        (compiler-load-parse-file-diagnostic-escaping
          (clone path)
          (sym_i64_env.sym-i64-shared-view (& cfgs)))]
      [node-delta : i64 (- (ast.ast-node-pool-len) start-nodes)]
      (if (and
        (compiler-load-ast-program-result-ok? cold)
        (<= node-delta compiler-load-local-program-cache-node-limit))
        (compiler-load-parse-file-diagnostic-cache-miss key path cfgs)
        cold))
    (compiler-load-parse-file-diagnostic-escaping path cfgs)))

(define (compiler-load-parse-file-diagnostic-cache-miss-local-with-pools
  [load-state : CompilerLoadSessionState]
  [key : CompilerLoadProgramCacheKey]
  [path : String]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]) : parser.ResultAstProgramDiagnostic
  (if (compiler-load-session-state-program-cache-can-store
    (compiler-load-session-state-shared-view (& load-state))
    key)
    (let
      [start-nodes : i64 (ast.ast-node-pool-context-expr-len pools)]
      [cold : parser.ResultAstProgramDiagnostic
        (compiler-load-parse-file-diagnostic-escaping-with-pools
          (clone path)
          (sym_i64_env.sym-i64-shared-view (& cfgs))
          (ast.ast-place-shared-view pools))]
      [node-delta : i64
        (- (ast.ast-node-pool-context-expr-len pools) start-nodes)]
      (if (and
        (compiler-load-ast-program-result-ok? cold)
        (<= node-delta compiler-load-local-program-cache-node-limit))
        (compiler-load-parse-file-diagnostic-cache-miss-with-pools
          load-state
          key
          path
          cfgs
          pools)
        cold))
    (compiler-load-parse-file-diagnostic-escaping-with-pools path cfgs pools)))

(define (compiler-load-parse-file-diagnostic-admit-only
  [key : CompilerLoadProgramCacheKey]
  [path : String]
  [cfgs : sym_i64_env.SymI64Env]) : parser.ResultAstProgramDiagnostic
  (let
    [parsed : parser.ResultAstProgramDiagnostic
      (compiler-load-parse-file-diagnostic-escaping path cfgs)]
    (begin
      (match (ast.ast-place-shared-view parsed)
        [(parser.ResultAstProgramDiagnostic.Ok _)
          (if (compiler-load-program-admission-record-persistent key)
            unit
            unit)]
        [(parser.ResultAstProgramDiagnostic.Err _) unit])
      parsed)))

(define (compiler-load-parse-file-diagnostic-admit-only-with-pools
  [load-state : CompilerLoadSessionState]
  [key : CompilerLoadProgramCacheKey]
  [path : String]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]) : parser.ResultAstProgramDiagnostic
  (let
    [parsed : parser.ResultAstProgramDiagnostic
      (compiler-load-parse-file-diagnostic-escaping-with-pools path cfgs pools)]
    (begin
      (match (ast.ast-place-shared-view parsed)
        [(parser.ResultAstProgramDiagnostic.Ok _)
          (if (compiler-load-session-state-program-admission-record-persistent
            load-state
            key)
            unit
            unit)]
        [(parser.ResultAstProgramDiagnostic.Err _) unit])
      parsed)))

(define (compiler-load-parse-file-diagnostic-session-id
  [path : String]
  [source-path-id : i64]
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]) : parser.ResultAstProgramDiagnostic
  (if (and
    (compiler-load-session-cache-enabled?)
    (compiler-load-session-program-cache-enabled?)
    (compiler-load-session-file-cacheable?
      (clone path)
      (ast.ast-place-shared-view stdlib-roots)))
    (let
      [key : CompilerLoadProgramCacheKey
        (compiler-load-program-cache-key-id
          CompilerLoadProgramFile
          source-path-id
          (sym_i64_env.sym-i64-shared-view (& cfgs)))]
      (match (compiler-load-program-cache-lookup key)
        [(CompilerLoadProgramCacheHit program)
          (begin
            (compiler-load-program-cache-note-hit!)
            (parser.ResultAstProgramDiagnostic.Ok program))]
        [(CompilerLoadProgramCacheMiss)
          (begin
            (compiler-load-program-cache-note-miss!)
            (if (or
              (compiler-load-session-file-cache-immediate?
                (clone path)
                (ast.ast-place-shared-view stdlib-roots))
              (compiler-load-program-admission-contains?
                (ast.ast-place-shared-view key)))
              (if (compiler-load-session-file-cache-immediate?
                (clone path)
                (ast.ast-place-shared-view stdlib-roots))
                (compiler-load-parse-file-diagnostic-cache-miss key path cfgs)
                (compiler-load-parse-file-diagnostic-cache-miss-local
                  key
                  path
                  cfgs))
              (compiler-load-parse-file-diagnostic-admit-only key path cfgs)))]))
    (compiler-load-parse-file-diagnostic-escaping path cfgs)))

(define (compiler-load-parse-file-diagnostic-session-id-with-pools
  [load-state : CompilerLoadSessionState]
  [path : String]
  [source-path-id : i64]
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]) : parser.ResultAstProgramDiagnostic
  (if (and
    (compiler-load-session-state-cache-enabled? load-state)
    (compiler-load-session-state-program-cache-enabled? load-state)
    (compiler-load-session-file-cacheable?
      (clone path)
      (ast.ast-place-shared-view stdlib-roots)))
    (let
      [key : CompilerLoadProgramCacheKey
        (compiler-load-session-state-program-cache-key-id
          (compiler-load-session-state-shared-view (& load-state))
          CompilerLoadProgramFile
          source-path-id
          (sym_i64_env.sym-i64-shared-view (& cfgs)))]
      (match (compiler-load-session-state-program-cache-lookup
        (compiler-load-session-state-shared-view (& load-state))
        key)
        [(CompilerLoadProgramCacheHit program)
          (begin
            (compiler-load-session-state-program-cache-note-hit!
              (compiler-load-session-state-shared-view (& load-state)))
            (parser.ResultAstProgramDiagnostic.Ok program))]
        [(CompilerLoadProgramCacheMiss)
          (begin
            (compiler-load-session-state-program-cache-note-miss!
              (compiler-load-session-state-shared-view (& load-state)))
            (if (or
              (compiler-load-session-file-cache-immediate?
                (clone path)
                (ast.ast-place-shared-view stdlib-roots))
              (compiler-load-session-state-program-admission-contains?
                (compiler-load-session-state-shared-view (& load-state))
                key))
              (if (compiler-load-session-file-cache-immediate?
                (clone path)
                (ast.ast-place-shared-view stdlib-roots))
                (compiler-load-parse-file-diagnostic-cache-miss-with-pools
                  (compiler-load-session-state-shared-view (& load-state))
                  (ast.ast-place-shared-view key)
                  (clone path)
                  (sym_i64_env.sym-i64-shared-view (& cfgs))
                  (ast.ast-place-shared-view pools))
                (compiler-load-parse-file-diagnostic-cache-miss-local-with-pools
                  (compiler-load-session-state-shared-view (& load-state))
                  (ast.ast-place-shared-view key)
                  (clone path)
                  (sym_i64_env.sym-i64-shared-view (& cfgs))
                  (ast.ast-place-shared-view pools)))
              (compiler-load-parse-file-diagnostic-admit-only-with-pools
                (compiler-load-session-state-shared-view (& load-state))
                key
                (clone path)
                cfgs
                pools)))]))
    (compiler-load-parse-file-diagnostic-detached-with-pools path cfgs pools)))

(define (compiler-load-parse-embedded-source-diagnostic-cache-miss
  [key : CompilerLoadProgramCacheKey]
  [path : String]
  [source : String]
  [cfgs : sym_i64_env.SymI64Env]) : parser.ResultAstProgramDiagnostic
  (if (compiler-load-program-cache-can-store key)
    (let
      [persistent : CompilerLoadPersistentProgramResult
        (in-arena
          (arena.Arena ast.node-pool-base-arena)
          (CompilerLoadPersistentProgramResult
            (compiler-load-program-cache-key-copy key)
            (compiler-load-parse-source-diagnostic-escaping path source cfgs)))]
      (match persistent
        [(CompilerLoadPersistentProgramResult persistent-key parsed)
          (compiler-load-cache-program-result persistent-key parsed)]))
    (compiler-load-parse-source-diagnostic-escaping path source cfgs)))

(define (compiler-load-parse-embedded-source-diagnostic-cache-miss-with-pools
  [load-state : CompilerLoadSessionState]
  [key : CompilerLoadProgramCacheKey]
  [path : String]
  [source : String]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]) : parser.ResultAstProgramDiagnostic
  (if (compiler-load-session-state-program-cache-can-store
    (compiler-load-session-state-shared-view (& load-state))
    key)
    (let
      [persistent : CompilerLoadPersistentProgramResult
        (in-arena
          (arena.Arena (ast.ast-node-pool-context-base-arena pools))
          (CompilerLoadPersistentProgramResult
            (compiler-load-program-cache-key-copy key)
            (compiler-load-parse-source-diagnostic-escaping-with-pools
              path
              source
              cfgs
              (ast.ast-place-shared-view pools))))]
      (match persistent
        [(CompilerLoadPersistentProgramResult persistent-key parsed)
          (compiler-load-cache-program-result-with-pools
            load-state
            persistent-key
            parsed
            pools)]))
    (compiler-load-parse-source-diagnostic-escaping-with-pools
      path
      source
      cfgs
      pools)))

(define (compiler-load-parse-embedded-source-diagnostic-session-id
  [path : String]
  [source-path-id : i64]
  [source : String]
  [cfgs : sym_i64_env.SymI64Env]) : parser.ResultAstProgramDiagnostic
  (begin
    (compiler-load-session-note-embedded-stdlib-source!)
    (if (and
      (compiler-load-session-cache-enabled?)
      (compiler-load-session-program-cache-enabled?))
      (let
        [key : CompilerLoadProgramCacheKey
          (compiler-load-program-cache-key-id
            CompilerLoadProgramEmbedded
            source-path-id
            (sym_i64_env.sym-i64-shared-view (& cfgs)))]
        (match (compiler-load-program-cache-lookup key)
          [(CompilerLoadProgramCacheHit program)
            (begin
              (compiler-load-program-cache-note-hit!)
              (parser.ResultAstProgramDiagnostic.Ok program))]
          [(CompilerLoadProgramCacheMiss)
            (begin
              (compiler-load-program-cache-note-miss!)
              (compiler-load-parse-embedded-source-diagnostic-cache-miss
                key
                (clone path)
                source
                cfgs))]))
      (compiler-load-parse-source-diagnostic-escaping path source cfgs))))

(define (compiler-load-parse-embedded-source-diagnostic-session-id-with-pools
  [load-state : CompilerLoadSessionState]
  [path : String]
  [source-path-id : i64]
  [source : String]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]) : parser.ResultAstProgramDiagnostic
  (begin
    (compiler-load-session-state-note-embedded-stdlib-source!
      (compiler-load-session-state-shared-view (& load-state)))
    (if (and
      (compiler-load-session-state-cache-enabled? load-state)
      (compiler-load-session-state-program-cache-enabled? load-state))
      (let
        [key : CompilerLoadProgramCacheKey
          (compiler-load-session-state-program-cache-key-id
            (compiler-load-session-state-shared-view (& load-state))
            CompilerLoadProgramEmbedded
            source-path-id
            (sym_i64_env.sym-i64-shared-view (& cfgs)))]
        (match (compiler-load-session-state-program-cache-lookup
          (compiler-load-session-state-shared-view (& load-state))
          key)
          [(CompilerLoadProgramCacheHit program)
            (begin
              (compiler-load-session-state-program-cache-note-hit! load-state)
              (parser.ResultAstProgramDiagnostic.Ok program))]
          [(CompilerLoadProgramCacheMiss)
            (begin
              (compiler-load-session-state-program-cache-note-miss!
                (compiler-load-session-state-shared-view (& load-state)))
              (compiler-load-parse-embedded-source-diagnostic-cache-miss-with-pools
                load-state
                key
                path
                source
                cfgs
                pools))]))
      (compiler-load-parse-source-diagnostic-escaping-with-pools
        path
        source
        cfgs
        pools))))

(define (compiler-load-source-with-paths-and-roots-expect-cfg
  [path : String]
  [source : String]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : svec.Vec]
  [expected-module : ast.AstMaybeModuleName]
  [cfgs : sym_i64_env.SymI64Env]) : ResultCompilerLoadWithPaths
  (let
    [fallback : String (compiler-load-canonical-module-id-from-path path)]
    [parse-identity : CompilerLoadParseIdentity
      (compiler-load-parse-identity (clone path) fallback expected-module)]
    (match (compiler-load-parse-source-diagnostic-escaping
      (clone path)
      source
      (sym_i64_env.sym-i64-shared-view (& cfgs)))
      [(parser.ResultAstProgramDiagnostic.Ok program)
        (compiler-load-program-with-paths-and-roots-expect-cfg
          path
          program
          seen
          stdlib-roots
          expected-module
          cfgs
          parse-identity)]
      [(parser.ResultAstProgramDiagnostic.Err diag)
        (ResultCompilerLoadWithPaths.Err diag)])))

(define (compiler-load-source-with-paths-and-roots-expect-cfg-with-pools
  [load-state : CompilerLoadSessionState]
  [path : String]
  [source : String]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : svec.Vec]
  [expected-module : ast.AstMaybeModuleName]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]) : ResultCompilerLoadWithPaths
  (let
    [fallback : String (compiler-load-canonical-module-id-from-path path)]
    [parse-identity : CompilerLoadParseIdentity
      (compiler-load-parse-identity (clone path) fallback expected-module)]
    (match (compiler-load-parse-source-diagnostic-escaping-with-pools
      (clone path)
      source
      (sym_i64_env.sym-i64-shared-view (& cfgs))
      (ast.ast-place-shared-view pools))
      [(parser.ResultAstProgramDiagnostic.Ok program)
        (compiler-load-program-with-paths-and-roots-expect-cfg-with-pools
          load-state
          path
          program
          seen
          stdlib-roots
          expected-module
          cfgs
          pools
          parse-identity)]
      [(parser.ResultAstProgramDiagnostic.Err diag)
        (ResultCompilerLoadWithPaths.Err diag)])))

(define (compiler-load-source
  [path : String]
  [source : String]
  [seen : sym_i64_env.SymI64Env]) : ResultCompilerLoad
  (compiler-load-drop-paths (compiler-load-source-with-paths path source seen)))

(define (compiler-load-file-with-paths
  [path : String]
  [seen : sym_i64_env.SymI64Env]) : ResultCompilerLoadWithPaths
  (compiler-load-file-with-paths-and-roots path seen (svec.new)))

(define (compiler-load-file-with-paths-and-roots
  [path : String]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : svec.Vec]) : ResultCompilerLoadWithPaths
  (compiler-load-file-with-paths-and-roots-expect
    path
    seen
    stdlib-roots
    ast.AstMaybeModuleName.No))

(define (compiler-load-file-with-paths-and-roots-cfg
  [path : String]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]) : ResultCompilerLoadWithPaths
  (compiler-load-file-with-paths-and-roots-expect-cfg
    path
    seen
    stdlib-roots
    ast.AstMaybeModuleName.No
    cfgs))

(define (compiler-load-file-with-paths-and-roots-cfg-with-pools
  [load-state : CompilerLoadSessionState]
  [path : String]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]) : ResultCompilerLoadWithPaths
  (compiler-load-file-with-paths-and-roots-expect-cfg-with-pools
    load-state
    path
    seen
    stdlib-roots
    ast.AstMaybeModuleName.No
    cfgs
    pools))

(define (compiler-load-file-with-paths-and-roots-expect
  [path : String]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : svec.Vec]
  [expected-module : ast.AstMaybeModuleName]) : ResultCompilerLoadWithPaths
  (compiler-load-file-with-paths-and-roots-expect-cfg
    path
    seen
    stdlib-roots
    expected-module
    (parser.compiler-cfg-empty)))

(define (compiler-load-bind-path-dedup
  [loaded : ResultCompilerLoadWithPaths]
  [path-dedup : bool]
  [path-key-id : i64]) : ResultCompilerLoadWithPaths
  (match loaded
    [(ResultCompilerLoadWithPaths.Ok decls paths modules loaded-seen)
      (ResultCompilerLoadWithPaths.Ok
        decls
        paths
        modules
        (if path-dedup
          (sym_i64_env.sym-i64-bind-id loaded-seen path-key-id 1)
          loaded-seen))]
    [(ResultCompilerLoadWithPaths.Err diag)
      (ResultCompilerLoadWithPaths.Err diag)]))

(define (compiler-load-file-with-paths-and-roots-expect-cfg
  [path : String]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : svec.Vec]
  [expected-module : ast.AstMaybeModuleName]
  [cfgs : sym_i64_env.SymI64Env]) : ResultCompilerLoadWithPaths
  (compiler-load-file-with-paths-and-roots-expect-cfg-root
    (clone path)
    seen
    stdlib-roots
    expected-module
    (compiler-load-dirname path)
    cfgs))

(define (compiler-load-file-with-paths-and-roots-expect-cfg-with-pools
  [load-state : CompilerLoadSessionState]
  [path : String]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : svec.Vec]
  [expected-module : ast.AstMaybeModuleName]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]) : ResultCompilerLoadWithPaths
  (compiler-load-file-with-paths-and-roots-expect-cfg-root-with-pools
    load-state
    (clone path)
    seen
    stdlib-roots
    expected-module
    (compiler-load-dirname path)
    cfgs
    pools))

(define (compiler-load-file-with-paths-and-roots-expect-cfg-root
  [path : String]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : svec.Vec]
  [expected-module : ast.AstMaybeModuleName]
  [import-root : String]
  [cfgs : sym_i64_env.SymI64Env]) : ResultCompilerLoadWithPaths
  (compiler-load-file-with-paths-and-roots-expect-cfg-root-cache-current
    (clone path)
    seen
    stdlib-roots
    expected-module
    import-root
    cfgs
    true))

(define (compiler-load-file-with-paths-and-roots-expect-cfg-root-with-pools
  [load-state : CompilerLoadSessionState]
  [path : String]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : svec.Vec]
  [expected-module : ast.AstMaybeModuleName]
  [import-root : String]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]) : ResultCompilerLoadWithPaths
  (compiler-load-file-with-paths-and-roots-expect-cfg-root-cache-current-with-pools
    load-state
    path
    seen
    stdlib-roots
    expected-module
    import-root
    cfgs
    true
    pools))

(define (compiler-load-file-with-paths-and-roots-expect-cfg-root-import-with-state-and-pools
  [load-state : CompilerLoadSessionState]
  [path : String]
  [source-path-id : i64]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : svec.Vec]
  [kind : ast.AstImportKind]
  [import-path : String]
  [expected-module : ast.AstMaybeModuleName]
  [import-root : String]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [context-module : String]
  [context-module-id : i64]) : ResultCompilerLoadWithPaths
  (let
    [fallback : String
      (compiler-load-canonical-module-id-from-import-rooted
        kind
        (clone import-path)
        (clone path)
        (clone import-root))]
    [source-module : String
      (compiler-load-canonical-source-module-from-import
        kind
        import-path
        (clone path)
        expected-module
        (clone context-module))]
    (compiler-load-file-with-paths-and-roots-expect-cfg-root-cache-current-fallback-with-pools
      load-state
      (clone path)
      source-path-id
      seen
      stdlib-roots
      expected-module
      (clone import-root)
      cfgs
      true
      pools
      context-module-id
      fallback
      (clone source-module)
      (if (string.eq source-module context-module)
        context-module-id
        -1)
      (compiler-load-decl-owner-id-from-root import-root path))))

(define (compiler-load-file-with-paths-and-roots-expect-cfg-root-cache-current
  [path : String]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : svec.Vec]
  [expected-module : ast.AstMaybeModuleName]
  [import-root : String]
  [cfgs : sym_i64_env.SymI64Env]
  [cache-current : bool]) : ResultCompilerLoadWithPaths
  (let
    [source-path-id : i64 (compiler-load-source-path-id path)]
    [path-key-id : i64
      (compiler-load-seen-path-key-id
        source-path-id
        cbi.compiler-builtin-id-fix-empty)]
    [path-dedup : bool (compiler-load-no-expected-module? expected-module)]
    (if (compiler-load-surface-summary-seen-expected-module?
      source-path-id
      expected-module
      (sym_i64_env.sym-i64-shared-view (& seen)))
      (compiler-load-seen-expected-module-with-paths
        (compiler-load-active-session-state-shared-view)
        path
        source-path-id
        expected-module
        seen)
      (if (and path-dedup (sym_i64_env.sym-i64-contains-id seen path-key-id))
        (ResultCompilerLoadWithPaths.Ok
          (ast.ast-decl-list-new)
          (ast.ast-decl-path-list-new)
          (ast.ast-decl-module-list-new)
          seen)
        (let
          [fallback : String
            (compiler-load-canonical-module-id-from-path (clone path))]
          [parse-identity : CompilerLoadParseIdentity
            (CompilerLoadParseIdentity
              source-path-id
              (compiler-load-module-fallback-id-for-parse
                fallback
                expected-module)
              cbi.compiler-builtin-id-fix-empty)]
          [parse-cfgs : sym_i64_env.SymI64Env cfgs]
          (if (io.file-exists? (clone path))
            (match (if cache-current
              (compiler-load-parse-file-diagnostic-session-id
                (clone path)
                source-path-id
                (ast.ast-place-shared-view stdlib-roots)
                (sym_i64_env.sym-i64-shared-view (& parse-cfgs)))
              (compiler-load-parse-file-diagnostic-escaping
                (clone path)
                (sym_i64_env.sym-i64-shared-view (& parse-cfgs))))
              [(parser.ResultAstProgramDiagnostic.Ok program)
                (compiler-load-bind-path-dedup
                  (compiler-load-program-with-paths-and-roots-expect-cfg-root
                    path
                    program
                    seen
                    stdlib-roots
                    expected-module
                    import-root
                    parse-cfgs
                    parse-identity)
                  path-dedup
                  path-key-id)]
              [(parser.ResultAstProgramDiagnostic.Err diag)
                (ResultCompilerLoadWithPaths.Err diag)])
            (match (compiler-load-embedded-stdlib-source-for-path (clone path))
              [(ces.CompilerEmbeddedStdlibSource.CompilerEmbeddedStdlibSomeSource
                  source)
                (match (begin
                  (compiler-load-note-embedded-module! (clone path))
                  (if cache-current
                    (compiler-load-parse-embedded-source-diagnostic-session-id
                      (clone path)
                      source-path-id
                      (clone source)
                      (sym_i64_env.sym-i64-shared-view (& parse-cfgs)))
                    (compiler-load-parse-source-diagnostic-escaping
                      (clone path)
                      source
                      (sym_i64_env.sym-i64-shared-view (& parse-cfgs)))))
                  [(parser.ResultAstProgramDiagnostic.Ok program)
                    (compiler-load-bind-path-dedup
                      (compiler-load-program-with-paths-and-roots-expect-cfg-root
                        (clone path)
                        program
                        seen
                        (ast.ast-place-shared-view stdlib-roots)
                        (clone expected-module)
                        (clone import-root)
                        (sym_i64_env.sym-i64-shared-view (& parse-cfgs))
                        parse-identity)
                      path-dedup
                      path-key-id)]
                  [(parser.ResultAstProgramDiagnostic.Err diag)
                    (ResultCompilerLoadWithPaths.Err diag)])]
              [(ces.CompilerEmbeddedStdlibSource.CompilerEmbeddedStdlibNoSource)
                (ResultCompilerLoadWithPaths.Err
                  (box
                    (cdiag.compiler-diagnostic-at-start
                      (clone path)
                      (str_cat.str-cat
                        "compiler-load: cannot read import "
                        path))))])))))))

(define (compiler-load-file-with-paths-and-roots-expect-cfg-root-cache-current-with-pools
  [load-state : CompilerLoadSessionState]
  [path : String]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : svec.Vec]
  [expected-module : ast.AstMaybeModuleName]
  [import-root : String]
  [cfgs : sym_i64_env.SymI64Env]
  [cache-current : bool]
  [pools : ast.AstNodePoolContext]) : ResultCompilerLoadWithPaths
  (let
    [fallback : String (compiler-load-canonical-module-id-from-path path)]
    (compiler-load-file-with-paths-and-roots-expect-cfg-root-cache-current-fallback-with-pools
      load-state
      (clone path)
      (compiler-load-source-path-id path)
      seen
      stdlib-roots
      expected-module
      import-root
      cfgs
      cache-current
      pools
      cbi.compiler-builtin-id-fix-empty
      fallback
      ""
      cbi.compiler-builtin-id-fix-empty
      cbi.compiler-builtin-id-fix-empty)))

(define (compiler-load-file-with-paths-and-roots-expect-cfg-root-cache-current-fallback-with-pools
  [load-state : CompilerLoadSessionState]
  [path : String]
  [source-path-id : i64]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : svec.Vec]
  [expected-module : ast.AstMaybeModuleName]
  [import-root : String]
  [cfgs : sym_i64_env.SymI64Env]
  [cache-current : bool]
  [pools : ast.AstNodePoolContext]
  [context-module-id : i64]
  [module-id-fallback : String]
  [source-module-fallback : String]
  [source-module-fallback-id-hint : i64]
  [decl-owner-id : i64]) : ResultCompilerLoadWithPaths
  (let
    [path-dedup : bool (compiler-load-no-expected-module? expected-module)]
    [path-key-id : i64
      (compiler-load-seen-path-key-id source-path-id context-module-id)]
    (if (compiler-load-session-state-surface-summary-seen-expected-module?
      (compiler-load-session-state-shared-view (& load-state))
      source-path-id
      (clone expected-module)
      (sym_i64_env.sym-i64-shared-view (& seen)))
      (compiler-load-seen-expected-module-with-paths
        load-state
        path
        source-path-id
        expected-module
        seen)
      (if (and path-dedup (sym_i64_env.sym-i64-contains-id seen path-key-id))
        (ResultCompilerLoadWithPaths.Ok
          (ast.ast-decl-list-new)
          (ast.ast-decl-path-list-new)
          (ast.ast-decl-module-list-new)
          seen)
        (let
          [parse-identity : CompilerLoadParseIdentity
            (CompilerLoadParseIdentity
              source-path-id
              (compiler-load-module-fallback-id-for-parse
                (clone module-id-fallback)
                (clone expected-module))
              decl-owner-id)]
          [module-id-fallback-id : i64 parse-identity.module-fallback-id]
          [source-module-fallback-id : i64
            (cond
              [(>= source-module-fallback-id-hint 0)
                source-module-fallback-id-hint]
              [(= (string.string-length source-module-fallback) 0)
                cbi.compiler-builtin-id-fix-empty]
              [(string.eq source-module-fallback module-id-fallback)
                module-id-fallback-id]
              [else
                (compiler-load-parse-context-name-id source-module-fallback)])]
          [parse-cfgs : sym_i64_env.SymI64Env cfgs]
          (if (io.file-exists? (clone path))
            (match (if cache-current
              (compiler-load-parse-file-diagnostic-session-id-with-pools
                (compiler-load-session-state-shared-view (& load-state))
                (clone path)
                source-path-id
                (ast.ast-place-shared-view stdlib-roots)
                (sym_i64_env.sym-i64-shared-view (& parse-cfgs))
                (ast.ast-place-shared-view pools))
              (compiler-load-parse-file-diagnostic-detached-with-pools
                (clone path)
                (sym_i64_env.sym-i64-shared-view (& parse-cfgs))
                (ast.ast-place-shared-view pools)))
              [(parser.ResultAstProgramDiagnostic.Ok program)
                (compiler-load-bind-path-dedup
                  (compiler-load-program-with-paths-and-roots-expect-cfg-root-fallback-with-pools
                    (compiler-load-session-state-shared-view (& load-state))
                    (clone path)
                    program
                    (sym_i64_env.sym-i64-shared-view (& seen))
                    (ast.ast-place-shared-view stdlib-roots)
                    (clone expected-module)
                    (clone import-root)
                    (sym_i64_env.sym-i64-shared-view (& parse-cfgs))
                    (ast.ast-place-shared-view pools)
                    (clone module-id-fallback)
                    (clone parse-identity)
                    (clone source-module-fallback)
                    source-module-fallback-id)
                  path-dedup
                  path-key-id)]
              [(parser.ResultAstProgramDiagnostic.Err diag)
                (ResultCompilerLoadWithPaths.Err diag)])
            (match (compiler-load-embedded-stdlib-source-for-path (clone path))
              [(ces.CompilerEmbeddedStdlibSource.CompilerEmbeddedStdlibSomeSource
                  source)
                (match (begin
                  (compiler-load-note-embedded-module! (clone path))
                  (if cache-current
                    (compiler-load-parse-embedded-source-diagnostic-session-id-with-pools
                      (compiler-load-session-state-shared-view (& load-state))
                      (clone path)
                      source-path-id
                      (clone source)
                      (sym_i64_env.sym-i64-shared-view (& parse-cfgs))
                      (ast.ast-place-shared-view pools))
                    (compiler-load-parse-source-diagnostic-escaping-with-pools
                      (clone path)
                      source
                      (sym_i64_env.sym-i64-shared-view (& parse-cfgs))
                      (ast.ast-place-shared-view pools))))
                  [(parser.ResultAstProgramDiagnostic.Ok program)
                    (compiler-load-bind-path-dedup
                      (compiler-load-program-with-paths-and-roots-expect-cfg-root-fallback-with-pools
                        (compiler-load-session-state-shared-view (& load-state))
                        (clone path)
                        program
                        (sym_i64_env.sym-i64-shared-view (& seen))
                        (ast.ast-place-shared-view stdlib-roots)
                        (clone expected-module)
                        (clone import-root)
                        (sym_i64_env.sym-i64-shared-view (& parse-cfgs))
                        (ast.ast-place-shared-view pools)
                        (clone module-id-fallback)
                        (clone parse-identity)
                        (clone source-module-fallback)
                        source-module-fallback-id)
                      path-dedup
                      path-key-id)]
                  [(parser.ResultAstProgramDiagnostic.Err diag)
                    (ResultCompilerLoadWithPaths.Err diag)])]
              [(ces.CompilerEmbeddedStdlibSource.CompilerEmbeddedStdlibNoSource)
                (ResultCompilerLoadWithPaths.Err
                  (box
                    (cdiag.compiler-diagnostic-at-start
                      (clone path)
                      (str_cat.str-cat
                        "compiler-load: cannot read import "
                        path))))])))))))

(define (compiler-load-file-with-paths-and-roots-expect-cfg-fallback
  [path : String]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : svec.Vec]
  [expected-module : ast.AstMaybeModuleName]
  [cfgs : sym_i64_env.SymI64Env]
  [module-id-fallback : String]
  [source-module-fallback : String]) : ResultCompilerLoadWithPaths
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [result : ResultCompilerLoadWithPaths
      (compiler-load-file-with-paths-and-roots-expect-cfg-root-cache-current-fallback-with-pools
        (compiler-load-active-session-state-shared-view)
        (clone path)
        (compiler-load-source-path-id path)
        seen
        stdlib-roots
        expected-module
        (compiler-load-dirname path)
        cfgs
        true
        (ast.ast-place-shared-view pools)
        cbi.compiler-builtin-id-fix-empty
        module-id-fallback
        (clone source-module-fallback)
        (if (= (string.string-length source-module-fallback) 0)
          cbi.compiler-builtin-id-fix-empty
          -1)
        cbi.compiler-builtin-id-fix-empty)]
    (begin
      (ast.ast-node-pool-context-install! pools)
      result)))

(define (compiler-load-entry-file-with-paths-and-roots-cfg
  [path : String]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]) : ResultCompilerLoadWithPaths
  (compiler-load-file-with-paths-and-roots-expect-cfg-root-cache-current
    (clone path)
    seen
    stdlib-roots
    ast.AstMaybeModuleName.No
    (compiler-load-dirname path)
    cfgs
    false))

(define (compiler-load-entry-file-with-paths-and-roots-cfg-with-pools
  [load-state : CompilerLoadSessionState]
  [path : String]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]) : ResultCompilerLoadWithPaths
  (compiler-load-file-with-paths-and-roots-expect-cfg-root-cache-current-with-pools
    load-state
    (clone path)
    seen
    stdlib-roots
    ast.AstMaybeModuleName.No
    (compiler-load-dirname path)
    cfgs
    false
    pools))

(define (compiler-load-package-hex-digit [n : i64]) : String
  (cond
    [(= n 0) "0"]
    [(= n 1) "1"]
    [(= n 2) "2"]
    [(= n 3) "3"]
    [(= n 4) "4"]
    [(= n 5) "5"]
    [(= n 6) "6"]
    [(= n 7) "7"]
    [(= n 8) "8"]
    [(= n 9) "9"]
    [(= n 10) "a"]
    [(= n 11) "b"]
    [(= n 12) "c"]
    [(= n 13) "d"]
    [(= n 14) "e"]
    [else "f"]))

(define (compiler-load-package-hex-byte [n : i64]) : String
  (str_cat.str-cat
    (compiler-load-package-hex-digit (/ n 16))
    (compiler-load-package-hex-digit (% n 16))))

(define (compiler-load-package-symbol-char
  [text : (& text str)]
  [idx : i64]
  [c : char]) : String
  (cond
    [(or
        (and (>= c 'A') (<= c 'Z'))
        (and (>= c 'a') (<= c 'z'))
        (and (>= c '0') (<= c '9'))
        (= c '_'))
      (string.substring text idx 1)]
    [(= c '-') "_"]
    [(= c '?') "_question"]
    [(= c '!') "_bang"]
    [(= c '+') "_plus"]
    [(= c '*') "_star"]
    [(= c '/') "_slash"]
    [(= c '=') "_eq"]
    [(= c '<') "_lt"]
    [(= c '>') "_gt"]
    [(= c ':') "_colon"]
    [else
      (str_cat.str-cat
        "_u"
        (compiler-load-package-hex-byte (compiler-load-char-code-at text idx)))]))

(define (compiler-load-package-asm-safe-symbol [name : String]) : String
  (let
    [i : i64 0]
    [n : i64 (string.string-length name)]
    [out : String ""]
    [emitted : bool false]
    [pending-separator : bool false]
    (begin
      (while (< i n)
        (if (compiler-load-package-tl-extension-at? name i)
          (set! i (+ i 3))
          (let
            [c : char (string.string-ref name i)]
            (if (compiler-load-package-symbol-separator? c)
              (begin
                (if emitted
                  (set! pending-separator true)
                  unit)
                (set! i (+ i 1)))
              (begin
                (if pending-separator
                  (begin
                    (set! out (str_cat.str-cat out "_" ""))
                    (set! pending-separator false))
                  unit)
                (set!
                  out
                  (str_cat.str-cat
                    out
                    (compiler-load-package-symbol-char name i c)
                    ""))
                (set! emitted true)
                (set! i (+ i 1)))))))
      out)))

(define (compiler-load-package-symbol-separator? [c : char]) : bool
  (or (= c '/') (= c '\\') (= c ':') (= c '.')))

(define (compiler-load-package-tl-extension-at?
  [name : (& name str)]
  [idx : i64]) : bool
  (let
    [n : i64 (string.string-length name)]
    [after : i64 (+ idx 3)]
    (and
      (<= after n)
      (= (string.string-ref name idx) '.')
      (= (string.string-ref name (+ idx 1)) 't')
      (= (string.string-ref name (+ idx 2)) 'l')
      (or
        (= after n)
        (compiler-load-package-symbol-separator? (string.string-ref name after))))))

(define (compiler-load-package-user-symbol [name : String]) : String
  (if (string.eq name "main")
    "main"
    (str_cat.str-cat "_tl_" (compiler-load-package-asm-safe-symbol name))))

(define (compiler-load-package-module-key [module : String] [name : String]) : String
  (if (= (string.string-length module) 0)
    name
    (str_cat.str-cat module "/" name)))

(define (compiler-load-package-module-id
  [entry-path : String]
  [decl-path : String]) : String
  (let
    [entry-path : String (compiler-load-normalize-path entry-path)]
    [decl-path : String (compiler-load-normalize-path decl-path)]
    [base : String (compiler-load-dirname entry-path)]
    [base-len : i64 (string.string-length base)]
    [decl-len : i64 (string.string-length decl-path)]
    (if (and (> base-len 0) (compiler-load-string-prefix-at? decl-path base 0))
      (string.substring decl-path base-len (- decl-len base-len))
      decl-path)))

(define (compiler-load-package-module-logical-name
  [entry-path : String]
  [decl-path : String]
  [source-name : String]) : String
  (if (and
    (string.eq
      (compiler-load-normalize-path decl-path)
      (compiler-load-normalize-path entry-path))
    (string.eq source-name "main"))
    "main"
    (str_cat.str-cat
      (compiler-load-package-module-id entry-path decl-path)
      "::"
      source-name)))

(define (compiler-load-package-entry-main?
  [entry-path : String]
  [decl-path : String]
  [_module : String]
  [source-name : String]) : bool
  (and
    (string.eq
      (compiler-load-normalize-path decl-path)
      (compiler-load-normalize-path entry-path))
    (string.eq source-name "main")))

(define (compiler-load-root-prefix [root : (& root str)]) : String
  (compiler-load-join-root-path (string.copy root) ""))

(define (compiler-load-path-under-root?
  [path : (& path str)]
  [root : (& root str)]) : bool
  (let
    [prefix : String (compiler-load-root-prefix root)]
    [prefix-len : i64 (string.string-length prefix)]
    (and (> prefix-len 0) (compiler-load-string-prefix-at? path prefix 0))))

(define (compiler-load-owned-path-from-root
  [owner : String]
  [root : String]
  [path : String]) : String
  (let
    [prefix : String (compiler-load-root-prefix root)]
    [prefix-len : i64 (string.string-length prefix)]
    [path-len : i64 (string.string-length path)]
    (if (= prefix-len 0)
      (if (compiler-load-absolute-path? path)
        path
        (str_cat.str-cat owner "/" (compiler-load-normalize-path path)))
      (if (compiler-load-path-under-root? path root)
        (str_cat.str-cat
          owner
          "/"
          (string.substring path prefix-len (- path-len prefix-len)))
        path))))

(define (compiler-load-stdlib-owner-root? [root : String]) : bool
  (let
    [normalized : String (compiler-load-normalize-path root)]
    [base : String (fs.basename (& normalized))]
    (string.eq base "stdlib")))

(define (compiler-load-stdlib-owned-path-from-roots
  [path : String]
  [stdlib-roots : svec.Vec]) : String
  (let
    [roots : svec.Vec (compiler-load-roots-with-env stdlib-roots)]
    [i : i64 0]
    [n : i64 (svec.len (& roots))]
    [found : bool false]
    [out : String ""]
    (begin
      (while (and (not found) (< i n))
        (let
          [root : String (svec.get (& roots) i "")]
          [prefix : String (compiler-load-root-prefix root)]
          [prefix-len : i64 (string.string-length prefix)]
          [path-len : i64 (string.string-length path)]
          (if (and
            (compiler-load-stdlib-owner-root? root)
            (> prefix-len 0)
            (compiler-load-string-prefix-at? path prefix 0))
            (begin
              (set! found true)
              (set!
                out
                (str_cat.str-cat
                  "stdlib/"
                  (string.substring path prefix-len (- path-len prefix-len)))))
            (set! i (+ i 1)))))
      (if found
        out
        path))))

(define (compiler-load-package-owned-path
  [package-owner : String]
  [package-root : String]
  [stdlib-roots : svec.Vec]
  [path : String]) : String
  (let
    [stdlib-path : String
      (if (compiler-load-stdlib-import? path)
        (compiler-load-normalize-path path)
        (compiler-load-stdlib-owned-path-from-roots (clone path) stdlib-roots))]
    (if (compiler-load-stdlib-import? stdlib-path)
      stdlib-path
      (if (= (string.string-length package-owner) 0)
        path
        (compiler-load-owned-path-from-root package-owner package-root path)))))

(define (compiler-load-package-owned-path-cached!
  [cache : (&mut cache load_i64_i64_map.Map)]
  [package-owner : String]
  [package-root : String]
  [stdlib-roots : svec.Vec]
  [path : String]
  [path-id : i64]) : i64
  (match (load_i64_i64_map.get cache path-id)
    [(load_i64_i64_map.LookupFound owned-id) owned-id]
    [(load_i64_i64_map.LookupMissing)
      (let
        [owned : String
          (compiler-load-package-owned-path
            package-owner
            package-root
            stdlib-roots
            path)]
        [owned-id : i64 (ci.intern-generated-canonical-name owned)]
        (begin
          (load_i64_i64_map.insert-ref! cache path-id owned-id)
          owned-id))]))

(define (compiler-load-package-decl-logical-name
  [entry-path : String]
  [decl-path : String]
  [module : String]
  [source-name : String]) : String
  (if (compiler-load-package-entry-main?
    (clone entry-path)
    (clone decl-path)
    (clone module)
    (clone source-name))
    "main"
    (if (string.eq module "")
      (compiler-load-package-module-logical-name
        entry-path
        decl-path
        source-name)
      (compiler-load-package-module-logical-name
        entry-path
        decl-path
        (compiler-load-package-module-key module source-name)))))

(define (compiler-load-param-type-list [params : ast.AstParamList]) : ast.AstTypeList
  (let
    [out : ast.AstTypeList
      (ast.ast-type-list-with-capacity (ast.ast-param-list-len (& params)))]
    (begin
      (compiler-load-param-type-list-into (& params) 0 (&mut out))
      out)))

(define (compiler-load-param-type-list-into
  [params : (& params ast.AstParamList)]
  [index : i64]
  [out : (&mut out ast.AstTypeList)]) : unit
  (if (>= index (ast.ast-param-list-len params))
    unit
    (begin
      (match (ast.ast-param-list-get params index (ast.ast-param-fallback))
        [(ast.AstParam.Param _ ty _)
          (ast.ast-type-list-push out (ast.ast-node-pool-reader-type-push ty))])
      (compiler-load-param-type-list-into params (+ index 1) out))))

(define (compiler-load-package-tlci-path
  [manifest-dir : String]
  [package-name : String]) : String
  (compiler-load-join-root-path
    (compiler-load-join-root-path
      (compiler-load-join-root-path manifest-dir "target")
      (string.copy (& compiler-load-package-artifact-profile)))
    (str_cat.str-cat package-name ".tlci")))

(define (compiler-load-package-spmd-interface
  [manifest-dir : String]
  [package-name : String]
  [package-version : String]) : ResultCompilerLoadPackageSpmdInterface
  (let
    [path : String
      (compiler-load-package-tlci-path
        (clone manifest-dir)
        (clone package-name))]
    (if (not (io.file-exists? (clone path)))
      (ResultCompilerLoadPackageSpmdInterface.Ok
        CompilerLoadPackageSpmdInterface.Unavailable)
      (match (compiler-load-try-read-file-text (& path))
        [(io.ErrIoString error)
          (ResultCompilerLoadPackageSpmdInterface.Err
            (str_cat.str-cat
              "compiler-load: cannot read dependency tlci '"
              path
              "': "
              (io.error-message error)))]
        [(io.OkIoString contents)
          (match (tlci.tlci-parse-image (tlci.tlci-string->bytes contents))
            [(tlci.ResultTlciImage.Err message)
              (ResultCompilerLoadPackageSpmdInterface.Err
                (str_cat.str-cat
                  "compiler-load: invalid dependency tlci '"
                  path
                  "': "
                  message))]
            [(tlci.ResultTlciImage.Ok image)
              (let
                [metadata : tlci.TlciMetadata image.metadata]
                (if (or
                  (not (string.eq metadata.package-name package-name))
                  (not (string.eq metadata.package-version package-version)))
                  (ResultCompilerLoadPackageSpmdInterface.Err
                    (str_cat.str-cat
                      "compiler-load: dependency tlci package identity mismatch for '"
                      path
                      "': expected "
                      package-name
                      "@"
                      package-version
                      ", found "
                      metadata.package-name
                      "@"
                      metadata.package-version))
                  (ResultCompilerLoadPackageSpmdInterface.Ok
                    (CompilerLoadPackageSpmdInterface.Available
                      metadata.spmd-callables))))])]))))

(define (compiler-load-imported-spmd-specializations
  [items : tlci.TlciSpmdSpecializations]) : ast.AstImportedSpmdSpecializationList
  (let
    [out : ast.AstImportedSpmdSpecializationList
      (ast.ast-imported-spmd-specialization-list-new)]
    [count : i64 (tlci.tlci-spmd-specializations-len items)]
    [index : i64 0]
    (begin
      (while (< index count)
        (let
          [item : tlci.TlciSpmdSpecialization
            (tlci.tlci-spmd-specializations-ref items index)]
          (begin
            (ast.ast-imported-spmd-specialization-list-push
              (&mut out)
              (ast.AstImportedSpmdSpecialization
                (ci.intern-id-from-renderable
                  (ci.intern-generated-canonical-name item.abi))
                (ci.intern-id-from-renderable
                  (ci.intern-generated-canonical-name item.backend))
                item.lanes
                (ci.intern-id-from-renderable
                  (ci.intern-generated-canonical-name item.args))
                (ci.intern-id-from-renderable
                  (ci.intern-generated-canonical-name item.result))
                item.index-param
                (ci.intern-id-from-renderable
                  (ci.intern-generated-canonical-name item.symbol))))
            (set! index (+ index 1)))))
      out)))

(define (compiler-load-imported-spmd-callables-for
  [canonical-name : String]
  [items : tlci.TlciSpmdCallables]) : ast.AstImportedSpmdCallableList
  (let
    [out : ast.AstImportedSpmdCallableList
      (ast.ast-imported-spmd-callable-list-new)]
    [count : i64 (tlci.tlci-spmd-callables-len items)]
    [index : i64 0]
    (begin
      (while (< index count)
        (let
          [item : tlci.TlciSpmdCallable
            (tlci.tlci-spmd-callables-ref items index)]
          (begin
            (if (string.eq item.name canonical-name)
              (ast.ast-imported-spmd-callable-list-push
                (&mut out)
                (ast.AstImportedSpmdCallable
                  (ci.intern-id-from-renderable
                    (ci.intern-generated-canonical-name item.signature))
                  (compiler-load-imported-spmd-specializations
                    item.specializations)))
              unit)
            (set! index (+ index 1)))))
      out)))

(define (compiler-load-imported-spmd-metadata
  [package-owner : String]
  [module : String]
  [name : i64]
  [interface : CompilerLoadPackageSpmdInterface]) : ast.AstImportedSpmdMetadata
  (let
    [canonical-name : String
      (compiler-load-package-module-key
        (if (= (string.string-length module) 0)
          package-owner
          module)
        (ci.intern-str name))]
    [callables : ast.AstImportedSpmdCallableList
      (match interface
        [(CompilerLoadPackageSpmdInterface.Unavailable)
          (ast.ast-imported-spmd-callable-list-new)]
        [(CompilerLoadPackageSpmdInterface.Available items)
          (compiler-load-imported-spmd-callables-for
            (clone canonical-name)
            items)])]
    (ast.AstImportedSpmdMetadata.Package
      (ci.intern-id-from-renderable
        (ci.intern-generated-canonical-name canonical-name))
      (box callables))))

(define (compiler-load-package-def-fn-extern
  [package-owner : String]
  [package-root : String]
  [stdlib-roots : svec.Vec]
  [decl-path : String]
  [module : String]
  [name : i64]
  [params : ast.AstParamList]
  [ret : ast.AstType]
  [spmd-interface : CompilerLoadPackageSpmdInterface]) : ast.AstDecl
  (let
    [name-str : String (ci.intern-str name)]
    [logical-path : String
      (compiler-load-package-owned-path
        (clone package-owner)
        (clone package-root)
        (ast.ast-place-shared-view stdlib-roots)
        decl-path)]
    [logical : String
      (compiler-load-package-decl-logical-name
        ""
        logical-path
        (clone module)
        name-str)]
    [link-name : String (compiler-load-package-user-symbol (clone logical))]
    (ast.AstDecl.Extern
      (ast.ast-decl-meta-runtime-shared-view)
      name
      (ast.AstExternKind.Function)
      (box
        (ast.AstExternMetadata.Metadata
          (ast.AstExternAbi.C)
          (ci.intern-id-from-renderable
            (ci.intern-generated-canonical-name
              (owned_view.compiler-owned-shared-view link-name)))
          (ast.ast-extern-link-input-list-new)
          (ast.ast-extern-metadata-flags false (string.eq link-name logical))
          (compiler-load-imported-spmd-metadata
            package-owner
            module
            name
            spmd-interface)))
      (ast.ast-ty-func (compiler-load-param-type-list params) ret))))

(define (compiler-load-package-transform-decl
  [package-owner : String]
  [package-root : String]
  [stdlib-roots : svec.Vec]
  [decl-path : String]
  [module : String]
  [spmd-interface : CompilerLoadPackageSpmdInterface]
  [decl : ast.AstDecl]) : CompilerLoadMaybeDecl
  (match (clone decl)
    [(ast.AstDecl.DefFn decl-meta name params ret _ _)
      (CompilerLoadSomeDecl
        (ast.ast-decl-with-meta
          decl-meta
          (compiler-load-package-def-fn-extern
            package-owner
            package-root
            stdlib-roots
            decl-path
            module
            name
            params
            ret
            spmd-interface)))]
    ;; Package macro declarations remain source-backed until #2755 commits
    ;; dependency-native results. Retaining the declaration also ensures the
    ;; catalog registry is consulted only after ordinary import visibility and
    ;; shadowing resolve this exact transformer.
    [(ast.AstDecl.DefMacro _ _ _ _ _) (CompilerLoadSomeDecl decl)]
    [(ast.AstDecl.DefStruct decl-meta _ _ _ _) (CompilerLoadSomeDecl decl)]
    [(ast.AstDecl.Module _) (CompilerLoadSomeDecl decl)]
    [(ast.AstDecl.Unsafe inner-box)
      (let
        [inner : ast.AstDecl (ast.ast-decl-box-shared-view inner-box)]
        (match (compiler-load-package-transform-decl
          package-owner
          package-root
          stdlib-roots
          decl-path
          module
          spmd-interface
          inner)
          [(CompilerLoadSomeDecl transformed)
            (CompilerLoadSomeDecl (ast.ast-decl-unsafe transformed))]
          [(CompilerLoadNoDecl) (CompilerLoadNoDecl)]))]
    [_ (CompilerLoadNoDecl)]))

(define (compiler-load-path-list-head-or
  [paths : ast.AstDeclPathList]
  [fallback : String]) : String
  (match (ast.ast-decl-path-list-step paths)
    [(ast.AstDeclPathListStep.Cons path _) path]
    [(ast.AstDeclPathListStep.Nil) fallback]))

(define (compiler-load-path-list-tail [paths : ast.AstDeclPathList]) : ast.AstDeclPathList
  (match (ast.ast-decl-path-list-step paths)
    [(ast.AstDeclPathListStep.Cons _ rest)
      (let
        [rest : ast.AstDeclPathList rest]
        rest)]
    [(ast.AstDeclPathListStep.Nil) (ast.ast-decl-path-list-new)]))

(define (compiler-load-package-owned-decl-entry-main?
  [entry-path : String]
  [module : String]
  [decl-path : String]
  [decl : ast.AstDecl]) : bool
  (match decl
    [(ast.AstDecl.DefFn decl-meta name _ _ _ _)
      (compiler-load-package-entry-main?
        entry-path
        decl-path
        module
        (ci.intern-str name))]
    [(ast.AstDecl.Unsafe inner-box)
      (compiler-load-package-owned-decl-entry-main?
        entry-path
        module
        decl-path
        (ast.ast-decl-box-shared-view inner-box))]
    [_ false]))

(define (compiler-load-package-owned-paths-for-decls-in-module
  [package-owner : String]
  [package-root : String]
  [stdlib-roots : svec.Vec]
  [entry-path : String]
  [decls : ast.AstDeclList]
  [paths : ast.AstDeclPathList]
  [module : String]) : ast.AstDeclPathList
  (let
    [count : i64 (ast.ast-decl-list-len (& decls))]
    [decl-cursor : ast.AstDeclList decls]
    [path-cursor : ast.AstDeclPathList paths]
    [current-module : String module]
    [out : ast.AstDeclPathList (ast.ast-decl-path-list-with-capacity count)]
    [owned-cache : load_i64_i64_map.Map
      (load_i64_i64_map.with-capacity (+ (* count 2) 16))]
    [done : bool false]
    (begin
      (while (not done)
        (match (ast.ast-decl-list-step (ast.ast-place-shared-view decl-cursor))
          [(ast.AstDeclListStep.Nil) (set! done true)]
          [(ast.AstDeclListStep.Cons decl rest)
            (let
              [decl-path : String
                (compiler-load-path-list-head-or
                  (ast.ast-place-shared-view path-cursor)
                  (clone entry-path))]
              [decl-path-id : i64
                (ast.ast-decl-path-list-owner-id
                  (& path-cursor)
                  0
                  cbi.compiler-builtin-id-fix-empty)]
              [decl-provenance-id : i64
                (ast.ast-decl-path-list-provenance-id
                  (& path-cursor)
                  0
                  cbi.compiler-builtin-id-fix-empty)]
              [owned-path-id : i64
                (if (compiler-load-package-owned-decl-entry-main?
                  (clone entry-path)
                  (clone current-module)
                  (clone decl-path)
                  (clone decl))
                  cbi.compiler-builtin-id-fix-empty
                  (compiler-load-package-owned-path-cached!
                    (&mut owned-cache)
                    (clone package-owner)
                    (clone package-root)
                    (ast.ast-place-shared-view stdlib-roots)
                    decl-path
                    decl-path-id))]
              [owned-path : String (ci.intern-str owned-path-id)]
              (begin
                (ast.ast-decl-path-list-push-with-owner-and-provenance-id
                  (&mut out)
                  owned-path
                  owned-path-id
                  decl-provenance-id)
                (match decl
                  [(ast.AstDecl.Module name)
                    (set! current-module (ci.intern-str name))]
                  [_ unit])
                (set! decl-cursor rest)
                (set! path-cursor (compiler-load-path-list-tail path-cursor))))]))
      out)))

(define (compiler-load-package-owned-paths-for-decls
  [package-owner : String]
  [package-root : String]
  [stdlib-roots : svec.Vec]
  [entry-path : String]
  [decls : ast.AstDeclList]
  [paths : ast.AstDeclPathList]) : ast.AstDeclPathList
  (compiler-load-package-owned-paths-for-decls-in-module
    package-owner
    package-root
    stdlib-roots
    entry-path
    decls
    paths
    ""))

(define (compiler-load-package-extern-decls
  [package-owner : String]
  [package-root : String]
  [stdlib-roots : svec.Vec]
  [decls : ast.AstDeclList]
  [paths : ast.AstDeclPathList]
  [seen : sym_i64_env.SymI64Env]
  [module : String]
  [module-id : i64]
  [spmd-interface : CompilerLoadPackageSpmdInterface]) : ResultCompilerLoadWithPaths
  (match (ast.ast-decl-list-step (ast.ast-place-shared-view decls))
    [(ast.AstDeclListStep.Nil)
      (ResultCompilerLoadWithPaths.Ok
        (ast.ast-decl-list-new)
        (ast.ast-decl-path-list-new)
        (ast.ast-decl-module-list-new)
        seen)]
    [(ast.AstDeclListStep.Cons decl rest)
      (let
        [rest : ast.AstDeclList rest]
        [decl-path : String
          (compiler-load-path-list-head-or
            (ast.ast-place-shared-view paths)
            (clone package-root))]
        [decl-path-id : i64
          (ast.ast-decl-path-list-owner-id
            (& paths)
            0
            cbi.compiler-builtin-id-fix-empty)]
        [decl-provenance-id : i64
          (ast.ast-decl-path-list-provenance-id
            (& paths)
            0
            cbi.compiler-builtin-id-fix-empty)]
        [owned-decl-path : String
          (compiler-load-package-owned-path
            (clone package-owner)
            (clone package-root)
            (ast.ast-place-shared-view stdlib-roots)
            (clone decl-path))]
        [rest-paths : ast.AstDeclPathList
          (compiler-load-path-list-tail (ast.ast-place-shared-view paths))]
        [next-module : String
          (match (clone decl)
            [(ast.AstDecl.Module name) (ci.intern-str name)]
            [_ (clone module)])]
        [next-module-id : i64
          (match (clone decl)
            [(ast.AstDecl.Module name) name]
            [_ module-id])]
        (match (compiler-load-package-extern-decls
          (clone package-owner)
          (clone package-root)
          (ast.ast-place-shared-view stdlib-roots)
          rest
          rest-paths
          seen
          next-module
          next-module-id
          (clone spmd-interface))
          [(ResultCompilerLoadWithPaths.Ok
              rest-decls
              rest-decl-paths
              rest-modules
              rest-seen)
            (match (compiler-load-package-transform-decl
              package-owner
              package-root
              stdlib-roots
              decl-path
              module
              spmd-interface
              decl)
              [(CompilerLoadSomeDecl transformed)
                (ResultCompilerLoadWithPaths.Ok
                  (compiler-load-decl-list-prepend-from-source
                    transformed
                    decls
                    rest-decls)
                  (ast.ast-decl-path-list-prepend-builder-with-owner-and-provenance-id
                    owned-decl-path
                    decl-path-id
                    decl-provenance-id
                    rest-decl-paths)
                  (ast.ast-decl-module-list-prepend-builder-id
                    module-id
                    rest-modules)
                  rest-seen)]
              [(CompilerLoadNoDecl)
                (ResultCompilerLoadWithPaths.Ok
                  rest-decls
                  rest-decl-paths
                  rest-modules
                  rest-seen)])]
          [(ResultCompilerLoadWithPaths.Err diag)
            (ResultCompilerLoadWithPaths.Err diag)]))]))

(define (compiler-load-package-entry-for-source [source-path : String]) : ResultCompilerLoadPackageEntry
  (match (compiler-load-discover-manifest (clone source-path))
    [(CompilerLoadNoPath)
      (ResultCompilerLoadPackageEntry.Err
        (str_cat.str-cat
          "compiler-load: dependency package manifest not found for "
          source-path))]
    [(CompilerLoadSomePath manifest-path)
      (match (compiler-load-parse-manifest-diagnostic-infer-kind
        (clone manifest-path)
        (compiler-load-read-file-text manifest-path))
        [(ResultCompilerPkgManifestDiagnostic.Err diag)
          (ResultCompilerLoadPackageEntry.Err
            (str_cat.str-cat
              "compiler-load: invalid dependency package manifest '"
              manifest-path
              "': "
              (cdiag.compiler-diagnostic-message (__tl-box-place diag))))]
        [(ResultCompilerPkgManifestDiagnostic.Ok manifest)
          (let
            [manifest-dir : String (compiler-load-dirname manifest-path)]
            (ResultCompilerLoadPackageEntry.Ok
              (CompilerLoadPackageEntry
                (compiler-load-normalize-path
                  (compiler-load-join-root-path
                    (clone manifest-dir)
                    manifest.entry))
                manifest-dir
                manifest.name
                manifest.version)))])]))

(defstruct CompilerLoadDependencySurfaceSelection
  (decls ast.AstDeclList)
  (paths ast.AstDeclPathList)
  (modules ast.AstDeclModuleList))

(defenum CompilerLoadDependencySurfaceImport
  (Unavailable)
  (Ok ResultCompilerLoadWithPaths))

(define (compiler-load-dependency-surface-decl-seen?
  [seen : sym_i64_env.SymI64Env]
  [decl : ast.AstDecl]
  [paths : ast.AstDeclPathList]
  [modules : ast.AstDeclModuleList]
  [index : i64]) : bool
  (let
    [owner-id : i64
      (ast.ast-decl-path-list-owner-id
        (& paths)
        index
        cbi.compiler-builtin-id-fix-empty)]
    [module-id : i64
      (ast.ast-decl-module-list-get-id
        (& modules)
        index
        cbi.compiler-builtin-id-fix-empty)]
    (match decl
      ;; A module declaration's side-table entry names the module that was
      ;; active *before* the marker.  Select the marker by the module it
      ;; introduces, otherwise the first declaration from a dependency can be
      ;; rebound under the final module of an already-seen prelude surface.
      [(ast.AstDecl.Module name) (sym_i64_env.sym-i64-contains-id seen name)]
      [_
        (or
          (and
            (not (= module-id cbi.compiler-builtin-id-fix-empty))
            (sym_i64_env.sym-i64-contains-id seen module-id))
          (and
            (not (= owner-id cbi.compiler-builtin-id-fix-empty))
            (sym_i64_env.sym-i64-contains-id
              seen
              (compiler-load-seen-path-key-id owner-id module-id))))])))

(define (compiler-load-dependency-surface-select
  [hydration : surface_hydrate.CompilerSurfaceHydration]
  [seen : sym_i64_env.SymI64Env]) : CompilerLoadDependencySurfaceSelection
  (let
    [surface : surface_ast.SurfaceAstHydration hydration.ast]
    [count : i64 (ast.ast-decl-list-len (& surface.decls))]
    [decls : ast.AstDeclList (ast.ast-decl-list-with-capacity count)]
    [paths : ast.AstDeclPathList (ast.ast-decl-path-list-with-capacity count)]
    [modules : ast.AstDeclModuleList
      (ast.ast-decl-module-list-with-capacity count)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (if (compiler-load-dependency-surface-decl-seen?
            seen
            (ast.ast-decl-list-get
              (& surface.decls)
              index
              (ast.ast-decl-fallback))
            (owned_view.compiler-owned-shared-view surface.paths)
            (owned_view.compiler-owned-shared-view surface.modules)
            index)
            unit
            (begin
              (ast.ast-decl-list-push-from
                (&mut decls)
                (& surface.decls.slots)
                (+ surface.decls.offset index))
              (ast.ast-decl-path-list-push-with-owner-and-provenance-id
                (&mut paths)
                (ast.ast-decl-path-list-get (& surface.paths) index "")
                (ast.ast-decl-path-list-owner-id
                  (& surface.paths)
                  index
                  cbi.compiler-builtin-id-fix-empty)
                (ast.ast-decl-path-list-provenance-id
                  (& surface.paths)
                  index
                  cbi.compiler-builtin-id-fix-empty))
              (ast.ast-decl-module-list-push-id
                (&mut modules)
                (ast.ast-decl-module-list-get-id
                  (& surface.modules)
                  index
                  cbi.compiler-builtin-id-fix-empty))))
          (set! index (+ index 1))))
      (CompilerLoadDependencySurfaceSelection decls paths modules))))

(define (compiler-load-dependency-surface-merge-seen
  [base : sym_i64_env.SymI64Env]
  [extra : sym_i64_env.SymI64Env]) : sym_i64_env.SymI64Env
  (let
    [cursor : sym_i64_env.SymI64Env extra]
    [out : sym_i64_env.SymI64Env base]
    [done : bool false]
    (begin
      (while (not done)
        (match (sym_i64_env.sym-i64-view
          (owned_view.compiler-owned-shared-view cursor))
          [(sym_i64_env.SymI64ViewNil) (set! done true)]
          [(sym_i64_env.SymI64ViewBind key value rest)
            (begin
              (if (and
                (sym_i64_env.sym-i64-contains-id out key)
                (= (sym_i64_env.sym-i64-lookup-id-or out key -1) value))
                unit
                (set! out (sym_i64_env.sym-i64-bind-id out key value)))
              (set! cursor rest))]))
      out)))

(define (compiler-load-dependency-surface-interface
  [spmd-callables : tlci.TlciSpmdCallables]) : CompilerLoadPackageSpmdInterface
  (CompilerLoadPackageSpmdInterface.Available spmd-callables))

(define (compiler-load-dependency-surface-final-module-id
  [decls : ast.AstDeclList]
  [fallback : i64]) : i64
  (let
    [cursor : ast.AstDeclList decls]
    [module-id : i64 fallback]
    [done : bool false]
    (begin
      (while (not done)
        (match (ast.ast-decl-list-step
          (owned_view.compiler-owned-shared-view cursor))
          [(ast.AstDeclListStep.Nil) (set! done true)]
          [(ast.AstDeclListStep.Cons decl rest)
            (begin
              (match decl
                [(ast.AstDecl.Module next-module) (set! module-id next-module)]
                [_ unit])
              (set! cursor rest))]))
      module-id)))

(define (compiler-load-session-state-dependency-surface-decl-count
  [state : CompilerLoadSessionState]) : i64
  (array-ref state.dependency-surfaces.surface-decl-count 0))

(define (compiler-load-session-state-dependency-surface-provenance?
  [state : CompilerLoadSessionState]
  [provenance-id : i64]) : bool
  (>=
    (compiler-load-dependency-catalog-slot-for-provenance-id
      state
      provenance-id)
    0))

(define (compiler-load-dependency-surface-provenance-count
  [state : CompilerLoadSessionState]
  [paths : ast.AstDeclPathList]) : i64
  (let
    [count : i64 (ast.ast-decl-path-list-len (& paths))]
    [index : i64 0]
    [matched : i64 0]
    (begin
      (while (< index count)
        (begin
          (if (compiler-load-session-state-dependency-surface-provenance?
            (owned_view.compiler-owned-shared-view state)
            (ast.ast-decl-path-list-provenance-id
              (& paths)
              index
              cbi.compiler-builtin-id-fix-empty))
            (set! matched (+ matched 1))
            unit)
          (set! index (+ index 1))))
      matched)))

(define (compiler-load-session-state-dependency-surface-provenance-count
  [state : CompilerLoadSessionState]) : i64
  (array-ref state.dependency-surfaces.surface-provenance-count 0))

(define (compiler-load-session-state-dependency-surface-note-macro-skip!
  [state : CompilerLoadSessionState]
  [count : i64]) : unit
  (set! (array-ref state.dependency-surfaces.macro-skip-count 0) count))

(define (compiler-load-session-state-dependency-surface-note-typecheck-skip!
  [state : CompilerLoadSessionState]
  [count : i64]) : unit
  (set! (array-ref state.dependency-surfaces.typecheck-skip-count 0) count))

(define (compiler-load-dependency-surface-decl-count) : i64
  (compiler-load-session-state-dependency-surface-decl-count
    (compiler-load-active-session-state-shared-view)))

(define (compiler-load-dependency-surface-import
  [resolved : String]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : svec.Vec]
  [entry : CompilerLoadPackageEntry]
  [expected-module : ast.AstMaybeModuleName]
  [module-id-fallback : String]
  [source-module-fallback : String]) : CompilerLoadDependencySurfaceImport
  (let
    [state : CompilerLoadSessionState
      (compiler-load-active-session-state-shared-view)]
    [surface-state : CompilerLoadDependencySurfaceState
      (owned_view.compiler-owned-shared-view state.dependency-surfaces)]
    (if (not (array-ref surface-state.enabled 0))
      CompilerLoadDependencySurfaceImport.Unavailable
      (let
        [slot : i64
          (compiler-load-dependency-catalog-slot-for-provenance-id
            (owned_view.compiler-owned-shared-view state)
            (compiler-load-source-path-id
              (owned_view.compiler-owned-shared-view resolved)))]
        [fragments : CompilerLoadDependencySurfaceList
          (owned_view.compiler-owned-array-element-shared-view
            surface-state.fragments
            0)]
        (if (or (< slot 0) (>= slot fragments.len))
          CompilerLoadDependencySurfaceImport.Unavailable
          (match (owned_view.compiler-owned-array-element-shared-view
            fragments.slots
            slot)
            [(CompilerLoadDependencySurfaceFragment.Unavailable)
              CompilerLoadDependencySurfaceImport.Unavailable]
            [(CompilerLoadDependencySurfaceFragment.Ready
                hydration
                spmd-callables)
              (let
                [selection : CompilerLoadDependencySurfaceSelection
                  (compiler-load-dependency-surface-select
                    (owned_view.compiler-owned-shared-view hydration)
                    (owned_view.compiler-owned-shared-view seen))]
                [active-pools : ast.AstNodePoolContext
                  (if (ast.ast-node-pool-has-active-context?)
                    (ast.ast-node-pool-context-active-live)
                    (ast.ast-node-pool-context-capture-active))]
                [copy : ast.AstProgramCompaction
                  (ast.ast-program-copy-append-with-pools
                    (owned_view.compiler-owned-shared-view hydration.ast.pools)
                    active-pools
                    (ast.ast-program
                      (owned_view.compiler-owned-shared-view selection.decls)))]
                [copied-program : ast.AstProgram
                  (match (owned_view.compiler-owned-shared-view copy)
                    [(ast.AstProgramCompaction program _) program])]
                [copied-decls : ast.AstDeclList
                  (match copied-program
                    [(ast.AstProgram.Program decls-box)
                      (__tl-box-place decls-box)])]
                [copied-pools : ast.AstNodePoolContext
                  (match (owned_view.compiler-owned-shared-view copy)
                    [(ast.AstProgramCompaction _ pools) pools])]
                [explicit-module : bool
                  (compiler-load-decl-list-has-module?
                    (owned_view.compiler-owned-shared-view copied-decls))]
                [module-id-fallback-id : i64
                  (compiler-load-module-fallback-id-for-parse
                    (owned_view.compiler-owned-shared-view module-id-fallback)
                    (owned_view.compiler-owned-shared-view expected-module))]
                [source-module-id : i64
                  (if explicit-module
                    (compiler-load-dependency-surface-final-module-id
                      (owned_view.compiler-owned-shared-view copied-decls)
                      cbi.compiler-builtin-id-fix-empty)
                    (cond
                      [(= (string.string-length source-module-fallback) 0)
                        cbi.compiler-builtin-id-fix-empty]
                      [(string.eq source-module-fallback module-id-fallback)
                        module-id-fallback-id]
                      [else
                        (compiler-load-parse-context-name-id
                          source-module-fallback)]))]
                [merged-seen : sym_i64_env.SymI64Env
                  (compiler-load-dependency-surface-merge-seen
                    (owned_view.compiler-owned-shared-view seen)
                    (owned_view.compiler-owned-shared-view hydration.ast.seen))]
                (begin
                  (ast.ast-node-pool-context-install! copied-pools)
                  ;; Source loading publishes this compact summary before
                  ;; traversing a file. Rebuild the same summary from the
                  ;; hydrated AST so qualified macro imports retain their
                  ;; ordinary visibility rules. The registry's exact package
                  ;; and source binding already authenticated these decls;
                  ;; package import spellings need not equal a declared module.
                  (compiler-load-surface-summary-remove-source!
                    (compiler-load-source-path-id
                      (owned_view.compiler-owned-shared-view resolved)))
                  (compiler-load-record-surface-summary!
                    (compiler-load-surface-summary-from-decls
                      (owned_view.compiler-owned-shared-view resolved)
                      (compiler-load-source-path-id
                        (owned_view.compiler-owned-shared-view resolved))
                      (owned_view.compiler-owned-shared-view entry.manifest-dir)
                      source-module-id
                      source-module-id
                      explicit-module
                      (not (compiler-load-no-expected-module? expected-module))
                      (owned_view.compiler-owned-shared-view copied-decls)))
                  (match (compiler-load-package-extern-decls
                    entry.owner
                    entry.manifest-dir
                    stdlib-roots
                    copied-decls
                    selection.paths
                    merged-seen
                    ""
                    cbi.compiler-builtin-id-fix-empty
                    (compiler-load-dependency-surface-interface spmd-callables))
                    [(ResultCompilerLoadWithPaths.Err _)
                      CompilerLoadDependencySurfaceImport.Unavailable]
                    [(ResultCompilerLoadWithPaths.Ok
                        decls
                        paths
                        modules
                        loaded-seen)
                      (let
                        [decl-count : i64 (ast.ast-decl-list-len (& decls))]
                        [provenance-count : i64
                          (compiler-load-dependency-surface-provenance-count
                            (owned_view.compiler-owned-shared-view state)
                            (owned_view.compiler-owned-shared-view paths))]
                        (begin
                          (if (array-ref fragments.imported slot)
                            unit
                            (match (surface_facts.surface-typecheck-facts-builder-append
                              (owned_view.compiler-owned-array-element-shared-view
                                surface-state.facts-builder
                                0)
                              (owned_view.compiler-owned-shared-view
                                hydration.facts))
                              [(surface_facts.ResultSurfaceTypecheckFactsBuilder.Err
                                  _)
                                (return
                                  CompilerLoadDependencySurfaceImport.Unavailable)]
                              [(surface_facts.ResultSurfaceTypecheckFactsBuilder.Ok
                                  next)
                                (begin
                                  (set!
                                    (array-ref surface-state.facts-builder 0)
                                    next)
                                  (set!
                                    (array-ref fragments.imported slot)
                                    true))]))
                          (set!
                            (array-ref surface-state.fragments 0)
                            (owned_view.compiler-owned-shared-view fragments))
                          (set!
                            (array-ref surface-state.surface-decl-count 0)
                            (+
                              (array-ref surface-state.surface-decl-count 0)
                              decl-count))
                          (set!
                            (array-ref surface-state.surface-provenance-count 0)
                            (+
                              (array-ref
                                surface-state.surface-provenance-count
                                0)
                              provenance-count))
                          (set!
                            (array-ref surface-state.hit-count 0)
                            (+ (array-ref surface-state.hit-count 0) 1))
                          (CompilerLoadDependencySurfaceImport.Ok
                            (ResultCompilerLoadWithPaths.Ok
                              decls
                              paths
                              modules
                              loaded-seen))))])))]))))))

(define (compiler-load-package-externs-from-import
  [resolved : String]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : svec.Vec]
  [expected-module : ast.AstMaybeModuleName]
  [cfgs : sym_i64_env.SymI64Env]
  [module-id-fallback : String]
  [source-module-fallback : String]) : ResultCompilerLoadWithPaths
  (match (compiler-load-package-entry-for-source (clone resolved))
    [(ResultCompilerLoadPackageEntry.Err message)
      (ResultCompilerLoadWithPaths.Err
        (box (cdiag.compiler-diagnostic-at-start (clone resolved) message)))]
    [(ResultCompilerLoadPackageEntry.Ok entry)
      (match (compiler-load-dependency-surface-import
        (clone resolved)
        (sym_i64_env.sym-i64-shared-view (& seen))
        (ast.ast-place-shared-view stdlib-roots)
        (owned_view.compiler-owned-shared-view entry)
        (owned_view.compiler-owned-shared-view expected-module)
        (clone module-id-fallback)
        (clone source-module-fallback))
        [(CompilerLoadDependencySurfaceImport.Ok loaded) loaded]
        [(CompilerLoadDependencySurfaceImport.Unavailable)
          (match (compiler-load-package-spmd-interface
            (clone entry.manifest-dir)
            (clone entry.owner)
            (clone entry.version))
            [(ResultCompilerLoadPackageSpmdInterface.Err message)
              (ResultCompilerLoadWithPaths.Err
                (box (cdiag.compiler-diagnostic-at-start resolved message)))]
            [(ResultCompilerLoadPackageSpmdInterface.Ok spmd-interface)
              (match (compiler-load-file-with-paths-and-roots-expect-cfg-fallback
                (clone resolved)
                seen
                (ast.ast-place-shared-view stdlib-roots)
                expected-module
                cfgs
                module-id-fallback
                source-module-fallback)
                [(ResultCompilerLoadWithPaths.Ok
                    imported-decls
                    imported-paths
                    _
                    import-seen)
                  (compiler-load-package-extern-decls
                    entry.owner
                    entry.manifest-dir
                    stdlib-roots
                    imported-decls
                    imported-paths
                    import-seen
                    ""
                    cbi.compiler-builtin-id-fix-empty
                    spmd-interface)]
                [(ResultCompilerLoadWithPaths.Err diag)
                  (ResultCompilerLoadWithPaths.Err diag)])])])]))

(define (compiler-load-package-expand-include-str
  [importer-path : String]
  [include-path : String]
  [name : i64]
  [stdlib-roots : svec.Vec]
  [manifest-dir : String]
  [deps : CompilerPkgDeps]) : ResultCompilerLoadInclude
  (match (if (compiler-load-pkg-import? include-path)
    (compiler-load-resolve-pkg-import (clone include-path) manifest-dir deps)
    (compiler-load-resolve-import-result-with-roots
      (clone importer-path)
      (clone include-path)
      stdlib-roots))
    [(ResultPkgResolve.Ok resolved)
      (compiler-load-include-str-from-resolved
        importer-path
        include-path
        resolved
        name)]
    [(ResultPkgResolve.Err message)
      (ResultCompilerLoadInclude.Err
        (box (cdiag.compiler-diagnostic-at-start importer-path message)))]))

(define (compiler-load-package-expand-include-str-comptime
  [importer-path : String]
  [include-path : String]
  [name : i64]
  [stdlib-roots : svec.Vec]
  [manifest-dir : String]
  [deps : CompilerPkgDeps]) : ResultCompilerLoadInclude
  (match (if (compiler-load-pkg-import? include-path)
    (compiler-load-resolve-pkg-import (clone include-path) manifest-dir deps)
    (compiler-load-resolve-import-result-with-roots
      (clone importer-path)
      (clone include-path)
      stdlib-roots))
    [(ResultPkgResolve.Ok resolved)
      (compiler-load-include-str-comptime-from-resolved-with-pools
        importer-path
        include-path
        resolved
        name
        (ast.ast-node-pool-context-capture-active))]
    [(ResultPkgResolve.Err message)
      (ResultCompilerLoadInclude.Err
        (box (cdiag.compiler-diagnostic-at-start importer-path message)))]))

(define (compiler-load-package-expand-include-str-lzss
  [importer-path : String]
  [include-path : String]
  [name : i64]
  [stdlib-roots : svec.Vec]
  [manifest-dir : String]
  [deps : CompilerPkgDeps]) : ResultCompilerLoadInclude
  (match (if (compiler-load-pkg-import? include-path)
    (compiler-load-resolve-pkg-import (clone include-path) manifest-dir deps)
    (compiler-load-resolve-import-result-with-roots
      (clone importer-path)
      (clone include-path)
      stdlib-roots))
    [(ResultPkgResolve.Ok resolved)
      (compiler-load-include-str-lzss-from-resolved
        importer-path
        include-path
        resolved
        name)]
    [(ResultPkgResolve.Err message)
      (ResultCompilerLoadInclude.Err
        (box (cdiag.compiler-diagnostic-at-start importer-path message)))]))

(define (compiler-load-package-expand-include-bin
  [importer-path : String]
  [include-path : String]
  [name : i64]
  [stdlib-roots : svec.Vec]
  [manifest-dir : String]
  [deps : CompilerPkgDeps]) : ResultCompilerLoadInclude
  (match (if (compiler-load-pkg-import? include-path)
    (compiler-load-resolve-pkg-import (clone include-path) manifest-dir deps)
    (compiler-load-resolve-import-result-with-roots
      (clone importer-path)
      (clone include-path)
      stdlib-roots))
    [(ResultPkgResolve.Ok resolved)
      (compiler-load-include-bin-from-resolved
        importer-path
        include-path
        resolved
        name)]
    [(ResultPkgResolve.Err message)
      (ResultCompilerLoadInclude.Err
        (box (cdiag.compiler-diagnostic-at-start importer-path message)))]))

(define (compiler-load-package-decls-with-module-and-roots
  [decls : ast.AstDeclList]
  [importer-path : String]
  [importer-path-id : i64]
  [importer-module : String]
  [importer-module-id : i64]
  [importer-source-module : String]
  [importer-source-module-id : i64]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : svec.Vec]
  [manifest-dir : String]
  [deps : CompilerPkgDeps]
  [cfgs : sym_i64_env.SymI64Env]) : ResultCompilerLoadWithPaths
  (match (ast.ast-decl-list-step (ast.ast-place-shared-view decls))
    [(ast.AstDeclListStep.Nil)
      (ResultCompilerLoadWithPaths.Ok
        (ast.ast-decl-list-new)
        (ast.ast-decl-path-list-new)
        (ast.ast-decl-module-list-new)
        seen)]
    [(ast.AstDeclListStep.Cons decl rest)
      (let
        [rest : ast.AstDeclList rest]
        (match (clone decl)
          [(ast.AstDecl.Import
              decl-meta
              (ast.AstImportSpec.Spec
                kind
                import-path
                expected-module
                alias
                span))
            (if (compiler-load-macro-import-kind? kind)
              (match (compiler-load-package-decls-with-module-and-roots
                rest
                (clone importer-path)
                importer-path-id
                importer-module
                importer-module-id
                (clone importer-source-module)
                importer-source-module-id
                (sym_i64_env.sym-i64-shared-view (& seen))
                (ast.ast-place-shared-view stdlib-roots)
                (clone manifest-dir)
                (ast.ast-place-shared-view deps)
                (sym_i64_env.sym-i64-shared-view (& cfgs)))
                [(ResultCompilerLoadWithPaths.Ok
                    rest-decls
                    rest-paths
                    rest-modules
                    rest-seen)
                  (ResultCompilerLoadWithPaths.Ok
                    (compiler-load-decl-list-prepend-from-source
                      decl
                      (ast.ast-place-shared-view decls)
                      rest-decls)
                    (ast.ast-decl-path-list-prepend-builder-with-owner-id
                      (clone importer-path)
                      importer-path-id
                      rest-paths)
                    (ast.ast-decl-module-list-prepend-builder-id
                      importer-module-id
                      rest-modules)
                    rest-seen)]
                [(ResultCompilerLoadWithPaths.Err diag)
                  (ResultCompilerLoadWithPaths.Err diag)])
              (match (compiler-load-resolve-package-import-spec-classified
                (owned_view.compiler-owned-shared-view importer-path)
                (owned_view.compiler-owned-shared-view kind)
                (owned_view.compiler-owned-shared-view import-path)
                (owned_view.compiler-owned-shared-view expected-module)
                (owned_view.compiler-owned-shared-view alias)
                (owned_view.compiler-owned-shared-view stdlib-roots)
                (owned_view.compiler-owned-shared-view manifest-dir)
                (owned_view.compiler-owned-shared-view deps))
                [(ResultCompilerLoadResolvedImport.Ok import)
                  (let
                    [resolved : String import.resolved]
                    [kind : ast.AstImportKind import.kind]
                    [import-path : String import.module-name]
                    [expected-module : ast.AstMaybeModuleName
                      import.expected-module]
                    [alias : ast.AstMaybeImportAlias import.alias]
                    [resolved-id : i64 (compiler-load-source-path-id resolved)]
                    [package-externs : bool
                      (compiler-load-package-import-externs?
                        (clone kind)
                        (clone import-path)
                        (clone expected-module)
                        (ast.ast-place-shared-view deps))]
                    [source-expected-module : ast.AstMaybeModuleName
                      (compiler-load-package-source-expected-module
                        (clone kind)
                        (clone expected-module)
                        package-externs)]
                    [fallback : String
                      (compiler-load-canonical-module-id-from-import
                        (clone kind)
                        (clone import-path)
                        (clone resolved))]
                    [source-fallback : String
                      (compiler-load-canonical-source-module-from-import
                        (clone kind)
                        (clone import-path)
                        (clone resolved)
                        (clone expected-module)
                        (clone importer-source-module))]
                    [preload-candidate : bool
                      (and
                        (not package-externs)
                        (compiler-load-lazy-import-preload-candidate?
                          (clone importer-path)
                          (clone kind)
                          (clone alias)))]
                    [preload-pools : ast.AstNodePoolContext
                      (ast.ast-node-pool-context-capture-active)]
                    [preload-demand : CompilerLoadLazyAliasDemand
                      (compiler-load-lazy-import-preload-demand
                        preload-candidate
                        (clone alias)
                        (ast.ast-place-shared-view rest)
                        (ast.ast-place-shared-view preload-pools))]
                    [preload-summary-needed : bool
                      (and
                        preload-candidate
                        (not
                          (or preload-demand.qualified preload-demand.unknown)))]
                    [_preload-summary : unit
                      (if preload-summary-needed
                        (compiler-load-lazy-import-preload-summary-with-pools
                          (clone resolved)
                          resolved-id
                          (ast.ast-place-shared-view stdlib-roots)
                          (clone expected-module)
                          (clone manifest-dir)
                          (sym_i64_env.sym-i64-shared-view (& cfgs))
                          (ast.ast-place-shared-view preload-pools))
                        unit)]
                    [preload-skip : bool
                      (if preload-summary-needed
                        (compiler-load-lazy-import-skip?
                          (clone importer-path)
                          (clone kind)
                          (clone resolved)
                          resolved-id
                          (clone expected-module)
                          (clone alias)
                          (ast.ast-place-shared-view rest)
                          (ast.ast-place-shared-view preload-pools)
                          (clone preload-demand)
                          (ast.ast-place-shared-view stdlib-roots))
                        false)]
                    (match (if preload-skip
                      (ResultCompilerLoadWithPaths.Ok
                        (ast.ast-decl-list-new)
                        (ast.ast-decl-path-list-new)
                        (ast.ast-decl-module-list-new)
                        (sym_i64_env.sym-i64-shared-view (& seen)))
                      (if package-externs
                        (compiler-load-package-externs-from-import
                          (clone resolved)
                          (sym_i64_env.sym-i64-shared-view (& seen))
                          (ast.ast-place-shared-view stdlib-roots)
                          (clone source-expected-module)
                          (sym_i64_env.sym-i64-shared-view (& cfgs))
                          (clone fallback)
                          "")
                        (compiler-load-package-file-with-paths-and-roots-expect-cache-current-fallback
                          (clone resolved)
                          resolved-id
                          (sym_i64_env.sym-i64-shared-view (& seen))
                          (ast.ast-place-shared-view stdlib-roots)
                          (clone expected-module)
                          (clone manifest-dir)
                          (ast.ast-place-shared-view deps)
                          (sym_i64_env.sym-i64-shared-view (& cfgs))
                          true
                          (clone fallback)
                          (clone source-fallback)
                          (if (string.eq source-fallback importer-source-module)
                            importer-source-module-id
                            -1))))
                      [(ResultCompilerLoadWithPaths.Ok
                          imported-decls
                          imported-paths
                          imported-modules
                          import-seen)
                        (let
                          [lazy-skip : bool preload-skip]
                          [after-import-seen : sym_i64_env.SymI64Env
                            (if lazy-skip
                              seen
                              import-seen)]
                          [validated-module : ast.AstMaybeModuleName
                            (compiler-load-after-import-expected-module
                              (compiler-load-active-session-state-shared-view)
                              resolved-id
                              (owned_view.compiler-owned-shared-view kind)
                              (owned_view.compiler-owned-shared-view
                                expected-module)
                              (owned_view.compiler-owned-shared-view alias)
                              (ast.ast-place-shared-view imported-decls))]
                          (begin
                            (when
                              (not
                                (or
                                  (compiler-load-expected-module-seen?
                                    (sym_i64_env.sym-i64-shared-view (& seen))
                                    (owned_view.compiler-owned-shared-view
                                      validated-module))
                                  (compiler-load-selected-item-present?
                                    (owned_view.compiler-owned-shared-view kind)
                                    (owned_view.compiler-owned-shared-view
                                      validated-module)
                                    (ast.ast-place-shared-view imported-decls))))
                              (return
                                (ResultCompilerLoadWithPaths.Err
                                  (box
                                    (cdiag.compiler-diagnostic-from-ast-span
                                      (owned_view.compiler-owned-shared-view
                                        importer-path)
                                      (__tl-box-place span)
                                      (compiler-load-missing-selected-item-message
                                        (owned_view.compiler-owned-shared-view
                                          import-path)
                                        (owned_view.compiler-owned-shared-view
                                          kind)))))))
                            (match (compiler-load-package-decls-with-module-and-roots
                              rest
                              (owned_view.compiler-owned-shared-view
                                importer-path)
                              importer-path-id
                              importer-module
                              importer-module-id
                              (owned_view.compiler-owned-shared-view
                                importer-source-module)
                              importer-source-module-id
                              after-import-seen
                              stdlib-roots
                              manifest-dir
                              deps
                              cfgs)
                              [(ResultCompilerLoadWithPaths.Ok
                                  rest-decls
                                  rest-paths
                                  rest-modules
                                  rest-seen)
                                (let
                                  [after-import-expected : ast.AstMaybeModuleName
                                    validated-module]
                                  [after-import-alias : ast.AstMaybeImportAlias
                                    (compiler-load-after-import-alias
                                      (compiler-load-active-session-state-shared-view)
                                      resolved-id
                                      (owned_view.compiler-owned-shared-view
                                        kind)
                                      (owned_view.compiler-owned-shared-view
                                        expected-module)
                                      (owned_view.compiler-owned-shared-view
                                        alias)
                                      (ast.ast-place-shared-view imported-decls))]
                                  (if lazy-skip
                                    (begin
                                      (compiler-load-lazy-import-record-skip!)
                                      (ResultCompilerLoadWithPaths.Ok
                                        (compiler-load-decls-after-import
                                          kind
                                          resolved
                                          after-import-expected
                                          after-import-alias
                                          (__tl-box-place span)
                                          importer-source-module
                                          importer-source-module-id
                                          decls
                                          (ast.ast-decl-list-new)
                                          rest-decls)
                                        (compiler-load-paths-after-import
                                          importer-path
                                          importer-path-id
                                          importer-path-id
                                          (owned_view.compiler-owned-shared-view
                                            after-import-alias)
                                          (ast.ast-decl-list-new)
                                          rest-paths)
                                        (compiler-load-modules-after-import
                                          importer-module-id
                                          after-import-alias
                                          (ast.ast-decl-list-new)
                                          rest-modules)
                                        rest-seen))
                                    (let
                                      [after-decls : ast.AstDeclList
                                        (compiler-load-decls-after-import
                                          kind
                                          resolved
                                          after-import-expected
                                          (owned_view.compiler-owned-shared-view
                                            after-import-alias)
                                          (__tl-box-place span)
                                          importer-source-module
                                          importer-source-module-id
                                          (ast.ast-place-shared-view decls)
                                          (ast.ast-place-shared-view
                                            imported-decls)
                                          rest-decls)]
                                      [after-paths : ast.AstDeclPathList
                                        (compiler-load-paths-after-import
                                          importer-path
                                          importer-path-id
                                          importer-path-id
                                          (owned_view.compiler-owned-shared-view
                                            after-import-alias)
                                          (ast.ast-place-shared-view
                                            imported-decls)
                                          rest-paths)]
                                      [after-modules : ast.AstDeclModuleList
                                        (compiler-load-modules-after-import
                                          importer-module-id
                                          after-import-alias
                                          (ast.ast-place-shared-view
                                            imported-decls)
                                          rest-modules)]
                                      (ResultCompilerLoadWithPaths.Ok
                                        (compiler-load-decl-list-append-onto
                                          imported-decls
                                          after-decls)
                                        (compiler-load-decl-path-list-append-onto
                                          imported-paths
                                          after-paths)
                                        (compiler-load-decl-module-list-append-onto
                                          imported-modules
                                          after-modules)
                                        rest-seen))))]
                              [(ResultCompilerLoadWithPaths.Err diag)
                                (ResultCompilerLoadWithPaths.Err diag)])))]
                      [(ResultCompilerLoadWithPaths.Err diag)
                        (ResultCompilerLoadWithPaths.Err diag)]))]
                [(ResultCompilerLoadResolvedImport.Err message)
                  (ResultCompilerLoadWithPaths.Err
                    (box
                      (cdiag.compiler-diagnostic-from-ast-span
                        importer-path
                        (__tl-box-place span)
                        message)))]))]
          [(ast.AstDecl.IncludeStr name include-path)
            (match (compiler-load-package-expand-include-str
              (clone importer-path)
              include-path
              name
              (ast.ast-place-shared-view stdlib-roots)
              (clone manifest-dir)
              (ast.ast-place-shared-view deps))
              [(ResultCompilerLoadInclude.Ok expanded)
                (match (compiler-load-package-decls-with-module-and-roots
                  (ast.ast-place-shared-view rest)
                  (clone importer-path)
                  importer-path-id
                  importer-module
                  importer-module-id
                  (clone importer-source-module)
                  importer-source-module-id
                  (sym_i64_env.sym-i64-shared-view (& seen))
                  (ast.ast-place-shared-view stdlib-roots)
                  (clone manifest-dir)
                  (ast.ast-place-shared-view deps)
                  (sym_i64_env.sym-i64-shared-view (& cfgs)))
                  [(ResultCompilerLoadWithPaths.Ok
                      rest-decls
                      rest-paths
                      rest-modules
                      rest-seen)
                    (ResultCompilerLoadWithPaths.Ok
                      (compiler-load-decl-list-prepend-from-source
                        expanded
                        (ast.ast-place-shared-view decls)
                        rest-decls)
                      (ast.ast-decl-path-list-prepend-builder-with-owner-id
                        (clone importer-path)
                        importer-path-id
                        rest-paths)
                      (ast.ast-decl-module-list-prepend-builder-id
                        importer-module-id
                        rest-modules)
                      rest-seen)]
                  [(ResultCompilerLoadWithPaths.Err diag)
                    (ResultCompilerLoadWithPaths.Err diag)])]
              [(ResultCompilerLoadInclude.Err diag)
                (ResultCompilerLoadWithPaths.Err diag)])]
          [(ast.AstDecl.IncludeStrComptime name include-path)
            (match (compiler-load-package-expand-include-str-comptime
              (clone importer-path)
              include-path
              name
              (ast.ast-place-shared-view stdlib-roots)
              (clone manifest-dir)
              (ast.ast-place-shared-view deps))
              [(ResultCompilerLoadInclude.Ok expanded)
                (match (compiler-load-package-decls-with-module-and-roots
                  (ast.ast-place-shared-view rest)
                  (clone importer-path)
                  importer-path-id
                  importer-module
                  importer-module-id
                  (clone importer-source-module)
                  importer-source-module-id
                  (sym_i64_env.sym-i64-shared-view (& seen))
                  (ast.ast-place-shared-view stdlib-roots)
                  (clone manifest-dir)
                  (ast.ast-place-shared-view deps)
                  (sym_i64_env.sym-i64-shared-view (& cfgs)))
                  [(ResultCompilerLoadWithPaths.Ok
                      rest-decls
                      rest-paths
                      rest-modules
                      rest-seen)
                    (ResultCompilerLoadWithPaths.Ok
                      (compiler-load-decl-list-prepend-from-source
                        expanded
                        (ast.ast-place-shared-view decls)
                        rest-decls)
                      (ast.ast-decl-path-list-prepend-builder-with-owner-id
                        (clone importer-path)
                        importer-path-id
                        rest-paths)
                      (ast.ast-decl-module-list-prepend-builder-id
                        importer-module-id
                        rest-modules)
                      rest-seen)]
                  [(ResultCompilerLoadWithPaths.Err diag)
                    (ResultCompilerLoadWithPaths.Err diag)])]
              [(ResultCompilerLoadInclude.Err diag)
                (ResultCompilerLoadWithPaths.Err diag)])]
          [(ast.AstDecl.IncludeStrLzss name include-path)
            (match (compiler-load-package-expand-include-str-lzss
              (clone importer-path)
              include-path
              name
              (ast.ast-place-shared-view stdlib-roots)
              (clone manifest-dir)
              (ast.ast-place-shared-view deps))
              [(ResultCompilerLoadInclude.Ok expanded)
                (match (compiler-load-package-decls-with-module-and-roots
                  (ast.ast-place-shared-view rest)
                  (clone importer-path)
                  importer-path-id
                  importer-module
                  importer-module-id
                  (clone importer-source-module)
                  importer-source-module-id
                  (sym_i64_env.sym-i64-shared-view (& seen))
                  (ast.ast-place-shared-view stdlib-roots)
                  (clone manifest-dir)
                  (ast.ast-place-shared-view deps)
                  (sym_i64_env.sym-i64-shared-view (& cfgs)))
                  [(ResultCompilerLoadWithPaths.Ok
                      rest-decls
                      rest-paths
                      rest-modules
                      rest-seen)
                    (ResultCompilerLoadWithPaths.Ok
                      (ast.ast-decl-list-prepend-builder expanded rest-decls)
                      (ast.ast-decl-path-list-prepend-builder-with-owner-id
                        (clone importer-path)
                        importer-path-id
                        rest-paths)
                      (ast.ast-decl-module-list-prepend-builder-id
                        importer-module-id
                        rest-modules)
                      rest-seen)]
                  [(ResultCompilerLoadWithPaths.Err diag)
                    (ResultCompilerLoadWithPaths.Err diag)])]
              [(ResultCompilerLoadInclude.Err diag)
                (ResultCompilerLoadWithPaths.Err diag)])]
          [(ast.AstDecl.IncludeBin name include-path)
            (match (compiler-load-package-expand-include-bin
              (clone importer-path)
              include-path
              name
              (ast.ast-place-shared-view stdlib-roots)
              (clone manifest-dir)
              (ast.ast-place-shared-view deps))
              [(ResultCompilerLoadInclude.Ok expanded)
                (match (compiler-load-package-decls-with-module-and-roots
                  (ast.ast-place-shared-view rest)
                  (clone importer-path)
                  importer-path-id
                  importer-module
                  importer-module-id
                  (clone importer-source-module)
                  importer-source-module-id
                  (sym_i64_env.sym-i64-shared-view (& seen))
                  (ast.ast-place-shared-view stdlib-roots)
                  (clone manifest-dir)
                  (ast.ast-place-shared-view deps)
                  (sym_i64_env.sym-i64-shared-view (& cfgs)))
                  [(ResultCompilerLoadWithPaths.Ok
                      rest-decls
                      rest-paths
                      rest-modules
                      rest-seen)
                    (ResultCompilerLoadWithPaths.Ok
                      (compiler-load-decl-list-prepend-from-source
                        expanded
                        decls
                        rest-decls)
                      (ast.ast-decl-path-list-prepend-builder-with-owner-id
                        (clone importer-path)
                        importer-path-id
                        rest-paths)
                      (ast.ast-decl-module-list-prepend-builder-id
                        importer-module-id
                        rest-modules)
                      rest-seen)]
                  [(ResultCompilerLoadWithPaths.Err diag)
                    (ResultCompilerLoadWithPaths.Err diag)])]
              [(ResultCompilerLoadInclude.Err diag)
                (ResultCompilerLoadWithPaths.Err diag)])]
          [_
            (match (compiler-load-package-decls-with-module-and-roots
              (ast.ast-place-shared-view rest)
              (clone importer-path)
              importer-path-id
              importer-module
              importer-module-id
              (clone importer-source-module)
              importer-source-module-id
              (sym_i64_env.sym-i64-shared-view (& seen))
              (ast.ast-place-shared-view stdlib-roots)
              (clone manifest-dir)
              (ast.ast-place-shared-view deps)
              (sym_i64_env.sym-i64-shared-view (& cfgs)))
              [(ResultCompilerLoadWithPaths.Ok
                  rest-decls
                  rest-paths
                  rest-modules
                  rest-seen)
                (ResultCompilerLoadWithPaths.Ok
                  (compiler-load-decl-list-prepend-from-source
                    decl
                    (ast.ast-place-shared-view decls)
                    rest-decls)
                  (ast.ast-decl-path-list-prepend-builder-with-owner-id
                    (clone importer-path)
                    importer-path-id
                    rest-paths)
                  (ast.ast-decl-module-list-prepend-builder-id
                    importer-module-id
                    rest-modules)
                  rest-seen)]
              [(ResultCompilerLoadWithPaths.Err diag)
                (ResultCompilerLoadWithPaths.Err diag)])]))]))

(define (compiler-load-package-program-with-paths-and-roots-expect-fallback
  [path : String]
  [program : ast.AstProgram]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : svec.Vec]
  [expected-module : ast.AstMaybeModuleName]
  [manifest-dir : String]
  [deps : CompilerPkgDeps]
  [cfgs : sym_i64_env.SymI64Env]
  [module-id-fallback : String]
  [parse-identity : CompilerLoadParseIdentity]
  [source-module-fallback : String]
  [source-module-fallback-id : i64]) : ResultCompilerLoadWithPaths
  (let
    [load-state : CompilerLoadSessionState
      (compiler-load-active-session-state-shared-view)]
    [entry-depth : i64 (array-ref load-state.surface-summary-load-depth 0)]
    [_ : unit (compiler-load-surface-summary-load-enter!)]
    [source-path-id : i64 parse-identity.source-path-id]
    [module-id-fallback-id : i64 parse-identity.module-fallback-id]
    [source-path : String (ci.intern-str source-path-id)]
    [loaded : ResultCompilerLoadWithPaths
      (match program
        [(ast.AstProgram.Program decls-box)
          (let
            [decls : ast.AstDeclList
              (ast.ast-decl-list-box-shared-view decls-box)]
            [effective-source-module-fallback : String
              (if (> (string.string-length source-module-fallback) 0)
                source-module-fallback
                (if (compiler-load-stdlib-source-module-import?
                  (compiler-load-normalize-path path))
                  module-id-fallback
                  ""))]
            [source-module : String
              (compiler-load-decls-source-module-or
                (ast.ast-place-shared-view decls)
                (clone effective-source-module-fallback))]
            [source-module-id : i64
              (if (compiler-load-decl-list-has-module?
                (ast.ast-place-shared-view decls))
                (compiler-load-decls-source-module-id
                  (ast.ast-place-shared-view decls))
                (if (>
                  (string.string-length effective-source-module-fallback)
                  0)
                  (if (> (string.string-length source-module-fallback) 0)
                    source-module-fallback-id
                    module-id-fallback-id)
                  cbi.compiler-builtin-id-fix-empty))]
            [load-decls : ast.AstDeclList
              (compiler-load-contextual-moduleless-decls
                (ast.ast-place-shared-view decls)
                (clone source-module)
                source-module-id)]
            (match (compiler-load-decls-module-id-with-fallback
              (clone source-path)
              (ast.ast-place-shared-view decls)
              (clone module-id-fallback)
              module-id-fallback-id)
              [(ResultCompilerLoadModuleId.Ok module-id module-name-id)
                (match (compiler-load-check-expected-module
                  (clone source-path)
                  (clone expected-module)
                  (clone module-id)
                  module-name-id)
                  [(ResultCompilerLoadModuleId.Ok _ _)
                    (if (compiler-load-seen-module-contains?
                      (sym_i64_env.sym-i64-shared-view (& seen))
                      (clone module-id)
                      module-name-id)
                      (compiler-load-seen-module-with-paths
                        (clone source-path)
                        source-path-id
                        (clone module-id)
                        module-name-id
                        (ast.ast-place-shared-view load-decls)
                        (sym_i64_env.sym-i64-shared-view (& seen)))
                      (match (compiler-load-check-dotted-import-aliases
                        (clone source-path)
                        (ast.ast-place-shared-view load-decls)
                        (clone source-module))
                        [(ResultCompilerLoadAliasCheck.Ok)
                          (begin
                            ;; Replace a speculative lazy summary with the
                            ;; identity established by the actual load.
                            (compiler-load-surface-summary-remove-source!
                              source-path-id)
                            (compiler-load-record-surface-summary!
                              (compiler-load-surface-summary-from-decls
                                (clone source-path)
                                source-path-id
                                (clone manifest-dir)
                                module-name-id
                                source-module-id
                                (compiler-load-decl-list-has-module?
                                  (ast.ast-place-shared-view decls))
                                (not
                                  (compiler-load-no-expected-module?
                                    (clone expected-module)))
                                (ast.ast-place-shared-view load-decls)))
                            (compiler-load-package-decls-with-module-and-roots
                              (ast.ast-place-shared-view load-decls)
                              (clone source-path)
                              source-path-id
                              (clone module-id)
                              module-name-id
                              (clone source-module)
                              source-module-id
                              (compiler-load-seen-module-bind
                                (sym_i64_env.sym-i64-shared-view (& seen))
                                (clone module-id)
                                module-name-id)
                              (ast.ast-place-shared-view stdlib-roots)
                              (clone manifest-dir)
                              (ast.ast-place-shared-view deps)
                              (sym_i64_env.sym-i64-shared-view (& cfgs))))]
                        [(ResultCompilerLoadAliasCheck.Err diag)
                          (ResultCompilerLoadWithPaths.Err diag)]))]
                  [(ResultCompilerLoadModuleId.Err diag)
                    (ResultCompilerLoadWithPaths.Err diag)])]
              [(ResultCompilerLoadModuleId.Err diag)
                (ResultCompilerLoadWithPaths.Err diag)]))])]
    (begin
      (compiler-load-surface-summary-load-exit!)
      (if (= entry-depth 0)
        (match loaded
          [(ResultCompilerLoadWithPaths.Ok decls paths modules loaded-seen)
            (match (compiler-load-check-unqualified-import-collisions
              (owned_view.compiler-owned-shared-view source-path)
              (ast.ast-place-shared-view decls)
              (ast.ast-place-shared-view paths))
              [(ResultCompilerLoadAliasCheck.Ok)
                (ResultCompilerLoadWithPaths.Ok decls paths modules loaded-seen)]
              [(ResultCompilerLoadAliasCheck.Err diag)
                (ResultCompilerLoadWithPaths.Err diag)])]
          [(ResultCompilerLoadWithPaths.Err diag)
            (ResultCompilerLoadWithPaths.Err diag)])
        loaded))))

(define (compiler-load-package-program-with-paths-and-roots-expect
  [path : String]
  [program : ast.AstProgram]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : svec.Vec]
  [expected-module : ast.AstMaybeModuleName]
  [manifest-dir : String]
  [deps : CompilerPkgDeps]
  [cfgs : sym_i64_env.SymI64Env]
  [parse-identity : CompilerLoadParseIdentity]) : ResultCompilerLoadWithPaths
  (compiler-load-package-program-with-paths-and-roots-expect-fallback
    (clone path)
    program
    seen
    stdlib-roots
    expected-module
    manifest-dir
    deps
    cfgs
    (compiler-load-canonical-module-id-from-path path)
    parse-identity
    ""
    cbi.compiler-builtin-id-fix-empty))

(define (compiler-load-package-file-with-paths-and-roots-expect-cache-current-fallback
  [path : String]
  [source-path-id : i64]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : svec.Vec]
  [expected-module : ast.AstMaybeModuleName]
  [manifest-dir : String]
  [deps : CompilerPkgDeps]
  [cfgs : sym_i64_env.SymI64Env]
  [cache-current : bool]
  [module-id-fallback : String]
  [source-module-fallback : String]
  [source-module-fallback-id-hint : i64]) : ResultCompilerLoadWithPaths
  (let
    [parse-cfgs : sym_i64_env.SymI64Env cfgs]
    [parse-identity : CompilerLoadParseIdentity
      (CompilerLoadParseIdentity
        source-path-id
        (compiler-load-module-fallback-id-for-parse
          (clone module-id-fallback)
          (clone expected-module))
        cbi.compiler-builtin-id-fix-empty)]
    [module-id-fallback-id : i64 parse-identity.module-fallback-id]
    [source-module-fallback-id : i64
      (cond
        [(>= source-module-fallback-id-hint 0) source-module-fallback-id-hint]
        [(= (string.string-length source-module-fallback) 0)
          cbi.compiler-builtin-id-fix-empty]
        [(string.eq source-module-fallback module-id-fallback)
          module-id-fallback-id]
        [else (compiler-load-parse-context-name-id source-module-fallback)])]
    (if (io.file-exists? (clone path))
      (match (if cache-current
        (compiler-load-parse-file-diagnostic-session-id
          (clone path)
          source-path-id
          (ast.ast-place-shared-view stdlib-roots)
          (sym_i64_env.sym-i64-shared-view (& parse-cfgs)))
        (compiler-load-parse-file-diagnostic-escaping
          (clone path)
          (sym_i64_env.sym-i64-shared-view (& parse-cfgs))))
        [(parser.ResultAstProgramDiagnostic.Ok program)
          (compiler-load-package-program-with-paths-and-roots-expect-fallback
            (clone path)
            program
            (sym_i64_env.sym-i64-shared-view (& seen))
            (ast.ast-place-shared-view stdlib-roots)
            (clone expected-module)
            (clone manifest-dir)
            (ast.ast-place-shared-view deps)
            (sym_i64_env.sym-i64-shared-view (& parse-cfgs))
            (clone module-id-fallback)
            (clone parse-identity)
            (clone source-module-fallback)
            source-module-fallback-id)]
        [(parser.ResultAstProgramDiagnostic.Err diag)
          (ResultCompilerLoadWithPaths.Err diag)])
      (match (compiler-load-embedded-stdlib-source-for-path (clone path))
        [(ces.CompilerEmbeddedStdlibSource.CompilerEmbeddedStdlibSomeSource
            source)
          (match (if cache-current
            (compiler-load-parse-embedded-source-diagnostic-session-id
              (clone path)
              source-path-id
              (clone source)
              (sym_i64_env.sym-i64-shared-view (& parse-cfgs)))
            (compiler-load-parse-source-diagnostic-escaping
              (clone path)
              source
              (sym_i64_env.sym-i64-shared-view (& parse-cfgs))))
            [(parser.ResultAstProgramDiagnostic.Ok program)
              (compiler-load-package-program-with-paths-and-roots-expect-fallback
                (clone path)
                program
                (sym_i64_env.sym-i64-shared-view (& seen))
                (ast.ast-place-shared-view stdlib-roots)
                (clone expected-module)
                (clone manifest-dir)
                (ast.ast-place-shared-view deps)
                (sym_i64_env.sym-i64-shared-view (& parse-cfgs))
                (clone module-id-fallback)
                (clone parse-identity)
                (clone source-module-fallback)
                source-module-fallback-id)]
            [(parser.ResultAstProgramDiagnostic.Err diag)
              (ResultCompilerLoadWithPaths.Err diag)])]
        [(ces.CompilerEmbeddedStdlibSource.CompilerEmbeddedStdlibNoSource)
          (ResultCompilerLoadWithPaths.Err
            (box
              (cdiag.compiler-diagnostic-at-start
                (clone path)
                (str_cat.str-cat "compiler-load: cannot read import " path))))]))))

(define (compiler-load-package-file-with-paths-and-roots-expect-cache-current
  [path : String]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : svec.Vec]
  [expected-module : ast.AstMaybeModuleName]
  [manifest-dir : String]
  [deps : CompilerPkgDeps]
  [cfgs : sym_i64_env.SymI64Env]
  [cache-current : bool]) : ResultCompilerLoadWithPaths
  (compiler-load-package-file-with-paths-and-roots-expect-cache-current-fallback
    (clone path)
    (compiler-load-source-path-id path)
    seen
    stdlib-roots
    expected-module
    manifest-dir
    deps
    cfgs
    cache-current
    (compiler-load-canonical-module-id-from-path path)
    ""
    cbi.compiler-builtin-id-fix-empty))

(define (compiler-load-package-file-with-paths-and-roots-expect
  [path : String]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : svec.Vec]
  [expected-module : ast.AstMaybeModuleName]
  [manifest-dir : String]
  [deps : CompilerPkgDeps]
  [cfgs : sym_i64_env.SymI64Env]) : ResultCompilerLoadWithPaths
  (compiler-load-package-file-with-paths-and-roots-expect-cache-current
    path
    seen
    stdlib-roots
    expected-module
    manifest-dir
    deps
    cfgs
    true))

(define (compiler-load-package-file-with-paths-and-roots
  [path : String]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : svec.Vec]
  [manifest-dir : String]
  [deps : CompilerPkgDeps]) : ResultCompilerLoadWithPaths
  (compiler-load-package-file-with-paths-and-roots-expect
    path
    seen
    stdlib-roots
    ast.AstMaybeModuleName.No
    manifest-dir
    deps
    (parser.compiler-cfg-empty)))

(define (compiler-load-package-file-with-paths-and-roots-cfg
  [path : String]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : svec.Vec]
  [manifest-dir : String]
  [deps : CompilerPkgDeps]
  [cfgs : sym_i64_env.SymI64Env]) : ResultCompilerLoadWithPaths
  (compiler-load-package-file-with-paths-and-roots-expect
    path
    seen
    stdlib-roots
    ast.AstMaybeModuleName.No
    manifest-dir
    deps
    cfgs))

(define (compiler-load-package-entry-file-with-paths-and-roots-cfg
  [path : String]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : svec.Vec]
  [manifest-dir : String]
  [deps : CompilerPkgDeps]
  [cfgs : sym_i64_env.SymI64Env]) : ResultCompilerLoadWithPaths
  (compiler-load-package-file-with-paths-and-roots-expect-cache-current
    path
    seen
    stdlib-roots
    ast.AstMaybeModuleName.No
    manifest-dir
    deps
    cfgs
    false))

(define (compiler-load-package-stdlib-prelude-source-with-roots-cfg
  [path : String]
  [source : String]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : svec.Vec]
  [manifest-dir : String]
  [deps : CompilerPkgDeps]
  [cfgs : sym_i64_env.SymI64Env]) : ResultCompilerLoadWithPaths
  (let
    [parse-cfgs : sym_i64_env.SymI64Env cfgs]
    [parse-identity : CompilerLoadParseIdentity
      (compiler-load-parse-identity
        (clone path)
        (compiler-load-canonical-module-id-from-path path)
        ast.AstMaybeModuleName.No)]
    (match (compiler-load-parse-source-diagnostic-escaping
      (clone path)
      source
      (sym_i64_env.sym-i64-shared-view (& parse-cfgs)))
      [(parser.ResultAstProgramDiagnostic.Ok program)
        (compiler-load-package-program-with-paths-and-roots-expect
          path
          program
          seen
          stdlib-roots
          ast.AstMaybeModuleName.No
          manifest-dir
          deps
          parse-cfgs
          parse-identity)]
      [(parser.ResultAstProgramDiagnostic.Err diag)
        (ResultCompilerLoadWithPaths.Err diag)])))

(define (compiler-load-package-stdlib-prelude-file-with-roots-cfg
  [path : String]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : svec.Vec]
  [manifest-dir : String]
  [deps : CompilerPkgDeps]
  [cfgs : sym_i64_env.SymI64Env]) : ResultCompilerLoadWithPaths
  (let
    [suffix : String (compiler-load-stdlib-suffix path)]
    (match (compiler-load-resolve-stdlib-root
      (clone suffix)
      (ast.ast-place-shared-view stdlib-roots))
      [(CompilerLoadSomePath source-path)
        (begin
          (compiler-load-note-embedded-equivalent-if-matching!
            suffix
            (clone source-path))
          (compiler-load-package-stdlib-prelude-source-with-roots-cfg
            (clone path)
            (compiler-load-read-file-text source-path)
            (sym_i64_env.sym-i64-shared-view (& seen))
            (ast.ast-place-shared-view stdlib-roots)
            (clone manifest-dir)
            (ast.ast-place-shared-view deps)
            (sym_i64_env.sym-i64-shared-view (& cfgs))))]
      [(CompilerLoadNoPath)
        (match (compiler-load-embedded-stdlib-source suffix)
          [(ces.CompilerEmbeddedStdlibSource.CompilerEmbeddedStdlibSomeSource
              source)
            (begin
              (compiler-load-note-embedded-module! (clone path))
              (compiler-load-session-note-embedded-stdlib-source!)
              (compiler-load-package-stdlib-prelude-source-with-roots-cfg
                (clone path)
                source
                (sym_i64_env.sym-i64-shared-view (& seen))
                (ast.ast-place-shared-view stdlib-roots)
                (clone manifest-dir)
                (ast.ast-place-shared-view deps)
                (sym_i64_env.sym-i64-shared-view (& cfgs))))]
          [(ces.CompilerEmbeddedStdlibSource.CompilerEmbeddedStdlibNoSource)
            (compiler-load-package-file-with-paths-and-roots-cfg
              path
              seen
              stdlib-roots
              manifest-dir
              deps
              cfgs)])])))

(define (compiler-load-package-core-macro-prelude-with-roots-cfg
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : svec.Vec]
  [manifest-dir : String]
  [deps : CompilerPkgDeps]
  [cfgs : sym_i64_env.SymI64Env]) : ResultCompilerLoadWithPaths
  (compiler-load-append-root-module-marker
    (compiler-load-package-stdlib-prelude-file-with-roots-cfg
      (string.copy (& compiler-load-core-macro-prelude-path))
      seen
      stdlib-roots
      manifest-dir
      deps
      cfgs)))

(define (compiler-load-package-file-with-runtime-cfg-inner
  [input-path : String]
  [stdlib-roots : svec.Vec]
  [manifest-dir : String]
  [deps : CompilerPkgDeps]
  [emit-entry : bool]
  [cfgs : sym_i64_env.SymI64Env]) : ResultCompilerLoadWithPaths
  (if emit-entry
    (match (compiler-load-package-stdlib-prelude-file-with-roots-cfg
      (string.copy (& compiler-load-runtime-prelude-path))
      (sym_i64_env.sym-i64-empty)
      (ast.ast-place-shared-view stdlib-roots)
      (clone manifest-dir)
      (ast.ast-place-shared-view deps)
      (sym_i64_env.sym-i64-shared-view (& cfgs)))
      [(ResultCompilerLoadWithPaths.Ok
          runtime-decls
          runtime-paths
          runtime-modules
          runtime-seen)
        (match (compiler-load-package-core-macro-prelude-with-roots-cfg
          (sym_i64_env.sym-i64-shared-view (& runtime-seen))
          (ast.ast-place-shared-view stdlib-roots)
          (clone manifest-dir)
          (ast.ast-place-shared-view deps)
          (sym_i64_env.sym-i64-shared-view (& cfgs)))
          [(ResultCompilerLoadWithPaths.Ok
              macro-decls
              macro-paths
              macro-modules
              prelude-seen)
            (match (compiler-load-package-entry-file-with-paths-and-roots-cfg
              (clone input-path)
              prelude-seen
              (ast.ast-place-shared-view stdlib-roots)
              (clone manifest-dir)
              (ast.ast-place-shared-view deps)
              (sym_i64_env.sym-i64-shared-view (& cfgs)))
              [(ResultCompilerLoadWithPaths.Ok
                  entry-decls
                  entry-paths
                  entry-modules
                  seen)
                (ResultCompilerLoadWithPaths.Ok
                  (compiler-load-decl-list-append
                    (compiler-load-decl-list-append runtime-decls macro-decls)
                    entry-decls)
                  (compiler-load-decl-path-list-append
                    (compiler-load-decl-path-list-append
                      runtime-paths
                      macro-paths)
                    entry-paths)
                  (compiler-load-decl-module-list-append
                    (compiler-load-decl-module-list-append
                      runtime-modules
                      macro-modules)
                    entry-modules)
                  seen)]
              [(ResultCompilerLoadWithPaths.Err diag)
                (ResultCompilerLoadWithPaths.Err diag)])]
          [(ResultCompilerLoadWithPaths.Err diag)
            (ResultCompilerLoadWithPaths.Err diag)])]
      [(ResultCompilerLoadWithPaths.Err diag)
        (ResultCompilerLoadWithPaths.Err diag)])
    (match (compiler-load-package-core-macro-prelude-with-roots-cfg
      (sym_i64_env.sym-i64-empty)
      (ast.ast-place-shared-view stdlib-roots)
      (clone manifest-dir)
      (ast.ast-place-shared-view deps)
      (sym_i64_env.sym-i64-shared-view (& cfgs)))
      [(ResultCompilerLoadWithPaths.Ok
          prelude-decls
          prelude-paths
          prelude-modules
          prelude-seen)
        (match (compiler-load-package-entry-file-with-paths-and-roots-cfg
          input-path
          prelude-seen
          stdlib-roots
          manifest-dir
          deps
          cfgs)
          [(ResultCompilerLoadWithPaths.Ok
              entry-decls
              entry-paths
              entry-modules
              seen)
            (ResultCompilerLoadWithPaths.Ok
              (compiler-load-decl-list-append prelude-decls entry-decls)
              (compiler-load-decl-path-list-append prelude-paths entry-paths)
              (compiler-load-decl-module-list-append
                prelude-modules
                entry-modules)
              seen)]
          [(ResultCompilerLoadWithPaths.Err diag)
            (ResultCompilerLoadWithPaths.Err diag)])]
      [(ResultCompilerLoadWithPaths.Err diag)
        (ResultCompilerLoadWithPaths.Err diag)])))

(define (compiler-load-dependency-surfaces-restore-base!
  [surface-state : (& surface-state CompilerLoadDependencySurfaceState)]) : unit
  (match (array-ref surface-state.base-facts 0)
    [(CompilerLoadDependencySurfaceBaseFacts.None)
      (surface_facts.surface-typecheck-facts-clear!)]
    [(CompilerLoadDependencySurfaceBaseFacts.Some facts)
      (if (surface_facts.surface-typecheck-facts-publish! (clone facts))
        unit
        (surface_facts.surface-typecheck-facts-clear!))]))

(define (compiler-load-dependency-surfaces-finalize!
  [state : (& state CompilerLoadSessionState)]
  [loaded : ResultCompilerLoadWithPaths]) : ResultCompilerLoadWithPaths
  (let
    [surface-state : (& state CompilerLoadDependencySurfaceState)
      (& state.dependency-surfaces)]
    [surface-count : i64 (array-ref surface-state.surface-decl-count 0)]
    (match loaded
      [(ResultCompilerLoadWithPaths.Err diag)
        (begin
          (compiler-load-dependency-surfaces-restore-base! surface-state)
          (ResultCompilerLoadWithPaths.Err diag))]
      [(ResultCompilerLoadWithPaths.Ok decls paths modules seen)
        (if (or (not (array-ref surface-state.enabled 0)) (<= surface-count 0))
          (begin
            (compiler-load-dependency-surfaces-restore-base! surface-state)
            (ResultCompilerLoadWithPaths.Ok decls paths modules seen))
          (match (surface_facts.surface-typecheck-facts-builder-finish
            (clone (array-ref surface-state.facts-builder 0)))
            [(surface_facts.ResultSurfaceTypecheckFacts.Err _)
              (begin
                (compiler-load-dependency-surfaces-restore-base! surface-state)
                (ResultCompilerLoadWithPaths.Ok decls paths modules seen))]
            [(surface_facts.ResultSurfaceTypecheckFacts.Ok composed)
              (let
                [candidate : surface_facts.SurfaceTypecheckFacts
                  (surface_facts.SurfaceTypecheckFacts
                    composed.macro-prefix-decl-count
                    composed.prefix-decl-count
                    composed.summary-values
                    composed.summary-functions
                    composed.summary-externs
                    composed.clone-decl-keys
                    composed.clone-root-keys
                    composed.clone-call-indices)]
                [published : bool
                  (surface_facts.surface-typecheck-facts-publish-composite!
                    candidate)]
                (begin
                  (if published
                    unit
                    (compiler-load-dependency-surfaces-restore-base!
                      surface-state))
                  (ResultCompilerLoadWithPaths.Ok decls paths modules seen)))]))])))

(define (compiler-load-package-file-with-runtime-cfg
  [input-path : String]
  [stdlib-roots : svec.Vec]
  [manifest-dir : String]
  [deps : CompilerPkgDeps]
  [emit-entry : bool]
  [cfgs : sym_i64_env.SymI64Env]) : ResultCompilerLoadWithPaths
  (let
    [state : CompilerLoadSessionState
      (compiler-load-active-session-state-shared-view)]
    [_surface-preflight : bool
      (compiler-load-dependency-surfaces-prepare!
        (compiler-load-global-shared-view state)
        (ast.ast-place-shared-view stdlib-roots)
        (sym_i64_env.sym-i64-shared-view (& cfgs)))]
    [loaded : ResultCompilerLoadWithPaths
      (compiler-load-package-file-with-runtime-cfg-inner
        input-path
        stdlib-roots
        manifest-dir
        deps
        emit-entry
        cfgs)]
    (compiler-load-dependency-surfaces-finalize! (& state) loaded)))

(define (compiler-load-decl-list-count [decls : (& decls ast.AstDeclList)]) : i64
  (ast.ast-decl-list-len decls))

(define (compiler-load-decl-list-value-name-count
  [decls : ast.AstDeclList]
  [want : String]) : i64
  (match (ast.ast-decl-list-step decls)
    [(ast.AstDeclListStep.Nil) 0]
    [(ast.AstDeclListStep.Cons decl rest)
      (+
        (match decl
          [(ast.AstDecl.Def _ name _ _)
            (if (string.eq (ci.intern-str name) want)
              1
              0)]
          [_ 0])
        (compiler-load-decl-list-value-name-count rest want))]))

(define (compiler-load-first-string-def?
  [decls : ast.AstDeclList]
  [name : String]
  [want : String]) : bool
  (match (ast.ast-decl-list-step decls)
    [(ast.AstDeclListStep.Cons
        (ast.AstDecl.Def
          _
          got
          (ast.AstMaybeType.Some (ast.AstType.String))
          value-box)
        _)
      (let
        [value : ast.AstExpr (ast.ast-node-get value-box)]
        (match value
          [(ast.AstExpr.Literal (ast.AstLiteral.String string-id))
            (and
              (string.eq (ci.intern-str got) name)
              (string.eq (ci.intern-str string-id) want))]
          [_ false]))]
    [_ false]))

(define (compiler-load-first-string-macro?
  [decls : ast.AstDeclList]
  [name : String]
  [want : String]) : bool
  (match (ast.ast-decl-list-step decls)
    [(ast.AstDeclListStep.Cons
        (ast.AstDecl.DefMacro _ got params (ast.AstType.String) body-box)
        _)
      (match (ast.ast-node-get body-box)
        [(ast.AstExpr.Call callee-box args)
          (and
            (string.eq (ci.intern-str got) name)
            (= (ast.ast-macro-param-list-len (& params)) 0)
            (match (ast.ast-node-get callee-box)
              [(ast.AstExpr.Var callee)
                (string.eq (ci.intern-str callee) "expr-string")]
              [_ false])
            (= (ast.ast-expr-list-len (& args)) 1)
            (match (ast.ast-node-get (ast.ast-expr-list-get (& args) 0 0))
              [(ast.AstExpr.Literal (ast.AstLiteral.String text))
                (string.eq (ci.intern-str text) want)]
              [_ false]))]
        [_ false])]
    [_ false]))

(define (compiler-load-first-lzss-def?
  [decls : ast.AstDeclList]
  [name : String]
  [want-source : String]) : bool
  (match (ast.ast-decl-list-step decls)
    [(ast.AstDeclListStep.Cons
        (ast.AstDecl.Def
          _
          got
          (ast.AstMaybeType.Some (ast.AstType.DynArray elem-id))
          value-box)
        _)
      (match (ast.ast-node-get value-box)
        [(ast.AstExpr.BinaryData bytes)
          (and
            (string.eq (ci.intern-str got) name)
            (match (ast.ty-node-get elem-id)
              [(ast.AstType.U8) true]
              [_ false])
            (string.eq
              bytes
              (ctfe.ctfe-embedded-stdlib-binary-data-bytes want-source)))]
        [_ false])]
    [_ false]))

(define (compiler-load-binary-payload-ok? [text : String]) : bool
  (and
    (= (string.string-length text) 6)
    (= (compiler-load-char-code-at text 0) 0)
    (= (compiler-load-char-code-at text 1) 65)
    (= (compiler-load-char-code-at text 2) 127)
    (= (compiler-load-char-code-at text 3) 128)
    (= (compiler-load-char-code-at text 4) 255)
    (= (compiler-load-char-code-at text 5) 10)))

(define (compiler-load-first-bin-def? [decls : ast.AstDeclList] [name : String]) : bool
  (match (ast.ast-decl-list-step decls)
    [(ast.AstDeclListStep.Cons
        (ast.AstDecl.Def
          _
          got
          (ast.AstMaybeType.Some (ast.AstType.DynArray elem-id))
          value-box)
        _)
      (let
        [value : ast.AstExpr (ast.ast-node-get value-box)]
        [elem : ast.AstType (ast.ty-node-get elem-id)]
        (match value
          [(ast.AstExpr.BinaryData text)
            (and
              (string.eq (ci.intern-str got) name)
              (match elem
                [(ast.AstType.U8) true]
                [_ false])
              (compiler-load-binary-payload-ok? text))]
          [_ false]))]
    [_ false]))

(define (compiler-load-binary-fixture) : String
  (let
    [bytes : (__tl_dyn-array u8) (__tl_make-array u8 6)]
    (begin
      (set! (array-ref bytes 0) (cast 0 : u8))
      (set! (array-ref bytes 1) (cast 65 : u8))
      (set! (array-ref bytes 2) (cast 127 : u8))
      (set! (array-ref bytes 3) (cast 128 : u8))
      (set! (array-ref bytes 4) (cast 255 : u8))
      (set! (array-ref bytes 5) (cast 10 : u8))
      (unsafe
        (string-from-bytes (ptr-cast (__tl_array-data bytes) : (Ptr u8)) 6)))))

(define (compiler-load-decl-list-has-import-alias?
  [decls : ast.AstDeclList]
  [target-module : String]
  [target-alias : String]) : bool
  (match (ast.ast-decl-list-step decls)
    [(ast.AstDeclListStep.Nil) false]
    [(ast.AstDeclListStep.Cons decl rest)
      (let
        [rest : ast.AstDeclList rest]
        (match decl
          [(ast.AstDecl.Import
              decl-meta
              (ast.AstImportSpec.Spec
                _
                _
                (ast.AstMaybeModuleName.Some module-name)
                (ast.AstMaybeImportAlias.Some alias)
                _))
            (if (and
              (string.eq (ci.intern-str module-name) target-module)
              (string.eq (ci.intern-str alias) target-alias))
              true
              (compiler-load-decl-list-has-import-alias?
                rest
                target-module
                target-alias))]
          [_
            (compiler-load-decl-list-has-import-alias?
              rest
              target-module
              target-alias)]))]))

(define (compiler-load-unmoduled-import-restored-decls?
  [decls : ast.AstDeclList]) : bool
  (match (ast.ast-decl-list-step decls)
    [(ast.AstDeclListStep.Cons (ast.AstDecl.Module imported-module) rest1)
      (let
        [rest1 : ast.AstDeclList rest1]
        (match (ast.ast-decl-list-step rest1)
          [(ast.AstDeclListStep.Cons
              (ast.AstDecl.Def decl-meta imported-name _ _)
              rest2)
            (let
              [rest2 : ast.AstDeclList rest2]
              (match (ast.ast-decl-list-step rest2)
                [(ast.AstDeclListStep.Cons
                    (ast.AstDecl.Module restored-module)
                    rest3)
                  (let
                    [rest3 : ast.AstDeclList rest3]
                    (match (ast.ast-decl-list-step rest3)
                      [(ast.AstDeclListStep.Cons
                          (ast.AstDecl.Import
                            _
                            (ast.AstImportSpec.Spec
                              _
                              _
                              (ast.AstMaybeModuleName.Some alias-module)
                              (ast.AstMaybeImportAlias.Some alias-name)
                              _))
                          rest4)
                        (let
                          [rest4 : ast.AstDeclList rest4]
                          (match (ast.ast-decl-list-step rest4)
                            [(ast.AstDeclListStep.Cons
                                (ast.AstDecl.DefFn _ main-name _ _ _ _)
                                done-box)
                              (let
                                [done : ast.AstDeclList done-box]
                                (and
                                  (ast.ast-decl-list-empty? (& done))
                                  (string.eq
                                    (ci.intern-str imported-module)
                                    "cl_restore_dep")
                                  (string.eq
                                    (ci.intern-str imported-name)
                                    "dep-value")
                                  (string.eq (ci.intern-str restored-module) "")
                                  (string.eq
                                    (ci.intern-str alias-module)
                                    "cl_restore_dep")
                                  (string.eq (ci.intern-str alias-name) "dep")
                                  (string.eq (ci.intern-str main-name) "main")))]
                            [_ false]))]
                      [_ false]))]
                [_ false]))]
          [_ false]))]
    [_ false]))

(define (compiler-load-two-modules?
  [modules : ast.AstDeclModuleList]
  [want : String]) : bool
  (and
    (= (ast.ast-decl-module-list-len (& modules)) 2)
    (string.eq (ast.ast-decl-module-list-get (& modules) 0 "") want)
    (string.eq (ast.ast-decl-module-list-get (& modules) 1 "") want)))

(define (compiler-load-entry-cycle-module-name? [name : String]) : bool
  (or
    (string.eq name "compiler_load_entry")
    (string.eq name "compiler_load_dep")))

(define (compiler-load-entry-cycle-modules-loop
  [modules : ast.AstDeclModuleList]
  [count : i64]) : bool
  (if (>= count (ast.ast-decl-module-list-len (& modules)))
    (= count 10)
    (and
      (compiler-load-entry-cycle-module-name?
        (ast.ast-decl-module-list-get (& modules) count ""))
      (compiler-load-entry-cycle-modules-loop modules (+ count 1)))))

(define (compiler-load-entry-cycle-modules? [modules : ast.AstDeclModuleList]) : bool
  (compiler-load-entry-cycle-modules-loop modules 0))

(define (compiler-load-surface-maybe-string-eq?
  [maybe : (& maybe CompilerLoadSurfaceMaybeString)]
  [want : (& want str)]) : bool
  (match maybe
    [(CompilerLoadSurfaceSomeString got) (string.eq got want)]
    [(CompilerLoadSurfaceNoString) (string.eq want "")]))

(define (compiler-load-surface-import-kind-code
  [kind : CompilerLoadSurfaceImportKind]) : i64
  (match kind
    [(CompilerLoadSurfaceImportModule) 1]
    [(CompilerLoadSurfaceImportMacro) 2]
    [(CompilerLoadSurfaceImportMacroDecls) 3]))

(define (compiler-load-surface-decl-kind-code
  [kind : CompilerLoadSurfaceDeclKind]) : i64
  (match kind
    [(CompilerLoadSurfaceValue) 1]
    [(CompilerLoadSurfaceFunction) 2]
    [(CompilerLoadSurfaceExtern) 3]
    [(CompilerLoadSurfaceStruct) 4]
    [(CompilerLoadSurfaceEnum) 5]
    [(CompilerLoadSurfaceMacro) 6]
    [(CompilerLoadSurfaceDispatch) 7]
    [(CompilerLoadSurfaceTest) 8]
    [(CompilerLoadSurfaceIncludeStr) 9]
    [(CompilerLoadSurfaceIncludeBin) 10]
    [(CompilerLoadSurfaceIncludeStrComptime) 11]))

(define (compiler-load-surface-macro-result-kind-code
  [kind : CompilerLoadSurfaceMacroResultKind]) : i64
  (match kind
    [(CompilerLoadSurfaceMacroExpr) 1]
    [(CompilerLoadSurfaceMacroModule) 2]
    [(CompilerLoadSurfaceMacroDecls) 3]
    [(CompilerLoadSurfaceMacroOther) 4]))

(define (compiler-load-surface-import-kind-count
  [imports : (& imports CompilerLoadSurfaceImportList)]
  [kind-code : i64]) : i64
  (let
    [index : i64 0]
    [count : i64 0]
    (begin
      (while (< index (compiler-load-surface-import-list-count imports))
        (begin
          (if (=
            (compiler-load-surface-import-kind-code
              (__tl-project-field
                (compiler-load-surface-import-list-at imports index)
                kind))
            kind-code)
            (set! count (+ count 1))
            unit)
          (set! index (+ index 1))))
      count)))

(define (compiler-load-surface-import-has?
  [imports : (& imports CompilerLoadSurfaceImportList)]
  [kind-code : i64]
  [import-path : String]
  [alias : String]
  [default-alias : String]) : bool
  (let
    [index : i64 0]
    (begin
      (while (< index (compiler-load-surface-import-list-count imports))
        (let
          [import-edge : CompilerLoadSurfaceImport
            (compiler-load-surface-import-list-at imports index)]
          (if (and
            (=
              (compiler-load-surface-import-kind-code import-edge.kind)
              kind-code)
            (string.eq import-edge.import-path import-path)
            (compiler-load-surface-maybe-string-eq? import-edge.alias alias)
            (compiler-load-surface-maybe-string-eq?
              import-edge.default-alias
              default-alias))
            (return true)
            (set! index (+ index 1)))))
      false)))

(define (compiler-load-surface-decl-kind-count
  [decls : (& decls CompilerLoadSurfaceDeclList)]
  [kind-code : i64]) : i64
  (let
    [index : i64 0]
    [count : i64 0]
    (begin
      (while (< index (compiler-load-surface-decl-list-count decls))
        (begin
          (if (=
            (compiler-load-surface-decl-kind-code
              (__tl-project-field
                (compiler-load-surface-decl-list-at decls index)
                kind))
            kind-code)
            (set! count (+ count 1))
            unit)
          (set! index (+ index 1))))
      count)))

(define (compiler-load-surface-decl-has?
  [decls : (& decls CompilerLoadSurfaceDeclList)]
  [kind-code : i64]
  [name : String]) : bool
  (let
    [index : i64 0]
    (begin
      (while (< index (compiler-load-surface-decl-list-count decls))
        (let
          [decl : CompilerLoadSurfaceDecl
            (compiler-load-surface-decl-list-at decls index)]
          (if (and
            (= (compiler-load-surface-decl-kind-code decl.kind) kind-code)
            (string.eq (ci.intern-str decl.name) name))
            (return true)
            (set! index (+ index 1)))))
      false)))

(define (compiler-load-surface-decl-in-module?
  [decls : (& decls CompilerLoadSurfaceDeclList)]
  [name : String]
  [module : String]) : bool
  (let
    [index : i64 0]
    (begin
      (while (< index (compiler-load-surface-decl-list-count decls))
        (let
          [decl : CompilerLoadSurfaceDecl
            (compiler-load-surface-decl-list-at decls index)]
          (if (and
            (string.eq (ci.intern-str decl.name) name)
            (string.eq (ci.intern-str decl.module) module))
            (return true)
            (set! index (+ index 1)))))
      false)))

(define (compiler-load-surface-decl-generated?
  [decls : (& decls CompilerLoadSurfaceDeclList)]
  [name : String]) : bool
  (let
    [index : i64 0]
    (begin
      (while (< index (compiler-load-surface-decl-list-count decls))
        (let
          [decl : CompilerLoadSurfaceDecl
            (compiler-load-surface-decl-list-at decls index)]
          (if (and
            (string.eq (ci.intern-str decl.name) name)
            decl.has-generated-meta)
            (return true)
            (set! index (+ index 1)))))
      false)))

(define (compiler-load-surface-decl-unsafe?
  [decls : (& decls CompilerLoadSurfaceDeclList)]
  [name : String]) : bool
  (let
    [index : i64 0]
    (begin
      (while (< index (compiler-load-surface-decl-list-count decls))
        (let
          [decl : CompilerLoadSurfaceDecl
            (compiler-load-surface-decl-list-at decls index)]
          (if (and (string.eq (ci.intern-str decl.name) name) decl.was-unsafe)
            (return true)
            (set! index (+ index 1)))))
      false)))

(define (compiler-load-surface-decl-cleanup?
  [decls : (& decls CompilerLoadSurfaceDeclList)]
  [name : String]) : bool
  (let
    [index : i64 0]
    (begin
      (while (< index (compiler-load-surface-decl-list-count decls))
        (let
          [decl : CompilerLoadSurfaceDecl
            (compiler-load-surface-decl-list-at decls index)]
          (if (and (string.eq (ci.intern-str decl.name) name) decl.has-cleanup)
            (return true)
            (set! index (+ index 1)))))
      false)))

(define (compiler-load-surface-macro-result-count
  [decls : (& decls CompilerLoadSurfaceDeclList)]
  [result-code : i64]) : i64
  (let
    [index : i64 0]
    [count : i64 0]
    (begin
      (while (< index (compiler-load-surface-decl-list-count decls))
        (let
          [decl : CompilerLoadSurfaceDecl
            (compiler-load-surface-decl-list-at decls index)]
          (begin
            (if (and
              (= (compiler-load-surface-decl-kind-code decl.kind) 6)
              (=
                (compiler-load-surface-macro-result-kind-code decl.macro-result)
                result-code))
              (set! count (+ count 1))
              unit)
            (set! index (+ index 1)))))
      count)))

(define (compiler-load-surface-summary-smoke-source) : String
  (str_cat.str-cat
    "(module summary.mod)
(import dep.mod as dep)
(import stdlib.vector as vec)
(import (vec.vector i64) as vi64)
(cfg feature (import feature.mod as feat))
(emit-generated VecI64)
(define value : i64 1)
(define (pub [x : i64]) (:export-symbol \"pub\") : i64 x)
(extern (foreign [x : i64]) : i64)
(unsafe (extern (danger [x : i64]) : i64))
(defstruct Resource (:cleanup close-resource) (fd i64 (:cleanup close-fd)))
(defenum Maybe (:cleanup close-maybe) (None) (Some i64 (:cleanup close-i64)))
(defmacro (expr-m [x : Expr]) : Expr x)
(defmacro (module-m [T : type]) : Module (expr-unit))
(defmacro (decls-m [T : type]) : Decls (expr-unit))
(define generated-value : i64 3)
(module nested.summary
  (define nested-value : i64 4))
("
    "test loader-summary value)
(include-str text \"data.txt\")
(include-bin blob \"data.bin\")"))

(define (compiler-load-surface-summary-shape-ok?
  [summary : CompilerLoadSurfaceSummary]) : bool
  (let
    [imports : CompilerLoadSurfaceImportList summary.imports]
    [decls : CompilerLoadSurfaceDeclList summary.decls]
    (and
      (string.eq (ci.intern-str summary.module-id) "summary.mod")
      (string.eq summary.source-path "src/summary.tl")
      (string.eq summary.root-id "src")
      (= (compiler-load-surface-import-list-count imports) 5)
      (=
        (array-length imports.slots)
        (compiler-load-surface-import-list-count imports))
      (string.eq
        (__tl-project-field
          (compiler-load-surface-import-list-at imports 0)
          import-path)
        "dep.mod")
      (string.eq
        (ci.intern-str
          (__tl-project-field
            (compiler-load-surface-import-list-at imports 0)
            module))
        "summary.mod")
      (string.eq
        (__tl-project-field
          (compiler-load-surface-import-list-at imports 1)
          import-path)
        "stdlib.vector")
      (= (compiler-load-surface-import-kind-count imports 1) 3)
      (= (compiler-load-surface-import-kind-count imports 2) 1)
      (= (compiler-load-surface-import-kind-count imports 3) 1)
      (compiler-load-surface-import-has?
        imports
        1
        "stdlib.vector"
        "vec"
        "vector")
      (compiler-load-surface-import-has? imports 1 "feature.mod" "feat" "mod")
      (= (compiler-load-surface-decl-list-count decls) 14)
      (=
        (array-length decls.slots)
        (compiler-load-surface-decl-list-count decls))
      (string.eq
        (ci.intern-str
          (__tl-project-field (compiler-load-surface-decl-list-at decls 0) name))
        "value")
      (string.eq
        (ci.intern-str
          (__tl-project-field
            (compiler-load-surface-decl-list-at
              decls
              (- (compiler-load-surface-decl-list-count decls) 1))
            name))
        "blob")
      (= (compiler-load-surface-decl-kind-count decls 6) 3)
      (compiler-load-surface-decl-has? decls 1 "value")
      (compiler-load-surface-decl-has? decls 2 "pub")
      (compiler-load-surface-decl-has? decls 3 "foreign")
      (compiler-load-surface-decl-in-module?
        decls
        "nested-value"
        "nested.summary")
      (compiler-load-surface-decl-unsafe? decls "danger")
      (compiler-load-surface-decl-cleanup? decls "Resource")
      (compiler-load-surface-decl-cleanup? decls "Maybe")
      (compiler-load-surface-decl-generated? decls "generated-value")
      (= (compiler-load-surface-macro-result-count decls 1) 1)
      (= (compiler-load-surface-macro-result-count decls 2) 1)
      (= (compiler-load-surface-macro-result-count decls 3) 1)
      summary.has-tests
      summary.has-export-metadata
      summary.has-generated-decls
      summary.has-decl-emitting-macro
      (compiler-load-surface-summary-requires-eager?
        (ast.ast-place-shared-view summary)))))

(define (compiler-load-surface-mark-generated-value! [program : ast.AstProgram]) : bool
  (match program
    [(ast.AstProgram.Program decls-box)
      (let
        [decls : ast.AstDeclList (ast.ast-decl-list-box-shared-view decls-box)]
        [index : i64 0]
        [found : bool false]
        (begin
          (while (and (< index (ast.ast-decl-list-len (& decls))) (not found))
            (let
              [decl : ast.AstDecl
                (ast.ast-decl-list-get (& decls) index (ast.ast-decl-fallback))]
              (match (ast.ast-place-shared-view decl)
                [(ast.AstDecl.Def _ name _ _)
                  (if (string.eq (ci.intern-str name) "generated-value")
                    (let
                      [args : ast.AstExprList (ast.ast-expr-list-new)]
                      (begin
                        (ast.ast-expr-list-push
                          (&mut args)
                          (ast.ast-node-push
                            (ast.AstExpr.Literal
                              (ast.ast-lit-generated-string "i64"))))
                        (set!
                          (array-ref decls.slots (+ decls.offset index))
                          (ast.ast-decl-comptime-decl-with-meta
                            (ast.AstGeneratedDeclMeta.Some
                              "gen-family"
                              "generated-value"
                              args
                              "")
                            decl))
                        (set! found true)))
                    unit)]
                [_ unit])
              (set! index (+ index 1))))
          found))]))

(define (compiler-load-surface-summary-smoke-ok?) : bool
  (let
    [cfgs : sym_i64_env.SymI64Env
      (parser.compiler-cfg-enable (parser.compiler-cfg-empty) "feature")]
    [path : String "src\\summary.tl"]
    [parse-identity : CompilerLoadParseIdentity
      (compiler-load-parse-identity
        (clone path)
        "src.summary"
        ast.AstMaybeModuleName.No)]
    [source-path-id : i64 parse-identity.source-path-id]
    [fallback-id : i64 parse-identity.module-fallback-id]
    (match (compiler-load-parse-source-diagnostic-escaping
      (clone path)
      (compiler-load-surface-summary-smoke-source)
      cfgs)
      [(parser.ResultAstProgramDiagnostic.Ok program)
        (if (not
          (compiler-load-surface-mark-generated-value!
            (ast.ast-place-shared-view program)))
          false
          (match (compiler-load-surface-summary-build
            path
            source-path-id
            "src\\..\\src"
            program
            fallback-id
            false)
            [(ResultCompilerLoadSurfaceSummary.Ok summary)
              (compiler-load-surface-summary-shape-ok? summary)]
            [(ResultCompilerLoadSurfaceSummary.Err _) false]))]
      [(parser.ResultAstProgramDiagnostic.Err _) false])))

(define (compiler-load-normalize-ok?) : bool
  (and
    (string.eq
      (compiler-load-normalize-path "selfhost/./x/../compiler_load.tl")
      "selfhost/compiler_load.tl")
    (string.eq
      (compiler-load-normalize-path "target\\loader\\..\\dep.tl")
      "target/dep.tl")))

(define (compiler-load-canonical-module-id-ok?) : bool
  (and
    (string.eq
      (compiler-load-canonical-module-id-from-path "stdlib/array.tl")
      "stdlib.array")
    (string.eq
      (compiler-load-canonical-module-id-from-path "src\\compiler_intern.tl")
      "src.compiler_intern")
    (string.eq
      (compiler-load-canonical-module-id-from-import
        (ast.AstImportKind.Module)
        "stdlib.some_name"
        "target/ignored/some_name.tl")
      "stdlib.some_name")))

(define (compiler-load-test-seen-contains?
  [seen : (& seen sym_i64_env.SymI64Env)]
  [name : (& name str)]) : bool
  (sym_i64_env.sym-i64-contains-id
    seen
    (compiler-load-parse-context-name-id name)))

(define (compiler-load-source-provenance-ok?) : bool
  (match (compiler-load-source-with-paths
    "src/./main.tl"
    "(module app.main)
(define answer : i64 42)"
    (sym_i64_env.sym-i64-empty))
    [(ResultCompilerLoadWithPaths.Ok decls _ modules seen)
      (and
        (= (compiler-load-decl-list-count decls) 2)
        (compiler-load-two-modules? modules "app.main")
        (compiler-load-test-seen-contains? seen "app.main"))]
    [(ResultCompilerLoadWithPaths.Err _) false]))

(define (compiler-load-entry-moduled-main-ok?) : bool
  (and
    (compiler-load-package-entry-main?
      "src/app.tl"
      "src/app.tl"
      "app.main"
      "main")
    (compiler-load-package-entry-main?
      "src\\app.tl"
      "src/app.tl"
      "app.main"
      "main")
    (not
      (compiler-load-package-entry-main?
        "src/app.tl"
        "src/lib.tl"
        "app.main"
        "main"))
    (not
      (compiler-load-package-entry-main?
        "src/app.tl"
        "src/app.tl"
        "app.main"
        "helper"))))

(define (compiler-load-expected-module-conflict-ok?) : bool
  (match (compiler-load-source-with-paths-and-roots-expect
    "src/lib.tl"
    "(module lib.actual)
(define value : i64 1)"
    (sym_i64_env.sym-i64-empty)
    (svec.new)
    (ast.AstMaybeModuleName.Some (ci.intern-generated-name "lib.want")))
    [(ResultCompilerLoadWithPaths.Err diag)
      (string.eq
        (cdiag.compiler-diagnostic-message (__tl-box-place diag))
        "compiler-load: import expected module lib.want but loaded lib.actual")]
    [(ResultCompilerLoadWithPaths.Ok _ _ _ _) false]))

(define (compiler-load-duplicate-module-ok?) : bool
  (match (compiler-load-source
    "src/dup.tl"
    "(module dup.one)
(module dup.two)
(define value : i64 1)"
    (sym_i64_env.sym-i64-empty))
    [(ResultCompilerLoad.Err diag)
      (string.eq
        (cdiag.compiler-diagnostic-message (__tl-box-place diag))
        "compiler-load: duplicate module declaration")]
    [(ResultCompilerLoad.Ok _ _) false]))

(define (compiler-load-nested-module-body-ok?) : bool
  (match (compiler-load-source
    "src/nested_module.tl"
    "(module local.helper (define value : i64 1))
(define root-value : i64 2)"
    (sym_i64_env.sym-i64-empty))
    [(ResultCompilerLoad.Ok decls _)
      (match (ast.ast-decl-list-step decls)
        [(ast.AstDeclListStep.Cons (ast.AstDecl.Module nested-module) rest1)
          (let
            [rest1 : ast.AstDeclList rest1]
            (match (ast.ast-decl-list-step rest1)
              [(ast.AstDeclListStep.Cons
                  (ast.AstDecl.Def decl-meta value-name _ _)
                  rest2)
                (let
                  [rest2 : ast.AstDeclList rest2]
                  (match (ast.ast-decl-list-step rest2)
                    [(ast.AstDeclListStep.Cons
                        (ast.AstDecl.Module restored-module)
                        rest3)
                      (let
                        [rest3 : ast.AstDeclList rest3]
                        (match (ast.ast-decl-list-step rest3)
                          [(ast.AstDeclListStep.Cons
                              (ast.AstDecl.Def _ root-name _ _)
                              done-box)
                            (let
                              [done : ast.AstDeclList done-box]
                              (and
                                (ast.ast-decl-list-empty? (& done))
                                (string.eq
                                  (ci.intern-str nested-module)
                                  "local.helper")
                                (string.eq (ci.intern-str value-name) "value")
                                (string.eq (ci.intern-str restored-module) "")
                                (string.eq
                                  (ci.intern-str root-name)
                                  "root-value")))]
                          [_ false]))]
                    [_ false]))]
              [_ false]))]
        [_ false])]
    [(ResultCompilerLoad.Err _) false]))

(define (compiler-load-nested-module-duplicate-ok?) : bool
  (match (compiler-load-source
    "src/nested_dup.tl"
    "(module local.helper (define a : i64 1))
(module local.helper (define b : i64 2))"
    (sym_i64_env.sym-i64-empty))
    [(ResultCompilerLoad.Err diag)
      (string.eq
        (cdiag.compiler-diagnostic-message (__tl-box-place diag))
        "compiler-load: duplicate module declaration")]
    [(ResultCompilerLoad.Ok _ _) false]))

(define (compiler-load-seen-module-ok?) : bool
  (match (compiler-load-source
    "src/other.tl"
    "(module seen.module)
(define value : i64 1)"
    (sym_i64_env.sym-i64-bind-id
      (sym_i64_env.sym-i64-empty)
      (compiler-load-parse-context-name-id "seen.module")
      1))
    [(ResultCompilerLoad.Ok decls _)
      (compiler-load-decl-list-has-module? decls)]
    [(ResultCompilerLoad.Err _) false]))

(define (compiler-load-cfg-import-ok?) : bool
  (let
    [source : String
      "(module cfg.entry)
(cfg missing (import definitely_missing))
(define value : i64 1)"]
    [enabled-source : String
      "(module cfg.entry.active)
(cfg feature (import definitely_missing))
(define value : i64 1)"]
    [feature-cfg : sym_i64_env.SymI64Env
      (parser.compiler-cfg-enable (parser.compiler-cfg-empty) "feature")]
    (and
      (match (compiler-load-source-with-paths-and-roots-cfg
        "src/main.tl"
        source
        (sym_i64_env.sym-i64-empty)
        (svec.new)
        (parser.compiler-cfg-empty))
        [(ResultCompilerLoadWithPaths.Ok decls _ _ _)
          (= (compiler-load-decl-list-count decls) 2)]
        [(ResultCompilerLoadWithPaths.Err _) false])
      (match (compiler-load-source-with-paths-and-roots-cfg
        "src/main.tl"
        enabled-source
        (sym_i64_env.sym-i64-empty)
        (svec.new)
        feature-cfg)
        [(ResultCompilerLoadWithPaths.Err _) true]
        [(ResultCompilerLoadWithPaths.Ok _ _ _ _) false]))))

(define (compiler-load-file-import-dedup-cycle-ok?) : bool
  (begin
    (compiler-load-write-file-text
      "target/compiler_load_dep.tl"
      "(module compiler_load_dep)
(import compiler_load_entry as entry)
(define dep : i64 1)")
    (compiler-load-write-file-text
      "target/compiler_load_entry.tl"
      "(module compiler_load_entry)
(import compiler_load_dep as dep)
(import compiler_load_dep)
(define (main) : i64 (+ dep.dep compiler_load_dep.dep))")
    (match (compiler-load-file-with-paths
      "target/compiler_load_entry.tl"
      (sym_i64_env.sym-i64-empty))
      [(ResultCompilerLoadWithPaths.Ok decls _ modules seen)
        (and
          (= (compiler-load-decl-list-count decls) 10)
          (compiler-load-entry-cycle-modules? modules)
          (compiler-load-test-seen-contains? seen "compiler_load_entry")
          (compiler-load-test-seen-contains? seen "compiler_load_dep"))]
      [(ResultCompilerLoadWithPaths.Err _) false])))

(define (compiler-load-import-module-restore-ok?) : bool
  (begin
    (compiler-load-write-file-text
      "target/cl_restore_dep.tl"
      "(module cl_restore_dep)
(define dep-value : i64 1)")
    (compiler-load-write-file-text
      "target/cl_restore_entry.tl"
      "(import cl_restore_dep as dep)
(define (main) : i64 dep.dep-value)")
    (match (compiler-load-file-with-paths
      "target/cl_restore_entry.tl"
      (sym_i64_env.sym-i64-empty))
      [(ResultCompilerLoadWithPaths.Ok decls _ _ _)
        (compiler-load-unmoduled-import-restored-decls? decls)]
      [(ResultCompilerLoadWithPaths.Err _) false])))

(define (compiler-load-import-alias-preserved-ok?) : bool
  (begin
    (compiler-load-write-file-text
      "target/cl_alias_dep.tl"
      "(module cl_alias_dep)
(define (get) : i64 7)")
    (compiler-load-write-file-text
      "target/cl_alias_entry.tl"
      "(import cl_alias_dep as dep)
(module alias.entry)
(define (main) : i64 (dep.get))")
    (match (compiler-load-file-with-paths
      "target/cl_alias_entry.tl"
      (sym_i64_env.sym-i64-empty))
      [(ResultCompilerLoadWithPaths.Ok decls _ _ _)
        (compiler-load-decl-list-has-import-alias? decls "cl_alias_dep" "dep")]
      [(ResultCompilerLoadWithPaths.Err _) false])))

(define (compiler-load-dotted-import-duplicate-alias-ok?) : bool
  (match (compiler-load-source
    "src/dup_alias.tl"
    "(module alias.entry)
(import pkg.one)
(import other.one)
(define (main) : i64 0)"
    (sym_i64_env.sym-i64-empty))
    [(ResultCompilerLoad.Err diag)
      (string.eq
        (cdiag.compiler-diagnostic-message (__tl-box-place diag))
        "compiler-load: ambiguous import alias 'one' between 'pkg.one' and 'other.one'; use distinct aliases or qualified access")]
    [(ResultCompilerLoad.Ok _ _) false]))

;; Re-importing the same module under the same alias is idempotent, not a
;; duplicate: only a different module under a repeated alias is ambiguous.
(define (compiler-load-dotted-import-same-alias-same-module-ok?) : bool
  (begin
    (compiler-load-write-file-text
      "target/cl_same_alias_dep.tl"
      "(module cl_same_alias_dep)
(define (get) : i64 7)")
    (compiler-load-write-file-text
      "target/cl_same_alias_entry.tl"
      "(import cl_same_alias_dep)
(import cl_same_alias_dep)
(import cl_same_alias_dep as dep)
(import cl_same_alias_dep as dep)
(define (main) : i64 (+ cl_same_alias_dep.get dep.get))")
    (match (compiler-load-file-with-paths
      "target/cl_same_alias_entry.tl"
      (sym_i64_env.sym-i64-empty))
      [(ResultCompilerLoadWithPaths.Err _) false]
      [(ResultCompilerLoadWithPaths.Ok _ _ _ _) true])))

(define (compiler-load-dotted-import-resolution-ok?) : bool
  (and
    (string.eq
      (compiler-load-dotted-module-path "stdlib.core_macros")
      "stdlib/core_macros.tl")
    (match (compiler-load-resolve-module-import-with-roots
      "src/main.tl"
      "src/"
      "app.lib"
      (svec.new))
      [(ResultPkgResolve.Ok path) (string.eq path "src/app/lib.tl")]
      [(ResultPkgResolve.Err _) false])
    (match (compiler-load-resolve-module-import-with-roots
      "src/main.tl"
      "src/"
      "stdlib.core_macros"
      (svec.new))
      [(ResultPkgResolve.Ok path) (string.eq path "stdlib/core_macros.tl")]
      [(ResultPkgResolve.Err _) false])))

(define (compiler-load-decl-list-has-wildcard-import?
  [decls : ast.AstDeclList]
  [target-module : String]) : bool
  (match (ast.ast-decl-list-step decls)
    [(ast.AstDeclListStep.Nil) false]
    [(ast.AstDeclListStep.Cons decl rest)
      (let
        [rest : ast.AstDeclList rest]
        (match decl
          [(ast.AstDecl.Import
              _
              (ast.AstImportSpec.Spec
                (ast.AstImportKind.ModuleAll)
                _
                (ast.AstMaybeModuleName.Some module-name)
                (ast.AstMaybeImportAlias.Some alias)
                span))
            (if (and
              (string.eq (ci.intern-str module-name) target-module)
              (= alias cbi.compiler-builtin-id-fix-empty)
              (>
                (ast.ast-source-span-start-line
                  (ast.ast-source-span-box-shared-view span))
                0))
              true
              (compiler-load-decl-list-has-wildcard-import? rest target-module))]
          [_ (compiler-load-decl-list-has-wildcard-import? rest target-module)]))]))

(define (compiler-load-decl-list-has-selected-import?
  [decls : ast.AstDeclList]
  [target-module : String]
  [item : String]
  [alias-name : String]) : bool
  (match (ast.ast-decl-list-step decls)
    [(ast.AstDeclListStep.Nil) false]
    [(ast.AstDeclListStep.Cons decl rest)
      (let
        [rest : ast.AstDeclList rest]
        (match decl
          [(ast.AstDecl.Import
              _
              (ast.AstImportSpec.Spec
                (ast.AstImportKind.ModuleItem item-id)
                _
                (ast.AstMaybeModuleName.Some module-name)
                (ast.AstMaybeImportAlias.Some alias)
                span))
            (if (and
              (string.eq (ci.intern-str module-name) target-module)
              (string.eq (ci.intern-str item-id) item)
              (string.eq (ci.intern-str alias) alias-name)
              (>
                (ast.ast-source-span-start-line
                  (ast.ast-source-span-box-shared-view span))
                0))
              true
              (compiler-load-decl-list-has-selected-import?
                rest
                target-module
                item
                alias-name))]
          [_
            (compiler-load-decl-list-has-selected-import?
              rest
              target-module
              item
              alias-name)]))]))

(define (compiler-load-import-suffix-resolution-ok?) : bool
  (let
    [root : String "target/cl_import_suffix_root"]
    [pkg-root : String "target/cl_import_suffix_root/pkg"]
    [roots : svec.Vec
      (compiler-load-string-vec-one
        (owned_view.compiler-owned-shared-view root))]
    (begin
      (compiler-load-test-mkdir root)
      (compiler-load-test-mkdir pkg-root)
      (compiler-load-write-file-text
        "target/cl_import_suffix_root/pkg/shared.tl"
        "(module pkg.shared)
(define value : i64 41)
(define (function [value : i64]) : i64 (+ value 1))
(defstruct SharedPair (value i64))
(defenum Choice (None) (Some i64))
(defmacro (macro [value : Expr]) : Expr value)")
      (compiler-load-write-file-text
        "target/cl_import_suffix_entry.tl"
        "(module suffix.entry)
(import pkg.shared.*)
(import pkg.shared.value as chosen)
(import pkg.shared.Some as chosen-some)
(define (main) : i64 chosen)")
      (compiler-load-write-file-text
        "target/cl_import_suffix_missing.tl"
        "(module suffix.missing)
(import pkg.shared.absent)
(define (main) : i64 0)")
      (compiler-load-write-file-text
        "target/cl_import_suffix_invalid.tl"
        "(module suffix.invalid)
(import pkg.shared.absent.extra)
(define (main) : i64 0)")
      (compiler-load-write-file-text
        "target/cl_import_suffix_root/pkg/macro-a.tl"
        "(module pkg.macro-a)
(defmacro (same-macro) : Expr '(+ 1 1))")
      (compiler-load-write-file-text
        "target/cl_import_suffix_root/pkg/macro-b.tl"
        "(module pkg.macro-b)
(defmacro (same-macro) : Expr '(+ 2 2))")
      (compiler-load-write-file-text
        "target/cl_import_suffix_collision.tl"
        "(module suffix.collision)
(import pkg.macro-a.*)
(import pkg.macro-b.*)
(define (main) : i64 0)")
      (compiler-load-write-file-text
        "target/cl_import_suffix_repeat.tl"
        "(module suffix.repeat)
(import pkg.shared.*)
(import pkg.shared.*)
(define (main) : i64 value)")
      (and
        (match (compiler-load-file-with-paths-and-roots
          "target/cl_import_suffix_entry.tl"
          (sym_i64_env.sym-i64-empty)
          (ast.ast-place-shared-view roots))
          [(ResultCompilerLoadWithPaths.Ok decls _ _ _)
            (and
              (compiler-load-decl-list-has-wildcard-import?
                (ast.ast-place-shared-view decls)
                "pkg.shared")
              (compiler-load-decl-list-has-selected-import?
                (ast.ast-place-shared-view decls)
                "pkg.shared"
                "value"
                "chosen")
              (compiler-load-decl-list-has-selected-import?
                (ast.ast-place-shared-view decls)
                "pkg.shared"
                "Some"
                "chosen-some"))]
          [(ResultCompilerLoadWithPaths.Err _) false])
        (match (compiler-load-file-with-paths-and-roots
          "target/cl_import_suffix_missing.tl"
          (sym_i64_env.sym-i64-empty)
          (ast.ast-place-shared-view roots))
          [(ResultCompilerLoadWithPaths.Err diag)
            (let
              [value : cdiag.CompilerDiagnostic
                (cdiag.compiler-diagnostic-box-shared-view diag)]
              (and
                (string.eq
                  (cdiag.compiler-diagnostic-message value)
                  "compiler-load: module 'pkg.shared' has no selected item 'absent'")
                (> (cdiag.compiler-diagnostic-line value) 0)))]
          [(ResultCompilerLoadWithPaths.Ok _ _ _ _) false])
        (match (compiler-load-file-with-paths-and-roots
          "target/cl_import_suffix_invalid.tl"
          (sym_i64_env.sym-i64-empty)
          (ast.ast-place-shared-view roots))
          [(ResultCompilerLoadWithPaths.Err diag)
            (let
              [value : cdiag.CompilerDiagnostic
                (cdiag.compiler-diagnostic-box-shared-view diag)]
              (and
                (string.eq
                  (cdiag.compiler-diagnostic-message value)
                  "compiler-load: import 'pkg.shared.absent.extra' leaves more than one segment after loadable module 'pkg.shared'; only one selected item is supported")
                (> (cdiag.compiler-diagnostic-line value) 0)))]
          [(ResultCompilerLoadWithPaths.Ok _ _ _ _) false])
        (match (compiler-load-file-with-paths-and-roots
          "target/cl_import_suffix_collision.tl"
          (sym_i64_env.sym-i64-empty)
          (ast.ast-place-shared-view roots))
          [(ResultCompilerLoadWithPaths.Err diag)
            (let
              [value : cdiag.CompilerDiagnostic
                (cdiag.compiler-diagnostic-box-shared-view diag)]
              (and
                (string.eq
                  (cdiag.compiler-diagnostic-path value)
                  "target/cl_import_suffix_collision.tl")
                (= (cdiag.compiler-diagnostic-line value) 3)
                (string.eq
                  (cdiag.compiler-diagnostic-message value)
                  "compiler-load: ambiguous unqualified import 'same-macro' between modules 'pkg.macro-a' and 'pkg.macro-b'; use explicit selected aliases or qualified access")))]
          [(ResultCompilerLoadWithPaths.Ok _ _ _ _) false])
        (match (compiler-load-file-with-paths-and-roots
          "target/cl_import_suffix_repeat.tl"
          (sym_i64_env.sym-i64-empty)
          roots)
          [(ResultCompilerLoadWithPaths.Ok _ _ _ _) true]
          [(ResultCompilerLoadWithPaths.Err _) false])))))

(define (compiler-load-test-mkdir-direct [path : String]) : bool
  (match (fs.try-mkdir-if-missing (& path))
    [(io.OkIoUnit) true]
    [(io.ErrIoUnit _) false]))

(define (compiler-load-test-mkdir [path : String]) : bool
  (if (compiler-load-string-prefix-at? path "target/" 0)
    (and
      (compiler-load-test-mkdir-direct "target")
      (compiler-load-test-mkdir-direct path))
    (compiler-load-test-mkdir-direct path)))

(define (compiler-load-session-cache-common-dep-ok?) : bool
  (let
    [root : String "target/cl_cache_common_root"]
    [dep-suffix : String "cache_dep.tl"]
    [dep-file : String (compiler-load-join-root-path (clone root) dep-suffix)]
    [roots : svec.Vec (compiler-load-string-vec-one (clone root))]
    (begin
      (compiler-load-test-mkdir root)
      (compiler-load-write-file-text
        dep-file
        "(module stdlib.cache_dep)
(define dep-value : i64 1)")
      (compiler-load-write-file-text
        "target/cl_cache_entry_a.tl"
        "(module cache.entry.a)
(import stdlib.cache_dep as dep)
(define entry-a : i64 1)")
      (compiler-load-write-file-text
        "target/cl_cache_entry_b.tl"
        "(module cache.entry.b)
(import stdlib.cache_dep as dep)
(define entry-b : i64 2)")
      (compiler-load-session-cache-enable!)
      (compiler-load-program-cache-clear!)
      (let
        [ok : bool false]
        (begin
          (if (match (compiler-load-file-with-paths-and-roots
            "target/cl_cache_entry_a.tl"
            (sym_i64_env.sym-i64-empty)
            (ast.ast-place-shared-view roots))
            [(ResultCompilerLoadWithPaths.Ok _ _ _ _) true]
            [(ResultCompilerLoadWithPaths.Err _) false])
            (begin
              (compiler-load-session-reset-pools!)
              (compiler-load-session-reset-interns!)
              (match (compiler-load-file-with-paths-and-roots
                "target/cl_cache_entry_b.tl"
                (sym_i64_env.sym-i64-empty)
                roots)
                [(ResultCompilerLoadWithPaths.Ok _ _ _ _)
                  (set!
                    ok
                    (and
                      (> (compiler-load-program-cache-hit-count-value) 0)
                      (>= (compiler-load-program-cache-store-count-value) 1)))]
                [(ResultCompilerLoadWithPaths.Err _) (set! ok false)]))
            (set! ok false))
          (compiler-load-session-cache-disable-for-test!)
          ok)))))

(define (compiler-load-session-cache-root-isolation-ok?) : bool
  (let
    [root-a : String "target/cl_cache_root_a"]
    [root-b : String "target/cl_cache_root_b"]
    [dep-suffix : String "cache_root_dep.tl"]
    [root-a-file : String
      (compiler-load-join-root-path (clone root-a) (clone dep-suffix))]
    [root-b-file : String
      (compiler-load-join-root-path (clone root-b) (clone dep-suffix))]
    [roots-a : svec.Vec (compiler-load-string-vec-one (clone root-a))]
    [roots-b : svec.Vec (compiler-load-string-vec-one (clone root-b))]
    (begin
      (compiler-load-test-mkdir root-a)
      (compiler-load-test-mkdir root-b)
      (compiler-load-write-file-text
        root-a-file
        "(module stdlib.cache_root_dep)
(define root-value : i64 1)")
      (compiler-load-write-file-text
        root-b-file
        "(module stdlib.cache_root_dep)
(define root-value : i64 2)")
      (compiler-load-write-file-text
        "target/cl_cache_root_entry_a.tl"
        "(module cache.root.entry.a)
(import stdlib.cache_root_dep as dep)
(define entry-a : i64 1)")
      (compiler-load-write-file-text
        "target/cl_cache_root_entry_b.tl"
        "(module cache.root.entry.b)
(import stdlib.cache_root_dep as dep)
(define entry-b : i64 2)")
      (compiler-load-session-cache-enable!)
      (compiler-load-program-cache-clear!)
      (let
        [ok : bool false]
        (begin
          (if (match (compiler-load-file-with-paths-and-roots
            "target/cl_cache_root_entry_a.tl"
            (sym_i64_env.sym-i64-empty)
            roots-a)
            [(ResultCompilerLoadWithPaths.Ok _ _ _ _) true]
            [(ResultCompilerLoadWithPaths.Err _) false])
            (begin
              (compiler-load-session-reset-pools!)
              (compiler-load-session-reset-interns!)
              (match (compiler-load-file-with-paths-and-roots
                "target/cl_cache_root_entry_b.tl"
                (sym_i64_env.sym-i64-empty)
                roots-b)
                [(ResultCompilerLoadWithPaths.Ok _ _ _ _) (set! ok true)]
                [(ResultCompilerLoadWithPaths.Err _) (set! ok false)]))
            (set! ok false))
          (compiler-load-session-cache-disable-for-test!)
          ok)))))

(define (compiler-load-session-cache-entry-cold-ok?) : bool
  (begin
    (compiler-load-write-file-text
      "target/cl_cache_cold_entry.tl"
      "(module cache.cold.entry)
(define entry-value : i64 1)")
    (compiler-load-session-cache-enable!)
    (compiler-load-program-cache-clear!)
    (let
      [ok : bool false]
      (begin
        (if (match (compiler-load-entry-file-with-paths-and-roots-cfg
          "target/cl_cache_cold_entry.tl"
          (sym_i64_env.sym-i64-empty)
          (svec.new)
          (parser.compiler-cfg-empty))
          [(ResultCompilerLoadWithPaths.Ok _ _ _ _) true]
          [(ResultCompilerLoadWithPaths.Err _) false])
          (begin
            (compiler-load-session-reset-pools!)
            (compiler-load-session-reset-interns!)
            (match (compiler-load-entry-file-with-paths-and-roots-cfg
              "target/cl_cache_cold_entry.tl"
              (sym_i64_env.sym-i64-empty)
              (svec.new)
              (parser.compiler-cfg-empty))
              [(ResultCompilerLoadWithPaths.Ok _ _ _ _)
                (set!
                  ok
                  (and
                    (= (compiler-load-program-cache-hit-count-value) 0)
                    (= (compiler-load-program-cache-store-count-value) 0)))]
              [(ResultCompilerLoadWithPaths.Err _) (set! ok false)]))
          (set! ok false))
        (compiler-load-session-cache-disable-for-test!)
        ok))))

(define (compiler-load-session-persistent-floor-interns-ok?) : bool
  (begin
    (compiler-load-session-cache-enable!)
    (compiler-load-session-program-cache-disable!)
    (let
      [id : i64
        (with-scratch
          (let
            [name : String (str_cat.str-cat "cache.floor." "transient")]
            [interned : i64 (ci.intern name)]
            (begin
              (compiler-load-session-note-persistent!)
              interned)))]
      (begin
        (compiler-load-session-reset-interns!)
        (let
          [again : i64 (ci.intern "cache.floor.transient")]
          [ok : bool (= id again)]
          (begin
            (compiler-load-session-cache-disable-for-test!)
            ok))))))

(define (compiler-load-session-cache-local-common-dep-ok?) : bool
  (let
    [dir : String "target/cl_cache_local"]
    [dep : String (compiler-load-join-root-path (clone dir) "dep.tl")]
    [entry-a : String (compiler-load-join-root-path (clone dir) "entry_a.tl")]
    [entry-b : String (compiler-load-join-root-path (clone dir) "entry_b.tl")]
    [entry-c : String (compiler-load-join-root-path (clone dir) "entry_c.tl")]
    (begin
      (compiler-load-test-mkdir (clone dir))
      (compiler-load-write-file-text
        (clone dep)
        "(module dep)
(define dep-value : i64 1)")
      (compiler-load-write-file-text
        (clone entry-a)
        "(module cache.local.entry.a)
(import dep)
(define entry-a : i64 1)")
      (compiler-load-write-file-text
        (clone entry-b)
        "(module cache.local.entry.b)
(import dep)
(define entry-b : i64 2)")
      (compiler-load-write-file-text
        (clone entry-c)
        "(module cache.local.entry.c)
(import dep)
(define entry-c : i64 3)")
      (compiler-load-session-cache-enable!)
      (compiler-load-program-cache-clear!)
      (let
        [ok : bool false]
        (begin
          (if (match (compiler-load-entry-file-with-paths-and-roots-cfg
            entry-a
            (sym_i64_env.sym-i64-empty)
            (svec.new)
            (parser.compiler-cfg-empty))
            [(ResultCompilerLoadWithPaths.Ok _ _ _ _) true]
            [(ResultCompilerLoadWithPaths.Err _) false])
            (begin
              (compiler-load-session-reset-pools!)
              (compiler-load-session-reset-interns!)
              (match (compiler-load-entry-file-with-paths-and-roots-cfg
                entry-b
                (sym_i64_env.sym-i64-empty)
                (svec.new)
                (parser.compiler-cfg-empty))
                [(ResultCompilerLoadWithPaths.Ok _ _ _ _)
                  (begin
                    (compiler-load-session-reset-pools!)
                    (compiler-load-session-reset-interns!)
                    (match (compiler-load-entry-file-with-paths-and-roots-cfg
                      entry-c
                      (sym_i64_env.sym-i64-empty)
                      (svec.new)
                      (parser.compiler-cfg-empty))
                      [(ResultCompilerLoadWithPaths.Ok _ _ _ _)
                        (set!
                          ok
                          (and
                            (> (compiler-load-program-cache-hit-count-value) 0)
                            (>=
                              (compiler-load-program-cache-store-count-value)
                              1)))]
                      [(ResultCompilerLoadWithPaths.Err _) (set! ok false)]))]
                [(ResultCompilerLoadWithPaths.Err _) (set! ok false)]))
            (set! ok false))
          (compiler-load-session-cache-disable-for-test!)
          ok)))))

(define (compiler-load-session-cache-package-common-dep-ok?) : bool
  (let
    [root : String "target/cl_cache_pkg"]
    [src : String (compiler-load-join-root-path (clone root) "src")]
    [dep : String (compiler-load-join-root-path (clone src) "common.tl")]
    [entry-a : String (compiler-load-join-root-path (clone src) "entry_a.tl")]
    [entry-b : String (compiler-load-join-root-path (clone src) "entry_b.tl")]
    [entry-c : String (compiler-load-join-root-path (clone src) "entry_c.tl")]
    [deps : CompilerPkgDeps (compiler-pkg-deps-empty)]
    (begin
      (compiler-load-test-mkdir (clone root))
      (compiler-load-test-mkdir (clone src))
      (compiler-load-write-file-text
        (clone dep)
        "(module common)
(define common-value : i64 1)")
      (compiler-load-write-file-text
        (clone entry-a)
        "(module cache.pkg.entry.a)
(import common)
(define entry-a : i64 1)")
      (compiler-load-write-file-text
        (clone entry-b)
        "(module cache.pkg.entry.b)
(import common)
(define entry-b : i64 2)")
      (compiler-load-write-file-text
        (clone entry-c)
        "(module cache.pkg.entry.c)
(import common)
(define entry-c : i64 3)")
      (compiler-load-session-cache-enable!)
      (compiler-load-program-cache-clear!)
      (let
        [ok : bool false]
        (begin
          (if (match (compiler-load-package-entry-file-with-paths-and-roots-cfg
            entry-a
            (sym_i64_env.sym-i64-empty)
            (svec.new)
            (clone root)
            (ast.ast-place-shared-view deps)
            (parser.compiler-cfg-empty))
            [(ResultCompilerLoadWithPaths.Ok _ _ _ _) true]
            [(ResultCompilerLoadWithPaths.Err _) false])
            (begin
              (compiler-load-session-reset-pools!)
              (compiler-load-session-reset-interns!)
              (match (compiler-load-package-entry-file-with-paths-and-roots-cfg
                entry-b
                (sym_i64_env.sym-i64-empty)
                (svec.new)
                (clone root)
                (ast.ast-place-shared-view deps)
                (parser.compiler-cfg-empty))
                [(ResultCompilerLoadWithPaths.Ok _ _ _ _)
                  (begin
                    (compiler-load-session-reset-pools!)
                    (compiler-load-session-reset-interns!)
                    (match (compiler-load-package-entry-file-with-paths-and-roots-cfg
                      entry-c
                      (sym_i64_env.sym-i64-empty)
                      (svec.new)
                      root
                      deps
                      (parser.compiler-cfg-empty))
                      [(ResultCompilerLoadWithPaths.Ok _ _ _ _)
                        (set!
                          ok
                          (and
                            (> (compiler-load-program-cache-hit-count-value) 0)
                            (>=
                              (compiler-load-program-cache-store-count-value)
                              1)))]
                      [(ResultCompilerLoadWithPaths.Err _) (set! ok false)]))]
                [(ResultCompilerLoadWithPaths.Err _) (set! ok false)]))
            (set! ok false))
          (compiler-load-session-cache-disable-for-test!)
          ok)))))

(define (compiler-load-dotted-source-root-ok?) : bool
  (begin
    (compiler-load-test-mkdir "target/cl_dotted_src")
    (compiler-load-test-mkdir "target/cl_dotted_src/nested")
    (compiler-load-write-file-text
      "target/cl_dotted_src/root_leaf.tl"
      "(module root_leaf)
(define leaf-val : i64 1)")
    (compiler-load-write-file-text
      "target/cl_dotted_src/nested/dep.tl"
      "(module nested.dep)
(import root_leaf as leaf)
(define dep-val : i64 leaf-val)")
    (compiler-load-write-file-text
      "target/cl_dotted_src/entry.tl"
      "(module dotted.entry)
(import nested.dep)
(define (main) : i64 dep-val)")
    (match (compiler-load-file-with-paths
      "target/cl_dotted_src/entry.tl"
      (sym_i64_env.sym-i64-empty))
      [(ResultCompilerLoadWithPaths.Ok _ _ _ seen)
        (and
          (compiler-load-test-seen-contains? seen "dotted.entry")
          (compiler-load-test-seen-contains? seen "nested.dep")
          (compiler-load-test-seen-contains? seen "root_leaf"))]
      [(ResultCompilerLoadWithPaths.Err _) false])))

(define (compiler-load-moduleless-dotted-source-root-ok?) : bool
  (begin
    (compiler-load-test-mkdir "target/cl_moduleless_dotted_src")
    (compiler-load-test-mkdir "target/cl_moduleless_dotted_src/nested")
    (compiler-load-write-file-text
      "target/cl_moduleless_dotted_src/root_leaf.tl"
      "(define leaf-val : i64 1)")
    (compiler-load-write-file-text
      "target/cl_moduleless_dotted_src/nested/dep.tl"
      "(import root_leaf as leaf)
(define dep-val : i64 leaf.leaf-val)")
    (compiler-load-write-file-text
      "target/cl_moduleless_dotted_src/entry.tl"
      "(module moduleless.dotted.entry)
(import nested.dep)
(define (main) : i64 dep.dep-val)")
    (match (compiler-load-file-with-paths
      "target/cl_moduleless_dotted_src/entry.tl"
      (sym_i64_env.sym-i64-empty))
      [(ResultCompilerLoadWithPaths.Ok decls _ _ seen)
        (and
          (compiler-load-decl-list-has-module-id?
            (ast.ast-place-shared-view decls)
            (compiler-load-parse-context-name-id "root_leaf"))
          (compiler-load-decl-list-has-module-id?
            (ast.ast-place-shared-view decls)
            (compiler-load-parse-context-name-id "nested.dep"))
          (compiler-load-decl-list-has-import-alias? decls "nested.dep" "dep")
          (compiler-load-test-seen-contains? seen "root_leaf")
          (compiler-load-test-seen-contains? seen "nested.dep"))]
      [(ResultCompilerLoadWithPaths.Err _) false])))

(define (compiler-load-stdlib-source-module-import-ok?) : bool
  (and
    (compiler-load-stdlib-source-module-import? "stdlib/vector.tl")
    (compiler-load-stdlib-source-module-import? "stdlib\\vector.tl")
    (not
      (compiler-load-stdlib-source-module-import? "stdlib/tests/thread_api.tl"))
    (not
      (compiler-load-stdlib-source-module-import?
        "stdlib\\tests\\thread_api.tl"))))

(define (compiler-load-dotted-source-root-fallback-ok?) : bool
  (let
    [root : String "target/cl_dotted_src_fallback/src"]
    [tests : String (compiler-load-join-root-path (clone root) "tests")]
    [leaf : String (compiler-load-join-root-path (clone root) "leaf.tl")]
    [mid : String (compiler-load-join-root-path (clone root) "mid.tl")]
    [entry : String (compiler-load-join-root-path (clone tests) "entry.tl")]
    [roots : svec.Vec (compiler-load-string-vec-one (clone root))]
    (begin
      (compiler-load-test-mkdir "target/cl_dotted_src_fallback")
      (compiler-load-test-mkdir root)
      (compiler-load-test-mkdir tests)
      (compiler-load-write-file-text
        leaf
        "(module leaf)
(define leaf-val : i64 1)")
      (compiler-load-write-file-text
        mid
        "(module mid)
(import leaf)
(define mid-val : i64 leaf.leaf-val)")
      (compiler-load-write-file-text
        (clone entry)
        "(module fallback.entry)
(import mid)
(define (main) : i64 mid.mid-val)")
      (match (compiler-load-file-with-paths-and-roots
        (clone entry)
        (sym_i64_env.sym-i64-empty)
        roots)
        [(ResultCompilerLoadWithPaths.Ok _ _ _ seen)
          (and
            (compiler-load-test-seen-contains? seen "fallback.entry")
            (compiler-load-test-seen-contains? seen "mid")
            (compiler-load-test-seen-contains? seen "leaf"))]
        [(ResultCompilerLoadWithPaths.Err _) false]))))

(define (compiler-load-dotted-transitive-import-ok?) : bool
  (let
    [root : String "target/cl_dotted_after_path/src"]
    [helper : String (compiler-load-join-root-path (clone root) "helper.tl")]
    [provider : String
      (compiler-load-join-root-path (clone root) "provider.tl")]
    [entry : String (compiler-load-join-root-path (clone root) "entry.tl")]
    (begin
      (compiler-load-test-mkdir "target/cl_dotted_after_path")
      (compiler-load-test-mkdir root)
      (compiler-load-write-file-text
        helper
        "(module helper)
(define answer : i64 42)")
      (compiler-load-write-file-text
        provider
        "(module provider)
(import helper as helper)
(define value : i64 helper.answer)")
      (compiler-load-write-file-text
        (clone entry)
        "(import provider)
(define (main) : i64 provider.value)")
      (match (compiler-load-file-with-paths entry (sym_i64_env.sym-i64-empty))
        [(ResultCompilerLoadWithPaths.Ok _ _ _ seen)
          (and
            (compiler-load-test-seen-contains? seen "provider")
            (compiler-load-test-seen-contains? seen "helper"))]
        [(ResultCompilerLoadWithPaths.Err _) false]))))

(define (compiler-load-canonical-source-explicit-mismatch-ok?) : bool
  (begin
    (compiler-load-write-file-text
      "target/cl_canonical_source_explicit.tl"
      "(module canonical.actual)
(define value : i64 42)")
    (compiler-load-write-file-text
      "target/cl_canonical_source_explicit_entry.tl"
      "(import cl_canonical_source_explicit as wrong)
(define (main) : i64 wrong.value)")
    (match (compiler-load-file-with-paths
      "target/cl_canonical_source_explicit_entry.tl"
      (sym_i64_env.sym-i64-empty))
      [(ResultCompilerLoadWithPaths.Err diag)
        (string.eq
          (cdiag.compiler-diagnostic-message (__tl-box-place diag))
          "compiler-load: import expected module cl_canonical_source_explicit but loaded canonical.actual")]
      [(ResultCompilerLoadWithPaths.Ok _ _ _ _) false])))

(define (compiler-load-package-dotted-import-resolution-ok?) : bool
  (let
    [deps : CompilerPkgDeps (compiler-load-pkg-resolve-deps)]
    (and
      (match (compiler-load-resolve-package-import-spec
        "proj/src/main.tl"
        (ast.AstImportKind.Module)
        "app.lib"
        ast.AstMaybeModuleName.No
        (svec.new)
        "proj"
        (ast.ast-place-shared-view deps))
        [(ResultPkgResolve.Ok path) (string.eq path "proj/app/lib.tl")]
        [(ResultPkgResolve.Err _) false])
      (match (compiler-load-resolve-package-import-spec
        "proj/src/main.tl"
        (ast.AstImportKind.Module)
        "math.src.add"
        ast.AstMaybeModuleName.No
        (svec.new)
        "proj"
        (ast.ast-place-shared-view deps))
        [(ResultPkgResolve.Ok path) (string.eq path "math/src/add.tl")]
        [(ResultPkgResolve.Err _) false])
      (compiler-load-package-import-externs?
        (ast.AstImportKind.Module)
        "math.src.add"
        ast.AstMaybeModuleName.No
        (ast.ast-place-shared-view deps))
      (not
        (compiler-load-package-import-externs?
          (ast.AstImportKind.Module)
          "stdlib.core_macros"
          ast.AstMaybeModuleName.No
          deps)))))

(define (compiler-load-package-dotted-sibling-source-ok?) : bool
  (let
    [root : String "target/cl_pkg_dotted_src"]
    [src : String (compiler-load-join-root-path (clone root) "src")]
    [entry : String (compiler-load-join-root-path (clone src) "main.tl")]
    [dep : String (compiler-load-join-root-path (clone src) "dep.tl")]
    [deps : CompilerPkgDeps (compiler-load-pkg-resolve-deps)]
    (begin
      (compiler-load-test-mkdir (clone root))
      (compiler-load-test-mkdir (clone src))
      (compiler-load-write-file-text
        (clone dep)
        "(module dep)
(define dep-val : i64 1)")
      (match (compiler-load-resolve-package-import-spec
        entry
        (ast.AstImportKind.Module)
        "dep"
        ast.AstMaybeModuleName.No
        (svec.new)
        root
        deps)
        [(ResultPkgResolve.Ok path)
          (string.eq path (compiler-load-normalize-path dep))]
        [(ResultPkgResolve.Err _) false]))))

(define (compiler-load-package-second-root-source-ok?) : bool
  (let
    [base : String "target/cl_pkg_second_root"]
    [first-root : String (compiler-load-join-root-path (clone base) "first")]
    [second-root : String (compiler-load-join-root-path (clone base) "second")]
    [tests-root : String (compiler-load-join-root-path (clone base) "tests")]
    [entry : String
      (compiler-load-join-root-path (clone tests-root) "entry.tl")]
    [dep : String
      (compiler-load-join-root-path (clone second-root) "root_helper.tl")]
    [first-order : String
      (compiler-load-join-root-path (clone first-root) "root_order.tl")]
    [second-order : String
      (compiler-load-join-root-path (clone second-root) "root_order.tl")]
    [roots : svec.Vec (svec.new)]
    (begin
      (compiler-load-test-mkdir (clone base))
      (compiler-load-test-mkdir (clone first-root))
      (compiler-load-test-mkdir (clone second-root))
      (compiler-load-test-mkdir (clone tests-root))
      (compiler-load-write-file-text
        (clone dep)
        "(module root_helper)
(define answer : i64 42)")
      (compiler-load-write-file-text
        (clone entry)
        "(import root_helper)
(define (main) : i64 root_helper.answer)")
      (compiler-load-write-file-text
        (clone first-order)
        "(module root_order)
(define answer : i64 1)")
      (compiler-load-write-file-text
        (clone second-order)
        "(module root_order)
(define answer : i64 2)")
      (svec.push-ref! (&mut roots) first-root)
      (svec.push-ref! (&mut roots) second-root)
      (let
        [order-ok : bool
          (match (compiler-load-resolve-package-import-spec
            (clone entry)
            (ast.AstImportKind.Module)
            "root_order"
            ast.AstMaybeModuleName.No
            (ast.ast-place-shared-view roots)
            (clone base)
            (compiler-pkg-deps-empty))
            [(ResultPkgResolve.Ok path)
              (string.eq path (compiler-load-normalize-path first-order))]
            [(ResultPkgResolve.Err _) false])]
        (and
          order-ok
          (match (compiler-load-package-file-with-paths-and-roots
            entry
            (sym_i64_env.sym-i64-empty)
            roots
            base
            (compiler-pkg-deps-empty))
            [(ResultCompilerLoadWithPaths.Ok _ _ _ _) true]
            [(ResultCompilerLoadWithPaths.Err _) false]))))))

(define (compiler-load-package-moduleless-pkg-import-id-ok?) : bool
  (let
    [base : String "target/cl_pkg_moduleless_id"]
    [app-root : String (compiler-load-join-root-path (clone base) "app")]
    [app-src : String (compiler-load-join-root-path (clone app-root) "src")]
    [math-root : String (compiler-load-join-root-path (clone base) "math")]
    [math-src : String (compiler-load-join-root-path (clone math-root) "src")]
    [entry : String (compiler-load-join-root-path (clone app-src) "main.tl")]
    [dep : String (compiler-load-join-root-path (clone math-src) "add.tl")]
    [deps : CompilerPkgDeps
      (compiler-pkg-deps-cons "math" "../math" (compiler-pkg-deps-empty))]
    (begin
      (compiler-load-test-mkdir (clone base))
      (compiler-load-test-mkdir (clone app-root))
      (compiler-load-test-mkdir (clone app-src))
      (compiler-load-test-mkdir (clone math-root))
      (compiler-load-test-mkdir (clone math-src))
      (compiler-load-write-file-text
        (compiler-load-join-root-path (clone math-root) "typelisp.pkg")
        "(package (name \"math\") (version \"1\") (kind staticlib) (entry \"src/add.tl\"))")
      (compiler-load-write-file-text
        (clone dep)
        "(define (add [x : i64]) : i64 (+ x 1))")
      (compiler-load-write-file-text
        (clone entry)
        "(module pkg.moduleless.entry)
(import math.src.add)
(define (main) : i64 0)")
      (match (compiler-load-package-file-with-paths-and-roots
        entry
        (sym_i64_env.sym-i64-empty)
        (svec.new)
        app-root
        deps)
        [(ResultCompilerLoadWithPaths.Ok decls _ _ seen)
          (and
            (compiler-load-decl-list-has-extern-symbol?
              decls
              "_tl_math_src_add_add")
            (compiler-load-test-seen-contains? seen "math.src.add")
            (not (compiler-load-test-seen-contains? seen dep)))]
        [(ResultCompilerLoadWithPaths.Err _) false]))))

(define (compiler-load-package-dotted-explicit-module-id-ok?) : bool
  (let
    [base : String "target/cl_pkg_dotted_explicit_id"]
    [app-root : String (compiler-load-join-root-path (clone base) "app")]
    [app-src : String (compiler-load-join-root-path (clone app-root) "src")]
    [math-root : String (compiler-load-join-root-path (clone base) "math")]
    [math-src : String (compiler-load-join-root-path (clone math-root) "src")]
    [entry : String (compiler-load-join-root-path (clone app-src) "main.tl")]
    [dep : String (compiler-load-join-root-path (clone math-src) "add.tl")]
    [deps : CompilerPkgDeps
      (compiler-pkg-deps-cons "math" "../math" (compiler-pkg-deps-empty))]
    (begin
      (compiler-load-test-mkdir (clone base))
      (compiler-load-test-mkdir (clone app-root))
      (compiler-load-test-mkdir (clone app-src))
      (compiler-load-test-mkdir (clone math-root))
      (compiler-load-test-mkdir (clone math-src))
      (compiler-load-write-file-text
        (compiler-load-join-root-path (clone math-root) "typelisp.pkg")
        "(package (name \"math\") (version \"1\") (kind staticlib) (entry \"src/add.tl\"))")
      (compiler-load-write-file-text
        (clone dep)
        "(module arithmetic.public)
(define (add [x : i64]) : i64 (+ x 1))")
      (compiler-load-write-file-text
        (clone entry)
        "(module pkg.dotted.explicit.entry)
(import math.src.add as math_add)
(define (main) : i64 (math_add.add 1))")
      (match (compiler-load-package-file-with-paths-and-roots
        entry
        (sym_i64_env.sym-i64-empty)
        (svec.new)
        app-root
        deps)
        [(ResultCompilerLoadWithPaths.Ok decls _ _ seen)
          (and
            (compiler-load-decl-list-has-import-alias?
              decls
              "arithmetic.public"
              "math_add")
            (compiler-load-test-seen-contains? seen "arithmetic.public"))]
        [(ResultCompilerLoadWithPaths.Err _) false]))))

(define (compiler-load-generated-meta-preserved-ok?) : bool
  (let
    [meta : ast.AstGeneratedDeclMeta
      (ast.AstGeneratedDeclMeta.Some
        "gen"
        "generated-fn"
        (ast.ast-expr-list-new)
        "")]
    [inner : ast.AstDecl
      (ast.ast-decl-def-fn-id
        (compiler-load-parse-context-name-id "generated-fn")
        (ast.ast-param-list-new)
        (ast.AstType.I64)
        (ast.ast-node-push (ast.AstExpr.Literal (ast.ast-lit-int 1))))]
    [decl : ast.AstDecl (ast.ast-decl-comptime-decl-with-meta meta inner)]
    (match (compiler-load-package-transform-decl
      "demo"
      ""
      (svec.new)
      "src/main.tl"
      "main"
      CompilerLoadPackageSpmdInterface.Unavailable
      decl)
      [(CompilerLoadSomeDecl transformed)
        (and
          (match (ast.ast-decl-generated-meta (clone transformed))
            [(ast.AstGeneratedDeclMeta.Some generator item arg-keys _)
              (and
                (string.eq generator "gen")
                (string.eq item "generated-fn")
                (= (ast.ast-expr-list-len (& arg-keys)) 0))]
            [_ false])
          (match transformed
            [(ast.AstDecl.Extern decl-meta name _ _ _)
              (string.eq (ci.intern-str name) "generated-fn")]
            [_ false]))]
      [(CompilerLoadNoDecl) false])))

;; Diamond import dedup: entry imports A and B, both of which
;; import C; C must load exactly once. Writes fixture modules under target/ and
;; loads through the file loader, mirroring the existing dedup/cycle self-test.
(define (compiler-load-diamond-import-ok?) : bool
  (begin
    (compiler-load-write-file-text
      "target/cl_diamond_c.tl"
      "(module cl_diamond_c)
(define c-val : i64 1)")
    (compiler-load-write-file-text
      "target/cl_diamond_a.tl"
      "(module cl_diamond_a)
(import cl_diamond_c as c)
(define a-val : i64 c.c-val)")
    (compiler-load-write-file-text
      "target/cl_diamond_b.tl"
      "(module cl_diamond_b)
(import cl_diamond_c as c)
(define b-val : i64 c.c-val)")
    (compiler-load-write-file-text
      "target/cl_diamond_entry.tl"
      "(module cl_diamond_entry)
(import cl_diamond_a as a)
(import cl_diamond_b as b)
(define (main) : i64 (+ a.a-val b.b-val))")
    (match (compiler-load-file-with-paths
      "target/cl_diamond_entry.tl"
      (sym_i64_env.sym-i64-empty))
      [(ResultCompilerLoadWithPaths.Ok decls _ _ seen)
        (and
          (= (compiler-load-decl-list-count decls) 17)
          (compiler-load-test-seen-contains? seen "cl_diamond_c")
          (compiler-load-test-seen-contains? seen "cl_diamond_a")
          (compiler-load-test-seen-contains? seen "cl_diamond_b")
          (compiler-load-test-seen-contains? seen "cl_diamond_entry"))]
      [(ResultCompilerLoadWithPaths.Err _) false])))

;; Transitive import dedup: entry imports A, A imports B, B
;; imports C; the whole chain loads with the deterministic loaded decl count and
;; every module recorded in the seen set.
(define (compiler-load-transitive-import-ok?) : bool
  (begin
    (compiler-load-write-file-text
      "target/cl_tr_c.tl"
      "(module cl_tr_c)
(define c-val : i64 1)")
    (compiler-load-write-file-text
      "target/cl_tr_b.tl"
      "(module cl_tr_b)
(import cl_tr_c as c)
(define b-val : i64 c.c-val)")
    (compiler-load-write-file-text
      "target/cl_tr_a.tl"
      "(module cl_tr_a)
(import cl_tr_b as b)
(define a-val : i64 b.b-val)")
    (compiler-load-write-file-text
      "target/cl_tr_entry.tl"
      "(module cl_tr_entry)
(import cl_tr_a as a)
(define (main) : i64 a.a-val)")
    (match (compiler-load-file-with-paths
      "target/cl_tr_entry.tl"
      (sym_i64_env.sym-i64-empty))
      [(ResultCompilerLoadWithPaths.Ok decls _ _ seen)
        (and
          (= (compiler-load-decl-list-count decls) 14)
          (compiler-load-test-seen-contains? seen "cl_tr_c")
          (compiler-load-test-seen-contains? seen "cl_tr_b")
          (compiler-load-test-seen-contains? seen "cl_tr_a")
          (compiler-load-test-seen-contains? seen "cl_tr_entry"))]
      [(ResultCompilerLoadWithPaths.Err _) false])))

;; An import whose module does not resolve to a readable file reports a
;; `cannot read import <path>` diagnostic.
(define (compiler-load-missing-import-ok?) : bool
  (match (compiler-load-source
    "src/app.tl"
    "(import no_such_module_xyz)
(define value : i64 1)"
    (sym_i64_env.sym-i64-empty))
    [(ResultCompilerLoad.Err diag)
      (string.eq
        (cdiag.compiler-diagnostic-message (__tl-box-place diag))
        "compiler-load: cannot read import src/no_such_module_xyz.tl")]
    [(ResultCompilerLoad.Ok _ _) false]))

(define (compiler-load-include-str-relative-ok?) : bool
  (begin
    (compiler-load-write-file-text
      "target/cl_include_payload.txt"
      "hello from include")
    (compiler-load-write-file-text
      "target/cl_include_entry.tl"
      "(include-str payload \"cl_include_payload.txt\")
(define (main) : i64 0)")
    (match (compiler-load-file-with-paths
      "target/cl_include_entry.tl"
      (sym_i64_env.sym-i64-empty))
      [(ResultCompilerLoadWithPaths.Ok decls _ _ _)
        (and
          (= (compiler-load-decl-list-count decls) 2)
          (compiler-load-first-string-def? decls "payload" "hello from include"))]
      [(ResultCompilerLoadWithPaths.Err _) false])))

(define (compiler-load-include-str-stdlib-root-ok?) : bool
  (begin
    (compiler-load-write-file-text
      "target/cl_include_root_payload.txt"
      "hello from root")
    (match (compiler-load-source-with-paths-and-roots
      "src/include_entry.tl"
      "(include-str embedded \"stdlib/cl_include_root_payload.txt\")
(define (main) : i64 0)"
      (sym_i64_env.sym-i64-empty)
      (compiler-load-string-vec-one "target"))
      [(ResultCompilerLoadWithPaths.Ok decls _ _ _)
        (and
          (= (compiler-load-decl-list-count decls) 2)
          (compiler-load-first-string-def? decls "embedded" "hello from root"))]
      [(ResultCompilerLoadWithPaths.Err _) false])))

(define (compiler-load-include-str-comptime-relative-ok?) : bool
  (begin
    (compiler-load-write-file-text
      "target/cl_include_comptime_payload.txt"
      "only at comptime")
    (compiler-load-write-file-text
      "target/cl_include_comptime_entry.tl"
      "(include-str-comptime payload \"cl_include_comptime_payload.txt\")
(define (main) : i64 0)")
    (match (compiler-load-file-with-paths
      "target/cl_include_comptime_entry.tl"
      (sym_i64_env.sym-i64-empty))
      [(ResultCompilerLoadWithPaths.Ok decls _ _ _)
        (and
          (= (compiler-load-decl-list-count decls) 2)
          (compiler-load-first-string-macro? decls "payload" "only at comptime"))]
      [(ResultCompilerLoadWithPaths.Err _) false])))

(define (compiler-load-include-str-lzss-relative-ok?) : bool
  (begin
    (compiler-load-write-file-text
      "target/cl_include_lzss_payload.txt"
      "compress me")
    (compiler-load-write-file-text
      "target/cl_include_lzss_entry.tl"
      "(include-str-lzss payload \"cl_include_lzss_payload.txt\")
(define (main) : i64 0)")
    (match (compiler-load-file-with-paths
      "target/cl_include_lzss_entry.tl"
      (sym_i64_env.sym-i64-empty))
      [(ResultCompilerLoadWithPaths.Ok decls _ _ _)
        (and
          (= (compiler-load-decl-list-count decls) 2)
          (compiler-load-first-lzss-def? decls "payload" "compress me"))]
      [(ResultCompilerLoadWithPaths.Err _) false])))

(define (compiler-load-missing-include-str-ok?) : bool
  (match (compiler-load-source
    "src/app.tl"
    "(include-str missing \"no_such_resource_xyz.txt\")
(define value : i64 1)"
    (sym_i64_env.sym-i64-empty))
    [(ResultCompilerLoad.Err diag)
      (string.eq
        (cdiag.compiler-diagnostic-message (__tl-box-place diag))
        "compiler-load: cannot read include-str no_such_resource_xyz.txt from src/app.tl (resolved src/no_such_resource_xyz.txt)")]
    [(ResultCompilerLoad.Ok _ _) false]))

(define (compiler-load-include-str-raw-text-ok?) : bool
  (let
    [payload : String "(import definitely_missing)
(define injected : i64 7)"]
    (begin
      (compiler-load-write-file-text
        "target/cl_include_raw_payload.txt"
        (clone payload))
      (compiler-load-write-file-text
        "target/cl_include_raw_entry.tl"
        "(include-str payload \"cl_include_raw_payload.txt\")
(define (main) : i64 0)")
      (match (compiler-load-file-with-paths
        "target/cl_include_raw_entry.tl"
        (sym_i64_env.sym-i64-empty))
        [(ResultCompilerLoadWithPaths.Ok decls _ _ _)
          (and
            (= (compiler-load-decl-list-count decls) 2)
            (compiler-load-first-string-def? decls "payload" payload))]
        [(ResultCompilerLoadWithPaths.Err _) false]))))

(define (compiler-load-include-bin-relative-ok?) : bool
  (begin
    (compiler-load-write-file-text
      "target/cl_include_bin_payload.bin"
      (compiler-load-binary-fixture))
    (compiler-load-write-file-text
      "target/cl_include_bin_entry.tl"
      "(include-bin payload \"cl_include_bin_payload.bin\")
(define (main) : i64 0)")
    (match (compiler-load-file-with-paths
      "target/cl_include_bin_entry.tl"
      (sym_i64_env.sym-i64-empty))
      [(ResultCompilerLoadWithPaths.Ok decls _ _ _)
        (and
          (= (compiler-load-decl-list-count decls) 2)
          (compiler-load-first-bin-def? decls "payload"))]
      [(ResultCompilerLoadWithPaths.Err _) false])))

(define (compiler-load-missing-include-bin-ok?) : bool
  (match (compiler-load-source
    "src/app.tl"
    "(include-bin missing \"no_such_resource_xyz.bin\")
(define value : i64 1)"
    (sym_i64_env.sym-i64-empty))
    [(ResultCompilerLoad.Err diag)
      (string.eq
        (cdiag.compiler-diagnostic-message (__tl-box-place diag))
        "compiler-load: cannot read include-bin no_such_resource_xyz.bin from src/app.tl (resolved src/no_such_resource_xyz.bin)")]
    [(ResultCompilerLoad.Ok _ _) false]))

(define (compiler-load-embedded-stdlib-lookup-ok?) : bool
  (match (compiler-load-embedded-stdlib-source "string.tl")
    [(ces.CompilerEmbeddedStdlibSource.CompilerEmbeddedStdlibSomeSource source)
      (match (compiler-load-source-with-paths-and-roots
        "stdlib/string.tl"
        source
        (sym_i64_env.sym-i64-empty)
        (svec.new))
        [(ResultCompilerLoadWithPaths.Ok decls _ _ _)
          (> (compiler-load-decl-list-count decls) 0)]
        [(ResultCompilerLoadWithPaths.Err _) false])]
    [(ces.CompilerEmbeddedStdlibSource.CompilerEmbeddedStdlibNoSource) false]))

(define (compiler-load-embedded-stdlib-missing-ok?) : bool
  (match (compiler-load-embedded-stdlib-source "definitely_missing_xyz.tl")
    [(ces.CompilerEmbeddedStdlibSource.CompilerEmbeddedStdlibNoSource) true]
    [(ces.CompilerEmbeddedStdlibSource.CompilerEmbeddedStdlibSomeSource _)
      false]))

(define (compiler-load-embedded-stdlib-escape-rejected-ok?) : bool
  (match (compiler-load-embedded-stdlib-source "../string.tl")
    [(ces.CompilerEmbeddedStdlibSource.CompilerEmbeddedStdlibNoSource) true]
    [(ces.CompilerEmbeddedStdlibSource.CompilerEmbeddedStdlibSomeSource _)
      false]))

;; A parse error inside an imported file surfaces a diagnostic whose path is the
;; imported file (not the importer), preserving imported-file provenance.
(define (compiler-load-imported-parse-error-path-ok?) : bool
  (begin
    (compiler-load-write-file-text
      "target/cl_ipe_dep.tl"
      "(module cl_ipe_dep)
(define broken : i64 )")
    (compiler-load-write-file-text
      "target/cl_ipe_entry.tl"
      "(module cl_ipe_entry)
(import cl_ipe_dep as dep)
(define (main) : i64 0)")
    (match (compiler-load-file-with-paths
      "target/cl_ipe_entry.tl"
      (sym_i64_env.sym-i64-empty))
      [(ResultCompilerLoadWithPaths.Err diag)
        (and
          (string.eq
            (cdiag.compiler-diagnostic-path (__tl-box-place diag))
            "target/cl_ipe_dep.tl")
          (string.eq
            (cdiag.compiler-diagnostic-message (__tl-box-place diag))
            "parse: malformed value definition"))]
      [(ResultCompilerLoadWithPaths.Ok _ _ _ _) false])))

;; A duplicate `(module ...)` declaration inside an imported file surfaces a
;; diagnostic whose path is the imported file, not the importer.
(define (compiler-load-imported-duplicate-module-path-ok?) : bool
  (begin
    (compiler-load-write-file-text
      "target/cl_idm_dep.tl"
      "(module idm.depa)
(module idm.depb)
(define v : i64 1)")
    (compiler-load-write-file-text
      "target/cl_idm_entry.tl"
      "(module idm.entry)
(import cl_idm_dep as dep)
(define (main) : i64 0)")
    (match (compiler-load-file-with-paths
      "target/cl_idm_entry.tl"
      (sym_i64_env.sym-i64-empty))
      [(ResultCompilerLoadWithPaths.Err diag)
        (and
          (string.eq
            (cdiag.compiler-diagnostic-path (__tl-box-place diag))
            "target/cl_idm_dep.tl")
          (string.eq
            (cdiag.compiler-diagnostic-message (__tl-box-place diag))
            "compiler-load: duplicate module declaration"))]
      [(ResultCompilerLoadWithPaths.Ok _ _ _ _) false])))

;; A `stdlib/<x>` import whose importer-relative path is absent resolves through
;; a configured `--stdlib-root` (root fallback).
(define (compiler-load-stdlib-root-fallback-ok?) : bool
  (begin
    (compiler-load-write-file-text
      "target/cl_srf_mod.tl"
      "(module stdlib.cl_srf_mod)
(define v : i64 1)")
    (compiler-load-write-file-text
      "target/cl_srf_entry.tl"
      "(module srf.entry)
(import stdlib.cl_srf_mod as m)
(define (main) : i64 m.v)")
    (match (compiler-load-file-with-paths-and-roots
      "target/cl_srf_entry.tl"
      (sym_i64_env.sym-i64-empty)
      (compiler-load-string-vec-one "target"))
      [(ResultCompilerLoadWithPaths.Ok _ _ _ seen)
        (compiler-load-test-seen-contains? seen "stdlib.cl_srf_mod")]
      [(ResultCompilerLoadWithPaths.Err _) false])))

;; A physically rooted prelude keeps its canonical logical path/module while
;; consuming the root's bytes. Rootless canonical paths prefer embedded source,
;; whereas a root that owns the suffix explicitly requests disk source.
(define (compiler-load-prelude-source-precedence-ok?) : bool
  (let
    [root-dir : String "target/cl_prelude_root"]
    [root-path : String "target/cl_prelude_root/runtime.tl"]
    [roots : svec.Vec (compiler-load-string-vec-one (clone root-dir))]
    (begin
      (fs.mkdir-status-owned (clone root-dir))
      (compiler-load-write-file-text
        root-path
        "(define prelude-root-marker : i64 1)")
      (compiler-load-write-file-text
        "target/cl_prelude_root/core_macros.tl"
        "(define core-prelude-root-marker : i64 1)")
      (and
        (match (compiler-load-stdlib-prelude-file-with-roots-cfg
          (string.copy (& compiler-load-runtime-prelude-path))
          (sym_i64_env.sym-i64-empty)
          (ast.ast-place-shared-view roots)
          (parser.compiler-cfg-empty))
          [(ResultCompilerLoadWithPaths.Ok decls paths modules _)
            (and
              (=
                (compiler-load-decl-list-value-name-count
                  decls
                  "prelude-root-marker")
                1)
              (string.eq
                (compiler-load-test-path-at paths 0)
                (compiler-load-runtime-prelude-path-shared-view))
              (string.eq
                (ast.ast-decl-module-list-get (& modules) 0 "")
                "stdlib.runtime"))]
          [(ResultCompilerLoadWithPaths.Err _) false])
        (match (compiler-load-core-macro-prelude-with-roots-cfg
          (sym_i64_env.sym-i64-empty)
          (ast.ast-place-shared-view roots)
          (parser.compiler-cfg-empty))
          [(ResultCompilerLoadWithPaths.Ok decls paths modules _)
            (and
              (=
                (compiler-load-decl-list-value-name-count
                  decls
                  "core-prelude-root-marker")
                1)
              (string.eq
                (compiler-load-test-path-at paths 0)
                (compiler-load-core-macro-prelude-path-shared-view))
              (string.eq
                (ast.ast-decl-module-list-get (& modules) 0 "")
                "stdlib.core_macros")
              (string.eq
                (ast.ast-decl-module-list-get
                  (& modules)
                  (- (ast.ast-decl-module-list-len (& modules)) 1)
                  "missing")
                ""))]
          [(ResultCompilerLoadWithPaths.Err _) false])
        (match (compiler-load-package-stdlib-prelude-file-with-roots-cfg
          (string.copy (& compiler-load-runtime-prelude-path))
          (sym_i64_env.sym-i64-empty)
          roots
          ""
          (compiler-pkg-deps-empty)
          (parser.compiler-cfg-empty))
          [(ResultCompilerLoadWithPaths.Ok decls paths modules _)
            (and
              (=
                (compiler-load-decl-list-value-name-count
                  decls
                  "prelude-root-marker")
                1)
              (string.eq
                (compiler-load-test-path-at paths 0)
                (compiler-load-runtime-prelude-path-shared-view))
              (string.eq
                (ast.ast-decl-module-list-get (& modules) 0 "")
                "stdlib.runtime"))]
          [(ResultCompilerLoadWithPaths.Err _) false])))))

;; `--stdlib-root` resolution searches roots in order; the first existing
;; candidate wins, so a missing leading root is skipped.
(define (compiler-load-stdlib-searched-root-ok?) : bool
  (begin
    (compiler-load-write-file-text
      "target/cl_ssr_mod.tl"
      "(module stdlib.cl_ssr_mod)
(define v : i64 1)")
    (compiler-load-write-file-text
      "target/cl_ssr_entry.tl"
      "(module ssr.entry)
(import stdlib.cl_ssr_mod as m)
(define (main) : i64 m.v)")
    (match (compiler-load-file-with-paths-and-roots
      "target/cl_ssr_entry.tl"
      (sym_i64_env.sym-i64-empty)
      (compiler-load-string-vec-two "target/cl_ssr_absent_root" "target"))
      [(ResultCompilerLoadWithPaths.Ok _ _ _ seen)
        (compiler-load-test-seen-contains? seen "stdlib.cl_ssr_mod")]
      [(ResultCompilerLoadWithPaths.Err _) false])))

;; A `stdlib/<x>` import found in no configured root reports a cannot-read
;; diagnostic naming the importer-relative candidate path.
(define (compiler-load-stdlib-unresolved-ok?) : bool
  (begin
    (compiler-load-write-file-text
      "target/cl_sur_entry.tl"
      "(module sur.entry)
(import stdlib.cl_sur_missing as m)
(define (main) : i64 0)")
    (match (compiler-load-file-with-paths-and-roots
      "target/cl_sur_entry.tl"
      (sym_i64_env.sym-i64-empty)
      (compiler-load-string-vec-one "target"))
      [(ResultCompilerLoadWithPaths.Err diag)
        (string.eq
          (cdiag.compiler-diagnostic-message (__tl-box-place diag))
          "compiler-load: cannot read import stdlib/cl_sur_missing.tl")]
      [(ResultCompilerLoadWithPaths.Ok _ _ _ _) false])))

;: --- typelisp.pkg manifest parser --------------------------------------------
;: Parse a `typelisp.pkg` manifest, an S-expression of the form
;:   (package (name "...") (version "...") (kind "bin") (entry "...")
;:            (dependencies (alias "path") ...))
;: into a structured value. Reuses the selfhost reader (`lex` + `result`)
;: instead of a
;: bespoke manifest tokenizer.
;: A parsed dependency: an import alias and its package-root path.
(defstruct CompilerPkgDep
  (alias String)
  (path String))

;: Alias->path dependency list from a parsed manifest, in manifest order.
(defstruct CompilerPkgDepList
  (slots (__tl_dyn-array CompilerPkgDep))
  (len i64))

;: Package dependencies preserve manifest order for deterministic builds while
;: indexing aliases for duplicate detection and `pkg:<alias>/...` resolution.
(defstruct CompilerPkgDeps
  (ordered CompilerPkgDepList))

;: Package artifact kind: binary executable or static library.
(defenum CompilerPkgKind
  (CompilerPkgKindBin)
  (CompilerPkgKindLib))

;: A parsed `typelisp.pkg` manifest.
;: One link scope's native inputs: ordered libraries, search paths, and raw
;: linker arguments. Order within each list is preserved from the manifest.
(defstruct CompilerPkgLinkSet
  (libraries fs.FsStringVector)
  (search-paths fs.FsStringVector)
  (args fs.FsStringVector))

;: Parsed `(link ...)` manifest section. `all` applies to every target; `linux`
;: and `windows` add per-target inputs. Empty lists mean the field was omitted.
(defstruct CompilerPkgLink
  (all CompilerPkgLinkSet)
  (linux CompilerPkgLinkSet)
  (windows CompilerPkgLinkSet))

(defenum ResultCompilerPkgLink
  (Ok CompilerPkgLink)
  (Err String))

;: Internal: a parsed list of `link` field string values, or a diagnostic.
(defenum ResultPkgStrVec
  (Ok fs.FsStringVector)
  (Err String))

(defstruct CompilerPkgManifest
  (name String)
  (version String)
  (kind CompilerPkgKind)
  (entry String)
  (deps CompilerPkgDeps)
  (link CompilerPkgLink))

;: Parse result: the manifest or a legacy string diagnostic.
(defenum ResultCompilerPkgManifest
  (Ok CompilerPkgManifest)
  (Err String))

;: Source-facing parse result: the manifest or a path/span-bearing diagnostic.
(defenum ResultCompilerPkgManifestDiagnostic
  (Ok CompilerPkgManifest)
  (Err (Box cdiag.CompilerDiagnostic)))

;: Internal: a single extracted string field value, or a diagnostic.
(defenum ResultPkgString
  (Ok String)
  (Err String))

;: Internal: a parsed package kind, or a diagnostic.
(defenum ResultCompilerPkgKind
  (Ok CompilerPkgKind)
  (Err String))

;: Internal: parsed dependencies, or a diagnostic.
(defenum ResultCompilerPkgDeps
  (Ok CompilerPkgDeps)
  (Err String))

;: Count the dependencies in a parsed list.
(define (compiler-pkg-dep-list-count [deps : (& deps CompilerPkgDepList)]) : i64
  deps.len)

(define (compiler-pkg-dep-list-at
  [deps : (& deps CompilerPkgDepList)]
  [index : i64]) : CompilerPkgDep
  (clone (array-ref deps.slots index)))

(define (compiler-pkg-dep-list-empty) : CompilerPkgDepList
  (CompilerPkgDepList (array.make-array CompilerPkgDep 0) 0))

(define (compiler-pkg-dep-list-copy-into
  [dst : (&mut dst (__tl_dyn-array CompilerPkgDep))]
  [src : (& src CompilerPkgDepList)]
  [dst-offset : i64]) : unit
  (let
    [n : i64 src.len]
    [index : i64 0]
    (while (< index n)
      (begin
        (set!
          (array-ref dst (+ dst-offset index))
          (clone (array-ref src.slots index)))
        (set! index (+ index 1))))))

;: Append `dep`. Every push right-sizes a fresh array, so callers that keep
;: extending the same list from several branches never share a buffer.
(define (compiler-pkg-dep-list-push
  [deps : CompilerPkgDepList]
  [dep : CompilerPkgDep]) : CompilerPkgDepList
  (let
    [n : i64 (compiler-pkg-dep-list-count deps)]
    [slots : (__tl_dyn-array CompilerPkgDep)
      (array.make-array CompilerPkgDep (+ n 1))]
    (begin
      (compiler-pkg-dep-list-copy-into (&mut slots) (& deps) 0)
      (set! (array-ref slots n) dep)
      (CompilerPkgDepList slots (+ n 1)))))

;: Prepend `dep`, right-sizing a fresh array like `compiler-pkg-dep-list-push`.
(define (compiler-pkg-dep-list-cons
  [dep : CompilerPkgDep]
  [deps : CompilerPkgDepList]) : CompilerPkgDepList
  (let
    [n : i64 (compiler-pkg-dep-list-count deps)]
    [slots : (__tl_dyn-array CompilerPkgDep)
      (array.make-array CompilerPkgDep (+ n 1))]
    (begin
      (set! (array-ref slots 0) dep)
      (compiler-pkg-dep-list-copy-into (&mut slots) (& deps) 1)
      (CompilerPkgDepList slots (+ n 1)))))

(define (compiler-pkg-deps-empty) : CompilerPkgDeps
  (CompilerPkgDeps (compiler-pkg-dep-list-empty)))

(define (compiler-pkg-deps-list [deps : CompilerPkgDeps]) : CompilerPkgDepList
  deps.ordered)

(define (compiler-pkg-deps-count [deps : (& deps CompilerPkgDeps)]) : i64
  deps.ordered.len)

(define (compiler-pkg-deps-alias-seen?
  [deps : CompilerPkgDeps]
  [target-alias : String]) : bool
  (let
    [ordered : CompilerPkgDepList (compiler-pkg-deps-list deps)]
    [index : i64 0]
    (begin
      (while (< index (compiler-pkg-dep-list-count ordered))
        (let
          [dep : CompilerPkgDep (compiler-pkg-dep-list-at ordered index)]
          (if (string.eq dep.alias target-alias)
            (return true)
            (set! index (+ index 1)))))
      false)))

(define (compiler-pkg-deps-cons
  [alias : String]
  [path : String]
  [tail : CompilerPkgDeps]) : CompilerPkgDeps
  (CompilerPkgDeps
    (compiler-pkg-dep-list-cons
      (CompilerPkgDep alias path)
      (compiler-pkg-deps-list tail))))

(define (compiler-pkg-deps-from-list [deps : CompilerPkgDepList]) : CompilerPkgDeps
  (CompilerPkgDeps deps))

(define (compiler-load-package-name-char? [c : char]) : bool
  (let
    [code : i64 (cast c : i64)]
    (or
      (and (>= code 48) (<= code 57))
      (and (>= code 65) (<= code 90))
      (and (>= code 97) (<= code 122))
      (= code 45)
      (= code 95))))

(define (compiler-load-package-token-valid? [value : String]) : bool
  (let
    [n : i64 (string.string-length value)]
    [i : i64 0]
    [ok : bool (> n 0)]
    (begin
      (while ok
        (if (< i n)
          (if (compiler-load-package-name-char? (string.string-ref value i))
            (set! i (+ i 1))
            (set! ok false))
          (set! ok false)))
      (= i n))))

(define (compiler-load-github-component-char? [c : char]) : bool
  (or (compiler-load-package-name-char? c) (= c '.')))

(define (compiler-load-github-component-valid? [value : String]) : bool
  (let
    [n : i64 (string.string-length value)]
    [i : i64 0]
    [ok : bool (> n 0)]
    (begin
      (while ok
        (if (< i n)
          (if (compiler-load-github-component-char? (string.string-ref value i))
            (set! i (+ i 1))
            (set! ok false))
          (set! ok false)))
      (= i n))))

(define (compiler-load-github-dependency-path? [path : String]) : bool
  (compiler-load-string-prefix-at? path "https://github.com/" 0))

(define (compiler-load-github-pin-kind-valid? [kind : String]) : bool
  (or (string.eq kind "rev") (string.eq kind "tag") (string.eq kind "branch")))

(define (compiler-load-github-address-body [address : String]) : String
  (if (compiler-load-string-prefix-at? address "github.com/" 0)
    (string.substring address 11 (- (string.string-length address) 11))
    address))

(define (compiler-load-github-address-error [alias : String]) : ResultPkgString
  (ResultPkgString.Err
    (str_cat.str-cat
      "manifest dependency `"
      alias
      "` github address must be `owner/repo` or `github.com/owner/repo`")))

(define (compiler-load-normalize-github-address
  [alias : String]
  [address : String]
  [pin-kind : String]
  [pin-value : String]) : ResultPkgString
  (let
    [body : String (compiler-load-github-address-body address)]
    [body-len : i64 (string.string-length body)]
    [slash : i64 (compiler-load-slash-index-from body 0 body-len)]
    (if (or (< slash 1) (>= slash (- body-len 1)))
      (compiler-load-github-address-error alias)
      (let
        [owner : String (string.substring body 0 slash)]
        [repo : String
          (string.substring body (+ slash 1) (- body-len (+ slash 1)))]
        (cond
          [(>=
              (compiler-load-slash-index-from
                repo
                0
                (string.string-length repo))
              0)
            (compiler-load-github-address-error alias)]
          [(not (compiler-load-github-component-valid? (clone owner)))
            (compiler-load-github-address-error alias)]
          [(not (compiler-load-github-component-valid? (clone repo)))
            (compiler-load-github-address-error alias)]
          [else
            (ResultPkgString.Ok
              (str_cat.str-cat
                "https://github.com/"
                owner
                "/"
                repo
                ".git#"
                pin-kind
                "="
                pin-value))])))))

(define (compiler-load-normal-relative-entry? [path : String]) : bool
  (compiler-load-safe-relative? path))

(define (compiler-load-symbol-text [name-id : ci.InternSyntaxId]) : String
  (reader.symbol-text-for-syntax-id name-id))

;; Manifest values outlive the reader's persistent intern arena because package
;; builds reset compiler state between inline-test phases. Materialize stored
;; values in the caller's arena without creating another intern entry.
(define (compiler-load-manifest-owned-intern-text [text-id : ci.InternId]) : String
  (let
    [text : String (ci.intern-id-str text-id)]
    (string.copy (& text))))

(define (compiler-load-manifest-owned-syntax-text [text-id : ci.InternSyntaxId]) : String
  (let
    [text : String (ci.intern-syntax-id-text text-id)]
    (string.copy (& text))))

;: Extract a single `"value"` from a field tail `("value")`.
(define (compiler-load-manifest-string-value
  [ftail : reader.Sexpr]
  [fname : String]) : ResultPkgString
  (match (reader.sexpr-view ftail)
    [(reader.SexprView.Cons vhead vrest)
      (match (reader.sexpr-view vhead)
        [(reader.SexprView.Str val-id)
          (match (reader.sexpr-view vrest)
            [(reader.SexprView.Nil)
              (ResultPkgString.Ok
                (compiler-load-manifest-owned-intern-text val-id))]
            [_
              (ResultPkgString.Err
                (str_cat.str-cat
                  "manifest field `"
                  fname
                  "` takes a single string value"))])]
        [_
          (ResultPkgString.Err
            (str_cat.str-cat
              "manifest field `"
              fname
              "` must have a string value"))])]
    [_
      (ResultPkgString.Err
        (str_cat.str-cat "manifest field `" fname "` must have a string value"))]))

(define (compiler-load-manifest-github-pin
  [alias : String]
  [address : String]
  [pin-form : reader.Sexpr]) : ResultPkgString
  (match (reader.sexpr-view pin-form)
    [(reader.SexprView.Cons pin-kind-node pin-tail)
      (match (reader.sexpr-view pin-kind-node)
        [(reader.SexprView.Sym pin-kind)
          (if (compiler-load-github-pin-kind-valid?
            (compiler-load-symbol-text pin-kind))
            (match (reader.sexpr-view pin-tail)
              [(reader.SexprView.Cons pin-value-node end)
                (match (reader.sexpr-view end)
                  [(reader.SexprView.Nil)
                    (match (reader.sexpr-view pin-value-node)
                      [(reader.SexprView.Str pin-value-id)
                        (let
                          [pin-value : String (ci.intern-id-str pin-value-id)]
                          (if (string.eq pin-value "")
                            (ResultPkgString.Err
                              (str_cat.str-cat
                                "manifest dependency `"
                                alias
                                "` github pin must not be empty"))
                            (compiler-load-normalize-github-address
                              alias
                              address
                              (compiler-load-symbol-text pin-kind)
                              pin-value)))]
                      [_
                        (ResultPkgString.Err
                          (str_cat.str-cat
                            "manifest dependency `"
                            alias
                            "` github pin must be a single string value"))])]
                  [_
                    (ResultPkgString.Err
                      (str_cat.str-cat
                        "manifest dependency `"
                        alias
                        "` github pin must be a single string value"))])]
              [_
                (ResultPkgString.Err
                  (str_cat.str-cat
                    "manifest dependency `"
                    alias
                    "` github pin must be a single string value"))])
            (ResultPkgString.Err
              (str_cat.str-cat
                "manifest dependency `"
                alias
                "` github pin must be rev, tag, or branch")))]
        [_
          (ResultPkgString.Err
            (str_cat.str-cat
              "manifest dependency `"
              alias
              "` github source requires exactly one rev, tag, or branch pin"))])]
    [_
      (ResultPkgString.Err
        (str_cat.str-cat
          "manifest dependency `"
          alias
          "` github source requires exactly one rev, tag, or branch pin"))]))

(define (compiler-load-manifest-github-value
  [alias : String]
  [source-tail : reader.Sexpr]) : ResultPkgString
  (match (reader.sexpr-view source-tail)
    [(reader.SexprView.Cons address-node after-address)
      (match (reader.sexpr-view address-node)
        [(reader.SexprView.Str address-id)
          (let
            [address : String (ci.intern-id-str address-id)]
            (match (reader.sexpr-view after-address)
              [(reader.SexprView.Cons pin-form end)
                (match (reader.sexpr-view end)
                  [(reader.SexprView.Nil)
                    (compiler-load-manifest-github-pin alias address pin-form)]
                  [_
                    (ResultPkgString.Err
                      (str_cat.str-cat
                        "manifest dependency `"
                        alias
                        "` github source requires exactly one rev, tag, or branch pin"))])]
              [_
                (ResultPkgString.Err
                  (str_cat.str-cat
                    "manifest dependency `"
                    alias
                    "` github source requires exactly one rev, tag, or branch pin"))]))]
        [_
          (ResultPkgString.Err
            (str_cat.str-cat
              "manifest dependency `"
              alias
              "` github source must be `(github \"owner/repo\" (rev|tag|branch \"pin\"))`"))])]
    [_
      (ResultPkgString.Err
        (str_cat.str-cat
          "manifest dependency `"
          alias
          "` github source must be `(github \"owner/repo\" (rev|tag|branch \"pin\"))`"))]))

(define (compiler-load-manifest-dependency-value
  [etail : reader.Sexpr]
  [alias : String]) : ResultPkgString
  (match (reader.sexpr-view etail)
    [(reader.SexprView.Cons vhead vrest)
      (match (reader.sexpr-view vrest)
        [(reader.SexprView.Nil)
          (match (reader.sexpr-view vhead)
            [(reader.SexprView.Str path-id)
              (ResultPkgString.Ok
                (compiler-load-manifest-owned-intern-text path-id))]
            [(reader.SexprView.Cons source-kind-node source-tail)
              (match (reader.sexpr-view source-kind-node)
                [(reader.SexprView.Sym source-kind)
                  (if (string.eq
                    (compiler-load-symbol-text source-kind)
                    "github")
                    (compiler-load-manifest-github-value alias source-tail)
                    (ResultPkgString.Err
                      (str_cat.str-cat
                        "manifest dependency `"
                        alias
                        "` must be a path string or github source")))]
                [_
                  (ResultPkgString.Err
                    (str_cat.str-cat
                      "manifest dependency `"
                      alias
                      "` must be a path string or github source"))])]
            [_
              (ResultPkgString.Err
                (str_cat.str-cat
                  "manifest dependency `"
                  alias
                  "` must be a path string or github source"))])]
        [_
          (ResultPkgString.Err
            (str_cat.str-cat
              "manifest dependency `"
              alias
              "` takes a single path string or github source"))])]
    [_
      (ResultPkgString.Err
        (str_cat.str-cat
          "manifest dependency `"
          alias
          "` must be a path string or github source"))]))

(define (compiler-load-manifest-kind-token [val : String]) : ResultCompilerPkgKind
  (if (string.eq val "bin")
    (ResultCompilerPkgKind.Ok (CompilerPkgKindBin))
    (if (or (string.eq val "staticlib") (string.eq val "lib"))
      (ResultCompilerPkgKind.Ok (CompilerPkgKindLib))
      (ResultCompilerPkgKind.Err
        "manifest field `kind` must be `bin`, `staticlib`, or `lib`"))))

(define (compiler-load-manifest-kind-value [ftail : reader.Sexpr]) : ResultCompilerPkgKind
  (match (reader.sexpr-view ftail)
    [(reader.SexprView.Cons vhead vrest)
      (match (reader.sexpr-view vrest)
        [(reader.SexprView.Nil)
          (match (reader.sexpr-view vhead)
            [(reader.SexprView.Str val-id)
              (compiler-load-manifest-kind-token (ci.intern-id-str val-id))]
            [(reader.SexprView.Sym val)
              (compiler-load-manifest-kind-token
                (compiler-load-symbol-text val))]
            [_
              (ResultCompilerPkgKind.Err
                "manifest field `kind` must have a string or symbol value")])]
        [_
          (ResultCompilerPkgKind.Err
            "manifest field `kind` takes a single value")])]
    [_
      (ResultCompilerPkgKind.Err
        "manifest field `kind` must have a string or symbol value")]))

(define (compiler-load-manifest-cons-dep
  [alias : String]
  [path : String]
  [rest : reader.Sexpr]) : ResultCompilerPkgDeps
  (cond
    [(string.eq alias "")
      (ResultCompilerPkgDeps.Err "dependency alias must not be empty")]
    [(not (compiler-load-package-token-valid? (clone alias)))
      (ResultCompilerPkgDeps.Err
        "dependency alias may only contain ASCII letters, digits, '-' and '_'")]
    [(string.eq path "")
      (ResultCompilerPkgDeps.Err
        (str_cat.str-cat
          "manifest dependency `"
          alias
          "` path must not be empty"))]
    [else
      (match (compiler-load-manifest-parse-deps rest)
        [(ResultCompilerPkgDeps.Err m) (ResultCompilerPkgDeps.Err m)]
        [(ResultCompilerPkgDeps.Ok tail-deps)
          (if (compiler-pkg-deps-alias-seen?
            (ast.ast-place-shared-view tail-deps)
            (clone alias))
            (ResultCompilerPkgDeps.Err
              (str_cat.str-cat "duplicate dependency alias `" alias "`"))
            (ResultCompilerPkgDeps.Ok
              (compiler-pkg-deps-cons alias path tail-deps)))])]))

;: Parse the `(alias "path") ...` entries of a `(dependencies ...)` field.
(define (compiler-load-manifest-parse-deps [entries : reader.Sexpr]) : ResultCompilerPkgDeps
  (match (reader.sexpr-view entries)
    [(reader.SexprView.Nil)
      (ResultCompilerPkgDeps.Ok (compiler-pkg-deps-empty))]
    [(reader.SexprView.Cons entry rest)
      (match (reader.sexpr-view entry)
        [(reader.SexprView.Cons ehead etail)
          (match (reader.sexpr-view ehead)
            [(reader.SexprView.Sym alias)
              (let
                [alias-text : String
                  (compiler-load-manifest-owned-syntax-text alias)]
                (match (compiler-load-manifest-dependency-value
                  etail
                  (clone alias-text))
                  [(ResultPkgString.Err m) (ResultCompilerPkgDeps.Err m)]
                  [(ResultPkgString.Ok path)
                    (compiler-load-manifest-cons-dep alias-text path rest)]))]
            [_
              (ResultCompilerPkgDeps.Err
                "dependency entries must start with an alias name")])]
        [_
          (ResultCompilerPkgDeps.Err
            "dependency entries must be lists like `(alias \"path\")`")])]
    [_
      (ResultCompilerPkgDeps.Err
        "`dependencies` must be a list of `(alias \"path\")` or `(alias (github ...))` entries")]))

;: An empty link scope (no libraries, search paths, or args).
(define (compiler-pkg-link-set-empty) : CompilerPkgLinkSet
  (CompilerPkgLinkSet
    (fs.string-vector-new)
    (fs.string-vector-new)
    (fs.string-vector-new)))

;: An empty `(link ...)` section (every scope empty).
(define (compiler-pkg-link-empty) : CompilerPkgLink
  (CompilerPkgLink
    (compiler-pkg-link-set-empty)
    (compiler-pkg-link-set-empty)
    (compiler-pkg-link-set-empty)))

;: Map a `link` sub-field name to its scope index, or -1 when unknown.
;: scope: 0 all-target, 1 linux, 2 windows.
(define (compiler-load-link-field-scope [fname : String]) : i64
  (cond
    [(string.eq fname "libraries") 0]
    [(string.eq fname "search-paths") 0]
    [(string.eq fname "args") 0]
    [(string.eq fname "linux-libraries") 1]
    [(string.eq fname "linux-search-paths") 1]
    [(string.eq fname "linux-args") 1]
    [(string.eq fname "windows-libraries") 2]
    [(string.eq fname "windows-search-paths") 2]
    [(string.eq fname "windows-args") 2]
    [else -1]))

;: Map a `link` sub-field name to its category index, or -1 when unknown.
;: category: 0 libraries, 1 search-paths, 2 args.
(define (compiler-load-link-field-category [fname : String]) : i64
  (cond
    [(string.eq fname "libraries") 0]
    [(string.eq fname "search-paths") 1]
    [(string.eq fname "args") 2]
    [(string.eq fname "linux-libraries") 0]
    [(string.eq fname "linux-search-paths") 1]
    [(string.eq fname "linux-args") 2]
    [(string.eq fname "windows-libraries") 0]
    [(string.eq fname "windows-search-paths") 1]
    [(string.eq fname "windows-args") 2]
    [else -1]))

;: The link scope's set for a scope index.
(define (compiler-pkg-link-scope-set [link : CompilerPkgLink] [scope : i64]) : CompilerPkgLinkSet
  (if (= scope 0)
    link.all
    (if (= scope 1)
      link.linux
      link.windows)))

;: Return `link` with the given scope's set replaced.
(define (compiler-pkg-link-replace-scope
  [link : CompilerPkgLink]
  [scope : i64]
  [set : CompilerPkgLinkSet]) : CompilerPkgLink
  (if (= scope 0)
    (CompilerPkgLink set link.linux link.windows)
    (if (= scope 1)
      (CompilerPkgLink link.all set link.windows)
      (CompilerPkgLink link.all link.linux set))))

;: The category's value list within a link scope set.
(define (compiler-pkg-link-set-category [set : CompilerPkgLinkSet] [cat : i64]) : fs.FsStringVector
  (if (= cat 0)
    set.libraries
    (if (= cat 1)
      set.search-paths
      set.args)))

;: Return `set` with the given category's value list replaced.
(define (compiler-pkg-link-set-replace-category
  [set : CompilerPkgLinkSet]
  [cat : i64]
  [vec : fs.FsStringVector]) : CompilerPkgLinkSet
  (if (= cat 0)
    (CompilerPkgLinkSet vec set.search-paths set.args)
    (if (= cat 1)
      (CompilerPkgLinkSet set.libraries vec set.args)
      (CompilerPkgLinkSet set.libraries set.search-paths vec))))

;: The value list for a (scope, category) pair.
(define (compiler-pkg-link-get-vec
  [link : CompilerPkgLink]
  [scope : i64]
  [cat : i64]) : fs.FsStringVector
  (compiler-pkg-link-set-category
    (compiler-pkg-link-scope-set (clone link) scope)
    cat))

;: Return `link` with the (scope, category) value list replaced.
(define (compiler-pkg-link-set-vec
  [link : CompilerPkgLink]
  [scope : i64]
  [cat : i64]
  [vec : fs.FsStringVector]) : CompilerPkgLink
  (compiler-pkg-link-replace-scope
    (clone link)
    scope
    (compiler-pkg-link-set-replace-category
      (compiler-pkg-link-scope-set (clone link) scope)
      cat
      vec)))

;: Parse the one-or-more non-empty string values of one `link` sub-field.
(define (compiler-load-manifest-link-values
  [values : reader.Sexpr]
  [fname : String]
  [acc : fs.FsStringVector]) : ResultPkgStrVec
  (match (reader.sexpr-view values)
    [(reader.SexprView.Nil)
      (if (= (fs.string-vector-len (& acc)) 0)
        (ResultPkgStrVec.Err
          (str_cat.str-cat
            "`link` field `"
            fname
            "` requires at least one value"))
        (ResultPkgStrVec.Ok acc))]
    [(reader.SexprView.Cons vhead vrest)
      (match (reader.sexpr-view vhead)
        [(reader.SexprView.Str val-id)
          (let
            [val : String (ci.intern-id-str val-id)]
            (if (string.eq val "")
              (ResultPkgStrVec.Err
                (str_cat.str-cat
                  "`link` field `"
                  fname
                  "` values must not be empty"))
              (let
                [out : fs.FsStringVector
                  (owned_view.compiler-owned-shared-view acc)]
                (begin
                  (fs.string-vector-push!
                    (&mut out)
                    (compiler-load-manifest-owned-intern-text val-id))
                  (compiler-load-manifest-link-values vrest fname out)))))]
        [_
          (ResultPkgStrVec.Err
            (str_cat.str-cat "`link` field `" fname "` values must be strings"))])]
    [_
      (ResultPkgStrVec.Err
        (str_cat.str-cat
          "`link` field `"
          fname
          "` must be a list of string values"))]))

;: Store one parsed sub-field into the accumulating link section, rejecting
;: unknown field names and a field that was already provided.
(define (compiler-load-manifest-link-store
  [acc : CompilerPkgLink]
  [fname : String]
  [values : fs.FsStringVector]) : ResultCompilerPkgLink
  (let
    [scope : i64 (compiler-load-link-field-scope (clone fname))]
    [cat : i64 (compiler-load-link-field-category (clone fname))]
    (if (or (< scope 0) (< cat 0))
      (ResultCompilerPkgLink.Err
        (str_cat.str-cat "unknown `link` field `" fname "`"))
      (let
        [existing : fs.FsStringVector
          (compiler-pkg-link-get-vec (ast.ast-place-shared-view acc) scope cat)]
        (if (> (fs.string-vector-len (& existing)) 0)
          (ResultCompilerPkgLink.Err
            (str_cat.str-cat "duplicate `link` field `" fname "`"))
          (ResultCompilerPkgLink.Ok
            (compiler-pkg-link-set-vec acc scope cat values)))))))

;: Walk the `(field "...")` entries of a `(link ...)` section.
(define (compiler-load-manifest-parse-link-into
  [entries : reader.Sexpr]
  [acc : CompilerPkgLink]) : ResultCompilerPkgLink
  (match (reader.sexpr-view entries)
    [(reader.SexprView.Nil) (ResultCompilerPkgLink.Ok acc)]
    [(reader.SexprView.Cons entry rest)
      (match (reader.sexpr-view entry)
        [(reader.SexprView.Cons ehead etail)
          (match (reader.sexpr-view ehead)
            [(reader.SexprView.Sym fname)
              (match (compiler-load-manifest-link-values
                etail
                (compiler-load-symbol-text fname)
                (fs.string-vector-new))
                [(ResultPkgStrVec.Err m) (ResultCompilerPkgLink.Err m)]
                [(ResultPkgStrVec.Ok values)
                  (match (compiler-load-manifest-link-store
                    acc
                    (compiler-load-symbol-text fname)
                    values)
                    [(ResultCompilerPkgLink.Err m)
                      (ResultCompilerPkgLink.Err m)]
                    [(ResultCompilerPkgLink.Ok acc2)
                      (compiler-load-manifest-parse-link-into rest acc2)])])]
            [_
              (ResultCompilerPkgLink.Err
                "`link` entries must start with a field name")])]
        [_
          (ResultCompilerPkgLink.Err
            "`link` entries must be lists like `(libraries \"...\")`")])]
    [_
      (ResultCompilerPkgLink.Err
        "`link` must be a list of `(field \"...\")` entries")]))

;: Parse a `(link ...)` manifest section into a CompilerPkgLink.
(define (compiler-load-manifest-parse-link [entries : reader.Sexpr]) : ResultCompilerPkgLink
  (compiler-load-manifest-parse-link-into entries (compiler-pkg-link-empty)))

(define (compiler-load-manifest-default-entry [kind : CompilerPkgKind]) : String
  (match kind
    [(CompilerPkgKindBin) "src/main.tl"]
    [(CompilerPkgKindLib) "src/lib.tl"]))

(define (compiler-load-manifest-with-kind
  [manifest : CompilerPkgManifest]
  [kind : CompilerPkgKind]) : CompilerPkgManifest
  (CompilerPkgManifest
    manifest.name
    manifest.version
    kind
    (compiler-load-manifest-default-entry kind)
    manifest.deps
    manifest.link))

;: Walk the package fields, accumulating name/version/kind/entry/deps, then
;: check required fields and synthesize convention defaults for omitted kind
;: and entry.
(define (compiler-load-manifest-fields
  [fields : reader.Sexpr]
  [name : String]
  [has-name : bool]
  [version : String]
  [has-version : bool]
  [kind : CompilerPkgKind]
  [has-kind : bool]
  [entry : String]
  [has-entry : bool]
  [has-deps : bool]
  [deps : CompilerPkgDeps]
  [has-link : bool]
  [link : CompilerPkgLink]) : ResultCompilerPkgManifest
  (match (reader.sexpr-view fields)
    [(reader.SexprView.Nil)
      (let
        [final-entry : String
          (if has-entry
            entry
            (compiler-load-manifest-default-entry kind))]
        (cond
          [(not has-name)
            (ResultCompilerPkgManifest.Err
              "manifest missing required field `name`")]
          [(string.eq name "")
            (ResultCompilerPkgManifest.Err
              "manifest field `name` must not be empty")]
          [(not (compiler-load-package-token-valid? (clone name)))
            (ResultCompilerPkgManifest.Err
              "manifest field `name` may only contain ASCII letters, digits, '-' and '_'")]
          [(not has-version)
            (ResultCompilerPkgManifest.Err
              "manifest missing required field `version`")]
          [(string.eq version "")
            (ResultCompilerPkgManifest.Err
              "manifest field `version` must not be empty")]
          [(string.eq final-entry "")
            (ResultCompilerPkgManifest.Err
              "manifest field `entry` must not be empty")]
          [(not (compiler-load-normal-relative-entry? (clone final-entry)))
            (ResultCompilerPkgManifest.Err
              "manifest field `entry` must be a normal relative path below the manifest directory")]
          [else
            (ResultCompilerPkgManifest.Ok
              (CompilerPkgManifest name version kind final-entry deps link))]))]
    [(reader.SexprView.Cons field rest)
      (match (reader.sexpr-view field)
        [(reader.SexprView.Cons fhead ftail)
          (match (reader.sexpr-view fhead)
            [(reader.SexprView.Sym fname)
              (cond
                [(string.eq (compiler-load-symbol-text fname) "dependencies")
                  (if has-deps
                    (ResultCompilerPkgManifest.Err
                      "duplicate manifest field `dependencies`")
                    (match (compiler-load-manifest-parse-deps ftail)
                      [(ResultCompilerPkgDeps.Err m)
                        (ResultCompilerPkgManifest.Err m)]
                      [(ResultCompilerPkgDeps.Ok parsed-deps)
                        (compiler-load-manifest-fields
                          rest
                          name
                          has-name
                          version
                          has-version
                          kind
                          has-kind
                          entry
                          has-entry
                          true
                          parsed-deps
                          has-link
                          link)]))]
                [(string.eq (compiler-load-symbol-text fname) "link")
                  (if has-link
                    (ResultCompilerPkgManifest.Err
                      "duplicate manifest field `link`")
                    (match (compiler-load-manifest-parse-link ftail)
                      [(ResultCompilerPkgLink.Err m)
                        (ResultCompilerPkgManifest.Err m)]
                      [(ResultCompilerPkgLink.Ok parsed-link)
                        (compiler-load-manifest-fields
                          rest
                          name
                          has-name
                          version
                          has-version
                          kind
                          has-kind
                          entry
                          has-entry
                          has-deps
                          deps
                          true
                          parsed-link)]))]
                [(string.eq (compiler-load-symbol-text fname) "name")
                  (if has-name
                    (ResultCompilerPkgManifest.Err
                      "duplicate manifest field `name`")
                    (match (compiler-load-manifest-string-value
                      ftail
                      (compiler-load-symbol-text fname))
                      [(ResultPkgString.Err m)
                        (ResultCompilerPkgManifest.Err m)]
                      [(ResultPkgString.Ok val)
                        (compiler-load-manifest-fields
                          rest
                          val
                          true
                          version
                          has-version
                          kind
                          has-kind
                          entry
                          has-entry
                          has-deps
                          deps
                          has-link
                          link)]))]
                [(string.eq (compiler-load-symbol-text fname) "version")
                  (if has-version
                    (ResultCompilerPkgManifest.Err
                      "duplicate manifest field `version`")
                    (match (compiler-load-manifest-string-value
                      ftail
                      (compiler-load-symbol-text fname))
                      [(ResultPkgString.Err m)
                        (ResultCompilerPkgManifest.Err m)]
                      [(ResultPkgString.Ok val)
                        (compiler-load-manifest-fields
                          rest
                          name
                          has-name
                          val
                          true
                          kind
                          has-kind
                          entry
                          has-entry
                          has-deps
                          deps
                          has-link
                          link)]))]
                [(string.eq (compiler-load-symbol-text fname) "kind")
                  (if has-kind
                    (ResultCompilerPkgManifest.Err
                      "duplicate manifest field `kind`")
                    (match (compiler-load-manifest-kind-value ftail)
                      [(ResultCompilerPkgKind.Err m)
                        (ResultCompilerPkgManifest.Err m)]
                      [(ResultCompilerPkgKind.Ok val)
                        (compiler-load-manifest-fields
                          rest
                          name
                          has-name
                          version
                          has-version
                          val
                          true
                          entry
                          has-entry
                          has-deps
                          deps
                          has-link
                          link)]))]
                [(string.eq (compiler-load-symbol-text fname) "entry")
                  (if has-entry
                    (ResultCompilerPkgManifest.Err
                      "duplicate manifest field `entry`")
                    (match (compiler-load-manifest-string-value
                      ftail
                      (compiler-load-symbol-text fname))
                      [(ResultPkgString.Err m)
                        (ResultCompilerPkgManifest.Err m)]
                      [(ResultPkgString.Ok val)
                        (compiler-load-manifest-fields
                          rest
                          name
                          has-name
                          version
                          has-version
                          kind
                          has-kind
                          val
                          true
                          has-deps
                          deps
                          has-link
                          link)]))]
                [else
                  (ResultCompilerPkgManifest.Err
                    (str_cat.str-cat
                      "unknown manifest field `"
                      (compiler-load-symbol-text fname)
                      "`"))])]
            [_
              (ResultCompilerPkgManifest.Err
                "package fields must start with a field name")])]
        [_
          (ResultCompilerPkgManifest.Err
            "package fields must be lists like `(name \"...\")`")])]
    [_
      (ResultCompilerPkgManifest.Err
        "package fields must be lists like `(name \"...\")`")]))

;: Parse the top-level `(package ...)` form.
(define (compiler-load-manifest-from-form [form : reader.Sexpr]) : ResultCompilerPkgManifest
  (match (reader.sexpr-view form)
    [(reader.SexprView.Cons head rest)
      (match (reader.sexpr-view head)
        [(reader.SexprView.Sym s)
          (if (string.eq (compiler-load-symbol-text s) "package")
            (compiler-load-manifest-fields
              rest
              ""
              false
              ""
              false
              (CompilerPkgKindBin)
              false
              ""
              false
              false
              (compiler-pkg-deps-empty)
              false
              (compiler-pkg-link-empty))
            (ResultCompilerPkgManifest.Err
              (str_cat.str-cat
                "expected `package` form, got `"
                (compiler-load-symbol-text s)
                "`")))]
        [_ (ResultCompilerPkgManifest.Err "manifest must start with `package`")])]
    [_
      (ResultCompilerPkgManifest.Err "manifest must be a `(package ...)` form")]))

(define (compiler-load-manifest-fields-have?
  [fields : reader.Sexpr]
  [target : (& target str)]) : bool
  (match (reader.sexpr-view fields)
    [(reader.SexprView.Nil) false]
    [(reader.SexprView.Cons field rest)
      (let
        [tail-has : bool (compiler-load-manifest-fields-have? rest target)]
        (match (reader.sexpr-view field)
          [(reader.SexprView.Cons fhead _)
            (match (reader.sexpr-view fhead)
              [(reader.SexprView.Sym name)
                (or
                  (string.eq (compiler-load-symbol-text name) target)
                  tail-has)]
              [_ tail-has])]
          [_ tail-has]))]
    [_ false]))

(define (compiler-load-manifest-form-has-field?
  [form : reader.Sexpr]
  [target : (& target str)]) : bool
  (match (reader.sexpr-view form)
    [(reader.SexprView.Cons head rest)
      (match (reader.sexpr-view head)
        [(reader.SexprView.Sym s)
          (if (string.eq (compiler-load-symbol-text s) "package")
            (compiler-load-manifest-fields-have? rest target)
            false)]
        [_ false])]
    [_ false]))

(define (compiler-load-manifest-needs-kind-inference? [form : reader.Sexpr]) : bool
  (and
    (not (compiler-load-manifest-form-has-field? (clone form) "kind"))
    (not (compiler-load-manifest-form-has-field? form "entry"))))

(define (compiler-load-manifest-convention-path
  [manifest-path : (& manifest-path str)]
  [relative : String]) : String
  (compiler-load-join-root-path (compiler-load-dirname manifest-path) relative))

(define (compiler-load-manifest-infer-kind-from-files [manifest-path : String]) : ResultCompilerPkgKind
  (let
    [has-main : bool
      (io.file-exists?
        (compiler-load-manifest-convention-path manifest-path "src/main.tl"))]
    [has-lib : bool
      (io.file-exists?
        (compiler-load-manifest-convention-path manifest-path "src/lib.tl"))]
    (cond
      [(and has-main (not has-lib))
        (ResultCompilerPkgKind.Ok (CompilerPkgKindBin))]
      [(and has-lib (not has-main))
        (ResultCompilerPkgKind.Ok (CompilerPkgKindLib))]
      [(and has-main has-lib)
        (ResultCompilerPkgKind.Err
          "manifest omits `kind` and `entry`, but both `src/main.tl` and `src/lib.tl` exist; add explicit `kind` or `entry`")]
      [else
        (ResultCompilerPkgKind.Err
          "manifest omits `kind` and `entry`, but neither `src/main.tl` nor `src/lib.tl` exists; add `kind` and `entry` or create a conventional entry file")])))

;: Preserve the legacy `manifest: ...` syntax-error message while attaching the
;: reader span to the source-facing diagnostic result.
(define (compiler-load-manifest-source-error-diagnostic
  [path : String]
  [err : token.SourceError]) : cdiag.CompilerDiagnostic
  (cdiag.compiler-diagnostic-from-span
    path
    (token.source-error-span (clone err))
    (str_cat.str-cat "manifest: " (token.source-error-message err))))

(define (compiler-load-manifest-validation-diagnostic
  [path : String]
  [form : reader.SpannedSexpr]
  [message : String]) : cdiag.CompilerDiagnostic
  (cdiag.compiler-diagnostic-from-span
    path
    (reader.spanned-sexpr-span form)
    message))

(define (compiler-load-manifest-apply-kind-inference
  [path : String]
  [form : reader.SpannedSexpr]
  [manifest : CompilerPkgManifest]) : ResultCompilerPkgManifestDiagnostic
  (let
    [raw-form : reader.Sexpr
      (reader.spanned-sexpr-form (ast.ast-place-shared-view form))]
    (if (compiler-load-manifest-needs-kind-inference? raw-form)
      (match (compiler-load-manifest-infer-kind-from-files (clone path))
        [(ResultCompilerPkgKind.Ok kind)
          (ResultCompilerPkgManifestDiagnostic.Ok
            (compiler-load-manifest-with-kind manifest kind))]
        [(ResultCompilerPkgKind.Err message)
          (ResultCompilerPkgManifestDiagnostic.Err
            (box
              (compiler-load-manifest-validation-diagnostic path form message)))])
      (ResultCompilerPkgManifestDiagnostic.Ok manifest))))

(define (compiler-load-parse-manifest-form-diagnostic
  [path : String]
  [form : reader.SpannedSexpr]) : ResultCompilerPkgManifestDiagnostic
  (match (compiler-load-manifest-from-form
    (reader.spanned-sexpr-form (ast.ast-place-shared-view form)))
    [(ResultCompilerPkgManifest.Ok manifest)
      (ResultCompilerPkgManifestDiagnostic.Ok manifest)]
    [(ResultCompilerPkgManifest.Err message)
      (ResultCompilerPkgManifestDiagnostic.Err
        (box (compiler-load-manifest-validation-diagnostic path form message)))]))

(define (compiler-load-parse-manifest-form-diagnostic-infer-kind
  [path : String]
  [form : reader.SpannedSexpr]) : ResultCompilerPkgManifestDiagnostic
  (match (compiler-load-manifest-from-form
    (reader.spanned-sexpr-form (ast.ast-place-shared-view form)))
    [(ResultCompilerPkgManifest.Ok manifest)
      (compiler-load-manifest-apply-kind-inference path form manifest)]
    [(ResultCompilerPkgManifest.Err message)
      (ResultCompilerPkgManifestDiagnostic.Err
        (box (compiler-load-manifest-validation-diagnostic path form message)))]))

;: Parse a `typelisp.pkg` manifest source string into a structured manifest,
;: preserving manifest path/span identity for source-facing errors.
(define (compiler-load-parse-manifest-diagnostic
  [path : String]
  [source : String]) : ResultCompilerPkgManifestDiagnostic
  (let
    [mark : i64 (reader.sp-node-pool-len)]
    [sexpr-mark : i64 (reader.sexpr-node-pool-len)]
    [result : ResultCompilerPkgManifestDiagnostic
      (match (lexer.spanned-result source)
        [(lexer.ResultSpannedTokens.Err err)
          (ResultCompilerPkgManifestDiagnostic.Err
            (box (compiler-load-manifest-source-error-diagnostic path err)))]
        [(lexer.ResultSpannedTokens.Ok toks)
          (match (reader.spanned-result toks)
            [(reader.ResultSpannedSexpr.Err err)
              (ResultCompilerPkgManifestDiagnostic.Err
                (box (compiler-load-manifest-source-error-diagnostic path err)))]
            [(reader.ResultSpannedSexpr.Ok form)
              (compiler-load-parse-manifest-form-diagnostic path form)])])]
    (begin
      (reader.sp-node-pool-truncate! mark)
      (reader.sexpr-node-pool-truncate! sexpr-mark)
      result)))

(define (compiler-load-parse-manifest-diagnostic-infer-kind
  [path : String]
  [source : String]) : ResultCompilerPkgManifestDiagnostic
  (let
    [mark : i64 (reader.sp-node-pool-len)]
    [sexpr-mark : i64 (reader.sexpr-node-pool-len)]
    [result : ResultCompilerPkgManifestDiagnostic
      (match (lexer.spanned-result source)
        [(lexer.ResultSpannedTokens.Err err)
          (ResultCompilerPkgManifestDiagnostic.Err
            (box (compiler-load-manifest-source-error-diagnostic path err)))]
        [(lexer.ResultSpannedTokens.Ok toks)
          (match (reader.spanned-result toks)
            [(reader.ResultSpannedSexpr.Err err)
              (ResultCompilerPkgManifestDiagnostic.Err
                (box (compiler-load-manifest-source-error-diagnostic path err)))]
            [(reader.ResultSpannedSexpr.Ok form)
              (compiler-load-parse-manifest-form-diagnostic-infer-kind
                path
                form)])])]
    (begin
      (reader.sp-node-pool-truncate! mark)
      (reader.sexpr-node-pool-truncate! sexpr-mark)
      result)))

;: Parse a manifest source string into a structured manifest. This compatibility
;: wrapper keeps existing in-memory parser callers and message-only tests stable.
(define (compiler-load-parse-manifest [source : String]) : ResultCompilerPkgManifest
  (match (compiler-load-parse-manifest-diagnostic "" source)
    [(ResultCompilerPkgManifestDiagnostic.Ok manifest)
      (ResultCompilerPkgManifest.Ok manifest)]
    [(ResultCompilerPkgManifestDiagnostic.Err diag)
      (ResultCompilerPkgManifest.Err
        (cdiag.compiler-diagnostic-message (__tl-box-place diag)))]))

;: Self-test: a full manifest parses with the expected fields + dependency
;: count.
(define (compiler-load-manifest-valid-full-ok?) : bool
  (match (compiler-load-parse-manifest
    "(package (name \"demo\") (version \"0.1.0\") (kind \"bin\") (entry \"src/main.tl\") (dependencies (math \"../math\") (util \"../util\")))")
    [(ResultCompilerPkgManifest.Ok m)
      (and
        (string.eq m.name "demo")
        (string.eq m.version "0.1.0")
        (match m.kind
          [(CompilerPkgKindBin)
            (and
              (string.eq m.entry "src/main.tl")
              (= (compiler-pkg-deps-count m.deps) 2))]
          [(CompilerPkgKindLib) false]))]
    [(ResultCompilerPkgManifest.Err _) false]))

;: Self-test: a manifest without a `dependencies` field parses with no deps.
(define (compiler-load-manifest-valid-nodeps-ok?) : bool
  (match (compiler-load-parse-manifest
    "(package (name \"x\") (version \"1\") (kind staticlib))")
    [(ResultCompilerPkgManifest.Ok m)
      (match m.kind
        [(CompilerPkgKindLib)
          (and
            (string.eq m.entry "src/lib.tl")
            (= (compiler-pkg-deps-count m.deps) 0))]
        [(CompilerPkgKindBin) false])]
    [(ResultCompilerPkgManifest.Err _) false]))

(define (compiler-load-manifest-default-bin-ok?) : bool
  (match (compiler-load-parse-manifest
    "(package (name \"default_bin\") (version \"1\"))")
    [(ResultCompilerPkgManifest.Ok m)
      (match m.kind
        [(CompilerPkgKindBin) (string.eq m.entry "src/main.tl")]
        [(CompilerPkgKindLib) false])]
    [(ResultCompilerPkgManifest.Err _) false]))

(define (compiler-load-manifest-entry-override-ok?) : bool
  (match (compiler-load-parse-manifest
    "(package (name \"override\") (version \"1\") (kind \"staticlib\") (entry \"custom/lib.tl\"))")
    [(ResultCompilerPkgManifest.Ok m)
      (match m.kind
        [(CompilerPkgKindLib) (string.eq m.entry "custom/lib.tl")]
        [(CompilerPkgKindBin) false])]
    [(ResultCompilerPkgManifest.Err _) false]))

(define (compiler-load-manifest-dep-path-is?
  [deps : CompilerPkgDeps]
  [alias : String]
  [expected : String]) : bool
  (match (compiler-load-pkg-dep-lookup deps alias)
    [(CompilerLoadSomePath path) (string.eq path expected)]
    [(CompilerLoadNoPath) false]))

(define (compiler-load-pkg-deps-three-alias-order?
  [deps : CompilerPkgDeps]
  [first-alias : String]
  [second-alias : String]
  [third-alias : String]) : bool
  (let
    [ordered : CompilerPkgDepList (compiler-pkg-deps-list deps)]
    (and
      (= (compiler-pkg-dep-list-count ordered) 3)
      (string.eq
        (__tl-project-field (compiler-pkg-dep-list-at ordered 0) alias)
        first-alias)
      (string.eq
        (__tl-project-field (compiler-pkg-dep-list-at ordered 1) alias)
        second-alias)
      (string.eq
        (__tl-project-field (compiler-pkg-dep-list-at ordered 2) alias)
        third-alias))))

(define (compiler-load-manifest-github-deps-ok?) : bool
  (match (compiler-load-parse-manifest
    "(package (name \"github_demo\") (version \"1\") (kind \"bin\") (entry \"src/main.tl\") (dependencies (math (github \"JoNil-Botta/math\" (rev \"abc123\"))) (util (github \"github.com/JoNil-Botta/util.repo\" (tag \"v1.0.0\"))) (core \"../core\")))")
    [(ResultCompilerPkgManifest.Ok m)
      (let
        [deps : CompilerPkgDeps m.deps]
        (and
          (= (compiler-pkg-deps-count deps) 3)
          (compiler-load-pkg-deps-three-alias-order?
            (ast.ast-place-shared-view deps)
            "math"
            "util"
            "core")
          (compiler-load-manifest-dep-path-is?
            (ast.ast-place-shared-view deps)
            "math"
            "https://github.com/JoNil-Botta/math.git#rev=abc123")
          (compiler-load-manifest-dep-path-is?
            (ast.ast-place-shared-view deps)
            "util"
            "https://github.com/JoNil-Botta/util.repo.git#tag=v1.0.0")
          (compiler-load-manifest-dep-path-is? deps "core" "../core")))]
    [(ResultCompilerPkgManifest.Err _) false]))

;: True when parsing `source` fails with exactly the `expected` diagnostic.
(define (compiler-load-manifest-rejects? [source : String] [expected : String]) : bool
  (match (compiler-load-parse-manifest source)
    [(ResultCompilerPkgManifest.Err m) (string.eq m expected)]
    [(ResultCompilerPkgManifest.Ok _) false]))

(define (compiler-load-manifest-diagnostic-span-forward?
  [diag : (& diag cdiag.CompilerDiagnostic)]) : bool
  (or
    (>
      (cdiag.compiler-diagnostic-end-line diag)
      (cdiag.compiler-diagnostic-line diag))
    (and
      (=
        (cdiag.compiler-diagnostic-end-line diag)
        (cdiag.compiler-diagnostic-line diag))
      (>=
        (cdiag.compiler-diagnostic-end-col diag)
        (cdiag.compiler-diagnostic-col diag)))))

(define (compiler-load-manifest-diagnostic-rejects?
  [path : String]
  [source : String]
  [expected : String]
  [line : i64]
  [col : i64]) : bool
  (match (compiler-load-parse-manifest-diagnostic (clone path) source)
    [(ResultCompilerPkgManifestDiagnostic.Err diag)
      (let
        [diagnostic : cdiag.CompilerDiagnostic
          (cdiag.compiler-diagnostic-box-shared-view diag)]
        (and
          (string.eq (cdiag.compiler-diagnostic-path diagnostic) path)
          (= (cdiag.compiler-diagnostic-line diagnostic) line)
          (= (cdiag.compiler-diagnostic-col diagnostic) col)
          (compiler-load-manifest-diagnostic-span-forward? diagnostic)
          (string.eq (cdiag.compiler-diagnostic-message diagnostic) expected)))]
    [(ResultCompilerPkgManifestDiagnostic.Ok _) false]))

(define (compiler-load-pkg-manifest-diagnostic-ok?) : bool
  (and
    (compiler-load-manifest-diagnostic-rejects?
      "pkg/typelisp.pkg"
      "("
      "manifest: reader: unterminated list: reached end of input before ')'"
      1
      1)
    (compiler-load-manifest-diagnostic-rejects?
      "pkg/typelisp.pkg"
      "(module foo)"
      "expected `package` form, got `module`"
      1
      1)))

(define (compiler-load-manifest-test-mkdir [path : String]) : bool
  (match (fs.try-mkdir-if-missing (& path))
    [(io.OkIoUnit) true]
    [(io.ErrIoUnit _) false]))

(define (compiler-load-manifest-test-write [path : String] [contents : String]) : bool
  (match (compiler-load-try-write-file-text (& path) (& contents))
    [(io.OkIoUnit) true]
    [(io.ErrIoUnit _) false]))

(define (compiler-load-manifest-test-root [name : String]) : String
  (compiler-load-join-root-path "target" name))

(define (compiler-load-manifest-test-src [root : (& root str)]) : String
  (compiler-load-join-root-path (string.copy root) "src"))

(define (compiler-load-manifest-test-path [root : String] [relative : String]) : String
  (compiler-load-join-root-path root relative))

(define (compiler-load-manifest-write-convention-fixture
  [root : String]
  [manifest : String]
  [has-main : bool]
  [has-lib : bool]) : bool
  (let
    [src : String (compiler-load-manifest-test-src root)]
    [ok-target : bool (compiler-load-manifest-test-mkdir "target")]
    [ok-root : bool (compiler-load-manifest-test-mkdir (clone root))]
    [ok-src : bool (compiler-load-manifest-test-mkdir src)]
    [ok-manifest : bool
      (compiler-load-manifest-test-write
        (compiler-load-manifest-test-path (clone root) "typelisp.pkg")
        manifest)]
    [ok-main : bool
      (if has-main
        (compiler-load-manifest-test-write
          (compiler-load-manifest-test-path (clone root) "src/main.tl")
          "(define (main) : i64 42)")
        true)]
    [ok-lib : bool
      (if has-lib
        (compiler-load-manifest-test-write
          (compiler-load-manifest-test-path root "src/lib.tl")
          "(define lib-value : i64 42)")
        true)]
    (and ok-target ok-root ok-src ok-manifest ok-main ok-lib)))

(define (compiler-load-manifest-path-kind-entry-is?
  [path : String]
  [expected-kind : CompilerPkgKind]
  [expected-entry : String]) : bool
  (match (compiler-load-parse-manifest-diagnostic-infer-kind
    (clone path)
    (compiler-load-read-file-text path))
    [(ResultCompilerPkgManifestDiagnostic.Ok manifest)
      (and
        (string.eq manifest.entry expected-entry)
        (match manifest.kind
          [(CompilerPkgKindBin)
            (match expected-kind
              [(CompilerPkgKindBin) true]
              [(CompilerPkgKindLib) false])]
          [(CompilerPkgKindLib)
            (match expected-kind
              [(CompilerPkgKindLib) true]
              [(CompilerPkgKindBin) false])]))]
    [(ResultCompilerPkgManifestDiagnostic.Err _) false]))

(define (compiler-load-manifest-path-rejects?
  [path : String]
  [expected : String]) : bool
  (match (compiler-load-parse-manifest-diagnostic-infer-kind
    (clone path)
    (compiler-load-read-file-text path))
    [(ResultCompilerPkgManifestDiagnostic.Err diag)
      (string.eq
        (cdiag.compiler-diagnostic-message (__tl-box-place diag))
        expected)]
    [(ResultCompilerPkgManifestDiagnostic.Ok _) false]))

(define (compiler-load-manifest-infer-bin-only-ok?) : bool
  (let
    [root : String
      (compiler-load-manifest-test-root "compiler_load_pkg_bin_only")]
    [manifest-path : String
      (compiler-load-manifest-test-path (clone root) "typelisp.pkg")]
    (and
      (compiler-load-manifest-write-convention-fixture
        root
        "(package (name \"bin_only\") (version \"1\"))"
        true
        false)
      (compiler-load-manifest-path-kind-entry-is?
        manifest-path
        (CompilerPkgKindBin)
        "src/main.tl"))))

(define (compiler-load-manifest-infer-lib-only-ok?) : bool
  (let
    [root : String
      (compiler-load-manifest-test-root "compiler_load_pkg_lib_only")]
    [manifest-path : String
      (compiler-load-manifest-test-path (clone root) "typelisp.pkg")]
    (and
      (compiler-load-manifest-write-convention-fixture
        root
        "(package (name \"lib_only\") (version \"1\"))"
        false
        true)
      (compiler-load-manifest-path-kind-entry-is?
        manifest-path
        (CompilerPkgKindLib)
        "src/lib.tl"))))

(define (compiler-load-manifest-infer-ambiguous-ok?) : bool
  (let
    [root : String
      (compiler-load-manifest-test-root "compiler_load_pkg_ambiguous")]
    [manifest-path : String
      (compiler-load-manifest-test-path (clone root) "typelisp.pkg")]
    (and
      (compiler-load-manifest-write-convention-fixture
        root
        "(package (name \"ambiguous\") (version \"1\"))"
        true
        true)
      (compiler-load-manifest-path-rejects?
        manifest-path
        "manifest omits `kind` and `entry`, but both `src/main.tl` and `src/lib.tl` exist; add explicit `kind` or `entry`"))))

(define (compiler-load-manifest-infer-missing-ok?) : bool
  (let
    [root : String
      (compiler-load-manifest-test-root "compiler_load_pkg_missing")]
    [manifest-path : String
      (compiler-load-manifest-test-path (clone root) "typelisp.pkg")]
    (and
      (compiler-load-manifest-write-convention-fixture
        root
        "(package (name \"missing\") (version \"1\"))"
        false
        false)
      (compiler-load-manifest-path-rejects?
        manifest-path
        "manifest omits `kind` and `entry`, but neither `src/main.tl` nor `src/lib.tl` exists; add `kind` and `entry` or create a conventional entry file"))))

(define (compiler-load-manifest-infer-explicit-ok?) : bool
  (let
    [root : String
      (compiler-load-manifest-test-root "compiler_load_pkg_explicit")]
    [manifest-path : String
      (compiler-load-manifest-test-path (clone root) "typelisp.pkg")]
    [explicit-entry-root : String
      (compiler-load-manifest-test-root "compiler_load_pkg_explicit_entry")]
    [explicit-entry-path : String
      (compiler-load-manifest-test-path
        (clone explicit-entry-root)
        "typelisp.pkg")]
    (and
      (compiler-load-manifest-write-convention-fixture
        root
        "(package (name \"explicit\") (version \"1\") (kind staticlib))"
        true
        true)
      (compiler-load-manifest-path-kind-entry-is?
        manifest-path
        (CompilerPkgKindLib)
        "src/lib.tl")
      (compiler-load-manifest-write-convention-fixture
        explicit-entry-root
        "(package (name \"explicit_entry\") (version \"1\") (entry \"custom.tl\"))"
        false
        true)
      (compiler-load-manifest-path-kind-entry-is?
        explicit-entry-path
        (CompilerPkgKindBin)
        "custom.tl"))))

(define (compiler-load-manifest-infer-package-entry-ok?) : bool
  (let
    [root : String
      (compiler-load-manifest-test-root "compiler_load_pkg_entry_lib_only")]
    [source-path : String
      (compiler-load-manifest-test-path (clone root) "src/lib.tl")]
    [expected-entry : String (compiler-load-normalize-path source-path)]
    (and
      (compiler-load-manifest-write-convention-fixture
        root
        "(package (name \"entry_dep\") (version \"1\"))"
        false
        true)
      (match (compiler-load-package-entry-for-source source-path)
        [(ResultCompilerLoadPackageEntry.Ok entry)
          (and
            (string.eq entry.owner "entry_dep")
            (string.eq entry.entry-path expected-entry))]
        [(ResultCompilerLoadPackageEntry.Err _) false]))))

(define (compiler-load-manifest-path-inference-ok?) : bool
  (and
    (compiler-load-manifest-infer-bin-only-ok?)
    (compiler-load-manifest-infer-lib-only-ok?)
    (compiler-load-manifest-infer-ambiguous-ok?)
    (compiler-load-manifest-infer-missing-ok?)
    (compiler-load-manifest-infer-explicit-ok?)
    (compiler-load-manifest-infer-package-entry-ok?)))

(define (compiler-load-pkg-manifest-github-validation-ok?) : bool
  (and
    (compiler-load-manifest-rejects?
      "(package (name \"x\") (version \"1\") (kind \"bin\") (entry \"e.tl\") (dependencies (math (github \"owner/repo\"))))"
      "manifest dependency `math` github source requires exactly one rev, tag, or branch pin")
    (compiler-load-manifest-rejects?
      "(package (name \"x\") (version \"1\") (kind \"bin\") (entry \"e.tl\") (dependencies (math (github \"owner/repo/extra\" (rev \"abc\")))))"
      "manifest dependency `math` github address must be `owner/repo` or `github.com/owner/repo`")
    (compiler-load-manifest-rejects?
      "(package (name \"x\") (version \"1\") (kind \"bin\") (entry \"e.tl\") (dependencies (math (github \"owner/repo\" (sha \"abc\")))))"
      "manifest dependency `math` github pin must be rev, tag, or branch")
    (compiler-load-manifest-rejects?
      "(package (name \"x\") (version \"1\") (kind \"bin\") (entry \"e.tl\") (dependencies (math (github \"owner/repo\" (rev \"\")))))"
      "manifest dependency `math` github pin must not be empty")))

(define (compiler-load-pkg-manifest-validation-ok?) : bool
  (and
    (compiler-load-manifest-rejects?
      "(package (name \"demo\") (name \"again\") (version \"1\") (kind \"bin\") (entry \"e.tl\"))"
      "duplicate manifest field `name`")
    (compiler-load-manifest-rejects?
      "(package (name \"\") (version \"1\") (kind \"bin\") (entry \"e.tl\"))"
      "manifest field `name` must not be empty")
    (compiler-load-manifest-rejects?
      "(package (name \"bad.name\") (version \"1\") (kind \"bin\") (entry \"e.tl\"))"
      "manifest field `name` may only contain ASCII letters, digits, '-' and '_'")
    (compiler-load-manifest-rejects?
      "(package (name \"x\") (version \"\") (kind \"bin\") (entry \"e.tl\"))"
      "manifest field `version` must not be empty")
    (compiler-load-manifest-rejects?
      "(package (name \"x\") (version \"1\") (kind \"bad\") (entry \"e.tl\"))"
      "manifest field `kind` must be `bin`, `staticlib`, or `lib`")
    (compiler-load-manifest-rejects?
      "(package (name \"x\") (version \"1\") (kind \"bin\") (kind \"lib\") (entry \"e.tl\"))"
      "duplicate manifest field `kind`")
    (compiler-load-manifest-rejects?
      "(package (name \"x\") (version \"1\") (kind \"bin\") (entry \"\"))"
      "manifest field `entry` must not be empty")
    (compiler-load-manifest-rejects?
      "(package (name \"x\") (version \"1\") (kind \"bin\") (entry \"../main.tl\"))"
      "manifest field `entry` must be a normal relative path below the manifest directory")
    (compiler-load-manifest-rejects?
      "(package (name \"x\") (version \"1\") (kind \"bin\") (entry \"e.tl\") (dependencies (math \"a\")) (dependencies (util \"b\")))"
      "duplicate manifest field `dependencies`")
    (compiler-load-manifest-rejects?
      "(package (name \"x\") (version \"1\") (kind \"bin\") (entry \"e.tl\") (dependencies (math \"a\") (math \"b\")))"
      "duplicate dependency alias `math`")
    (compiler-load-manifest-rejects?
      "(package (name \"x\") (version \"1\") (kind \"bin\") (entry \"e.tl\") (dependencies (bad.alias \"a\")))"
      "dependency alias may only contain ASCII letters, digits, '-' and '_'")
    (compiler-load-manifest-rejects?
      "(package (name \"x\") (version \"1\") (kind \"bin\") (entry \"e.tl\") (dependencies (math \"\")))"
      "manifest dependency `math` path must not be empty")))

;: True when a package link string vector is empty.
(define (compiler-load-link-vec-empty? [vec : (& vec fs.FsStringVector)]) : bool
  (= (fs.string-vector-len vec) 0))

;: True when a package link string vector holds exactly one value equal to `a`.
(define (compiler-load-link-vec-single?
  [vec : (& vec fs.FsStringVector)]
  [a : String]) : bool
  (and
    (= (fs.string-vector-len vec) 1)
    (string.eq (fs.string-vector-get vec 0 "") a)))

;: True when a package link string vector holds exactly `a` then `b`, in order.
(define (compiler-load-link-vec-pair?
  [vec : (& vec fs.FsStringVector)]
  [a : String]
  [b : String]) : bool
  (and
    (= (fs.string-vector-len vec) 2)
    (string.eq (fs.string-vector-get vec 0 "") a)
    (string.eq (fs.string-vector-get vec 1 "") b)))

;: Self-test: a `(link ...)` section parses into all-target and per-target sets
;: with manifest order preserved.
(define (compiler-load-manifest-link-valid-ok?) : bool
  (match (compiler-load-parse-manifest
    "(package (name \"p\") (version \"1\") (kind \"bin\") (entry \"src/main.tl\") (link (libraries \"raylib\") (search-paths \"vendor/lib\") (linux-libraries \"GL\" \"m\") (linux-args \"-Wl,--as-needed\") (windows-libraries \"opengl32\")))")
    [(ResultCompilerPkgManifest.Ok m)
      (let
        [link : CompilerPkgLink m.link]
        [all : CompilerPkgLinkSet link.all]
        [lin : CompilerPkgLinkSet link.linux]
        [win : CompilerPkgLinkSet link.windows]
        (and
          (compiler-load-link-vec-single? (& all.libraries) "raylib")
          (compiler-load-link-vec-single? (& all.search-paths) "vendor/lib")
          (compiler-load-link-vec-empty? (& all.args))
          (compiler-load-link-vec-pair? (& lin.libraries) "GL" "m")
          (compiler-load-link-vec-single? (& lin.args) "-Wl,--as-needed")
          (compiler-load-link-vec-single? (& win.libraries) "opengl32")))]
    [(ResultCompilerPkgManifest.Err _) false]))

;: Self-test: a manifest with no `link` section parses with empty link sets.
(define (compiler-load-manifest-link-default-ok?) : bool
  (match (compiler-load-parse-manifest
    "(package (name \"p\") (version \"1\") (kind \"bin\") (entry \"src/main.tl\"))")
    [(ResultCompilerPkgManifest.Ok m)
      (let
        [link : CompilerPkgLink m.link]
        (and
          (compiler-load-link-vec-empty? (& link.all.libraries))
          (compiler-load-link-vec-empty? (& link.linux.libraries))
          (compiler-load-link-vec-empty? (& link.windows.libraries))))]
    [(ResultCompilerPkgManifest.Err _) false]))

;: Self-test: invalid `(link ...)` sections produce the expected diagnostics.
(define (compiler-load-manifest-link-rejections-ok?) : bool
  (and
    (compiler-load-manifest-rejects?
      "(package (name \"x\") (version \"1\") (kind \"bin\") (entry \"e.tl\") (link (libraries \"a\")) (link (args \"b\")))"
      "duplicate manifest field `link`")
    (compiler-load-manifest-rejects?
      "(package (name \"x\") (version \"1\") (kind \"bin\") (entry \"e.tl\") (link (libraries \"a\") (libraries \"b\")))"
      "duplicate `link` field `libraries`")
    (compiler-load-manifest-rejects?
      "(package (name \"x\") (version \"1\") (kind \"bin\") (entry \"e.tl\") (link (frobs \"a\")))"
      "unknown `link` field `frobs`")
    (compiler-load-manifest-rejects?
      "(package (name \"x\") (version \"1\") (kind \"bin\") (entry \"e.tl\") (link (libraries \"\")))"
      "`link` field `libraries` values must not be empty")
    (compiler-load-manifest-rejects?
      "(package (name \"x\") (version \"1\") (kind \"bin\") (entry \"e.tl\") (link (libraries)))"
      "`link` field `libraries` requires at least one value")
    (compiler-load-manifest-rejects?
      "(package (name \"x\") (version \"1\") (kind \"bin\") (entry \"e.tl\") (link (libraries 5)))"
      "`link` field `libraries` values must be strings")))

;: Aggregate link-section self-test.
(define (compiler-load-manifest-link-ok?) : bool
  (and
    (compiler-load-manifest-link-valid-ok?)
    (compiler-load-manifest-link-default-ok?)
    (compiler-load-manifest-link-rejections-ok?)))

;: Aggregate manifest-parser self-test.
(define (compiler-load-pkg-manifest-ok?) : bool
  (and
    (compiler-load-manifest-valid-full-ok?)
    (compiler-load-manifest-link-ok?)
    (compiler-load-manifest-valid-nodeps-ok?)
    (compiler-load-manifest-default-bin-ok?)
    (compiler-load-manifest-entry-override-ok?)
    (compiler-load-manifest-rejects?
      "(package (version \"1\") (kind \"bin\") (entry \"e.tl\"))"
      "manifest missing required field `name`")
    (compiler-load-manifest-rejects?
      "(package (name \"x\") (kind \"bin\") (entry \"e.tl\"))"
      "manifest missing required field `version`")
    (compiler-load-manifest-rejects?
      "(module foo)"
      "expected `package` form, got `module`")
    (compiler-load-pkg-manifest-validation-ok?)
    (compiler-load-manifest-github-deps-ok?)
    (compiler-load-pkg-manifest-github-validation-ok?)
    (compiler-load-pkg-manifest-diagnostic-ok?)))

;: --- pkg:<alias>/... import resolution ---------------------------------------
;: Resolve a `pkg:<alias>/<rest>` import against a parsed manifest's dependency
;: list, relative to the manifest directory: `<manifest-dir>/<dep-path>/<rest>`,
;: normalized. Rejects a missing alias, an empty/`/`-less spec, and a `rest`
;: that escapes the dependency root via `..`, preserving those diagnostics when
;: the import resolver runs inside the selfhost driver.
;: True when an import path is a package import (`pkg:<alias>/...`).
(define (compiler-load-pkg-import? [path : (& path str)]) : bool
  (compiler-load-string-prefix-at? path "pkg:" 0))

;: Index of the first '/' in `s` at or after `i`, or -1 if none.
(define (compiler-load-slash-index-from [s : (& s str)] [i : i64] [n : i64]) : i64
  (if (>= i n)
    -1
    (if (= (string.string-ref s i) '/')
      i
      (compiler-load-slash-index-from s (+ i 1) n))))

;: True when a path is not a safe relative suffix below its package root.
(define (compiler-load-path-escapes? [path : String]) : bool
  (not (compiler-load-safe-relative? path)))

;: Look up a dependency's root path by import alias.
(define (compiler-load-pkg-dep-lookup
  [deps : CompilerPkgDeps]
  [target-alias : String]) : CompilerLoadMaybePath
  (let
    [ordered : CompilerPkgDepList (compiler-pkg-deps-list deps)]
    [index : i64 0]
    (begin
      (while (< index (compiler-pkg-dep-list-count ordered))
        (let
          [dep : CompilerPkgDep (compiler-pkg-dep-list-at ordered index)]
          (if (string.eq dep.alias target-alias)
            (return (CompilerLoadSomePath dep.path))
            (set! index (+ index 1)))))
      (CompilerLoadNoPath))))

;: Resolve `pkg:<alias>/<rest>` against `deps`, relative to `manifest-dir`.
(define (compiler-load-resolve-pkg-import
  [import-path : String]
  [manifest-dir : String]
  [deps : CompilerPkgDeps]) : ResultPkgResolve
  (let
    [body : String
      (string.substring import-path 4 (- (string.string-length import-path) 4))]
    [slash : i64
      (compiler-load-slash-index-from body 0 (string.string-length body))]
    (if (< slash 0)
      (ResultPkgResolve.Err
        (str_cat.str-cat
          "compiler-load: pkg import missing '/' after alias: "
          import-path))
      (let
        [alias : String (string.substring body 0 slash)]
        [rest : String
          (string.substring
            body
            (+ slash 1)
            (- (string.string-length body) (+ slash 1)))]
        (if (= (string.string-length alias) 0)
          (ResultPkgResolve.Err
            (str_cat.str-cat
              "compiler-load: pkg import has empty alias: "
              import-path))
          (match (compiler-load-pkg-dep-lookup deps (clone alias))
            [(CompilerLoadNoPath)
              (ResultPkgResolve.Err
                (str_cat.str-cat
                  "compiler-load: unknown package alias '"
                  alias
                  "': "
                  import-path))]
            [(CompilerLoadSomePath dep-path)
              (if (compiler-load-github-dependency-path? (clone dep-path))
                (ResultPkgResolve.Err
                  (str_cat.str-cat
                    "compiler-load: GitHub dependency '"
                    alias
                    "' requires fetch support: "
                    import-path))
                (let
                  [norm-rest : String (compiler-load-normalize-path rest)]
                  (if (compiler-load-path-escapes? (clone norm-rest))
                    (ResultPkgResolve.Err
                      (str_cat.str-cat
                        "compiler-load: pkg import escapes package root: "
                        import-path))
                    (ResultPkgResolve.Ok
                      (compiler-load-normalize-path
                        (compiler-load-join-root-path
                          (compiler-load-join-root-path manifest-dir dep-path)
                          norm-rest))))))]))))))

;: Parent directory of a directory path, or no-path at the top. `dirname`
;: returns a path *including* its trailing separator, so a trailing separator
;: is stripped first to make the walk-up progress (e.g. `src/` -> ``, the cwd).
(define (compiler-load-parent-dir [dir : String]) : CompilerLoadMaybePath
  (let
    [n : i64 (string.string-length dir)]
    (if (= n 0)
      (CompilerLoadNoPath)
      (let
        [trimmed : String
          (if (compiler-load-path-separator? (string.string-ref dir (- n 1)))
            (string.substring dir 0 (- n 1))
            dir)]
        [parent : String (compiler-load-dirname trimmed)]
        (if (string.eq parent dir)
          (CompilerLoadNoPath)
          (CompilerLoadSomePath parent))))))

;: Walk up from `dir` looking for a `typelisp.pkg` manifest, mirroring the Rust
;: `discover_manifest` (src/package.rs). `fuel` bounds the climb.
(define (compiler-load-discover-manifest-up [dir : String] [fuel : i64]) : CompilerLoadMaybePath
  (if (<= fuel 0)
    (CompilerLoadNoPath)
    (let
      [candidate : String (str_cat.str-cat (clone dir) "typelisp.pkg")]
      (if (io.file-exists? (clone candidate))
        (CompilerLoadSomePath candidate)
        (match (compiler-load-parent-dir dir)
          [(CompilerLoadNoPath) (CompilerLoadNoPath)]
          [(CompilerLoadSomePath parent)
            (compiler-load-discover-manifest-up parent (- fuel 1))])))))

;: Discover the nearest `typelisp.pkg` at or above the importer's directory.
(define (compiler-load-discover-manifest [start-path : String]) : CompilerLoadMaybePath
  (compiler-load-discover-manifest-up (compiler-load-dirname start-path) 256))

;: Resolve a `pkg:<alias>/...` import by discovering and parsing the nearest
;: `typelisp.pkg` relative to the importer, then resolving against its deps.
;: Missing manifests and parse errors fall back to the raw import path so the
;: loader reports a normal "cannot read import" error. Syntactically valid
;: manifests preserve pkg-resolution diagnostics into the caller.
(define (compiler-load-resolve-pkg-import-from-disk
  [importer-path : String]
  [import-path : String]) : ResultPkgResolve
  (match (compiler-load-discover-manifest importer-path)
    [(CompilerLoadNoPath) (ResultPkgResolve.Ok import-path)]
    [(CompilerLoadSomePath manifest-path)
      (match (compiler-load-parse-manifest-diagnostic
        (clone manifest-path)
        (compiler-load-read-file-text manifest-path))
        [(ResultCompilerPkgManifestDiagnostic.Err _)
          (ResultPkgResolve.Ok import-path)]
        [(ResultCompilerPkgManifestDiagnostic.Ok manifest)
          (compiler-load-resolve-pkg-import
            import-path
            (compiler-load-dirname manifest-path)
            manifest.deps)])]))

;: Self-test fixture: local deps plus one GitHub dep that needs fetch support.
(define (compiler-load-pkg-resolve-deps) : CompilerPkgDeps
  (compiler-pkg-deps-cons
    "math"
    "../math"
    (compiler-pkg-deps-cons
      "util"
      "vendor/util"
      (compiler-pkg-deps-cons
        "remote"
        "https://github.com/owner/repo.git#rev=abc"
        (compiler-pkg-deps-empty)))))

;: True when resolving `import-path` yields exactly `expected`.
(define (compiler-load-pkg-resolves? [import-path : String] [expected : String]) : bool
  (match (compiler-load-resolve-pkg-import
    import-path
    "proj"
    (compiler-load-pkg-resolve-deps))
    [(ResultPkgResolve.Ok p) (string.eq p expected)]
    [(ResultPkgResolve.Err _) false]))

;: True when resolving `import-path` fails with exactly `expected`.
(define (compiler-load-pkg-resolve-rejects?
  [import-path : String]
  [expected : String]) : bool
  (match (compiler-load-resolve-pkg-import
    import-path
    "proj"
    (compiler-load-pkg-resolve-deps))
    [(ResultPkgResolve.Err m) (string.eq m expected)]
    [(ResultPkgResolve.Ok _) false]))

;: Aggregate pkg-import resolution self-test.
(define (compiler-load-pkg-resolve-ok?) : bool
  (and
    (compiler-load-pkg-resolves? "pkg:math/src/add.tl" "math/src/add.tl")
    (compiler-load-pkg-resolves? "pkg:util/lib.tl" "proj/vendor/util/lib.tl")
    (compiler-load-pkg-resolve-rejects?
      "pkg:nope/x.tl"
      "compiler-load: unknown package alias 'nope': pkg:nope/x.tl")
    (compiler-load-pkg-resolve-rejects?
      "pkg:math"
      "compiler-load: pkg import missing '/' after alias: pkg:math")
    (compiler-load-pkg-resolve-rejects?
      "pkg:math/../../etc.tl"
      "compiler-load: pkg import escapes package root: pkg:math/../../etc.tl")
    (compiler-load-pkg-resolve-rejects?
      "pkg:remote/src/lib.tl"
      "compiler-load: GitHub dependency 'remote' requires fetch support: pkg:remote/src/lib.tl")))

;: True when `parent-dir dir` yields exactly `expected`.
(define (compiler-load-pkg-parent-dir-is? [dir : String] [expected : String]) : bool
  (match (compiler-load-parent-dir dir)
    [(CompilerLoadSomePath p) (string.eq p expected)]
    [(CompilerLoadNoPath) false]))

;: True when `parent-dir dir` reports no parent (top of the climb).
(define (compiler-load-pkg-parent-dir-none? [dir : String]) : bool
  (match (compiler-load-parent-dir dir)
    [(CompilerLoadNoPath) true]
    [(CompilerLoadSomePath _) false]))

;: The manifest-discovery walk-up steps one directory at a time, descending to
;: the cwd (``) before stopping.
(define (compiler-load-pkg-parent-dir-ok?) : bool
  (and
    (compiler-load-pkg-parent-dir-is? "a/b/" "a/")
    (compiler-load-pkg-parent-dir-is? "a/b/c/" "a/b/")
    (compiler-load-pkg-parent-dir-is? "a/" "")
    (compiler-load-pkg-parent-dir-none? "")))

(define (compiler-load-string-vec-roots-ok?) : bool
  (begin
    (compiler-load-write-file-text
      "target/cl_vec_root_payload.tl"
      "(define v : i64 1)")
    (let
      [roots : svec.Vec
        (compiler-load-string-vec-two "target/cl_vec_missing_root" "target")]
      (and
        (= (svec.len (& roots)) 2)
        (string.eq (svec.get (& roots) 0 "") "target/cl_vec_missing_root")
        (string.eq (svec.get (& roots) 1 "") "target")
        (match (compiler-load-resolve-stdlib-root-raw
          "cl_vec_root_payload.tl"
          roots)
          [(CompilerLoadSomePath path)
            (string.eq path "target/cl_vec_root_payload.tl")]
          [(CompilerLoadNoPath) false])))))

(define (compiler-load-pkg-dep-list-ok?) : bool
  (let
    [deps : CompilerPkgDeps
      (compiler-pkg-deps-cons
        "alpha"
        "dep-alpha"
        (compiler-pkg-deps-cons "beta" "dep-beta" (compiler-pkg-deps-empty)))]
    (and
      (= (compiler-pkg-deps-count deps) 2)
      (compiler-pkg-deps-alias-seen? (ast.ast-place-shared-view deps) "beta")
      (compiler-load-manifest-dep-path-is? deps "beta" "dep-beta"))))

;; relative-resolution variants: importer-relative join, parent-directory
;; (`..`) resolution end-to-end (join then normalize), and absolute-path
;; preservation (Unix-rooted and Windows-drive imports ignore the importer dir).
;; Pure path-string logic; complements `compiler-load-normalize-ok?` which covers
;; bare `.`/`..`/separator normalization without the importer-relative join.
(define (compiler-load-relative-resolution-ok?) : bool
  (and
    ;; importer-relative: import resolves against the importer's directory
    (string.eq
      (compiler-load-join-import-path "src/app/main.tl" "util.tl")
      "src/app/util.tl")
    ;; parent-directory (`..`) resolution end-to-end (join then normalize)
    (string.eq
      (compiler-load-normalize-path
        (compiler-load-join-import-path "src/app/main.tl" "../lib/helper.tl"))
      "src/lib/helper.tl")
    ;; absolute Unix-rooted import is preserved as-is (importer dir ignored)
    (string.eq
      (compiler-load-join-import-path "src/app/main.tl" "/opt/dep.tl")
      "/opt/dep.tl")
    ;; absolute Windows-drive import is preserved as-is
    (string.eq
      (compiler-load-join-import-path "src/app/main.tl" "C:/dep.tl")
      "C:/dep.tl")))

(define (compiler-load-dotted-module-path-cache-ok?) : bool
  (begin
    (compiler-load-dotted-path-cache-reset!)
    (let
      [home : arena.Arena (arena.current)]
      [stdlib-name : String "stdlib.core_macros"]
      [pkg-name : String "pkg.local.mod"]
      [stdlib-id : i64 (ci.intern stdlib-name)]
      [pkg-id : i64 (ci.intern pkg-name)]
      [first : String
        (compiler-load-dotted-module-path-id stdlib-id "stdlib.core_macros")]
      [second : String
        (compiler-load-dotted-module-path-id stdlib-id "stdlib.core_macros")]
      [third : String
        (compiler-load-dotted-module-path-id pkg-id "pkg.local.mod")]
      (and
        (arena.eq? (arena.current) home)
        (string.eq first "stdlib/core_macros.tl")
        (string.eq second "stdlib/core_macros.tl")
        (string.eq third "pkg/local/mod.tl")
        (match (compiler-load-dotted-path-cache-lookup stdlib-id)
          [(CompilerLoadSomeString cached)
            (string.eq cached "stdlib/core_macros.tl")]
          [(CompilerLoadNoString) false])
        (match (compiler-load-dotted-path-cache-lookup pkg-id)
          [(CompilerLoadSomeString cached)
            (string.eq cached "pkg/local/mod.tl")]
          [(CompilerLoadNoString) false])))))

(define (compiler-load-test-path-at [paths : ast.AstDeclPathList] [index : i64]) : String
  (match (ast.ast-decl-path-list-step paths)
    [(ast.AstDeclPathListStep.Nil) ""]
    [(ast.AstDeclPathListStep.Cons path rest)
      (if (= index 0)
        path
        (let
          [rest : ast.AstDeclPathList rest]
          (compiler-load-test-path-at rest (- index 1))))]))

(define (compiler-load-package-owner-paths-ok?) : bool
  (let
    [roots : svec.Vec (compiler-load-string-vec-one "C:/repo/stdlib")]
    [mixed-roots : svec.Vec
      (compiler-load-string-vec-two "C:/repo/stdlib" "C:/repo/selfhost")]
    [runtime-decl : ast.AstDecl
      (ast.ast-decl-def-fn-id
        (compiler-load-parse-context-name-id "runtime-helper")
        (ast.ast-param-list-new)
        (ast.AstType.I64)
        (ast.ast-node-push (ast.AstExpr.Literal (ast.ast-lit-int 1))))]
    [helper-decl : ast.AstDecl
      (ast.ast-decl-def-fn-id
        (compiler-load-parse-context-name-id "helper")
        (ast.ast-param-list-new)
        (ast.AstType.I64)
        (ast.ast-node-push (ast.AstExpr.Literal (ast.ast-lit-int 2))))]
    [main-decl : ast.AstDecl
      (ast.ast-decl-def-fn-id
        (compiler-load-parse-context-name-id "main")
        (ast.ast-param-list-new)
        (ast.AstType.I64)
        (ast.ast-node-push (ast.AstExpr.Literal (ast.ast-lit-int 0))))]
    [decls : ast.AstDeclList
      (ast.ast-decl-cons
        runtime-decl
        (ast.ast-decl-cons
          helper-decl
          (ast.ast-decl-cons main-decl (ast.ast-decl-list-new))))]
    [runtime-path-id : i64
      (compiler-load-source-path-id "C:/repo/stdlib/runtime.tl")]
    [main-path-id : i64 (compiler-load-source-path-id "C:/pkg/src/main.tl")]
    [paths : ast.AstDeclPathList
      (ast.ast-decl-path-cons-with-owner-id
        "C:/repo/stdlib/runtime.tl"
        runtime-path-id
        (ast.ast-decl-path-cons-with-owner-id
          "C:/pkg/src/main.tl"
          main-path-id
          (ast.ast-decl-path-cons-with-owner-id
            "C:/pkg/src/main.tl"
            main-path-id
            (ast.ast-decl-path-list-new))))]
    [owned : ast.AstDeclPathList
      (compiler-load-package-owned-paths-for-decls
        "app"
        "C:/pkg/"
        (ast.ast-place-shared-view roots)
        "C:/pkg/src/main.tl"
        decls
        paths)]
    [runtime-owned-ok : bool
      (string.eq
        (compiler-load-test-path-at (ast.ast-place-shared-view owned) 0)
        "stdlib/runtime.tl")]
    [helper-owned-ok : bool
      (string.eq
        (compiler-load-test-path-at (ast.ast-place-shared-view owned) 1)
        "app/src/main.tl")]
    [entry-main-ok : bool
      (string.eq
        (compiler-load-test-path-at (ast.ast-place-shared-view owned) 2)
        "")]
    [stdlib-normalized-ok : bool
      (string.eq
        (compiler-load-package-owned-path
          "app"
          "C:/pkg/"
          (ast.ast-place-shared-view roots)
          "stdlib/../stdlib/runtime.tl")
        "stdlib/runtime.tl")]
    [empty-root-owned-ok : bool
      (string.eq
        (compiler-load-package-owned-path "app" "" roots "src/main.tl")
        "app/src/main.tl")]
    [selfhost-root-owned-ok : bool
      (string.eq
        (compiler-load-package-owned-path
          "app"
          "C:/repo/"
          mixed-roots
          "C:/repo/selfhost/compiler_driver_core.tl")
        "app/selfhost/compiler_driver_core.tl")]
    (and
      runtime-owned-ok
      helper-owned-ok
      entry-main-ok
      stdlib-normalized-ok
      empty-root-owned-ok
      selfhost-root-owned-ok)))

(define (compiler-load-package-owner-extern-symbol-ok?) : bool
  (let
    [decl : ast.AstDecl
      (compiler-load-package-def-fn-extern
        "dep"
        "C:/dep/"
        (svec.new)
        "C:/dep/src/lib.tl"
        ""
        (ci.intern "helper")
        (ast.ast-param-list-new)
        (ast.AstType.I64)
        CompilerLoadPackageSpmdInterface.Unavailable)]
    (match decl
      [(ast.AstDecl.Extern decl-meta _ _ metadata _)
        (string.eq
          (ast.ast-extern-metadata-symbol
            (ast.ast-extern-metadata-box-shared-view metadata))
          "_tl_dep_src_lib_helper")]
      [_ false])))

(define (compiler-load-package-source-macro-preserved-ok?) : bool
  (let
    [name : i64 (ci.intern-generated-name "package-source-macro")]
    [body : i64 (ast.ast-node-push (ast.AstExpr.Literal (ast.ast-lit-int 42)))]
    [decl : ast.AstDecl
      (ast.ast-decl-def-macro-id
        name
        (ast.ast-macro-param-list-new)
        (ast.AstType.I64)
        body)]
    (match (compiler-load-package-transform-decl
      "dep"
      "C:/dep/"
      (svec.new)
      "C:/dep/src/lib.tl"
      "dep.module"
      CompilerLoadPackageSpmdInterface.Unavailable
      decl)
      [(CompilerLoadSomeDecl transformed)
        (match transformed
          [(ast.AstDecl.DefMacro _ got-name params (ast.AstType.I64) got-body)
            (and
              (= got-name name)
              (= (ast.ast-macro-param-list-len (& params)) 0)
              (= got-body body))]
          [_ false])]
      [(CompilerLoadNoDecl) false])))

(define (compiler-load-package-imported-spmd-metadata-ok?) : bool
  (let
    [specialization : tlci.TlciSpmdSpecialization
      (tlci.tlci-make-spmd-specialization
        "spmd-call-v1"
        "avx512"
        8
        "vu"
        "v"
        0
        "_tl___tl_spmd_fixture_helper")]
    [callable : tlci.TlciSpmdCallable
      (tlci.tlci-make-spmd-callable
        "spmd_fixture/helper"
        "(-> i64 i64 i64)"
        (tlci.tlci-spmd-specializations-push
          (tlci.tlci-spmd-specializations-empty)
          specialization))]
    [metadata : ast.AstImportedSpmdMetadata
      (compiler-load-imported-spmd-metadata
        "spmd_fixture"
        "spmd_fixture"
        (ci.intern "helper")
        (CompilerLoadPackageSpmdInterface.Available
          (tlci.tlci-spmd-callables-push
            (tlci.tlci-spmd-callables-empty)
            callable)))]
    (match metadata
      [(ast.AstImportedSpmdMetadata.No) false]
      [(ast.AstImportedSpmdMetadata.Package canonical-name callables-box)
        (let
          [callables : ast.AstImportedSpmdCallableList
            (ast.ast-imported-spmd-callable-list-box-shared-view callables-box)]
          [copied-callable : ast.AstImportedSpmdCallable
            (ast.ast-imported-spmd-callable-list-get
              (& callables)
              0
              (ast.ast-imported-spmd-callable-fallback))]
          [specializations : ast.AstImportedSpmdSpecializationList
            copied-callable.specializations]
          [copied-specialization : ast.AstImportedSpmdSpecialization
            (ast.ast-imported-spmd-specialization-list-get
              (& specializations)
              0
              (ast.ast-imported-spmd-specialization-fallback))]
          (and
            (string.eq (ci.intern-id-str canonical-name) "spmd_fixture/helper")
            (= (ast.ast-imported-spmd-callable-list-len (& callables)) 1)
            (string.eq
              (ci.intern-id-str copied-callable.signature)
              "(-> i64 i64 i64)")
            (=
              (ast.ast-imported-spmd-specialization-list-len
                (& specializations))
              1)
            (string.eq
              (ci.intern-id-str copied-specialization.symbol)
              "_tl___tl_spmd_fixture_helper")))])))

(define (compiler-load-module-list-slots-address
  [items : (& items ast.AstDeclModuleList)]) : i64
  (unsafe
    (cast (ptr->int (ptr-cast (__tl_array-data items.slots) : (Ptr u8))) : i64)))

(define (compiler-load-append-onto-reuse-ok?) : bool
  (let
    [left-a-id : i64 (ci.intern-generated-name "left-a")]
    [left-b-id : i64 (ci.intern-generated-name "left-b")]
    [right-a-id : i64 (ci.intern-generated-name "right-a")]
    [right-b-id : i64 (ci.intern-generated-name "right-b")]
    [alias-a-id : i64 (ci.intern-generated-name "alias-a")]
    [alias-b-id : i64 (ci.intern-generated-name "alias-b")]
    [tail-a-id : i64 (ci.intern-generated-name "tail-a")]
    [tail-b-id : i64 (ci.intern-generated-name "tail-b")]
    [left : ast.AstDeclModuleList (ast.ast-decl-module-list-with-capacity 2)]
    [_left : unit
      (begin
        (ast.ast-decl-module-list-push-id (&mut left) left-a-id)
        (ast.ast-decl-module-list-push-id (&mut left) left-b-id))]
    [right-base : ast.AstDeclModuleList (ast.ast-decl-module-list-new)]
    [right-tail : ast.AstDeclModuleList
      (ast.ast-decl-module-list-prepend-builder-id right-b-id right-base)]
    [right : ast.AstDeclModuleList
      (ast.ast-decl-module-list-prepend-builder-id right-a-id right-tail)]
    [right-address : i64 (compiler-load-module-list-slots-address right)]
    [reused : ast.AstDeclModuleList
      (compiler-load-decl-module-list-append-onto left right)]
    [shared : (__tl_dyn-array i64) (array.make-array i64 8)]
    [_shared : unit
      (begin
        (set! (array-ref shared 1) alias-a-id)
        (set! (array-ref shared 2) alias-b-id)
        (set! (array-ref shared 4) tail-a-id)
        (set! (array-ref shared 5) tail-b-id))]
    [alias-left : ast.AstDeclModuleList
      (ast.AstDeclModuleList (ast.ast-place-shared-view shared) 1 2 true)]
    [alias-right : ast.AstDeclModuleList
      (ast.AstDeclModuleList (ast.ast-place-shared-view shared) 4 2 true)]
    [alias-address : i64 (compiler-load-module-list-slots-address alias-right)]
    [copied : ast.AstDeclModuleList
      (compiler-load-decl-module-list-append-onto alias-left alias-right)]
    (and
      (= (compiler-load-module-list-slots-address reused) right-address)
      (= (ast.ast-decl-module-list-len (& reused)) 4)
      (= (ast.ast-decl-module-list-get-id (& reused) 0 -1) left-a-id)
      (= (ast.ast-decl-module-list-get-id (& reused) 1 -1) left-b-id)
      (= (ast.ast-decl-module-list-get-id (& reused) 2 -1) right-a-id)
      (= (ast.ast-decl-module-list-get-id (& reused) 3 -1) right-b-id)
      (not (= (compiler-load-module-list-slots-address copied) alias-address))
      (= (ast.ast-decl-module-list-len (& copied)) 4)
      (= (ast.ast-decl-module-list-get-id (& copied) 0 -1) alias-a-id)
      (= (ast.ast-decl-module-list-get-id (& copied) 1 -1) alias-b-id)
      (= (ast.ast-decl-module-list-get-id (& copied) 2 -1) tail-a-id)
      (= (ast.ast-decl-module-list-get-id (& copied) 3 -1) tail-b-id)
      (= (array-ref shared 1) alias-a-id)
      (= (array-ref shared 2) alias-b-id)
      (= (array-ref shared 4) tail-a-id)
      (= (array-ref shared 5) tail-b-id))))

(define (compiler-load-session-explicit-cache-api-isolation-ok?) : bool
  (let
    [previous-state : CompilerLoadSessionState
      (compiler-load-global-shared-view compiler-load-active-session-state)]
    [state-a : CompilerLoadSessionState (compiler-load-session-state-new)]
    [state-b : CompilerLoadSessionState (compiler-load-session-state-new)]
    [_select-b : unit
      (compiler-load-session-state-use!
        (compiler-load-session-state-shared-view (& state-b)))]
    [cfgs : sym_i64_env.SymI64Env (sym_i64_env.sym-i64-empty)]
    [program-key : CompilerLoadProgramCacheKey
      (CompilerLoadProgramCacheKey
        CompilerLoadProgramEmbedded
        701
        (sym_i64_env.sym-i64-shared-view (& cfgs)))]
    [program : ast.AstProgram (ast.ast-program (ast.ast-decl-list-new))]
    [_store-program : bool
      (compiler-load-session-state-program-cache-store
        (compiler-load-session-state-shared-view (& state-a))
        (ast.ast-place-shared-view program-key)
        (ast.ast-place-shared-view program))]
    [_note-hit : unit
      (compiler-load-session-state-program-cache-note-hit!
        (compiler-load-session-state-shared-view (& state-a)))]
    [_admit : bool
      (compiler-load-session-state-program-admission-record
        (compiler-load-session-state-shared-view (& state-a))
        (ast.ast-place-shared-view program-key))]
    [prelude-key : CompilerLoadPreludeCacheKey
      (CompilerLoadPreludeCacheKey
        (CompilerLoadInternIdSeq (array.make-array i64 0) 0)
        cfgs)]
    [_store-prelude : unit
      (compiler-load-session-state-runtime-prelude-cache-store
        (compiler-load-session-state-shared-view (& state-a))
        (ast.ast-place-shared-view prelude-key)
        (ast.ast-decl-list-new)
        (ast.ast-decl-path-list-new)
        (ast.ast-decl-module-list-new)
        (sym_i64_env.sym-i64-empty))]
    [dotted : String
      (compiler-load-session-state-dotted-module-path-id
        (compiler-load-session-state-shared-view (& state-a))
        702
        "pkg.explicit")]
    [ok : bool
      (and
        (match (compiler-load-session-state-program-cache-lookup
          (compiler-load-session-state-shared-view (& state-a))
          program-key)
          [(CompilerLoadProgramCacheHit _) true]
          [_ false])
        (=
          (compiler-load-session-state-program-cache-hit-count-value state-a)
          1)
        (=
          (compiler-load-session-state-program-cache-store-count-value state-a)
          1)
        (compiler-load-session-state-program-admission-contains?
          (compiler-load-session-state-shared-view (& state-a))
          program-key)
        (match (compiler-load-session-state-runtime-prelude-cache-lookup
          (compiler-load-session-state-shared-view (& state-a))
          prelude-key)
          [(CompilerLoadPreludeCacheHit _ _ _ _) true]
          [_ false])
        (string.eq dotted "pkg/explicit.tl")
        (not (array-ref state-b.program-cache-ready 0))
        (=
          (compiler-load-session-state-program-cache-hit-count-value state-b)
          0)
        (=
          (compiler-load-session-state-program-cache-store-count-value state-b)
          0)
        (not (array-ref state-b.program-admission-ready 0))
        (not (array-ref state-b.runtime-prelude-cache-ready 0))
        (match (compiler-load-session-state-dotted-path-cache-lookup
          state-b
          702)
          [(CompilerLoadNoString) true]
          [_ false]))]
    (begin
      (compiler-load-session-state-use! previous-state)
      ok)))

(define (compiler-load-session-explicit-parse-isolation-ok?) : bool
  (let
    [home : arena.Arena (arena.current)]
    [previous-state : CompilerLoadSessionState
      (compiler-load-global-shared-view compiler-load-active-session-state)]
    [state-a : CompilerLoadSessionState (compiler-load-session-state-new)]
    [state-b : CompilerLoadSessionState (compiler-load-session-state-new)]
    [_enable-a : unit
      (compiler-load-session-state-cache-enable!
        (compiler-load-session-state-shared-view (& state-a)))]
    [_select-b : unit
      (compiler-load-session-state-use!
        (compiler-load-session-state-shared-view (& state-b)))]
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [cfgs : sym_i64_env.SymI64Env (sym_i64_env.sym-i64-empty)]
    [ok-path : String "explicit-state-a.tl"]
    [ok-id : i64 (compiler-load-source-path-id (clone ok-path))]
    [first : parser.ResultAstProgramDiagnostic
      (compiler-load-parse-embedded-source-diagnostic-session-id-with-pools
        (compiler-load-session-state-shared-view (& state-a))
        (clone ok-path)
        ok-id
        "(define value : i64 42)"
        (sym_i64_env.sym-i64-shared-view (& cfgs))
        (ast.ast-place-shared-view pools))]
    [second : parser.ResultAstProgramDiagnostic
      (compiler-load-parse-embedded-source-diagnostic-session-id-with-pools
        (compiler-load-session-state-shared-view (& state-a))
        (clone ok-path)
        ok-id
        "(define value : i64 42)"
        (sym_i64_env.sym-i64-shared-view (& cfgs))
        (ast.ast-place-shared-view pools))]
    [bad-path : String "explicit-state-a-bad.tl"]
    [bad : parser.ResultAstProgramDiagnostic
      (compiler-load-parse-embedded-source-diagnostic-session-id-with-pools
        (compiler-load-session-state-shared-view (& state-a))
        (clone bad-path)
        (compiler-load-source-path-id (clone bad-path))
        "("
        cfgs
        pools)]
    [ok : bool
      (and
        (arena.eq? (arena.current) home)
        (compiler-load-ast-program-result-ok? first)
        (compiler-load-ast-program-result-ok? second)
        (match bad
          [(parser.ResultAstProgramDiagnostic.Err diag)
            (and
              (string.eq
                (cdiag.compiler-diagnostic-path (__tl-box-place diag))
                bad-path)
              (>
                (string.string-length
                  (cdiag.compiler-diagnostic-message (__tl-box-place diag)))
                0))]
          [_ false])
        (=
          (compiler-load-session-state-program-cache-hit-count-value state-a)
          1)
        (=
          (compiler-load-session-state-program-cache-miss-count-value state-a)
          2)
        (=
          (compiler-load-session-state-program-cache-store-count-value state-a)
          1)
        (compiler-load-session-state-embedded-stdlib-source-used? state-a)
        (=
          (compiler-load-session-state-program-cache-hit-count-value state-b)
          0)
        (=
          (compiler-load-session-state-program-cache-miss-count-value state-b)
          0)
        (=
          (compiler-load-session-state-program-cache-store-count-value state-b)
          0)
        (not (compiler-load-session-state-embedded-stdlib-source-used? state-b)))]
    (begin
      (compiler-load-session-state-use! previous-state)
      ok)))

(define (compiler-load-session-owned-traversal-isolation-ok?) : bool
  (let
    [state-a : CompilerLoadSessionState (compiler-load-session-state-new)]
    [state-b : CompilerLoadSessionState (compiler-load-session-state-new)]
    [alias-a-member-id : i64 cbi.compiler-builtin-id-fix-arena_dot_Arena]
    [alias-a-id : i64 (ci.intern-leading-dot-id alias-a-member-id)]
    [member-a-id : i64
      (compiler-load-lazy-qualified-member-id alias-a-member-id alias-a-id)]
    [alias-b-member-id : i64 cbi.compiler-builtin-id-fix-stdlib_dot_string]
    [alias-b-id : i64 (ci.intern-leading-dot-id alias-b-member-id)]
    [member-b-id : i64
      (compiler-load-lazy-qualified-member-id alias-b-member-id alias-b-id)]
    [secondary-root-id : i64 cbi.compiler-builtin-id-fix-empty]
    [summary : CompilerLoadSurfaceSummary
      (CompilerLoadSurfaceSummary
        alias-a-id
        alias-a-id
        false
        false
        alias-b-id
        "state.tl"
        ""
        (compiler-load-surface-import-list-empty)
        (compiler-load-surface-decl-list-empty)
        false
        false
        false
        false
        (CompilerLoadLazyImportDirect))]
    [_seed-b-caches : unit
      (begin
        (set! (array-ref state-b.program-cache-hit-count 0) 7)
        (set! (array-ref state-b.runtime-prelude-cache-ready 0) true))]
    [_clear-a-caches : unit
      (begin
        (compiler-load-session-state-program-cache-clear!
          (compiler-load-session-state-shared-view (& state-a)))
        (compiler-load-session-state-runtime-prelude-cache-clear!
          (compiler-load-session-state-shared-view (& state-a))))]
    [dotted-id : i64 alias-a-member-id]
    [_seed-b-dotted : unit
      (begin
        (compiler-load-session-state-dotted-path-cache-reset!
          (compiler-load-session-state-shared-view (& state-b)))
        (compiler-load-session-state-dotted-path-cache-store!
          (compiler-load-session-state-shared-view (& state-b))
          dotted-id
          "pkg/member.tl")
        (compiler-load-session-state-dotted-path-cache-reset!
          (compiler-load-session-state-shared-view (& state-a))))]
    [_record-a : unit
      (begin
        (compiler-load-session-state-surface-summary-load-enter!
          (compiler-load-session-state-shared-view (& state-a)))
        (compiler-load-session-state-record-surface-summary!
          state-a
          (ast.ast-place-shared-view summary))
        (compiler-load-session-state-lazy-import-record-skip!
          (compiler-load-session-state-shared-view (& state-a)))
        (compiler-load-session-state-lazy-import-record-skip!
          (compiler-load-session-state-shared-view (& state-a)))
        (compiler-load-session-state-lazy-qualified-observer-begin-pair!
          state-a
          alias-a-id
          secondary-root-id)
        (compiler-load-session-state-lazy-qualified-observer-note!
          state-a
          alias-a-member-id))]
    [_record-b : unit
      (begin
        (compiler-load-session-state-surface-summary-load-enter!
          (compiler-load-session-state-shared-view (& state-b)))
        (compiler-load-session-state-record-surface-summary! state-b summary)
        (compiler-load-session-state-lazy-import-record-skip!
          (compiler-load-session-state-shared-view (& state-b)))
        (compiler-load-session-state-lazy-qualified-observer-begin-pair!
          state-b
          alias-b-id
          secondary-root-id)
        (compiler-load-session-state-lazy-qualified-observer-note!
          state-b
          alias-b-member-id))]
    [observed-b : CompilerLoadLazyQualifiedObserverResult
      (compiler-load-session-state-lazy-qualified-observer-end-pair! state-b)]
    [a-still-active : bool
      (compiler-load-session-state-lazy-qualified-observer-active? state-a)]
    [observed-a : CompilerLoadLazyQualifiedObserverResult
      (compiler-load-session-state-lazy-qualified-observer-end-pair! state-a)]
    [_finish : unit
      (begin
        (compiler-load-session-state-surface-summary-load-exit!
          (compiler-load-session-state-shared-view (& state-a)))
        (compiler-load-session-state-surface-summary-load-exit!
          (compiler-load-session-state-shared-view (& state-b))))]
    [before-reset : bool
      (and
        a-still-active
        (not
          (compiler-load-session-state-lazy-qualified-observer-active? state-b))
        (=
          (compiler-load-session-state-lazy-import-skip-count
            (compiler-load-session-state-shared-view (& state-a)))
          2)
        (=
          (compiler-load-session-state-lazy-import-skip-count
            (compiler-load-session-state-shared-view (& state-b)))
          1)
        (sym_i64_env.sym-i64-contains-id observed-a.primary-members member-a-id)
        (sym_i64_env.sym-i64-contains-id observed-b.primary-members member-b-id))]
    [_reset-a : unit
      (compiler-load-session-state-surface-summaries-reset!
        (compiler-load-session-state-shared-view (& state-a)))]
    (cond
      [(not before-reset)
        (io.panic "compiler-load: traversal before-reset mismatch")]
      [(not (= (array-ref state-b.program-cache-hit-count 0) 7))
        (io.panic "compiler-load: traversal program cache mismatch")]
      [(not (array-ref state-b.runtime-prelude-cache-ready 0))
        (io.panic "compiler-load: traversal prelude cache mismatch")]
      [(not
          (match (compiler-load-session-state-dotted-path-cache-lookup
            (compiler-load-session-state-shared-view (& state-b))
            dotted-id)
            [(CompilerLoadSomeString path) (string.eq path "pkg/member.tl")]
            [_ false]))
        (io.panic "compiler-load: traversal dotted cache mismatch")]
      [(not
          (=
            (compiler-load-session-state-lazy-import-skip-count
              (compiler-load-session-state-shared-view (& state-a)))
            0))
        (io.panic "compiler-load: traversal reset count mismatch")]
      [(not
          (=
            (compiler-load-session-state-lazy-import-skip-count
              (compiler-load-session-state-shared-view (& state-b)))
            1))
        (io.panic "compiler-load: traversal peer count mismatch")]
      [(not
          (match (compiler-load-session-state-surface-summary-find-source
            state-a
            alias-b-id)
            [(CompilerLoadNoSurfaceSummary) true]
            [_ false]))
        (io.panic "compiler-load: traversal reset summary mismatch")]
      [(not
          (match (compiler-load-session-state-surface-summary-find-source
            state-b
            alias-b-id)
            [(CompilerLoadSomeSurfaceSummary _) true]
            [_ false]))
        (io.panic "compiler-load: traversal peer summary mismatch")]
      [else true])))

(define (compiler-load-lazy-qualified-observer-test-root
  [offset : i64]
  [level : i64]) : i64
  (+ offset (+ 1000 level)))

(define (compiler-load-lazy-qualified-observer-test-secondary-root
  [offset : i64]
  [level : i64]) : i64
  (+ offset (+ 2000 level)))

(define (compiler-load-lazy-qualified-observer-test-member
  [offset : i64]
  [level : i64]) : i64
  (+ offset (+ 3000 level)))

(define (compiler-load-lazy-qualified-observer-test-secondary-member
  [offset : i64]
  [level : i64]) : i64
  (+ offset (+ 4000 level)))

(define (compiler-load-lazy-qualified-observer-test-exhaustive? [level : i64]) : bool
  (= (% level 2) 0))

(define (compiler-load-lazy-qualified-observer-test-secondary-qualified?
  [level : i64]) : bool
  (= (% level 3) 1))

(define (compiler-load-lazy-qualified-observer-test-secondary-direct?
  [level : i64]) : bool
  (= (% level 4) 2))

(define (compiler-load-lazy-qualified-observer-test-configure!
  [state : (& state CompilerLoadSessionState)]
  [offset : i64]
  [level : i64]) : unit
  (let
    [observer : (& state CompilerLoadLazyQualifiedObserverState)
      (compiler-load-session-state-lazy-qualified-observer state)]
    (begin
      ;; Production begin-pair makes every active query exhaustive. Vary this
      ;; internal bit here so the frame test proves it is snapshotted rather
      ;; than accidentally derived from active state during a pop.
      (compiler-load-lazy-qualified-observer-flag-set!
        observer
        1
        (compiler-load-lazy-qualified-observer-test-exhaustive? level))
      (compiler-load-lazy-qualified-observer-members-set!
        observer
        0
        (sym_i64_env.sym-i64-bind-id
          (sym_i64_env.sym-i64-empty)
          (compiler-load-lazy-qualified-observer-test-member offset level)
          1))
      (compiler-load-lazy-qualified-observer-members-set!
        observer
        1
        (sym_i64_env.sym-i64-bind-id
          (sym_i64_env.sym-i64-empty)
          (compiler-load-lazy-qualified-observer-test-secondary-member
            offset
            level)
          1))
      (compiler-load-lazy-qualified-observer-flag-set!
        observer
        2
        (compiler-load-lazy-qualified-observer-test-secondary-qualified? level))
      (compiler-load-lazy-qualified-observer-flag-set!
        observer
        3
        (compiler-load-lazy-qualified-observer-test-secondary-direct? level)))))

(define (compiler-load-lazy-qualified-observer-test-empty-state?
  [state : (& state CompilerLoadSessionState)]
  [offset : i64]) : bool
  (let
    [observer : (& state CompilerLoadLazyQualifiedObserverState)
      (compiler-load-session-state-lazy-qualified-observer state)]
    [primary-members : sym_i64_env.SymI64Env
      (compiler-load-lazy-qualified-observer-members observer 0)]
    [secondary-members : sym_i64_env.SymI64Env
      (compiler-load-lazy-qualified-observer-members observer 1)]
    [stack : CompilerLoadLazyQualifiedObserverStack
      (compiler-load-global-array-element-shared-view observer.stack 0)]
    (and
      (not (compiler-load-lazy-qualified-observer-flag observer 0))
      (not (compiler-load-lazy-qualified-observer-flag observer 1))
      (= (compiler-load-lazy-qualified-observer-root-id observer 0) 0)
      (= (compiler-load-lazy-qualified-observer-root-id observer 1) 0)
      (not
        (sym_i64_env.sym-i64-contains-id
          primary-members
          (compiler-load-lazy-qualified-observer-test-member offset 0)))
      (not
        (sym_i64_env.sym-i64-contains-id
          secondary-members
          (compiler-load-lazy-qualified-observer-test-secondary-member offset 0)))
      (not (compiler-load-lazy-qualified-observer-flag observer 2))
      (not (compiler-load-lazy-qualified-observer-flag observer 3))
      (= (compiler-load-lazy-qualified-observer-stack-count stack) 0))))

(define (compiler-load-lazy-qualified-observer-test-stack-capacity-zero?
  [state : (& state CompilerLoadSessionState)]) : bool
  (let
    [observer : (& state CompilerLoadLazyQualifiedObserverState)
      (compiler-load-session-state-lazy-qualified-observer state)]
    [stack : CompilerLoadLazyQualifiedObserverStack
      (compiler-load-global-array-element-shared-view observer.stack 0)]
    (= (array-length stack.slots) 0)))

(define (compiler-load-lazy-qualified-observer-test-state-at?
  [state : (& state CompilerLoadSessionState)]
  [offset : i64]
  [level : i64]) : bool
  (if (< level 0)
    (compiler-load-lazy-qualified-observer-test-empty-state? state offset)
    (let
      [observer : (& state CompilerLoadLazyQualifiedObserverState)
        (compiler-load-session-state-lazy-qualified-observer state)]
      [primary-members : sym_i64_env.SymI64Env
        (compiler-load-lazy-qualified-observer-members observer 0)]
      [secondary-members : sym_i64_env.SymI64Env
        (compiler-load-lazy-qualified-observer-members observer 1)]
      (and
        (compiler-load-lazy-qualified-observer-flag observer 0)
        (=
          (compiler-load-lazy-qualified-observer-flag observer 1)
          (compiler-load-lazy-qualified-observer-test-exhaustive? level))
        (=
          (compiler-load-lazy-qualified-observer-root-id observer 0)
          (compiler-load-lazy-qualified-observer-test-root offset level))
        (=
          (compiler-load-lazy-qualified-observer-root-id observer 1)
          (compiler-load-lazy-qualified-observer-test-secondary-root
            offset
            level))
        (sym_i64_env.sym-i64-contains-id
          primary-members
          (compiler-load-lazy-qualified-observer-test-member offset level))
        (sym_i64_env.sym-i64-contains-id
          secondary-members
          (compiler-load-lazy-qualified-observer-test-secondary-member
            offset
            level))
        (=
          (compiler-load-lazy-qualified-observer-flag observer 2)
          (compiler-load-lazy-qualified-observer-test-secondary-qualified?
            level))
        (=
          (compiler-load-lazy-qualified-observer-flag observer 3)
          (compiler-load-lazy-qualified-observer-test-secondary-direct? level))
        (=
          (compiler-load-lazy-qualified-observer-stack-count
            (array-ref observer.stack 0))
          (+ level 1))))))

(define (compiler-load-lazy-qualified-observer-test-result-at?
  [result : CompilerLoadLazyQualifiedObserverResult]
  [offset : i64]
  [level : i64]) : bool
  (and
    (sym_i64_env.sym-i64-contains-id
      result.primary-members
      (compiler-load-lazy-qualified-observer-test-member offset level))
    (sym_i64_env.sym-i64-contains-id
      result.secondary-members
      (compiler-load-lazy-qualified-observer-test-secondary-member offset level))
    (=
      result.secondary-qualified
      (compiler-load-lazy-qualified-observer-test-secondary-qualified? level))
    (=
      result.secondary-direct
      (compiler-load-lazy-qualified-observer-test-secondary-direct? level))))

(define (compiler-load-lazy-qualified-observer-test-empty-result?
  [result : CompilerLoadLazyQualifiedObserverResult]
  [offset : i64]) : bool
  (and
    (not
      (sym_i64_env.sym-i64-contains-id
        result.primary-members
        (compiler-load-lazy-qualified-observer-test-member offset 0)))
    (not
      (sym_i64_env.sym-i64-contains-id
        result.secondary-members
        (compiler-load-lazy-qualified-observer-test-secondary-member offset 0)))
    (not result.secondary-qualified)
    (not result.secondary-direct)))

(define (compiler-load-lazy-qualified-observer-test-push-depth!
  [state : (& state CompilerLoadSessionState)]
  [offset : i64]
  [depth : i64]) : unit
  (let
    [level : i64 0]
    (while (< level depth)
      (begin
        (compiler-load-session-state-lazy-qualified-observer-begin-pair!
          state
          (compiler-load-lazy-qualified-observer-test-root offset level)
          (compiler-load-lazy-qualified-observer-test-secondary-root
            offset
            level))
        (compiler-load-lazy-qualified-observer-test-configure!
          state
          offset
          level)
        (set! level (+ level 1))))))

;; Crosses six geometric capacity boundaries, then pops two independently
;; owned states in an interleaved order. Every frame field is varied so a
;; missing snapshot/restore cannot hide behind the ordinary production values.
(define (compiler-load-lazy-qualified-observer-dense-stack-ok?) : bool
  (let
    [state-a : CompilerLoadSessionState (compiler-load-session-state-new)]
    [state-b : CompilerLoadSessionState (compiler-load-session-state-new)]
    [state-reset : CompilerLoadSessionState (compiler-load-session-state-new)]
    [offset-a : i64 0]
    [offset-b : i64 10000]
    [offset-reset : i64 20000]
    [depth : i64 40]
    [level : i64 0]
    [ok : bool true]
    (begin
      (while (< level depth)
        (begin
          (compiler-load-session-state-lazy-qualified-observer-begin-pair!
            state-a
            (compiler-load-lazy-qualified-observer-test-root offset-a level)
            (compiler-load-lazy-qualified-observer-test-secondary-root
              offset-a
              level))
          (compiler-load-lazy-qualified-observer-test-configure!
            state-a
            offset-a
            level)
          (compiler-load-session-state-lazy-qualified-observer-begin-pair!
            state-b
            (compiler-load-lazy-qualified-observer-test-root offset-b level)
            (compiler-load-lazy-qualified-observer-test-secondary-root
              offset-b
              level))
          (compiler-load-lazy-qualified-observer-test-configure!
            state-b
            offset-b
            level)
          (set! level (+ level 1))))
      (set! level (- depth 1))
      (while (and ok (>= level 0))
        (let
          [result-b : CompilerLoadLazyQualifiedObserverResult
            (compiler-load-session-state-lazy-qualified-observer-end-pair!
              state-b)]
          (begin
            (set!
              ok
              (and
                (compiler-load-lazy-qualified-observer-test-result-at?
                  result-b
                  offset-b
                  level)
                (compiler-load-lazy-qualified-observer-test-state-at?
                  state-a
                  offset-a
                  level)
                (compiler-load-lazy-qualified-observer-test-state-at?
                  state-b
                  offset-b
                  (- level 1))))
            (if ok
              (let
                [result-a : CompilerLoadLazyQualifiedObserverResult
                  (compiler-load-session-state-lazy-qualified-observer-end-pair!
                    state-a)]
                (set!
                  ok
                  (and
                    (compiler-load-lazy-qualified-observer-test-result-at?
                      result-a
                      offset-a
                      level)
                    (compiler-load-lazy-qualified-observer-test-state-at?
                      state-a
                      offset-a
                      (- level 1))
                    (compiler-load-lazy-qualified-observer-test-state-at?
                      state-b
                      offset-b
                      (- level 1)))))
              unit)
            (set! level (- level 1)))))
      ;; A reset from a deep live stack must discard its backing slots rather
      ;; than leave an arena-owned array reachable through the session state.
      (compiler-load-lazy-qualified-observer-test-push-depth!
        state-reset
        offset-reset
        depth)
      (compiler-load-session-state-lazy-qualified-observer-reset! state-reset)
      (set!
        ok
        (and
          ok
          (compiler-load-lazy-qualified-observer-test-empty-state?
            state-reset
            offset-reset)
          (compiler-load-lazy-qualified-observer-test-stack-capacity-zero?
            state-reset)))
      ;; The state remains reusable after that reset.
      (compiler-load-session-state-lazy-qualified-observer-begin-pair!
        state-reset
        (compiler-load-lazy-qualified-observer-test-root offset-reset 0)
        (compiler-load-lazy-qualified-observer-test-secondary-root
          offset-reset
          0))
      (compiler-load-lazy-qualified-observer-test-configure!
        state-reset
        offset-reset
        0)
      (let
        [reset-result : CompilerLoadLazyQualifiedObserverResult
          (compiler-load-session-state-lazy-qualified-observer-end-pair!
            state-reset)]
        (set!
          ok
          (and
            ok
            (compiler-load-lazy-qualified-observer-test-result-at?
              reset-result
              offset-reset
              0)
            (compiler-load-lazy-qualified-observer-test-empty-state?
              state-reset
              offset-reset))))
      ;; Empty pops preserve the old contract: return an empty observation and
      ;; leave both independent states inactive.
      (let
        [underflow-a : CompilerLoadLazyQualifiedObserverResult
          (compiler-load-session-state-lazy-qualified-observer-end-pair!
            state-a)]
        [underflow-b : CompilerLoadLazyQualifiedObserverResult
          (compiler-load-session-state-lazy-qualified-observer-end-pair!
            state-b)]
        (and
          ok
          (compiler-load-lazy-qualified-observer-test-empty-result?
            underflow-a
            offset-a)
          (compiler-load-lazy-qualified-observer-test-empty-result?
            underflow-b
            offset-b)
          (compiler-load-lazy-qualified-observer-test-empty-state?
            state-a
            offset-a)
          (compiler-load-lazy-qualified-observer-test-empty-state?
            state-b
            offset-b)
          (compiler-load-lazy-qualified-observer-test-stack-capacity-zero?
            state-a)
          (compiler-load-lazy-qualified-observer-test-stack-capacity-zero?
            state-b))))))

(define (compiler-load-surface-summary-list-test-summary
  [module-id : i64]
  [source-path-id : i64]
  [source-path : String]) : CompilerLoadSurfaceSummary
  (CompilerLoadSurfaceSummary
    module-id
    module-id
    true
    true
    source-path-id
    source-path
    ""
    (compiler-load-surface-import-list-empty)
    (compiler-load-surface-decl-list-empty)
    false
    false
    false
    false
    (CompilerLoadLazyImportDirect)))

(define (compiler-load-surface-summary-dense-session-ok?) : bool
  (let
    [state-a : CompilerLoadSessionState (compiler-load-session-state-new)]
    [state-b : CompilerLoadSessionState (compiler-load-session-state-new)]
    [module-a : i64 (ci.intern "surface-dense.module-a")]
    [module-b : i64 (ci.intern "surface-dense.module-b")]
    [module-peer : i64 (ci.intern "surface-dense.module-peer")]
    [source-a : i64 (ci.intern "target/surface-dense-a.tl")]
    [source-b : i64 (ci.intern "target/surface-dense-b.tl")]
    [source-peer : i64 (ci.intern "target/surface-dense-peer.tl")]
    [summary-a : CompilerLoadSurfaceSummary
      (compiler-load-surface-summary-list-test-summary
        module-a
        source-a
        "target/surface-dense-a.tl")]
    [duplicate-source : CompilerLoadSurfaceSummary
      (compiler-load-surface-summary-list-test-summary
        module-b
        source-a
        "target/surface-dense-a-duplicate.tl")]
    [duplicate-module : CompilerLoadSurfaceSummary
      (compiler-load-surface-summary-list-test-summary
        module-a
        source-b
        "target/surface-dense-b.tl")]
    [reloaded : CompilerLoadSurfaceSummary
      (compiler-load-surface-summary-list-test-summary
        module-b
        source-b
        "target/surface-dense-b-reloaded.tl")]
    [peer : CompilerLoadSurfaceSummary
      (compiler-load-surface-summary-list-test-summary
        module-peer
        source-peer
        "target/surface-dense-peer.tl")]
    (begin
      ;; Interleave independent sessions and prove duplicate-source suppression
      ;; does not suppress a distinct source with the same module identity.
      (compiler-load-session-state-record-surface-summary!
        (& state-a)
        summary-a)
      (compiler-load-session-state-record-surface-summary! (& state-b) peer)
      (compiler-load-session-state-record-surface-summary!
        (& state-a)
        duplicate-source)
      (compiler-load-session-state-record-surface-summary!
        (& state-a)
        duplicate-module)
      (let
        [before : CompilerLoadSurfaceSummaryList
          (compiler-load-session-state-surface-summaries state-a)]
        [before-ok : bool
          (and
            (=
              (compiler-load-surface-summary-list-count
                (ast.ast-place-shared-view before))
              2)
            (>=
              (array-length before.slots)
              (compiler-load-surface-summary-list-count
                (ast.ast-place-shared-view before)))
            (=
              (__tl-project-field
                (compiler-load-surface-summary-list-at
                  (ast.ast-place-shared-view before)
                  0)
                source-path-id)
              source-b)
            (=
              (__tl-project-field
                (compiler-load-surface-summary-list-at
                  (ast.ast-place-shared-view before)
                  1)
                source-path-id)
              source-a)
            (match (compiler-load-session-state-surface-summary-find-source
              state-a
              source-a)
              [(CompilerLoadSomeSurfaceSummary summary)
                (= summary.module-id module-a)]
              [_ false])
            (match (compiler-load-session-state-surface-summary-find-module
              state-a
              module-a)
              [(CompilerLoadSomeSurfaceSummary summary)
                (= summary.source-path-id source-b)]
              [_ false]))]
        [_remove : unit
          (compiler-load-session-state-surface-summary-remove-source!
            (compiler-load-session-state-shared-view (& state-a))
            source-b)]
        [after-remove-ok : bool
          (and
            (=
              (compiler-load-surface-summary-list-count
                (compiler-load-session-state-surface-summaries state-a))
              1)
            (match (compiler-load-session-state-surface-summary-find-module
              state-a
              module-a)
              [(CompilerLoadSomeSurfaceSummary summary)
                (= summary.source-path-id source-a)]
              [_ false]))]
        [_reload : unit
          (compiler-load-session-state-record-surface-summary! state-a reloaded)]
        [reload-ok : bool
          (and
            (=
              (compiler-load-surface-summary-list-count
                (compiler-load-session-state-surface-summaries state-a))
              2)
            (match (compiler-load-session-state-surface-summary-find-source
              state-a
              source-b)
              [(CompilerLoadSomeSurfaceSummary summary)
                (= summary.module-id module-b)]
              [_ false]))]
        [_reset-a : unit
          (compiler-load-session-state-surface-summaries-reset!
            (compiler-load-session-state-shared-view (& state-a)))]
        [isolation-ok : bool
          (and
            (=
              (compiler-load-surface-summary-list-count
                (compiler-load-session-state-surface-summaries state-a))
              0)
            (=
              (compiler-load-surface-summary-list-count
                (compiler-load-session-state-surface-summaries state-b))
              1)
            (match (compiler-load-session-state-surface-summary-find-source
              state-b
              source-peer)
              [(CompilerLoadSomeSurfaceSummary summary)
                (= summary.module-id module-peer)]
              [_ false]))]
        (and before-ok after-remove-ok reload-ok isolation-ok)))))

(define (compiler-load-dependency-catalog-registry-ok?) : bool
  (let
    [state : CompilerLoadSessionState (compiler-load-session-state-new)]
    [other-state : CompilerLoadSessionState (compiler-load-session-state-new)]
    [owner : i64
      (compiler-load-dependency-catalog-owner-arena-ensure!
        (compiler-load-global-shared-view state))]
    [checks : (__tl_dyn-array bool) (__tl_make-array false)]
    (begin
      (compiler-load-session-state-set-dependency-tlci-force-source!
        (compiler-load-global-shared-view state)
        true)
      (compiler-load-session-state-set-dependency-tlci-force-source!
        (compiler-load-global-shared-view other-state)
        false)
      (in-arena
        (arena.Arena owner)
        (let
          [outer-root : String
            (compiler-load-canonical-path
              (compiler-load-join-root-path
                (fs.current-dir)
                "__dependency_catalog_test"))]
          [nested-root : String
            (compiler-load-join-root-path
              (compiler-load-global-shared-view outer-root)
              "nested")]
          [metadata-root : String
            (compiler-load-join-root-path
              (compiler-load-global-shared-view outer-root)
              "metadata")]
          [outer-key : CompilerLoadDependencyCatalogKey
            (CompilerLoadDependencyCatalogKey
              (compiler-load-global-shared-view outer-root)
              "outer"
              "1.0.0"
              (compiler-load-join-root-path
                (compiler-load-global-shared-view outer-root)
                "target/outer.tlci")
              11
              12
              13
              14
              "compiler-a")]
          [nested-key : CompilerLoadDependencyCatalogKey
            (CompilerLoadDependencyCatalogKey
              (compiler-load-global-shared-view nested-root)
              "nested"
              "2.0.0"
              (compiler-load-join-root-path
                (compiler-load-global-shared-view nested-root)
                "target/nested.tlci")
              21
              22
              23
              24
              "compiler-b")]
          [metadata-key : CompilerLoadDependencyCatalogKey
            (CompilerLoadDependencyCatalogKey
              (compiler-load-global-shared-view metadata-root)
              "metadata"
              "3.0.0"
              (compiler-load-join-root-path
                (compiler-load-global-shared-view metadata-root)
                "target/metadata.tlci")
              31
              32
              (tlci.tlci-build-host-platform)
              tlci.tlci-callback-abi-version
              "compiler-c")]
          [metadata-image : tlci.TlciImage
            (tlci.tlci-make-image
              (tlci.tlci-build-host-platform)
              tlci.tlci-callback-abi-version
              "compiler-c"
              (tlci.tlci-make-metadata-v2
                "metadata"
                "3.0.0"
                (tlci.tlci-spmd-callables-empty))
              (tlci.tlci-empty-bytes)
              (tlci.tlci-empty-bytes)
              (tlci.tlci-empty-bytes)
              (tlci.tlci-empty-bytes)
              (tlci.tlci-empty-bytes)
              (tlci.tlci-empty-bytes))]
          [outer-entry : CompilerLoadDependencyCatalogEntry
            (CompilerLoadDependencyCatalogEntry
              outer-key
              CompilerLoadDependencyCatalogImage.None
              (tlci.tlci-spmd-callables-empty)
              (CompilerLoadDependencyCatalogStatus.Unavailable
                (CompilerLoadDependencyCatalogFailure.Missing "outer missing")))]
          [nested-entry : CompilerLoadDependencyCatalogEntry
            (CompilerLoadDependencyCatalogEntry
              (compiler-load-global-shared-view nested-key)
              CompilerLoadDependencyCatalogImage.None
              (tlci.tlci-spmd-callables-empty)
              (CompilerLoadDependencyCatalogStatus.Unavailable
                (CompilerLoadDependencyCatalogFailure.Missing "nested missing")))]
          [metadata-entry : CompilerLoadDependencyCatalogEntry
            (CompilerLoadDependencyCatalogEntry
              metadata-key
              (CompilerLoadDependencyCatalogImage.Some metadata-image)
              (tlci.tlci-spmd-callables-empty)
              CompilerLoadDependencyCatalogStatus.TrustedMetadataOnly)]
          [outer-slot : i64
            (compiler-load-dependency-catalog-record-owned!
              (compiler-load-global-shared-view state)
              outer-entry)]
          [nested-slot : i64
            (compiler-load-dependency-catalog-record-owned!
              (compiler-load-global-shared-view state)
              (compiler-load-global-shared-view nested-entry))]
          [metadata-slot : i64
            (compiler-load-dependency-catalog-record-owned!
              (compiler-load-global-shared-view state)
              metadata-entry)]
          [nested-provenance : i64
            (ci.intern
              (compiler-load-join-root-path
                (compiler-load-global-shared-view nested-root)
                "src/lib.tl"))]
          [outer-provenance : i64
            (ci.intern (compiler-load-join-root-path outer-root "src/lib.tl"))]
          [sibling-provenance : i64
            (ci.intern
              (compiler-load-join-root-path
                (fs.current-dir)
                "__dependency_catalog_test-other/src/lib.tl"))]
          [same-slot : i64
            (compiler-load-dependency-catalog-record-owned!
              (compiler-load-global-shared-view state)
              (compiler-load-global-shared-view nested-entry))]
          [observation : CompilerLoadDependencyCatalogObservation
            (compiler-load-dependency-catalog-observe
              (compiler-load-global-shared-view state))]
          (set!
            (array-ref checks 0)
            (and
              (compiler-load-session-state-dependency-tlci-force-source? state)
              (not
                (compiler-load-session-state-dependency-tlci-force-source?
                  other-state))
              (= outer-slot 0)
              (= nested-slot 1)
              (= metadata-slot 2)
              (= same-slot nested-slot)
              (=
                (compiler-load-dependency-catalog-find-key-slot
                  (compiler-load-global-shared-view state)
                  (compiler-load-global-shared-view nested-key))
                nested-slot)
              (=
                (compiler-load-dependency-catalog-slot-for-provenance-id
                  (compiler-load-global-shared-view state)
                  nested-provenance)
                nested-slot)
              (=
                (compiler-load-dependency-catalog-slot-for-provenance-id
                  (compiler-load-global-shared-view state)
                  outer-provenance)
                outer-slot)
              (=
                (compiler-load-dependency-catalog-slot-for-provenance-id
                  (compiler-load-global-shared-view state)
                  sibling-provenance)
                -1)
              (=
                (compiler-load-dependency-catalog-slot-for-provenance-id
                  other-state
                  nested-provenance)
                -1)
              (match (compiler-load-dependency-catalog-lookup-macro
                (compiler-load-global-shared-view state)
                metadata-slot
                "metadata/macro")
                [(CompilerLoadDependencyCatalogLookup.MetadataOnly) true]
                [_ false])
              (match (compiler-load-dependency-catalog-admitted-image
                (compiler-load-global-shared-view state)
                metadata-slot)
                [(CompilerLoadDependencyCatalogAdmittedImage.TrustedMetadataOnly
                    image)
                  (and
                    (= (array-length image.code) 0)
                    (= (array-length image.fixups) 0)
                    (= (array-length image.entries) 0)
                    (= (array-length image.imports) 0))]
                [_ false])
              (match (compiler-load-dependency-catalog-lookup-macro
                (compiler-load-global-shared-view state)
                nested-slot
                "nested/macro")
                [(CompilerLoadDependencyCatalogLookup.Unavailable
                    (CompilerLoadDependencyCatalogFailure.Missing message))
                  (string.eq message "nested missing")]
                [_ false])
              (= observation.entries 3)
              (= observation.generation 3)
              (= observation.unavailable 2)
              (= observation.metadata-only 1)
              (= observation.trusted-code 0)
              (= observation.code-bytes 0)
              (= observation.fixup-bytes 0)
              (= observation.entry-bytes 0)
              (= observation.import-bytes 0)))
          (let
            [capability : CompilerLoadDependencyCatalogCapability
              (CompilerLoadDependencyCatalogCapability
                (compiler-load-session-state-dependency-catalog-handle
                  (compiler-load-global-shared-view state))
                nested-slot
                (compiler-load-global-shared-view nested-key)
                (array-ref state.dependency-catalog.generation 0)
                (ci.intern
                  (compiler-load-global-shared-view nested-key.package-name))
                (ci.intern
                  (compiler-load-global-shared-view nested-key.package-version))
                (ci.intern
                  (compiler-load-global-shared-view nested-key.artifact-path))
                (tlci_loader_support.TlciResolvedMacroEntry 0 0))]
            [replacement-key : CompilerLoadDependencyCatalogKey
              (CompilerLoadDependencyCatalogKey
                (compiler-load-global-shared-view nested-root)
                "nested"
                "2.0.0"
                (compiler-load-join-root-path
                  (compiler-load-global-shared-view nested-root)
                  "target/nested-next.tlci")
                21
                222
                23
                24
                "compiler-b")]
            [replacement-entry : CompilerLoadDependencyCatalogEntry
              (CompilerLoadDependencyCatalogEntry
                replacement-key
                CompilerLoadDependencyCatalogImage.None
                (tlci.tlci-spmd-callables-empty)
                (CompilerLoadDependencyCatalogStatus.Unavailable
                  (CompilerLoadDependencyCatalogFailure.Missing
                    "nested replacement missing")))]
            (begin
              (set!
                (array-ref checks 0)
                (and
                  (array-ref checks 0)
                  (compiler-load-dependency-catalog-capability-current?
                    (compiler-load-global-shared-view capability))))
              (compiler-load-dependency-catalog-record-owned!
                (compiler-load-global-shared-view state)
                replacement-entry)
              (set!
                (array-ref checks 0)
                (and
                  (array-ref checks 0)
                  (not
                    (compiler-load-dependency-catalog-capability-current?
                      (compiler-load-global-shared-view capability)))))))))
      (let
        [release-ok : bool
          (match (compiler-load-session-state-dependency-catalog-release!
            (compiler-load-global-shared-view state))
            [(ResultCompilerLoadDependencyCatalogUnit.Ok) true]
            [(ResultCompilerLoadDependencyCatalogUnit.Err _) false])]
        (and
          (array-ref checks 0)
          release-ok
          (=
            (compiler-load-dependency-catalog-owner-arena
              (compiler-load-global-shared-view state))
            0)
          (= (array-ref state.dependency-catalog.entries 0).len 0))))))

(define (compiler-load-self-test) : i64
  (begin
    (unless
      (compiler-load-dependency-catalog-registry-ok?)
      (return (io.panic "compiler-load: dependency catalog registry mismatch")))
    (unless
      (compiler-load-embedded-provenance-observer-ok?)
      (return (io.panic "compiler-load: embedded provenance observer mismatch")))
    (unless
      (compiler-load-session-explicit-cache-api-isolation-ok?)
      (return
        (io.panic "compiler-load: explicit cache API isolation smoke mismatch")))
    (unless
      (compiler-load-session-explicit-parse-isolation-ok?)
      (return
        (io.panic "compiler-load: explicit parse isolation smoke mismatch")))
    (unless
      (compiler-load-session-owned-traversal-isolation-ok?)
      (return
        (io.panic "compiler-load: owned traversal isolation smoke mismatch")))
    (unless
      (compiler-load-surface-summary-dense-session-ok?)
      (return
        (io.panic "compiler-load: dense surface summary session mismatch")))
    (unless
      (compiler-load-lazy-qualified-observer-dense-stack-ok?)
      (return
        (io.panic "compiler-load: lazy qualified observer dense stack mismatch")))
    (unless
      (compiler-load-append-onto-reuse-ok?)
      (return (io.panic "compiler-load: append-onto reuse smoke mismatch")))
    (unless
      (compiler-load-normalize-ok?)
      (return (io.panic "compiler-load: normalize smoke mismatch")))
    (unless
      (compiler-load-canonical-module-id-ok?)
      (return (io.panic "compiler-load: canonical module id smoke mismatch")))
    (unless
      (compiler-load-relative-resolution-ok?)
      (return (io.panic "compiler-load: relative resolution smoke mismatch")))
    (unless
      (compiler-load-dotted-module-path-cache-ok?)
      (return (io.panic "compiler-load: dotted path cache smoke mismatch")))
    (unless
      (compiler-load-package-owner-paths-ok?)
      (return (io.panic "compiler-load: package owner path smoke mismatch")))
    (unless
      (compiler-load-package-owner-extern-symbol-ok?)
      (return
        (io.panic "compiler-load: package owner extern symbol smoke mismatch")))
    (unless
      (compiler-load-package-source-macro-preserved-ok?)
      (return
        (io.panic "compiler-load: package source macro was not preserved")))
    (unless
      (compiler-load-package-imported-spmd-metadata-ok?)
      (return
        (io.panic
          "compiler-load: package imported SPMD metadata smoke mismatch")))
    (unless
      (compiler-load-source-provenance-ok?)
      (return (io.panic "compiler-load: source provenance smoke mismatch")))
    (unless
      (compiler-load-entry-moduled-main-ok?)
      (return (io.panic "compiler-load: entry moduled main smoke mismatch")))
    (unless
      (compiler-load-expected-module-conflict-ok?)
      (return (io.panic "compiler-load: expected module smoke mismatch")))
    (unless
      (compiler-load-duplicate-module-ok?)
      (return (io.panic "compiler-load: duplicate module smoke mismatch")))
    (unless
      (compiler-load-nested-module-body-ok?)
      (return (io.panic "compiler-load: nested module body smoke mismatch")))
    (unless
      (compiler-load-nested-module-duplicate-ok?)
      (return
        (io.panic "compiler-load: nested module duplicate smoke mismatch")))
    (unless
      (compiler-load-seen-module-ok?)
      (return (io.panic "compiler-load: seen module smoke mismatch")))
    (unless
      (compiler-load-cfg-import-ok?)
      (return (io.panic "compiler-load: cfg import smoke mismatch")))
    (unless
      (compiler-load-surface-summary-smoke-ok?)
      (return (io.panic "compiler-load: surface summary smoke mismatch")))
    (unless
      (compiler-load-session-cache-common-dep-ok?)
      (return
        (io.panic "compiler-load: session cache common dep smoke mismatch")))
    (unless
      (compiler-load-session-cache-root-isolation-ok?)
      (return
        (io.panic "compiler-load: session cache root isolation smoke mismatch")))
    (unless
      (compiler-load-session-cache-entry-cold-ok?)
      (return
        (io.panic "compiler-load: session cache entry cold smoke mismatch")))
    (unless
      (compiler-load-session-persistent-floor-interns-ok?)
      (return
        (io.panic
          "compiler-load: session cache intern floor kept scratch storage")))
    (unless
      (compiler-load-session-cache-local-common-dep-ok?)
      (return
        (io.panic
          "compiler-load: session cache local common dep smoke mismatch")))
    (unless
      (compiler-load-session-cache-package-common-dep-ok?)
      (return
        (io.panic
          "compiler-load: session cache package common dep smoke mismatch")))
    (unless
      (compiler-load-file-import-dedup-cycle-ok?)
      (return (io.panic "compiler-load: import dedup/cycle smoke mismatch")))
    (unless
      (compiler-load-import-module-restore-ok?)
      (return (io.panic "compiler-load: import module restore smoke mismatch")))
    (unless
      (compiler-load-import-alias-preserved-ok?)
      (return
        (io.panic "compiler-load: import alias preservation smoke mismatch")))
    (unless
      (compiler-load-dotted-import-duplicate-alias-ok?)
      (return
        (io.panic "compiler-load: dotted import duplicate alias smoke mismatch")))
    (unless
      (compiler-load-dotted-import-same-alias-same-module-ok?)
      (return
        (io.panic
          "compiler-load: dotted import same-module alias smoke mismatch")))
    (unless
      (compiler-load-dotted-import-resolution-ok?)
      (return
        (io.panic "compiler-load: dotted import resolution smoke mismatch")))
    (unless
      (compiler-load-import-suffix-resolution-ok?)
      (return
        (io.panic "compiler-load: import suffix resolution smoke mismatch")))
    (unless
      (compiler-load-dotted-source-root-ok?)
      (return (io.panic "compiler-load: dotted source root smoke mismatch")))
    (unless
      (compiler-load-moduleless-dotted-source-root-ok?)
      (return
        (io.panic "compiler-load: moduleless dotted source root smoke mismatch")))
    (unless
      (compiler-load-stdlib-source-module-import-ok?)
      (return
        (io.panic "compiler-load: stdlib source module import smoke mismatch")))
    (unless
      (compiler-load-dotted-source-root-fallback-ok?)
      (return
        (io.panic "compiler-load: dotted source root fallback smoke mismatch")))
    (unless
      (compiler-load-dotted-transitive-import-ok?)
      (return
        (io.panic "compiler-load: dotted transitive import smoke mismatch")))
    (unless
      (compiler-load-canonical-source-explicit-mismatch-ok?)
      (return
        (io.panic "compiler-load: canonical source mismatch smoke mismatch")))
    (unless
      (compiler-load-package-dotted-import-resolution-ok?)
      (return
        (io.panic
          "compiler-load: package dotted import resolution smoke mismatch")))
    (unless
      (compiler-load-package-dotted-sibling-source-ok?)
      (return
        (io.panic "compiler-load: package dotted sibling source smoke mismatch")))
    (unless
      (compiler-load-package-second-root-source-ok?)
      (return
        (io.panic "compiler-load: package second root source smoke mismatch")))
    (unless
      (compiler-load-package-moduleless-pkg-import-id-ok?)
      (return
        (io.panic "compiler-load: package moduleless pkg import smoke mismatch")))
    (unless
      (compiler-load-package-dotted-explicit-module-id-ok?)
      (return
        (io.panic
          "compiler-load: package dotted explicit module smoke mismatch")))
    (unless
      (compiler-load-generated-meta-preserved-ok?)
      (return
        (io.panic
          "compiler-load: generated metadata preservation smoke mismatch")))
    (unless
      (compiler-load-diamond-import-ok?)
      (return (io.panic "compiler-load: diamond import smoke mismatch")))
    (unless
      (compiler-load-transitive-import-ok?)
      (return (io.panic "compiler-load: transitive import smoke mismatch")))
    (unless
      (compiler-load-missing-import-ok?)
      (return (io.panic "compiler-load: missing import smoke mismatch")))
    (unless
      (compiler-load-include-str-relative-ok?)
      (return (io.panic "compiler-load: include-str relative smoke mismatch")))
    (unless
      (compiler-load-include-str-stdlib-root-ok?)
      (return
        (io.panic "compiler-load: include-str stdlib root smoke mismatch")))
    (unless
      (compiler-load-include-str-comptime-relative-ok?)
      (return
        (io.panic "compiler-load: include-str-comptime relative smoke mismatch")))
    (unless
      (compiler-load-include-str-lzss-relative-ok?)
      (return
        (io.panic "compiler-load: include-str-lzss relative smoke mismatch")))
    (unless
      (compiler-load-missing-include-str-ok?)
      (return (io.panic "compiler-load: missing include-str smoke mismatch")))
    (unless
      (compiler-load-include-str-raw-text-ok?)
      (return (io.panic "compiler-load: include-str raw text smoke mismatch")))
    (unless
      (compiler-load-include-bin-relative-ok?)
      (return (io.panic "compiler-load: include-bin relative smoke mismatch")))
    (unless
      (compiler-load-missing-include-bin-ok?)
      (return (io.panic "compiler-load: missing include-bin smoke mismatch")))
    (unless
      (compiler-load-embedded-stdlib-lookup-ok?)
      (return (io.panic "compiler-load: embedded stdlib lookup smoke mismatch")))
    (unless
      (compiler-load-embedded-stdlib-missing-ok?)
      (return
        (io.panic "compiler-load: embedded stdlib missing smoke mismatch")))
    (unless
      (compiler-load-embedded-stdlib-escape-rejected-ok?)
      (return (io.panic "compiler-load: embedded stdlib escape smoke mismatch")))
    (unless
      (compiler-load-imported-parse-error-path-ok?)
      (return
        (io.panic "compiler-load: imported parse error path smoke mismatch")))
    (unless
      (compiler-load-imported-duplicate-module-path-ok?)
      (return
        (io.panic
          "compiler-load: imported duplicate module path smoke mismatch")))
    (unless
      (compiler-load-stdlib-root-fallback-ok?)
      (return (io.panic "compiler-load: stdlib root fallback smoke mismatch")))
    (unless
      (compiler-load-prelude-source-precedence-ok?)
      (return
        (io.panic "compiler-load: prelude source precedence smoke mismatch")))
    (unless
      (compiler-load-stdlib-searched-root-ok?)
      (return (io.panic "compiler-load: stdlib searched root smoke mismatch")))
    (unless
      (compiler-load-stdlib-unresolved-ok?)
      (return (io.panic "compiler-load: stdlib unresolved smoke mismatch")))
    (unless
      (compiler-load-pkg-manifest-ok?)
      (return (io.panic "compiler-load: pkg manifest smoke mismatch")))
    (unless
      (compiler-load-manifest-path-inference-ok?)
      (return
        (io.panic "compiler-load: manifest path inference smoke mismatch")))
    (unless
      (compiler-load-pkg-resolve-ok?)
      (return (io.panic "compiler-load: pkg resolve smoke mismatch")))
    (unless
      (compiler-load-pkg-parent-dir-ok?)
      (return (io.panic "compiler-load: pkg parent-dir smoke mismatch")))
    (unless
      (compiler-load-string-vec-roots-ok?)
      (return (io.panic "compiler-load: string vec roots smoke mismatch")))
    (unless
      (compiler-load-pkg-dep-list-ok?)
      (return (io.panic "compiler-load: pkg-dep-list smoke mismatch")))
    42))