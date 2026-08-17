;; compiler_dependency_tlci.tl - Package TLCI discovery and admission.
;;
;; This module sits above compiler_load and package_source_core so the loader
;; session can own admitted catalogs without introducing an import cycle.
(import stdlib.arena)
(import stdlib.byte_buf)
(import stdlib.io)
(import stdlib.string)
(import stdlib.str_cat_runtime as str_cat)
(import compiler_owned_view as owned_view)
(import compiler_load as load)
(import package_source_core as package_source)
(import tlci_core as tlci)
(cfg dependency-tlci-verification (import stdlib.env as verification_env))
(cfg test (import stdlib.fs))
(cfg embedded-stdlib-tlci (import tlci_loader as loader))
(cfg
  embedded-stdlib-tlci
  (import compiler_embedded_stdlib_tlci as comptime_host))

(define (compiler-dependency-tlci-own-text [text : String]) : String
  (string.substring (& text) 0 (string.string-length text)))

(cfg
  dependency-tlci-verification
  (define (compiler-dependency-tlci-verification-env? [name : String]) : bool
    (match (verification_env.get (& name))
      [(verification_env.EnvSomeString value) (string.eq value "1")]
      [(verification_env.EnvNoString) false])))

(cfg
  dependency-tlci-verification
  (define (compiler-dependency-tlci-verification-requested?) : bool
    (compiler-dependency-tlci-verification-env?
      "TYPELISP_DEPENDENCY_TLCI_VERIFY")))

(cfg
  dependency-tlci-verification
  (define (compiler-dependency-tlci-verification-force-source?) : bool
    (compiler-dependency-tlci-verification-env?
      "TYPELISP_DEPENDENCY_TLCI_FORCE_SOURCE")))

(cfg
  dependency-tlci-verification
  (define (compiler-dependency-tlci-verification-record!
    [state : load.CompilerLoadSessionState]
    [phase : String]
    [requests : i64]) : unit
    (if (not (compiler-dependency-tlci-verification-requested?))
      unit
      (let
        [observed : load.CompilerLoadDependencyCatalogObservation
          (load.compiler-load-dependency-catalog-observe state)]
        (io.print-error
          (str_cat.str-cat
            "dependency-tlci-verification|phase="
            phase
            "|requests="
            (string.int->string requests)
            "|entries="
            (string.int->string observed.entries)
            "|generation="
            (string.int->string observed.generation)
            "|unavailable="
            (string.int->string observed.unavailable)
            "|metadata="
            (string.int->string observed.metadata-only)
            "|code="
            (string.int->string observed.trusted-code)
            "|code-bytes="
            (string.int->string observed.code-bytes)
            "|fixup-bytes="
            (string.int->string observed.fixup-bytes)
            "|entry-bytes="
            (string.int->string observed.entry-bytes)
            "|import-bytes="
            (string.int->string observed.import-bytes)
            "\n"))))))

(define (compiler-dependency-tlci-verification-finish!
  [_state : load.CompilerLoadSessionState]) : unit
  (cfg
    dependency-tlci-verification
    (compiler-dependency-tlci-verification-record! _state "finished" -1)
    unit))

(define (compiler-dependency-tlci-key
  [canonical-root : String]
  [package-name : String]
  [package-version : String]
  [artifact-path : String]
  [source-digest : i64]
  [image-content-hash : i64]
  [host-platform : i64]
  [callback-abi-version : i64]
  [compiler-identity : String]) : load.CompilerLoadDependencyCatalogKey
  (load.CompilerLoadDependencyCatalogKey
    (compiler-dependency-tlci-own-text canonical-root)
    (compiler-dependency-tlci-own-text package-name)
    (compiler-dependency-tlci-own-text package-version)
    (compiler-dependency-tlci-own-text artifact-path)
    source-digest
    image-content-hash
    host-platform
    callback-abi-version
    (compiler-dependency-tlci-own-text compiler-identity)))

(define (compiler-dependency-tlci-record-unavailable!
  [state : load.CompilerLoadSessionState]
  [key : load.CompilerLoadDependencyCatalogKey]
  [failure : load.CompilerLoadDependencyCatalogFailure]) : i64
  (load.compiler-load-dependency-catalog-record-owned!
    state
    (load.CompilerLoadDependencyCatalogEntry
      key
      load.CompilerLoadDependencyCatalogImage.None
      (load.CompilerLoadDependencyCatalogStatus.Unavailable failure))))

