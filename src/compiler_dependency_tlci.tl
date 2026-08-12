;; compiler_dependency_tlci.tl - Package TLCI discovery and admission.
;;
;; This module sits above compiler_load and package_source_core so the loader
;; session can own admitted catalogs without introducing an import cycle.
(import stdlib.arena)
(import stdlib.byte_buf)
(import stdlib.fs)
(import stdlib.io)
(import stdlib.string)
(import stdlib.str_cat_runtime as str_cat)
(import compiler_load as load)
(import package_source_core as package_source)
(import tlci_core as tlci)
(import tlci_loader as loader)
(cfg
  embedded-stdlib-tlci
  (import compiler_embedded_stdlib_tlci as comptime_host))

(define (compiler-dependency-tlci-own-text [text : String]) : String
  (string.substring (& text) 0 (string.string-length text)))

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
  [owner : i64]
  [bytes : (__tl_dyn-array u8)]) : load.CompilerLoadDependencyCatalogStatus
  (cfg
    embedded-stdlib-tlci
    (match (loader.tlci-loader-load-from-bytes-with-host
      owner
      bytes
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
        source-set
        artifact-path
        source-digest
        (tlci.tlci-content-hash bytes)
        image)]
    [reused : i64
      (load.compiler-load-dependency-catalog-find-key-slot state key)]
    (if (>= reused 0)
      reused
      (let
        [metadata : tlci.TlciMetadata image.metadata]
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
            image.rodata)
            [(package_source.PackageSourceBindingVerification.Match digest)
              (if (not (= digest source-digest))
                (compiler-dependency-tlci-record-unavailable!
                  state
                  key
                  (load.CompilerLoadDependencyCatalogFailure.StaleSource
                    source-digest
                    digest))
                (match (tlci.tlci-image-admit-host
                  image
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
        source-set.manifest-dir
        source-set.manifest.name)]
    (match (package_source.package-source-set-digest source-set)
      [(package_source.ResultPackageSourceDigest.Err message)
        (compiler-dependency-tlci-record-unavailable!
          state
          (compiler-dependency-tlci-base-key source-set artifact-path -1)
          (load.CompilerLoadDependencyCatalogFailure.Malformed
            (compiler-dependency-tlci-own-text message)))]
      [(package_source.ResultPackageSourceDigest.Ok source-digest)
        (if (not (io.file-exists? artifact-path))
          (compiler-dependency-tlci-record-unavailable!
            state
            (compiler-dependency-tlci-base-key
              source-set
              artifact-path
              source-digest)
            (load.CompilerLoadDependencyCatalogFailure.Missing
              (compiler-dependency-tlci-own-text artifact-path)))
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
                (match (tlci.tlci-parse-image bytes)
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
                      state
                      (load.compiler-load-dependency-catalog-owner-arena state)
                      source-set
                      artifact-path
                      source-digest
                      bytes
                      image)]))]))])))

(define (compiler-dependency-tlci-prepare-source-set!
  [state : load.CompilerLoadSessionState]
  [source-set : package_source.PackageSourceSet]) : i64
  (let
    [owner : i64
      (load.compiler-load-dependency-catalog-owner-arena-ensure! state)]
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
      (load.compiler-load-join-root-path root "typelisp.pkg")]
    (match (package_source.package-source-discover-for
      "build dependency catalog"
      manifest-path
      true)
      [(package_source.ResultPackageSourceSet.Ok source-set)
        (compiler-dependency-tlci-prepare-source-set! state source-set)]
      [(package_source.ResultPackageSourceSet.Err message)
        (let
          [owner : i64
            (load.compiler-load-dependency-catalog-owner-arena-ensure! state)]
          (in-arena
            (arena.Arena owner)
            (compiler-dependency-tlci-record-unavailable!
              state
              (compiler-dependency-tlci-key
                (load.compiler-load-canonical-path root)
                dep.alias
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
        state
        manifest-dir
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
  (compiler-dependency-tlci-prepare-deps-from!
    state
    manifest-dir
    (load.compiler-pkg-deps-list deps)
    0))