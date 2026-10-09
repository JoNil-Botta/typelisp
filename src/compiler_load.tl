;; compiler_load.tl - Shared selfhost compiler source/import loader.
(import stdlib.arena)
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
(import compiler_source_overlay as source_overlay)

(defmacro (compiler-load-global-shared-view [place : Expr]) : Expr
  `(unsafe
    (ptr-read (ptr-addr-of ,place))))

(defmacro (compiler-load-global-array-element-shared-view
  [items : Expr]
  [index : Expr]) : Expr
  `(unsafe
    (ptr-read (ptr-offset (__tl_array-data ,items) ,index))))

;; CompilerProfileState slot 350 is the load lifetime ledger's exact source
;; payload count. The active loader session already owns an explicit interner
;; whose profile-metrics address names that job's storage, so this adds no
;; process-global counter and no field/allocation to ordinary loader state.
(cfg
  (any compile-profile test)
  (define compiler-load-profile-input-bytes-metric : i64
    350))

(cfg
  (any compile-profile test)
  (define (compiler-load-profile-note-input-bytes! [count : i64]) : unit
    ;; Standalone `check`, manifest, and test readers intentionally use the
    ;; compatibility session, whose interner may expose a narrower leaf metric
    ;; view. Only an installed driver-owned load session carries the full
    ;; CompilerProfileState address used by slot 350.
    (if (not (compiler-load-active-session-live?))
      unit
      (let
        [load-state : CompilerLoadSessionState
          (compiler-load-active-session-state-shared-view)]
        [intern-state : ci.InternCompatState
          (compiler-load-session-state-interns load-state)]
        [metrics-address : u64
          (ci.intern-compat-state-profile-metrics-address-ref (& intern-state))]
        (if (= metrics-address (cast 0 : u64))
          unit
          (unsafe
            (let
              [slot : (MutPtr i64)
                (ptr-offset
                  (int->ptr metrics-address : (MutPtr i64))
                  compiler-load-profile-input-bytes-metric)]
              (ptr-write! slot (+ (ptr-read slot) count)))))))))

;; Sources, manifests, and include payloads are interpreted as text here.
;; Make that conversion explicit at the binary IO boundary.
(define (compiler-load-read-file-text [path : (& path str)]) : String
  (let
    [contents : byte_buf.ByteBuf (io.read-file (string.copy path))]
    [count : i64 (byte_buf.len contents)]
    [_profile-input : unit
      (cfg compile-profile (compiler-load-profile-note-input-bytes! count) unit)]
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

(define (compiler-load-try-read-file-text [path : (& source str)]) : io.ResultIoString
  (let
    [contents (try (io.try-read-file path))]
    (begin
      (cfg
        compile-profile
        (compiler-load-profile-note-input-bytes! (byte_buf.len contents))
        unit)
      (OkIoString (byte_buf.to-string contents)))))

(define (compiler-load-lex-token-buffer-arena-handle) : i64
  (lexer.spanned-token-buffer-arena-handle-value))

(define (compiler-load-reader-node-pool-arena-handle) : i64
  (reader.sp-node-pool-base-arena-handle-value))

;; Retire the frontend token buffer once a whole-program load has returned its
;; `ast.AstDeclList`. It is pure scan scratch whose contents were already copied
;; out by value; see the no-dangling argument at its release site in `lex.tl`.
;; Only single-entry compile paths call this: a session that reuses loader
;; state across jobs would just pay the regrow.
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
  (lexer.spanned-token-buffer-release!))

;; Whole-program uncached handoff: release pure scan storage and transfer the
;; compact declaration/member/semantic-origin prefix out of the reader arena
;; whose capacity was sized by the largest transient source form.  Source text,
;; token rows and reader builders are not part of this graph;
;; the stable row ids and by-value spans are the only data later diagnostics,
;; symbol collection, semantic indexing, and macro/typecheck paths consume.
(define (compiler-load-transfer-frontend-handoff!) : unit
  (compiler-load-release-frontend-scan-arenas!)
  (reader.sp-node-pool-compact-retained!))

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
  (Available String tlci.TlciSpmdCallables))

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

(defstruct CompilerLoadUnqualifiedImportState
  (source-ids load_i64_i64_map.Map)
  (source-modules load_i64_i64_map.Map)
  ;; Declaration index of each name a module declares itself. Only modules
  ;; with unqualified imports are recorded: no other module can collide.
  (local-decls load_i64_i64_map.Map))

(defstruct CompilerLoadUnqualifiedImportCollision
  (name String)
  (first-module String)
  (second-module String)
  (path String)
  (span ast.AstSourceSpan)
  ;; Declaration index of the importing module's own declaration of `name`,
  ;; or -1 when both bindings are imports.
  (local-index i64))

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
    i64
    ast.AstFieldDefList)
  (CompilerLoadSurfaceEnumSignature
    ast.AstLifetimeList
    ast.AstEnumCleanup
    i64
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
    (__tl_make-array CompilerLoadSurfaceImport 0)
    0))

(define (compiler-load-surface-import-list-count
  [imports : (& imports CompilerLoadSurfaceImportList)]) : i64
  imports.len)

(define (compiler-load-surface-import-list-at
  [imports : (& imports CompilerLoadSurfaceImportList)]
  [index : i64]) : CompilerLoadSurfaceImport
  (clone (array-ref imports.slots index)))

(define (compiler-load-surface-decl-list-empty) : CompilerLoadSurfaceDeclList
  (CompilerLoadSurfaceDeclList (__tl_make-array CompilerLoadSurfaceDecl 0) 0))

(define (compiler-load-surface-decl-list-count
  [decls : (& decls CompilerLoadSurfaceDeclList)]) : i64
  decls.len)

(define (compiler-load-surface-decl-list-at
  [decls : (& decls CompilerLoadSurfaceDeclList)]
  [index : i64]) : CompilerLoadSurfaceDecl
  (clone (array-ref decls.slots index)))

;; Read-only searches borrow candidates; retained payloads use the owning accessor.
(define (compiler-load-surface-decl-list-borrow-at
  [decls : (& decls CompilerLoadSurfaceDeclList)]
  [index : i64]) : (& decls CompilerLoadSurfaceDecl)
  (& (array-ref decls.slots index)))

(define (compiler-load-surface-summary-list-empty) : CompilerLoadSurfaceSummaryList
  (CompilerLoadSurfaceSummaryList
    (__tl_make-array CompilerLoadSurfaceSummary 0)
    0))

(define (compiler-load-surface-summary-list-count
  [summaries : (& summaries CompilerLoadSurfaceSummaryList)]) : i64
  summaries.len)

(define (compiler-load-surface-summary-list-at
  [summaries : (& summaries CompilerLoadSurfaceSummaryList)]
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

;; Embedded-stdlib route trust belongs to the load session whose intern table
;; produced these ids. Keeping the map heads in the session prevents a batch
;; reset or an interleaved job from reinterpreting a numeric id under another
;; intern generation.
(defstruct CompilerLoadEmbeddedStdlibProvenanceState
  (module-ids (__tl_dyn-array sym_i64_env.SymI64Env))
  (equivalence-cache (__tl_dyn-array sym_i64_env.SymI64Env))
  ;; Physical source path -> stdlib suffix, for each stdlib module read from a
  ;; path not already spelled `stdlib/<suffix>` (#8430). The module's name
  ;; identity is `stdlib/<suffix>` wherever its root lies relative to the cwd;
  ;; its path stays physical. -1 marks a path whose suffix another file also
  ;; claimed.
  (canonical-paths (__tl_dyn-array sym_i64_env.SymI64Env))
  ;; Stdlib suffix -> the first physical path noted for it.
  (suffix-claims (__tl_dyn-array sym_i64_env.SymI64Env))
  (noted (__tl_dyn-array bool)))

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
  (__tl_make-array CompilerLoadDependencyCatalogEntry 0))

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
        [(EnvSomeString value) (string.eq value "1")]
        [(EnvNoString) false]))))

;; What answers a session's source reads during an overlay check (#7455). While
;; `active`, an admitted overlay entry answers its canonical path, every other
;; source is read as usual, and each consumed source is recorded in `ledger`,
;; which allocates in `owner-arena` so it outlives per-file scratch arenas.
(defstruct CompilerLoadSourceProvider
  (active bool)
  (overlay source_overlay.CompilerSourceOverlay)
  (ledger source_overlay.CompilerSourceLedger)
  (owner-arena i64))

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
  (embedded-stdlib-provenance CompilerLoadEmbeddedStdlibProvenanceState)
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
  ;; Surface summaries must outlive macro scratch, but no summary payload may
  ;; accumulate in the process-lived session owner across batch entries. The
  ;; mutable handle names a dedicated, resettable payload arena.
  (surface-summary-owner-arena (__tl_dyn-array i64))
  ;; Stable arena address of the canonical shallow state record. Every field
  ;; is itself an arena-backed handle, so reading this record preserves the
  ;; session identity without a reference-typed temporary during bootstrap.
  (owner-arena i64)
  (shared-address u64)
  (dotted-path-cache-owner-arena (__tl_dyn-array i64))
  (embedded-provenance-owner-arena (__tl_dyn-array i64))
  (source-provider (__tl_dyn-array CompilerLoadSourceProvider)))

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
    [flags : (__tl_dyn-array bool) (__tl_make-array bool 3)]
    (set! (array-ref flags 2) true)
    flags))

(define (compiler-load-session-state-i64-cell [value : i64]) : (__tl_dyn-array
    i64)
  (__tl_make-array value))

(define (compiler-load-lazy-qualified-observer-stack-empty) : CompilerLoadLazyQualifiedObserverStack
  (CompilerLoadLazyQualifiedObserverStack
    (__tl_make-array CompilerLoadLazyQualifiedObserverFrame 0)
    0))

(define (compiler-load-lazy-qualified-observer-state-new) : CompilerLoadLazyQualifiedObserverState
  (let
    [flags : (__tl_dyn-array bool) (__tl_make-array bool 4)]
    [root-ids : (__tl_dyn-array i64) (__tl_make-array i64 2)]
    [member-sets : (__tl_dyn-array sym_i64_env.SymI64Env)
      (__tl_make-array sym_i64_env.SymI64Env 2)]
    [stack : (__tl_dyn-array CompilerLoadLazyQualifiedObserverStack)
      (__tl_make-array (compiler-load-lazy-qualified-observer-stack-empty))]
    (set! (array-ref member-sets 0) (sym_i64_env.sym-i64-empty))
    (set! (array-ref member-sets 1) (sym_i64_env.sym-i64-empty))
    (CompilerLoadLazyQualifiedObserverState flags root-ids member-sets stack)))

(define (compiler-load-session-state-bool-cell-get
  [cell : (& cell (__tl_dyn-array bool))]) : bool
  (array-ref cell 0))

(define (compiler-load-session-state-bool-cell-set!
  [cell : (__tl_dyn-array bool)]
  [value : bool]) : unit
  (set! (array-ref cell 0) value))

(define (compiler-load-embedded-stdlib-provenance-state-new) : CompilerLoadEmbeddedStdlibProvenanceState
  (CompilerLoadEmbeddedStdlibProvenanceState
    (__tl_make-array (sym_i64_env.sym-i64-empty))
    (__tl_make-array (sym_i64_env.sym-i64-empty))
    (__tl_make-array (sym_i64_env.sym-i64-empty))
    (__tl_make-array (sym_i64_env.sym-i64-empty))
    (compiler-load-session-state-bool-cell false)))

(define (compiler-load-source-provider-inactive) : CompilerLoadSourceProvider
  (CompilerLoadSourceProvider
    false
    (source_overlay.compiler-source-overlay-empty "")
    (source_overlay.compiler-source-ledger-new
      (source_overlay.compiler-source-overlay-default-limits))
    0))

(define (compiler-load-source-provider-cell) : (__tl_dyn-array
    CompilerLoadSourceProvider)
  (__tl_make-array (compiler-load-source-provider-inactive)))

(define (compiler-load-session-state-new-with-reset-safety-and-catalog
  [standalone-reset-safe : bool]
  [catalog : CompilerLoadDependencyCatalogRegistry]) : CompilerLoadSessionState
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
        (compiler-load-embedded-stdlib-provenance-state-new)
        catalog
        (compiler-load-dependency-surface-state-new)
        (compiler-load-session-state-bool-cell false)
        (__tl_make-array ci.InternCompatState 1)
        (compiler-load-session-state-bool-cell false)
        (compiler-load-session-state-bool-cell standalone-reset-safe)
        (compiler-load-session-state-i64-cell 0)
        (arena.tl_arena_current)
        0
        (compiler-load-session-state-i64-cell 0)
        (compiler-load-session-state-i64-cell 0)
        (compiler-load-source-provider-cell))]
    [cell : (__tl_dyn-array CompilerLoadSessionState) (__tl_make-array initial)]
    [address : u64
      (unsafe
        (ptr->int (__tl_array-data cell)))]
    [canonical : CompilerLoadSessionState
      (compiler-load-global-array-element-shared-view cell 0)]
    (set! canonical.shared-address address)
    (set! (array-ref cell 0) canonical)
    (compiler-load-global-array-element-shared-view cell 0)))

(define (compiler-load-session-state-new-with-standalone-reset-safety
  [standalone-reset-safe : bool]) : CompilerLoadSessionState
  (compiler-load-session-state-new-with-reset-safety-and-catalog
    standalone-reset-safe
    (compiler-load-dependency-catalog-registry-new)))

;; A package child owns fresh parse caches and hydrated surfaces, but borrows the
;; enclosing package's admitted images. Its teardown must release only those
;; derived surfaces, never the enclosing catalog or its executable mappings.
(define (compiler-load-session-state-new-for-package-child
  [parent : CompilerLoadSessionState]) : CompilerLoadSessionState
  (let
    [state : CompilerLoadSessionState
      (compiler-load-session-state-new-with-reset-safety-and-catalog
        true
        parent.dependency-catalog)]
    (compiler-load-session-state-set-dependency-tlci-force-source!
      (owned_view.compiler-owned-shared-view state)
      (compiler-load-session-state-dependency-tlci-force-source? parent))
    state))

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
  [state : (& state CompilerLoadSessionState)]) : i64
  (array-ref state.dependency-catalog.owner-arena 0))

(define (compiler-load-dependency-catalog-owner-arena-ensure!
  [state : CompilerLoadSessionState]) : i64
  (let
    [owner : i64 (compiler-load-dependency-catalog-owner-arena state)]
    (if (> owner 0)
      owner
      (let
        [next : i64 (arena.tl_arena_make_small)]
        (set! (array-ref state.dependency-catalog.owner-arena 0) next)
        next))))

(define (compiler-load-dependency-catalog-key-eq?
  [left : (& left CompilerLoadDependencyCatalogKey)]
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
    [(TrustedCode loaded)
      (let
        [_ (try (tlci_loader_support.tlci-loader-release loaded))]
        Ok)]
    [_ Ok]))

(define (compiler-load-dependency-catalog-find-root-slot
  [items : CompilerLoadDependencyCatalogList]
  [canonical-root : (& canonical-root str)]) : i64
  (let
    [index : i64 0]
    (while (< index items.len)
      (let
        [entry : CompilerLoadDependencyCatalogEntry
          (owned_view.compiler-owned-array-element-shared-view
            items.slots
            index)]
        (if (string.eq entry.key.canonical-root canonical-root)
          (return index)
          (set! index (+ index 1)))))
    -1))

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
        key.canonical-root)]
    (if (and
      (>= slot 0)
      (let
        [entry : CompilerLoadDependencyCatalogEntry
          (owned_view.compiler-owned-array-element-shared-view items.slots slot)]
        (compiler-load-dependency-catalog-key-eq? entry.key key)))
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
        (__tl_make-array CompilerLoadDependencyCatalogEntry capacity))]
    [index : i64 0]
    (while (< index items.len)
      (set!
        (array-ref slots index)
        (owned_view.compiler-owned-array-element-shared-view items.slots index))
      (set! index (+ index 1)))
    (CompilerLoadDependencyCatalogList slots items.len)))

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
        entry.key.canonical-root)]
    (if (>= slot 0)
      (let
        [old : CompilerLoadDependencyCatalogEntry
          (owned_view.compiler-owned-array-element-shared-view items.slots slot)]
        (if (compiler-load-dependency-catalog-key-eq? old.key entry.key)
          slot
          (begin
            (match (compiler-load-dependency-catalog-entry-release-mapping! old)
              [(Ok) unit]
              [(Err _) unit])
            (set! (array-ref items.slots slot) entry)
            (set!
              (array-ref registry.generation 0)
              (+ (array-ref registry.generation 0) 1))
            slot)))
      (let
        [owner : i64
          (compiler-load-dependency-catalog-owner-arena-ensure! state)]
        [ready : CompilerLoadDependencyCatalogList
          (if (< items.len (array-length items.slots))
            items
            (compiler-load-dependency-catalog-grow owner items))]
        [next-slot : i64 ready.len]
        (set! (array-ref ready.slots next-slot) entry)
        (set! ready.len (+ ready.len 1))
        (set! (array-ref registry.entries 0) ready)
        (set!
          (array-ref registry.generation 0)
          (+ (array-ref registry.generation 0) 1))
        next-slot))))

(define (compiler-load-dependency-catalog-release-from!
  [items : CompilerLoadDependencyCatalogList]
  [index : i64]
  [first-error : String]) : String
  (if (>= index items.len)
    first-error
    (match (compiler-load-dependency-catalog-entry-release-mapping!
      (owned_view.compiler-owned-array-element-shared-view items.slots index))
      [(Ok)
        (compiler-load-dependency-catalog-release-from!
          items
          (+ index 1)
          first-error)]
      [(Err message)
        (compiler-load-dependency-catalog-release-from!
          items
          (+ index 1)
          (if (= (string.string-length first-error) 0)
            message
            first-error))])))

;; Retire only derived frontend views; admitted catalog mappings stay live.
;; Call after clearing typecheck/prefix references, in the arena that should
;; own the replacement empty session carriers.
(define (compiler-load-session-state-dependency-surfaces-release!
  [state : CompilerLoadSessionState]) : unit
  (let
    [surface-state : CompilerLoadDependencySurfaceState
      state.dependency-surfaces]
    (compiler-load-dependency-surface-list-destroy-storage!
      (owned_view.compiler-owned-array-element-shared-view
        surface-state.fragments
        0))
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
    (set! (array-ref surface-state.typecheck-skip-count 0) 0)))

(define (compiler-load-session-state-dependency-catalog-release!
  [state : CompilerLoadSessionState]) : ResultCompilerLoadDependencyCatalogUnit
  (let
    [registry : CompilerLoadDependencyCatalogRegistry
      (owned_view.compiler-owned-shared-view state.dependency-catalog)]
    [items : CompilerLoadDependencyCatalogList
      (owned_view.compiler-owned-array-element-shared-view registry.entries 0)]
    [owner : i64 (array-ref registry.owner-arena 0)]
    [error : String (compiler-load-dependency-catalog-release-from! items 0 "")]
    (compiler-load-session-state-dependency-surfaces-release! state)
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
    (if (= (string.string-length error) 0)
      Ok
      (Err error))))

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
    (while (< index items.len)
      (let
        [entry : CompilerLoadDependencyCatalogEntry
          (owned_view.compiler-owned-array-element-shared-view
            items.slots
            index)]
        [root : String entry.key.canonical-root]
        [root-len : i64 (string.string-length root)]
        (when
          (and
            (> root-len best-len)
            (or
              (string.eq path root)
              (compiler-load-path-under-root? path root)))
          (set! best index)
          (set! best-len root-len))
        (set! index (+ index 1))))
    best))

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
      NoCatalog
      (let
        [entry : CompilerLoadDependencyCatalogEntry
          (owned_view.compiler-owned-array-element-shared-view items.slots slot)]
        (match entry.status
          [(Unavailable failure) (Unavailable failure)]
          [(TrustedMetadataOnly) MetadataOnly]
          [(TrustedCode loaded)
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
                [(Resolved resolved)
                  (Resolved
                    (CompilerLoadDependencyCatalogCapability
                      handle
                      slot
                      entry.key
                      generation
                      package-name-id
                      package-version-id
                      artifact-path-id
                      resolved))]
                [(Shell resolved)
                  (Shell
                    (CompilerLoadDependencyCatalogCapability
                      handle
                      slot
                      entry.key
                      generation
                      package-name-id
                      package-version-id
                      artifact-path-id
                      resolved))]
                [(Missing) Missing]
                [(Err message) (Unavailable (MappingFailure message))]))])))))

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
          (compiler-load-dependency-catalog-key-eq? entry.key capability.key))))))

;; Revalidate the complete registry capability immediately before entering
;; mapped code. No loaded-image value crosses this API boundary.
(define (compiler-load-dependency-catalog-capability-dispatch
  [capability : CompilerLoadDependencyCatalogCapability]
  [identity : String]
  [session-cookie : i64]) : tlci_loader_support.ResultTlciMacroDispatch
  (if (not
    (compiler-load-dependency-catalog-capability-current?
      (compiler-load-global-shared-view capability)))
    (Err
      (compiler-load-dependency-catalog-capability-error
        capability
        identity
        "selected catalog capability is stale"))
    (let
      [items : CompilerLoadDependencyCatalogList
        (compiler-load-dependency-catalog-handle-items capability.handle)]
      [entry : CompilerLoadDependencyCatalogEntry
        (owned_view.compiler-owned-array-element-shared-view
          items.slots
          capability.slot)]
      (match entry.status
        [(TrustedCode loaded)
          (match (tlci_loader_support.tlci-loader-dispatch-resolved-macro
            (& loaded)
            capability.resolved
            session-cookie
            (__tl_make-array i64 0)
            0)
            [(Ok dispatch) (Ok dispatch)]
            [(Err message)
              (Err
                (compiler-load-dependency-catalog-capability-error
                  capability
                  identity
                  message))])]
        [_
          (Err
            (compiler-load-dependency-catalog-capability-error
              capability
              identity
              "selected catalog is no longer executable"))]))))

(define (compiler-load-dependency-catalog-capability-mark-shell!
  [capability : CompilerLoadDependencyCatalogCapability]
  [identity : String]) : tlci_loader_support.ResultTlciLoaderUnit
  (if (not
    (compiler-load-dependency-catalog-capability-current?
      (compiler-load-global-shared-view capability)))
    (Err
      (compiler-load-dependency-catalog-capability-error
        capability
        identity
        "selected catalog capability is stale"))
    (let
      [items : CompilerLoadDependencyCatalogList
        (compiler-load-dependency-catalog-handle-items capability.handle)]
      [entry : CompilerLoadDependencyCatalogEntry
        (owned_view.compiler-owned-array-element-shared-view
          items.slots
          capability.slot)]
      (match entry.status
        [(TrustedCode loaded)
          (match (tlci_loader_support.tlci-loader-mark-macro-entry-shell!
            (& loaded)
            capability.resolved)
            [(Ok) Ok]
            [(Err message)
              (Err
                (compiler-load-dependency-catalog-capability-error
                  capability
                  identity
                  message))])]
        [_
          (Err
            (compiler-load-dependency-catalog-capability-error
              capability
              identity
              "selected catalog is no longer executable"))]))))

(define (compiler-load-dependency-catalog-admitted-image
  [state : (& state CompilerLoadSessionState)]
  [slot : i64]) : CompilerLoadDependencyCatalogAdmittedImage
  (let
    [items : CompilerLoadDependencyCatalogList
      (owned_view.compiler-owned-array-element-shared-view
        state.dependency-catalog.entries
        0)]
    (if (or (< slot 0) (>= slot items.len))
      NoCatalog
      (let
        [entry : CompilerLoadDependencyCatalogEntry
          (owned_view.compiler-owned-array-element-shared-view items.slots slot)]
        (match entry.status
          [(Unavailable failure) (Unavailable failure)]
          [(TrustedMetadataOnly)
            (match entry.image
              [(Some image) (TrustedMetadataOnly image)]
              [(None)
                (Unavailable
                  (Malformed
                    "dependency catalog: trusted metadata entry has no image"))])]
          [(TrustedCode loaded)
            (match entry.image
              [(Some image) (TrustedCode image loaded)]
              [(None)
                (Unavailable
                  (Malformed
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
      (match (owned_view.compiler-owned-array-element-shared-view
        surfaces.slots
        index)
        [(Ready hydration _)
          (let
            [pools : ast.AstNodePoolContext hydration.ast.pools]
            [base-arena : i64 (ast.ast-node-pool-context-base-arena pools)]
            (ast.ast-node-pool-context-destroy-storage! pools)
            (unsafe
              (arena.tl_arena_destroy base-arena)))]
        [(Unavailable) unit])
      (set! index (+ index 1)))))

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
        (Some (surface_facts.surface-typecheck-facts-current))
        None)]
    [base-builder : surface_facts.SurfaceTypecheckFactsBuilder
      (match (owned_view.compiler-owned-shared-view base-facts)
        [(None) (surface_facts.surface-typecheck-facts-builder-empty)]
        [(Some facts)
          (match (surface_facts.surface-typecheck-facts-builder-append
            (surface_facts.surface-typecheck-facts-builder-empty)
            facts)
            [(Ok next) next]
            [(Err _) (surface_facts.surface-typecheck-facts-builder-empty)])])]
    [index : i64 0]
    (while (< index fragments.len)
      (set! (array-ref fragments.imported index) false)
      (set! index (+ index 1)))
    (set! (array-ref surface-state.base-facts 0) base-facts)
    (set! (array-ref surface-state.facts-builder 0) base-builder)
    (set! (array-ref surface-state.surface-decl-count 0) 0)
    (set! (array-ref surface-state.surface-provenance-count 0) 0)
    (set! (array-ref surface-state.hit-count 0) 0)
    (set! (array-ref surface-state.macro-skip-count 0) 0)
    (set! (array-ref surface-state.typecheck-skip-count 0) 0)
    (if (surface_facts.surface-typecheck-facts-composite-active?)
      (surface_facts.surface-typecheck-facts-clear!)
      unit)))

(define (compiler-load-dependency-surface-key-current?
  [catalog-key : CompilerLoadDependencyCatalogKey]
  [surface-key : (& surface-key surface_identity.SurfaceIdentityKey)]
  [configuration : (& configuration str)]) : bool
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
      [(ExactMatch) true]
      [_ false])))

(define (compiler-load-dependency-surface-copy-specializations
  [source : tlci.TlciSpmdSpecializations]) : tlci.TlciSpmdSpecializations
  (let
    [count : i64 (tlci.tlci-spmd-specializations-len source)]
    [out : tlci.TlciSpmdSpecializations
      (tlci.tlci-spmd-specializations-with-capacity count)]
    [index : i64 0]
    (while (< index count)
      (let
        [item : tlci.TlciSpmdSpecialization
          (tlci.tlci-spmd-specializations-ref source index)]
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
        (set! index (+ index 1))))
    out))

(define (compiler-load-dependency-surface-copy-spmd-callables
  [source : (& source tlci.TlciSpmdCallables)]) : tlci.TlciSpmdCallables
  (let
    [count : i64 (tlci.tlci-spmd-callables-len source)]
    [out : tlci.TlciSpmdCallables
      (tlci.tlci-spmd-callables-with-capacity count)]
    [index : i64 0]
    (while (< index count)
      (let
        [item : tlci.TlciSpmdCallable
          (tlci.tlci-spmd-callables-ref source index)]
        (tlci.tlci-spmd-callables-push!
          (&mut out)
          (tlci.TlciSpmdCallable
            (string.copy (& item.name))
            (string.copy (& item.signature))
            (compiler-load-dependency-surface-copy-specializations
              item.specializations)))
        (set! index (+ index 1))))
    out))

(define (compiler-load-dependency-surface-hydrate-entry
  [_owner : i64]
  [entry : CompilerLoadDependencyCatalogEntry]
  [configuration : (& configuration str)]
  [structural-session : cis.InternStructuralSessionHandle]) : CompilerLoadDependencySurfaceFragment
  (match entry.status
    [(Unavailable _) Unavailable]
    [_
      (match entry.image
        [(None) Unavailable]
        [(Some image)
          (match (surface_hydrate.compiler-surface-key
            (owned_view.compiler-owned-shared-view image.rodata))
            [(Missing) Unavailable]
            [(Err _) Unavailable]
            [(Ok key)
              (if (not
                (compiler-load-dependency-surface-key-current?
                  entry.key
                  key
                  configuration))
                Unavailable
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
                      (arena.Arena (ast.ast-node-pool-context-base-arena pools))
                      (compiler-load-dependency-surface-copy-spmd-callables
                        entry.spmd-callables))]
                  [hydrated : surface_hydrate.ResultCompilerSurfaceHydration
                    (in-arena
                      (arena.Arena (ast.ast-node-pool-context-base-arena pools))
                      (surface_hydrate.compiler-surface-hydrate
                        image.rodata
                        key
                        structural-session
                        pools))]
                  (match hydrated
                    [(Ok hydration) (Ready hydration spmd-callables)]
                    [_
                      (let
                        [base-arena : i64
                          (ast.ast-node-pool-context-base-arena pools)]
                        (ast.ast-node-pool-context-destroy-storage! pools)
                        (unsafe
                          (arena.tl_arena_destroy base-arena))
                        Unavailable)])))])])]))

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
  [configuration : (& configuration str)]) : bool
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
        (while (< index catalog.len)
          (let
            [fragment : CompilerLoadDependencySurfaceFragment
              (if (and
                verify-reject-last
                (> catalog.len 1)
                (= index (- catalog.len 1)))
                Unavailable
                (compiler-load-dependency-surface-hydrate-entry
                  owner
                  (owned_view.compiler-owned-array-element-shared-view
                    catalog.slots
                    index)
                  configuration
                  structural-session))]
            (set! (array-ref slots index) fragment)
            (match fragment
              [(Unavailable) (set! ok false)]
              [(Ready hydration _)
                (match (surface_facts.surface-typecheck-facts-builder-append
                  (owned_view.compiler-owned-shared-view preflight-facts)
                  hydration.facts)
                  [(Err _) (set! ok false)]
                  [(Ok next) (set! preflight-facts next)])])
            (set! index (+ index 1))))
        (set!
          (array-ref surface-state.fragments 0)
          (CompilerLoadDependencySurfaceList slots imported catalog.len))
        (set!
          (array-ref surface-state.intern-generation 0)
          (ci.intern-generation))
        (set!
          (array-ref surface-state.configuration 0)
          (string.copy configuration))
        (set! (array-ref surface-state.prepared 0) true)
        (set! (array-ref surface-state.enabled 0) ok)
        (if ok
          unit
          (set!
            (array-ref surface-state.fallback-count 0)
            (+ (array-ref surface-state.fallback-count 0) 1)))
        ok))))

(define (compiler-load-dependency-surfaces-prepare!
  [state : CompilerLoadSessionState]
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]) : bool
  (let
    [surface-state : CompilerLoadDependencySurfaceState
      (owned_view.compiler-owned-shared-view state.dependency-surfaces)]
    [configuration : String
      (compiler-load-dependency-surface-configuration cfgs)]
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
        (= (array-ref surface-state.intern-generation 0) (ci.intern-generation))
        (string.eq (array-ref surface-state.configuration 0) configuration)
        (=
          (array-ref surface-state.fragments 0).len
          (array-ref state.dependency-catalog.entries 0).len))
        (array-ref surface-state.enabled 0)
        (compiler-load-dependency-surfaces-build-cache! state configuration)))))

(define (compiler-load-dependency-catalog-observe
  [state : (& state CompilerLoadSessionState)]) : CompilerLoadDependencyCatalogObservation
  (let
    [state : CompilerLoadSessionState
      (owned_view.compiler-owned-reference-shared-view state)]
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
    (while (< index items.len)
      (match (compiler-load-dependency-catalog-admitted-image state index)
        [(NoCatalog) unit]
        [(Unavailable _) (set! unavailable (+ unavailable 1))]
        [(TrustedMetadataOnly image)
          (set! metadata-only (+ metadata-only 1))
          (set! code-bytes (+ code-bytes (array-length image.code)))
          (set! fixup-bytes (+ fixup-bytes (array-length image.fixups)))
          (set! entry-bytes (+ entry-bytes (array-length image.entries)))
          (set! import-bytes (+ import-bytes (array-length image.imports)))]
        [(TrustedCode image _)
          (set! trusted-code (+ trusted-code 1))
          (set! code-bytes (+ code-bytes (array-length image.code)))
          (set! fixup-bytes (+ fixup-bytes (array-length image.fixups)))
          (set! entry-bytes (+ entry-bytes (array-length image.entries)))
          (set! import-bytes (+ import-bytes (array-length image.imports)))])
      (set! index (+ index 1)))
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
      (array-ref state.dependency-surfaces.typecheck-skip-count 0))))

(define compiler-load-default-session-state : (__tl_dyn-array
    CompilerLoadSessionState)
  (__tl_make-array (compiler-load-standalone-session-state-new)))

;; Install the process-lifetime compatibility default session. Only this module
;; writes its globals; test harnesses swap the default through this function.
(define (compiler-load-default-session-state-set!
  [state : CompilerLoadSessionState]) : unit
  (set! (array-ref compiler-load-default-session-state 0) state))

;; Serial/test compatibility selector. Production call sites are migrated to
;; explicit state APIs incrementally; do not add new compile-job dependencies.
(define compiler-load-active-session-state : CompilerLoadSessionState
  (compiler-load-standalone-session-state-new))

;; Serial compatibility adapters intentionally share this process-lifetime
;; state through a visibly unsafe shallow read.
(define (compiler-load-active-session-state-shared-view) : CompilerLoadSessionState
  (unsafe
    (ptr-read (ptr-addr-of compiler-load-active-session-state))))

(define (compiler-load-session-state-shared-view
  [state : (& state CompilerLoadSessionState)]) : CompilerLoadSessionState
  (unsafe
    (ptr-read (int->ptr state.shared-address : (Ptr CompilerLoadSessionState)))))

;; Serial/test compatibility accessor. Production jobs pass their owned state
;; directly; adapters that cannot yet own a job context use this accessor so
;; stateful compiler modules do not depend on the selector variable itself.
(define (compiler-load-serial-test-session-state) : CompilerLoadSessionState
  (compiler-load-active-session-state-shared-view))

;; Source provider (#7455). Installing one makes every source read of the
;; session answer admitted overlay entries from the overlay and record each
;; consumed source in the provider's ledger; finishing hands the ledger back.
(define (compiler-load-session-state-source-provider
  [state : (& state CompilerLoadSessionState)]) : CompilerLoadSourceProvider
  (compiler-load-global-array-element-shared-view state.source-provider 0))

(define (compiler-load-session-state-source-provider-active?
  [state : (& state CompilerLoadSessionState)]) : bool
  (let
    [provider : CompilerLoadSourceProvider
      (compiler-load-session-state-source-provider state)]
    provider.active))

;; Start answering `state`'s source reads from `overlay`. The ledger allocates
;; in the caller's current arena, which must outlive the provider.
(define (compiler-load-session-state-source-provider-install!
  [state : CompilerLoadSessionState]
  [overlay : source_overlay.CompilerSourceOverlay]) : unit
  (let
    [ledger : source_overlay.CompilerSourceLedger
      (source_overlay.compiler-source-ledger-new overlay.limits)]
    (set!
      (array-ref state.source-provider 0)
      (CompilerLoadSourceProvider true overlay ledger (arena.tl_arena_current)))))

;; Stop the provider and return its ledger.
(define (compiler-load-session-state-source-provider-finish!
  [state : CompilerLoadSessionState]) : source_overlay.CompilerSourceLedger
  (let
    [provider : CompilerLoadSourceProvider
      (compiler-load-session-state-source-provider (& state))]
    (in-arena
      (arena.Arena state.owner-arena)
      (set!
        (array-ref state.source-provider 0)
        (compiler-load-source-provider-inactive)))
    provider.ledger))

;; Record one consumed source whose content identity is already known.
(define (compiler-load-session-state-source-record!
  [state : CompilerLoadSessionState]
  [class : source_overlay.CompilerSourceClass]
  [canonical : (& canonical str)]
  [path : (& path str)]
  [content : source_overlay.CompilerSourceContent]) : unit
  (let
    [provider : CompilerLoadSourceProvider
      (compiler-load-session-state-source-provider (& state))]
    (if provider.active
      (in-arena
        (arena.Arena provider.owner-arena)
        (source_overlay.compiler-source-ledger-record!
          (&mut provider.ledger)
          class
          canonical
          path
          (source_overlay.compiler-source-content-copy (& content)))
        (set! (array-ref state.source-provider 0) provider))
      unit)))

;; Record `text` as consumed from `path` under `class` and `canonical`.
(define (compiler-load-session-state-source-note!
  [state : CompilerLoadSessionState]
  [class : source_overlay.CompilerSourceClass]
  [canonical : (& canonical str)]
  [path : (& path str)]
  [text : (& text str)]) : unit
  (let
    [provider : CompilerLoadSourceProvider
      (compiler-load-session-state-source-provider (& state))]
    (if provider.active
      (in-arena
        (arena.Arena provider.owner-arena)
        (source_overlay.compiler-source-ledger-record-text!
          (&mut provider.ledger)
          class
          canonical
          path
          text)
        (set! (array-ref state.source-provider 0) provider))
      unit)))

(define (compiler-load-source-provider-canonical-path
  [provider : (& provider CompilerLoadSourceProvider)]
  [path : (& path str)]) : String
  (source_overlay.compiler-source-canonical-path (& provider.overlay.cwd) path))

;; Every source file a load session consumes is read here: the admitted
;; overlay entry for its canonical path when a provider is active, else the
;; file itself. Resolution has already chosen `path`, so an overlay can change a
;; source's bytes but not which file an import names.
(define (compiler-load-session-state-read-source-text
  [state : CompilerLoadSessionState]
  [path : (& path str)]) : String
  (let
    [provider : CompilerLoadSourceProvider
      (compiler-load-session-state-source-provider (& state))]
    (if (not provider.active)
      (compiler-load-read-file-text path)
      (let
        [canonical : String
          (compiler-load-source-provider-canonical-path (& provider) path)]
        [index : i64
          (source_overlay.compiler-source-overlay-find
            (& provider.overlay)
            (& canonical))]
        (if (< index 0)
          (let
            [text : String (compiler-load-read-file-text path)]
            (compiler-load-session-state-source-note!
              state
              (Disk)
              (& canonical)
              path
              (& text))
            text)
          (begin
            (compiler-load-session-state-source-record!
              state
              (Overlay)
              (& canonical)
              path
              (source_overlay.compiler-source-overlay-entry-content
                (& provider.overlay)
                index))
            (source_overlay.compiler-source-overlay-entry-bytes
              (& provider.overlay)
              index)))))))

(define (compiler-load-session-source-provider-active?) : bool
  (let
    [state : CompilerLoadSessionState
      (compiler-load-active-session-state-shared-view)]
    (compiler-load-session-state-source-provider-active? state)))

(define (compiler-load-session-read-source-text [path : (& path str)]) : String
  (compiler-load-session-state-read-source-text
    (compiler-load-active-session-state-shared-view)
    path))

;; Read an input other than a source that still decides what the check sees,
;; such as a dependency's TLCI image. An active provider records it from disk.
(define (compiler-load-session-try-read-input-text [path : (& path str)]) : io.ResultIoString
  (let
    [text (try (compiler-load-try-read-file-text path))]
    [state : CompilerLoadSessionState
      (compiler-load-active-session-state-shared-view)]
    [provider : CompilerLoadSourceProvider
      (compiler-load-session-state-source-provider (& state))]
    (if provider.active
      (let
        [canonical : String
          (compiler-load-source-provider-canonical-path (& provider) path)]
        (compiler-load-session-state-source-note!
          state
          (Disk)
          (& canonical)
          path
          (& text)))
      unit)
    (OkIoString text)))

;; Record an embedded stdlib source the session parsed. Embedded sources are no
;; file, so their identity is `embedded:` and the stdlib path.
(define (compiler-load-session-state-note-embedded-source!
  [state : CompilerLoadSessionState]
  [path : (& path str)]
  [text : (& text str)]) : unit
  (if (compiler-load-session-state-source-provider-active? (& state))
    (let
      [canonical : String (str_cat.str-cat "embedded:" (string.copy path))]
      (compiler-load-session-state-source-note!
        state
        (Embedded)
        (& canonical)
        path
        text))
    unit))

;; Record the embedded stdlib source for `path` when a provider is active.
(define (compiler-load-session-state-note-embedded-path!
  [state : CompilerLoadSessionState]
  [path : (& path str)]) : unit
  (if (compiler-load-session-state-source-provider-active? (& state))
    (match (compiler-load-embedded-stdlib-source-for-path (string.copy path))
      [(CompilerEmbeddedStdlibSomeSource text)
        (compiler-load-session-state-note-embedded-source! state path (& text))]
      [(CompilerEmbeddedStdlibNoSource) unit])
    unit))

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

(define (compiler-load-session-state-program-cache-set-enabled-cell!
  [state : CompilerLoadSessionState]
  [enabled : bool]) : unit
  (compiler-load-session-state-bool-cell-set!
    state.program-cache-enabled
    enabled))

(define (compiler-load-session-state-program-cache-fill!
  [state : (& state CompilerLoadSessionState)]
  [index : i64]) : unit
  (unless
    (>= index compiler-load-program-cache-capacity)
    (set! (array-ref state.program-cache index) (CompilerLoadProgramCacheEmpty))
    (compiler-load-session-state-program-cache-fill! state (+ index 1))))

(define (compiler-load-session-state-program-cache-stats-reset!
  [state : CompilerLoadSessionState]) : unit
  (set! (array-ref state.program-cache-hit-count 0) 0)
  (set! (array-ref state.program-cache-miss-count 0) 0)
  (set! (array-ref state.program-cache-store-count 0) 0))

(define (compiler-load-session-state-program-cache-clear!
  [state : CompilerLoadSessionState]) : unit
  (compiler-load-session-state-program-cache-fill! state 0)
  (set! (array-ref state.program-cache-ready 0) true)
  (compiler-load-session-state-program-admission-clear! state)
  (compiler-load-session-state-program-cache-stats-reset! state))

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

(define (compiler-load-session-state-program-cache-miss-count-value
  [state : (& state CompilerLoadSessionState)]) : i64
  (array-ref state.program-cache-miss-count 0))

(define (compiler-load-session-state-program-cache-store-count-value
  [state : (& state CompilerLoadSessionState)]) : i64
  (array-ref state.program-cache-store-count 0))

(define (compiler-load-cfg-key-equal?
  [left : (& left sym_i64_env.SymI64Env)]
  [right : (& right sym_i64_env.SymI64Env)]) : bool
  (match (sym_i64_env.sym-i64-view (sym_i64_env.sym-i64-shared-view left))
    [(SymI64ViewNil)
      (match (sym_i64_env.sym-i64-view (sym_i64_env.sym-i64-shared-view right))
        [(SymI64ViewNil) true]
        [(SymI64ViewBind _ _ _) false])]
    [(SymI64ViewBind left-key left-value left-rest)
      (match (sym_i64_env.sym-i64-view (sym_i64_env.sym-i64-shared-view right))
        [(SymI64ViewNil) false]
        [(SymI64ViewBind right-key right-value right-rest)
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
    [(SymI64ViewNil) (sym_i64_env.sym-i64-empty)]
    [(SymI64ViewBind key value rest)
      (sym_i64_env.sym-i64-bind-id (compiler-load-cfg-key-copy rest) key value)]))

(define (compiler-load-program-cache-key-copy
  [key : (& key CompilerLoadProgramCacheKey)]) : CompilerLoadProgramCacheKey
  (CompilerLoadProgramCacheKey
    (clone key.kind)
    key.path-id
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
  (compiler-load-session-state-program-cache-ensure!
    (owned_view.compiler-owned-shared-view state))
  (compiler-load-session-state-program-cache-lookup-from state key 0))

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
        (set!
          (array-ref state.program-cache index)
          (CompilerLoadProgramCacheFull key program))
        (compiler-load-session-state-program-cache-note-store! state)
        true]
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
  (compiler-load-session-state-program-cache-ensure!
    (owned_view.compiler-owned-shared-view state))
  (compiler-load-session-state-program-cache-store-at state key program 0))

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
  (compiler-load-session-state-program-cache-ensure!
    (owned_view.compiler-owned-shared-view state))
  (compiler-load-session-state-program-cache-can-store-at state key 0))

(define (compiler-load-program-cache-can-store
  [key : (& key CompilerLoadProgramCacheKey)]) : bool
  (compiler-load-session-state-program-cache-can-store
    (compiler-load-active-session-state-shared-view)
    key))

(define (compiler-load-session-state-program-admission-fill!
  [state : (& state CompilerLoadSessionState)]
  [index : i64]) : unit
  (unless
    (>= index compiler-load-program-cache-capacity)
    (set!
      (array-ref state.program-admission index)
      (CompilerLoadProgramAdmissionEmpty))
    (compiler-load-session-state-program-admission-fill! state (+ index 1))))

(define (compiler-load-session-state-program-admission-clear!
  [state : (& state CompilerLoadSessionState)]) : unit
  (compiler-load-session-state-program-admission-fill! state 0)
  (set! (array-ref state.program-admission-ready 0) true))

(define (compiler-load-session-state-program-admission-ensure!
  [state : (& state CompilerLoadSessionState)]) : unit
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
  (compiler-load-session-state-program-admission-ensure! state)
  (compiler-load-session-state-program-admission-contains-from? state key 0))

(define (compiler-load-program-admission-contains?
  [key : CompilerLoadProgramCacheKey]) : bool
  (compiler-load-session-state-program-admission-contains?
    (compiler-load-active-session-state-shared-view)
    key))

(define (compiler-load-session-state-program-admission-record-at
  [state : (& state CompilerLoadSessionState)]
  [key : CompilerLoadProgramCacheKey]
  [index : i64]) : bool
  (if (>= index compiler-load-program-cache-capacity)
    false
    (match (clone (array-ref state.program-admission index))
      [(CompilerLoadProgramAdmissionEmpty)
        (set!
          (array-ref state.program-admission index)
          (CompilerLoadProgramAdmissionFull key))
        true]
      [(CompilerLoadProgramAdmissionFull slot-key)
        (if (compiler-load-program-cache-key-equal? slot-key key)
          true
          (compiler-load-session-state-program-admission-record-at
            state
            key
            (+ index 1)))])))

(define (compiler-load-session-state-program-admission-record
  [state : (& state CompilerLoadSessionState)]
  [key : CompilerLoadProgramCacheKey]) : bool
  (compiler-load-session-state-program-admission-ensure! state)
  (compiler-load-session-state-program-admission-record-at state key 0))

(define (compiler-load-session-state-program-admission-record-persistent
  [state : CompilerLoadSessionState]
  [key : CompilerLoadProgramCacheKey]) : bool
  (if (compiler-load-session-state-program-admission-contains?
    (owned_view.compiler-owned-shared-view state)
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
      (when
        (> new-intern-floor old-intern-floor)
        (ci.intern-compat-state-persistent-arena-floor-refresh! interns)
        (set! (array-ref state.intern-floor 0) new-intern-floor)))
    (let
      [new-intern-floor : i64 (ci.intern-pool-len)]
      (when
        (> new-intern-floor old-intern-floor)
        (ci.intern-persistent-arena-floor-refresh!)
        (set! (array-ref state.intern-floor 0) new-intern-floor)))))

(define (compiler-load-session-state-note-persistent!
  [state : CompilerLoadSessionState]) : unit
  (if (>
    (ast.ast-node-pool-len)
    (compiler-load-session-state-ast-floor-value state))
    (begin
      (set! (array-ref state.ast-floor 0) (ast.ast-node-pool-len))
      (ast.ast-node-protected-floor-set! (ast.ast-node-pool-len)))
    unit)
  (if (>
    (ast.ty-node-pool-len)
    (compiler-load-session-state-ty-floor-value state))
    (set! (array-ref state.ty-floor 0) (ast.ty-node-pool-len))
    unit)
  (compiler-load-session-state-intern-floor-refresh!
    (owned_view.compiler-owned-shared-view state)
    (compiler-load-session-state-intern-floor-value state)))

(define (compiler-load-session-note-persistent!) : unit
  (compiler-load-session-state-note-persistent!
    (compiler-load-active-session-state-shared-view)))

(define (compiler-load-session-state-note-persistent-interns!
  [state : CompilerLoadSessionState]) : unit
  (compiler-load-session-state-intern-floor-refresh!
    (owned_view.compiler-owned-shared-view state)
    (compiler-load-session-state-intern-floor-value state)))

(define (compiler-load-session-state-note-persistent-with-pools!
  [state : CompilerLoadSessionState]
  [pools : ast.AstNodePoolContext]) : unit
  (if (>
    (ast.ast-node-pool-context-expr-len pools)
    (compiler-load-session-state-ast-floor-value state))
    (begin
      (set!
        (array-ref state.ast-floor 0)
        (ast.ast-node-pool-context-expr-len pools))
      (ast.ast-node-protected-floor-set!
        (ast.ast-node-pool-context-expr-len pools)))
    unit)
  (if (>
    (ast.ast-node-pool-context-type-len pools)
    (compiler-load-session-state-ty-floor-value state))
    (set!
      (array-ref state.ty-floor 0)
      (ast.ast-node-pool-context-type-len pools))
    unit)
  (compiler-load-session-state-intern-floor-refresh!
    (owned_view.compiler-owned-shared-view state)
    (compiler-load-session-state-intern-floor-value state)))

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
  (set! (array-ref state.ast-floor 0) ast-floor)
  (ast.ast-node-protected-floor-set! ast-floor)
  (set! (array-ref state.ty-floor 0) ty-floor)
  (set! (array-ref state.intern-floor 0) intern-floor))

(define (compiler-load-session-floors-set!
  [ast-floor : i64]
  [ty-floor : i64]
  [intern-floor : i64]) : unit
  (compiler-load-session-state-floors-set!
    (compiler-load-active-session-state-shared-view)
    ast-floor
    ty-floor
    intern-floor))

(define (compiler-load-session-state-use!
  [state : (& state CompilerLoadSessionState)]) : unit
  (let
    [state : CompilerLoadSessionState
      (owned_view.compiler-owned-reference-shared-view state)]
    (set! (array-ref state.intern-state-ready 0) false)
    (set! compiler-load-active-session-state state)))

;; Reinstall a displaced session exactly as it was saved, without touching its
;; intern-state flags. Only this module may write the active-session global.
(define (compiler-load-session-state-restore!
  [state : CompilerLoadSessionState]) : unit
  (set! compiler-load-active-session-state state))

(define (compiler-load-session-state-use-with-intern-state!
  [state : (& state CompilerLoadSessionState)]
  [intern-state : ci.InternCompatState]) : unit
  (let
    [state : CompilerLoadSessionState
      (owned_view.compiler-owned-reference-shared-view state)]
    (set! (array-ref state.intern-state 0) intern-state)
    (set! (array-ref state.intern-state-ready 0) true)
    (set! compiler-load-active-session-state state)))

;; Read the interner that defines this session's id domain. Production driver
;; sessions bind an explicit owner before load starts; the active-table capture
;; is retained only for standalone/test sessions created through the legacy
;; `compiler-load-session-state-use!` adapter.
(define (compiler-load-session-state-interns
  [state : (& state CompilerLoadSessionState)]) : ci.InternCompatState
  (if (array-ref state.intern-state-ready 0)
    (owned_view.compiler-owned-array-element-shared-view state.intern-state 0)
    (ci.intern-compat-state-capture-active)))

;; Intern into the table that gives this load session's id-keyed caches their
;; meaning. Explicit driver sessions never intern through a compatibility
;; table another job installed; standalone adapters retain the historical
;; active-table fallback until they bind an owner.
(define (compiler-load-session-state-intern
  [state : CompilerLoadSessionState]
  [name : String]) : i64
  (if (array-ref state.intern-state-ready 0)
    (let
      [interns : (&mut state ci.InternCompatState)
        (&mut (array-ref state.intern-state 0))]
      ;; The compatibility bridge keeps its active scalar cursor outside the
      ;; state record. While this session owns the installed table, that live
      ;; cursor is authoritative; recapture it after the insertion. A session
      ;; whose owner is not installed stays entirely explicit and cannot touch
      ;; an unrelated job's table.
      (if (=
        (ci.intern-active-table-id)
        (ci.intern-compat-state-table-id interns))
        (let
          [id : i64 (ci.intern name)]
          (ci.intern-compat-state-capture-from-globals! interns)
          id)
        (ci.intern-compat-state-intern interns (& name))))
    (ci.intern name)))

(define (compiler-load-session-cache-enable!) : unit
  (set!
    (array-ref
      (__tl-project-field compiler-load-active-session-state cache-enabled)
      0)
    true))

(define (compiler-load-session-state-program-cache-disable!
  [state : CompilerLoadSessionState]) : unit
  (compiler-load-session-state-program-cache-set-enabled-cell!
    (owned_view.compiler-owned-shared-view state)
    false)
  (set! (array-ref state.program-cache-ready 0) false)
  (set! (array-ref state.program-admission-ready 0) false)
  (set! (array-ref state.program-cache-hit-count 0) 0)
  (set! (array-ref state.program-cache-miss-count 0) 0)
  (set! (array-ref state.program-cache-store-count 0) 0))

(define (compiler-load-session-program-cache-disable!) : unit
  (set!
    (array-ref
      (__tl-project-field
        compiler-load-active-session-state
        program-cache-enabled)
      0)
    false)
  (compiler-load-program-cache-clear!))

(define (compiler-load-session-state-program-cache-enabled?
  [state : (& state CompilerLoadSessionState)]) : bool
  (array-ref state.program-cache-enabled 0))

(define (compiler-load-session-program-cache-enabled?) : bool
  (let
    [state : CompilerLoadSessionState
      (compiler-load-active-session-state-shared-view)]
    (compiler-load-session-state-program-cache-enabled? state)))

(define (compiler-load-session-program-cache-enable!) : unit
  (set!
    (array-ref
      (__tl-project-field
        compiler-load-active-session-state
        program-cache-enabled)
      0)
    true))

(define (compiler-load-session-cache-disable-for-test!) : unit
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
  (compiler-load-runtime-prelude-cache-clear!))

;; Retire every cache and floor owned by the active serial compiler session.
;; The replacement state is installed before the global pool/intern reset so
;; those resets cannot preserve the old session's floors. Callers must invoke
;; this while allocating in the arena that will outlive the retired session.
(define (compiler-load-session-fresh-reset!) : unit
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
  (compiler-load-runtime-prelude-cache-clear!))

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

;; Canonical ids of modules whose source matches the embedded stdlib payload.
;; The owning session's intern table gives these ids meaning: embedded source
;; and disk source byte-identical to it once prepared as the payload prepares
;; it (inline tests blanked, #8713; prose comments cut, #8659) may use the
;; catalog, while modified or otherwise untrusted roots must expand from their
;; own source.
(define (compiler-load-session-state-provenance-arena-value
  [state : CompilerLoadSessionState]) : i64
  (if (array-ref state.intern-state-ready 0)
    (ci.intern-compat-state-persistent-arena-current-head
      (array-ref state.intern-state 0))
    (array-ref state.embedded-provenance-owner-arena 0)))

(define (compiler-load-session-state-embedded-provenance-arena
  [state : (& state CompilerLoadSessionState)]) : i64
  (if (array-ref state.intern-state-ready 0)
    (ci.intern-compat-state-persistent-arena-current-head
      (array-ref state.intern-state 0))
    (begin
      (if (= (array-ref state.embedded-provenance-owner-arena 0) 0)
        (set!
          (array-ref state.embedded-provenance-owner-arena 0)
          (arena.tl_arena_make_small))
        unit)
      (array-ref state.embedded-provenance-owner-arena 0))))

(define (compiler-load-session-state-embedded-module-ids-shared-view
  [state : CompilerLoadSessionState]) : sym_i64_env.SymI64Env
  (array-ref state.embedded-stdlib-provenance.module-ids 0))

(define (compiler-load-session-state-embedded-equivalence-cache-shared-view
  [state : CompilerLoadSessionState]) : sym_i64_env.SymI64Env
  (array-ref state.embedded-stdlib-provenance.equivalence-cache 0))

(define (compiler-load-session-state-embedded-provenance-noted?
  [state : CompilerLoadSessionState]) : bool
  (array-ref state.embedded-stdlib-provenance.noted 0))

(define (compiler-load-session-state-embedded-provenance-reset!
  [state : CompilerLoadSessionState]) : unit
  (set!
    (array-ref state.embedded-stdlib-provenance.module-ids 0)
    (sym_i64_env.sym-i64-empty))
  (set!
    (array-ref state.embedded-stdlib-provenance.equivalence-cache 0)
    (sym_i64_env.sym-i64-empty))
  (set!
    (array-ref state.embedded-stdlib-provenance.canonical-paths 0)
    (sym_i64_env.sym-i64-empty))
  (set!
    (array-ref state.embedded-stdlib-provenance.suffix-claims 0)
    (sym_i64_env.sym-i64-empty))
  (set! (array-ref state.embedded-stdlib-provenance.noted 0) false)
  (let
    [owner : i64 (array-ref state.embedded-provenance-owner-arena 0)]
    (set! (array-ref state.embedded-provenance-owner-arena 0) 0)
    (if (> owner 0)
      (unsafe
        (arena.tl_arena_destroy owner))
      unit)))

(define (compiler-load-session-state-note-embedded-module!
  [state : (& state CompilerLoadSessionState)]
  [path : String]) : unit
  (let
    [state : CompilerLoadSessionState
      (owned_view.compiler-owned-reference-shared-view state)]
    [source-path : String (string.copy (& path))]
    [id : i64
      (compiler-load-session-state-intern
        (owned_view.compiler-owned-shared-view state)
        (compiler-load-canonical-module-id-from-path path))]
    (compiler-load-session-state-note-embedded-path!
      (owned_view.compiler-owned-shared-view state)
      (& source-path))
    ;; The map head belongs to this session. Its nodes outlive load-scoped
    ;; scratch arenas and remain valid until the next session intern reset.
    (in-arena
      (arena.Arena
        (compiler-load-session-state-embedded-provenance-arena state))
      (set!
        (array-ref state.embedded-stdlib-provenance.module-ids 0)
        (sym_i64_env.sym-i64-bind-id
          (compiler-load-session-state-embedded-module-ids-shared-view state)
          id
          1)))))

(define (compiler-load-note-embedded-module! [path : String]) : unit
  (let
    [state (compiler-load-active-session-state-shared-view)]
    (compiler-load-session-state-note-embedded-module! state path)))

;: A stdlib module resolved from a root (or the working directory) whose
;: source, prepared as the payload prepares it (inline tests blanked, #8713;
;: prose comments cut, #8659), is byte-identical to the embedded payload's
;: copy carries embedded provenance for the macro route: the source-bound
;: catalog is exact for it by construction, since inline tests define nothing
;: outside `--cfg test` and comments define nothing, and any other user
;: modification breaks the equality and keeps that module on source
;: interpretation. Cached per suffix; the compare runs
;: once per module per session. Every call also notes the module's canonical
;: name identity, whether or not the source matches.
(define (compiler-load-session-state-note-embedded-equivalent-if-matching!
  [state : CompilerLoadSessionState]
  [suffix : String]
  [disk-path : String]) : unit
  (let
    [key : i64
      (compiler-load-session-state-intern
        (owned_view.compiler-owned-shared-view state)
        (string.copy suffix))]
    [_canonical : unit
      (compiler-load-session-state-note-stdlib-path!
        (owned_view.compiler-owned-shared-view state)
        key
        (string.copy suffix)
        (string.copy disk-path))]
    [cache : sym_i64_env.SymI64Env
      (compiler-load-session-state-embedded-equivalence-cache-shared-view
        (owned_view.compiler-owned-shared-view state))]
    (if (sym_i64_env.sym-i64-contains-id cache key)
      unit
      (let
        [outcome : i64
          (match (compiler-load-embedded-stdlib-source (string.copy suffix))
            [(CompilerEmbeddedStdlibSomeSource embedded-text)
              (let
                [disk-text : String (compiler-load-read-file-text disk-path)]
                (if (ces.compiler-embedded-stdlib-source-matches-blanked?
                  (& disk-text)
                  (& embedded-text))
                  1
                  -1))]
            [(CompilerEmbeddedStdlibNoSource) -1])]
        (in-arena
          (arena.Arena
            (compiler-load-session-state-embedded-provenance-arena state))
          (set!
            (array-ref state.embedded-stdlib-provenance.equivalence-cache 0)
            (sym_i64_env.sym-i64-bind-id
              (compiler-load-session-state-embedded-equivalence-cache-shared-view
                (owned_view.compiler-owned-shared-view state))
              key
              outcome)))
        (when
          (= outcome 1)
          (compiler-load-session-state-note-embedded-module!
            state
            (str_cat.str-cat "stdlib/" suffix))
          (set! (array-ref state.embedded-stdlib-provenance.noted 0) true))))))

;: Record that the stdlib module SUFFIX, interned as SUFFIX-ID, was read from
;: DISK-PATH. Every stdlib module resolution notes its module here, so the
;: name identity does not depend on how the root is spelled relative to the
;: cwd. A path already spelled `stdlib/<suffix>` is its own canonical form and
;: is not mapped, so the table stays empty unless a root lies elsewhere. A
;: suffix names one file per session: when a second file claims it, neither
;: file takes the shared name, and both keep their path-derived names.
(define (compiler-load-session-state-note-stdlib-path!
  [state : CompilerLoadSessionState]
  [suffix-id : i64]
  [suffix : String]
  [disk-path : String]) : unit
  (let
    [path : String (compiler-load-normalize-path (& disk-path))]
    [identity? : bool (string.eq path (str_cat.str-cat "stdlib/" suffix))]
    [path-id : i64
      (compiler-load-session-state-intern
        (owned_view.compiler-owned-shared-view state)
        path)]
    [claims : sym_i64_env.SymI64Env
      (array-ref state.embedded-stdlib-provenance.suffix-claims 0)]
    [paths : sym_i64_env.SymI64Env
      (array-ref state.embedded-stdlib-provenance.canonical-paths 0)]
    [claimant : i64 (sym_i64_env.sym-i64-lookup-id-or (& claims) suffix-id -1)]
    (in-arena
      (arena.Arena
        (compiler-load-session-state-embedded-provenance-arena state))
      (if (< claimant 0)
        (begin
          (set!
            (array-ref state.embedded-stdlib-provenance.suffix-claims 0)
            (sym_i64_env.sym-i64-bind-id claims suffix-id path-id))
          (if identity?
            unit
            (set!
              (array-ref state.embedded-stdlib-provenance.canonical-paths 0)
              (sym_i64_env.sym-i64-bind-id paths path-id suffix-id))))
        (if (or
          (= claimant path-id)
          (= (sym_i64_env.sym-i64-lookup-id-or (& paths) path-id 0) -1))
          unit
          (set!
            (array-ref state.embedded-stdlib-provenance.canonical-paths 0)
            (sym_i64_env.sym-i64-bind-id
              (sym_i64_env.sym-i64-bind-id paths claimant -1)
              path-id
              -1)))))))

;: The name identity of the module read from PATH: `stdlib/<suffix>` when a
;: stdlib root resolved it, else PATH itself. The path keeps naming the real
;: file everywhere else, for diagnostics and reads. The lookup does not intern.
;: Lowering asks once per declaration, so the table is read in place rather
;: than through a copy of the whole session. Ids are the active interner's;
;: the driver installs the session's own table as the active one.
(define (compiler-load-canonical-stdlib-path [path : String]) : String
  (let
    [paths : sym_i64_env.SymI64Env
      (array-ref
        (unsafe
          (ptr-read
            (ptr-addr-of
              compiler-load-active-session-state.embedded-stdlib-provenance.canonical-paths)))
        0)]
    (if (< paths.head 0)
      path
      (match (ci.intern-lookup (compiler-load-normalize-path (& path)))
        [(InternLookupFound path-id)
          (let
            [suffix-id : i64
              (sym_i64_env.sym-i64-lookup-id-or (& paths) path-id -1)]
            (if (< suffix-id 0)
              path
              (str_cat.str-cat "stdlib/" (ci.intern-str suffix-id))))]
        [(InternLookupMissing) path]))))

(define (compiler-load-note-embedded-equivalent-if-matching!
  [suffix : String]
  [disk-path : String]) : unit
  (compiler-load-session-state-note-embedded-equivalent-if-matching!
    (compiler-load-active-session-state-shared-view)
    suffix
    disk-path))

(define (compiler-load-session-note-embedded-stdlib-source!) : unit
  (compiler-load-session-state-note-embedded-stdlib-source!
    (compiler-load-active-session-state-shared-view)))

(define (compiler-load-session-reset-pools!) : unit
  (parser.compiler-parse-decl-origin-cache-reset!)
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
      ;; Cached programs below the floor go back to their parsed form (#8757).
      (ast.ast-node-protected-restore!)
      (ast.ast-node-pool-reset-to! (compiler-load-session-ast-floor-value))
      (ast.ty-node-pool-reset-to! (compiler-load-session-ty-floor-value)))
    (begin
      ;; Standalone sessions own no cached AST whose cold parse sidecars must
      ;; survive. Clear the spanned reader pool before their arena is retired,
      ;; matching compiler-load-session-state-reset-pools-with-pools! below.
      (reader.sp-node-pool-reset!)
      (ast.ast-node-protected-floor-set! 0)
      (ast.ast-node-pool-reset!)
      (ast.ty-node-pool-reset!))))

(define (compiler-load-session-state-reset-pools-with-pools!
  [state : CompilerLoadSessionState]
  [pools : ast.AstNodePoolContext]) : unit
  (parser.compiler-parse-decl-origin-cache-reset!)
  (compiler-load-session-state-surface-summaries-reset!
    (owned_view.compiler-owned-shared-view state))
  (compiler-load-session-state-lazy-qualified-observer-reset! state)
  (set! (array-ref state.surface-summary-load-depth 0) 0)
  (if (compiler-load-session-state-cache-enabled? state)
    (begin
      ;; Cached programs below the floor go back to their parsed form (#8757).
      (ast.ast-node-protected-restore!)
      (ast.ast-node-pool-context-reset-to!
        pools
        (compiler-load-session-state-ast-floor-value state)
        (compiler-load-session-state-ty-floor-value state)))
    (begin
      (reader.sp-node-pool-reset!)
      (ast.ast-node-protected-floor-set! 0)
      (ast.ast-node-pool-context-reset-to! pools 0 0))))

(define (compiler-load-session-reset-interns!) : unit
  (compiler-load-session-state-embedded-provenance-reset!
    (compiler-load-active-session-state-shared-view))
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
    (ci.intern-reset!)))

(define (compiler-load-session-state-reset-interns-with-state!
  [load-state : CompilerLoadSessionState]
  [intern-state : (&mut intern-state ci.InternCompatState)]) : unit
  (compiler-load-session-state-embedded-provenance-reset!
    (owned_view.compiler-owned-shared-view load-state))
  (compiler-load-session-state-surface-summaries-reset!
    (owned_view.compiler-owned-shared-view load-state))
  (compiler-load-session-state-lazy-qualified-observer-reset! load-state)
  (set! (array-ref load-state.surface-summary-load-depth 0) 0)
  (if (compiler-load-session-state-cache-enabled? load-state)
    (begin
      (ci.intern-compat-state-reset-to!
        intern-state
        (compiler-load-session-state-intern-floor-value load-state))
      (ci.intern-compat-state-persistent-arena-reset-to-floor! intern-state))
    (ci.intern-compat-state-reset! intern-state)))

(define (compiler-load-session-state-runtime-prelude-cache-fill!
  [state : (& state CompilerLoadSessionState)]
  [index : i64]) : unit
  (unless
    (>= index compiler-load-runtime-prelude-cache-capacity)
    (set!
      (array-ref state.runtime-prelude-cache index)
      (CompilerLoadPreludeCacheEmpty))
    (compiler-load-session-state-runtime-prelude-cache-fill! state (+ index 1))))

(define (compiler-load-session-state-runtime-prelude-cache-clear!
  [state : CompilerLoadSessionState]) : unit
  (compiler-load-session-state-runtime-prelude-cache-fill! state 0)
  (set! (array-ref state.runtime-prelude-cache-ready 0) true))

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
    (while (and same (< index count))
      (set! same (= (array-ref left.slots index) (array-ref right.slots index)))
      (set! index (+ index 1)))
    same))

;; The copy runs under whichever arena the caller made current, so the cached
;; key's ids land in the same long-lived arena the cons spine used to.
(define (compiler-load-intern-id-seq-copy [ids : CompilerLoadInternIdSeq]) : CompilerLoadInternIdSeq
  (let
    [count : i64 ids.len]
    [slots : (__tl_dyn-array i64) (__tl_make-array i64 count)]
    [index : i64 0]
    (while (< index count)
      (set! (array-ref slots index) (array-ref ids.slots index))
      (set! index (+ index 1)))
    (CompilerLoadInternIdSeq slots count)))

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
  (compiler-load-session-state-runtime-prelude-cache-ensure!
    (owned_view.compiler-owned-shared-view state))
  (compiler-load-session-state-runtime-prelude-cache-lookup-from state key 0))

(define (compiler-load-session-state-runtime-prelude-cache-store-at
  [state : (& state CompilerLoadSessionState)]
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
  (compiler-load-session-state-runtime-prelude-cache-ensure!
    (owned_view.compiler-owned-shared-view state))
  (compiler-load-session-state-runtime-prelude-cache-store-at
    state
    key
    decls
    paths
    modules
    seen
    0)
  (compiler-load-session-state-note-persistent! state))

(define (compiler-load-session-state-runtime-prelude-cache-store-with-pools
  [state : CompilerLoadSessionState]
  [key : CompilerLoadPreludeCacheKey]
  [decls : ast.AstDeclList]
  [paths : ast.AstDeclPathList]
  [modules : ast.AstDeclModuleList]
  [seen : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]) : unit
  (compiler-load-session-state-runtime-prelude-cache-ensure!
    (owned_view.compiler-owned-shared-view state))
  (compiler-load-session-state-runtime-prelude-cache-store-at
    state
    key
    decls
    paths
    modules
    seen
    0)
  (compiler-load-session-state-note-persistent-with-pools! state pools))

(define (compiler-load-root-cache-ids-from
  [roots : (& roots svec.Vec)]
  [index : i64]
  [count : i64]) : CompilerLoadInternIdSeq
  (let
    [len : i64
      (if (< index count)
        (- count index)
        0)]
    [slots : (__tl_dyn-array i64) (__tl_make-array i64 len)]
    [cursor : i64 0]
    (while (< cursor len)
      (let
        [root : String
          (compiler-load-normalize-path (svec.get roots (+ index cursor) ""))]
        (set! (array-ref slots cursor) (compiler-load-source-path-id root))
        (set! cursor (+ cursor 1))))
    (CompilerLoadInternIdSeq slots len)))

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
    [(SymI64ViewNil) out]
    [(SymI64ViewBind key value rest)
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
    (while (< i n)
      (if (compiler-load-path-separator? (string.string-ref path i))
        (set! last i)
        (set! last last))
      (set! i (+ i 1)))
    (if (< last 0)
      ""
      (string.substring path 0 (+ last 1)))))

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
          (while ok
            (if (< i prefix-len)
              (if (=
                (compiler-load-char-code-at text (+ start i))
                (compiler-load-char-code-at prefix i))
                (set! i (+ i 1))
                (set! ok false))
              (set! ok false)))
          (= i prefix-len))))))

(define (compiler-load-string-contains-from?
  [text : (& text str)]
  [needle : (& needle str)]
  [start : i64]) : bool
  (let
    [text-len : i64 (string.string-length text)]
    [needle-len : i64 (string.string-length needle)]
    [i : i64 start]
    [found : bool false]
    (while (and (not found) (<= (+ i needle-len) text-len))
      (if (compiler-load-string-prefix-at? text needle i)
        (set! found true)
        (set! i (+ i 1))))
    found))

(define (compiler-load-string-contains?
  [text : (& text str)]
  [needle : (& needle str)]) : bool
  (compiler-load-string-contains-from? text needle 0))

(define (compiler-load-lazy-env-disabled? [name : String]) : bool
  (match (env.get (& name))
    [(EnvSomeString value)
      (or
        (string.eq value "0")
        (string.eq value "false")
        (string.eq value "off"))]
    [(EnvNoString) false]))

(define (compiler-load-session-state-lazy-import-mode-enabled?
  [state : CompilerLoadSessionState]) : bool
  (array-ref state.cache-enabled 2))

(define (compiler-load-session-state-lazy-import-mode-set-enabled!
  [state : CompilerLoadSessionState]
  [enabled : bool]) : unit
  (set! (array-ref state.cache-enabled 2) enabled))

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
      (string.eq normalized "stdlib/runtime.tl")
      (string.eq normalized compiler-load-core-macro-prelude-path))))

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
    [next-roots : svec.Vec roots]
    (svec.push-ref! (&mut next-roots) root)
    next-roots))

(define (compiler-load-roots-with-env [roots : svec.Vec]) : svec.Vec
  (let
    [name : String "TYPELISP_STDLIB_ROOT"]
    (match (env.get (& name))
      [(EnvNoString) roots]
      [(EnvSomeString root)
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
  [_path : String]
  [_stdlib-roots : (& _stdlib-roots svec.Vec)]) : bool
  ;; Entry files opt out before this helper. Resolved import files are safe to
  ;; cache by path + cfg, including local and package-owned modules. Lexical
  ;; normalization always produces a non-empty spelling (`"."` for empty
  ;; input), so normalizing only to test the result length was vacuous.
  true)

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
      (while (and (not found) (< i n))
        (let
          [root : String (svec.get (& roots) i "")]
          [candidate : String
            (compiler-load-join-root-path root (string.copy suffix))]
          (if (io.file-exists? (string.copy candidate))
            (begin
              (set! found true)
              (set! found-path candidate))
            (set! i (+ i 1)))))
      (if found
        (CompilerLoadSomePath found-path)
        (CompilerLoadNoPath)))
    (CompilerLoadNoPath)))

(define (compiler-load-resolve-stdlib-root [suffix : String] [roots : svec.Vec]) : CompilerLoadMaybePath
  (compiler-load-resolve-stdlib-root-raw
    suffix
    (compiler-load-roots-with-env roots)))

(define (compiler-load-embedded-stdlib-source [suffix : String]) : ces.CompilerEmbeddedStdlibSource
  (if (compiler-load-safe-relative? suffix)
    (ces.compiler-embedded-stdlib-lookup suffix)
    (CompilerEmbeddedStdlibNoSource)))

(define (compiler-load-embedded-stdlib-path [suffix : String]) : CompilerLoadMaybePath
  (match (compiler-load-embedded-stdlib-source (string.copy suffix))
    [(CompilerEmbeddedStdlibSomeSource _)
      (CompilerLoadSomePath (str_cat.str-cat "stdlib/" suffix))]
    [(CompilerEmbeddedStdlibNoSource) (CompilerLoadNoPath)]))

(define (compiler-load-embedded-stdlib-source-for-path [path : String]) : ces.CompilerEmbeddedStdlibSource
  (if (compiler-load-stdlib-import? path)
    (compiler-load-embedded-stdlib-source (compiler-load-stdlib-suffix path))
    (CompilerEmbeddedStdlibNoSource)))

(define (compiler-load-resolve-import-with-roots
  [importer-path : String]
  [import-path : String]
  [stdlib-roots : svec.Vec]) : String
  (match (compiler-load-resolve-import-result-with-roots
    (string.copy importer-path)
    (string.copy import-path)
    (clone stdlib-roots))
    [(Ok resolved) resolved]
    [(Err _) import-path]))

(define (compiler-load-resolve-import-result-with-roots
  [importer-path : String]
  [import-path : String]
  [stdlib-roots : svec.Vec]) : ResultPkgResolve
  (if (compiler-load-pkg-import? (string.copy import-path))
    (compiler-load-resolve-pkg-import-from-disk importer-path import-path)
    (let
      [primary : String
        (compiler-load-join-import-path
          (string.copy importer-path)
          (string.copy import-path))]
      [resolved : String
        (if (io.file-exists? (string.copy primary))
          primary
          (if (compiler-load-stdlib-import? import-path)
            (let
              [suffix : String
                (compiler-load-stdlib-suffix (string.copy import-path))]
              (match (compiler-load-resolve-stdlib-root
                (string.copy suffix)
                stdlib-roots)
                [(CompilerLoadSomePath root-path) root-path]
                [(CompilerLoadNoPath)
                  (if (io.file-exists? (string.copy import-path))
                    import-path
                    (match (compiler-load-embedded-stdlib-path suffix)
                      [(CompilerLoadSomePath embedded-path) embedded-path]
                      [(CompilerLoadNoPath) primary]))]))
            primary))]
      (Ok (compiler-load-normalize-path resolved)))))

(define (compiler-load-session-state-dotted-path-cache-clear-ready!
  [state : (& state CompilerLoadSessionState)]
  [index : i64]) : unit
  (unless
    (>= index compiler-load-dotted-path-cache-capacity)
    (set! (array-ref state.dotted-path-cache-ready index) false)
    (set! (array-ref state.dotted-path-cache-values index) "")
    (compiler-load-session-state-dotted-path-cache-clear-ready!
      state
      (+ index 1))))

(define (compiler-load-session-state-dotted-path-arena-ensure!
  [state : (& state CompilerLoadSessionState)]) : i64
  (if (= (array-ref state.dotted-path-cache-owner-arena 0) 0)
    (set!
      (array-ref state.dotted-path-cache-owner-arena 0)
      (arena.tl_arena_make_small))
    unit)
  (array-ref state.dotted-path-cache-owner-arena 0))

(define (compiler-load-session-state-dotted-path-cache-reset!
  [state : CompilerLoadSessionState]) : unit
  (compiler-load-session-state-dotted-path-cache-clear-ready! state 0)
  (let
    [owner : i64 (array-ref state.dotted-path-cache-owner-arena 0)]
    (set! (array-ref state.dotted-path-cache-owner-arena 0) 0)
    (if (> owner 0)
      (unsafe
        (arena.tl_arena_destroy owner))
      unit))
  (set! (array-ref state.dotted-path-cache-generation 0) (ci.intern-generation)))

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
  [state : (& state CompilerLoadSessionState)]
  [module-id : i64]) : CompilerLoadMaybeString
  (let
    [bucket : i64 (compiler-load-dotted-path-cache-bucket module-id)]
    (if (if (array-ref state.dotted-path-cache-ready bucket)
      (= (array-ref state.dotted-path-cache-keys bucket) module-id)
      false)
      (CompilerLoadSomeString
        (string.copy (array-ref state.dotted-path-cache-values bucket)))
      (CompilerLoadNoString))))

(define (compiler-load-session-state-dotted-path-cache-store!
  [state : (& state CompilerLoadSessionState)]
  [module-id : i64]
  [path : String]) : unit
  (let
    [bucket : i64 (compiler-load-dotted-path-cache-bucket module-id)]
    (set! (array-ref state.dotted-path-cache-ready bucket) true)
    (set! (array-ref state.dotted-path-cache-keys bucket) module-id)
    (set! (array-ref state.dotted-path-cache-values bucket) path)))

(define (compiler-load-dotted-module-path-uncached [module-name : String]) : String
  (let
    [n : i64 (string.string-length module-name)]
    [i : i64 0]
    [out : String ""]
    (while (< i n)
      (if (string.char-eq (string.string-ref module-name i) '.')
        (set! out (str_cat.str-cat out "/" ""))
        (set! out (str_cat.str-cat out (string.substring module-name i 1) "")))
      (set! i (+ i 1)))
    (str_cat.str-cat out ".tl" "")))

(define (compiler-load-session-state-dotted-module-path-id
  [state : CompilerLoadSessionState]
  [module-id : i64]
  [module-name : String]) : String
  (compiler-load-session-state-dotted-path-cache-ensure!
    (owned_view.compiler-owned-shared-view state))
  (match (compiler-load-session-state-dotted-path-cache-lookup state module-id)
    [(CompilerLoadSomeString path) path]
    [(CompilerLoadNoString)
      ;; Cache payloads own a generation independent of caller scratch.
      ;; Both hit and miss paths copy results into the caller's arena before
      ;; a later cache generation can retire this private storage.
      (let
        [retained : String
          (in-arena
            (arena.Arena
              (compiler-load-session-state-dotted-path-arena-ensure! state))
            (let
              [path : String
                (compiler-load-dotted-module-path-uncached module-name)]
              (compiler-load-session-state-dotted-path-cache-store!
                state
                module-id
                (string.copy path))
              path))]
        (string.copy retained))]))

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
    [(Some module-id)
      (compiler-load-dotted-module-path-id module-id module-name)]
    [(No) (compiler-load-dotted-module-path-uncached module-name)]))

(define (compiler-load-dotted-module-first-len [module-name : String]) : i64
  (let
    [n : i64 (string.string-length module-name)]
    [i : i64 0]
    [done : bool false]
    (while (and (not done) (< i n))
      (if (string.char-eq (string.string-ref module-name i) '.')
        (set! done true)
        (set! i (+ i 1))))
    i))

(define (compiler-load-dotted-module-first [module-name : String]) : String
  (let
    [first-len : i64
      (compiler-load-dotted-module-first-len (string.copy module-name))]
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

(define (compiler-load-dotted-module-last-dot
  [module-name : (& module-name str)]) : i64
  (let
    [index : i64 (- (string.string-length module-name) 1)]
    [found : i64 -1]
    (while (and (< found 0) (>= index 0))
      (if (string.char-eq (string.string-ref module-name index) '.')
        (set! found index)
        (set! index (- index 1))))
    found))

(define (compiler-load-resolved-source-exists? [path : String]) : bool
  (or
    (io.file-exists? (owned_view.compiler-owned-shared-view path))
    (match (compiler-load-embedded-stdlib-source-for-path path)
      [(CompilerEmbeddedStdlibSomeSource _) true]
      [(CompilerEmbeddedStdlibNoSource) false])))

(define (compiler-load-import-module-id [module-name : (& module-name str)]) : i64
  (compiler-load-parse-context-name-id module-name))

(define (compiler-load-selected-item-id
  [expected-module : ast.AstMaybeModuleName]
  [fallback : String]) : i64
  (match expected-module
    [(Some full-import-id) (ci.intern-dotted-final-id full-import-id)]
    [(No) (compiler-load-import-module-id fallback)]))

(define (compiler-load-resolved-import
  [resolved : String]
  [kind : ast.AstImportKind]
  [module-name : String]
  [alias : ast.AstMaybeImportAlias]) : ResultCompilerLoadResolvedImport
  (let
    [module-id : i64 (compiler-load-import-module-id module-name)]
    (Ok
      (CompilerLoadResolvedImport
        resolved
        kind
        module-name
        (Some module-id)
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
    [suffix : String (compiler-load-stdlib-suffix (string.copy module-path))]
    (if (io.file-exists? (string.copy module-path))
      (begin
        (compiler-load-note-embedded-equivalent-if-matching!
          suffix
          (string.copy module-path))
        (string.copy module-path))
      (match (compiler-load-resolve-stdlib-root
        (string.copy suffix)
        stdlib-roots)
        [(CompilerLoadSomePath root-path)
          (compiler-load-note-embedded-equivalent-if-matching!
            suffix
            (string.copy root-path))
          root-path]
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
    (Ok (compiler-load-resolve-stdlib-module-path module-path stdlib-roots))
    (let
      [root-primary : String
        (compiler-load-normalize-path
          (compiler-load-join-root-path
            (string.copy import-root)
            (string.copy module-path)))]
      (if (compiler-load-nested-import-root? import-root)
        (if (io.file-exists? (string.copy root-primary))
          (Ok root-primary)
          (let
            [importer-dir : String (compiler-load-dirname importer-path)]
            [importer-primary : String
              (compiler-load-normalize-path
                (compiler-load-join-root-path
                  (string.copy importer-dir)
                  (string.copy module-path)))]
            (if (and
              (not (string.eq importer-dir import-root))
              (compiler-load-nested-import-root? importer-dir)
              (io.file-exists? (string.copy importer-primary)))
              (Ok importer-primary)
              (match (compiler-load-resolve-root-module-path
                module-path
                stdlib-roots)
                [(CompilerLoadSomePath root-path) (Ok root-path)]
                [(CompilerLoadNoPath) (Ok root-primary)]))))
        (match (compiler-load-resolve-root-module-path module-path stdlib-roots)
          [(CompilerLoadSomePath root-path) (Ok root-path)]
          [(CompilerLoadNoPath) (Ok root-primary)])))))

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
        (string.copy import-path)
        expected-module)]
    [first-len : i64
      (compiler-load-dotted-module-first-len (string.copy import-path))]
    [first : String (string.substring (string.copy import-path) 0 first-len)]
    [rest : String
      (compiler-load-dotted-module-rest (string.copy import-path) first-len)]
    (if (or
      (compiler-load-stdlib-import? (string.copy module-path))
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
      (match (compiler-load-discover-manifest (string.copy importer-path))
        [(CompilerLoadNoPath)
          (compiler-load-resolve-module-path-with-roots
            importer-path
            import-root
            module-path
            stdlib-roots)]
        [(CompilerLoadSomePath manifest-path)
          (match (compiler-load-parse-manifest-diagnostic
            (string.copy manifest-path)
            (compiler-load-session-read-source-text manifest-path))
            [(Err _)
              (compiler-load-resolve-module-path-with-roots
                importer-path
                import-root
                module-path
                stdlib-roots)]
            [(Ok manifest)
              (match (compiler-load-pkg-dep-lookup
                manifest.deps
                (string.copy first))
                [(CompilerLoadNoPath)
                  (compiler-load-resolve-module-path-with-roots
                    importer-path
                    import-root
                    module-path
                    stdlib-roots)]
                [(CompilerLoadSomePath dep-path)
                  (if (compiler-load-github-dependency-path?
                    (string.copy dep-path))
                    (Err
                      (str_cat.str-cat
                        "compiler-load: GitHub dependency '"
                        first
                        "' requires fetch support: "
                        import-path))
                    (Ok
                      (compiler-load-normalize-path
                        (compiler-load-join-root-path
                          (compiler-load-join-root-path
                            (compiler-load-dirname manifest-path)
                            dep-path)
                          (compiler-load-dotted-module-path-uncached rest)))))])])]))))

(define (compiler-load-resolve-package-module-import
  [module-name : String]
  [expected-module : ast.AstMaybeModuleName]
  [importer-path : String]
  [manifest-dir : String]
  [deps : CompilerPkgDeps]
  [stdlib-roots : svec.Vec]) : ResultPkgResolve
  (let
    [first-len : i64
      (compiler-load-dotted-module-first-len (string.copy module-name))]
    [first : String (string.substring module-name 0 first-len)]
    [module-path : String
      (compiler-load-dotted-module-path-from-ast
        (string.copy module-name)
        expected-module)]
    (if (compiler-load-stdlib-import? (string.copy module-path))
      (Ok (compiler-load-resolve-stdlib-module-path module-path stdlib-roots))
      (let
        [rest : String
          (compiler-load-dotted-module-rest (string.copy module-name) first-len)]
        [importer-dir : String (compiler-load-dirname importer-path)]
        [primary : String
          (compiler-load-normalize-path
            (compiler-load-join-root-path
              (string.copy importer-dir)
              (string.copy module-path)))]
        [fallback : String
          (compiler-load-normalize-path
            (compiler-load-join-root-path
              (string.copy manifest-dir)
              (string.copy module-path)))]
        (if (= (string.string-length rest) 0)
          ;; A bare single-segment import names a local module first; the
          ;; package alias only disambiguates nested paths.
          (if (and
            (compiler-load-nested-import-root? importer-dir)
            (io.file-exists? (string.copy primary)))
            (Ok primary)
            (if (io.file-exists? (string.copy fallback))
              (Ok fallback)
              (match (compiler-load-resolve-root-module-path
                module-path
                stdlib-roots)
                [(CompilerLoadSomePath root-path) (Ok root-path)]
                [(CompilerLoadNoPath)
                  (Err
                    (str_cat.str-cat
                      "compiler-load: dotted import missing module segment after package alias: "
                      module-name))])))
          (match (compiler-load-pkg-dep-lookup
            (ast.ast-place-shared-view deps)
            (string.copy first))
            [(CompilerLoadNoPath)
              (cond
                [(and
                    (compiler-load-nested-import-root? importer-dir)
                    (io.file-exists? (string.copy primary)))
                  (Ok primary)]
                [(io.file-exists? (string.copy fallback)) (Ok fallback)]
                [else
                  (match (compiler-load-resolve-root-module-path
                    (string.copy module-path)
                    stdlib-roots)
                    [(CompilerLoadSomePath root-path) (Ok root-path)]
                    [(CompilerLoadNoPath)
                      (if (= (compiler-pkg-deps-count deps) 0)
                        ;; A dotted alias with no declared dependencies and no
                        ;; local or root module is an unknown package alias;
                        ;; with a deps graph the name may be a vendored local
                        ;; source module.
                        (Err
                          (str_cat.str-cat
                            "compiler-load: unknown package alias '"
                            first
                            "': pkg:"
                            module-path))
                        (Ok fallback))])])]
            [(CompilerLoadSomePath dep-path)
              (if (compiler-load-github-dependency-path? (string.copy dep-path))
                (Err
                  (str_cat.str-cat
                    "compiler-load: GitHub dependency '"
                    first
                    "' requires fetch support: "
                    module-name))
                (Ok
                  (compiler-load-normalize-path
                    (compiler-load-join-root-path
                      (compiler-load-join-root-path manifest-dir dep-path)
                      (compiler-load-dotted-module-path-uncached rest)))))]))))))

(defenum CompilerLoadImportResolverMode
  (Ordinary String)
  (Package String CompilerPkgDeps))

(defstruct CompilerLoadImportResolver
  (importer-path String)
  (stdlib-roots svec.Vec)
  (mode CompilerLoadImportResolverMode))

(define (compiler-load-ordinary-import-resolver
  [importer-path : String]
  [import-root : String]
  [stdlib-roots : svec.Vec]) : CompilerLoadImportResolver
  (CompilerLoadImportResolver importer-path stdlib-roots (Ordinary import-root)))

(define (compiler-load-package-import-resolver
  [importer-path : String]
  [manifest-dir : String]
  [deps : CompilerPkgDeps]
  [stdlib-roots : svec.Vec]) : CompilerLoadImportResolver
  (CompilerLoadImportResolver
    importer-path
    stdlib-roots
    (Package manifest-dir deps)))

;; Resolve exactly one candidate module while keeping ordinary-root and
;; package/dependency path policy in explicit typed arms. Import grammar and
;; dotted selected-item fallback are shared below this boundary.
(define (compiler-load-resolve-import-candidate
  [resolver : CompilerLoadImportResolver]
  [module-name : String]
  [expected-module : ast.AstMaybeModuleName]) : ResultPkgResolve
  (match resolver.mode
    [(Ordinary import-root)
      (compiler-load-resolve-dotted-import-spec-with-roots
        resolver.importer-path
        import-root
        module-name
        expected-module
        resolver.stdlib-roots)]
    [(Package manifest-dir deps)
      (compiler-load-resolve-package-module-import
        module-name
        expected-module
        resolver.importer-path
        manifest-dir
        deps
        resolver.stdlib-roots)]))

(define (compiler-load-search-import-prefix
  [resolver : CompilerLoadImportResolver]
  [original-import-path : String]
  [candidate : String]
  [selected-item : i64]
  [remaining-segments : i64]
  [alias : ast.AstMaybeImportAlias]) : ResultCompilerLoadResolvedImport
  (let
    [candidate-id : i64 (compiler-load-import-module-id candidate)]
    (match (compiler-load-resolve-import-candidate
      (owned_view.compiler-owned-shared-view resolver)
      (owned_view.compiler-owned-shared-view candidate)
      (Some candidate-id))
      [(Ok resolved)
        (if (compiler-load-resolved-source-exists?
          (owned_view.compiler-owned-shared-view resolved))
          (if (= remaining-segments 1)
            (compiler-load-resolved-import
              resolved
              (ModuleItem selected-item)
              candidate
              alias)
            (Err
              (compiler-load-invalid-selected-import-message
                original-import-path
                candidate)))
          (let
            [dot : i64 (compiler-load-dotted-module-last-dot candidate)]
            (if (< dot 0)
              (Err "")
              (compiler-load-search-import-prefix
                resolver
                original-import-path
                (string.substring candidate 0 dot)
                selected-item
                (+ remaining-segments 1)
                alias))))]
      [(Err _)
        (let
          [dot : i64 (compiler-load-dotted-module-last-dot candidate)]
          (if (< dot 0)
            (Err "")
            (compiler-load-search-import-prefix
              resolver
              original-import-path
              (string.substring candidate 0 dot)
              selected-item
              (+ remaining-segments 1)
              alias)))])))

(define (compiler-load-resolve-import-spec-classified
  [resolver : CompilerLoadImportResolver]
  [kind : ast.AstImportKind]
  [import-path : String]
  [expected-module : ast.AstMaybeModuleName]
  [alias : ast.AstMaybeImportAlias]) : ResultCompilerLoadResolvedImport
  (match kind
    [(ModuleAll)
      (let
        [resolved
          (try
            (compiler-load-resolve-import-candidate
              resolver
              (owned_view.compiler-owned-shared-view import-path)
              expected-module))]
        (compiler-load-resolved-import resolved ModuleAll import-path alias))]
    [(ModuleItem _)
      (let
        [resolved
          (try
            (compiler-load-resolve-import-candidate
              resolver
              (owned_view.compiler-owned-shared-view import-path)
              expected-module))]
        (compiler-load-resolved-import resolved kind import-path alias))]
    [(Module)
      (let
        [original : ResultPkgResolve
          (compiler-load-resolve-import-candidate
            (owned_view.compiler-owned-shared-view resolver)
            (owned_view.compiler-owned-shared-view import-path)
            expected-module)]
        (match original
          [(Ok resolved)
            (if (compiler-load-resolved-source-exists?
              (owned_view.compiler-owned-shared-view resolved))
              (compiler-load-resolved-import resolved Module import-path alias)
              (let
                [dot : i64 (compiler-load-dotted-module-last-dot import-path)]
                (if (< dot 0)
                  (compiler-load-resolved-import
                    resolved
                    Module
                    import-path
                    alias)
                  (let
                    [item-text : String
                      (string.substring
                        import-path
                        (+ dot 1)
                        (- (string.string-length import-path) (+ dot 1)))]
                    (match (compiler-load-search-import-prefix
                      resolver
                      (owned_view.compiler-owned-shared-view import-path)
                      (string.substring import-path 0 dot)
                      (compiler-load-selected-item-id expected-module item-text)
                      1
                      alias)
                      [(Ok selected) (Ok selected)]
                      [(Err message)
                        (if (= (string.string-length message) 0)
                          (compiler-load-resolved-import
                            resolved
                            Module
                            import-path
                            alias)
                          (Err message))])))))]
          [(Err original-message)
            (let
              [dot : i64 (compiler-load-dotted-module-last-dot import-path)]
              (if (< dot 0)
                (Err original-message)
                (let
                  [item-text : String
                    (string.substring
                      import-path
                      (+ dot 1)
                      (- (string.string-length import-path) (+ dot 1)))]
                  (match (compiler-load-search-import-prefix
                    resolver
                    (owned_view.compiler-owned-shared-view import-path)
                    (string.substring import-path 0 dot)
                    (compiler-load-selected-item-id expected-module item-text)
                    1
                    alias)
                    [(Ok selected) (Ok selected)]
                    [(Err message)
                      (if (= (string.string-length message) 0)
                        (Err original-message)
                        (Err message))]))))]))]
    [(Macro _ _)
      (Err
        "compiler-load: module macro imports must be expanded before import resolution")]
    [(MacroDecls _ _)
      (Err
        "compiler-load: module macro imports must be expanded before import resolution")]))

;; Semantic consumers that already know whether an import selects a module or
;; item still need the raw ordinary-root candidate. Keep that API on the same
;; typed resolver boundary without duplicating dotted fallback classification.
(define (compiler-load-resolve-import-spec-with-roots
  [importer-path : String]
  [import-root : String]
  [kind : ast.AstImportKind]
  [import-path : String]
  [expected-module : ast.AstMaybeModuleName]
  [stdlib-roots : svec.Vec]) : ResultPkgResolve
  (if (compiler-load-macro-import-kind? kind)
    (Err
      "compiler-load: module macro imports must be expanded before import resolution")
    (compiler-load-resolve-import-candidate
      (compiler-load-ordinary-import-resolver
        importer-path
        import-root
        stdlib-roots)
      import-path
      expected-module)))

(define (compiler-load-resolve-package-import-spec
  [importer-path : String]
  [kind : ast.AstImportKind]
  [import-path : String]
  [expected-module : ast.AstMaybeModuleName]
  [stdlib-roots : svec.Vec]
  [manifest-dir : String]
  [deps : CompilerPkgDeps]) : ResultPkgResolve
  (if (compiler-load-macro-import-kind? kind)
    (Err
      "compiler-load: module macro imports must be expanded before import resolution")
    (compiler-load-resolve-import-candidate
      (compiler-load-package-import-resolver
        importer-path
        manifest-dir
        deps
        stdlib-roots)
      import-path
      expected-module)))

(define (compiler-load-resolve-import-spec-with-roots-classified
  [importer-path : String]
  [import-root : String]
  [kind : ast.AstImportKind]
  [import-path : String]
  [expected-module : ast.AstMaybeModuleName]
  [alias : ast.AstMaybeImportAlias]
  [stdlib-roots : svec.Vec]) : ResultCompilerLoadResolvedImport
  (compiler-load-resolve-import-spec-classified
    (compiler-load-ordinary-import-resolver
      importer-path
      import-root
      stdlib-roots)
    kind
    import-path
    expected-module
    alias))

(define (compiler-load-resolve-package-import-spec-classified
  [importer-path : String]
  [kind : ast.AstImportKind]
  [import-path : String]
  [expected-module : ast.AstMaybeModuleName]
  [alias : ast.AstMaybeImportAlias]
  [stdlib-roots : svec.Vec]
  [manifest-dir : String]
  [deps : CompilerPkgDeps]) : ResultCompilerLoadResolvedImport
  (compiler-load-resolve-import-spec-classified
    (compiler-load-package-import-resolver
      importer-path
      manifest-dir
      deps
      stdlib-roots)
    kind
    import-path
    expected-module
    alias))

(define (compiler-load-package-import-externs?
  [kind : ast.AstImportKind]
  [import-path : String]
  [expected-module : ast.AstMaybeModuleName]
  [deps : CompilerPkgDeps]) : bool
  (match kind
    [(Module)
      (let
        [module-path : String
          (compiler-load-dotted-module-path-from-ast
            (string.copy import-path)
            expected-module)]
        [first : String
          (compiler-load-dotted-module-first (string.copy import-path))]
        [rest : String
          (compiler-load-dotted-module-rest
            (string.copy import-path)
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
    [(ModuleAll)
      (compiler-load-package-import-externs?
        Module
        import-path
        expected-module
        deps)]
    [(ModuleItem _)
      (compiler-load-package-import-externs?
        Module
        import-path
        expected-module
        deps)]
    [(Macro _ _) false]
    [(MacroDecls _ _) false]))

(define (compiler-load-package-source-expected-module
  [kind : ast.AstImportKind]
  [expected-module : ast.AstMaybeModuleName]
  [package-externs : bool]) : ast.AstMaybeModuleName
  (if package-externs
    (match kind
      ;; A dependency alias selects a package root and source path; it is not
      ;; the dependency source's public module identity. Let an explicit module
      ;; declaration win, while a moduleless source keeps the dotted fallback.
      [(Module) No]
      [(ModuleAll) No]
      [(ModuleItem _) No]
      [_ expected-module])
    expected-module))

(define (compiler-load-macro-import-kind? [kind : ast.AstImportKind]) : bool
  (match kind
    [(Macro _ _) true]
    [(MacroDecls _ _) true]
    [_ false]))

(defenum CompilerLoadIncludeKind
  (RuntimeString)
  (ComptimeString)
  (LzssString)
  (Binary))

(define (compiler-load-include-str-def-with-pools
  [pools : ast.AstNodePoolContext]
  [name : i64]
  [contents : String]) : ast.AstDecl
  (ast.ast-decl-def-id
    name
    (Some (String))
    (ast.ast-node-pool-context-expr-push
      pools
      (Literal (ast.ast-lit-generated-string contents)))))

;; Comptime includes retain their macro declaration and transformer-only bytes.
(define (compiler-load-include-str-comptime-def-with-pools
  [pools : ast.AstNodePoolContext]
  [name : i64]
  [contents : String]) : ast.AstDecl
  (let
    [args : ast.AstExprList (ast.ast-expr-list-with-capacity 1)]
    [literal : i64
      (ast.ast-node-pool-context-expr-push
        pools
        (Literal (ast.ast-lit-generated-string contents)))]
    (ast.ast-expr-list-push (&mut args) literal)
    (ast.ast-decl-def-macro-id
      name
      (ast.ast-macro-param-list-new)
      (String)
      (ast.ast-node-pool-context-expr-push
        pools
        (Call
          (ast.ast-node-pool-context-expr-push
            pools
            (Var (cbi.compiler-builtin-ctfe "expr-string")))
          args)))))

(define (compiler-load-include-bin-def-with-pools
  [pools : ast.AstNodePoolContext]
  [name : i64]
  [contents : String]) : ast.AstDecl
  (ast.ast-decl-def-id
    name
    (Some (ast.ast-ty-dyn-array-with-pools pools (& (U8))))
    (ast.ast-node-pool-context-expr-push pools (BinaryData contents))))

(define (compiler-load-include-str-lzss-def-with-pools
  [pools : ast.AstNodePoolContext]
  [name : i64]
  [contents : String]) : ast.AstDecl
  (compiler-load-include-bin-def-with-pools
    pools
    name
    (ctfe.ctfe-embedded-stdlib-binary-data-bytes contents)))

(define (compiler-load-include-def-with-pools
  [kind : CompilerLoadIncludeKind]
  [pools : ast.AstNodePoolContext]
  [name : i64]
  [contents : String]) : ast.AstDecl
  (match kind
    [(RuntimeString)
      (compiler-load-include-str-def-with-pools pools name contents)]
    [(ComptimeString)
      (compiler-load-include-str-comptime-def-with-pools pools name contents)]
    [(LzssString)
      (compiler-load-include-str-lzss-def-with-pools pools name contents)]
    [(Binary) (compiler-load-include-bin-def-with-pools pools name contents)]))

(define (compiler-load-include-read-error
  [kind : CompilerLoadIncludeKind]
  [importer-path : String]
  [include-path : String]
  [resolved : String]) : cdiag.CompilerDiagnostic
  (cdiag.compiler-diagnostic-at-start
    (string.copy importer-path)
    (str_cat.str-cat
      "compiler-load: cannot read "
      (match kind
        [(Binary) "include-bin"]
        [_ "include-str"])
      " "
      include-path
      " from "
      importer-path
      " (resolved "
      resolved
      ")")))

;; The bytes an include embeds. An `include-str-lzss` of a TypeLisp `.tl`
;; source embeds it with its top-level inline tests blanked (#8713) and its
;; prose comments cut (#8659); every other include embeds `contents` exactly.
(define (compiler-load-include-contents
  [kind : CompilerLoadIncludeKind]
  [include-path : (& include-path str)]
  [contents : String]) : String
  (match kind
    [(LzssString)
      (if (compiler-load-tl-path? include-path)
        (ces.compiler-embedded-stdlib-payload-source contents)
        contents)]
    [_ contents]))

(define (compiler-load-include-from-resolved-with-pools
  [kind : CompilerLoadIncludeKind]
  [importer-path : String]
  [include-path : String]
  [resolved : String]
  [name : i64]
  [pools : ast.AstNodePoolContext]) : ResultCompilerLoadInclude
  (if (io.file-exists? (string.copy resolved))
    (Ok
      (compiler-load-include-def-with-pools
        kind
        pools
        name
        (compiler-load-include-contents
          kind
          (& include-path)
          (compiler-load-session-read-source-text resolved))))
    (match (compiler-load-embedded-stdlib-source-for-path
      (string.copy resolved))
      [(CompilerEmbeddedStdlibSomeSource source)
        (compiler-load-session-state-note-embedded-source!
          (compiler-load-active-session-state-shared-view)
          (& resolved)
          (& source))
        (Ok
          (compiler-load-include-def-with-pools
            kind
            pools
            name
            (compiler-load-include-contents kind (& include-path) source)))]
      [(CompilerEmbeddedStdlibNoSource)
        (Err
          (box
            (compiler-load-include-read-error
              kind
              importer-path
              include-path
              resolved)))])))

(define (compiler-load-include-from-resolved
  [kind : CompilerLoadIncludeKind]
  [importer-path : String]
  [include-path : String]
  [resolved : String]
  [name : i64]) : ResultCompilerLoadInclude
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [result : ResultCompilerLoadInclude
      (compiler-load-include-from-resolved-with-pools
        kind
        importer-path
        include-path
        resolved
        name
        pools)]
    (ast.ast-node-pool-context-install! pools)
    result))

(define (compiler-load-expand-include-with-pools
  [kind : CompilerLoadIncludeKind]
  [importer-path : String]
  [include-path : String]
  [name : i64]
  [stdlib-roots : svec.Vec]
  [pools : ast.AstNodePoolContext]) : ResultCompilerLoadInclude
  (match (compiler-load-resolve-import-result-with-roots
    (string.copy importer-path)
    (string.copy include-path)
    stdlib-roots)
    [(Ok resolved)
      (compiler-load-include-from-resolved-with-pools
        kind
        importer-path
        include-path
        resolved
        name
        pools)]
    [(Err message)
      (Err (box (cdiag.compiler-diagnostic-at-start importer-path message)))]))

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

;; Include expansion precedes the recursive tail load. Only its successful
;; result reaches this shared declaration/path/module publication boundary.
(define (compiler-load-prepend-include
  [kind : CompilerLoadIncludeKind]
  [expanded : ast.AstDecl]
  [source : ast.AstDeclList]
  [importer-path : String]
  [owner-id : i64]
  [provenance-id : i64]
  [module-id : i64]
  [rest : ResultCompilerLoadWithPaths]) : ResultCompilerLoadWithPaths
  (match rest
    [(Ok decls paths modules seen)
      (Ok
        (match kind
          ;; Preserve the existing LZSS declaration-origin policy.
          [(LzssString) (ast.ast-decl-list-prepend-builder expanded decls)]
          [_
            (compiler-load-decl-list-prepend-from-source expanded source decls)])
        (ast.ast-decl-path-list-prepend-builder-with-owner-and-provenance-id
          importer-path
          owner-id
          provenance-id
          paths)
        (ast.ast-decl-module-list-prepend-builder-id module-id modules)
        seen)]
    [(Err diagnostic) (Err diagnostic)]))

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
      (parser.compiler-parse-decl-origin-register-list-aliases! (& out) 1 rest))
    out))

(define (compiler-load-decl-list-prepend
  [head : ast.AstDecl]
  [rest : ast.AstDeclList]) : ast.AstDeclList
  (compiler-load-decl-list-prepend-with-origin head (None) rest))

(define (compiler-load-decl-list-append
  [left : ast.AstDeclList]
  [right : ast.AstDeclList]) : ast.AstDeclList
  (let
    [out : ast.AstDeclList
      (ast.ast-decl-list-with-capacity
        (+ (ast.ast-decl-list-len (& left)) (ast.ast-decl-list-len (& right))))]
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
    out))

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
          (ast.ast-decl-list-copy-to
            (&mut right-slots)
            (& left.slots)
            left.offset
            new-offset
            0
            left-len)
          (ast.AstDeclList right-slots new-offset (+ left-len right-len) true))
        (let
          [out : ast.AstDeclList
            (ast.ast-decl-list-with-capacity (+ left-len right-len))]
          (ast.ast-decl-list-append-from (&mut out) (& left) 0)
          (ast.ast-decl-list-append-from (&mut out) (& right) 0)
          out))]
    [same-storage : bool
      (= right-key (parser.compiler-parse-decl-list-storage-key (& out)))]
    (parser.compiler-parse-decl-origin-register-list-aliases! (& out) 0 left)
    (if same-storage
      unit
      (parser.compiler-parse-decl-origin-register-list-aliases!
        (& out)
        left-len
        right))
    out))

(define (compiler-load-decl-path-list-append
  [left : ast.AstDeclPathList]
  [right : ast.AstDeclPathList]) : ast.AstDeclPathList
  (let
    [out : ast.AstDeclPathList
      (ast.ast-decl-path-list-with-capacity
        (+
          (ast.ast-decl-path-list-len (& left))
          (ast.ast-decl-path-list-len (& right))))]
    (ast.ast-decl-path-list-append-from (&mut out) (& left) 0)
    (ast.ast-decl-path-list-append-from (&mut out) (& right) 0)
    out))

(define (compiler-load-decl-path-list-append-onto
  [left : ast.AstDeclPathList]
  [right : ast.AstDeclPathList]) : ast.AstDeclPathList
  (let
    [left-len : i64 (ast.ast-decl-path-list-len (& left))]
    [right-len : i64 (ast.ast-decl-path-list-len (& right))]
    [right-slots : (__tl_dyn-array String)
      (ast.ast-place-shared-view right.slots)]
    [right-owner-ids : (__tl_dyn-array i64) right.owner-ids]
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
          true))
      (let
        [out : ast.AstDeclPathList
          (ast.ast-decl-path-list-with-capacity (+ left-len right-len))]
        (ast.ast-decl-path-list-append-from (&mut out) (& left) 0)
        (ast.ast-decl-path-list-append-from (&mut out) (& right) 0)
        out))))

(define (compiler-load-decl-module-list-append
  [left : ast.AstDeclModuleList]
  [right : ast.AstDeclModuleList]) : ast.AstDeclModuleList
  (let
    [out : ast.AstDeclModuleList
      (ast.ast-decl-module-list-with-capacity
        (+
          (ast.ast-decl-module-list-len (& left))
          (ast.ast-decl-module-list-len (& right))))]
    (ast.ast-decl-module-list-append-from (&mut out) (& left) 0)
    (ast.ast-decl-module-list-append-from (&mut out) (& right) 0)
    out))

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
          true))
      (let
        [out : ast.AstDeclModuleList
          (ast.ast-decl-module-list-with-capacity (+ left-len right-len))]
        (ast.ast-decl-module-list-append-from (&mut out) (& left) 0)
        (ast.ast-decl-module-list-append-from (&mut out) (& right) 0)
        out))))

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
(define (compiler-load-stdlib-prelude-file-with-roots-cfg
  [path : String]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]) : ResultCompilerLoadWithPaths
  (let
    [suffix : String (compiler-load-stdlib-suffix (string.copy path))]
    (match (compiler-load-resolve-stdlib-root
      (string.copy suffix)
      (ast.ast-place-shared-view stdlib-roots))
      [(CompilerLoadSomePath source-path)
        (compiler-load-note-embedded-equivalent-if-matching!
          suffix
          (string.copy source-path))
        (compiler-load-source-with-paths-and-roots-cfg
          (string.copy path)
          (compiler-load-session-read-source-text source-path)
          seen
          stdlib-roots
          cfgs)]
      [(CompilerLoadNoPath)
        (match (compiler-load-embedded-stdlib-source suffix)
          [(CompilerEmbeddedStdlibSomeSource source)
            (compiler-load-note-embedded-module! (string.copy path))
            (compiler-load-session-note-embedded-stdlib-source!)
            (compiler-load-source-with-paths-and-roots-cfg
              (string.copy path)
              source
              seen
              stdlib-roots
              cfgs)]
          [(CompilerEmbeddedStdlibNoSource)
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
    No
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
    [suffix : String (compiler-load-stdlib-suffix (string.copy path))]
    (match (compiler-load-resolve-stdlib-root
      (string.copy suffix)
      (ast.ast-place-shared-view stdlib-roots))
      [(CompilerLoadSomePath source-path)
        (compiler-load-session-state-note-embedded-equivalent-if-matching!
          (owned_view.compiler-owned-shared-view load-state)
          suffix
          (string.copy source-path))
        (let
          [text : String
            (compiler-load-session-state-read-source-text
              (owned_view.compiler-owned-shared-view load-state)
              (& source-path))]
          (compiler-load-stdlib-prelude-source-with-roots-cfg-with-pools
            load-state
            (string.copy path)
            text
            seen
            stdlib-roots
            cfgs
            pools))]
      [(CompilerLoadNoPath)
        (match (compiler-load-embedded-stdlib-source suffix)
          [(CompilerEmbeddedStdlibSomeSource source)
            (compiler-load-session-state-note-embedded-module!
              load-state
              (string.copy path))
            (compiler-load-session-state-note-embedded-stdlib-source!
              (owned_view.compiler-owned-shared-view load-state))
            (compiler-load-stdlib-prelude-source-with-roots-cfg-with-pools
              load-state
              path
              source
              seen
              stdlib-roots
              cfgs
              pools)]
          [(CompilerEmbeddedStdlibNoSource)
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
    [(Ok decls paths modules seen)
      (Ok
        (compiler-load-decl-list-append
          decls
          (ast.ast-decl-cons
            (& (ast.ast-decl-module-id cbi.compiler-builtin-id-fix-empty))
            (& (ast.ast-decl-list-new))))
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
            (& (ast.ast-decl-module-list-new))))
        seen)]
    [(Err diag) (Err diag)]))

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
    [(Ok decls _ _ seen) (Ok decls seen)]
    [(Err diag) (Err diag)]))

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
  (match (ast.ast-decl-list-step decls)
    [(Nil)
      (match found
        [(CompilerLoadNoModuleId) (Ok fallback fallback-id)]
        [(CompilerLoadSomeModuleId name name-id) (Ok name name-id)])]
    [(Cons decl rest)
      (let
        [rest : ast.AstDeclList rest]
        (match (clone decl)
          [(Module name)
            (match found
              [(CompilerLoadNoModuleId)
                (compiler-load-decls-module-id-loop
                  path
                  rest
                  fallback
                  fallback-id
                  (CompilerLoadSomeModuleId (ci.intern-str name) name))]
              [(CompilerLoadSomeModuleId _ _)
                (Err
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
      (compiler-load-canonical-module-id-from-path (string.copy path))]
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
    [(No) (Ok actual actual-id)]
    [(Some want)
      (let
        [checked-actual-id : i64
          (if (>= actual-id 0)
            actual-id
            (compiler-load-parse-context-name-id (string.copy actual)))]
        (if (= want checked-actual-id)
          (Ok actual checked-actual-id)
          (Err
            (box
              (cdiag.compiler-diagnostic-at-start
                (string.copy path)
                (str_cat.str-cat
                  "compiler-load: import expected module "
                  (ci.intern-str want)
                  " but loaded "
                  actual))))))]))

(define (compiler-load-no-expected-module? [expected : ast.AstMaybeModuleName]) : bool
  (match expected
    [(No) true]
    [(Some _) false]))

(define (compiler-load-module-fallback-id-for-parse
  [fallback : String]
  [expected : ast.AstMaybeModuleName]) : i64
  (let
    [fallback-id : i64 (compiler-load-parse-context-name-id fallback)]
    (match expected
      [(Some module-id)
        (if (= module-id fallback-id)
          module-id
          fallback-id)]
      [(No) fallback-id])))

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

(define (compiler-load-tl-path? [path : (& path str)]) : bool
  (let
    [n : i64 (string.string-length path)]
    (and (>= n 3) (string.eq (string.substring path (- n 3) 3) ".tl"))))

(define (compiler-load-strip-tl-extension [path : String]) : String
  (if (compiler-load-tl-path? (& path))
    (string.substring path 0 (- (string.string-length path) 3))
    path))

(define (compiler-load-module-id-from-path-text [path : (& path str)]) : String
  (let
    [normalized : String
      (compiler-load-strip-tl-extension (compiler-load-normalize-path path))]
    [n : i64 (string.string-length normalized)]
    [i : i64 0]
    [out : String ""]
    (while (< i n)
      (let
        [c : char (string.string-ref normalized i)]
        (if (compiler-load-path-separator? c)
          (set! out (str_cat.str-cat out "." ""))
          (set! out (str_cat.str-cat out (string.substring normalized i 1) "")))
        (set! i (+ i 1))))
    out))

(define (compiler-load-canonical-module-id-from-path [path : (& path str)]) : String
  (compiler-load-module-id-from-path-text path))

(define (compiler-load-root-relative-path
  [root : (& root str)]
  [path : (& path str)]) : String
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
    [(Module) import-path]
    [(ModuleAll) import-path]
    [(ModuleItem _) import-path]
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
    [(Nil) ""]
    [(Cons decl rest)
      (let
        [rest : ast.AstDeclList rest]
        (match (clone decl)
          [(Module name) (ci.intern-str name)]
          [_ (compiler-load-decls-source-module rest)]))]))

(define (compiler-load-decls-source-module-id [decls : ast.AstDeclList]) : i64
  (match (ast.ast-decl-list-step decls)
    [(Nil) cbi.compiler-builtin-id-fix-empty]
    [(Cons decl rest)
      (let
        [rest : ast.AstDeclList rest]
        (match decl
          [(Module name) name]
          [_ (compiler-load-decls-source-module-id rest)]))]))

(define (compiler-load-decls-source-module-or
  [decls : ast.AstDeclList]
  [fallback : String]) : String
  (match (ast.ast-decl-list-step decls)
    [(Nil) fallback]
    [(Cons decl rest)
      (let
        [rest : ast.AstDeclList rest]
        (match decl
          [(Module name) (ci.intern-str name)]
          [_ (compiler-load-decls-source-module-or rest fallback)]))]))

;; Tag-only predicate: an index cursor reads the tag word through a borrow
;; instead of copying a 104 B row and a 144 B step result per declaration.
(define (compiler-load-decl-list-has-module?
  [decls : (& decls ast.AstDeclList)]) : bool
  (let
    [count : i64 (ast.ast-decl-list-len (& decls))]
    [index : i64 0]
    [found : bool false]
    (while (and (not found) (< index count))
      (match (ast.ast-decl-list-ref-borrowed (& decls) index)
        [(Module _) (set! found true)]
        [_ unit])
      (set! index (+ index 1)))
    found))

(define (compiler-load-decl-list-has-module-id?
  [decls : ast.AstDeclList]
  [want : i64]) : bool
  (let
    [count : i64 (ast.ast-decl-list-len (& decls))]
    [index : i64 0]
    (while (< index count)
      (let
        [decl : ast.AstDecl
          (ast.ast-decl-list-get (& decls) index (ast.ast-decl-fallback))]
        (match decl
          [(Module name) (when (= name want) (return true))]
          [(ModuleBody name body-box)
            (when
              (or
                (= name want)
                (compiler-load-decl-list-has-module-id? (deref body-box) want))
              (return true))]
          [_ unit])
        (set! index (+ index 1))))
    false))

(define (compiler-load-contextual-moduleless-decls
  [decls : ast.AstDeclList]
  [source-module : String]
  [source-module-id : i64]) : ast.AstDeclList
  (if (and
    (> (string.string-length source-module) 0)
    (not (compiler-load-decl-list-has-module? decls)))
    (compiler-load-decl-list-prepend
      (ast.ast-decl-module-id source-module-id)
      decls)
    decls))

(define (compiler-load-seen-module-with-paths
  [path : String]
  [path-id : i64]
  [_ : String]
  [module-name-id : i64]
  [decls : ast.AstDeclList]
  [seen : sym_i64_env.SymI64Env]) : ResultCompilerLoadWithPaths
  (if (compiler-load-decl-list-has-module? decls)
    (Ok
      (ast.ast-decl-cons
        (& (ast.ast-decl-module-id module-name-id))
        (& (ast.ast-decl-list-new)))
      (ast.ast-decl-path-list-prepend-builder-with-owner-id
        (string.copy path)
        path-id
        (ast.ast-decl-path-list-new))
      (ast.ast-decl-module-cons-id
        module-name-id
        (& (ast.ast-decl-module-list-new)))
      seen)
    (Ok
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
    [(Module)
      (match (compiler-load-session-state-surface-summary-find-source
        state
        source-path-id)
        [(CompilerLoadSomeSurfaceSummary summary)
          (Some summary.declaration-module-id)]
        [(CompilerLoadNoSurfaceSummary)
          (if (compiler-load-decl-list-has-module? imported-decls)
            (Some (compiler-load-decls-source-module-id imported-decls))
            expected)])]
    [(ModuleAll)
      (match (compiler-load-session-state-surface-summary-find-source
        state
        source-path-id)
        [(CompilerLoadSomeSurfaceSummary summary)
          (Some summary.declaration-module-id)]
        [(CompilerLoadNoSurfaceSummary)
          (if (compiler-load-decl-list-has-module? imported-decls)
            (Some (compiler-load-decls-source-module-id imported-decls))
            expected)])]
    [(ModuleItem _)
      (match (compiler-load-session-state-surface-summary-find-source
        state
        source-path-id)
        [(CompilerLoadSomeSurfaceSummary summary)
          (Some summary.declaration-module-id)]
        [(CompilerLoadNoSurfaceSummary)
          (if (compiler-load-decl-list-has-module? imported-decls)
            (Some (compiler-load-decls-source-module-id imported-decls))
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

(define (compiler-load-import-alias-collision-result
  [path : String]
  [span : ast.AstSourceSpan]
  [alias : i64]
  [first-module : i64]
  [second-module : i64]) : ResultCompilerLoadAliasCheck
  (Err
    (box
      (cdiag.compiler-diagnostic-from-ast-span
        path
        span
        (str_cat.str-cat
          "compiler-load: ambiguous import alias '"
          (str_cat.str-cat
            (ci.intern-str alias)
            (str_cat.str-cat
              "' between '"
              (str_cat.str-cat
                (ci.intern-str first-module)
                (str_cat.str-cat
                  "' and '"
                  (str_cat.str-cat
                    (ci.intern-str second-module)
                    "'; use distinct aliases or qualified access"))))))))))

;; Parsed sources and fully expanded programs share this namespace rule. The
;; expected module is the loader's canonical identity; paths are diagnostic
;; provenance, never alias identities. Temporary bindings live for this scan.
(define (compiler-load-check-dotted-import-aliases-with-paths
  [fallback-path : String]
  [decls : ast.AstDeclList]
  [paths : ast.AstDeclPathList]) : ResultCompilerLoadAliasCheck
  (let
    [seen : load_i64_i64_map.Map (load_i64_i64_map.with-capacity 64)]
    [current-module : i64
      (compiler-load-decls-source-module-id (ast.ast-place-shared-view decls))]
    [count : i64 (ast.ast-decl-list-len (& decls))]
    [index : i64 0]
    (while (< index count)
      (let
        [decl : ast.AstDecl
          (ast.ast-array-shared-view decls.slots (+ decls.offset index))]
        (match decl
          [(Module name) (set! current-module name)]
          [(Import _ (Spec (Module) import-name expected (Some alias) span))
            ;; An empty generated-module marker means unqualified import,
            ;; not a user-visible dotted alias. Its names have their own
            ;; collision policy; distinct unqualified modules are valid.
            (unless
              (= alias cbi.compiler-builtin-id-fix-empty)
              (let
                [key : i64
                  (compiler-load-dotted-import-alias-key current-module alias)]
                [source-module : i64
                  (match expected
                    [(Some name) name]
                    [(No) (ci.intern import-name)])]
                (match (load_i64_i64_map.get (& seen) key)
                  [(LookupFound prior)
                    ;; Re-importing one module under the same alias is
                    ;; idempotent, including replayed generated imports.
                    (unless
                      (= prior source-module)
                      (return
                        (compiler-load-import-alias-collision-result
                          (ast.ast-decl-path-list-get
                            (& paths)
                            index
                            fallback-path)
                          (__tl-box-place span)
                          alias
                          prior
                          source-module)))]
                  [(LookupMissing)
                    (load_i64_i64_map.insert-ref! (&mut seen) key source-module)])))]
          [_ unit])
        (set! index (+ index 1))))
    (Ok)))

(define (compiler-load-check-dotted-import-aliases
  [path : String]
  [decls : ast.AstDeclList]
  [_source-module : String]) : ResultCompilerLoadAliasCheck
  (compiler-load-check-dotted-import-aliases-with-paths
    path
    decls
    (ast.ast-decl-path-list-new)))

;; `local-index` is the declaration index when the binding is the importing
;; module's own declaration, and -1 for an import.
(define (compiler-load-unqualified-import-note
  [state : (&mut state CompilerLoadUnqualifiedImportState)]
  [importer-module : i64]
  [local-name : i64]
  [source-module : i64]
  [source-item : i64]
  [local-index : i64]
  [path : String]
  [span : ast.AstSourceSpan]) : CompilerLoadUnqualifiedImportStep
  (let
    [key : i64 (ci.intern-composite-pair-id importer-module local-name)]
    [source-id : i64 (ci.intern-composite-pair-id source-module source-item)]
    (match (load_i64_i64_map.get (& state.source-ids) key)
      [(LookupFound prior-source-id)
        (if (= prior-source-id source-id)
          (Ok)
          (Collision
            (CompilerLoadUnqualifiedImportCollision
              (ci.intern-str local-name)
              (ci.intern-str
                (match (load_i64_i64_map.get (& state.source-modules) key)
                  [(LookupFound prior-module) prior-module]
                  [(LookupMissing) cbi.compiler-builtin-id-fix-empty]))
              (ci.intern-str source-module)
              path
              span
              (match (load_i64_i64_map.get (& state.local-decls) key)
                [(LookupFound prior-index) prior-index]
                [(LookupMissing) -1]))))]
      [(LookupMissing)
        (load_i64_i64_map.insert-ref! (&mut state.source-ids) key source-id)
        (load_i64_i64_map.insert-ref!
          (&mut state.source-modules)
          key
          source-module)
        (when
          (>= local-index 0)
          (load_i64_i64_map.insert-ref!
            (&mut state.local-decls)
            key
            local-index))
        (Ok)])))

(define (compiler-load-unqualified-import-note-variants
  [state : (&mut state CompilerLoadUnqualifiedImportState)]
  [importer-module : i64]
  [source-module : i64]
  [variants : (& variants ast.AstVariantDefList)]
  [index : i64]
  [local-index : i64]
  [path : String]
  [span : ast.AstSourceSpan]) : CompilerLoadUnqualifiedImportStep
  (if (>= index (ast.ast-variant-def-list-len variants))
    (Ok)
    (match (ast.ast-variant-def-list-get
      variants
      index
      (ast.ast-variant-def-fallback))
      [(Def name _ _)
        (match (compiler-load-unqualified-import-note
          state
          importer-module
          name
          source-module
          name
          local-index
          (owned_view.compiler-owned-shared-view path)
          span)
          [(Ok)
            (compiler-load-unqualified-import-note-variants
              state
              importer-module
              source-module
              variants
              (+ index 1)
              local-index
              path
              span)]
          [(Collision collision) (Collision collision)])])))

(define (compiler-load-unqualified-import-note-decl
  [state : (&mut state CompilerLoadUnqualifiedImportState)]
  [importer-module : i64]
  [source-module : i64]
  [decl : ast.AstDecl]
  [local-index : i64]
  [path : String]
  [span : ast.AstSourceSpan]) : CompilerLoadUnqualifiedImportStep
  (match (ast.ast-decl-unwrapped (& decl))
    [(Def _ name _ _)
      (compiler-load-unqualified-import-note
        state
        importer-module
        name
        source-module
        name
        local-index
        path
        span)]
    [(DefFn _ name _ _ _ _)
      (compiler-load-unqualified-import-note
        state
        importer-module
        name
        source-module
        name
        local-index
        path
        span)]
    [(DefMacro _ name _ _ _)
      (compiler-load-unqualified-import-note
        state
        importer-module
        name
        source-module
        name
        local-index
        path
        span)]
    [(DefDispatch _ name _)
      (compiler-load-unqualified-import-note
        state
        importer-module
        name
        source-module
        name
        local-index
        path
        span)]
    [(Extern _ name _ _ _)
      (compiler-load-unqualified-import-note
        state
        importer-module
        name
        source-module
        name
        local-index
        path
        span)]
    [(DefStruct _ name _ _ _)
      (compiler-load-unqualified-import-note
        state
        importer-module
        name
        source-module
        name
        local-index
        path
        span)]
    [(DefStructLifetimes _ name _ _ _ _)
      (compiler-load-unqualified-import-note
        state
        importer-module
        name
        source-module
        name
        local-index
        path
        span)]
    [(DefEnum _ name _ variants)
      (match (compiler-load-unqualified-import-note
        state
        importer-module
        name
        source-module
        name
        local-index
        (owned_view.compiler-owned-shared-view path)
        span)
        [(Ok)
          (compiler-load-unqualified-import-note-variants
            state
            importer-module
            source-module
            (& variants)
            0
            local-index
            path
            span)]
        [(Collision collision) (Collision collision)])]
    [(DefEnumLifetimes _ name _ _ variants)
      (match (compiler-load-unqualified-import-note
        state
        importer-module
        name
        source-module
        name
        local-index
        (owned_view.compiler-owned-shared-view path)
        span)
        [(Ok)
          (compiler-load-unqualified-import-note-variants
            state
            importer-module
            source-module
            (& variants)
            0
            local-index
            path
            span)]
        [(Collision collision) (Collision collision)])]
    [_ (Ok)]))

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
    (while (< index count)
      (let
        [decl : ast.AstDecl
          (ast.ast-array-shared-view decls.slots (+ decls.offset index))]
        (match (ast.ast-place-shared-view decl)
          [(Module next-module) (set! cur-module next-module)]
          [_
            (when
              (= cur-module source-module)
              (match (compiler-load-unqualified-import-note-decl
                state
                importer-module
                source-module
                decl
                -1
                (owned_view.compiler-owned-shared-view path)
                span)
                [(Ok) unit]
                [(Collision collision) (return (Collision collision))]))])
        (set! index (+ index 1))))
    (Ok)))

;; Note the declarations of every module that imports unqualified names, so an
;; import that binds one of the module's own names is a collision whichever
;; comes first. A module's own declarations of a name share one source, so
;; noting them never collides. Both walks read declaration tags in place; a row
;; is copied only inside a module with unqualified imports, and a program
;; without such imports skips the second walk.
(define (compiler-load-unqualified-import-note-locals
  [state : (&mut state CompilerLoadUnqualifiedImportState)]
  [decls : (& decls ast.AstDeclList)]) : unit
  (let
    [importers : load_i64_i64_map.Map (load_i64_i64_map.with-capacity 16)]
    [any-importer : bool false]
    [in-importer : bool false]
    [cur-module : i64 cbi.compiler-builtin-id-fix-empty]
    [count : i64 (ast.ast-decl-list-len decls)]
    [index : i64 0]
    (while (< index count)
      (match (ast.ast-decl-list-ref-borrowed decls index)
        [(Module _)
          (set!
            cur-module
            (ast.ast-decl-list-module-id-at
              decls
              index
              cbi.compiler-builtin-id-fix-empty))]
        [(Import _ (Spec (ModuleAll) _ (Some _) _ _))
          (load_i64_i64_map.insert-ref! (&mut importers) cur-module 1)
          (set! any-importer true)]
        [(Import _ (Spec (ModuleItem _) _ (Some _) (Some _) _))
          (load_i64_i64_map.insert-ref! (&mut importers) cur-module 1)
          (set! any-importer true)]
        [_ unit])
      (set! index (+ index 1)))
    (when
      any-importer
      (set! cur-module cbi.compiler-builtin-id-fix-empty)
      (set!
        in-importer
        (match (load_i64_i64_map.get (& importers) cur-module)
          [(LookupFound _) true]
          [(LookupMissing) false]))
      (set! index 0)
      (while (< index count)
        (match (ast.ast-decl-list-ref-borrowed decls index)
          [(Module _)
            (set!
              cur-module
              (ast.ast-decl-list-module-id-at
                decls
                index
                cbi.compiler-builtin-id-fix-empty))
            (set!
              in-importer
              (match (load_i64_i64_map.get (& importers) cur-module)
                [(LookupFound _) true]
                [(LookupMissing) false]))]
          [_
            (when
              in-importer
              (match (compiler-load-unqualified-import-note-decl
                state
                cur-module
                cur-module
                (ast.ast-decl-list-get decls index (ast.ast-decl-fallback))
                index
                ""
                (ast.ast-decl-span-fallback))
                [(Ok) unit]
                [(Collision _) unit]))])
        (set! index (+ index 1))))))

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

;; Declarations before the first module marker belong to an entry file
;; without a `module` form, whose identity is empty.
(define (compiler-load-unqualified-import-local-collision-message
  [collision : CompilerLoadUnqualifiedImportCollision]) : String
  (str_cat.str-cat
    "compiler-load: unqualified import '"
    (str_cat.str-cat
      (string.copy (& collision.name))
      (str_cat.str-cat
        "' from module '"
        (str_cat.str-cat
          collision.second-module
          (str_cat.str-cat
            "' collides with the declaration of '"
            (str_cat.str-cat
              collision.name
              (if (= (string.string-length collision.first-module) 0)
                "' in the entry module"
                (str_cat.str-cat
                  "' in module '"
                  (str_cat.str-cat collision.first-module "'"))))))))))

;; The import is the primary span. An import that collides with the importing
;; module's own declaration also labels that declaration when the parser
;; recorded its span.
(define (compiler-load-unqualified-import-collision-result
  [collision : CompilerLoadUnqualifiedImportCollision]
  [decls : (& decls ast.AstDeclList)]
  [paths : (& paths ast.AstDeclPathList)]) : ResultCompilerLoadAliasCheck
  (if (< collision.local-index 0)
    (let
      [message : String
        (compiler-load-unqualified-import-collision-message
          (owned_view.compiler-owned-shared-view collision))]
      (Err
        (box
          (cdiag.compiler-diagnostic-from-ast-span
            collision.path
            collision.span
            message))))
    (let
      [diag : cdiag.CompilerDiagnostic
        (cdiag.compiler-diagnostic-with-help
          (&
            (cdiag.compiler-diagnostic-from-ast-span
              (owned_view.compiler-owned-shared-view collision.path)
              collision.span
              (compiler-load-unqualified-import-local-collision-message
                (owned_view.compiler-owned-shared-view collision))))
          "alias the import with `as`, rename the declaration, or import the module and use qualified access")]
      (Err
        (box
          (match (parser.compiler-parse-decl-span decls collision.local-index)
            [(Some span)
              (cdiag.compiler-diagnostic-with-secondary
                (& diag)
                (cdiag.CompilerDiagnosticSpan
                  (ast.ast-decl-path-list-get
                    paths
                    collision.local-index
                    (owned_view.compiler-owned-shared-view collision.path))
                  (ast.ast-source-span-start-line span)
                  (ast.ast-source-span-start-col span)
                  (ast.ast-source-span-end-line span)
                  (ast.ast-source-span-end-col span))
                (CompilerDiagnosticSomeString
                  (str_cat.str-cat
                    "'"
                    (str_cat.str-cat collision.name "' is declared here"))))]
            [(None) diag]))))))

(define (compiler-load-check-unqualified-imports
  [fallback-path : String]
  [decls : ast.AstDeclList]
  [paths : (& paths ast.AstDeclPathList)]
  [require-selected-items : bool]) : ResultCompilerLoadAliasCheck
  (let
    [state : CompilerLoadUnqualifiedImportState
      (CompilerLoadUnqualifiedImportState
        (load_i64_i64_map.with-capacity 64)
        (load_i64_i64_map.with-capacity 64)
        (load_i64_i64_map.with-capacity 64))]
    [cur-module : i64 cbi.compiler-builtin-id-fix-empty]
    [count : i64 (ast.ast-decl-list-len (& decls))]
    [index : i64 0]
    (compiler-load-unqualified-import-note-locals (&mut state) (& decls))
    (while (< index count)
      (let
        [decl : ast.AstDecl
          (ast.ast-array-shared-view decls.slots (+ decls.offset index))]
        [path : String
          (ast.ast-decl-path-list-get
            (& paths)
            index
            (owned_view.compiler-owned-shared-view fallback-path))]
        (match decl
          [(Module next-module) (set! cur-module next-module)]
          [(Import _ (Spec (ModuleAll) _ (Some source-module) _ span))
            (match (compiler-load-unqualified-import-note-wildcard
              (&mut state)
              (ast.ast-place-shared-view decls)
              cur-module
              source-module
              path
              (__tl-box-place span))
              [(Ok) unit]
              [(Collision collision)
                (return
                  (compiler-load-unqualified-import-collision-result
                    collision
                    (& decls)
                    paths))])]
          [(Import
            _
            (Spec
              (ModuleItem source-item)
              _
              (Some source-module)
              (Some alias)
              span))
            (when
              (and
                require-selected-items
                (not
                  (compiler-load-selected-item-present?
                    (ModuleItem source-item)
                    (Some source-module)
                    (ast.ast-place-shared-view decls))))
              (return
                (Err
                  (box
                    (cdiag.compiler-diagnostic-from-ast-span
                      path
                      (__tl-box-place span)
                      (compiler-load-missing-selected-item-message
                        (ci.intern-str source-module)
                        (ModuleItem source-item)))))))
            (match (compiler-load-unqualified-import-note
              (&mut state)
              cur-module
              alias
              source-module
              source-item
              -1
              path
              (__tl-box-place span))
              [(Ok) unit]
              [(Collision collision)
                (return
                  (compiler-load-unqualified-import-collision-result
                    collision
                    (& decls)
                    paths))])]
          [_ unit])
        (set! index (+ index 1))))
    (Ok)))

;; Loading checks namespace collisions while declarations may still contain
;; generators. Only the completed expansion can require every selected item to
;; be present in the final declaration view, including previously loaded modules.
(define (compiler-load-check-unqualified-import-collisions
  [fallback-path : String]
  [decls : ast.AstDeclList]
  [paths : (& paths ast.AstDeclPathList)]) : ResultCompilerLoadAliasCheck
  (compiler-load-check-unqualified-imports fallback-path decls paths false))

(define (compiler-load-check-expanded-unqualified-imports
  [fallback-path : String]
  [decls : ast.AstDeclList]
  [paths : ast.AstDeclPathList]) : ResultCompilerLoadAliasCheck
  (compiler-load-check-unqualified-imports fallback-path decls paths true))

(define (compiler-load-session-state-surface-summary-owner-arena
  [state : (& state CompilerLoadSessionState)]) : i64
  (array-ref state.surface-summary-owner-arena 0))

(define (compiler-load-session-state-surface-summary-owner-arena-ensure!
  [state : (& state CompilerLoadSessionState)]) : i64
  (let
    [owner : i64
      (compiler-load-session-state-surface-summary-owner-arena (& state))]
    (if (> owner 0)
      owner
      (let
        [fresh : i64 (arena.tl_arena_make_small)]
        (set! (array-ref state.surface-summary-owner-arena 0) fresh)
        fresh))))

;; Moves whenever a surface-summary list loses or reorders entries: a reset or
;; a source removal. An append keeps every earlier summary at its physical
;; index, so it changes only the count. Readers that index summaries by
;; position (the typechecker's macro surface index) rebuild when this moves.
;; It is process-wide and only ever grows, so a reader that also keys on its
;; session and count never mistakes one list for another.
(define compiler-load-surface-summaries-epoch : i64
  0)

(define (compiler-load-surface-summaries-epoch-bump!) : unit
  (set!
    compiler-load-surface-summaries-epoch
    (+ compiler-load-surface-summaries-epoch 1)))

(define (compiler-load-surface-summaries-epoch-value) : i64
  compiler-load-surface-summaries-epoch)

;; The owner arena of the active load session, which identifies it.
(define (compiler-load-active-session-owner-arena) : i64
  (__tl-project-field
    (compiler-load-active-session-state-shared-view)
    owner-arena))

(define (compiler-load-session-state-surface-summaries-reset!
  [state : CompilerLoadSessionState]) : unit
  (compiler-load-surface-summaries-epoch-bump!)
  (let
    [payload-owner : i64
      (compiler-load-session-state-surface-summary-owner-arena (& state))]
    ;; Unpublish every summary before retiring the payload arena. Rebuild the
    ;; empty descriptor in the stable session owner so the state never keeps
    ;; a handle into the destroyed generation between batch entries.
    (in-arena
      (arena.Arena state.owner-arena)
      (set!
        (array-ref state.surface-summaries 0)
        (compiler-load-surface-summary-list-empty))
      (set! (array-ref state.lazy-import-skip-record-count 0) 0))
    (set! (array-ref state.surface-summary-owner-arena 0) 0)
    (when
      (> payload-owner 0)
      (if (= (arena.tl_arena_current) payload-owner)
        (unsafe
          (arena.tl_arena_set state.owner-arena))
        unit)
      (unsafe
        (arena.tl_arena_destroy payload-owner)))))

(define (compiler-load-surface-summaries-reset!) : unit
  (compiler-load-session-state-surface-summaries-reset!
    (compiler-load-active-session-state-shared-view)))

(define (compiler-load-session-state-surface-summary-load-enter!
  [state : CompilerLoadSessionState]) : unit
  (let
    [depth : i64 (array-ref state.surface-summary-load-depth 0)]
    (if (= depth 0)
      (compiler-load-session-state-surface-summaries-reset!
        (owned_view.compiler-owned-shared-view state))
      unit)
    (set! (array-ref state.surface-summary-load-depth 0) (+ depth 1))))

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
  [state : (& state CompilerLoadSessionState)]) : i64
  (array-ref state.lazy-import-skip-record-count 0))

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
    (while (< index (compiler-load-surface-summary-list-count summaries))
      (if (=
        (__tl-project-field
          (compiler-load-surface-summary-list-at summaries index)
          source-path-id)
        source-path-id)
        (return true)
        (set! index (+ index 1))))
    false))

(define (compiler-load-surface-summary-list-record
  [summaries : CompilerLoadSurfaceSummaryList]
  [summary : CompilerLoadSurfaceSummary]) : CompilerLoadSurfaceSummaryList
  (let
    [len : i64 (compiler-load-surface-summary-list-count summaries)]
    [slots : (__tl_dyn-array CompilerLoadSurfaceSummary) summaries.slots]
    (if (< len (array-length slots))
      unit
      (let
        [capacity : i64
          (if (= (array-length slots) 0)
            1
            (* (array-length slots) 2))]
        [bigger : (__tl_dyn-array CompilerLoadSurfaceSummary)
          (__tl_make-array CompilerLoadSurfaceSummary capacity)]
        [index : i64 0]
        (while (< index len)
          (set! (array-ref bigger index) (array-ref slots index))
          (set! index (+ index 1)))
        (set! slots bigger)))
    (set! (array-ref slots len) summary)
    (CompilerLoadSurfaceSummaryList slots (+ len 1))))

(define (compiler-load-session-state-record-surface-summary!
  [state : (& state CompilerLoadSessionState)]
  [summary : CompilerLoadSurfaceSummary]) : unit
  (if (compiler-load-surface-summary-source-active?
    (compiler-load-session-state-surface-summaries state)
    summary.source-path-id)
    unit
    ;; Generated imports can build summaries while macro scratch is current.
    ;; The lazy-import handoff reads them once after scratch release to distill
    ;; definition-site aliases, so own both the summary payload and the dense
    ;; list growth in the load session's resettable surface-summary arena.
    (let
      [payload-owner : i64
        (compiler-load-session-state-surface-summary-owner-arena-ensure! state)]
      [copy-into-owner? : bool (not (= (arena.tl_arena_current) payload-owner))]
      (in-arena
        (arena.Arena payload-owner)
        (let
          [owned : CompilerLoadSurfaceSummary
            (if copy-into-owner?
              (clone summary)
              summary)]
          (set!
            (array-ref state.surface-summaries 0)
            (compiler-load-surface-summary-list-record
              (compiler-load-session-state-surface-summaries state)
              owned)))))))

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
    (while (< index (compiler-load-surface-summary-list-count summaries))
      (let
        [summary : CompilerLoadSurfaceSummary
          (compiler-load-surface-summary-list-at summaries index)]
        (if (= summary.source-path-id source-path-id)
          (return (CompilerLoadSomeSurfaceSummary summary))
          (set! index (+ index 1)))))
    (CompilerLoadNoSurfaceSummary)))

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
    (while (< index (compiler-load-surface-summary-list-count summaries))
      (let
        [summary : CompilerLoadSurfaceSummary
          (compiler-load-surface-summary-list-at summaries index)]
        (if (= summary.module-id module-id)
          (return (CompilerLoadSomeSurfaceSummary summary))
          (set! index (+ index 1)))))
    (CompilerLoadNoSurfaceSummary)))

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
  [state : (& state CompilerLoadSessionState)]
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
          [(Some _)
            ;; A qualified alias requires a concrete declaration module.
            (not
              (=
                summary.declaration-module-id
                cbi.compiler-builtin-id-fix-empty))]
          [(No) summary.qualified-load])
        (compiler-load-seen-module-contains? seen "" summary.module-id))]))

(define (compiler-load-surface-summary-seen-expected-module?
  [source-path-id : i64]
  [expected-module : ast.AstMaybeModuleName]
  [seen : sym_i64_env.SymI64Env]) : bool
  (let
    [bound-6 (compiler-load-active-session-state-shared-view)]
    (compiler-load-session-state-surface-summary-seen-expected-module?
      bound-6
      source-path-id
      expected-module
      seen)))

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
      (Ok
        (ast.ast-decl-list-new)
        (ast.ast-decl-path-list-new)
        (ast.ast-decl-module-list-new)
        seen)]
    [(CompilerLoadSomeSurfaceSummary summary)
      (let
        [module-id : i64 summary.module-id]
        (match expected-module
          [(Some expected-id)
            (when
              (and summary.explicit-module (not (= module-id expected-id)))
              (return
                (Err
                  (box
                    (cdiag.compiler-diagnostic-at-start
                      (string.copy path)
                      (str_cat.str-cat
                        "compiler-load: import expected module "
                        (ci.intern-str expected-id)
                        " but loaded "
                        (ci.intern-syntax-name-text-or
                          module-id
                          "<structural-module>")))))))]
          [(No) unit])
        (if (match expected-module
          [(Some expected-id) (= module-id expected-id)]
          [(No) false])
          (Ok
            (ast.ast-decl-cons
              (& (ast.ast-decl-module-id module-id))
              (& (ast.ast-decl-list-new)))
            (ast.ast-decl-path-list-prepend-builder-with-owner-id
              path
              source-path-id
              (ast.ast-decl-path-list-new))
            (ast.ast-decl-module-cons-id
              module-id
              (& (ast.ast-decl-module-list-new)))
            seen)
          (Ok
            (ast.ast-decl-list-new)
            (ast.ast-decl-path-list-new)
            (ast.ast-decl-module-list-new)
            seen)))]))

(define (compiler-load-resolved-path-id-for-generated-import-with-state
  [state : CompilerLoadSessionState]
  [resolved : String]
  [expected-module : ast.AstMaybeModuleName]) : i64
  (match expected-module
    [(No) (ci.intern-generated-canonical-name resolved)]
    [(Some module-id)
      (match (compiler-load-session-state-surface-summary-find-module
        state
        module-id)
        [(CompilerLoadNoSurfaceSummary)
          (ci.intern-generated-canonical-name resolved)]
        [(CompilerLoadSomeSurfaceSummary summary)
          ;; Package resolution and summary construction both retain normalized
          ;; spellings. Compare those directly: source-token IDs and generated
          ;; canonical IDs intentionally occupy different identity domains.
          (if (string.eq summary.source-path resolved)
            summary.source-path-id
            (ci.intern-generated-canonical-name resolved))])]))

;; Serial/test compatibility adapter.
(define (compiler-load-surface-summary-remove-source-in
  [summaries : CompilerLoadSurfaceSummaryList]
  [source-path-id : i64]) : CompilerLoadSurfaceSummaryList
  (let
    [len : i64 (compiler-load-surface-summary-list-count summaries)]
    [kept : i64 0]
    [physical-index : i64 0]
    (while (< physical-index len)
      (if (not
        (=
          (__tl-project-field
            (array-ref summaries.slots physical-index)
            source-path-id)
          source-path-id))
        (set! kept (+ kept 1))
        unit)
      (set! physical-index (+ physical-index 1)))
    (if (= kept len)
      summaries
      (let
        [slots : (__tl_dyn-array CompilerLoadSurfaceSummary)
          (__tl_make-array CompilerLoadSurfaceSummary kept)]
        [read-index : i64 0]
        [write-index : i64 0]
        (while (< read-index len)
          (let
            [summary : CompilerLoadSurfaceSummary
              (clone (array-ref summaries.slots read-index))]
            (when
              (not (= summary.source-path-id source-path-id))
              (set! (array-ref slots write-index) summary)
              (set! write-index (+ write-index 1)))
            (set! read-index (+ read-index 1))))
        (CompilerLoadSurfaceSummaryList slots kept)))))

(define (compiler-load-session-state-surface-summary-remove-source!
  [state : CompilerLoadSessionState]
  [source-path-id : i64]) : unit
  (compiler-load-surface-summaries-epoch-bump!)
  (let
    [payload-owner : i64
      (compiler-load-session-state-surface-summary-owner-arena-ensure!
        (& state))]
    (in-arena
      (arena.Arena payload-owner)
      (set!
        (array-ref state.surface-summaries 0)
        (compiler-load-surface-summary-remove-source-in
          (compiler-load-session-state-surface-summaries state)
          source-path-id)))))

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
    (match (if (io.file-exists? (string.copy path))
      (compiler-load-parse-file-diagnostic-session-id-with-pools
        (owned_view.compiler-owned-shared-view load-state)
        (string.copy path)
        source-path-id
        stdlib-roots
        parse-cfgs
        pools)
      (match (compiler-load-embedded-stdlib-source-for-path (string.copy path))
        [(CompilerEmbeddedStdlibSomeSource source)
          (compiler-load-parse-embedded-source-diagnostic-session-id-with-pools
            (owned_view.compiler-owned-shared-view load-state)
            (string.copy path)
            source-path-id
            source
            parse-cfgs
            pools)]
        [(CompilerEmbeddedStdlibNoSource)
          (parser.ResultAstProgramDiagnostic.Err
            (box
              (cdiag.compiler-diagnostic-at-start
                (string.copy path)
                (str_cat.str-cat
                  "compiler-load: cannot read import "
                  (string.copy path)))))]))
      [(Ok program)
        (match (compiler-load-surface-summary-build
          (string.copy path)
          source-path-id
          import-root
          program
          fallback-id
          (not (compiler-load-no-expected-module? expected-module)))
          [(Ok summary)
            (compiler-load-session-state-record-surface-summary!
              load-state
              summary)]
          [(Err _) unit])]
      [(Err _) unit])))

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
    (compiler-load-session-state-surface-summary-remove-source!
      (owned_view.compiler-owned-shared-view load-state)
      parse-identity.source-path-id)
    (compiler-load-surface-summary-load-with-pools
      load-state
      path
      parse-identity
      stdlib-roots
      expected-module
      import-root
      cfgs
      pools)))

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
    (while (< index (compiler-load-surface-decl-list-count decls))
      (if (compiler-load-surface-summary-decl-requires-eager?
        (compiler-load-surface-decl-list-at decls index))
        (return true)
        (set! index (+ index 1))))
    false))

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
    [(SymI64ViewNil) members]
    [(SymI64ViewBind member-id _ rest)
      (compiler-load-structural-member-set-add-id
        (compiler-load-structural-member-set-union-from members rest)
        member-id)]))

(define (compiler-load-structural-member-set-union
  [left : sym_i64_env.SymI64Env]
  [right : sym_i64_env.SymI64Env]) : sym_i64_env.SymI64Env
  (match (sym_i64_env.sym-i64-view left)
    [(SymI64ViewNil) right]
    [_
      (match (sym_i64_env.sym-i64-view right)
        [(SymI64ViewNil) left]
        [_ (compiler-load-structural-member-set-union-from left right)])]))

(define (compiler-load-lazy-alias-demand-merge
  [left : CompilerLoadLazyAliasDemand]
  [right : CompilerLoadLazyAliasDemand]) : CompilerLoadLazyAliasDemand
  (CompilerLoadLazyAliasDemand
    (or left.qualified right.qualified)
    (or left.direct right.direct)
    (or left.unknown right.unknown)
    (compiler-load-structural-member-set-union left.members right.members)))

(define (compiler-load-lazy-dotted-tail-after-prefix-id-with-intern-state
  [interns : (& interns ci.InternCompatState)]
  [name : i64]
  [prefix : i64]) : i64
  (if (ci.intern-compat-state-dotted? interns prefix)
    (if (and
      (ci.intern-compat-state-dotted? interns name)
      (=
        (ci.intern-compat-state-leading-dot-id interns name)
        (ci.intern-compat-state-leading-dot-id interns prefix)))
      (compiler-load-lazy-dotted-tail-after-prefix-id-with-intern-state
        interns
        (ci.intern-compat-state-dotted-tail-id interns name)
        (ci.intern-compat-state-dotted-tail-id interns prefix))
      -1)
    (if (and
      (ci.intern-compat-state-dotted? interns name)
      (= (ci.intern-compat-state-leading-dot-id interns name) prefix))
      (ci.intern-compat-state-dotted-tail-id interns name)
      -1)))

(define (compiler-load-session-intern-renderable-id-active?
  [interns : (& interns ci.InternCompatState)]
  [id : i64]) : bool
  (and
    (ci.intern-renderable-id? id)
    (or
      (< id (ci.intern-compat-state-pool-len interns))
      (ci.intern-compat-state-generated-id-active? interns id))))

(define (compiler-load-session-state-lazy-tail-after-prefix-id
  [state : CompilerLoadSessionState]
  [name : i64]
  [alias : i64]) : i64
  (let
    [interns : ci.InternCompatState (compiler-load-session-state-interns state)]
    (unless
      (and
        (compiler-load-session-intern-renderable-id-active? (& interns) name)
        (compiler-load-session-intern-renderable-id-active? (& interns) alias))
      (return -1))
    (if (ci.intern-compat-state-qualified? (& interns) name)
      (if (=
        (ci.intern-compat-state-qualified-module-id (& interns) name)
        alias)
        (ci.intern-compat-state-qualified-base-id (& interns) name)
        -1)
      (compiler-load-lazy-dotted-tail-after-prefix-id-with-intern-state
        (& interns)
        name
        alias))))

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
      (compiler-load-lazy-qualified-observer-stack-empty))))

(define (compiler-load-lazy-qualified-observer-reset!) : unit
  (let
    [state : CompilerLoadSessionState
      (compiler-load-active-session-state-shared-view)]
    (compiler-load-session-state-lazy-qualified-observer-reset! state)))

(define (compiler-load-lazy-qualified-observer-members-with-note
  [state : CompilerLoadSessionState]
  [name : i64]
  [root-id : i64]
  [members : sym_i64_env.SymI64Env]) : sym_i64_env.SymI64Env
  (let
    [member-id : i64
      (compiler-load-session-state-lazy-qualified-member-id state name root-id)]
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
        (compiler-load-session-state-shared-view (& state))
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
    (if (compiler-load-session-state-lazy-name-qualified-by-id?
      (compiler-load-session-state-shared-view (& state))
      name
      secondary-root-id)
      (begin
        (compiler-load-lazy-qualified-observer-flag-set! observer 2 true)
        (compiler-load-lazy-qualified-observer-members-set!
          observer
          1
          (compiler-load-lazy-qualified-observer-members-with-note
            (compiler-load-session-state-shared-view (& state))
            name
            secondary-root-id
            (compiler-load-lazy-qualified-observer-members observer 1))))
      (if (and
        (not (sym_i64_env.sym-i64-contains-id locals name))
        (= name secondary-root-id))
        (compiler-load-lazy-qualified-observer-flag-set! observer 3 true)
        unit))
    unit))

(define (compiler-load-session-state-lazy-name-qualified-by-id?
  [state : CompilerLoadSessionState]
  [name : i64]
  [alias : i64]) : bool
  (>=
    (compiler-load-session-state-lazy-tail-after-prefix-id state name alias)
    0))

(define (compiler-load-session-state-lazy-qualified-member-id
  [state : CompilerLoadSessionState]
  [name : i64]
  [alias : i64]) : i64
  (let
    [base : i64
      (compiler-load-session-state-lazy-tail-after-prefix-id
        (owned_view.compiler-owned-shared-view state)
        name
        alias)]
    [interns : ci.InternCompatState (compiler-load-session-state-interns state)]
    (if (and
      (ci.intern-renderable-id? base)
      (ci.intern-compat-state-dotted? (& interns) base))
      (ci.intern-compat-state-leading-dot-id (& interns) base)
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
      [(Def variant-name _ _)
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
      [(CompilerLoadSurfaceEnumSignature _ _ _ variants)
        (compiler-load-lazy-surface-variant-direct-name? variants name)]
      [_ false])))

(define (compiler-load-lazy-surface-decls-direct-name?
  [decls : (& decls CompilerLoadSurfaceDeclList)]
  [name : i64]) : bool
  (let
    [index : i64 0]
    (while (< index (compiler-load-surface-decl-list-count decls))
      (if (compiler-load-lazy-surface-decl-direct-name?
        (compiler-load-surface-decl-list-at decls index)
        name)
        (return true)
        (set! index (+ index 1))))
    false))

(define (compiler-load-session-state-lazy-name-demand
  [state : CompilerLoadSessionState]
  [name : i64]
  [alias : i64]
  [summary : (& summary CompilerLoadSurfaceSummary)]
  [locals : sym_i64_env.SymI64Env]) : CompilerLoadLazyAliasDemand
  (if (compiler-load-session-state-lazy-qualified-observer-active? (& state))
    (compiler-load-session-state-lazy-qualified-observer-note-secondary!
      (& state)
      name
      locals)
    unit)
  (cond
    [(compiler-load-session-state-lazy-name-qualified-by-id?
        (owned_view.compiler-owned-shared-view state)
        name
        alias)
      (let
        [member-id : i64
          (compiler-load-session-state-lazy-qualified-member-id
            (owned_view.compiler-owned-shared-view state)
            name
            alias)]
        (if (< member-id 0)
          (compiler-load-lazy-alias-demand-unknown)
          (begin
            (if (compiler-load-session-state-lazy-qualified-observer-active?
              (& state))
              (compiler-load-session-state-lazy-qualified-observer-note!
                (& state)
                name)
              unit)
            (compiler-load-lazy-alias-demand-qualified member-id))))]
    [(sym_i64_env.sym-i64-contains-id locals name)
      (compiler-load-lazy-alias-demand-none)]
    [(or
        (= name alias)
        (compiler-load-lazy-surface-decls-direct-name? summary.decls name))
      (compiler-load-lazy-alias-demand-direct)]
    [else (compiler-load-lazy-alias-demand-none)]))

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
    (when (= len 0) (return false))
    (while (< index len)
      (if (not
        (compiler-load-surface-decl-decl-emitting?
          (compiler-load-surface-decl-list-at decls index)))
        (return false)
        (set! index (+ index 1))))
    true))

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
  [summary : (& summary CompilerLoadSurfaceSummary)]
  [locals : sym_i64_env.SymI64Env]) : CompilerLoadLazyAliasDemand
  (compiler-load-session-state-lazy-type-demand
    state
    (ast.ty-node-get type-id)
    alias
    summary
    locals))

(define (compiler-load-session-state-lazy-type-list-demand
  [state : CompilerLoadSessionState]
  [types : ast.AstTypeList]
  [alias : i64]
  [summary : (& summary CompilerLoadSurfaceSummary)]
  [locals : sym_i64_env.SymI64Env]) : CompilerLoadLazyAliasDemand
  (ast.ast-type-id-list-fold
    types
    compiler-load-lazy-alias-demand-merge
    (compiler-load-lazy-alias-demand-none)
    compiler-load-lazy-type-id-demand-hook
    (owned_view.compiler-owned-shared-view state)
    alias
    summary
    locals))

(define (compiler-load-session-state-lazy-type-demand
  [state : CompilerLoadSessionState]
  [ty : ast.AstType]
  [alias : i64]
  [summary : (& summary CompilerLoadSurfaceSummary)]
  [locals : sym_i64_env.SymI64Env]) : CompilerLoadLazyAliasDemand
  (match (owned_view.compiler-owned-shared-view ty)
    [(Enum name)
      (compiler-load-session-state-lazy-name-demand
        state
        name
        alias
        summary
        locals)]
    [(EnumArgs name _)
      (compiler-load-session-state-lazy-name-demand
        state
        name
        alias
        summary
        locals)]
    [(Struct name)
      (compiler-load-session-state-lazy-name-demand
        state
        name
        alias
        summary
        locals)]
    [(StructArgs name _)
      (compiler-load-session-state-lazy-name-demand
        state
        name
        alias
        summary
        locals)]
    [(Var name)
      (compiler-load-session-state-lazy-name-demand
        state
        name
        alias
        summary
        locals)]
    [(VarArgs name _)
      (compiler-load-session-state-lazy-name-demand
        state
        name
        alias
        summary
        locals)]
    ;; A C-function type's signature is not an alias use.
    [(CFunc _ _) (compiler-load-lazy-alias-demand-none)]
    [_
      (ast.ast-type-fold-children
        ty
        compiler-load-lazy-alias-demand-merge
        (compiler-load-lazy-alias-demand-none)
        compiler-load-lazy-type-id-demand-hook
        (owned_view.compiler-owned-shared-view state)
        alias
        summary
        locals)]))

(define (compiler-load-session-state-lazy-maybe-type-demand
  [state : CompilerLoadSessionState]
  [maybe-ty : ast.AstMaybeType]
  [alias : i64]
  [summary : (& summary CompilerLoadSurfaceSummary)]
  [locals : sym_i64_env.SymI64Env]) : CompilerLoadLazyAliasDemand
  (match maybe-ty
    [(No) (compiler-load-lazy-alias-demand-none)]
    [(Some ty)
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
  [summary : (& summary CompilerLoadSurfaceSummary)]
  [locals : sym_i64_env.SymI64Env]
  [index : i64]) : CompilerLoadLazyAliasDemand
  (if (>= index (ast.ast-param-list-len params))
    (compiler-load-lazy-alias-demand-none)
    (match (ast.ast-param-list-get params index (ast.ast-param-fallback))
      [(Param _ ty _)
        (compiler-load-lazy-alias-demand-merge
          (compiler-load-session-state-lazy-type-demand
            (owned_view.compiler-owned-shared-view state)
            ty
            alias
            summary
            locals)
          (compiler-load-session-state-lazy-param-list-demand-at?
            state
            params
            alias
            summary
            locals
            (+ index 1)))])))

(define (compiler-load-session-state-lazy-param-list-demand
  [state : CompilerLoadSessionState]
  [params : (& params ast.AstParamList)]
  [alias : i64]
  [summary : (& summary CompilerLoadSurfaceSummary)]
  [locals : sym_i64_env.SymI64Env]) : CompilerLoadLazyAliasDemand
  (compiler-load-session-state-lazy-param-list-demand-at?
    state
    (& params)
    alias
    summary
    locals
    0))

(define (compiler-load-session-state-lazy-param-list-locals-at
  [state : (& state CompilerLoadSessionState)]
  [params : (& params ast.AstParamList)]
  [locals : sym_i64_env.SymI64Env]
  [index : i64]) : sym_i64_env.SymI64Env
  (if (>= index (ast.ast-param-list-len params))
    locals
    (match (ast.ast-param-list-get params index (ast.ast-param-fallback))
      [(Param name _ _)
        (compiler-load-session-state-lazy-param-list-locals-at
          state
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
  [summary : (& summary CompilerLoadSurfaceSummary)]
  [locals : sym_i64_env.SymI64Env]
  [index : i64]) : CompilerLoadLazyAliasDemand
  (if (>= index (ast.ast-macro-param-list-len params))
    (compiler-load-lazy-alias-demand-none)
    (match (ast.ast-macro-param-list-get
      params
      index
      (ast.ast-macro-param-fallback))
      [(Param _ ty _ _)
        (compiler-load-lazy-alias-demand-merge
          (compiler-load-session-state-lazy-type-demand
            (owned_view.compiler-owned-shared-view state)
            ty
            alias
            summary
            locals)
          (compiler-load-session-state-lazy-macro-param-list-demand-at?
            state
            params
            alias
            summary
            locals
            (+ index 1)))])))

(define (compiler-load-session-state-lazy-macro-param-list-demand
  [state : CompilerLoadSessionState]
  [params : (& params ast.AstMacroParamList)]
  [alias : i64]
  [summary : (& summary CompilerLoadSurfaceSummary)]
  [locals : sym_i64_env.SymI64Env]) : CompilerLoadLazyAliasDemand
  (compiler-load-session-state-lazy-macro-param-list-demand-at?
    state
    (& params)
    alias
    summary
    locals
    0))

(define (compiler-load-session-state-lazy-macro-param-list-locals-at
  [state : (& state CompilerLoadSessionState)]
  [params : (& params ast.AstMacroParamList)]
  [locals : sym_i64_env.SymI64Env]
  [index : i64]) : sym_i64_env.SymI64Env
  (if (>= index (ast.ast-macro-param-list-len params))
    locals
    (match (ast.ast-macro-param-list-get
      params
      index
      (ast.ast-macro-param-fallback))
      [(Param name _ _ _)
        (compiler-load-session-state-lazy-macro-param-list-locals-at
          state
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
  [summary : (& summary CompilerLoadSurfaceSummary)]
  [locals : sym_i64_env.SymI64Env]
  [index : i64]) : CompilerLoadLazyAliasDemand
  (if (>= index (ast.ast-field-def-list-len fields))
    (compiler-load-lazy-alias-demand-none)
    (match (ast.ast-field-def-list-get
      fields
      index
      (ast.ast-field-def-fallback))
      [(Def _ ty _)
        (compiler-load-lazy-alias-demand-merge
          (compiler-load-session-state-lazy-type-demand
            (owned_view.compiler-owned-shared-view state)
            ty
            alias
            summary
            locals)
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
  [summary : (& summary CompilerLoadSurfaceSummary)]
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
  [summary : (& summary CompilerLoadSurfaceSummary)]
  [locals : sym_i64_env.SymI64Env]
  [index : i64]) : CompilerLoadLazyAliasDemand
  (if (>= index (ast.ast-variant-def-list-len variants))
    (compiler-load-lazy-alias-demand-none)
    (match (ast.ast-variant-def-list-get
      variants
      index
      (ast.ast-variant-def-fallback))
      [(Def _ types _)
        (compiler-load-lazy-alias-demand-merge
          (compiler-load-session-state-lazy-type-list-demand
            (owned_view.compiler-owned-shared-view state)
            types
            alias
            summary
            locals)
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
  [summary : (& summary CompilerLoadSurfaceSummary)]
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
  [summary : (& summary CompilerLoadSurfaceSummary)]
  [locals : sym_i64_env.SymI64Env]) : CompilerLoadLazyAliasDemand
  (match pattern
    [(Var _ maybe-ty)
      (compiler-load-session-state-lazy-maybe-type-demand
        state
        maybe-ty
        alias
        summary
        locals)]
    [(Tuple patterns)
      (compiler-load-session-state-lazy-pattern-list-demand
        state
        (deref patterns)
        alias
        summary
        locals)]
    [(Array patterns)
      (compiler-load-session-state-lazy-pattern-list-demand
        state
        (deref patterns)
        alias
        summary
        locals)]
    [(Slice patterns _)
      (compiler-load-session-state-lazy-pattern-list-demand
        state
        (deref patterns)
        alias
        summary
        locals)]
    [(Variant name patterns)
      (compiler-load-lazy-alias-demand-merge
        (compiler-load-session-state-lazy-name-demand
          (owned_view.compiler-owned-shared-view state)
          name
          alias
          summary
          locals)
        (compiler-load-session-state-lazy-pattern-list-demand
          state
          (deref patterns)
          alias
          summary
          locals))]
    [(Wildcard) (compiler-load-lazy-alias-demand-none)]
    [(Binding _) (compiler-load-lazy-alias-demand-none)]
    [(Literal _) (compiler-load-lazy-alias-demand-none)]))

(define (compiler-load-session-state-lazy-pattern-list-demand-at?
  [state : CompilerLoadSessionState]
  [patterns : (& patterns ast.AstPatternList)]
  [alias : i64]
  [summary : (& summary CompilerLoadSurfaceSummary)]
  [locals : sym_i64_env.SymI64Env]
  [index : i64]) : CompilerLoadLazyAliasDemand
  (if (>= index patterns.len)
    (compiler-load-lazy-alias-demand-none)
    (compiler-load-lazy-alias-demand-merge
      (compiler-load-session-state-lazy-pattern-demand
        (owned_view.compiler-owned-shared-view state)
        (ast.ast-pattern-list-get patterns index (ast.ast-pattern-fallback))
        alias
        summary
        locals)
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
  [summary : (& summary CompilerLoadSurfaceSummary)]
  [locals : sym_i64_env.SymI64Env]) : CompilerLoadLazyAliasDemand
  (compiler-load-session-state-lazy-pattern-list-demand-at?
    state
    (& patterns)
    alias
    summary
    locals
    0))

(define (compiler-load-session-state-lazy-pattern-locals
  [state : (& state CompilerLoadSessionState)]
  [pattern : ast.AstPattern]
  [locals : sym_i64_env.SymI64Env]) : sym_i64_env.SymI64Env
  (match pattern
    [(Var name _)
      (if (compiler-load-session-state-lazy-qualified-observer-exhaustive?
        state)
        (compiler-load-session-state-lazy-demand-bind-local-exhaustive
          state
          locals
          name)
        (sym_i64_env.sym-i64-bind-id locals name 1))]
    [(Binding name)
      (if (compiler-load-session-state-lazy-qualified-observer-exhaustive?
        state)
        (compiler-load-session-state-lazy-demand-bind-local-exhaustive
          state
          locals
          name)
        (sym_i64_env.sym-i64-bind-id locals name 1))]
    [(Tuple patterns)
      (compiler-load-session-state-lazy-pattern-list-locals
        state
        (deref patterns)
        locals)]
    [(Array patterns)
      (compiler-load-session-state-lazy-pattern-list-locals
        state
        (deref patterns)
        locals)]
    [(Slice patterns _)
      (compiler-load-session-state-lazy-pattern-list-locals
        state
        (deref patterns)
        locals)]
    [(Variant _ patterns)
      (compiler-load-session-state-lazy-pattern-list-locals
        state
        (deref patterns)
        locals)]
    [(Wildcard) locals]
    [(Literal _) locals]))

(define (compiler-load-session-state-lazy-pattern-list-locals-at
  [state : (& state CompilerLoadSessionState)]
  [patterns : (& patterns ast.AstPatternList)]
  [locals : sym_i64_env.SymI64Env]
  [index : i64]) : sym_i64_env.SymI64Env
  (if (>= index patterns.len)
    locals
    (compiler-load-session-state-lazy-pattern-list-locals-at
      state
      patterns
      (compiler-load-session-state-lazy-pattern-locals
        state
        (ast.ast-pattern-list-get patterns index (ast.ast-pattern-fallback))
        locals)
      (+ index 1))))

(define (compiler-load-session-state-lazy-pattern-list-locals
  [state : (& state CompilerLoadSessionState)]
  [patterns : ast.AstPatternList]
  [locals : sym_i64_env.SymI64Env]) : sym_i64_env.SymI64Env
  (compiler-load-session-state-lazy-pattern-list-locals-at
    state
    (& patterns)
    locals
    0))

(define (compiler-load-session-state-lazy-expr-list-demand
  [state : CompilerLoadSessionState]
  [exprs : ast.AstExprList]
  [alias : i64]
  [summary : (& summary CompilerLoadSurfaceSummary)]
  [locals : sym_i64_env.SymI64Env]) : CompilerLoadLazyAliasDemand
  (ast.ast-expr-list-fold
    exprs
    compiler-load-lazy-alias-demand-merge
    (compiler-load-lazy-alias-demand-none)
    compiler-load-lazy-expr-demand-hook
    (owned_view.compiler-owned-shared-view state)
    alias
    summary
    locals))

(define (compiler-load-session-state-lazy-let-bindings-demand-at?
  [state : CompilerLoadSessionState]
  [bindings : (& bindings ast.AstLetBindingList)]
  [alias : i64]
  [summary : (& summary CompilerLoadSurfaceSummary)]
  [locals : sym_i64_env.SymI64Env]
  [index : i64]) : CompilerLoadLazyAliasDemand
  (if (>= index (ast.ast-let-binding-list-len bindings))
    (compiler-load-lazy-alias-demand-none)
    (match (ast.ast-let-binding-list-get
      bindings
      index
      (ast.ast-let-binding-fallback))
      [(Binding name maybe-ty init)
        (compiler-load-lazy-alias-demand-merge
          (compiler-load-session-state-lazy-maybe-type-demand
            (owned_view.compiler-owned-shared-view state)
            maybe-ty
            alias
            summary
            locals)
          (compiler-load-lazy-alias-demand-merge
            (compiler-load-session-state-lazy-expr-demand
              (owned_view.compiler-owned-shared-view state)
              init
              alias
              summary
              locals)
            (compiler-load-session-state-lazy-let-bindings-demand-at?
              (owned_view.compiler-owned-shared-view state)
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
  [state : (& state CompilerLoadSessionState)]
  [bindings : (& bindings ast.AstLetBindingList)]
  [locals : sym_i64_env.SymI64Env]
  [index : i64]) : sym_i64_env.SymI64Env
  (if (>= index (ast.ast-let-binding-list-len bindings))
    locals
    (match (ast.ast-let-binding-list-get
      bindings
      index
      (ast.ast-let-binding-fallback))
      [(Binding name _ _)
        (compiler-load-session-state-lazy-let-bindings-locals-at
          state
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
  [summary : (& summary CompilerLoadSurfaceSummary)]
  [locals : sym_i64_env.SymI64Env]
  [index : i64]) : CompilerLoadLazyAliasDemand
  (if (>= index (ast.ast-match-arm-list-len arms))
    (compiler-load-lazy-alias-demand-none)
    (match (ast.ast-match-arm-list-get arms index (ast.ast-match-arm-fallback))
      [(Arm pattern body)
        (compiler-load-lazy-alias-demand-merge
          (compiler-load-session-state-lazy-pattern-demand
            (owned_view.compiler-owned-shared-view state)
            (clone pattern)
            alias
            summary
            locals)
          (compiler-load-lazy-alias-demand-merge
            (compiler-load-session-state-lazy-expr-demand
              (owned_view.compiler-owned-shared-view state)
              body
              alias
              summary
              (compiler-load-session-state-lazy-pattern-locals
                state
                pattern
                locals))
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
  [summary : (& summary CompilerLoadSurfaceSummary)]
  [locals : sym_i64_env.SymI64Env]) : CompilerLoadLazyAliasDemand
  (compiler-load-session-state-lazy-match-arms-demand-at?
    state
    (& arms)
    alias
    summary
    locals
    0))

;; AstExpr child schema hooks take the walk's contexts first and the child last.
(defmacro (compiler-load-lazy-expr-demand-hook
  [state : Expr]
  [alias : Expr]
  [summary : Expr]
  [locals : Expr]
  [node-id : Expr]) : Expr
  `(compiler-load-session-state-lazy-expr-demand
    ,state
    ,node-id
    ,alias
    ,summary
    ,locals))

(defmacro (compiler-load-lazy-type-id-demand-hook
  [state : Expr]
  [alias : Expr]
  [summary : Expr]
  [locals : Expr]
  [type-id : Expr]) : Expr
  `(compiler-load-session-state-lazy-type-id-demand
    ,state
    ,type-id
    ,alias
    ,summary
    ,locals))

(defmacro (compiler-load-lazy-type-demand-hook
  [state : Expr]
  [alias : Expr]
  [summary : Expr]
  [locals : Expr]
  [ty : Expr]) : Expr
  `(compiler-load-session-state-lazy-type-demand
    ,state
    ,ty
    ,alias
    ,summary
    ,locals))

(defmacro (compiler-load-lazy-pattern-demand-hook
  [state : Expr]
  [alias : Expr]
  [summary : Expr]
  [locals : Expr]
  [pattern : Expr]) : Expr
  `(compiler-load-session-state-lazy-pattern-demand
    ,state
    ,pattern
    ,alias
    ,summary
    ,locals))

(define (compiler-load-session-state-lazy-expr-demand
  [state : CompilerLoadSessionState]
  [node-id : i64]
  [alias : i64]
  [summary : (& summary CompilerLoadSurfaceSummary)]
  [locals : sym_i64_env.SymI64Env]) : CompilerLoadLazyAliasDemand
  ;; Names, binders and quoted syntax are resolved here; the other ordinary
  ;; forms merge their children's demand through the AstExpr child schema.
  (match (ast.ast-node-get node-id)
    [(Var name)
      (compiler-load-session-state-lazy-name-demand
        state
        name
        alias
        summary
        locals)]
    [(Let let-box)
      (match (__tl-box-place let-box)
        [(Let bindings body)
          (compiler-load-lazy-alias-demand-merge
            (compiler-load-session-state-lazy-let-bindings-demand-at?
              (owned_view.compiler-owned-shared-view state)
              (& bindings)
              alias
              summary
              locals
              0)
            (compiler-load-session-state-lazy-expr-demand
              (owned_view.compiler-owned-shared-view state)
              body
              alias
              summary
              (compiler-load-session-state-lazy-let-bindings-locals-at
                state
                (& bindings)
                locals
                0)))])]
    [(Lambda lambda-box)
      (match (__tl-box-place lambda-box)
        [(Lambda params ret body)
          (compiler-load-lazy-alias-demand-merge
            (compiler-load-session-state-lazy-param-list-demand
              (owned_view.compiler-owned-shared-view state)
              params
              alias
              summary
              locals)
            (compiler-load-lazy-alias-demand-merge
              (compiler-load-session-state-lazy-maybe-type-demand
                (owned_view.compiler-owned-shared-view state)
                ret
                alias
                summary
                locals)
              (compiler-load-session-state-lazy-expr-demand
                (owned_view.compiler-owned-shared-view state)
                body
                alias
                summary
                (compiler-load-session-state-lazy-param-list-locals
                  state
                  params
                  locals))))])]
    [(Set target value)
      (compiler-load-lazy-alias-demand-merge
        (compiler-load-session-state-lazy-name-demand
          (owned_view.compiler-owned-shared-view state)
          target
          alias
          summary
          locals)
        (compiler-load-session-state-lazy-expr-demand
          state
          value
          alias
          summary
          locals))]
    [(Match match-box)
      (match (__tl-box-place match-box)
        [(Match scrutinee arms)
          (compiler-load-lazy-alias-demand-merge
            (compiler-load-session-state-lazy-expr-demand
              (owned_view.compiler-owned-shared-view state)
              scrutinee
              alias
              summary
              locals)
            (compiler-load-session-state-lazy-match-arms-demand
              state
              arms
              alias
              summary
              locals))])]
    [(Foreach foreach-box)
      (match (__tl-box-place foreach-box)
        [(Foreach index ty start end body)
          (compiler-load-lazy-alias-demand-merge
            (compiler-load-session-state-lazy-type-demand
              (owned_view.compiler-owned-shared-view state)
              ty
              alias
              summary
              locals)
            (compiler-load-lazy-alias-demand-merge
              (compiler-load-session-state-lazy-expr-demand
                (owned_view.compiler-owned-shared-view state)
                start
                alias
                summary
                locals)
              (compiler-load-lazy-alias-demand-merge
                (compiler-load-session-state-lazy-expr-demand
                  (owned_view.compiler-owned-shared-view state)
                  end
                  alias
                  summary
                  locals)
                (compiler-load-session-state-lazy-expr-demand
                  (owned_view.compiler-owned-shared-view state)
                  body
                  alias
                  summary
                  (if (compiler-load-session-state-lazy-qualified-observer-exhaustive?
                    state)
                    (compiler-load-session-state-lazy-demand-bind-local-exhaustive
                      state
                      locals
                      index)
                    (sym_i64_env.sym-i64-bind-id locals index 1))))))]
        [(Foreach2
            outer
            outer-ty
            outer-start
            outer-end
            inner
            inner-ty
            inner-start
            inner-end
            body)
          (let
            [outer-locals : sym_i64_env.SymI64Env
              (if (compiler-load-session-state-lazy-qualified-observer-exhaustive?
                state)
                (compiler-load-session-state-lazy-demand-bind-local-exhaustive
                  state
                  locals
                  outer)
                (sym_i64_env.sym-i64-bind-id locals outer 1))]
            [body-locals : sym_i64_env.SymI64Env
              (if (compiler-load-session-state-lazy-qualified-observer-exhaustive?
                state)
                (compiler-load-session-state-lazy-demand-bind-local-exhaustive
                  state
                  outer-locals
                  inner)
                (sym_i64_env.sym-i64-bind-id outer-locals inner 1))]
            (compiler-load-lazy-alias-demand-merge
              (compiler-load-session-state-lazy-type-demand
                (owned_view.compiler-owned-shared-view state)
                outer-ty
                alias
                summary
                locals)
              (compiler-load-lazy-alias-demand-merge
                (compiler-load-session-state-lazy-type-demand
                  (owned_view.compiler-owned-shared-view state)
                  inner-ty
                  alias
                  summary
                  locals)
                (compiler-load-lazy-alias-demand-merge
                  (compiler-load-session-state-lazy-expr-demand
                    (owned_view.compiler-owned-shared-view state)
                    outer-start
                    alias
                    summary
                    locals)
                  (compiler-load-lazy-alias-demand-merge
                    (compiler-load-session-state-lazy-expr-demand
                      (owned_view.compiler-owned-shared-view state)
                      outer-end
                      alias
                      summary
                      locals)
                    (compiler-load-lazy-alias-demand-merge
                      (compiler-load-session-state-lazy-expr-demand
                        (owned_view.compiler-owned-shared-view state)
                        inner-start
                        alias
                        summary
                        locals)
                      (compiler-load-lazy-alias-demand-merge
                        (compiler-load-session-state-lazy-expr-demand
                          (owned_view.compiler-owned-shared-view state)
                          inner-end
                          alias
                          summary
                          locals)
                        (compiler-load-session-state-lazy-expr-demand
                          state
                          body
                          alias
                          summary
                          body-locals))))))))])]
    [(ForeachActive lane body)
      (compiler-load-session-state-lazy-expr-demand
        (owned_view.compiler-owned-shared-view state)
        body
        alias
        summary
        (if (compiler-load-session-state-lazy-qualified-observer-exhaustive?
          state)
          (compiler-load-session-state-lazy-demand-bind-local-exhaustive
            state
            locals
            lane)
          (sym_i64_env.sym-i64-bind-id locals lane 1)))]
    [(SpmdReduce reduce-box)
      (match (__tl-box-place reduce-box)
        [(Reduce _ index ty start end init value)
          (compiler-load-lazy-alias-demand-merge
            (compiler-load-session-state-lazy-type-demand
              (owned_view.compiler-owned-shared-view state)
              ty
              alias
              summary
              locals)
            (compiler-load-lazy-alias-demand-merge
              (compiler-load-session-state-lazy-expr-demand
                (owned_view.compiler-owned-shared-view state)
                start
                alias
                summary
                locals)
              (compiler-load-lazy-alias-demand-merge
                (compiler-load-session-state-lazy-expr-demand
                  (owned_view.compiler-owned-shared-view state)
                  end
                  alias
                  summary
                  locals)
                (compiler-load-lazy-alias-demand-merge
                  (compiler-load-session-state-lazy-expr-demand
                    (owned_view.compiler-owned-shared-view state)
                    init
                    alias
                    summary
                    locals)
                  (compiler-load-session-state-lazy-expr-demand
                    (owned_view.compiler-owned-shared-view state)
                    value
                    alias
                    summary
                    (if (compiler-load-session-state-lazy-qualified-observer-exhaustive?
                      state)
                      (compiler-load-session-state-lazy-demand-bind-local-exhaustive
                        state
                        locals
                        index)
                      (sym_i64_env.sym-i64-bind-id locals index 1)))))))])]
    [(SpmdScan scan-box)
      (match (__tl-box-place scan-box)
        [(Scan _ index ty start end prefix _ init value body)
          (let
            [value-locals : sym_i64_env.SymI64Env
              (if (compiler-load-session-state-lazy-qualified-observer-exhaustive?
                state)
                (compiler-load-session-state-lazy-demand-bind-local-exhaustive
                  state
                  locals
                  index)
                (sym_i64_env.sym-i64-bind-id locals index 1))]
            [body-locals : sym_i64_env.SymI64Env
              (if (compiler-load-session-state-lazy-qualified-observer-exhaustive?
                state)
                (compiler-load-session-state-lazy-demand-bind-local-exhaustive
                  state
                  value-locals
                  prefix)
                (sym_i64_env.sym-i64-bind-id value-locals prefix 1))]
            (compiler-load-lazy-alias-demand-merge
              (compiler-load-session-state-lazy-type-demand
                (owned_view.compiler-owned-shared-view state)
                ty
                alias
                summary
                locals)
              (compiler-load-lazy-alias-demand-merge
                (compiler-load-session-state-lazy-expr-demand
                  (owned_view.compiler-owned-shared-view state)
                  start
                  alias
                  summary
                  locals)
                (compiler-load-lazy-alias-demand-merge
                  (compiler-load-session-state-lazy-expr-demand
                    (owned_view.compiler-owned-shared-view state)
                    end
                    alias
                    summary
                    locals)
                  (compiler-load-lazy-alias-demand-merge
                    (compiler-load-session-state-lazy-expr-demand
                      (owned_view.compiler-owned-shared-view state)
                      init
                      alias
                      summary
                      locals)
                    (compiler-load-lazy-alias-demand-merge
                      (compiler-load-session-state-lazy-expr-demand
                        (owned_view.compiler-owned-shared-view state)
                        value
                        alias
                        summary
                        value-locals)
                      (compiler-load-session-state-lazy-expr-demand
                        state
                        body
                        alias
                        summary
                        body-locals)))))))])]
    [(SpmdCompact compact-box)
      (match (__tl-box-place compact-box)
        [(Compact index index-ty start end slot slot-ty init keep body)
          (let
            [keep-locals : sym_i64_env.SymI64Env
              (if (compiler-load-session-state-lazy-qualified-observer-exhaustive?
                state)
                (compiler-load-session-state-lazy-demand-bind-local-exhaustive
                  state
                  locals
                  index)
                (sym_i64_env.sym-i64-bind-id locals index 1))]
            [body-locals : sym_i64_env.SymI64Env
              (if (compiler-load-session-state-lazy-qualified-observer-exhaustive?
                state)
                (compiler-load-session-state-lazy-demand-bind-local-exhaustive
                  state
                  keep-locals
                  slot)
                (sym_i64_env.sym-i64-bind-id keep-locals slot 1))]
            (compiler-load-lazy-alias-demand-merge
              (compiler-load-session-state-lazy-type-demand
                (owned_view.compiler-owned-shared-view state)
                index-ty
                alias
                summary
                locals)
              (compiler-load-lazy-alias-demand-merge
                (compiler-load-session-state-lazy-type-demand
                  (owned_view.compiler-owned-shared-view state)
                  slot-ty
                  alias
                  summary
                  locals)
                (compiler-load-lazy-alias-demand-merge
                  (compiler-load-session-state-lazy-expr-demand
                    (owned_view.compiler-owned-shared-view state)
                    start
                    alias
                    summary
                    locals)
                  (compiler-load-lazy-alias-demand-merge
                    (compiler-load-session-state-lazy-expr-demand
                      (owned_view.compiler-owned-shared-view state)
                      end
                      alias
                      summary
                      locals)
                    (compiler-load-lazy-alias-demand-merge
                      (compiler-load-session-state-lazy-expr-demand
                        (owned_view.compiler-owned-shared-view state)
                        init
                        alias
                        summary
                        locals)
                      (compiler-load-lazy-alias-demand-merge
                        (compiler-load-session-state-lazy-expr-demand
                          (owned_view.compiler-owned-shared-view state)
                          keep
                          alias
                          summary
                          keep-locals)
                        (compiler-load-session-state-lazy-expr-demand
                          state
                          body
                          alias
                          summary
                          body-locals))))))))])]
    [(Comptime inner)
      (if (compiler-load-session-state-lazy-qualified-observer-exhaustive?
        state)
        (compiler-load-session-state-lazy-expr-demand
          state
          inner
          alias
          summary
          locals)
        (compiler-load-lazy-alias-demand-unknown))]
    [(Quote inner)
      (if (compiler-load-session-state-lazy-qualified-observer-exhaustive?
        state)
        (compiler-load-session-state-lazy-expr-demand
          state
          inner
          alias
          summary
          locals)
        (compiler-load-lazy-alias-demand-unknown))]
    [(Quasiquote inner)
      (if (compiler-load-session-state-lazy-qualified-observer-exhaustive?
        state)
        (compiler-load-session-state-lazy-expr-demand
          state
          inner
          alias
          summary
          locals)
        (compiler-load-lazy-alias-demand-unknown))]
    [(Unquote inner)
      (if (compiler-load-session-state-lazy-qualified-observer-exhaustive?
        state)
        (compiler-load-session-state-lazy-expr-demand
          state
          inner
          alias
          summary
          locals)
        (compiler-load-lazy-alias-demand-unknown))]
    [(UnquoteSplicing inner)
      (if (compiler-load-session-state-lazy-qualified-observer-exhaustive?
        state)
        (compiler-load-session-state-lazy-expr-demand
          state
          inner
          alias
          summary
          locals)
        (compiler-load-lazy-alias-demand-unknown))]
    ;; Macro-generated and uncommon AST shapes are an explicit eager fence.
    [(MacroExpansion _ _ _) (compiler-load-lazy-alias-demand-unknown)]
    [(ArrayTake _ _ _) (compiler-load-lazy-alias-demand-unknown)]
    [(WithRegion _ _) (compiler-load-lazy-alias-demand-unknown)]
    [(WithResource _) (compiler-load-lazy-alias-demand-unknown)]
    [(BracketClause _) (compiler-load-lazy-alias-demand-unknown)]
    [(PtrAddrOf _) (compiler-load-lazy-alias-demand-unknown)]
    [(PtrRead _) (compiler-load-lazy-alias-demand-unknown)]
    [(PtrWrite _ _) (compiler-load-lazy-alias-demand-unknown)]
    [(PtrOffset _ _) (compiler-load-lazy-alias-demand-unknown)]
    [(PtrCast _ _) (compiler-load-lazy-alias-demand-unknown)]
    [(PtrToInt _) (compiler-load-lazy-alias-demand-unknown)]
    [(IntToPtr _ _) (compiler-load-lazy-alias-demand-unknown)]
    [(StringData _) (compiler-load-lazy-alias-demand-unknown)]
    [(StringFromBytes _ _) (compiler-load-lazy-alias-demand-unknown)]
    [(ArrayData _) (compiler-load-lazy-alias-demand-unknown)]
    [(CpuIdEax _ _) (compiler-load-lazy-alias-demand-unknown)]
    [(CpuIdEbx _ _) (compiler-load-lazy-alias-demand-unknown)]
    [(CpuIdEcx _ _) (compiler-load-lazy-alias-demand-unknown)]
    [(CpuIdEdx _ _) (compiler-load-lazy-alias-demand-unknown)]
    [(Xgetbv _) (compiler-load-lazy-alias-demand-unknown)]
    [(Syscall _) (compiler-load-lazy-alias-demand-unknown)]
    [(ForOwnedState _) (compiler-load-lazy-alias-demand-unknown)]
    [(ForOwnedStep _) (compiler-load-lazy-alias-demand-unknown)]
    [_
      (ast.ast-expr-fold-children
        (ast.ast-node-get node-id)
        compiler-load-lazy-alias-demand-merge
        (compiler-load-lazy-alias-demand-none)
        compiler-load-lazy-expr-demand-hook
        compiler-load-lazy-type-id-demand-hook
        compiler-load-lazy-type-demand-hook
        compiler-load-lazy-pattern-demand-hook
        (owned_view.compiler-owned-shared-view state)
        alias
        summary
        locals)]))

(define (compiler-load-session-state-lazy-module-macro-demand
  [state : CompilerLoadSessionState]
  [call-id : i64]
  [alias : i64]
  [summary : (& summary CompilerLoadSurfaceSummary)]
  [locals : sym_i64_env.SymI64Env]) : CompilerLoadLazyAliasDemand
  ;; A module macro can introduce declarations that are not visible in the
  ;; static surface. If its direct macro name belongs to this import (through
  ;; either its local alias or canonical module ID), retain the source module
  ;; instead of assuming a later typechecker fast path can materialize it.
  ;; This keeps arbitrary generated-module macros correct.
  (let
    [spanned : i64 (ast.ast-expr-span-wrapper-inner call-id)]
    (if (>= spanned 0)
      (compiler-load-session-state-lazy-module-macro-demand
        state
        spanned
        alias
        summary
        locals)
      (match (ast.ast-node-get call-id)
        [(Call func args)
          (let
            [function-demand : CompilerLoadLazyAliasDemand
              (compiler-load-session-state-lazy-module-macro-demand
                (owned_view.compiler-owned-shared-view state)
                func
                alias
                summary
                locals)]
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
        [(Var name)
          (let
            [name-demand : CompilerLoadLazyAliasDemand
              (compiler-load-session-state-lazy-name-demand
                (owned_view.compiler-owned-shared-view state)
                name
                alias
                summary
                locals)]
            (if (or
              name-demand.direct
              (compiler-load-session-state-lazy-name-qualified-by-id?
                state
                name
                summary.module-id))
              (compiler-load-lazy-alias-demand-unknown)
              name-demand))]
        [_ (compiler-load-lazy-alias-demand-unknown)]))))

(define (compiler-load-lazy-module-macro-qualified-by?
  [state : CompilerLoadSessionState]
  [call-id : i64]
  [module-id : i64]) : bool
  ;; A moduleless source file has a path-derived summary ID, but a caller can
  ;; still invoke its macro through the canonical dotted import ID. Keep that
  ;; import loaded when the macro target uses that spelling.
  (let
    [spanned : i64 (ast.ast-expr-span-wrapper-inner call-id)]
    (if (>= spanned 0)
      (compiler-load-lazy-module-macro-qualified-by? state spanned module-id)
      (match (ast.ast-node-get call-id)
        [(Call func _)
          (compiler-load-lazy-module-macro-qualified-by? state func module-id)]
        [(Var name)
          (compiler-load-session-state-lazy-name-qualified-by-id?
            state
            name
            module-id)]
        [_ false]))))

(define (compiler-load-lazy-decl-module-macro-qualified-by?
  [state : CompilerLoadSessionState]
  [decl : ast.AstDecl]
  [module-id : i64]) : bool
  (match decl
    [(ModuleBody _ body)
      (compiler-load-lazy-decl-list-module-macro-qualified-by?
        state
        (deref body)
        module-id)]
    [(Import decl-meta (Spec (Macro call-expr _) _ _ _ _))
      (compiler-load-lazy-module-macro-qualified-by? state call-expr module-id)]
    [(Unsafe inner)
      (compiler-load-lazy-decl-module-macro-qualified-by?
        state
        (deref inner)
        module-id)]
    [_ false]))

(define (compiler-load-lazy-decl-list-module-macro-qualified-by?
  [state : CompilerLoadSessionState]
  [decls : ast.AstDeclList]
  [module-id : i64]) : bool
  (match (ast.ast-decl-list-step decls)
    [(Nil) false]
    [(Cons decl rest)
      (or
        (compiler-load-lazy-decl-module-macro-qualified-by?
          (owned_view.compiler-owned-shared-view state)
          decl
          module-id)
        (compiler-load-lazy-decl-list-module-macro-qualified-by?
          state
          rest
          module-id))]))

(define (compiler-load-session-state-lazy-generated-meta-demand
  [state : CompilerLoadSessionState]
  [meta : ast.AstGeneratedDeclMeta]
  [alias : i64]
  [summary : (& summary CompilerLoadSurfaceSummary)]
  [locals : sym_i64_env.SymI64Env]) : CompilerLoadLazyAliasDemand
  (match meta
    [(No) (compiler-load-lazy-alias-demand-none)]
    [(Some _ _ args _)
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
  [summary : (& summary CompilerLoadSurfaceSummary)]
  [locals : sym_i64_env.SymI64Env]) : CompilerLoadLazyAliasDemand
  (match decl
    [(Module _) (compiler-load-lazy-alias-demand-none)]
    [(ModuleBody _ body)
      (compiler-load-session-state-lazy-decl-list-demand
        state
        (deref body)
        alias
        summary
        locals)]
    [(Def decl-meta _ maybe-ty body)
      (compiler-load-lazy-alias-demand-merge
        (compiler-load-session-state-lazy-maybe-type-demand
          (owned_view.compiler-owned-shared-view state)
          maybe-ty
          alias
          summary
          locals)
        (compiler-load-session-state-lazy-expr-demand
          state
          body
          alias
          summary
          locals))]
    [(DefFn decl-meta _ params ret body _)
      (compiler-load-lazy-alias-demand-merge
        (compiler-load-session-state-lazy-param-list-demand
          (owned_view.compiler-owned-shared-view state)
          params
          alias
          summary
          locals)
        (compiler-load-lazy-alias-demand-merge
          (compiler-load-session-state-lazy-type-demand
            (owned_view.compiler-owned-shared-view state)
            ret
            alias
            summary
            locals)
          (compiler-load-session-state-lazy-expr-demand
            (owned_view.compiler-owned-shared-view state)
            body
            alias
            summary
            (compiler-load-session-state-lazy-param-list-locals
              state
              params
              locals))))]
    [(DefMacro decl-meta _ params ret body)
      (if (compiler-load-session-state-lazy-qualified-observer-exhaustive?
        state)
        (compiler-load-lazy-alias-demand-merge
          (compiler-load-session-state-lazy-macro-param-list-demand
            (owned_view.compiler-owned-shared-view state)
            params
            alias
            summary
            locals)
          (compiler-load-lazy-alias-demand-merge
            (compiler-load-session-state-lazy-type-demand
              (owned_view.compiler-owned-shared-view state)
              ret
              alias
              summary
              locals)
            (compiler-load-session-state-lazy-expr-demand
              (owned_view.compiler-owned-shared-view state)
              body
              alias
              summary
              (compiler-load-session-state-lazy-macro-param-list-locals
                state
                params
                locals))))
        (compiler-load-lazy-alias-demand-unknown))]
    [(Extern decl-meta _ _ _ ty)
      (if (compiler-load-session-state-lazy-qualified-observer-exhaustive?
        state)
        (compiler-load-session-state-lazy-type-demand
          state
          ty
          alias
          summary
          locals)
        (compiler-load-lazy-alias-demand-unknown))]
    [(DefEnum decl-meta _ _ variants)
      (if (compiler-load-session-state-lazy-qualified-observer-exhaustive?
        state)
        (compiler-load-session-state-lazy-variant-list-demand
          state
          variants
          alias
          summary
          locals)
        (compiler-load-lazy-alias-demand-unknown))]
    [(DefEnumLifetimes decl-meta _ _ _ variants)
      (if (compiler-load-session-state-lazy-qualified-observer-exhaustive?
        state)
        (compiler-load-session-state-lazy-variant-list-demand
          state
          variants
          alias
          summary
          locals)
        (compiler-load-lazy-alias-demand-unknown))]
    [(DefStruct decl-meta _ _ _ fields)
      (if (compiler-load-session-state-lazy-qualified-observer-exhaustive?
        state)
        (compiler-load-session-state-lazy-field-list-demand
          state
          fields
          alias
          summary
          locals)
        (compiler-load-lazy-alias-demand-unknown))]
    [(DefStructLifetimes decl-meta _ _ _ _ fields)
      (if (compiler-load-session-state-lazy-qualified-observer-exhaustive?
        state)
        (compiler-load-session-state-lazy-field-list-demand
          state
          fields
          alias
          summary
          locals)
        (compiler-load-lazy-alias-demand-unknown))]
    [(Import decl-meta (Spec (Macro call-expr _) _ _ _ _))
      (compiler-load-session-state-lazy-module-macro-demand
        state
        call-expr
        alias
        summary
        locals)]
    [(Import decl-meta (Spec (MacroDecls _ _) _ _ _ _))
      (compiler-load-lazy-alias-demand-unknown)]
    [(Import decl-meta _) (compiler-load-lazy-alias-demand-none)]
    [(Test _ body _ _)
      (compiler-load-session-state-lazy-expr-demand
        state
        body
        alias
        summary
        locals)]
    [(Unsafe inner)
      ;; ast-decl-comptime-only? and ast-decl-generated-meta recurse through
      ;; Unsafe, so the outer dispatcher has already accounted for metadata.
      (compiler-load-session-state-lazy-decl-demand-inner
        state
        (deref inner)
        alias
        summary
        locals)]
    [(DefDispatch decl-meta _ _) (compiler-load-lazy-alias-demand-none)]
    [(IncludeStr _ _) (compiler-load-lazy-alias-demand-none)]
    [(IncludeStrComptime _ _) (compiler-load-lazy-alias-demand-none)]
    [(IncludeStrLzss _ _) (compiler-load-lazy-alias-demand-none)]
    [(IncludeBin _ _) (compiler-load-lazy-alias-demand-none)]
    ;; A future declaration shape might hide references. Keep it conservative.
    [_ (compiler-load-lazy-alias-demand-unknown)]))

(define (compiler-load-session-state-lazy-decl-demand
  [state : CompilerLoadSessionState]
  [decl : ast.AstDecl]
  [alias : i64]
  [summary : (& summary CompilerLoadSurfaceSummary)]
  [locals : sym_i64_env.SymI64Env]) : CompilerLoadLazyAliasDemand
  (if (ast.ast-decl-comptime-only? decl)
    (if (compiler-load-session-state-lazy-qualified-observer-exhaustive? state)
      (compiler-load-lazy-alias-demand-merge
        (compiler-load-session-state-lazy-generated-meta-demand
          (owned_view.compiler-owned-shared-view state)
          (ast.ast-decl-generated-meta decl)
          alias
          summary
          locals)
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
  [summary : (& summary CompilerLoadSurfaceSummary)]
  [locals : sym_i64_env.SymI64Env]) : CompilerLoadLazyAliasDemand
  (match (ast.ast-decl-list-step decls)
    [(Nil) (compiler-load-lazy-alias-demand-none)]
    [(Cons decl rest)
      (let
        [head : CompilerLoadLazyAliasDemand
          (compiler-load-session-state-lazy-decl-demand
            (owned_view.compiler-owned-shared-view state)
            decl
            alias
            summary
            locals)]
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
        [(Some alias-name)
          (let
            [bound-6 (compiler-load-lazy-empty-surface-summary)]
            (compiler-load-session-state-lazy-decl-list-demand
              state
              rest
              alias-name
              bound-6
              (sym_i64_env.sym-i64-empty)))]
        [(No) (compiler-load-lazy-alias-demand-none)])
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
      [(Module) true]
      [_ false])
    (match alias
      [(Some _) true]
      [(No) false])))

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
  [summary : (& summary CompilerLoadSurfaceSummary)]
  [_resolved : String]
  [stdlib-roots : svec.Vec]) : bool
  (and
    (not summary.explicit-module)
    (not (compiler-load-stdlib-import? summary.source-path))
    (not
      (compiler-load-path-under-roots-from?
        ;; The summary retains the normalized spelling for this resolved ID.
        ;; Reuse it instead of rebuilding the same owner for every lazy check.
        summary.source-path
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
          (owned_view.compiler-owned-shared-view load-state)))
      (compiler-load-prelude-importer? importer-path))
      false
      (match (compiler-load-session-state-surface-summary-find-source
        load-state
        resolved-id)
        [(CompilerLoadNoSurfaceSummary) false]
        [(CompilerLoadSomeSurfaceSummary summary)
          (if (compiler-load-lazy-import-include-semantics?
            summary
            (string.copy resolved)
            stdlib-roots)
            false
            (let
              [policy : CompilerLoadLazyImportPolicy summary.lazy-policy]
              (match kind
                [(Module)
                  (if (compiler-load-lazy-decl-list-module-macro-qualified-by?
                    (owned_view.compiler-owned-shared-view load-state)
                    (ast.ast-place-shared-view rest)
                    (match expected-module
                      [(Some module-id) module-id]
                      [(No) summary.module-id]))
                    false
                    (match alias
                      [(Some alias-name)
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
                      [(No) false]))]
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
    [(No) (CompilerLoadSurfaceNoString)]
    [(Some name) (CompilerLoadSurfaceSomeString (ci.intern-str name))]))

(define (compiler-load-surface-alias-maybe [alias : ast.AstMaybeImportAlias]) : CompilerLoadSurfaceMaybeString
  (match alias
    [(No) (CompilerLoadSurfaceNoString)]
    [(Some name) (CompilerLoadSurfaceSomeString (ci.intern-str name))]))

(define (compiler-load-surface-import-kind [kind : ast.AstImportKind]) : CompilerLoadSurfaceImportKind
  (match kind
    [(Module) (CompilerLoadSurfaceImportModule)]
    [(ModuleAll) (CompilerLoadSurfaceImportModule)]
    [(ModuleItem _) (CompilerLoadSurfaceImportModule)]
    [(Macro _ _) (CompilerLoadSurfaceImportMacro)]
    [(MacroDecls _ _) (CompilerLoadSurfaceImportMacroDecls)]))

(define (compiler-load-surface-import-decl-emitting? [kind : ast.AstImportKind]) : bool
  (match kind
    [(MacroDecls _ _) true]
    [_ false]))

(define (compiler-load-surface-import-default-alias
  [kind : ast.AstImportKind]
  [import-path : String]) : CompilerLoadSurfaceMaybeString
  (match kind
    [(Module)
      (CompilerLoadSurfaceSomeString
        (parser.parse-ast-dotted-import-default-alias import-path))]
    [_ (CompilerLoadSurfaceNoString)]))

(define (compiler-load-surface-macro-result-kind [ret : ast.AstType]) : CompilerLoadSurfaceMacroResultKind
  (match ret
    [(Expr) (CompilerLoadSurfaceMacroExpr)]
    [(Var name)
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
    [(No) false]
    [(Export _) true]))

(define (compiler-load-surface-generated-meta?
  [meta : ast.AstGeneratedDeclMeta]) : bool
  (match meta
    [(No) false]
    [(Some _ _ _ _) true]))

(define (compiler-load-surface-field-list-cleanup?
  [fields : (& fields ast.AstFieldDefList)]) : bool
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
      [(Def _ _ cleanup)
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
  [variants : (& variants ast.AstVariantDefList)]) : bool
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
      [(Def _ _ cleanups)
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
    [(Import _ _) (CompilerLoadSurfaceCounts 1 0)]
    [(Unsafe inner-box) (compiler-load-surface-count-decl (deref inner-box))]
    [(ModuleBody _ body-box)
      (compiler-load-surface-count-decls (deref body-box))]
    [(Module _) (CompilerLoadSurfaceCounts 0 0)]
    [_ (CompilerLoadSurfaceCounts 0 1)]))

(define (compiler-load-surface-count-decls [decls : ast.AstDeclList]) : CompilerLoadSurfaceCounts
  (match (ast.ast-decl-list-step decls)
    [(Nil) (CompilerLoadSurfaceCounts 0 0)]
    [(Cons decl rest)
      (compiler-load-surface-counts-add
        (compiler-load-surface-count-decl decl)
        (compiler-load-surface-count-decls rest))]))

(define (compiler-load-surface-build-empty [counts : CompilerLoadSurfaceCounts]) : CompilerLoadSurfaceBuild
  (CompilerLoadSurfaceBuild
    (__tl_make-array CompilerLoadSurfaceImport counts.imports)
    0
    (__tl_make-array CompilerLoadSurfaceDecl counts.decls)
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
    (set! (array-ref build.import-slots index) import-edge)
    (CompilerLoadSurfaceBuild
      build.import-slots
      (+ index 1)
      build.decl-slots
      build.decl-len
      build.has-tests
      build.has-export-metadata
      build.has-generated-decls
      (or build.has-decl-emitting-macro decl-emitting))))

(define (compiler-load-surface-build-add-decl
  [build : CompilerLoadSurfaceBuild]
  [decl : CompilerLoadSurfaceDecl]
  [has-test : bool]
  [has-export : bool]
  [has-generated : bool]
  [decl-emitting : bool]) : CompilerLoadSurfaceBuild
  (let
    [index : i64 build.decl-len]
    (set! (array-ref build.decl-slots index) decl)
    (CompilerLoadSurfaceBuild
      build.import-slots
      build.import-len
      build.decl-slots
      (+ index 1)
      (or build.has-tests has-test)
      (or build.has-export-metadata has-export)
      (or build.has-generated-decls has-generated)
      (or build.has-decl-emitting-macro decl-emitting))))

(define (compiler-load-surface-build-decl-inner
  [source-path : String]
  [module-id : i64]
  [decl : ast.AstDecl]
  [generated : bool]
  [was-unsafe : bool]
  [build : CompilerLoadSurfaceBuild]) : CompilerLoadSurfaceBuild
  (match decl
    [(Import decl-meta (Spec kind import-path module-name alias span))
      (compiler-load-surface-build-add-import
        build
        (CompilerLoadSurfaceImport
          (compiler-load-surface-import-kind kind)
          module-id
          source-path
          (string.copy import-path)
          (compiler-load-surface-module-maybe module-name)
          (compiler-load-surface-alias-maybe alias)
          (compiler-load-surface-import-default-alias kind import-path)
          (clone (__tl-box-place span)))
        (compiler-load-surface-import-decl-emitting? kind))]
    [(Def decl-meta name maybe-ty _)
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
    [(DefFn decl-meta name params ret _ metadata)
      (let
        [has-export : bool
          (compiler-load-surface-fn-export?
            (ast.ast-fn-metadata-export (& metadata)))]
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
    [(Extern decl-meta name kind meta ty)
      (compiler-load-surface-build-add-decl
        build
        (CompilerLoadSurfaceDecl
          (CompilerLoadSurfaceExtern)
          name
          module-id
          (CompilerLoadSurfaceExternSignature kind (deref meta) ty)
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
    [(DefStruct decl-meta name repr cleanup fields)
      (let
        [has-cleanup : bool
          (or
            (ast.ast-struct-cleanup? cleanup)
            (compiler-load-surface-field-list-cleanup? fields))]
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
              (ast.ast-decl-meta-aggregate-markers (& decl-meta))
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
    [(DefStructLifetimes decl-meta name lifetimes repr cleanup fields)
      (let
        [has-cleanup : bool
          (or
            (ast.ast-struct-cleanup? cleanup)
            (compiler-load-surface-field-list-cleanup? fields))]
        (compiler-load-surface-build-add-decl
          build
          (CompilerLoadSurfaceDecl
            (CompilerLoadSurfaceStruct)
            name
            module-id
            (CompilerLoadSurfaceStructSignature
              lifetimes
              repr
              cleanup
              (ast.ast-decl-meta-aggregate-markers (& decl-meta))
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
    [(DefEnum decl-meta name cleanup variants)
      (let
        [has-cleanup : bool
          (or
            (ast.ast-enum-cleanup? cleanup)
            (compiler-load-surface-variant-list-cleanup? variants))]
        (compiler-load-surface-build-add-decl
          build
          (CompilerLoadSurfaceDecl
            (CompilerLoadSurfaceEnum)
            name
            module-id
            (CompilerLoadSurfaceEnumSignature
              (ast.ast-lifetime-list-new)
              cleanup
              (ast.ast-decl-meta-aggregate-markers (& decl-meta))
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
    [(DefEnumLifetimes decl-meta name lifetimes cleanup variants)
      (let
        [has-cleanup : bool
          (or
            (ast.ast-enum-cleanup? cleanup)
            (compiler-load-surface-variant-list-cleanup? variants))]
        (compiler-load-surface-build-add-decl
          build
          (CompilerLoadSurfaceDecl
            (CompilerLoadSurfaceEnum)
            name
            module-id
            (CompilerLoadSurfaceEnumSignature
              lifetimes
              cleanup
              (ast.ast-decl-meta-aggregate-markers (& decl-meta))
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
    [(DefMacro decl-meta name params ret body-box)
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
    [(DefDispatch decl-meta name variants)
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
    [(Test name _ _ span)
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
    [(IncludeStr name _)
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
    [(IncludeStrComptime name _)
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
    [(IncludeStrLzss name _)
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
    [(IncludeBin name _)
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
    [(Unsafe inner-box)
      (compiler-load-surface-build-decl
        source-path
        module-id
        (deref inner-box)
        generated
        true
        build)]
    [(ModuleBody nested-module body-box)
      (compiler-load-surface-build-decls-into
        source-path
        nested-module
        (deref body-box)
        build)]
    [(Module _) build]
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
    [(Nil) build]
    [(Cons decl rest-box)
      (let
        [rest : ast.AstDeclList rest-box]
        (match (clone decl)
          [(Module next-module)
            (compiler-load-surface-build-decls-into
              (string.copy source-path)
              next-module
              rest
              build)]
          [(ModuleBody nested-module body-box)
            (compiler-load-surface-build-decls-into
              (string.copy source-path)
              module-id
              rest
              (compiler-load-surface-build-decls-into
                source-path
                nested-module
                (deref body-box)
                build))]
          [_
            (compiler-load-surface-build-decls-into
              (string.copy source-path)
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
      (compiler-load-surface-build-decls
        (string.copy source-path)
        module-id
        decls)]
    (CompilerLoadSurfaceSummary
      module-id
      declaration-module-id
      explicit-module
      qualified-load
      source-path-id
      source-path
      (compiler-load-normalize-path root-id)
      (CompilerLoadSurfaceImportList build.import-slots build.import-len)
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
    [(Program decls-box)
      (let
        [decls : ast.AstDeclList (deref decls-box)]
        [source-module : String
          (compiler-load-decls-source-module (ast.ast-place-shared-view decls))]
        (match (compiler-load-decls-module-id
          (string.copy path)
          (ast.ast-place-shared-view decls)
          fallback-id)
          [(Ok _ module-id)
            (let
              [_
                (try
                  (compiler-load-check-dotted-import-aliases
                    (string.copy path)
                    (ast.ast-place-shared-view decls)
                    source-module))]
              (Ok
                (compiler-load-surface-summary-from-decls
                  path
                  source-path-id
                  root-id
                  module-id
                  module-id
                  (compiler-load-decl-list-has-module? decls)
                  qualified-load
                  decls)))]
          [(Err diag) (Err diag)]))]))

(define (compiler-load-decl-defines-selected-item?
  [decl : ast.AstDecl]
  [item : i64]) : bool
  (match (ast.ast-decl-unwrapped (& decl))
    [(Def decl-meta name _ _) (= name item)]
    [(DefFn decl-meta name _ _ _ _) (= name item)]
    [(DefMacro decl-meta name _ _ _) (= name item)]
    [(DefDispatch decl-meta name _) (= name item)]
    [(Extern decl-meta name _ _ _) (= name item)]
    [(DefEnum decl-meta name _ variants)
      (or
        (= name item)
        (compiler-load-lazy-surface-variant-direct-name? variants item))]
    [(DefEnumLifetimes decl-meta name _ _ variants)
      (or
        (= name item)
        (compiler-load-lazy-surface-variant-direct-name? variants item))]
    [(DefStruct decl-meta name _ _ _) (= name item)]
    [(DefStructLifetimes decl-meta name _ _ _ _) (= name item)]
    [_ false]))

(define (compiler-load-module-defines-selected-item?
  [decls : ast.AstDeclList]
  [target-module : i64]
  [item : i64]) : bool
  (let
    [count : i64 (ast.ast-decl-list-len (& decls))]
    [cur-module : i64 cbi.compiler-builtin-id-fix-empty]
    [index : i64 0]
    (while (< index count)
      (let
        [decl : ast.AstDecl
          (ast.ast-array-shared-view decls.slots (+ decls.offset index))]
        (match (ast.ast-place-shared-view decl)
          [(Module next-module) (set! cur-module next-module)]
          [_
            (when
              (and
                (= cur-module target-module)
                (compiler-load-decl-defines-selected-item? decl item))
              (return true))])
        (set! index (+ index 1))))
    false))

(define (compiler-load-selected-item-present?
  [kind : ast.AstImportKind]
  [expected-module : ast.AstMaybeModuleName]
  [decls : ast.AstDeclList]) : bool
  (match kind
    [(ModuleItem item)
      (match expected-module
        [(Some target-module)
          (compiler-load-module-defines-selected-item? decls target-module item)]
        [(No) false])]
    [_ true]))

;; A module-scope generator parses as an import whose kind carries the macro
;; call. Until the fixed-point expansion has run it, the module's parsed
;; declarations are not its final export set.
(define (compiler-load-decl-pending-generator? [decl : ast.AstDecl]) : bool
  (match (ast.ast-decl-unwrapped (& decl))
    [(Import _ (Spec kind _ _ _ _))
      (match kind
        [(Macro _ _) true]
        [(MacroDecls _ _) true]
        [_ false])]
    [_ false]))

(define (compiler-load-module-has-pending-generator?
  [decls : ast.AstDeclList]
  [target-module : i64]) : bool
  (let
    [count : i64 (ast.ast-decl-list-len (& decls))]
    [cur-module : i64 cbi.compiler-builtin-id-fix-empty]
    [index : i64 0]
    (while (< index count)
      (let
        [decl : ast.AstDecl
          (ast.ast-array-shared-view decls.slots (+ decls.offset index))]
        (match (ast.ast-place-shared-view decl)
          [(Module next-module) (set! cur-module next-module)]
          [_
            (when
              (and
                (= cur-module target-module)
                (compiler-load-decl-pending-generator? decl))
              (return true))])
        (set! index (+ index 1))))
    false))

;; Load-time policy for both the source and the package walker. A selected item
;; missing from a module that still has a pending generator is not an error
;; yet: `compiler-load-check-expanded-unqualified-imports` requires every
;; selected item against the completed expansion, which always runs for a
;; program that contains a generator. A module without generators has its final
;; declarations now, so its missing items keep failing here.
(define (compiler-load-selected-item-present-or-pending?
  [kind : ast.AstImportKind]
  [expected-module : ast.AstMaybeModuleName]
  [decls : ast.AstDeclList]) : bool
  (if (compiler-load-selected-item-present?
    kind
    expected-module
    (ast.ast-place-shared-view decls))
    true
    (match kind
      [(ModuleItem _)
        (match expected-module
          [(Some target-module)
            (compiler-load-module-has-pending-generator? decls target-module)]
          [(No) false])]
      [_ false])))

(define (compiler-load-expected-module-seen?
  [seen : sym_i64_env.SymI64Env]
  [expected-module : ast.AstMaybeModuleName]) : bool
  (match expected-module
    [(Some module-id) (sym_i64_env.sym-i64-contains-id seen module-id)]
    [(No) false]))

(define (compiler-load-missing-selected-item-message
  [module-name : String]
  [kind : ast.AstImportKind]) : String
  (match kind
    [(ModuleItem item)
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
    [(Some _)
      (compiler-load-decl-list-prepend-from-source
        (Import
          (ast.ast-decl-meta-runtime-shared-view)
          (Spec kind import-path expected-module alias (box span)))
        source
        rest)]
    [(No) rest]))

(define (compiler-load-alias-path-list
  [importer-path : String]
  [importer-path-id : i64]
  [importer-decl-owner-id : i64]
  [alias : ast.AstMaybeImportAlias]
  [rest : ast.AstDeclPathList]) : ast.AstDeclPathList
  (match alias
    [(Some _)
      (ast.ast-decl-path-list-prepend-builder-with-owner-and-provenance-id
        importer-path
        importer-decl-owner-id
        importer-path-id
        rest)]
    [(No) rest]))

(define (compiler-load-alias-module-list
  [importer-module-id : i64]
  [alias : ast.AstMaybeImportAlias]
  [rest : ast.AstDeclModuleList]) : ast.AstDeclModuleList
  (match alias
    [(Some _)
      (ast.ast-decl-module-list-prepend-builder-id importer-module-id rest)]
    [(No) rest]))

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
        (string.copy importer-path)
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
  [imported-decls : (& imported-decls ast.AstDeclList)]
  [rest : ast.AstDeclModuleList]) : ast.AstDeclModuleList
  (let
    [after-alias : ast.AstDeclModuleList
      (compiler-load-alias-module-list importer-module-id alias rest)]
    (if (compiler-load-decl-list-has-module? imported-decls)
      (ast.ast-decl-module-list-prepend-builder-id
        importer-module-id
        after-alias)
      after-alias)))

;; A declaration is "ordinary" exactly when it reaches the `[_ ...]` arm of
;; `compiler-load-decls-with-module-and-roots-cfg-root-with-pools-at-special-head`
;; below: it is not a module body, an import, or one of the four include forms.
;; Ordinary declarations are nearly all of a module's top level and contribute
;; one row to each of the three output lists without touching `seen`, so
;; `compiler-load-decls-with-module-and-roots-cfg-root-with-pools` folds a whole
;; run of them in a loop. Keep the six constructors here and that match's arms in
;; sync; the arm order below mirrors the arm order there so they cannot drift.
(define (compiler-load-decl-ordinary? [decl : ast.AstDecl]) : bool
  (match decl
    [(ModuleBody _ _) false]
    [(Import _ _) false]
    [(IncludeStr _ _) false]
    [(IncludeStrComptime _ _) false]
    [(IncludeStrLzss _ _) false]
    [(IncludeBin _ _) false]
    [_ true]))

;; Length of the maximal run of ordinary declarations starting at the head of
;; `decls`, i.e. the number of leading declarations the walk can fold without
;; recursing. Zero means the head is special (or the list is empty) and the
;; declaration walk takes its per-kind match.
(define (compiler-load-decl-ordinary-run-length
  [decls : (& decls ast.AstDeclList)]) : i64
  (let
    [len : i64 decls.len]
    [offset : i64 decls.offset]
    [slots : (__tl_dyn-array ast.AstDecl) decls.slots]
    [count : i64 0]
    [scanning : bool true]
    (while scanning
      (if (>= count len)
        (set! scanning false)
        (if (compiler-load-decl-ordinary?
          (owned_view.compiler-owned-array-element-shared-view
            slots
            (+ offset count)))
          (set! count (+ count 1))
          (set! scanning false))))
    count))

;; The declaration walk for a list whose head is NOT an ordinary declaration.
;; Every arm recurses through
;; `compiler-load-decls-with-module-and-roots-cfg-root-with-pools`, which folds
;; the ordinary run that follows before handing the next special declaration
;; back here, so this function is entered once per module body / import / include
;; rather than once per declaration. Its `[_ ...]` arm is therefore unreachable
;; from that entry point; it is kept as the exhaustive fallback for `AstDecl` and
;; as the fail-safe if `compiler-load-decl-ordinary?` ever drifts from the arms
;; above it.
(define (compiler-load-decls-with-module-and-roots-cfg-root-with-pools-at-special-head
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
  (match (ast.ast-decl-list-step decls)
    [(Nil)
      (Ok
        (ast.ast-decl-list-new)
        (ast.ast-decl-path-list-new)
        (ast.ast-decl-module-list-new)
        seen)]
    [(Cons decl rest)
      (let
        [rest : ast.AstDeclList rest]
        (match (clone decl)
          [(ModuleBody target-module-id body-box)
            (let
              [target-module : String (ci.intern-str target-module-id)]
              [body : ast.AstDeclList (deref body-box)]
              (if (or
                (compiler-load-decl-list-has-module-id?
                  (ast.ast-place-shared-view body)
                  target-module-id)
                (compiler-load-decl-list-has-module-id?
                  (ast.ast-place-shared-view rest)
                  target-module-id))
                (Err
                  (box
                    (cdiag.compiler-diagnostic-at-start
                      (string.copy importer-path)
                      "compiler-load: duplicate module declaration")))
                (match (compiler-load-decls-with-module-and-roots-cfg-root-with-pools
                  (CompilerLoadTraversalContext
                    traversal.load-state
                    traversal.importer-path-id
                    target-module-id)
                  body
                  (string.copy importer-path)
                  (string.copy target-module)
                  target-module-id
                  target-module
                  target-module-id
                  seen
                  (ast.ast-place-shared-view stdlib-roots)
                  (string.copy import-root)
                  cfgs
                  pools)
                  [(Ok body-decls body-paths body-modules body-seen)
                    (match (compiler-load-decls-with-module-and-roots-cfg-root-with-pools
                      (ast.ast-place-shared-view traversal)
                      rest
                      (string.copy importer-path)
                      importer-module
                      importer-module-id
                      importer-source-module
                      importer-source-module-id
                      body-seen
                      stdlib-roots
                      import-root
                      cfgs
                      pools)
                      [(Ok rest-decls rest-paths rest-modules rest-seen)
                        (Ok
                          (compiler-load-decl-list-prepend
                            (ast.ast-decl-module-id target-module-id)
                            (compiler-load-decl-list-append-onto
                              body-decls
                              (compiler-load-decl-list-prepend
                                (ast.ast-decl-module-id
                                  importer-source-module-id)
                                rest-decls)))
                          (ast.ast-decl-path-list-prepend-builder-with-owner-and-provenance-id
                            (string.copy importer-path)
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
                      [(Err diag) (Err diag)])]
                  [(Err diag) (Err diag)])))]
          [(Import decl-meta (Spec kind import-path expected-module alias span))
            (if (compiler-load-macro-import-kind? kind)
              (match (compiler-load-decls-with-module-and-roots-cfg-root-with-pools
                (ast.ast-place-shared-view traversal)
                rest
                (string.copy importer-path)
                importer-module
                importer-module-id
                importer-source-module
                importer-source-module-id
                seen
                stdlib-roots
                import-root
                cfgs
                pools)
                [(Ok rest-decls rest-paths rest-modules rest-seen)
                  (Ok
                    (compiler-load-decl-list-prepend-from-source
                      decl
                      decls
                      rest-decls)
                    (ast.ast-decl-path-list-prepend-builder-with-owner-and-provenance-id
                      (string.copy importer-path)
                      traversal.importer-decl-owner-id
                      traversal.importer-path-id
                      rest-paths)
                    (ast.ast-decl-module-list-prepend-builder-id
                      importer-source-module-id
                      rest-modules)
                    rest-seen)]
                [(Err diag) (Err diag)])
              (match (compiler-load-resolve-import-spec-with-roots-classified
                (owned_view.compiler-owned-shared-view importer-path)
                (owned_view.compiler-owned-shared-view import-root)
                kind
                import-path
                expected-module
                alias
                (owned_view.compiler-owned-shared-view stdlib-roots))
                [(Ok import)
                  (let
                    [resolved : String import.resolved]
                    [kind : ast.AstImportKind import.kind]
                    [import-path : String import.module-name]
                    [expected-module : ast.AstMaybeModuleName
                      import.expected-module]
                    [alias : ast.AstMaybeImportAlias import.alias]
                    [resolved-id : i64 (compiler-load-source-path-id resolved)]
                    [preload-candidate : bool
                      (compiler-load-session-state-lazy-import-preload-candidate?
                        (owned_view.compiler-owned-shared-view
                          traversal.load-state)
                        (string.copy importer-path)
                        (clone kind)
                        (clone alias))]
                    [preload-demand : CompilerLoadLazyAliasDemand
                      (compiler-load-session-state-lazy-import-preload-demand
                        (owned_view.compiler-owned-shared-view
                          traversal.load-state)
                        preload-candidate
                        (clone alias)
                        (ast.ast-place-shared-view rest)
                        pools)]
                    [preload-summary-needed : bool
                      (and
                        preload-candidate
                        (not
                          (or preload-demand.qualified preload-demand.unknown)))]
                    [_preload-summary : unit
                      (if preload-summary-needed
                        (compiler-load-lazy-import-preload-summary-with-state-and-pools
                          (owned_view.compiler-owned-shared-view
                            traversal.load-state)
                          (string.copy resolved)
                          resolved-id
                          (ast.ast-place-shared-view stdlib-roots)
                          (clone expected-module)
                          (string.copy import-root)
                          cfgs
                          pools)
                        unit)]
                    [preload-skip : bool
                      (if preload-summary-needed
                        (compiler-load-lazy-import-skip-with-state?
                          (owned_view.compiler-owned-shared-view
                            traversal.load-state)
                          (string.copy importer-path)
                          (clone kind)
                          (string.copy resolved)
                          resolved-id
                          (clone expected-module)
                          (clone alias)
                          (ast.ast-place-shared-view rest)
                          pools
                          (clone preload-demand)
                          (ast.ast-place-shared-view stdlib-roots))
                        false)]
                    (match (if preload-skip
                      (ResultCompilerLoadWithPaths.Ok
                        (ast.ast-decl-list-new)
                        (ast.ast-decl-path-list-new)
                        (ast.ast-decl-module-list-new)
                        seen)
                      (compiler-load-file-with-paths-and-roots-expect-cfg-root-import-with-state-and-pools
                        (owned_view.compiler-owned-shared-view
                          traversal.load-state)
                        (string.copy resolved)
                        resolved-id
                        seen
                        (ast.ast-place-shared-view stdlib-roots)
                        (clone kind)
                        (string.copy import-path)
                        (clone expected-module)
                        (string.copy import-root)
                        cfgs
                        pools
                        (string.copy importer-source-module)
                        importer-source-module-id))
                      [(Ok
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
                              (owned_view.compiler-owned-shared-view
                                traversal.load-state)
                              resolved-id
                              kind
                              expected-module
                              alias
                              (ast.ast-place-shared-view imported-decls))]
                          (when
                            (not
                              (or
                                (compiler-load-expected-module-seen?
                                  seen
                                  validated-module)
                                (compiler-load-selected-item-present-or-pending?
                                  kind
                                  validated-module
                                  (ast.ast-place-shared-view imported-decls))))
                            (return
                              (Err
                                (box
                                  (cdiag.compiler-diagnostic-from-ast-span
                                    importer-path
                                    (__tl-box-place span)
                                    (compiler-load-missing-selected-item-message
                                      import-path
                                      kind))))))
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
                            [(Ok rest-decls rest-paths rest-modules rest-seen)
                              (let
                                [after-import-expected : ast.AstMaybeModuleName
                                  validated-module]
                                [after-import-alias : ast.AstMaybeImportAlias
                                  (compiler-load-after-import-alias
                                    (owned_view.compiler-owned-shared-view
                                      traversal.load-state)
                                    resolved-id
                                    kind
                                    expected-module
                                    alias
                                    (ast.ast-place-shared-view imported-decls))]
                                (if lazy-skip
                                  (begin
                                    (compiler-load-session-state-lazy-import-record-skip!
                                      traversal.load-state)
                                    (Ok
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
                                        traversal.importer-path-id
                                        traversal.importer-decl-owner-id
                                        after-import-alias
                                        (ast.ast-decl-list-new)
                                        rest-paths)
                                      (let
                                        [bound-7 (ast.ast-decl-list-new)]
                                        (compiler-load-modules-after-import
                                          importer-source-module-id
                                          after-import-alias
                                          bound-7
                                          rest-modules))
                                      rest-seen))
                                  (let
                                    [after-decls : ast.AstDeclList
                                      (compiler-load-decls-after-import
                                        kind
                                        resolved
                                        after-import-expected
                                        after-import-alias
                                        (__tl-box-place span)
                                        importer-source-module
                                        importer-source-module-id
                                        decls
                                        (ast.ast-place-shared-view
                                          imported-decls)
                                        rest-decls)]
                                    [after-paths : ast.AstDeclPathList
                                      (compiler-load-paths-after-import
                                        importer-path
                                        traversal.importer-path-id
                                        traversal.importer-decl-owner-id
                                        after-import-alias
                                        (ast.ast-place-shared-view
                                          imported-decls)
                                        rest-paths)]
                                    [after-modules : ast.AstDeclModuleList
                                      (compiler-load-modules-after-import
                                        importer-source-module-id
                                        after-import-alias
                                        imported-decls
                                        rest-modules)]
                                    (Ok
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
                            [(Err diag) (Err diag)]))]
                      [(Err diag) (Err diag)]))]
                [(Err message)
                  (Err
                    (box
                      (cdiag.compiler-diagnostic-from-ast-span
                        importer-path
                        (__tl-box-place span)
                        message)))]))]
          [(IncludeStr name include-path)
            (let
              [expanded
                (try
                  (compiler-load-expand-include-with-pools
                    RuntimeString
                    (string.copy importer-path)
                    include-path
                    name
                    (ast.ast-place-shared-view stdlib-roots)
                    pools))]
              (compiler-load-prepend-include
                RuntimeString
                expanded
                decls
                (string.copy importer-path)
                traversal.importer-decl-owner-id
                traversal.importer-path-id
                importer-source-module-id
                (compiler-load-decls-with-module-and-roots-cfg-root-with-pools
                  traversal
                  rest
                  (string.copy importer-path)
                  importer-module
                  importer-module-id
                  (string.copy importer-source-module)
                  importer-source-module-id
                  seen
                  stdlib-roots
                  (string.copy import-root)
                  cfgs
                  pools)))]
          [(IncludeStrComptime name include-path)
            (let
              [expanded
                (try
                  (compiler-load-expand-include-with-pools
                    ComptimeString
                    (string.copy importer-path)
                    include-path
                    name
                    (ast.ast-place-shared-view stdlib-roots)
                    pools))]
              (compiler-load-prepend-include
                ComptimeString
                expanded
                decls
                (string.copy importer-path)
                traversal.importer-decl-owner-id
                traversal.importer-path-id
                importer-source-module-id
                (compiler-load-decls-with-module-and-roots-cfg-root-with-pools
                  traversal
                  rest
                  (string.copy importer-path)
                  importer-module
                  importer-module-id
                  (string.copy importer-source-module)
                  importer-source-module-id
                  seen
                  stdlib-roots
                  (string.copy import-root)
                  cfgs
                  pools)))]
          [(IncludeStrLzss name include-path)
            (let
              [expanded
                (try
                  (compiler-load-expand-include-with-pools
                    LzssString
                    (string.copy importer-path)
                    include-path
                    name
                    (ast.ast-place-shared-view stdlib-roots)
                    pools))]
              (compiler-load-prepend-include
                LzssString
                expanded
                decls
                (string.copy importer-path)
                traversal.importer-decl-owner-id
                traversal.importer-path-id
                importer-source-module-id
                (compiler-load-decls-with-module-and-roots-cfg-root-with-pools
                  traversal
                  rest
                  (string.copy importer-path)
                  importer-module
                  importer-module-id
                  (string.copy importer-source-module)
                  importer-source-module-id
                  seen
                  stdlib-roots
                  (string.copy import-root)
                  cfgs
                  pools)))]
          [(IncludeBin name include-path)
            (let
              [expanded
                (try
                  (compiler-load-expand-include-with-pools
                    Binary
                    (string.copy importer-path)
                    include-path
                    name
                    (ast.ast-place-shared-view stdlib-roots)
                    pools))]
              (compiler-load-prepend-include
                Binary
                expanded
                decls
                (string.copy importer-path)
                traversal.importer-decl-owner-id
                traversal.importer-path-id
                importer-source-module-id
                (compiler-load-decls-with-module-and-roots-cfg-root-with-pools
                  traversal
                  rest
                  (string.copy importer-path)
                  importer-module
                  importer-module-id
                  (string.copy importer-source-module)
                  importer-source-module-id
                  seen
                  stdlib-roots
                  (string.copy import-root)
                  cfgs
                  pools)))]
          [_
            (match (compiler-load-decls-with-module-and-roots-cfg-root-with-pools
              (ast.ast-place-shared-view traversal)
              rest
              (string.copy importer-path)
              importer-module
              importer-module-id
              (string.copy importer-source-module)
              importer-source-module-id
              seen
              stdlib-roots
              (string.copy import-root)
              cfgs
              pools)
              [(Ok rest-decls rest-paths rest-modules rest-seen)
                (Ok
                  (compiler-load-decl-list-prepend-from-source
                    decl
                    decls
                    rest-decls)
                  (ast.ast-decl-path-list-prepend-builder-with-owner-and-provenance-id
                    (string.copy importer-path)
                    traversal.importer-decl-owner-id
                    traversal.importer-path-id
                    rest-paths)
                  (ast.ast-decl-module-list-prepend-builder-id
                    importer-source-module-id
                    rest-modules)
                  rest-seen)]
              [(Err diag) (Err diag)])]))]))

;; Entry point of the loader's declaration walk.
;;
;; Recursing once per declaration would make the walk's depth equal to the
;; module's top-level declaration count. The walked frame carries the per-arm
;; clones and the return temporaries of nine recursive call sites, so a module
;; with a few thousand top-level forms could exhaust the Windows stack reserve.
;; The list length is a module property, not a bound the loader controls, so the
;; walk iterates over the maximal run of ordinary declarations; only module
;; bodies, imports and includes still cost a frame.
;;
;; A declaration list is a flat slice, so the run needs no side table: the walk's
;; `decls` at run position `i` is exactly `ast-decl-list-step`'s `rest` applied
;; `i` times, i.e. the same storage at `offset + i`, and its head is the element
;; there. The run is folded back to front onto the result of the single recursive
;; call for the remainder, rebuilding each position's declaration and its list
;; view -- the `source` the origin sidecar attributes the flattened row to --
;; from that base. The prepends therefore run in exactly the order the unwinding
;; per-declaration recursion ran them, with the same arguments, so
;; `compiler-load-decl-list-prepend-from-source`'s alias records are registered
;; in the same order and the three lists come out identical.
;;
;; Do not carry the run in a `set!` cursor whose value is copied out through
;; `ast-place-shared-view` and stored for later: that copy is a raw read of the
;; local's address, which the backend reorders across the `set!`, so every stored
;; view observes the NEXT position and every flattened declaration is silently
;; attributed to the wrong source slot.
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
  (let
    [run-length : i64 (compiler-load-decl-ordinary-run-length decls)]
    (if (<= run-length 0)
      (compiler-load-decls-with-module-and-roots-cfg-root-with-pools-at-special-head
        traversal
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
        pools)
      (let
        [base-offset : i64 decls.offset]
        [base-len : i64 decls.len]
        [base-prependable : bool decls.prependable]
        [base-slots : (__tl_dyn-array ast.AstDecl) decls.slots]
        (match (compiler-load-decls-with-module-and-roots-cfg-root-with-pools
          (ast.ast-place-shared-view traversal)
          (ast.AstDeclList
            (ast.ast-place-shared-view base-slots)
            (+ base-offset run-length)
            (- base-len run-length)
            false)
          (clone importer-path)
          importer-module
          importer-module-id
          (clone importer-source-module)
          importer-source-module-id
          seen
          stdlib-roots
          (clone import-root)
          cfgs
          pools)
          [(Ok rest-decls rest-paths rest-modules rest-seen)
            (let
              [out-decls : ast.AstDeclList rest-decls]
              [out-paths : ast.AstDeclPathList rest-paths]
              [out-modules : ast.AstDeclModuleList rest-modules]
              [fold : i64 (- run-length 1)]
              (while (>= fold 0)
                (set!
                  out-decls
                  (compiler-load-decl-list-prepend-from-source
                    (owned_view.compiler-owned-array-element-shared-view
                      base-slots
                      (+ base-offset fold))
                    (ast.AstDeclList
                      (ast.ast-place-shared-view base-slots)
                      (+ base-offset fold)
                      (- base-len fold)
                      (and (= fold 0) base-prependable))
                    out-decls))
                (set!
                  out-paths
                  (ast.ast-decl-path-list-prepend-builder-with-owner-and-provenance-id
                    (clone importer-path)
                    traversal.importer-decl-owner-id
                    traversal.importer-path-id
                    out-paths))
                (set!
                  out-modules
                  (ast.ast-decl-module-list-prepend-builder-id
                    importer-source-module-id
                    out-modules))
                (set! fold (- fold 1)))
              (Ok out-decls out-paths out-modules rest-seen))]
          [(Err diag) (Err diag)])))))

(define (compiler-load-program-with-paths-and-roots-expect-cfg
  [path : (& path str)]
  [program : ast.AstProgram]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : svec.Vec]
  [expected-module : ast.AstMaybeModuleName]
  [cfgs : sym_i64_env.SymI64Env]
  [parse-identity : CompilerLoadParseIdentity]) : ResultCompilerLoadWithPaths
  (compiler-load-program-with-paths-and-roots-expect-cfg-root
    (string.copy path)
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
    (string.copy path)
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
    (string.copy path)
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
        (owned_view.compiler-owned-shared-view load-state))]
    [source-path-id : i64 parse-identity.source-path-id]
    [module-id-fallback-id : i64 parse-identity.module-fallback-id]
    [source-path : String (ci.intern-str source-path-id)]
    [loaded : ResultCompilerLoadWithPaths
      (match program
        [(Program decls-box)
          (let
            [decls : ast.AstDeclList (deref decls-box)]
            [effective-source-module-fallback : String
              (if (> (string.string-length source-module-fallback) 0)
                (owned_view.compiler-owned-shared-view source-module-fallback)
                (if (compiler-load-stdlib-source-module-import?
                  (compiler-load-normalize-path path))
                  (owned_view.compiler-owned-shared-view module-id-fallback)
                  ""))]
            [source-module : String
              (compiler-load-decls-source-module-or
                (ast.ast-place-shared-view decls)
                (string.copy effective-source-module-fallback))]
            [source-module-id : i64
              (if (compiler-load-decl-list-has-module? decls)
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
                (string.copy source-module)
                source-module-id)]
            (match (compiler-load-decls-module-id-with-fallback
              (string.copy source-path)
              (ast.ast-place-shared-view decls)
              (string.copy module-id-fallback)
              module-id-fallback-id)
              [(Ok module-id module-name-id)
                (match (compiler-load-check-expected-module
                  (string.copy source-path)
                  (clone expected-module)
                  (string.copy module-id)
                  module-name-id)
                  [(Ok _ _)
                    (if (compiler-load-seen-module-contains?
                      seen
                      (string.copy module-id)
                      module-name-id)
                      (compiler-load-seen-module-with-paths
                        (string.copy source-path)
                        source-path-id
                        (string.copy module-id)
                        module-name-id
                        load-decls
                        seen)
                      (match (compiler-load-check-dotted-import-aliases
                        (string.copy source-path)
                        (ast.ast-place-shared-view load-decls)
                        (string.copy source-module))
                        [(Ok)
                          ;; Replace a speculative lazy summary with the
                          ;; identity established by the actual load.
                          (compiler-load-session-state-surface-summary-remove-source!
                            (owned_view.compiler-owned-shared-view load-state)
                            source-path-id)
                          (compiler-load-session-state-record-surface-summary!
                            load-state
                            (compiler-load-surface-summary-from-decls
                              (string.copy source-path)
                              source-path-id
                              (string.copy import-root)
                              module-name-id
                              source-module-id
                              (compiler-load-decl-list-has-module? decls)
                              (not
                                (compiler-load-no-expected-module?
                                  (clone expected-module)))
                              (ast.ast-place-shared-view load-decls)))
                          (compiler-load-decls-with-module-and-roots-cfg-root-with-pools
                            (CompilerLoadTraversalContext
                              (owned_view.compiler-owned-shared-view load-state)
                              source-path-id
                              parse-identity.decl-owner-id)
                            load-decls
                            (string.copy source-path)
                            (string.copy module-id)
                            module-name-id
                            (string.copy source-module)
                            source-module-id
                            (compiler-load-seen-module-bind
                              seen
                              module-id
                              module-name-id)
                            stdlib-roots
                            import-root
                            cfgs
                            pools)]
                        [(Err diag) (Err diag)]))]
                  [(Err diag) (Err diag)])]
              [(Err diag) (Err diag)]))])]
    (compiler-load-session-state-surface-summary-load-exit! load-state)
    (if (= entry-depth 0)
      (match loaded
        [(Ok decls paths modules loaded-seen)
          (let
            [_
              (try
                (compiler-load-check-unqualified-import-collisions
                  source-path
                  (ast.ast-place-shared-view decls)
                  paths))]
            (Ok decls paths modules loaded-seen))]
        [(Err diag) (Err diag)])
      loaded)))

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
        (string.copy path)
        program
        seen
        stdlib-roots
        expected-module
        import-root
        cfgs
        pools
        parse-identity)]
    (ast.ast-node-pool-context-install! pools)
    result))

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
    (string.copy path)
    source
    seen
    stdlib-roots
    No))

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
    No
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
;; Parsing into a throwaway scratch arena and `clone`-ing the result back out
;; cannot work with the flat-node AST: `AstExpr`/`AstType`/`SpannedSexpr` nodes
;; live in persistent GLOBAL pools, not the active arena, so destroying the
;; scratch arena leaves the cloned program pointing at pool slots whose backing
;; list/string data has been freed. Reclaiming parse memory needs pool-aware
;; reclamation (e.g. truncating the node pools after escaping), not arena
;; destruction.
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
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [result : parser.ResultAstProgramDiagnostic
      (compiler-load-parse-file-diagnostic-detached-with-pools
        (compiler-load-active-session-state-shared-view)
        path
        cfgs
        pools)]
    ;; Serial package loading reads the compatibility pools after this boundary.
    ;; Publish the compacted destination before traversing imports; the parser's
    ;; temporary pools and arena have already been retired by the shared helper.
    (ast.ast-node-pool-context-install! pools)
    result))

(define (compiler-load-parse-file-diagnostic-escaping-with-pools
  [load-state : CompilerLoadSessionState]
  [path : String]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]) : parser.ResultAstProgramDiagnostic
  (let
    [source : String
      (compiler-load-session-state-read-source-text load-state (& path))]
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
  (parser.compiler-parse-decl-origin-copy-direct-records!
    source
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
      (match (array-ref source-slots (+ source-offset index))
        [(ModuleBody _ source-body-box)
          (match (array-ref dest-slots (+ dest-offset index))
            [(ModuleBody _ dest-body-box)
              (compiler-load-propagate-compacted-decl-origins!
                (deref source-body-box)
                (deref dest-body-box)
                records-start
                records-end)]
            [_ unit])]
        [_ unit])
      (set! index (+ index 1)))))

(define (compiler-load-propagate-compacted-program-origins!
  [source : ast.AstProgram]
  [dest : ast.AstProgram]
  [records-start : i64]
  [records-end : i64]) : unit
  (match source
    [(Program source-decls-box)
      (match dest
        [(Program dest-decls-box)
          (compiler-load-propagate-compacted-decl-origins!
            (deref source-decls-box)
            (deref dest-decls-box)
            records-start
            records-end)])]))

(define (compiler-load-parse-file-diagnostic-detached-with-pools
  [load-state : CompilerLoadSessionState]
  [path : String]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]) : parser.ResultAstProgramDiagnostic
  (let
    [caller-arena : i64 (arena.tl_arena_current)]
    [scratch-root : i64 (arena.tl_arena_make)]
    [_use-scratch : unit
      (unsafe
        (arena.tl_arena_set scratch-root))]
    [source : String
      (compiler-load-session-state-read-source-text load-state (& path))]
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
        scratch-pools)]
    (match parsed
      [(Ok program)
        (match (ast.ast-program-copy-append-with-pools
          scratch-pools
          pools
          (& program))
          [(AstProgramCompaction out-program _)
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
              [out : parser.ResultAstProgramDiagnostic (Ok out-program)]
              (ast.ast-node-pool-context-destroy-storage! scratch-pools)
              (unsafe
                (arena.tl_arena_destroy scratch-root))
              out)])]
      [(Err diag)
        (let
          [_restore-caller : unit
            (unsafe
              (arena.tl_arena_set caller-arena))]
          [stable-diag : (Box cdiag.CompilerDiagnostic)
            (box (cdiag.compiler-diagnostic-copy (deref diag)))]
          [out : parser.ResultAstProgramDiagnostic (Err stable-diag)]
          (reader.sp-node-pool-truncate! records-start)
          (ast.ast-node-pool-context-destroy-storage! scratch-pools)
          (unsafe
            (arena.tl_arena_destroy scratch-root))
          out)])))

(define (compiler-load-cache-program-result
  [key : CompilerLoadProgramCacheKey]
  [result : parser.ResultAstProgramDiagnostic]) : parser.ResultAstProgramDiagnostic
  (let
    [program (try result)]
    (if (compiler-load-program-cache-store
      key
      (ast.ast-place-shared-view program))
      (compiler-load-session-note-persistent!)
      unit)
    (Ok program)))

(define (compiler-load-cache-program-result-with-pools
  [load-state : CompilerLoadSessionState]
  [key : CompilerLoadProgramCacheKey]
  [result : parser.ResultAstProgramDiagnostic]
  [pools : ast.AstNodePoolContext]) : parser.ResultAstProgramDiagnostic
  (let
    [program (try result)]
    (if (compiler-load-session-state-program-cache-store
      (owned_view.compiler-owned-shared-view load-state)
      key
      (ast.ast-place-shared-view program))
      (compiler-load-session-state-note-persistent-with-pools! load-state pools)
      unit)
    (Ok program)))

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
    (owned_view.compiler-owned-shared-view load-state)
    key)
    (let
      [persistent : CompilerLoadPersistentProgramResult
        (in-arena
          (arena.Arena (ast.ast-node-pool-context-base-arena pools))
          (CompilerLoadPersistentProgramResult
            (compiler-load-program-cache-key-copy key)
            (compiler-load-parse-file-diagnostic-escaping-with-pools
              (owned_view.compiler-owned-shared-view load-state)
              path
              cfgs
              pools)))]
      (match persistent
        [(CompilerLoadPersistentProgramResult persistent-key parsed)
          (compiler-load-cache-program-result-with-pools
            load-state
            persistent-key
            parsed
            pools)]))
    (compiler-load-parse-file-diagnostic-escaping-with-pools
      load-state
      path
      cfgs
      pools)))

(define (compiler-load-ast-program-result-ok?
  [result : (& result parser.ResultAstProgramDiagnostic)]) : bool
  (match result
    [(Ok _) true]
    [(Err _) false]))

(define (compiler-load-parse-file-diagnostic-cache-miss-local
  [key : CompilerLoadProgramCacheKey]
  [path : String]
  [cfgs : sym_i64_env.SymI64Env]) : parser.ResultAstProgramDiagnostic
  (if (compiler-load-program-cache-can-store key)
    (let
      [start-nodes : i64 (ast.ast-node-pool-len)]
      [cold : parser.ResultAstProgramDiagnostic
        (compiler-load-parse-file-diagnostic-escaping (string.copy path) cfgs)]
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
    (owned_view.compiler-owned-shared-view load-state)
    key)
    (let
      [start-nodes : i64 (ast.ast-node-pool-context-expr-len pools)]
      [cold : parser.ResultAstProgramDiagnostic
        (compiler-load-parse-file-diagnostic-escaping-with-pools
          (owned_view.compiler-owned-shared-view load-state)
          (string.copy path)
          cfgs
          pools)]
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
    (compiler-load-parse-file-diagnostic-escaping-with-pools
      load-state
      path
      cfgs
      pools)))

(define (compiler-load-parse-file-diagnostic-admit-only
  [key : CompilerLoadProgramCacheKey]
  [path : String]
  [cfgs : sym_i64_env.SymI64Env]) : parser.ResultAstProgramDiagnostic
  (let
    [parsed : parser.ResultAstProgramDiagnostic
      (compiler-load-parse-file-diagnostic-escaping path cfgs)]
    (match (& parsed)
      [(Ok _)
        (if (compiler-load-program-admission-record-persistent key)
          unit
          unit)]
      [(Err _) unit])
    parsed))

(define (compiler-load-parse-file-diagnostic-admit-only-with-pools
  [load-state : CompilerLoadSessionState]
  [key : CompilerLoadProgramCacheKey]
  [path : String]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]) : parser.ResultAstProgramDiagnostic
  (let
    [parsed : parser.ResultAstProgramDiagnostic
      (compiler-load-parse-file-diagnostic-escaping-with-pools
        (owned_view.compiler-owned-shared-view load-state)
        path
        cfgs
        pools)]
    (match (& parsed)
      [(Ok _)
        (if (compiler-load-session-state-program-admission-record-persistent
          load-state
          key)
          unit
          unit)]
      [(Err _) unit])
    parsed))

(define (compiler-load-parse-file-diagnostic-session-id
  [path : String]
  [source-path-id : i64]
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]) : parser.ResultAstProgramDiagnostic
  ;; A source provider must see every read, so its checks bypass the cache.
  (if (and
    (compiler-load-session-cache-enabled?)
    (compiler-load-session-program-cache-enabled?)
    (not (compiler-load-session-source-provider-active?))
    (compiler-load-session-file-cacheable? (string.copy path) stdlib-roots))
    (let
      [key : CompilerLoadProgramCacheKey
        (compiler-load-program-cache-key-id
          CompilerLoadProgramFile
          source-path-id
          cfgs)]
      (match (compiler-load-program-cache-lookup key)
        [(CompilerLoadProgramCacheHit program)
          (compiler-load-program-cache-note-hit!)
          (Ok program)]
        [(CompilerLoadProgramCacheMiss)
          (let
            [immediate : bool
              (compiler-load-session-file-cache-immediate?
                (string.copy path)
                stdlib-roots)]
            (compiler-load-program-cache-note-miss!)
            (if (or immediate (compiler-load-program-admission-contains? key))
              (if immediate
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
  ;; A source provider must see every read, so its checks bypass the cache.
  (if (and
    (compiler-load-session-state-cache-enabled? load-state)
    (compiler-load-session-state-program-cache-enabled? load-state)
    (not (compiler-load-session-state-source-provider-active? load-state))
    (compiler-load-session-file-cacheable? (string.copy path) stdlib-roots))
    (let
      [key : CompilerLoadProgramCacheKey
        (compiler-load-session-state-program-cache-key-id
          (owned_view.compiler-owned-shared-view load-state)
          CompilerLoadProgramFile
          source-path-id
          cfgs)]
      (match (compiler-load-session-state-program-cache-lookup
        (owned_view.compiler-owned-shared-view load-state)
        key)
        [(CompilerLoadProgramCacheHit program)
          (compiler-load-session-state-program-cache-note-hit! load-state)
          (Ok program)]
        [(CompilerLoadProgramCacheMiss)
          (let
            [immediate : bool
              (compiler-load-session-file-cache-immediate?
                (string.copy path)
                stdlib-roots)]
            (compiler-load-session-state-program-cache-note-miss!
              (owned_view.compiler-owned-shared-view load-state))
            (if (or
              immediate
              (compiler-load-session-state-program-admission-contains?
                (owned_view.compiler-owned-shared-view load-state)
                key))
              (if immediate
                (compiler-load-parse-file-diagnostic-cache-miss-with-pools
                  load-state
                  key
                  (string.copy path)
                  cfgs
                  pools)
                (compiler-load-parse-file-diagnostic-cache-miss-local-with-pools
                  load-state
                  key
                  (string.copy path)
                  cfgs
                  pools))
              (compiler-load-parse-file-diagnostic-admit-only-with-pools
                load-state
                key
                (string.copy path)
                cfgs
                pools)))]))
    (compiler-load-parse-file-diagnostic-detached-with-pools
      load-state
      path
      cfgs
      pools)))

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
    (owned_view.compiler-owned-shared-view load-state)
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
              pools)))]
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
  (compiler-load-session-note-embedded-stdlib-source!)
  (compiler-load-session-state-note-embedded-source!
    (compiler-load-active-session-state-shared-view)
    (& path)
    (& source))
  (if (and
    (compiler-load-session-cache-enabled?)
    (compiler-load-session-program-cache-enabled?)
    (not (compiler-load-session-source-provider-active?)))
    (let
      [key : CompilerLoadProgramCacheKey
        (compiler-load-program-cache-key-id
          CompilerLoadProgramEmbedded
          source-path-id
          cfgs)]
      (match (compiler-load-program-cache-lookup key)
        [(CompilerLoadProgramCacheHit program)
          (compiler-load-program-cache-note-hit!)
          (Ok program)]
        [(CompilerLoadProgramCacheMiss)
          (compiler-load-program-cache-note-miss!)
          (compiler-load-parse-embedded-source-diagnostic-cache-miss
            key
            (string.copy path)
            source
            cfgs)]))
    (compiler-load-parse-source-diagnostic-escaping path source cfgs)))

(define (compiler-load-parse-embedded-source-diagnostic-session-id-with-pools
  [load-state : CompilerLoadSessionState]
  [path : String]
  [source-path-id : i64]
  [source : String]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]) : parser.ResultAstProgramDiagnostic
  (compiler-load-session-state-note-embedded-stdlib-source!
    (owned_view.compiler-owned-shared-view load-state))
  (compiler-load-session-state-note-embedded-source!
    (owned_view.compiler-owned-shared-view load-state)
    (& path)
    (& source))
  (if (and
    (compiler-load-session-state-cache-enabled? load-state)
    (compiler-load-session-state-program-cache-enabled? load-state)
    (not (compiler-load-session-state-source-provider-active? load-state)))
    (let
      [key : CompilerLoadProgramCacheKey
        (compiler-load-session-state-program-cache-key-id
          (owned_view.compiler-owned-shared-view load-state)
          CompilerLoadProgramEmbedded
          source-path-id
          cfgs)]
      (match (compiler-load-session-state-program-cache-lookup
        (owned_view.compiler-owned-shared-view load-state)
        key)
        [(CompilerLoadProgramCacheHit program)
          (compiler-load-session-state-program-cache-note-hit! load-state)
          (Ok program)]
        [(CompilerLoadProgramCacheMiss)
          (compiler-load-session-state-program-cache-note-miss!
            (owned_view.compiler-owned-shared-view load-state))
          (compiler-load-parse-embedded-source-diagnostic-cache-miss-with-pools
            load-state
            key
            path
            source
            cfgs
            pools)]))
    (compiler-load-parse-source-diagnostic-escaping-with-pools
      path
      source
      cfgs
      pools)))

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
      (compiler-load-parse-identity (string.copy path) fallback expected-module)]
    [program
      (try
        (compiler-load-parse-source-diagnostic-escaping
          (string.copy path)
          source
          cfgs))]
    (compiler-load-program-with-paths-and-roots-expect-cfg
      path
      program
      seen
      stdlib-roots
      expected-module
      cfgs
      parse-identity)))

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
      (compiler-load-parse-identity (string.copy path) fallback expected-module)]
    [program
      (try
        (compiler-load-parse-source-diagnostic-escaping-with-pools
          (string.copy path)
          source
          cfgs
          pools))]
    (compiler-load-program-with-paths-and-roots-expect-cfg-with-pools
      load-state
      path
      program
      seen
      stdlib-roots
      expected-module
      cfgs
      pools
      parse-identity)))

(define (compiler-load-source
  [path : String]
  [source : String]
  [seen : sym_i64_env.SymI64Env]) : ResultCompilerLoad
  (compiler-load-drop-paths (compiler-load-source-with-paths path source seen)))

(define (compiler-load-file-with-paths-and-roots
  [path : String]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : svec.Vec]) : ResultCompilerLoadWithPaths
  (compiler-load-file-with-paths-and-roots-expect path seen stdlib-roots No))

(define (compiler-load-file-with-paths-and-roots-cfg
  [path : String]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]) : ResultCompilerLoadWithPaths
  (compiler-load-file-with-paths-and-roots-expect-cfg
    path
    seen
    stdlib-roots
    No
    cfgs))

(define (compiler-load-file-with-paths-and-roots-cfg-with-pools
  [load-state : CompilerLoadSessionState]
  [path : (& path str)]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]) : ResultCompilerLoadWithPaths
  (compiler-load-file-with-paths-and-roots-expect-cfg-with-pools
    load-state
    path
    seen
    stdlib-roots
    No
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
    [(Ok decls paths modules loaded-seen)
      (Ok
        decls
        paths
        modules
        (if path-dedup
          (sym_i64_env.sym-i64-bind-id loaded-seen path-key-id 1)
          loaded-seen))]
    [(Err diag) (Err diag)]))

(define (compiler-load-file-with-paths-and-roots-expect-cfg
  [path : String]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : svec.Vec]
  [expected-module : ast.AstMaybeModuleName]
  [cfgs : sym_i64_env.SymI64Env]) : ResultCompilerLoadWithPaths
  (compiler-load-file-with-paths-and-roots-expect-cfg-root
    (string.copy path)
    seen
    stdlib-roots
    expected-module
    (compiler-load-dirname path)
    cfgs))

(define (compiler-load-file-with-paths-and-roots-expect-cfg-with-pools
  [load-state : CompilerLoadSessionState]
  [path : (& path str)]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : svec.Vec]
  [expected-module : ast.AstMaybeModuleName]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]) : ResultCompilerLoadWithPaths
  (compiler-load-file-with-paths-and-roots-expect-cfg-root-with-pools
    load-state
    (string.copy path)
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
    (string.copy path)
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
        (string.copy import-path)
        (string.copy path)
        (string.copy import-root))]
    [source-module : String
      (compiler-load-canonical-source-module-from-import
        kind
        import-path
        (string.copy path)
        expected-module
        (string.copy context-module))]
    (compiler-load-file-with-paths-and-roots-expect-cfg-root-cache-current-fallback-with-pools
      load-state
      (string.copy path)
      source-path-id
      seen
      stdlib-roots
      expected-module
      (string.copy import-root)
      cfgs
      true
      pools
      context-module-id
      fallback
      (string.copy source-module)
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
      seen)
      (compiler-load-seen-expected-module-with-paths
        (compiler-load-active-session-state-shared-view)
        path
        source-path-id
        expected-module
        seen)
      (if (and path-dedup (sym_i64_env.sym-i64-contains-id seen path-key-id))
        (Ok
          (ast.ast-decl-list-new)
          (ast.ast-decl-path-list-new)
          (ast.ast-decl-module-list-new)
          seen)
        (let
          [fallback : String
            (compiler-load-canonical-module-id-from-path (string.copy path))]
          [parse-identity : CompilerLoadParseIdentity
            (CompilerLoadParseIdentity
              source-path-id
              (compiler-load-module-fallback-id-for-parse
                fallback
                expected-module)
              cbi.compiler-builtin-id-fix-empty)]
          [parse-cfgs : sym_i64_env.SymI64Env cfgs]
          (if (io.file-exists? (string.copy path))
            (let
              [program
                (try
                  (if cache-current
                    (compiler-load-parse-file-diagnostic-session-id
                      (string.copy path)
                      source-path-id
                      (ast.ast-place-shared-view stdlib-roots)
                      parse-cfgs)
                    (compiler-load-parse-file-diagnostic-escaping
                      (string.copy path)
                      parse-cfgs)))]
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
                path-key-id))
            (match (compiler-load-embedded-stdlib-source-for-path
              (string.copy path))
              [(CompilerEmbeddedStdlibSomeSource source)
                (let
                  [program
                    (try
                      (begin
                        (compiler-load-note-embedded-module! (string.copy path))
                        (if cache-current
                          (compiler-load-parse-embedded-source-diagnostic-session-id
                            (string.copy path)
                            source-path-id
                            (string.copy source)
                            parse-cfgs)
                          (compiler-load-parse-source-diagnostic-escaping
                            (string.copy path)
                            source
                            parse-cfgs))))]
                  (compiler-load-bind-path-dedup
                    (compiler-load-program-with-paths-and-roots-expect-cfg-root
                      (string.copy path)
                      program
                      seen
                      stdlib-roots
                      (clone expected-module)
                      (string.copy import-root)
                      parse-cfgs
                      parse-identity)
                    path-dedup
                    path-key-id))]
              [(CompilerEmbeddedStdlibNoSource)
                (Err
                  (box
                    (cdiag.compiler-diagnostic-at-start
                      (string.copy path)
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
      (string.copy path)
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
      load-state
      source-path-id
      (clone expected-module)
      seen)
      (compiler-load-seen-expected-module-with-paths
        load-state
        path
        source-path-id
        expected-module
        seen)
      (if (and path-dedup (sym_i64_env.sym-i64-contains-id seen path-key-id))
        (Ok
          (ast.ast-decl-list-new)
          (ast.ast-decl-path-list-new)
          (ast.ast-decl-module-list-new)
          seen)
        (let
          [parse-identity : CompilerLoadParseIdentity
            (CompilerLoadParseIdentity
              source-path-id
              (compiler-load-module-fallback-id-for-parse
                (string.copy module-id-fallback)
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
          (if (io.file-exists? (string.copy path))
            (let
              [program
                (try
                  (if cache-current
                    (compiler-load-parse-file-diagnostic-session-id-with-pools
                      (owned_view.compiler-owned-shared-view load-state)
                      (string.copy path)
                      source-path-id
                      (ast.ast-place-shared-view stdlib-roots)
                      parse-cfgs
                      pools)
                    (compiler-load-parse-file-diagnostic-detached-with-pools
                      (owned_view.compiler-owned-shared-view load-state)
                      (string.copy path)
                      parse-cfgs
                      pools)))]
              (compiler-load-bind-path-dedup
                (compiler-load-program-with-paths-and-roots-expect-cfg-root-fallback-with-pools
                  load-state
                  (string.copy path)
                  program
                  seen
                  stdlib-roots
                  (clone expected-module)
                  (string.copy import-root)
                  parse-cfgs
                  pools
                  (string.copy module-id-fallback)
                  (clone parse-identity)
                  (string.copy source-module-fallback)
                  source-module-fallback-id)
                path-dedup
                path-key-id))
            (match (compiler-load-embedded-stdlib-source-for-path
              (string.copy path))
              [(CompilerEmbeddedStdlibSomeSource source)
                (let
                  [program
                    (try
                      (begin
                        (compiler-load-session-state-note-embedded-module!
                          load-state
                          (string.copy path))
                        (if cache-current
                          (compiler-load-parse-embedded-source-diagnostic-session-id-with-pools
                            (owned_view.compiler-owned-shared-view load-state)
                            (string.copy path)
                            source-path-id
                            (string.copy source)
                            parse-cfgs
                            pools)
                          (compiler-load-parse-source-diagnostic-escaping-with-pools
                            (string.copy path)
                            source
                            parse-cfgs
                            pools))))]
                  (compiler-load-bind-path-dedup
                    (compiler-load-program-with-paths-and-roots-expect-cfg-root-fallback-with-pools
                      load-state
                      (string.copy path)
                      program
                      seen
                      stdlib-roots
                      (clone expected-module)
                      (string.copy import-root)
                      parse-cfgs
                      pools
                      (string.copy module-id-fallback)
                      (clone parse-identity)
                      (string.copy source-module-fallback)
                      source-module-fallback-id)
                    path-dedup
                    path-key-id))]
              [(CompilerEmbeddedStdlibNoSource)
                (Err
                  (box
                    (cdiag.compiler-diagnostic-at-start
                      (string.copy path)
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
        (string.copy path)
        (compiler-load-source-path-id path)
        seen
        stdlib-roots
        expected-module
        (compiler-load-dirname path)
        cfgs
        true
        pools
        cbi.compiler-builtin-id-fix-empty
        module-id-fallback
        (string.copy source-module-fallback)
        (if (= (string.string-length source-module-fallback) 0)
          cbi.compiler-builtin-id-fix-empty
          -1)
        cbi.compiler-builtin-id-fix-empty)]
    (ast.ast-node-pool-context-install! pools)
    result))

(define (compiler-load-entry-file-with-paths-and-roots-cfg
  [path : String]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]) : ResultCompilerLoadWithPaths
  (compiler-load-file-with-paths-and-roots-expect-cfg-root-cache-current
    (string.copy path)
    seen
    stdlib-roots
    No
    (compiler-load-dirname path)
    cfgs
    false))

(define (compiler-load-entry-file-with-paths-and-roots-cfg-with-pools
  [load-state : CompilerLoadSessionState]
  [path : (& path str)]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]) : ResultCompilerLoadWithPaths
  (compiler-load-file-with-paths-and-roots-expect-cfg-root-cache-current-with-pools
    load-state
    (string.copy path)
    seen
    stdlib-roots
    No
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
              (when
                pending-separator
                (set! out (str_cat.str-cat out "_" ""))
                (set! pending-separator false))
              (set!
                out
                (str_cat.str-cat
                  out
                  (compiler-load-package-symbol-char name i c)
                  ""))
              (set! emitted true)
              (set! i (+ i 1)))))))
    out))

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

(define (compiler-load-package-module-id-normalized
  [entry-path : String]
  [decl-path : String]) : String
  (let
    [decl-path : String (compiler-load-canonical-stdlib-path decl-path)]
    [base : String (compiler-load-dirname entry-path)]
    [base-len : i64 (string.string-length base)]
    [decl-len : i64 (string.string-length decl-path)]
    (if (and (> base-len 0) (compiler-load-string-prefix-at? decl-path base 0))
      (string.substring decl-path base-len (- decl-len base-len))
      decl-path)))

(define (compiler-load-package-module-logical-name-normalized
  [entry-path : String]
  [decl-path : String]
  [source-name : String]) : String
  (if (and (string.eq decl-path entry-path) (string.eq source-name "main"))
    "main"
    (str_cat.str-cat
      (compiler-load-package-module-id-normalized entry-path decl-path)
      "::"
      source-name)))

(define (compiler-load-package-entry-main-normalized?
  [entry-path : String]
  [decl-path : String]
  [source-name : String]) : bool
  (and (string.eq decl-path entry-path) (string.eq source-name "main")))

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
      path)))

(define (compiler-load-package-owned-path
  [package-owner : String]
  [package-root : String]
  [stdlib-roots : svec.Vec]
  [path : String]) : String
  (let
    [stdlib-path : String
      (if (compiler-load-stdlib-import? path)
        (compiler-load-normalize-path path)
        (compiler-load-stdlib-owned-path-from-roots
          (string.copy path)
          stdlib-roots))]
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
    [(LookupFound owned-id) owned-id]
    [(LookupMissing)
      (let
        [owned : String
          (compiler-load-package-owned-path
            package-owner
            package-root
            stdlib-roots
            path)]
        [owned-id : i64 (ci.intern-generated-canonical-name owned)]
        (load_i64_i64_map.insert-ref! cache path-id owned-id)
        owned-id)]))

(define (compiler-load-package-decl-logical-name-normalized
  [entry-path : String]
  [decl-path : String]
  [module : String]
  [source-name : String]) : String
  (if (compiler-load-package-entry-main-normalized?
    (string.copy entry-path)
    (string.copy decl-path)
    (string.copy source-name))
    "main"
    (if (string.eq module "")
      (compiler-load-package-module-logical-name-normalized
        entry-path
        decl-path
        source-name)
      (compiler-load-package-module-logical-name-normalized
        entry-path
        decl-path
        (compiler-load-package-module-key module source-name)))))

(define (compiler-load-param-type-list [params : ast.AstParamList]) : ast.AstTypeList
  (let
    [out : ast.AstTypeList
      (ast.ast-type-list-with-capacity (ast.ast-param-list-len (& params)))]
    (compiler-load-param-type-list-into (& params) 0 (&mut out))
    out))

(define (compiler-load-param-type-list-into
  [params : (& params ast.AstParamList)]
  [index : i64]
  [out : (&mut out ast.AstTypeList)]) : unit
  (unless
    (>= index (ast.ast-param-list-len params))
    (match (ast.ast-param-list-get params index (ast.ast-param-fallback))
      [(Param _ ty _)
        (ast.ast-type-list-push out (ast.ast-node-pool-reader-type-push (& ty)))])
    (compiler-load-param-type-list-into params (+ index 1) out)))

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
        (string.copy manifest-dir)
        (string.copy package-name))]
    (if (not (io.file-exists? (string.copy path)))
      (Ok Unavailable)
      (match (compiler-load-session-try-read-input-text (& path))
        [(ErrIoString error)
          (Err
            (str_cat.str-cat
              "compiler-load: cannot read dependency tlci '"
              path
              "': "
              (io.error-message error)))]
        [(OkIoString contents)
          (match (tlci.tlci-parse-image (tlci.tlci-string->bytes contents))
            [(Err message)
              (Err
                (str_cat.str-cat
                  "compiler-load: invalid dependency tlci '"
                  path
                  "': "
                  message))]
            [(Ok image)
              (let
                [metadata : tlci.TlciMetadata image.metadata]
                (if (or
                  (not (string.eq metadata.package-name package-name))
                  (not (string.eq metadata.package-version package-version)))
                  (Err
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
                  (Ok
                    (Available
                      (string.copy metadata.package-version)
                      metadata.spmd-callables))))])]))))

(define (compiler-load-imported-spmd-specializations
  [items : tlci.TlciSpmdSpecializations]) : ast.AstImportedSpmdSpecializationList
  (let
    [out : ast.AstImportedSpmdSpecializationList
      (ast.ast-imported-spmd-specialization-list-new)]
    [count : i64 (tlci.tlci-spmd-specializations-len items)]
    [index : i64 0]
    (while (< index count)
      (let
        [item : tlci.TlciSpmdSpecialization
          (tlci.tlci-spmd-specializations-ref items index)]
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
        (set! index (+ index 1))))
    out))

(define (compiler-load-imported-spmd-callables-for
  [canonical-name : String]
  [items : tlci.TlciSpmdCallables]) : ast.AstImportedSpmdCallableList
  (let
    [out : ast.AstImportedSpmdCallableList
      (ast.ast-imported-spmd-callable-list-new)]
    [count : i64 (tlci.tlci-spmd-callables-len items)]
    [index : i64 0]
    (while (< index count)
      (let
        [item : tlci.TlciSpmdCallable
          (tlci.tlci-spmd-callables-ref items index)]
        (if (string.eq item.name canonical-name)
          (ast.ast-imported-spmd-callable-list-push
            (&mut out)
            (ast.AstImportedSpmdCallable
              (ci.intern-id-from-renderable
                (ci.intern-generated-canonical-name item.signature))
              (compiler-load-imported-spmd-specializations item.specializations)))
          unit)
        (set! index (+ index 1))))
    out))

(define (compiler-load-imported-spmd-metadata
  [package-owner : String]
  [module : String]
  [name : i64]
  [interface : CompilerLoadPackageSpmdInterface]) : ast.AstImportedSpmdMetadata
  (let
    [canonical-name : String
      (compiler-load-package-module-key
        (if (= (string.string-length module) 0)
          (owned_view.compiler-owned-shared-view package-owner)
          module)
        (ci.intern-str name))]
    [callables : ast.AstImportedSpmdCallableList
      (match (clone interface)
        [(Unavailable) (ast.ast-imported-spmd-callable-list-new)]
        [(Available _ items)
          (compiler-load-imported-spmd-callables-for
            (string.copy canonical-name)
            items)])]
    (Package
      (string.copy package-owner)
      (match interface
        [(Available version _) version]
        [(Unavailable) ""])
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
        (string.copy package-owner)
        (string.copy package-root)
        stdlib-roots
        decl-path)]
    [normalized-logical-path : String
      (compiler-load-normalize-path logical-path)]
    [logical : String
      (compiler-load-package-decl-logical-name-normalized
        "."
        normalized-logical-path
        (string.copy module)
        name-str)]
    [link-name : String
      (compiler-load-package-user-symbol (string.copy logical))]
    (Extern
      (ast.ast-decl-meta-runtime-shared-view)
      name
      (Function)
      (box
        (ast.AstExternMetadata.Metadata
          (TypeLisp)
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
      (ast.ast-ty-func (compiler-load-param-type-list params) (& ret)))))

(define (compiler-load-package-transform-decl
  [package-owner : String]
  [package-root : String]
  [stdlib-roots : svec.Vec]
  [decl-path : String]
  [module : String]
  [spmd-interface : CompilerLoadPackageSpmdInterface]
  [decl : ast.AstDecl]) : CompilerLoadMaybeDecl
  (match (clone decl)
    [(DefFn decl-meta name params ret _ _)
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
    [(DefMacro _ _ _ _ _) (CompilerLoadSomeDecl decl)]
    [(DefStruct decl-meta _ _ _ _) (CompilerLoadSomeDecl decl)]
    [(Module _) (CompilerLoadSomeDecl decl)]
    [(Unsafe inner-box)
      (let
        [inner : ast.AstDecl (deref inner-box)]
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
    [(Cons path _) path]
    [(Nil) fallback]))

(define (compiler-load-path-list-tail [paths : ast.AstDeclPathList]) : ast.AstDeclPathList
  (match (ast.ast-decl-path-list-step paths)
    [(Cons _ rest)
      (let
        [rest : ast.AstDeclPathList rest]
        rest)]
    [(Nil) (ast.ast-decl-path-list-new)]))

(define (compiler-load-package-owned-decl-entry-main-normalized?
  [normalized-entry-path : String]
  [_module : String]
  [decl-path : String]
  [decl : ast.AstDecl]) : bool
  (match decl
    [(DefFn decl-meta name _ _ _ _)
      (compiler-load-package-entry-main-normalized?
        normalized-entry-path
        (compiler-load-normalize-path decl-path)
        (ci.intern-str name))]
    [(Unsafe inner-box)
      (compiler-load-package-owned-decl-entry-main-normalized?
        normalized-entry-path
        _module
        decl-path
        (deref inner-box))]
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
    [normalized-entry-path : String (compiler-load-normalize-path entry-path)]
    [owned-cache : load_i64_i64_map.Map
      (load_i64_i64_map.with-capacity (+ (* count 2) 16))]
    [done : bool false]
    (while (not done)
      (match (ast.ast-decl-list-step decl-cursor)
        [(Nil) (set! done true)]
        [(Cons decl rest)
          (let
            [decl-path : String
              (compiler-load-path-list-head-or
                (ast.ast-place-shared-view path-cursor)
                (string.copy entry-path))]
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
              (if (compiler-load-package-owned-decl-entry-main-normalized?
                (string.copy normalized-entry-path)
                (string.copy current-module)
                (string.copy decl-path)
                (clone decl))
                cbi.compiler-builtin-id-fix-empty
                (compiler-load-package-owned-path-cached!
                  (&mut owned-cache)
                  (string.copy package-owner)
                  (string.copy package-root)
                  (ast.ast-place-shared-view stdlib-roots)
                  decl-path
                  decl-path-id))]
            [owned-path : String (ci.intern-str owned-path-id)]
            (ast.ast-decl-path-list-push-with-owner-and-provenance-id
              (&mut out)
              owned-path
              owned-path-id
              decl-provenance-id)
            (match decl
              [(Module name) (set! current-module (ci.intern-str name))]
              [_ unit])
            (set! decl-cursor rest)
            (set! path-cursor (compiler-load-path-list-tail path-cursor)))]))
    out))

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
  (match (ast.ast-decl-list-step decls)
    [(Nil)
      (Ok
        (ast.ast-decl-list-new)
        (ast.ast-decl-path-list-new)
        (ast.ast-decl-module-list-new)
        seen)]
    [(Cons decl rest)
      (let
        [rest : ast.AstDeclList rest]
        [decl-path : String
          (compiler-load-path-list-head-or
            (ast.ast-place-shared-view paths)
            (string.copy package-root))]
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
            (string.copy package-owner)
            (string.copy package-root)
            (ast.ast-place-shared-view stdlib-roots)
            (string.copy decl-path))]
        [rest-paths : ast.AstDeclPathList (compiler-load-path-list-tail paths)]
        [next-module : String
          (match (clone decl)
            [(Module name) (ci.intern-str name)]
            [_ (string.copy module)])]
        [next-module-id : i64
          (match (clone decl)
            [(Module name) name]
            [_ module-id])]
        (match (compiler-load-package-extern-decls
          (string.copy package-owner)
          (string.copy package-root)
          (ast.ast-place-shared-view stdlib-roots)
          rest
          rest-paths
          seen
          next-module
          next-module-id
          (clone spmd-interface))
          [(Ok rest-decls rest-decl-paths rest-modules rest-seen)
            (match (compiler-load-package-transform-decl
              package-owner
              package-root
              stdlib-roots
              decl-path
              module
              spmd-interface
              decl)
              [(CompilerLoadSomeDecl transformed)
                (Ok
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
                (Ok rest-decls rest-decl-paths rest-modules rest-seen)])]
          [(Err diag) (Err diag)]))]))

(define (compiler-load-package-entry-for-source [source-path : String]) : ResultCompilerLoadPackageEntry
  (match (compiler-load-discover-manifest (string.copy source-path))
    [(CompilerLoadNoPath)
      (Err
        (str_cat.str-cat
          "compiler-load: dependency package manifest not found for "
          source-path))]
    [(CompilerLoadSomePath manifest-path)
      (match (compiler-load-parse-manifest-diagnostic-infer-kind
        (string.copy manifest-path)
        (compiler-load-session-read-source-text manifest-path))
        [(Err diag)
          (Err
            (str_cat.str-cat
              "compiler-load: invalid dependency package manifest '"
              manifest-path
              "': "
              (cdiag.compiler-diagnostic-message (__tl-box-place diag))))]
        [(Ok manifest)
          (let
            [manifest-dir : String (compiler-load-dirname manifest-path)]
            (Ok
              (CompilerLoadPackageEntry
                (compiler-load-normalize-path
                  (compiler-load-join-root-path
                    (string.copy manifest-dir)
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
  [paths : (& paths ast.AstDeclPathList)]
  [modules : (& modules ast.AstDeclModuleList)]
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
      [(Module name) (sym_i64_env.sym-i64-contains-id seen name)]
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
  [hydration : (& hydration surface_hydrate.CompilerSurfaceHydration)]
  [seen : sym_i64_env.SymI64Env]) : CompilerLoadDependencySurfaceSelection
  (let
    [surface : surface_ast.SurfaceAstHydration hydration.ast]
    [count : i64 (ast.ast-decl-list-len (& surface.decls))]
    [decls : ast.AstDeclList (ast.ast-decl-list-with-capacity count)]
    [paths : ast.AstDeclPathList (ast.ast-decl-path-list-with-capacity count)]
    [modules : ast.AstDeclModuleList
      (ast.ast-decl-module-list-with-capacity count)]
    [index : i64 0]
    (while (< index count)
      (unless
        (compiler-load-dependency-surface-decl-seen?
          seen
          (ast.ast-decl-list-get
            (& surface.decls)
            index
            (ast.ast-decl-fallback))
          surface.paths
          surface.modules
          index)
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
            cbi.compiler-builtin-id-fix-empty)))
      (set! index (+ index 1)))
    (CompilerLoadDependencySurfaceSelection decls paths modules)))

(define (compiler-load-dependency-surface-merge-seen
  [base : sym_i64_env.SymI64Env]
  [extra : sym_i64_env.SymI64Env]) : sym_i64_env.SymI64Env
  (let
    [cursor : sym_i64_env.SymI64Env extra]
    [out : sym_i64_env.SymI64Env base]
    [done : bool false]
    (while (not done)
      (match (sym_i64_env.sym-i64-view cursor)
        [(SymI64ViewNil) (set! done true)]
        [(SymI64ViewBind key value rest)
          (if (and
            (sym_i64_env.sym-i64-contains-id out key)
            (= (sym_i64_env.sym-i64-lookup-id-or out key -1) value))
            unit
            (set! out (sym_i64_env.sym-i64-bind-id out key value)))
          (set! cursor rest)]))
    out))

(define (compiler-load-dependency-surface-interface
  [version : String]
  [spmd-callables : tlci.TlciSpmdCallables]) : CompilerLoadPackageSpmdInterface
  (Available version spmd-callables))

(define (compiler-load-dependency-surface-final-module-id
  [decls : ast.AstDeclList]
  [fallback : i64]) : i64
  (let
    [cursor : ast.AstDeclList decls]
    [module-id : i64 fallback]
    [done : bool false]
    (while (not done)
      (match (ast.ast-decl-list-step cursor)
        [(Nil) (set! done true)]
        [(Cons decl rest)
          (match decl
            [(Module next-module) (set! module-id next-module)]
            [_ unit])
          (set! cursor rest)]))
    module-id))

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
  [paths : (& paths ast.AstDeclPathList)]) : i64
  (let
    [count : i64 (ast.ast-decl-path-list-len (& paths))]
    [index : i64 0]
    [matched : i64 0]
    (while (< index count)
      (if (compiler-load-session-state-dependency-surface-provenance?
        (owned_view.compiler-owned-shared-view state)
        (ast.ast-decl-path-list-provenance-id
          (& paths)
          index
          cbi.compiler-builtin-id-fix-empty))
        (set! matched (+ matched 1))
        unit)
      (set! index (+ index 1)))
    matched))

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
      Unavailable
      (let
        [slot : i64
          (compiler-load-dependency-catalog-slot-for-provenance-id
            (owned_view.compiler-owned-shared-view state)
            (compiler-load-source-path-id resolved))]
        [fragments : CompilerLoadDependencySurfaceList
          (owned_view.compiler-owned-array-element-shared-view
            surface-state.fragments
            0)]
        (if (or (< slot 0) (>= slot fragments.len))
          Unavailable
          (match (owned_view.compiler-owned-array-element-shared-view
            fragments.slots
            slot)
            [(Unavailable) Unavailable]
            [(Ready hydration spmd-callables)
              (let
                [selection : CompilerLoadDependencySurfaceSelection
                  (compiler-load-dependency-surface-select hydration seen)]
                [active-pools : ast.AstNodePoolContext
                  (if (ast.ast-node-pool-has-active-context?)
                    (ast.ast-node-pool-context-active-live)
                    (ast.ast-node-pool-context-capture-active))]
                [copy : ast.AstProgramCompaction
                  (ast.ast-program-copy-append-with-pools
                    hydration.ast.pools
                    active-pools
                    (& (ast.ast-program selection.decls)))]
                [copied-program : ast.AstProgram
                  (match (owned_view.compiler-owned-shared-view copy)
                    [(AstProgramCompaction program _) program])]
                [copied-decls : ast.AstDeclList
                  (match copied-program
                    [(Program decls-box) (__tl-box-place decls-box)])]
                [copied-pools : ast.AstNodePoolContext
                  (match copy
                    [(AstProgramCompaction _ pools) pools])]
                [explicit-module : bool
                  (compiler-load-decl-list-has-module? copied-decls)]
                [module-id-fallback-id : i64
                  (compiler-load-module-fallback-id-for-parse
                    (owned_view.compiler-owned-shared-view module-id-fallback)
                    expected-module)]
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
                    seen
                    hydration.ast.seen)]
                (ast.ast-node-pool-context-install! copied-pools)
                ;; Source loading publishes this compact summary before
                ;; traversing a file. Rebuild the same summary from the
                ;; hydrated AST so qualified macro imports retain their
                ;; ordinary visibility rules. The registry's exact package
                ;; and source binding already authenticated these decls;
                ;; package import spellings need not equal a declared module.
                (compiler-load-surface-summary-remove-source!
                  (compiler-load-source-path-id resolved))
                (compiler-load-record-surface-summary!
                  (compiler-load-surface-summary-from-decls
                    (owned_view.compiler-owned-shared-view resolved)
                    (compiler-load-source-path-id resolved)
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
                  (compiler-load-dependency-surface-interface
                    entry.version
                    spmd-callables))
                  [(Err _) Unavailable]
                  [(Ok decls paths modules loaded-seen)
                    (let
                      [decl-count : i64 (ast.ast-decl-list-len (& decls))]
                      [provenance-count : i64
                        (compiler-load-dependency-surface-provenance-count
                          state
                          paths)]
                      (if (array-ref fragments.imported slot)
                        unit
                        (match (surface_facts.surface-typecheck-facts-builder-append
                          (owned_view.compiler-owned-array-element-shared-view
                            surface-state.facts-builder
                            0)
                          hydration.facts)
                          [(Err _) (return Unavailable)]
                          [(Ok next)
                            (set!
                              (array-ref surface-state.facts-builder 0)
                              next)
                            (set! (array-ref fragments.imported slot) true)]))
                      (set! (array-ref surface-state.fragments 0) fragments)
                      (set!
                        (array-ref surface-state.surface-decl-count 0)
                        (+
                          (array-ref surface-state.surface-decl-count 0)
                          decl-count))
                      (set!
                        (array-ref surface-state.surface-provenance-count 0)
                        (+
                          (array-ref surface-state.surface-provenance-count 0)
                          provenance-count))
                      (set!
                        (array-ref surface-state.hit-count 0)
                        (+ (array-ref surface-state.hit-count 0) 1))
                      (Ok (Ok decls paths modules loaded-seen)))]))]))))))

(define (compiler-load-package-externs-from-import
  [resolved : String]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : svec.Vec]
  [expected-module : ast.AstMaybeModuleName]
  [cfgs : sym_i64_env.SymI64Env]
  [module-id-fallback : String]
  [source-module-fallback : String]) : ResultCompilerLoadWithPaths
  (match (compiler-load-package-entry-for-source (string.copy resolved))
    [(Err message)
      (Err
        (box
          (cdiag.compiler-diagnostic-at-start (string.copy resolved) message)))]
    [(Ok entry)
      (match (compiler-load-dependency-surface-import
        (string.copy resolved)
        seen
        (ast.ast-place-shared-view stdlib-roots)
        (owned_view.compiler-owned-shared-view entry)
        expected-module
        (string.copy module-id-fallback)
        (string.copy source-module-fallback))
        [(Ok loaded) loaded]
        [(Unavailable)
          (match (compiler-load-package-spmd-interface
            (string.copy entry.manifest-dir)
            (string.copy entry.owner)
            (string.copy entry.version))
            [(Err message)
              (Err (box (cdiag.compiler-diagnostic-at-start resolved message)))]
            [(Ok spmd-interface)
              (match (compiler-load-file-with-paths-and-roots-expect-cfg-fallback
                (string.copy resolved)
                seen
                (ast.ast-place-shared-view stdlib-roots)
                expected-module
                cfgs
                module-id-fallback
                source-module-fallback)
                [(Ok imported-decls imported-paths _ import-seen)
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
                [(Err diag) (Err diag)])])])]))

(define (compiler-load-package-expand-include
  [kind : CompilerLoadIncludeKind]
  [importer-path : String]
  [include-path : String]
  [name : i64]
  [stdlib-roots : svec.Vec]
  [manifest-dir : String]
  [deps : CompilerPkgDeps]) : ResultCompilerLoadInclude
  (match (if (compiler-load-pkg-import? include-path)
    (compiler-load-resolve-pkg-import
      (string.copy include-path)
      manifest-dir
      deps)
    (compiler-load-resolve-import-result-with-roots
      (string.copy importer-path)
      (string.copy include-path)
      stdlib-roots))
    [(Ok resolved)
      (compiler-load-include-from-resolved
        kind
        importer-path
        include-path
        resolved
        name)]
    [(Err message)
      (Err (box (cdiag.compiler-diagnostic-at-start importer-path message)))]))

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
  (match (ast.ast-decl-list-step decls)
    [(Nil)
      (Ok
        (ast.ast-decl-list-new)
        (ast.ast-decl-path-list-new)
        (ast.ast-decl-module-list-new)
        seen)]
    [(Cons decl rest)
      (let
        [rest : ast.AstDeclList rest]
        (match (clone decl)
          [(Import decl-meta (Spec kind import-path expected-module alias span))
            (if (compiler-load-macro-import-kind? kind)
              (match (compiler-load-package-decls-with-module-and-roots
                rest
                (string.copy importer-path)
                importer-path-id
                importer-module
                importer-module-id
                (string.copy importer-source-module)
                importer-source-module-id
                seen
                stdlib-roots
                (string.copy manifest-dir)
                deps
                cfgs)
                [(Ok rest-decls rest-paths rest-modules rest-seen)
                  (Ok
                    (compiler-load-decl-list-prepend-from-source
                      decl
                      decls
                      rest-decls)
                    (ast.ast-decl-path-list-prepend-builder-with-owner-id
                      (string.copy importer-path)
                      importer-path-id
                      rest-paths)
                    (ast.ast-decl-module-list-prepend-builder-id
                      importer-module-id
                      rest-modules)
                    rest-seen)]
                [(Err diag) (Err diag)])
              (match (compiler-load-resolve-package-import-spec-classified
                (owned_view.compiler-owned-shared-view importer-path)
                kind
                import-path
                expected-module
                alias
                (owned_view.compiler-owned-shared-view stdlib-roots)
                (owned_view.compiler-owned-shared-view manifest-dir)
                (owned_view.compiler-owned-shared-view deps))
                [(Ok import)
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
                        (string.copy import-path)
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
                        (string.copy import-path)
                        (string.copy resolved))]
                    [source-fallback : String
                      (compiler-load-canonical-source-module-from-import
                        (clone kind)
                        (string.copy import-path)
                        (string.copy resolved)
                        (clone expected-module)
                        (string.copy importer-source-module))]
                    [preload-candidate : bool
                      (and
                        (not package-externs)
                        (compiler-load-lazy-import-preload-candidate?
                          (string.copy importer-path)
                          (clone kind)
                          (clone alias)))]
                    [preload-pools : ast.AstNodePoolContext
                      (ast.ast-node-pool-context-capture-active)]
                    [preload-demand : CompilerLoadLazyAliasDemand
                      (compiler-load-lazy-import-preload-demand
                        preload-candidate
                        (clone alias)
                        (ast.ast-place-shared-view rest)
                        preload-pools)]
                    [preload-summary-needed : bool
                      (and
                        preload-candidate
                        (not
                          (or preload-demand.qualified preload-demand.unknown)))]
                    [_preload-summary : unit
                      (if preload-summary-needed
                        (compiler-load-lazy-import-preload-summary-with-pools
                          (string.copy resolved)
                          resolved-id
                          (ast.ast-place-shared-view stdlib-roots)
                          (clone expected-module)
                          (string.copy manifest-dir)
                          cfgs
                          preload-pools)
                        unit)]
                    [preload-skip : bool
                      (if preload-summary-needed
                        (compiler-load-lazy-import-skip?
                          (string.copy importer-path)
                          (clone kind)
                          (string.copy resolved)
                          resolved-id
                          (clone expected-module)
                          (clone alias)
                          (ast.ast-place-shared-view rest)
                          preload-pools
                          (clone preload-demand)
                          (ast.ast-place-shared-view stdlib-roots))
                        false)]
                    (match (if preload-skip
                      (ResultCompilerLoadWithPaths.Ok
                        (ast.ast-decl-list-new)
                        (ast.ast-decl-path-list-new)
                        (ast.ast-decl-module-list-new)
                        seen)
                      (if package-externs
                        (compiler-load-package-externs-from-import
                          (string.copy resolved)
                          seen
                          (ast.ast-place-shared-view stdlib-roots)
                          (clone source-expected-module)
                          cfgs
                          (string.copy fallback)
                          "")
                        (compiler-load-package-file-with-paths-and-roots-expect-cache-current-fallback
                          (string.copy resolved)
                          resolved-id
                          seen
                          (ast.ast-place-shared-view stdlib-roots)
                          (clone expected-module)
                          (string.copy manifest-dir)
                          (ast.ast-place-shared-view deps)
                          cfgs
                          true
                          (string.copy fallback)
                          (string.copy source-fallback)
                          (if (string.eq source-fallback importer-source-module)
                            importer-source-module-id
                            -1))))
                      [(Ok
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
                              kind
                              expected-module
                              alias
                              (ast.ast-place-shared-view imported-decls))]
                          (when
                            (not
                              (or
                                (compiler-load-expected-module-seen?
                                  seen
                                  validated-module)
                                (compiler-load-selected-item-present-or-pending?
                                  kind
                                  validated-module
                                  (ast.ast-place-shared-view imported-decls))))
                            (return
                              (Err
                                (box
                                  (cdiag.compiler-diagnostic-from-ast-span
                                    importer-path
                                    (__tl-box-place span)
                                    (compiler-load-missing-selected-item-message
                                      import-path
                                      kind))))))
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
                            [(Ok rest-decls rest-paths rest-modules rest-seen)
                              (let
                                [after-import-expected : ast.AstMaybeModuleName
                                  validated-module]
                                [after-import-alias : ast.AstMaybeImportAlias
                                  (compiler-load-after-import-alias
                                    (compiler-load-active-session-state-shared-view)
                                    resolved-id
                                    kind
                                    expected-module
                                    alias
                                    (ast.ast-place-shared-view imported-decls))]
                                (if lazy-skip
                                  (begin
                                    (compiler-load-lazy-import-record-skip!)
                                    (Ok
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
                                        after-import-alias
                                        (ast.ast-decl-list-new)
                                        rest-paths)
                                      (let
                                        [bound-8 (ast.ast-decl-list-new)]
                                        (compiler-load-modules-after-import
                                          importer-module-id
                                          after-import-alias
                                          bound-8
                                          rest-modules))
                                      rest-seen))
                                  (let
                                    [after-decls : ast.AstDeclList
                                      (compiler-load-decls-after-import
                                        kind
                                        resolved
                                        after-import-expected
                                        after-import-alias
                                        (__tl-box-place span)
                                        importer-source-module
                                        importer-source-module-id
                                        decls
                                        (ast.ast-place-shared-view
                                          imported-decls)
                                        rest-decls)]
                                    [after-paths : ast.AstDeclPathList
                                      (compiler-load-paths-after-import
                                        importer-path
                                        importer-path-id
                                        importer-path-id
                                        after-import-alias
                                        (ast.ast-place-shared-view
                                          imported-decls)
                                        rest-paths)]
                                    [after-modules : ast.AstDeclModuleList
                                      (compiler-load-modules-after-import
                                        importer-module-id
                                        after-import-alias
                                        imported-decls
                                        rest-modules)]
                                    (Ok
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
                            [(Err diag) (Err diag)]))]
                      [(Err diag) (Err diag)]))]
                [(Err message)
                  (Err
                    (box
                      (cdiag.compiler-diagnostic-from-ast-span
                        importer-path
                        (__tl-box-place span)
                        message)))]))]
          [(IncludeStr name include-path)
            (let
              [expanded
                (try
                  (compiler-load-package-expand-include
                    RuntimeString
                    (string.copy importer-path)
                    include-path
                    name
                    (ast.ast-place-shared-view stdlib-roots)
                    (string.copy manifest-dir)
                    (ast.ast-place-shared-view deps)))]
              (compiler-load-prepend-include
                RuntimeString
                expanded
                decls
                (string.copy importer-path)
                importer-path-id
                importer-path-id
                importer-module-id
                (compiler-load-package-decls-with-module-and-roots
                  rest
                  (string.copy importer-path)
                  importer-path-id
                  importer-module
                  importer-module-id
                  (string.copy importer-source-module)
                  importer-source-module-id
                  seen
                  stdlib-roots
                  (string.copy manifest-dir)
                  deps
                  cfgs)))]
          [(IncludeStrComptime name include-path)
            (let
              [expanded
                (try
                  (compiler-load-package-expand-include
                    ComptimeString
                    (string.copy importer-path)
                    include-path
                    name
                    (ast.ast-place-shared-view stdlib-roots)
                    (string.copy manifest-dir)
                    (ast.ast-place-shared-view deps)))]
              (compiler-load-prepend-include
                ComptimeString
                expanded
                decls
                (string.copy importer-path)
                importer-path-id
                importer-path-id
                importer-module-id
                (compiler-load-package-decls-with-module-and-roots
                  rest
                  (string.copy importer-path)
                  importer-path-id
                  importer-module
                  importer-module-id
                  (string.copy importer-source-module)
                  importer-source-module-id
                  seen
                  stdlib-roots
                  (string.copy manifest-dir)
                  deps
                  cfgs)))]
          [(IncludeStrLzss name include-path)
            (let
              [expanded
                (try
                  (compiler-load-package-expand-include
                    LzssString
                    (string.copy importer-path)
                    include-path
                    name
                    (ast.ast-place-shared-view stdlib-roots)
                    (string.copy manifest-dir)
                    (ast.ast-place-shared-view deps)))]
              (compiler-load-prepend-include
                LzssString
                expanded
                decls
                (string.copy importer-path)
                importer-path-id
                importer-path-id
                importer-module-id
                (compiler-load-package-decls-with-module-and-roots
                  rest
                  (string.copy importer-path)
                  importer-path-id
                  importer-module
                  importer-module-id
                  (string.copy importer-source-module)
                  importer-source-module-id
                  seen
                  stdlib-roots
                  (string.copy manifest-dir)
                  deps
                  cfgs)))]
          [(IncludeBin name include-path)
            (let
              [expanded
                (try
                  (compiler-load-package-expand-include
                    Binary
                    (string.copy importer-path)
                    include-path
                    name
                    (ast.ast-place-shared-view stdlib-roots)
                    (string.copy manifest-dir)
                    (ast.ast-place-shared-view deps)))]
              (compiler-load-prepend-include
                Binary
                expanded
                decls
                (string.copy importer-path)
                importer-path-id
                importer-path-id
                importer-module-id
                (compiler-load-package-decls-with-module-and-roots
                  rest
                  (string.copy importer-path)
                  importer-path-id
                  importer-module
                  importer-module-id
                  (string.copy importer-source-module)
                  importer-source-module-id
                  seen
                  stdlib-roots
                  (string.copy manifest-dir)
                  deps
                  cfgs)))]
          [_
            (match (compiler-load-package-decls-with-module-and-roots
              rest
              (string.copy importer-path)
              importer-path-id
              importer-module
              importer-module-id
              (string.copy importer-source-module)
              importer-source-module-id
              seen
              stdlib-roots
              (string.copy manifest-dir)
              deps
              cfgs)
              [(Ok rest-decls rest-paths rest-modules rest-seen)
                (Ok
                  (compiler-load-decl-list-prepend-from-source
                    decl
                    decls
                    rest-decls)
                  (ast.ast-decl-path-list-prepend-builder-with-owner-id
                    (string.copy importer-path)
                    importer-path-id
                    rest-paths)
                  (ast.ast-decl-module-list-prepend-builder-id
                    importer-module-id
                    rest-modules)
                  rest-seen)]
              [(Err diag) (Err diag)])]))]))

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
        [(Program decls-box)
          (let
            [decls : ast.AstDeclList (deref decls-box)]
            [effective-source-module-fallback : String
              (if (> (string.string-length source-module-fallback) 0)
                (owned_view.compiler-owned-shared-view source-module-fallback)
                (if (compiler-load-stdlib-source-module-import?
                  (compiler-load-normalize-path path))
                  (owned_view.compiler-owned-shared-view module-id-fallback)
                  ""))]
            [source-module : String
              (compiler-load-decls-source-module-or
                (ast.ast-place-shared-view decls)
                (string.copy effective-source-module-fallback))]
            [source-module-id : i64
              (if (compiler-load-decl-list-has-module? decls)
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
                (string.copy source-module)
                source-module-id)]
            (match (compiler-load-decls-module-id-with-fallback
              (string.copy source-path)
              (ast.ast-place-shared-view decls)
              (string.copy module-id-fallback)
              module-id-fallback-id)
              [(Ok module-id module-name-id)
                (match (compiler-load-check-expected-module
                  (string.copy source-path)
                  (clone expected-module)
                  (string.copy module-id)
                  module-name-id)
                  [(Ok _ _)
                    (if (compiler-load-seen-module-contains?
                      seen
                      (string.copy module-id)
                      module-name-id)
                      (compiler-load-seen-module-with-paths
                        (string.copy source-path)
                        source-path-id
                        (string.copy module-id)
                        module-name-id
                        load-decls
                        seen)
                      (match (compiler-load-check-dotted-import-aliases
                        (string.copy source-path)
                        (ast.ast-place-shared-view load-decls)
                        (string.copy source-module))
                        [(Ok)
                          ;; Replace a speculative lazy summary with the
                          ;; identity established by the actual load.
                          (compiler-load-surface-summary-remove-source!
                            source-path-id)
                          (compiler-load-record-surface-summary!
                            (compiler-load-surface-summary-from-decls
                              (string.copy source-path)
                              source-path-id
                              (string.copy manifest-dir)
                              module-name-id
                              source-module-id
                              (compiler-load-decl-list-has-module? decls)
                              (not
                                (compiler-load-no-expected-module?
                                  (clone expected-module)))
                              (ast.ast-place-shared-view load-decls)))
                          (compiler-load-package-decls-with-module-and-roots
                            load-decls
                            (string.copy source-path)
                            source-path-id
                            (string.copy module-id)
                            module-name-id
                            (string.copy source-module)
                            source-module-id
                            (compiler-load-seen-module-bind
                              seen
                              (string.copy module-id)
                              module-name-id)
                            stdlib-roots
                            (string.copy manifest-dir)
                            deps
                            cfgs)]
                        [(Err diag) (Err diag)]))]
                  [(Err diag) (Err diag)])]
              [(Err diag) (Err diag)]))])]
    (compiler-load-surface-summary-load-exit!)
    (if (= entry-depth 0)
      (match loaded
        [(Ok decls paths modules loaded-seen)
          (let
            [_
              (try
                (compiler-load-check-unqualified-import-collisions
                  source-path
                  (ast.ast-place-shared-view decls)
                  paths))]
            (Ok decls paths modules loaded-seen))]
        [(Err diag) (Err diag)])
      loaded)))

(define (compiler-load-package-program-with-paths-and-roots-expect
  [path : (& path str)]
  [program : ast.AstProgram]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : svec.Vec]
  [expected-module : ast.AstMaybeModuleName]
  [manifest-dir : String]
  [deps : CompilerPkgDeps]
  [cfgs : sym_i64_env.SymI64Env]
  [parse-identity : CompilerLoadParseIdentity]) : ResultCompilerLoadWithPaths
  (compiler-load-package-program-with-paths-and-roots-expect-fallback
    (string.copy path)
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
          (string.copy module-id-fallback)
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
    (if (io.file-exists? (string.copy path))
      (let
        [program
          (try
            (if cache-current
              (compiler-load-parse-file-diagnostic-session-id
                (string.copy path)
                source-path-id
                (ast.ast-place-shared-view stdlib-roots)
                parse-cfgs)
              (compiler-load-parse-file-diagnostic-escaping
                (string.copy path)
                parse-cfgs)))]
        (compiler-load-package-program-with-paths-and-roots-expect-fallback
          (string.copy path)
          program
          seen
          stdlib-roots
          (clone expected-module)
          (string.copy manifest-dir)
          deps
          parse-cfgs
          (string.copy module-id-fallback)
          (clone parse-identity)
          (string.copy source-module-fallback)
          source-module-fallback-id))
      (match (compiler-load-embedded-stdlib-source-for-path (string.copy path))
        [(CompilerEmbeddedStdlibSomeSource source)
          (let
            [program
              (try
                (if cache-current
                  (compiler-load-parse-embedded-source-diagnostic-session-id
                    (string.copy path)
                    source-path-id
                    (string.copy source)
                    parse-cfgs)
                  (compiler-load-parse-source-diagnostic-escaping
                    (string.copy path)
                    source
                    parse-cfgs)))]
            (compiler-load-package-program-with-paths-and-roots-expect-fallback
              (string.copy path)
              program
              seen
              stdlib-roots
              (clone expected-module)
              (string.copy manifest-dir)
              deps
              parse-cfgs
              (string.copy module-id-fallback)
              (clone parse-identity)
              (string.copy source-module-fallback)
              source-module-fallback-id))]
        [(CompilerEmbeddedStdlibNoSource)
          (Err
            (box
              (cdiag.compiler-diagnostic-at-start
                (string.copy path)
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
    (string.copy path)
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
    No
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
    No
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
        (string.copy path)
        (compiler-load-canonical-module-id-from-path path)
        No)]
    [program
      (try
        (compiler-load-parse-source-diagnostic-escaping
          (string.copy path)
          source
          parse-cfgs))]
    (compiler-load-package-program-with-paths-and-roots-expect
      path
      program
      seen
      stdlib-roots
      No
      manifest-dir
      deps
      parse-cfgs
      parse-identity)))

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
      (string.copy suffix)
      (ast.ast-place-shared-view stdlib-roots))
      [(CompilerLoadSomePath source-path)
        (compiler-load-note-embedded-equivalent-if-matching!
          suffix
          (string.copy source-path))
        (compiler-load-package-stdlib-prelude-source-with-roots-cfg
          (string.copy path)
          (compiler-load-session-read-source-text source-path)
          seen
          stdlib-roots
          (string.copy manifest-dir)
          deps
          cfgs)]
      [(CompilerLoadNoPath)
        (match (compiler-load-embedded-stdlib-source suffix)
          [(CompilerEmbeddedStdlibSomeSource source)
            (compiler-load-note-embedded-module! (string.copy path))
            (compiler-load-session-note-embedded-stdlib-source!)
            (compiler-load-package-stdlib-prelude-source-with-roots-cfg
              (string.copy path)
              source
              seen
              stdlib-roots
              (string.copy manifest-dir)
              deps
              cfgs)]
          [(CompilerEmbeddedStdlibNoSource)
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
      (string.copy manifest-dir)
      (ast.ast-place-shared-view deps)
      cfgs)
      [(Ok runtime-decls runtime-paths runtime-modules runtime-seen)
        (match (compiler-load-package-core-macro-prelude-with-roots-cfg
          runtime-seen
          (ast.ast-place-shared-view stdlib-roots)
          (string.copy manifest-dir)
          (ast.ast-place-shared-view deps)
          cfgs)
          [(Ok macro-decls macro-paths macro-modules prelude-seen)
            (match (compiler-load-package-entry-file-with-paths-and-roots-cfg
              (string.copy input-path)
              prelude-seen
              stdlib-roots
              (string.copy manifest-dir)
              deps
              cfgs)
              [(Ok entry-decls entry-paths entry-modules seen)
                (Ok
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
              [(Err diag) (Err diag)])]
          [(Err diag) (Err diag)])]
      [(Err diag) (Err diag)])
    (match (compiler-load-package-core-macro-prelude-with-roots-cfg
      (sym_i64_env.sym-i64-empty)
      (ast.ast-place-shared-view stdlib-roots)
      (string.copy manifest-dir)
      (ast.ast-place-shared-view deps)
      cfgs)
      [(Ok prelude-decls prelude-paths prelude-modules prelude-seen)
        (match (compiler-load-package-entry-file-with-paths-and-roots-cfg
          input-path
          prelude-seen
          stdlib-roots
          manifest-dir
          deps
          cfgs)
          [(Ok entry-decls entry-paths entry-modules seen)
            (Ok
              (compiler-load-decl-list-append prelude-decls entry-decls)
              (compiler-load-decl-path-list-append prelude-paths entry-paths)
              (compiler-load-decl-module-list-append
                prelude-modules
                entry-modules)
              seen)]
          [(Err diag) (Err diag)])]
      [(Err diag) (Err diag)])))

(define (compiler-load-dependency-surfaces-restore-base!
  [surface-state : (& surface-state CompilerLoadDependencySurfaceState)]) : unit
  (match (array-ref surface-state.base-facts 0)
    [(None) (surface_facts.surface-typecheck-facts-clear!)]
    [(Some facts)
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
      [(Err diag)
        (compiler-load-dependency-surfaces-restore-base! surface-state)
        (Err diag)]
      [(Ok decls paths modules seen)
        (if (or (not (array-ref surface-state.enabled 0)) (<= surface-count 0))
          (begin
            (compiler-load-dependency-surfaces-restore-base! surface-state)
            (Ok decls paths modules seen))
          (match (surface_facts.surface-typecheck-facts-builder-finish
            (clone (array-ref surface-state.facts-builder 0)))
            [(Err _)
              (compiler-load-dependency-surfaces-restore-base! surface-state)
              (Ok decls paths modules seen)]
            [(Ok composed)
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
                (if published
                  unit
                  (compiler-load-dependency-surfaces-restore-base!
                    surface-state))
                (Ok decls paths modules seen))]))])))

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
        cfgs)]
    [loaded : ResultCompilerLoadWithPaths
      (compiler-load-package-file-with-runtime-cfg-inner
        input-path
        stdlib-roots
        manifest-dir
        deps
        emit-entry
        cfgs)]
    (compiler-load-dependency-surfaces-finalize! (& state) loaded)))

(define (compiler-load-test-mkdir-direct [path : String]) : bool
  (match (fs.try-mkdir-if-missing (& path))
    [(OkIoUnit) true]
    [(ErrIoUnit _) false]))

(define (compiler-load-test-mkdir [path : String]) : bool
  (if (compiler-load-string-prefix-at? path "target/" 0)
    (and
      (compiler-load-test-mkdir-direct "target")
      (compiler-load-test-mkdir-direct path))
    (compiler-load-test-mkdir-direct path)))

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

;: First normal package dependency carried by a manifest, when present.
;: The dedicated result keeps package-edge policy separate from native
;: `(link ...)` metadata.
(defenum CompilerPkgMaybeDependency
  (NoDependency)
  (Dependency CompilerPkgDep))

;: Count the dependencies in a parsed list.
(define (compiler-pkg-dep-list-count [deps : (& deps CompilerPkgDepList)]) : i64
  deps.len)

(define (compiler-pkg-dep-list-at
  [deps : (& deps CompilerPkgDepList)]
  [index : i64]) : CompilerPkgDep
  (clone (array-ref deps.slots index)))

(define (compiler-pkg-dep-list-empty) : CompilerPkgDepList
  (CompilerPkgDepList (__tl_make-array CompilerPkgDep 0) 0))

(define (compiler-pkg-dep-list-copy-into
  [dst : (&mut dst (__tl_dyn-array CompilerPkgDep))]
  [src : (& src CompilerPkgDepList)]
  [dst-offset : i64]) : unit
  (let
    [n : i64 src.len]
    [index : i64 0]
    (while (< index n)
      (set!
        (array-ref dst (+ dst-offset index))
        (clone (array-ref src.slots index)))
      (set! index (+ index 1)))))

;: Append `dep`. Every push right-sizes a fresh array, so callers that keep
;: extending the same list from several branches never share a buffer.
(define (compiler-pkg-dep-list-push
  [deps : CompilerPkgDepList]
  [dep : CompilerPkgDep]) : CompilerPkgDepList
  (let
    [n : i64 (compiler-pkg-dep-list-count deps)]
    [slots : (__tl_dyn-array CompilerPkgDep)
      (__tl_make-array CompilerPkgDep (+ n 1))]
    (compiler-pkg-dep-list-copy-into (&mut slots) (& deps) 0)
    (set! (array-ref slots n) dep)
    (CompilerPkgDepList slots (+ n 1))))

;: Prepend `dep`, right-sizing a fresh array like `compiler-pkg-dep-list-push`.
(define (compiler-pkg-dep-list-cons
  [dep : CompilerPkgDep]
  [deps : CompilerPkgDepList]) : CompilerPkgDepList
  (let
    [n : i64 (compiler-pkg-dep-list-count deps)]
    [slots : (__tl_dyn-array CompilerPkgDep)
      (__tl_make-array CompilerPkgDep (+ n 1))]
    (set! (array-ref slots 0) dep)
    (compiler-pkg-dep-list-copy-into (&mut slots) (& deps) 1)
    (CompilerPkgDepList slots (+ n 1))))

(define (compiler-pkg-deps-empty) : CompilerPkgDeps
  (CompilerPkgDeps (compiler-pkg-dep-list-empty)))

(define (compiler-pkg-deps-list [deps : CompilerPkgDeps]) : CompilerPkgDepList
  deps.ordered)

(define (compiler-pkg-deps-count [deps : (& deps CompilerPkgDeps)]) : i64
  deps.ordered.len)

;: Return the first normal dependency of a library package. Binary package
;: dependencies and dependency-free libraries intentionally return none.
(define (compiler-pkg-manifest-first-library-dependency
  [manifest : (& manifest CompilerPkgManifest)]) : CompilerPkgMaybeDependency
  (match manifest.kind
    [(CompilerPkgKindBin) (NoDependency)]
    [(CompilerPkgKindLib)
      (let
        [deps : CompilerPkgDepList
          (compiler-pkg-deps-list (clone manifest.deps))]
        (if (= (compiler-pkg-dep-list-count (& deps)) 0)
          (NoDependency)
          (Dependency (compiler-pkg-dep-list-at (& deps) 0))))]))

;: Explain the dependency-free library invariant and its supported
;: composition/native-link alternatives.
(define (compiler-pkg-library-dependency-message
  [package-name : String]
  [alias : String]) : String
  (str_cat.str-cat
    "library package `"
    package-name
    "` cannot declare normal dependency `"
    (string.copy alias)
    "`; declare `"
    alias
    "` directly in the consuming application, remove or combine the library dependency, or use `link` for native libraries"))

(define (compiler-pkg-deps-alias-seen?
  [deps : CompilerPkgDeps]
  [target-alias : String]) : bool
  (let
    [ordered : CompilerPkgDepList (compiler-pkg-deps-list deps)]
    [index : i64 0]
    (while (< index (compiler-pkg-dep-list-count ordered))
      (let
        [dep : CompilerPkgDep (compiler-pkg-dep-list-at ordered index)]
        (if (string.eq dep.alias target-alias)
          (return true)
          (set! index (+ index 1)))))
    false))

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
    (while ok
      (if (< i n)
        (if (compiler-load-package-name-char? (string.string-ref value i))
          (set! i (+ i 1))
          (set! ok false))
        (set! ok false)))
    (= i n)))

(define (compiler-load-github-component-char? [c : char]) : bool
  (or (compiler-load-package-name-char? c) (= c '.')))

(define (compiler-load-github-component-valid? [value : String]) : bool
  (let
    [n : i64 (string.string-length value)]
    [i : i64 0]
    [ok : bool (> n 0)]
    (while ok
      (if (< i n)
        (if (compiler-load-github-component-char? (string.string-ref value i))
          (set! i (+ i 1))
          (set! ok false))
        (set! ok false)))
    (= i n)))

(define (compiler-load-github-dependency-path? [path : String]) : bool
  (compiler-load-string-prefix-at? path "https://github.com/" 0))

(define (compiler-load-github-pin-kind-valid? [kind : String]) : bool
  (or (string.eq kind "rev") (string.eq kind "tag") (string.eq kind "branch")))

(define (compiler-load-github-address-body [address : String]) : String
  (if (compiler-load-string-prefix-at? address "github.com/" 0)
    (string.substring address 11 (- (string.string-length address) 11))
    address))

(define (compiler-load-github-address-error [alias : String]) : ResultPkgString
  (Err
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
          [(not (compiler-load-github-component-valid? (string.copy owner)))
            (compiler-load-github-address-error alias)]
          [(not (compiler-load-github-component-valid? (string.copy repo)))
            (compiler-load-github-address-error alias)]
          [else
            (Ok
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
  [ftail : (& program (Slice reader.SpannedSexpr))]
  [fname : String]) : ResultPkgString
  (match ftail
    [(slice (Str val-id _))
      (Ok (compiler-load-manifest-owned-intern-text val-id))]
    [(slice (Str _ _) & _)
      (Err
        (str_cat.str-cat
          "manifest field `"
          fname
          "` takes a single string value"))]
    [_
      (Err
        (str_cat.str-cat "manifest field `" fname "` must have a string value"))]))

(define (compiler-load-manifest-github-pin
  [alias : String]
  [address : String]
  [pin-form : reader.SpannedSexpr]) : ResultPkgString
  (match (reader.sexpr-view pin-form)
    [(List (slice (Sym pin-kind _) & pin-tail))
      (if (compiler-load-github-pin-kind-valid?
        (compiler-load-symbol-text pin-kind))
        (match pin-tail
          [(slice (Str pin-value-id _))
            (let
              [pin-value : String (ci.intern-id-str pin-value-id)]
              (if (string.eq pin-value "")
                (Err
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
            (Err
              (str_cat.str-cat
                "manifest dependency `"
                alias
                "` github pin must be a single string value"))])
        (Err
          (str_cat.str-cat
            "manifest dependency `"
            alias
            "` github pin must be rev, tag, or branch")))]
    [_
      (Err
        (str_cat.str-cat
          "manifest dependency `"
          alias
          "` github source requires exactly one rev, tag, or branch pin"))]))

(define (compiler-load-manifest-github-value
  [alias : String]
  [source-tail : (& program (Slice reader.SpannedSexpr))]) : ResultPkgString
  (match source-tail
    [(slice (Str address-id _) & after-address)
      (let
        [address : String (ci.intern-id-str address-id)]
        (match after-address
          [(slice pin-form)
            (compiler-load-manifest-github-pin alias address pin-form)]
          [_
            (Err
              (str_cat.str-cat
                "manifest dependency `"
                alias
                "` github source requires exactly one rev, tag, or branch pin"))]))]
    [_
      (Err
        (str_cat.str-cat
          "manifest dependency `"
          alias
          "` github source must be `(github \"owner/repo\" (rev|tag|branch \"pin\"))`"))]))

(define (compiler-load-manifest-dependency-value
  [etail : (& program (Slice reader.SpannedSexpr))]
  [alias : String]) : ResultPkgString
  (match etail
    [(slice (Str path-id _))
      (Ok (compiler-load-manifest-owned-intern-text path-id))]
    [(slice vhead)
      (match (reader.sexpr-view vhead)
        [(List (slice (Sym source-kind _) & source-tail))
          (if (string.eq (compiler-load-symbol-text source-kind) "github")
            (compiler-load-manifest-github-value alias source-tail)
            (Err
              (str_cat.str-cat
                "manifest dependency `"
                alias
                "` must be a path string or github source")))]
        [(List (slice _ & _))
          (Err
            (str_cat.str-cat
              "manifest dependency `"
              alias
              "` must be a path string or github source"))]
        [_
          (Err
            (str_cat.str-cat
              "manifest dependency `"
              alias
              "` must be a path string or github source"))])]
    [(slice _ & _)
      (Err
        (str_cat.str-cat
          "manifest dependency `"
          alias
          "` takes a single path string or github source"))]
    [_
      (Err
        (str_cat.str-cat
          "manifest dependency `"
          alias
          "` must be a path string or github source"))]))

(define (compiler-load-manifest-kind-token [val : String]) : ResultCompilerPkgKind
  (if (string.eq val "bin")
    (Ok (CompilerPkgKindBin))
    (if (or (string.eq val "staticlib") (string.eq val "lib"))
      (Ok (CompilerPkgKindLib))
      (Err "manifest field `kind` must be `bin`, `staticlib`, or `lib`"))))

(define (compiler-load-manifest-kind-value
  [ftail : (& program (Slice reader.SpannedSexpr))]) : ResultCompilerPkgKind
  (match ftail
    [(slice (Str val-id _))
      (compiler-load-manifest-kind-token (ci.intern-id-str val-id))]
    [(slice (Sym val _))
      (compiler-load-manifest-kind-token (compiler-load-symbol-text val))]
    [(slice _) (Err "manifest field `kind` must have a string or symbol value")]
    [(slice _ & _) (Err "manifest field `kind` takes a single value")]
    [_ (Err "manifest field `kind` must have a string or symbol value")]))

(define (compiler-load-manifest-cons-dep
  [alias : String]
  [path : String]
  [rest : (& program (Slice reader.SpannedSexpr))]) : ResultCompilerPkgDeps
  (cond
    [(string.eq alias "") (Err "dependency alias must not be empty")]
    [(not (compiler-load-package-token-valid? (string.copy alias)))
      (Err
        "dependency alias may only contain ASCII letters, digits, '-' and '_'")]
    [(string.eq path "")
      (Err
        (str_cat.str-cat
          "manifest dependency `"
          alias
          "` path must not be empty"))]
    [else
      (let
        [tail-deps (try (compiler-load-manifest-parse-deps rest))]
        (if (compiler-pkg-deps-alias-seen?
          (ast.ast-place-shared-view tail-deps)
          (string.copy alias))
          (Err (str_cat.str-cat "duplicate dependency alias `" alias "`"))
          (Ok (compiler-pkg-deps-cons alias path tail-deps))))]))

;: Parse the `(alias "path") ...` entries of a `(dependencies ...)` field.
(define (compiler-load-manifest-parse-deps
  [entries : (& program (Slice reader.SpannedSexpr))]) : ResultCompilerPkgDeps
  (match entries
    [(slice) (Ok (compiler-pkg-deps-empty))]
    [(slice entry & rest)
      (match (reader.sexpr-view entry)
        [(List (slice (Sym alias _) & etail))
          (let
            [alias-text : String
              (compiler-load-manifest-owned-syntax-text alias)]
            [path
              (try
                (compiler-load-manifest-dependency-value
                  etail
                  (string.copy alias-text)))]
            (compiler-load-manifest-cons-dep alias-text path rest))]
        [(List (slice _ & _))
          (Err "dependency entries must start with an alias name")]
        [_ (Err "dependency entries must be lists like `(alias \"path\")`")])]))

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
  [values : (& program (Slice reader.SpannedSexpr))]
  [fname : String]
  [acc : fs.FsStringVector]) : ResultPkgStrVec
  (match values
    [(slice)
      (if (= (fs.string-vector-len (& acc)) 0)
        (Err
          (str_cat.str-cat
            "`link` field `"
            fname
            "` requires at least one value"))
        (Ok acc))]
    [(slice (Str val-id _) & vrest)
      (let
        [val : String (ci.intern-id-str val-id)]
        (if (string.eq val "")
          (Err
            (str_cat.str-cat
              "`link` field `"
              fname
              "` values must not be empty"))
          (let
            [out : fs.FsStringVector acc]
            (fs.string-vector-push!
              (&mut out)
              (compiler-load-manifest-owned-intern-text val-id))
            (compiler-load-manifest-link-values vrest fname out))))]
    [(slice _ & _)
      (Err (str_cat.str-cat "`link` field `" fname "` values must be strings"))]))

;: Store one parsed sub-field into the accumulating link section, rejecting
;: unknown field names and a field that was already provided.
(define (compiler-load-manifest-link-store
  [acc : CompilerPkgLink]
  [fname : String]
  [values : fs.FsStringVector]) : ResultCompilerPkgLink
  (let
    [scope : i64 (compiler-load-link-field-scope (string.copy fname))]
    [cat : i64 (compiler-load-link-field-category (string.copy fname))]
    (if (or (< scope 0) (< cat 0))
      (Err (str_cat.str-cat "unknown `link` field `" fname "`"))
      (let
        [existing : fs.FsStringVector
          (compiler-pkg-link-get-vec (ast.ast-place-shared-view acc) scope cat)]
        (if (> (fs.string-vector-len (& existing)) 0)
          (Err (str_cat.str-cat "duplicate `link` field `" fname "`"))
          (Ok (compiler-pkg-link-set-vec acc scope cat values)))))))

;: Walk the `(field "...")` entries of a `(link ...)` section.
(define (compiler-load-manifest-parse-link-into
  [entries : (& program (Slice reader.SpannedSexpr))]
  [acc : CompilerPkgLink]) : ResultCompilerPkgLink
  (match entries
    [(slice) (Ok acc)]
    [(slice entry & rest)
      (match (reader.sexpr-view entry)
        [(List (slice (Sym fname _) & etail))
          (let
            [values
              (try
                (compiler-load-manifest-link-values
                  etail
                  (compiler-load-symbol-text fname)
                  (fs.string-vector-new)))]
            [acc2
              (try
                (compiler-load-manifest-link-store
                  acc
                  (compiler-load-symbol-text fname)
                  values))]
            (compiler-load-manifest-parse-link-into rest acc2))]
        [(List (slice _ & _))
          (Err "`link` entries must start with a field name")]
        [_ (Err "`link` entries must be lists like `(libraries \"...\")`")])]))

;: Parse a `(link ...)` manifest section into a CompilerPkgLink.
(define (compiler-load-manifest-parse-link
  [entries : (& program (Slice reader.SpannedSexpr))]) : ResultCompilerPkgLink
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
  [fields : (& program (Slice reader.SpannedSexpr))]
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
  (match fields
    [(slice)
      (let
        [final-entry : String
          (if has-entry
            entry
            (compiler-load-manifest-default-entry kind))]
        (cond
          [(not has-name) (Err "manifest missing required field `name`")]
          [(string.eq name "") (Err "manifest field `name` must not be empty")]
          [(not (compiler-load-package-token-valid? (string.copy name)))
            (Err
              "manifest field `name` may only contain ASCII letters, digits, '-' and '_'")]
          [(not has-version) (Err "manifest missing required field `version`")]
          [(string.eq version "")
            (Err "manifest field `version` must not be empty")]
          [(string.eq final-entry "")
            (Err "manifest field `entry` must not be empty")]
          [(not
              (compiler-load-normal-relative-entry? (string.copy final-entry)))
            (Err
              "manifest field `entry` must be a normal relative path below the manifest directory")]
          [else
            (Ok (CompilerPkgManifest name version kind final-entry deps link))]))]
    [(slice field & rest)
      (match (reader.sexpr-view field)
        [(List (slice (Sym fname _) & ftail))
          (cond
            [(string.eq (compiler-load-symbol-text fname) "dependencies")
              (if has-deps
                (Err "duplicate manifest field `dependencies`")
                (let
                  [parsed-deps (try (compiler-load-manifest-parse-deps ftail))]
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
                    link)))]
            [(string.eq (compiler-load-symbol-text fname) "link")
              (if has-link
                (Err "duplicate manifest field `link`")
                (let
                  [parsed-link (try (compiler-load-manifest-parse-link ftail))]
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
                    parsed-link)))]
            [(string.eq (compiler-load-symbol-text fname) "name")
              (if has-name
                (Err "duplicate manifest field `name`")
                (let
                  [val
                    (try
                      (compiler-load-manifest-string-value
                        ftail
                        (compiler-load-symbol-text fname)))]
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
                    link)))]
            [(string.eq (compiler-load-symbol-text fname) "version")
              (if has-version
                (Err "duplicate manifest field `version`")
                (let
                  [val
                    (try
                      (compiler-load-manifest-string-value
                        ftail
                        (compiler-load-symbol-text fname)))]
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
                    link)))]
            [(string.eq (compiler-load-symbol-text fname) "kind")
              (if has-kind
                (Err "duplicate manifest field `kind`")
                (let
                  [val (try (compiler-load-manifest-kind-value ftail))]
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
                    link)))]
            [(string.eq (compiler-load-symbol-text fname) "entry")
              (if has-entry
                (Err "duplicate manifest field `entry`")
                (let
                  [val
                    (try
                      (compiler-load-manifest-string-value
                        ftail
                        (compiler-load-symbol-text fname)))]
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
                    link)))]
            [else
              (Err
                (str_cat.str-cat
                  "unknown manifest field `"
                  (compiler-load-symbol-text fname)
                  "`"))])]
        [(List (slice _ & _))
          (Err "package fields must start with a field name")]
        [_ (Err "package fields must be lists like `(name \"...\")`")])]))

;: Parse the top-level `(package ...)` form.
(define (compiler-load-manifest-from-form [form : reader.SpannedSexpr]) : ResultCompilerPkgManifest
  (match (reader.sexpr-view form)
    [(List (slice (Sym s _) & rest))
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
        (Err
          (str_cat.str-cat
            "expected `package` form, got `"
            (compiler-load-symbol-text s)
            "`")))]
    [(List (slice _ & _)) (Err "manifest must start with `package`")]
    [_ (Err "manifest must be a `(package ...)` form")]))

(define (compiler-load-manifest-fields-have?
  [fields : (& program (Slice reader.SpannedSexpr))]
  [target : (& target str)]) : bool
  (match fields
    [(slice) false]
    [(slice field & rest)
      (let
        [tail-has : bool (compiler-load-manifest-fields-have? rest target)]
        (match (reader.sexpr-view field)
          [(List (slice (Sym name _) & _))
            (or (string.eq (compiler-load-symbol-text name) target) tail-has)]
          [_ tail-has]))]))

(define (compiler-load-manifest-form-has-field?
  [form : reader.SpannedSexpr]
  [target : (& target str)]) : bool
  (match (reader.sexpr-view form)
    [(List (slice (Sym s _) & rest))
      (if (string.eq (compiler-load-symbol-text s) "package")
        (compiler-load-manifest-fields-have? rest target)
        false)]
    [_ false]))

(define (compiler-load-manifest-needs-kind-inference?
  [form : reader.SpannedSexpr]) : bool
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
      [(and has-main (not has-lib)) (Ok (CompilerPkgKindBin))]
      [(and has-lib (not has-main)) (Ok (CompilerPkgKindLib))]
      [(and has-main has-lib)
        (Err
          "manifest omits `kind` and `entry`, but both `src/main.tl` and `src/lib.tl` exist; add explicit `kind` or `entry`")]
      [else
        (Err
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

;: Return the first dependency alias span from a well-formed
;: `(dependencies ...)` field. The whole manifest span is a fail-closed
;: fallback for callers validating a structurally constructed form.
(define (compiler-load-manifest-first-dependency-entry-span
  [entries : (& program (Slice reader.SpannedSexpr))]
  [fallback : token.SourceSpan]) : token.SourceSpan
  (match entries
    [(slice entry & _)
      (match (reader.spanned-sexpr-view entry)
        [(List (slice alias & _) _) (reader.spanned-sexpr-span alias)]
        [_ fallback])]
    [_ fallback]))

(define (compiler-load-manifest-first-dependency-field-span
  [fields : reader.SpannedSexpr]
  [fallback : token.SourceSpan]) : token.SourceSpan
  (match (reader.spanned-sexpr-view fields)
    [(List (slice field & _) _)
      (match (reader.spanned-sexpr-view field)
        [(List (slice (Sym name _) & entries) _)
          (let
            [rest (reader.spanned-sexpr-drop fields 1)]
            (if (string.eq (compiler-load-symbol-text name) "dependencies")
              (compiler-load-manifest-first-dependency-entry-span
                entries
                fallback)
              (compiler-load-manifest-first-dependency-field-span rest fallback)))]
        [(List (slice _ & _) _)
          (let
            [rest (reader.spanned-sexpr-drop fields 1)]
            (compiler-load-manifest-first-dependency-field-span rest fallback))]
        [_
          (let
            [rest (reader.spanned-sexpr-drop fields 1)]
            (compiler-load-manifest-first-dependency-field-span rest fallback))])]
    [_ fallback]))

(define (compiler-load-manifest-first-dependency-span
  [form : reader.SpannedSexpr]) : token.SourceSpan
  (let
    [fallback : token.SourceSpan (reader.spanned-sexpr-span (clone form))]
    (match (reader.spanned-sexpr-view form)
      [(List (slice _ & _) _)
        (let
          [fields (reader.spanned-sexpr-drop form 1)]
          (compiler-load-manifest-first-dependency-field-span fields fallback))]
      [_ fallback])))

;: Enforce dependency-free library artifacts after kind inference and attach
;: the diagnostic to the forbidden alias rather than the whole manifest.
(define (compiler-load-manifest-validate-library-dependencies
  [path : String]
  [form : reader.SpannedSexpr]
  [manifest : CompilerPkgManifest]) : ResultCompilerPkgManifestDiagnostic
  (match (compiler-pkg-manifest-first-library-dependency (& manifest))
    [(NoDependency) (Ok manifest)]
    [(Dependency dep)
      (Err
        (box
          (cdiag.compiler-diagnostic-from-span
            path
            (compiler-load-manifest-first-dependency-span form)
            (compiler-pkg-library-dependency-message manifest.name dep.alias))))]))

(define (compiler-load-manifest-apply-kind-inference
  [path : String]
  [form : reader.SpannedSexpr]
  [manifest : CompilerPkgManifest]) : ResultCompilerPkgManifestDiagnostic
  (let
    [raw-form : reader.SpannedSexpr (ast.ast-place-shared-view form)]
    (if (compiler-load-manifest-needs-kind-inference? raw-form)
      (match (compiler-load-manifest-infer-kind-from-files (string.copy path))
        [(Ok kind)
          (compiler-load-manifest-validate-library-dependencies
            path
            form
            (compiler-load-manifest-with-kind manifest kind))]
        [(Err message)
          (Err
            (box
              (compiler-load-manifest-validation-diagnostic path form message)))])
      (compiler-load-manifest-validate-library-dependencies path form manifest))))

(define (compiler-load-parse-manifest-form-diagnostic
  [path : String]
  [form : reader.SpannedSexpr]) : ResultCompilerPkgManifestDiagnostic
  (match (compiler-load-manifest-from-form form)
    [(Ok manifest)
      (compiler-load-manifest-validate-library-dependencies path form manifest)]
    [(Err message)
      (Err
        (box (compiler-load-manifest-validation-diagnostic path form message)))]))

(define (compiler-load-parse-manifest-form-diagnostic-infer-kind
  [path : String]
  [form : reader.SpannedSexpr]) : ResultCompilerPkgManifestDiagnostic
  (match (compiler-load-manifest-from-form form)
    [(Ok manifest)
      (compiler-load-manifest-apply-kind-inference path form manifest)]
    [(Err message)
      (Err
        (box (compiler-load-manifest-validation-diagnostic path form message)))]))

;: Parse a `typelisp.pkg` manifest source string into a structured manifest,
;: preserving manifest path/span identity for source-facing errors.
(define (compiler-load-parse-manifest-diagnostic
  [path : String]
  [source : String]) : ResultCompilerPkgManifestDiagnostic
  (let
    [mark : i64 (reader.sp-node-pool-len)]
    [result : ResultCompilerPkgManifestDiagnostic
      (match (lexer.spanned-result (& source))
        [(Err err)
          (Err (box (compiler-load-manifest-source-error-diagnostic path err)))]
        [(Ok toks)
          (match (reader.spanned-result toks)
            [(Err err)
              (Err
                (box (compiler-load-manifest-source-error-diagnostic path err)))]
            [(Ok form) (compiler-load-parse-manifest-form-diagnostic path form)])])]
    (reader.sp-node-pool-truncate! mark)
    result))

(define (compiler-load-parse-manifest-diagnostic-infer-kind
  [path : String]
  [source : String]) : ResultCompilerPkgManifestDiagnostic
  (let
    [mark : i64 (reader.sp-node-pool-len)]
    [result : ResultCompilerPkgManifestDiagnostic
      (match (lexer.spanned-result (& source))
        [(Err err)
          (Err (box (compiler-load-manifest-source-error-diagnostic path err)))]
        [(Ok toks)
          (match (reader.spanned-result toks)
            [(Err err)
              (Err
                (box (compiler-load-manifest-source-error-diagnostic path err)))]
            [(Ok form)
              (compiler-load-parse-manifest-form-diagnostic-infer-kind
                path
                form)])])]
    (reader.sp-node-pool-truncate! mark)
    result))

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
    (while (< index (compiler-pkg-dep-list-count ordered))
      (let
        [dep : CompilerPkgDep (compiler-pkg-dep-list-at ordered index)]
        (if (string.eq dep.alias target-alias)
          (return (CompilerLoadSomePath dep.path))
          (set! index (+ index 1)))))
    (CompilerLoadNoPath)))

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
      (Err
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
          (Err
            (str_cat.str-cat
              "compiler-load: pkg import has empty alias: "
              import-path))
          (match (compiler-load-pkg-dep-lookup deps (string.copy alias))
            [(CompilerLoadNoPath)
              (Err
                (str_cat.str-cat
                  "compiler-load: unknown package alias '"
                  alias
                  "': "
                  import-path))]
            [(CompilerLoadSomePath dep-path)
              (if (compiler-load-github-dependency-path? (string.copy dep-path))
                (Err
                  (str_cat.str-cat
                    "compiler-load: GitHub dependency '"
                    alias
                    "' requires fetch support: "
                    import-path))
                (let
                  [norm-rest : String (compiler-load-normalize-path rest)]
                  (if (compiler-load-path-escapes? (string.copy norm-rest))
                    (Err
                      (str_cat.str-cat
                        "compiler-load: pkg import escapes package root: "
                        import-path))
                    (Ok
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
            (owned_view.compiler-owned-shared-view dir))]
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
      [candidate : String (str_cat.str-cat (string.copy dir) "typelisp.pkg")]
      (if (io.file-exists? (string.copy candidate))
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
    [(CompilerLoadNoPath) (Ok import-path)]
    [(CompilerLoadSomePath manifest-path)
      (match (compiler-load-parse-manifest-diagnostic
        (string.copy manifest-path)
        (compiler-load-session-read-source-text manifest-path))
        [(Err _) (Ok import-path)]
        [(Ok manifest)
          (compiler-load-resolve-pkg-import
            import-path
            (compiler-load-dirname manifest-path)
            manifest.deps)])]))