(define (compiler-dependency-tlci-record-image!
  [state : load.CompilerLoadSessionState]
  [key : load.CompilerLoadDependencyCatalogKey]
  [image : tlci.TlciImage]
  [status : load.CompilerLoadDependencyCatalogStatus]) : i64
  (load.compiler-load-dependency-catalog-record-owned!
    state
    (load.CompilerLoadDependencyCatalogEntry
      key
      (load.CompilerLoadDependencyCatalogImage.Some image)
      status)))

(define (compiler-dependency-tlci-base-key
  [source-set : package_source.PackageSourceSet]
  [artifact-path : String]
  [source-digest : i64]) : load.CompilerLoadDependencyCatalogKey
  (compiler-dependency-tlci-key
    (load.compiler-load-canonical-path source-set.manifest-dir)
    source-set.manifest.name
    source-set.manifest.version
    (load.compiler-load-canonical-path artifact-path)
    source-digest
    -1
    -1
    -1
    ""))

(define (compiler-dependency-tlci-image-key
  [source-set : package_source.PackageSourceSet]
  [artifact-path : String]
  [source-digest : i64]
  [image-content-hash : i64]
  [image : tlci.TlciImage]) : load.CompilerLoadDependencyCatalogKey
  (compiler-dependency-tlci-key
    (load.compiler-load-canonical-path source-set.manifest-dir)
    source-set.manifest.name
    source-set.manifest.version
    (load.compiler-load-canonical-path artifact-path)
    source-digest
    image-content-hash
    image.host-platform
    image.callback-abi-version
    image.compiler-build-hash))

(define (compiler-dependency-tlci-host-failure
  [image : tlci.TlciImage]
  [message : String]) : load.CompilerLoadDependencyCatalogFailure
  (let
    [host : i64 (tlci.tlci-build-host-platform)]
    (if (and
      (match (tlci.tlci-image-classify image)
        [(tlci.TlciImageClassification.CodeBearing) true]
        [(tlci.TlciImageClassification.MetadataOnly) false])
      (tlci.tlci-host-platform-supported? image.host-platform)
      (tlci.tlci-host-platform-supported? host)
      (not (= image.host-platform host)))
      (load.CompilerLoadDependencyCatalogFailure.WrongPlatform
        image.host-platform
        host)
      (load.CompilerLoadDependencyCatalogFailure.Unsupported
        (compiler-dependency-tlci-own-text message)))))

(define (compiler-dependency-tlci-map-status
  [_owner : i64]
  [_bytes : (__tl_dyn-array u8)]) : load.CompilerLoadDependencyCatalogStatus
  (cfg
    embedded-stdlib-tlci
    (match (loader.tlci-loader-load-from-bytes-with-host
      _owner
      _bytes
      (comptime_host.compiler-comptime-host-table))
      [(loader.ResultTlciLoadedImage.Ok loaded)
        (load.CompilerLoadDependencyCatalogStatus.TrustedCode loaded)]
      [(loader.ResultTlciLoadedImage.Err message)
        (load.CompilerLoadDependencyCatalogStatus.Unavailable
          (load.CompilerLoadDependencyCatalogFailure.MappingFailure
            (compiler-dependency-tlci-own-text message)))])
    (load.CompilerLoadDependencyCatalogStatus.Unavailable
      (load.CompilerLoadDependencyCatalogFailure.Unsupported
        "dependency native catalogs require embedded-stdlib-tlci host callbacks"))))

