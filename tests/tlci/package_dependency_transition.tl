;; Same-process dependency-catalog lifecycle witness for
;; verify-package-native-tlci.sh. The shell gate supplies two real package
;; source/image pairs produced by the compiler under test; this program swaps
;; them beneath one job-owned registry and proves the old mapped capability is
;; invalidated before the rebuilt image is admitted.
(import compiler_dependency_tlci as dependency_tlci)
(import compiler_load as load)
(import compiler_owned_view as owned_view)
(import package_source_core as package_source)
(import stdlib.byte_buf)
(import stdlib.io)
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.string)

(defstruct PackageDependencyTransitionStale
  (expected i64)
  (actual i64))

(define (package-dependency-transition-require
  [condition : bool]
  [message : String]) : unit
  (unless condition (io.panic message)))

(define (package-dependency-transition-copy-file
  [source : String]
  [target : String]) : unit
  (let
    [contents : byte_buf.ByteBuf (io.read-file source)]
    (io.write-file target (byte_buf.as-bytes (& contents)))))

(define (package-dependency-transition-source-set [manifest-path : String]) : package_source.PackageSourceSet
  (match (package_source.package-source-discover-for
    "package tlci transition"
    manifest-path
    true)
    [(package_source.ResultPackageSourceSet.Ok source-set) source-set]
    [(package_source.ResultPackageSourceSet.Err message) (io.panic message)]))

(define (package-dependency-transition-capability
  [state : load.CompilerLoadSessionState]
  [slot : i64]
  [identity : String]) : load.CompilerLoadDependencyCatalogCapability
  (match (load.compiler-load-dependency-catalog-lookup-macro
    state
    slot
    identity)
    [(load.CompilerLoadDependencyCatalogLookup.Resolved capability) capability]
    [_ (io.panic "package tlci transition: macro was not a native result")]))

(define (package-dependency-transition-stale
  [state : load.CompilerLoadSessionState]
  [slot : i64]) : PackageDependencyTransitionStale
  (match (load.compiler-load-dependency-catalog-admitted-image state slot)
    [(load.CompilerLoadDependencyCatalogAdmittedImage.Unavailable failure)
      (match failure
        [(load.CompilerLoadDependencyCatalogFailure.StaleSource expected actual)
          (PackageDependencyTransitionStale expected actual)]
        [_
          (io.panic
            "package tlci transition: changed source was not StaleSource")])]
    [_
      (io.panic
        "package tlci transition: changed source retained executable code")]))

(define (package-dependency-transition-trusted-observation?
  [observed : load.CompilerLoadDependencyCatalogObservation]
  [generation : i64]) : bool
  (and
    (= observed.entries 1)
    (= observed.generation generation)
    (= observed.unavailable 0)
    (= observed.metadata-only 0)
    (= observed.trusted-code 1)
    (> observed.code-bytes 0)
    (> observed.entry-bytes 0)))

(define (package-dependency-transition-stale-observation?
  [observed : load.CompilerLoadDependencyCatalogObservation]) : bool
  (and
    (= observed.entries 1)
    (= observed.generation 2)
    (= observed.unavailable 1)
    (= observed.metadata-only 0)
    (= observed.trusted-code 0)
    (= observed.code-bytes 0)
    (= observed.fixup-bytes 0)
    (= observed.entry-bytes 0)
    (= observed.import-bytes 0)))

(define (package-dependency-transition-rebuilt-key?
  [old : load.CompilerLoadDependencyCatalogKey]
  [rebuilt : load.CompilerLoadDependencyCatalogKey]
  [stale : PackageDependencyTransitionStale]) : bool
  (and
    (string.eq old.canonical-root rebuilt.canonical-root)
    (string.eq old.package-name rebuilt.package-name)
    (string.eq old.package-version rebuilt.package-version)
    (string.eq old.artifact-path rebuilt.artifact-path)
    (= old.source-digest stale.actual)
    (= rebuilt.source-digest stale.expected)
    (not (= old.source-digest rebuilt.source-digest))
    (not (= old.image-content-hash rebuilt.image-content-hash))
    (= old.host-platform rebuilt.host-platform)
    (= old.callback-abi-version rebuilt.callback-abi-version)
    (string.eq old.compiler-identity rebuilt.compiler-identity)))

