;; tlci_loader_smoke.tl - Executable smoke for tlci loader helpers.
;; Keep the loader/core pair on one flat identity until canonical load-once
;; aliasing can replace this compatibility edge (#5130).
(import "../tlci_loader.tl")
(import "../tlci_core.tl")
(import compiler_comptime_image_core as comptime_image)
(import compiler_comptime_diagnostics_core as comptime_diagnostics)
(import stdlib.string)

(define tlci-loader-smoke-macro-name : String
  "native-probe")

(define (tlci-loader-smoke-host-table) : TlciHostCallbackTable
  (TlciHostCallbackTable
    tlci-host-callback-table-magic
    tlci-host-abi-version
    tlci-host-callback-table-size
    0
    0
    0
    1
    1))

(define (tlci-loader-smoke-dispatch-result?
  [result : ResultTlciMacroDispatch]
  [status : i64]
  [handle : i64]) : bool
  (match result
    [(ResultTlciMacroDispatch.Err _) false]
    [(ResultTlciMacroDispatch.Ok dispatch)
      (and
        (= (struct-get dispatch status) status)
        (= (struct-get dispatch result-handle) handle))]))

(define (tlci-loader-smoke-native-loaded? [bytes : (Array u8)]) : bool
  (match (tlci-loader-load-from-bytes-with-host
    bytes
    (tlci-loader-smoke-host-table))
    [(ResultTlciLoadedImage.Err _) false]
    [(ResultTlciLoadedImage.Ok loaded)
      (let
        [installed : bool
          (match (tlci-loader-probe-install-self-callback!
            (& loaded)
            tlci-loader-smoke-macro-name)
            [(ResultTlciLoaderUnit.Err _) false]
            [(ResultTlciLoaderUnit.Ok) true])]
        [missing : bool
          (match (tlci-loader-find-macro-entry
            (& loaded)
            "missing-native-probe")
            [(ResultTlciMacroEntry.Err message)
              (string.eq message "tlci loader: macro entry not found")]
            [(ResultTlciMacroEntry.Ok _) false])]
        [success : bool
          (and
            installed
            (tlci-loader-smoke-dispatch-result?
              (tlci-loader-dispatch-macro
                (& loaded)
                tlci-loader-smoke-macro-name
                0x5151
                (make-array i64 0)
                -9)
              tlci-host-callback-status-ok
              4242))]
        [_fuel-status : unit
          (tlci-loader-probe-set-host-status!
            (& loaded)
            tlci-host-callback-status-fuel-exhausted)]
        [scratch : (Array i64) (make-array 31337)]
        [fuel : bool
          (and
            (tlci-loader-smoke-dispatch-result?
              (tlci-loader-dispatch-macro
                (& loaded)
                tlci-loader-smoke-macro-name
                0x5151
                scratch
                -9)
              tlci-host-callback-status-fuel-exhausted
              -9)
            ;; The failed native expansion neither commits its result slot nor
            ;; mutates caller-owned scratch/operand state. Compiler AST and
            ;; typechecker state are outside this focused API by construction.
            (= (array-ref scratch 0) 31337))]
        [fuel-diagnostic : bool
          (let
            [message : String
              (tlci-loader-macro-status-diagnostic
                tlci-loader-smoke-macro-name
                tlci-host-callback-status-fuel-exhausted)]
            [interpreted-prefix : String
              (comptime_diagnostics.compiler-comptime-fuel-diagnostic-message)]
            (and
              (string.is-string-prefix-at (& message) (& interpreted-prefix) 0)
              (string.eq
                message
                "compile-time evaluation limit exceeded in macro native-probe")))]
        [wrong-session : bool
          (tlci-loader-smoke-dispatch-result?
            (tlci-loader-dispatch-macro
              (& loaded)
              tlci-loader-smoke-macro-name
              0
              (make-array i64 0)
              -9)
            tlci-host-callback-status-bad-request
            -9)]
        [released : bool
          (match (tlci-loader-release loaded)
            [(ResultTlciLoaderUnit.Ok) true]
            [(ResultTlciLoaderUnit.Err _) false])]
        (and missing success fuel fuel-diagnostic wrong-session released))]))

(define (tlci-loader-smoke-package-loaded? [bytes : (Array u8)]) : bool
  (match (tlci-loader-load-from-bytes-with-host
    bytes
    (tlci-loader-smoke-host-table))
    [(ResultTlciLoadedImage.Err _) false]
    [(ResultTlciLoadedImage.Ok loaded)
      (let
        [installed : bool
          (match (tlci-loader-probe-install-self-callback!
            (& loaded)
            "pkg/alpha")
            [(ResultTlciLoaderUnit.Err _) false]
            [(ResultTlciLoaderUnit.Ok) true])]
        [alpha : bool
          (tlci-loader-smoke-dispatch-result?
            (tlci-loader-dispatch-macro
              (& loaded)
              "pkg/alpha"
              0
              (make-array i64 0)
              -1)
            tlci-host-callback-status-ok
            0)]
        [beta : bool
          (tlci-loader-smoke-dispatch-result?
            (tlci-loader-dispatch-macro
              (& loaded)
              "pkg/beta"
              0
              (make-array i64 0)
              -1)
            tlci-host-callback-status-ok
            0)]
        [released : bool
          (match (tlci-loader-release loaded)
            [(ResultTlciLoaderUnit.Ok) true]
            [(ResultTlciLoaderUnit.Err _) false])]
        (and installed alpha beta released))]))

(define (tlci-loader-smoke-package-repeat?
  [metadata : TlciMetadata]
  [names : (Array String)]
  [first : (Array u8)]) : bool
  (match (tlci-emit-code-bearing-package-image
    metadata
    "package-smoke-v1"
    names
    (cfg windows true false))
    [(ResultTlciBytes.Err _) false]
    [(ResultTlciBytes.Ok second) (tlci-bytes-eq? first second)]))

(define (tlci-loader-smoke-package-ok?) : bool
  (let
    [metadata : TlciMetadata (tlci-make-metadata "v1" "pkg" "0.1.0")]
    [names : (Array String) (make-array "pkg/alpha" "pkg/beta")]
    (match (tlci-emit-code-bearing-package-image
      metadata
      "package-smoke-v1"
      names
      (cfg windows true false))
      [(ResultTlciBytes.Err _) false]
      [(ResultTlciBytes.Ok first)
        (and
          (tlci-loader-smoke-package-repeat? metadata names first)
          (tlci-loader-smoke-package-loaded? first))])))

(define (tlci-loader-smoke-malformed-rejected?
  [bytes : (Array u8)]
  [macro-table-offset : i64]) : bool
  (let
    [malformed : (Array u8) (tlci-copy-bytes bytes)]
    [code-offset : i64 (tlci-read-u64 malformed 88)]
    [reserved-offset : i64
      (+ (+ code-offset macro-table-offset) tlci-macro-entry-reserved0-offset)]
    (begin
      (tlci-set-u64! malformed reserved-offset 1)
      (tlci-set-u64!
        malformed
        tlci-hash-field-offset
        (tlci-content-hash malformed))
      (match (tlci-loader-load-from-bytes-with-host
        malformed
        (tlci-loader-smoke-host-table))
        [(ResultTlciLoadedImage.Err message)
          (string.eq
            message
            "tlci loader: macro entry reserved field must be zero")]
        [(ResultTlciLoadedImage.Ok loaded)
          (begin
            (tlci-loader-release loaded)
            false)]))))

(define (tlci-loader-smoke-native-ok?) : bool
  (match (comptime_image.compiler-comptime-lower-probe
    (comptime_image.compiler-comptime-probe-program)
    (cfg windows true false))
    [(comptime_image.ResultCompilerComptimeImagePayload.Err _) false]
    [(comptime_image.ResultCompilerComptimeImagePayload.Ok payload)
      (match (tlci-emit-native-comptime-probe-image (cfg windows true false))
        [(ResultTlciBytes.Err _) false]
        [(ResultTlciBytes.Ok first)
          (match (tlci-emit-native-comptime-probe-image
            (cfg windows true false))
            [(ResultTlciBytes.Err _) false]
            [(ResultTlciBytes.Ok second)
              (and
                (tlci-bytes-eq? first second)
                (tlci-loader-smoke-malformed-rejected?
                  first
                  (struct-get payload macro-table-offset))
                (tlci-loader-smoke-native-loaded? first))])])]))

(define (main) : i64
  (if (= (tlci-loader-self-test) 42)
    (if (and (tlci-loader-smoke-native-ok?) (tlci-loader-smoke-package-ok?))
      42
      5)
    1))