(define (compiler-dependency-tlci-admit-parsed!
  [state : load.CompilerLoadSessionState]
  [owner : i64]
  [source-set : package_source.PackageSourceSet]
  [artifact-path : String]
  [source-digest : i64]
  [bytes : (__tl_dyn-array u8)]
  [image : tlci.TlciImage]) : i64
  (let
    [key : load.CompilerLoadDependencyCatalogKey
      (compiler-dependency-tlci-image-key
        (owned_view.compiler-owned-shared-view source-set)
        artifact-path
        source-digest
        (tlci.tlci-content-hash bytes)
        (owned_view.compiler-owned-shared-view image))]
    [reused : i64
      (load.compiler-load-dependency-catalog-find-key-slot
        (owned_view.compiler-owned-shared-view state)
        (owned_view.compiler-owned-shared-view key))]
    (if (>= reused 0)
      reused
      (let
        [metadata : tlci.TlciMetadata
          (owned_view.compiler-owned-shared-view image.metadata)]
        (if (or
          (not (string.eq metadata.package-name source-set.manifest.name))
          (not (string.eq metadata.package-version source-set.manifest.version)))
          (compiler-dependency-tlci-record-unavailable!
            state
            key
            (load.CompilerLoadDependencyCatalogFailure.PackageMismatch
              (compiler-dependency-tlci-own-text source-set.manifest.name)
              (compiler-dependency-tlci-own-text source-set.manifest.version)
              (compiler-dependency-tlci-own-text metadata.package-name)
              (compiler-dependency-tlci-own-text metadata.package-version)))
          (match (package_source.package-source-verify-binding
            source-set
            (owned_view.compiler-owned-shared-view image.rodata))
            [(package_source.PackageSourceBindingVerification.Match digest)
              (if (not (= digest source-digest))
                (compiler-dependency-tlci-record-unavailable!
                  state
                  key
                  (load.CompilerLoadDependencyCatalogFailure.StaleSource
                    source-digest
                    digest))
                (match (tlci.tlci-image-admit-host
                  (owned_view.compiler-owned-shared-view image)
                  (tlci.tlci-build-host-platform))
                  [(tlci.TlciImageHostAdmission.MetadataOnly)
                    ;; Metadata-only images are trusted for later metadata
                    ;; consumers, but are never handed to the mapping API.
                    (compiler-dependency-tlci-record-image!
                      state
                      key
                      image
                      load.CompilerLoadDependencyCatalogStatus.TrustedMetadataOnly)]
                  [(tlci.TlciImageHostAdmission.CodeBearing)
                    (compiler-dependency-tlci-record-image!
                      state
                      key
                      image
                      (compiler-dependency-tlci-map-status owner bytes))]
                  [(tlci.TlciImageHostAdmission.Rejected message)
                    (compiler-dependency-tlci-record-unavailable!
                      state
                      key
                      (compiler-dependency-tlci-host-failure image message))]))]
            [(package_source.PackageSourceBindingVerification.Mismatch
                expected
                actual)
              (compiler-dependency-tlci-record-unavailable!
                state
                key
                (load.CompilerLoadDependencyCatalogFailure.StaleSource
                  expected
                  actual))]
            [(package_source.PackageSourceBindingVerification.Unreadable
                message)
              (compiler-dependency-tlci-record-unavailable!
                state
                key
                (load.CompilerLoadDependencyCatalogFailure.Malformed
                  (compiler-dependency-tlci-own-text message)))]
            [(package_source.PackageSourceBindingVerification.MissingOrLegacy)
              (compiler-dependency-tlci-record-unavailable!
                state
                key
                (load.CompilerLoadDependencyCatalogFailure.Unsupported
                  "dependency tlci has no current package-source binding"))]
            [(package_source.PackageSourceBindingVerification.UnsupportedSchema
                schema)
              (compiler-dependency-tlci-record-unavailable!
                state
                key
                (load.CompilerLoadDependencyCatalogFailure.Unsupported
                  (str_cat.str-cat
                    "dependency tlci uses unsupported package-source binding schema "
                    (string.int->string schema))))]
            [(package_source.PackageSourceBindingVerification.Malformed message)
              (compiler-dependency-tlci-record-unavailable!
                state
                key
                (load.CompilerLoadDependencyCatalogFailure.Malformed
                  (compiler-dependency-tlci-own-text message)))]))))))