(define (package-dependency-transition-run
  [manifest-path : String]
  [source-path : String]
  [old-source-path : String]
  [new-source-path : String]
  [artifact-path : String]
  [old-image-path : String]
  [new-image-path : String]
  [identity : String]) : i64
  (let
    [state : load.CompilerLoadSessionState
      (load.compiler-load-session-state-new)]
    [old-slot : i64
      (dependency_tlci.compiler-dependency-tlci-prepare-source-set!
        (owned_view.compiler-owned-shared-view state)
        (package-dependency-transition-source-set (string.copy manifest-path)))]
    [old-observed : load.CompilerLoadDependencyCatalogObservation
      (load.compiler-load-dependency-catalog-observe
        (owned_view.compiler-owned-shared-view state))]
    [old-capability : load.CompilerLoadDependencyCatalogCapability
      (package-dependency-transition-capability
        (owned_view.compiler-owned-shared-view state)
        old-slot
        (string.copy identity))]
    (begin
      (package-dependency-transition-require
        (and
          (= old-slot 0)
          (package-dependency-transition-trusted-observation? old-observed 1))
        "package tlci transition: old image was not admitted once")
      (package-dependency-transition-copy-file
        new-source-path
        (string.copy source-path))
      (let
        [stale-slot : i64
          (dependency_tlci.compiler-dependency-tlci-prepare-source-set!
            (owned_view.compiler-owned-shared-view state)
            (package-dependency-transition-source-set
              (string.copy manifest-path)))]
        [stale-observed : load.CompilerLoadDependencyCatalogObservation
          (load.compiler-load-dependency-catalog-observe
            (owned_view.compiler-owned-shared-view state))]
        [stale : PackageDependencyTransitionStale
          (package-dependency-transition-stale
            (owned_view.compiler-owned-shared-view state)
            stale-slot)]
        (begin
          (package-dependency-transition-require
            (and
              (= stale-slot old-slot)
              (package-dependency-transition-stale-observation? stale-observed)
              (not
                (load.compiler-load-dependency-catalog-capability-current?
                  (owned_view.compiler-owned-shared-view old-capability))))
            "package tlci transition: stale image retained its mapped capability")
          (package-dependency-transition-copy-file
            new-image-path
            (string.copy artifact-path))
          (let
            [rebuilt-slot : i64
              (dependency_tlci.compiler-dependency-tlci-prepare-source-set!
                (owned_view.compiler-owned-shared-view state)
                (package-dependency-transition-source-set
                  (string.copy manifest-path)))]
            [rebuilt-observed : load.CompilerLoadDependencyCatalogObservation
              (load.compiler-load-dependency-catalog-observe
                (owned_view.compiler-owned-shared-view state))]
            [rebuilt-capability : load.CompilerLoadDependencyCatalogCapability
              (package-dependency-transition-capability
                (owned_view.compiler-owned-shared-view state)
                rebuilt-slot
                (string.copy identity))]
            (begin
              (package-dependency-transition-require
                (and
                  (= rebuilt-slot old-slot)
                  (package-dependency-transition-trusted-observation?
                    rebuilt-observed
                    3)
                  (package-dependency-transition-rebuilt-key?
                    (owned_view.compiler-owned-shared-view old-capability.key)
                    (owned_view.compiler-owned-shared-view
                      rebuilt-capability.key)
                    (owned_view.compiler-owned-shared-view stale)))
                "package tlci transition: rebuilt image key was not admitted")
              (package-dependency-transition-copy-file
                old-source-path
                (string.copy source-path))
              (package-dependency-transition-copy-file
                old-image-path
                (string.copy artifact-path))
              (let
                [restored-slot : i64
                  (dependency_tlci.compiler-dependency-tlci-prepare-source-set!
                    (owned_view.compiler-owned-shared-view state)
                    (package-dependency-transition-source-set
                      (string.copy manifest-path)))]
                [restored-observed : load.CompilerLoadDependencyCatalogObservation
                  (load.compiler-load-dependency-catalog-observe
                    (owned_view.compiler-owned-shared-view state))]
                [restored-capability : load.CompilerLoadDependencyCatalogCapability
                  (package-dependency-transition-capability
                    (owned_view.compiler-owned-shared-view state)
                    restored-slot
                    (string.copy identity))]
                [reused-slot : i64
                  (dependency_tlci.compiler-dependency-tlci-prepare-source-set!
                    (owned_view.compiler-owned-shared-view state)
                    (package-dependency-transition-source-set manifest-path))]
                [reused-observed : load.CompilerLoadDependencyCatalogObservation
                  (load.compiler-load-dependency-catalog-observe
                    (owned_view.compiler-owned-shared-view state))]
                (begin
                  (package-dependency-transition-require
                    (and
                      (= restored-slot old-slot)
                      (= reused-slot old-slot)
                      (package-dependency-transition-trusted-observation?
                        restored-observed
                        4)
                      (package-dependency-transition-trusted-observation?
                        reused-observed
                        4)
                      (load.compiler-load-dependency-catalog-key-eq?
                        (owned_view.compiler-owned-shared-view
                          old-capability.key)
                        (owned_view.compiler-owned-shared-view
                          restored-capability.key)))
                    "package tlci transition: exact restored key was not reused")
                  (io.print-format
                    "{}"
                    (str_cat.str-cat
                      "package-tlci-transition|package="
                      old-capability.key.package-name
                      "|classification=stale-source|stale-unavailable=1"
                      "|stale-code-bytes=0|old-generation=1"
                      "|stale-generation=2|rebuilt-generation=3"
                      "|restored-generation=4|reused-generation=4"
                      "|old-source="
                      (string.int->string stale.actual)
                      "|new-source="
                      (string.int->string stale.expected)
                      "|old-image="
                      (string.int->string old-capability.key.image-content-hash)
                      "|new-image="
                      (string.int->string
                        rebuilt-capability.key.image-content-hash)
                      "\n"))
                  (match (load.compiler-load-session-state-dependency-catalog-release!
                    (owned_view.compiler-owned-shared-view state))
                    [(load.ResultCompilerLoadDependencyCatalogUnit.Ok) 0]
                    [(load.ResultCompilerLoadDependencyCatalogUnit.Err message)
                      (io.panic message)]))))))))))

(define (main) : i64
  (if (= (io.arg-count) 1)
    0
    (if (not (= (io.arg-count) 9))
      (io.panic
        "usage: package_dependency_transition <manifest> <source> <old-source> <new-source> <artifact> <old-image> <new-image> <identity>")
      (package-dependency-transition-run
        (io.arg 1)
        (io.arg 2)
        (io.arg 3)
        (io.arg 4)
        (io.arg 5)
        (io.arg 6)
        (io.arg 7)
        (io.arg 8)))))