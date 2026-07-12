;; tlci_loader_smoke.tl - Executable smoke for tlci loader helpers.
(import tlci_loader)
(import tlci_core as tlci)

(define tlci-loader-smoke-macro-name : String
  "native-probe")

(define (tlci-loader-smoke-host-table) : tlci.TlciHostCallbackTable
  (tlci.TlciHostCallbackTable
    tlci.tlci-host-callback-table-magic
    tlci.tlci-host-abi-version
    tlci.tlci-host-callback-table-size
    0
    0
    0
    1
    1))

(define (tlci-loader-smoke-dispatch-result?
  [result : tlci_loader.ResultTlciMacroDispatch]
  [status : i64]
  [handle : i64]) : bool
  (match result
    [(tlci_loader.ResultTlciMacroDispatch.Err _) false]
    [(tlci_loader.ResultTlciMacroDispatch.Ok dispatch)
      (and
        (= (struct-get dispatch status) status)
        (= (struct-get dispatch result-handle) handle))]))

(define (tlci-loader-smoke-native-loaded? [bytes : (Array u8)]) : bool
  (match (tlci_loader.tlci-loader-load-from-bytes-with-host
    bytes
    (tlci-loader-smoke-host-table))
    [(tlci_loader.ResultTlciLoadedImage.Err _) false]
    [(tlci_loader.ResultTlciLoadedImage.Ok loaded)
      (let
        [installed : bool
          (match (tlci_loader.tlci-loader-probe-install-self-callback!
            (& loaded)
            tlci-loader-smoke-macro-name)
            [(tlci_loader.ResultTlciLoaderUnit.Err _) false]
            [(tlci_loader.ResultTlciLoaderUnit.Ok) true])]
        [success : bool
          (and
            installed
            (tlci-loader-smoke-dispatch-result?
              (tlci_loader.tlci-loader-dispatch-macro
                (& loaded)
                tlci-loader-smoke-macro-name
                0x5151
                (make-array i64 0)
                -9)
              tlci.tlci-host-callback-status-ok
              4242))]
        [_fuel-status : unit
          (tlci_loader.tlci-loader-probe-set-host-status!
            (& loaded)
            tlci.tlci-host-callback-status-fuel-exhausted)]
        [scratch : (Array i64) (make-array 31337)]
        [fuel : bool
          (and
            (tlci-loader-smoke-dispatch-result?
              (tlci_loader.tlci-loader-dispatch-macro
                (& loaded)
                tlci-loader-smoke-macro-name
                0x5151
                scratch
                -9)
              tlci.tlci-host-callback-status-fuel-exhausted
              -9)
            ;; The failed native expansion neither commits its result slot nor
            ;; mutates caller-owned scratch/operand state. Compiler AST and
            ;; typechecker state are outside this focused API by construction.
            (= (array-ref scratch 0) 31337))]
        [wrong-session : bool
          (tlci-loader-smoke-dispatch-result?
            (tlci_loader.tlci-loader-dispatch-macro
              (& loaded)
              tlci-loader-smoke-macro-name
              0
              (make-array i64 0)
              -9)
            tlci.tlci-host-callback-status-bad-request
            -9)]
        [released : bool
          (match (tlci_loader.tlci-loader-release loaded)
            [(tlci_loader.ResultTlciLoaderUnit.Ok) true]
            [(tlci_loader.ResultTlciLoaderUnit.Err _) false])]
        (and success fuel wrong-session released))]))

(define (tlci-loader-smoke-native-ok?) : bool
  (match (tlci.tlci-emit-native-comptime-probe-image (cfg windows true false))
    [(tlci.ResultTlciBytes.Err _) false]
    [(tlci.ResultTlciBytes.Ok first)
      (match (tlci.tlci-emit-native-comptime-probe-image
        (cfg windows true false))
        [(tlci.ResultTlciBytes.Err _) false]
        [(tlci.ResultTlciBytes.Ok second)
          (and
            (tlci.tlci-bytes-eq? first second)
            (tlci-loader-smoke-native-loaded? first))])]))

(define (main) : i64
  (if (= (tlci_loader.tlci-loader-self-test) 42)
    (if (tlci-loader-smoke-native-ok?)
      42
      5)
    1))