(define (compiler-dependency-tlci-prepare-source-set-owned!
  [state : load.CompilerLoadSessionState]
  [source-set : package_source.PackageSourceSet]) : i64
  (let
    [artifact-path : String
      (load.compiler-load-package-tlci-path
        (owned_view.compiler-owned-shared-view source-set.manifest-dir)
        (owned_view.compiler-owned-shared-view source-set.manifest.name))]
    (match (package_source.package-source-set-digest
      (owned_view.compiler-owned-shared-view source-set))
      [(package_source.ResultPackageSourceDigest.Err message)
        (compiler-dependency-tlci-record-unavailable!
          state
          (compiler-dependency-tlci-base-key source-set artifact-path -1)
          (load.CompilerLoadDependencyCatalogFailure.Malformed
            (compiler-dependency-tlci-own-text message)))]
      [(package_source.ResultPackageSourceDigest.Ok source-digest)
        (if (load.compiler-load-session-state-dependency-tlci-force-source?
          state)
          (compiler-dependency-tlci-record-unavailable!
            state
            (compiler-dependency-tlci-base-key
              source-set
              (owned_view.compiler-owned-shared-view artifact-path)
              source-digest)
            (load.CompilerLoadDependencyCatalogFailure.Missing
              "dependency tlci disabled by verification source control"))
          (if (not
            (io.file-exists?
              (owned_view.compiler-owned-shared-view artifact-path)))
            (compiler-dependency-tlci-record-unavailable!
              state
              (compiler-dependency-tlci-base-key
                source-set
                (owned_view.compiler-owned-shared-view artifact-path)
                source-digest)
              (load.CompilerLoadDependencyCatalogFailure.Missing
                (compiler-dependency-tlci-own-text
                  (owned_view.compiler-owned-shared-view artifact-path))))
            (match (io.try-read-file (& artifact-path))
              [(io.ErrIoBytes error)
                (compiler-dependency-tlci-record-unavailable!
                  state
                  (compiler-dependency-tlci-base-key
                    source-set
                    artifact-path
                    source-digest)
                  (load.CompilerLoadDependencyCatalogFailure.Malformed
                    (compiler-dependency-tlci-own-text (io.error-message error))))]
              [(io.OkIoBytes contents)
                (let
                  [bytes : (__tl_dyn-array u8) (byte_buf.to-array contents)]
                  (match (tlci.tlci-parse-image
                    (owned_view.compiler-owned-shared-view bytes))
                    [(tlci.ResultTlciImage.Err message)
                      (compiler-dependency-tlci-record-unavailable!
                        state
                        (compiler-dependency-tlci-base-key
                          source-set
                          artifact-path
                          source-digest)
                        (load.CompilerLoadDependencyCatalogFailure.Malformed
                          (compiler-dependency-tlci-own-text message)))]
                    [(tlci.ResultTlciImage.Ok image)
                      (compiler-dependency-tlci-admit-parsed!
                        (owned_view.compiler-owned-shared-view state)
                        (load.compiler-load-dependency-catalog-owner-arena
                          (owned_view.compiler-owned-shared-view state))
                        source-set
                        artifact-path
                        source-digest
                        bytes
                        image)]))])))])))

(define (compiler-dependency-tlci-prepare-source-set!
  [state : load.CompilerLoadSessionState]
  [source-set : package_source.PackageSourceSet]) : i64
  (let
    [owner : i64
      (load.compiler-load-dependency-catalog-owner-arena-ensure!
        (owned_view.compiler-owned-shared-view state))]
    (in-arena
      (arena.Arena owner)
      (compiler-dependency-tlci-prepare-source-set-owned! state source-set))))

(define (compiler-dependency-tlci-prepare-dep!
  [state : load.CompilerLoadSessionState]
  [manifest-dir : String]
  [dep : load.CompilerPkgDep]) : i64
  (let
    [root : String
      (load.compiler-load-normalize-path
        (load.compiler-load-join-root-path manifest-dir dep.path))]
    [manifest-path : String
      (load.compiler-load-join-root-path
        (owned_view.compiler-owned-shared-view root)
        "typelisp.pkg")]
    (match (package_source.package-source-discover-for
      "build dependency catalog"
      manifest-path
      true)
      [(package_source.ResultPackageSourceSet.Ok source-set)
        (compiler-dependency-tlci-prepare-source-set! state source-set)]
      [(package_source.ResultPackageSourceSet.Err message)
        (let
          [owner : i64
            (load.compiler-load-dependency-catalog-owner-arena-ensure!
              (owned_view.compiler-owned-shared-view state))]
          (in-arena
            (arena.Arena owner)
            (compiler-dependency-tlci-record-unavailable!
              state
              (compiler-dependency-tlci-key
                (load.compiler-load-canonical-path
                  (owned_view.compiler-owned-shared-view root))
                (owned_view.compiler-owned-shared-view dep.alias)
                ""
                (load.compiler-load-canonical-path
                  (load.compiler-load-package-tlci-path root dep.alias))
                -1
                -1
                -1
                -1
                "")
              (load.CompilerLoadDependencyCatalogFailure.Malformed
                (compiler-dependency-tlci-own-text message)))))])))

(define (compiler-dependency-tlci-prepare-deps-from!
  [state : load.CompilerLoadSessionState]
  [manifest-dir : String]
  [deps : load.CompilerPkgDepList]
  [index : i64]) : unit
  (if (>= index (load.compiler-pkg-dep-list-count deps))
    unit
    (begin
      (compiler-dependency-tlci-prepare-dep!
        (owned_view.compiler-owned-shared-view state)
        (owned_view.compiler-owned-shared-view manifest-dir)
        (load.compiler-pkg-dep-list-at deps index))
      (compiler-dependency-tlci-prepare-deps-from!
        state
        manifest-dir
        deps
        (+ index 1)))))

