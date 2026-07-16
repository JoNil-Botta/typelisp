;; Build-configured embedded stdlib comptime image and production loader path.
(cfg
  (any stage0-seed-bootstrap test)
  (import compiler_embedded_stdlib_tlci_payload_seed as payload))
(cfg
  (not (any stage0-seed-bootstrap test))
  (import compiler_embedded_stdlib_tlci_payload as payload))
(import "tlci_loader.tl")
(import stdlib.array)

(defenum CompilerEmbeddedStdlibTlciValidation
  (Ok i64)
  (Err String))

(define (compiler-embedded-stdlib-tlci-length) : i64
  (array-length payload.embedded-stdlib-tlci-bytes))

(define (compiler-embedded-stdlib-tlci-copy) : (Array u8)
  (let
    [length : i64 (compiler-embedded-stdlib-tlci-length)]
    [out : (Array u8) (array.make-array u8 length)]
    [index : i64 0]
    (begin
      (while (< index length)
        (begin
          (array-set!
            out
            index
            (array-ref payload.embedded-stdlib-tlci-bytes index))
          (set! index (+ index 1))))
      out)))

(define (compiler-embedded-stdlib-tlci-host-table) : TlciHostCallbackTable
  (TlciHostCallbackTable
    tlci-host-callback-table-magic
    tlci-host-abi-version
    tlci-host-callback-table-size
    0
    0
    0
    1
    1))

;; Map the embedded image through the production W^X loader, execute its image
;; registration entry, validate every registered macro record, and release the
;; mapping. Callback addresses are nonzero sentinels because validation never
;; invokes a transformer; real dispatch installs compiler-owned callbacks.
(define (compiler-embedded-stdlib-tlci-validate) : CompilerEmbeddedStdlibTlciValidation
  (if (= (compiler-embedded-stdlib-tlci-length) 0)
    (CompilerEmbeddedStdlibTlciValidation.Err
      "embedded stdlib tlci is unavailable in the seed/test build")
    (match (tlci-loader-load-from-bytes-with-host
      (compiler-embedded-stdlib-tlci-copy)
      (compiler-embedded-stdlib-tlci-host-table))
      [(ResultTlciLoadedImage.Err message)
        (CompilerEmbeddedStdlibTlciValidation.Err message)]
      [(ResultTlciLoadedImage.Ok loaded)
        (let
          [count : i64 (struct-get loaded macro-entry-count)]
          [has-array-length : bool
            (match (tlci-loader-find-macro-entry
              (& loaded)
              "stdlib.array/length")
              [(ResultTlciMacroEntry.Ok _) true]
              [(ResultTlciMacroEntry.Err _) false])]
          (match (tlci-loader-release loaded)
            [(ResultTlciLoaderUnit.Err message)
              (CompilerEmbeddedStdlibTlciValidation.Err message)]
            [(ResultTlciLoaderUnit.Ok)
              (if (and (> count 0) has-array-length)
                (CompilerEmbeddedStdlibTlciValidation.Ok count)
                (CompilerEmbeddedStdlibTlciValidation.Err
                  "embedded stdlib tlci is missing its macro catalog"))]))])))