(define (compiler-dependency-tlci-prepare-deps!
  [state : load.CompilerLoadSessionState]
  [manifest-dir : String]
  [deps : load.CompilerPkgDeps]) : unit
  (let
    [items : load.CompilerPkgDepList (load.compiler-pkg-deps-list deps)]
    (begin
      (load.compiler-load-session-state-set-dependency-tlci-force-source!
        (owned_view.compiler-owned-shared-view state)
        (cfg
          dependency-tlci-verification
          (compiler-dependency-tlci-verification-force-source?)
          false))
      (compiler-dependency-tlci-prepare-deps-from!
        (owned_view.compiler-owned-shared-view state)
        manifest-dir
        (owned_view.compiler-owned-shared-view items)
        0)
      (cfg
        dependency-tlci-verification
        (compiler-dependency-tlci-verification-record!
          (owned_view.compiler-owned-shared-view state)
          "prepared"
          (load.compiler-pkg-dep-list-count items))
        unit))))

(cfg
  test
  (define compiler-dependency-tlci-test-root : String
    (str_cat.str-cat
      "target/compiler_dependency_tlci_fixture/"
      (string.int->string (fs.process-id)))))

(cfg
  test
  (define (compiler-dependency-tlci-test-path [suffix : String]) : String
    (load.compiler-load-join-root-path
      (string.copy (& compiler-dependency-tlci-test-root))
      suffix)))

(cfg
  test
  (define (compiler-dependency-tlci-test-mkdir [path : String]) : bool
    (match (fs.try-mkdir-if-missing (& path))
      [(io.OkIoUnit) true]
      [(io.ErrIoUnit _) false])))

(cfg
  test
  (define (compiler-dependency-tlci-test-write-text
    [path : (& path str)]
    [contents : (& contents str)]) : bool
    (match (io.try-write-file path (byte_buf.str-as-bytes contents))
      [(io.OkIoUnit) true]
      [(io.ErrIoUnit _) false])))

(cfg
  test
  (define (compiler-dependency-tlci-test-write-bytes
    [path : (& path str)]
    [contents : (__tl_dyn-array u8)]) : bool
    (let
      [buffer : byte_buf.ByteBuf (byte_buf.from-array contents)]
      (match (io.try-write-file path (byte_buf.as-bytes (& buffer)))
        [(io.OkIoUnit) true]
        [(io.ErrIoUnit _) false]))))

(cfg
  test
  (define (compiler-dependency-tlci-test-setup!) : bool
    (and
      (compiler-dependency-tlci-test-mkdir "target")
      (compiler-dependency-tlci-test-mkdir
        "target/compiler_dependency_tlci_fixture")
      (compiler-dependency-tlci-test-mkdir
        (string.copy (& compiler-dependency-tlci-test-root)))
      (compiler-dependency-tlci-test-mkdir
        (compiler-dependency-tlci-test-path "src"))
      (compiler-dependency-tlci-test-mkdir
        (compiler-dependency-tlci-test-path "target"))
      (compiler-dependency-tlci-test-mkdir
        (compiler-dependency-tlci-test-path "target/release"))
      (compiler-dependency-tlci-test-write-text
        (compiler-dependency-tlci-test-path "typelisp.pkg")
        "(package\n  (name \"metadata_dep\")\n  (version \"1.0.0\")\n  (kind \"staticlib\")\n  (entry \"src/lib.tl\"))\n")
      (compiler-dependency-tlci-test-write-text
        (compiler-dependency-tlci-test-path "src/lib.tl")
        "(module metadata_dep)\n(define (answer) : i64 42)\n"))))

(cfg
  test
  (define (compiler-dependency-tlci-test-source-set) : package_source.PackageSourceSet
    (match (package_source.package-source-discover-for
      "dependency tlci test"
      (compiler-dependency-tlci-test-path "typelisp.pkg")
      true)
      [(package_source.ResultPackageSourceSet.Ok source-set) source-set]
      [(package_source.ResultPackageSourceSet.Err message) (io.panic message)])))

(cfg
  test
  (define (compiler-dependency-tlci-test-digest
    [source-set : package_source.PackageSourceSet]) : i64
    (match (package_source.package-source-set-digest source-set)
      [(package_source.ResultPackageSourceDigest.Ok digest) digest]
      [(package_source.ResultPackageSourceDigest.Err message)
        (io.panic message)])))

(cfg
  test
  (define (compiler-dependency-tlci-test-rodata
    [schema : i64]
    [digest : i64]
    [payload-len : i64]) : (__tl_dyn-array u8)
    (let
      [payload : (__tl_dyn-array u8) (__tl_make-array u8 payload-len)]
      [sections : (__tl_dyn-array tlci.TlciAuxSection)
        (__tl_make-array tlci.TlciAuxSection 1)]
      (begin
        (if (>= payload-len 8)
          (tlci.tlci-set-u64! (&mut payload) 0 digest)
          unit)
        (set!
          (array-ref sections 0)
          (tlci.TlciAuxSection
            tlci.tlci-aux-kind-package-source-binding
            schema
            payload))
        (match (tlci.tlci-aux-pack-rodata (tlci.tlci-empty-bytes) sections)
          [(tlci.ResultTlciAuxBytes.Ok packed) packed]
          [(tlci.ResultTlciAuxBytes.Err message) (io.panic message)])))))

(cfg
  test
  (define (compiler-dependency-tlci-test-image
    [name : String]
    [platform : i64]
    [rodata : (__tl_dyn-array u8)]) : tlci.TlciImage
    (tlci.tlci-make-image
      platform
      tlci.tlci-callback-abi-version
      "0000000000000000000000000000000000000000"
      (tlci.tlci-make-metadata-v2 name "1.0.0" (tlci.tlci-spmd-callables-empty))
      rodata
      (tlci.tlci-empty-bytes)
      (tlci.tlci-empty-bytes)
      (tlci.tlci-empty-bytes)
      (tlci.tlci-empty-bytes)
      (tlci.tlci-empty-bytes))))

(cfg
  test
  (define (compiler-dependency-tlci-test-emit [image : tlci.TlciImage]) : (__tl_dyn-array
      u8)
    (match (tlci.tlci-emit-image image)
      [(tlci.ResultTlciBytes.Ok bytes) bytes]
      [(tlci.ResultTlciBytes.Err message) (io.panic message)])))

(cfg
  test
  (define (compiler-dependency-tlci-test-release!
    [state : load.CompilerLoadSessionState]) : unit
    (match (load.compiler-load-session-state-dependency-catalog-release! state)
      [(load.ResultCompilerLoadDependencyCatalogUnit.Ok) unit]
      [(load.ResultCompilerLoadDependencyCatalogUnit.Err message)
        (io.panic message)])))

(cfg
  test
  (define (compiler-dependency-tlci-test-opposite-platform) : i64
    (if (= (tlci.tlci-build-host-platform) tlci.tlci-host-platform-x86-64-linux)
      tlci.tlci-host-platform-x86-64-windows
      tlci.tlci-host-platform-x86-64-linux)))

(cfg
  test
  (test
    compiler-dependency-tlci-metadata-only-admission
    (if (not (compiler-dependency-tlci-test-setup!))
      (io.panic "dependency tlci: unable to create metadata fixture")
      (let
        [source-set : package_source.PackageSourceSet
          (compiler-dependency-tlci-test-source-set)]
        [digest : i64
          (compiler-dependency-tlci-test-digest
            (owned_view.compiler-owned-shared-view source-set))]
        [wrong-digest : i64
          (if (= digest 2147483646)
            0
            (+ digest 1))]
        [artifact : String
          (load.compiler-load-package-tlci-path
            (owned_view.compiler-owned-shared-view source-set.manifest-dir)
            (owned_view.compiler-owned-shared-view source-set.manifest.name))]
        [good-image : tlci.TlciImage
          (compiler-dependency-tlci-test-image
            "metadata_dep"
            (tlci.tlci-build-host-platform)
            (compiler-dependency-tlci-test-rodata
              tlci.tlci-package-source-binding-schema-version
              digest
              8))]
        [good-bytes : (__tl_dyn-array u8)
          (compiler-dependency-tlci-test-emit good-image)]
        [state : load.CompilerLoadSessionState
          (load.compiler-load-session-state-new)]
        [opposite-state : load.CompilerLoadSessionState
          (load.compiler-load-session-state-new)]
        [stale-state : load.CompilerLoadSessionState
          (load.compiler-load-session-state-new)]
        [mismatch-state : load.CompilerLoadSessionState
          (load.compiler-load-session-state-new)]
        [unsupported-state : load.CompilerLoadSessionState
          (load.compiler-load-session-state-new)]
        [malformed-state : load.CompilerLoadSessionState
          (load.compiler-load-session-state-new)]
        [missing-state : load.CompilerLoadSessionState
          (load.compiler-load-session-state-new)]
        [parse-state : load.CompilerLoadSessionState
          (load.compiler-load-session-state-new)]
        (begin
          (unless
            (compiler-dependency-tlci-test-write-bytes
              artifact
              (owned_view.compiler-owned-shared-view good-bytes))
            (return (io.panic "dependency tlci: unable to write trusted image")))
          (let
            [first : i64
              (compiler-dependency-tlci-prepare-source-set!
                (owned_view.compiler-owned-shared-view state)
                (owned_view.compiler-owned-shared-view source-set))]
            [second : i64
              (compiler-dependency-tlci-prepare-source-set!
                (owned_view.compiler-owned-shared-view state)
                (owned_view.compiler-owned-shared-view source-set))]
            [observed : load.CompilerLoadDependencyCatalogObservation
              (load.compiler-load-dependency-catalog-observe
                (owned_view.compiler-owned-shared-view state))]
            (unless
              (and
                (= first 0)
                (= second first)
                (= observed.entries 1)
                (= observed.generation 1)
                (= observed.unavailable 0)
                (= observed.metadata-only 1)
                (= observed.trusted-code 0)
                (= observed.code-bytes 0)
                (= observed.fixup-bytes 0)
                (= observed.entry-bytes 0)
                (= observed.import-bytes 0)
                (match (load.compiler-load-dependency-catalog-lookup-macro
                  (owned_view.compiler-owned-shared-view state)
                  first
                  "metadata_dep/missing")
                  [(load.CompilerLoadDependencyCatalogLookup.MetadataOnly) true]
                  [_ false]))
              (return
                (io.panic
                  "dependency tlci: trusted metadata observation mismatch"))))
          (unless
            (compiler-dependency-tlci-test-write-bytes
              artifact
              (compiler-dependency-tlci-test-emit
                (compiler-dependency-tlci-test-image
                  "metadata_dep"
                  (compiler-dependency-tlci-test-opposite-platform)
                  (compiler-dependency-tlci-test-rodata
                    tlci.tlci-package-source-binding-schema-version
                    digest
                    8))))
            (return
              (io.panic "dependency tlci: unable to write cross-host image")))
          (unless
            (match (load.compiler-load-dependency-catalog-admitted-image
              (owned_view.compiler-owned-shared-view opposite-state)
              (compiler-dependency-tlci-prepare-source-set!
                (owned_view.compiler-owned-shared-view opposite-state)
                (owned_view.compiler-owned-shared-view source-set)))
              [(load.CompilerLoadDependencyCatalogAdmittedImage.TrustedMetadataOnly
                  image)
                (and
                  (=
                    image.host-platform
                    (compiler-dependency-tlci-test-opposite-platform))
                  (= (array-length image.code) 0))]
              [_ false])
            (return
              (io.panic
                "dependency tlci: cross-host metadata image was not admitted")))
          (unless
            (compiler-dependency-tlci-test-write-bytes
              artifact
              (compiler-dependency-tlci-test-emit
                (compiler-dependency-tlci-test-image
                  "metadata_dep"
                  (tlci.tlci-build-host-platform)
                  (compiler-dependency-tlci-test-rodata
                    tlci.tlci-package-source-binding-schema-version
                    wrong-digest
                    8))))
            (return (io.panic "dependency tlci: unable to write stale image")))
          (unless
            (match (load.compiler-load-dependency-catalog-admitted-image
              (owned_view.compiler-owned-shared-view stale-state)
              (compiler-dependency-tlci-prepare-source-set!
                (owned_view.compiler-owned-shared-view stale-state)
                (owned_view.compiler-owned-shared-view source-set)))
              [(load.CompilerLoadDependencyCatalogAdmittedImage.Unavailable
                  (load.CompilerLoadDependencyCatalogFailure.StaleSource
                    expected
                    actual))
                (and (= expected digest) (= actual wrong-digest))]
              [_ false])
            (return
              (io.panic "dependency tlci: stale image was not classified")))
          (unless
            (compiler-dependency-tlci-test-write-bytes
              artifact
              (compiler-dependency-tlci-test-emit
                (compiler-dependency-tlci-test-image
                  "wrong_dep"
                  (tlci.tlci-build-host-platform)
                  (compiler-dependency-tlci-test-rodata
                    tlci.tlci-package-source-binding-schema-version
                    digest
                    8))))
            (return
              (io.panic "dependency tlci: unable to write identity mismatch")))
          (unless
            (match (load.compiler-load-dependency-catalog-admitted-image
              (owned_view.compiler-owned-shared-view mismatch-state)
              (compiler-dependency-tlci-prepare-source-set!
                (owned_view.compiler-owned-shared-view mismatch-state)
                (owned_view.compiler-owned-shared-view source-set)))
              [(load.CompilerLoadDependencyCatalogAdmittedImage.Unavailable
                  (load.CompilerLoadDependencyCatalogFailure.PackageMismatch
                    expected-name
                    _
                    actual-name
                    _))
                (and
                  (string.eq expected-name "metadata_dep")
                  (string.eq actual-name "wrong_dep"))]
              [_ false])
            (return
              (io.panic "dependency tlci: identity mismatch was not classified")))
          (unless
            (compiler-dependency-tlci-test-write-bytes
              artifact
              (compiler-dependency-tlci-test-emit
                (compiler-dependency-tlci-test-image
                  "metadata_dep"
                  (tlci.tlci-build-host-platform)
                  (compiler-dependency-tlci-test-rodata 2 digest 8))))
            (return
              (io.panic "dependency tlci: unable to write unsupported schema")))
          (unless
            (match (load.compiler-load-dependency-catalog-admitted-image
              (owned_view.compiler-owned-shared-view unsupported-state)
              (compiler-dependency-tlci-prepare-source-set!
                (owned_view.compiler-owned-shared-view unsupported-state)
                (owned_view.compiler-owned-shared-view source-set)))
              [(load.CompilerLoadDependencyCatalogAdmittedImage.Unavailable
                  (load.CompilerLoadDependencyCatalogFailure.Unsupported _))
                true]
              [_ false])
            (return
              (io.panic
                "dependency tlci: unsupported schema was not classified")))
          (unless
            (compiler-dependency-tlci-test-write-bytes
              artifact
              (compiler-dependency-tlci-test-emit
                (compiler-dependency-tlci-test-image
                  "metadata_dep"
                  (tlci.tlci-build-host-platform)
                  (compiler-dependency-tlci-test-rodata
                    tlci.tlci-package-source-binding-schema-version
                    digest
                    7))))
            (return
              (io.panic "dependency tlci: unable to write malformed schema")))
          (unless
            (match (load.compiler-load-dependency-catalog-admitted-image
              (owned_view.compiler-owned-shared-view malformed-state)
              (compiler-dependency-tlci-prepare-source-set!
                (owned_view.compiler-owned-shared-view malformed-state)
                (owned_view.compiler-owned-shared-view source-set)))
              [(load.CompilerLoadDependencyCatalogAdmittedImage.Unavailable
                  (load.CompilerLoadDependencyCatalogFailure.Malformed _))
                true]
              [_ false])
            (return
              (io.panic "dependency tlci: malformed schema was not classified")))
          (match (fs.try-remove-file (& artifact))
            [(io.OkIoUnit) unit]
            [(io.ErrIoUnit error) (return (io.panic (io.error-message error)))])
          (unless
            (match (load.compiler-load-dependency-catalog-admitted-image
              (owned_view.compiler-owned-shared-view missing-state)
              (compiler-dependency-tlci-prepare-source-set!
                (owned_view.compiler-owned-shared-view missing-state)
                (owned_view.compiler-owned-shared-view source-set)))
              [(load.CompilerLoadDependencyCatalogAdmittedImage.Unavailable
                  (load.CompilerLoadDependencyCatalogFailure.Missing path))
                (string.eq path artifact)]
              [_ false])
            (return
              (io.panic "dependency tlci: missing image was not classified")))
          (unless
            (compiler-dependency-tlci-test-write-text artifact "not a tlci")
            (return (io.panic "dependency tlci: unable to write parse failure")))
          (unless
            (match (load.compiler-load-dependency-catalog-admitted-image
              (owned_view.compiler-owned-shared-view parse-state)
              (compiler-dependency-tlci-prepare-source-set!
                (owned_view.compiler-owned-shared-view parse-state)
                (owned_view.compiler-owned-shared-view source-set)))
              [(load.CompilerLoadDependencyCatalogAdmittedImage.Unavailable
                  (load.CompilerLoadDependencyCatalogFailure.Malformed _))
                true]
              [_ false])
            (return
              (io.panic "dependency tlci: malformed image was not classified")))
          (compiler-dependency-tlci-test-release!
            (owned_view.compiler-owned-shared-view state))
          (unless
            (and
              (=
                (load.compiler-load-dependency-catalog-observe
                  (owned_view.compiler-owned-shared-view state)).entries
                0)
              (=
                (load.compiler-load-dependency-catalog-observe
                  (owned_view.compiler-owned-shared-view opposite-state)).entries
                1))
            (return (io.panic "dependency tlci: session release leaked state")))
          (compiler-dependency-tlci-test-release! opposite-state)
          (compiler-dependency-tlci-test-release! stale-state)
          (compiler-dependency-tlci-test-release! mismatch-state)
          (compiler-dependency-tlci-test-release! unsupported-state)
          (compiler-dependency-tlci-test-release! malformed-state)
          (compiler-dependency-tlci-test-release! missing-state)
          (compiler-dependency-tlci-test-release! parse-state)
          (compiler-dependency-tlci-test-write-bytes artifact good-bytes)
          unit)))))