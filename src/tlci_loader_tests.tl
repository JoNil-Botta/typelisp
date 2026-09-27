;; tlci_loader_tests.tl - image fixtures, fault-injection cases and the
;; self-test for tlci_loader, kept out of the production module.
;; tlci_loader_smoke.tl runs the self-test; the package discovery lifetime
;; tests reuse the fixtures.
(import compiler_owned_view as owned_view)
(import stdlib.arena)
(import stdlib.string)
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.io)
(import tlci_core as tlci)
(import tlci_core_tests)
(cfg test (import tlci_pages as pages))
(import tlci_loader)

(define (tlci-loader-test-put-string!
  [bytes : (&mut bytes (__tl_dyn-array u8))]
  [offset : i64]
  [text : String]) : unit
  (let
    [i : i64 0]
    [n : i64 (tlci.tlci-string-length text)]
    (begin
      (while (< i n)
        (begin
          (set!
            (array-ref bytes (+ offset i))
            (cast (tlci.tlci-string-ref text i) : u8))
          (set! i (+ i 1))))
      unit)))

(define (tlci-loader-test-macro-loaded
  [storage : (& storage (__tl_dyn-array u8))]
  [table : i64]
  [count : i64]) : tlci_loader.TlciLoadedImage
  (let
    [base : i64 (tlci_loader.tlci-loader-u8-array-addr storage)]
    (tlci_loader.TlciLoadedImage
      base
      (array-length storage)
      true
      true
      true
      (+ base 96)
      (__tl_make-array i64 0)
      (__tl_make-array i64 0)
      0
      0
      0
      table
      count
      base
      (array-length storage)
      base
      (array-length storage)
      0
      0
      0
      0
      (__tl_make-array i64 0)
      (__tl_make-array i64 0)
      (__tl_make-array i64 0)
      (__tl_make-array i64 0)
      (__tl_make-array i64 0)
      0
      (__tl_make-array true))))

(define (tlci-loader-test-write-macro-entry!
  [storage : (&mut storage (__tl_dyn-array u8))]
  [offset : i64]
  [name-offset : i64]
  [name-len : i64]
  [function-offset : i64]
  [reserved0 : i64]) : unit
  (let
    [base : i64 (tlci_loader.tlci-loader-u8-array-addr storage)]
    [record : i64 (+ base offset)]
    (begin
      (tlci_loader.tlci-loader-write-mapped-i64!
        (+ record tlci.tlci-macro-entry-name-ptr-offset)
        (+ base name-offset))
      (tlci_loader.tlci-loader-write-mapped-i64!
        (+ record tlci.tlci-macro-entry-name-len-offset)
        name-len)
      (tlci_loader.tlci-loader-write-mapped-i64!
        (+ record tlci.tlci-macro-entry-function-offset)
        (+ base function-offset))
      (tlci_loader.tlci-loader-write-mapped-i64!
        (+ record tlci.tlci-macro-entry-reserved0-offset)
        reserved0))))

(define (tlci-loader-test-validation-error?
  [result : tlci_loader.ResultTlciLoaderUnit]
  [expected : String]) : bool
  (match result
    [(tlci_loader.ResultTlciLoaderUnit.Ok) false]
    [(tlci_loader.ResultTlciLoaderUnit.Err message)
      (string.eq message expected)]))

(define (tlci-loader-test-macro-entry-validation-ok?) : bool
  (let
    [storage : (__tl_dyn-array u8) (__tl_make-array u8 128)]
    [base : i64 (tlci_loader.tlci-loader-u8-array-addr storage)]
    (begin
      (tlci-loader-test-put-string! (&mut storage) 64 "dup")
      (tlci-loader-test-put-string! (&mut storage) 72 "dup")
      (tlci-loader-test-write-macro-entry! (&mut storage) 0 64 3 96 0)
      (tlci-loader-test-write-macro-entry! (&mut storage) 32 72 3 96 0)
      (let
        [duplicate-loaded : tlci_loader.TlciLoadedImage
          (tlci-loader-test-macro-loaded (& storage) base 2)]
        [duplicate : bool
          (tlci-loader-test-validation-error?
            (tlci_loader.tlci-loader-validate-macro-entries duplicate-loaded)
            "tlci loader: duplicate macro entry name")]
        [_distinct-name : unit
          (tlci-loader-test-put-string! (&mut storage) 72 "two")]
        [valid-loaded : tlci_loader.TlciLoadedImage
          (tlci-loader-test-macro-loaded (& storage) base 2)]
        [valid : bool
          (match (tlci_loader.tlci-loader-validate-macro-entries valid-loaded)
            [(tlci_loader.ResultTlciLoaderUnit.Ok) true]
            [(tlci_loader.ResultTlciLoaderUnit.Err _) false])]
        [_reserved : unit
          (tlci_loader.tlci-loader-write-mapped-i64!
            (+ base tlci.tlci-macro-entry-reserved0-offset)
            1)]
        [reserved-loaded : tlci_loader.TlciLoadedImage
          (tlci-loader-test-macro-loaded (& storage) base 1)]
        [reserved : bool
          (tlci-loader-test-validation-error?
            (tlci_loader.tlci-loader-validate-macro-entries reserved-loaded)
            "tlci loader: macro entry reserved field must be zero")]
        [_bad-name : unit
          (tlci-loader-test-write-macro-entry! (&mut storage) 0 127 2 96 0)]
        [bad-name-loaded : tlci_loader.TlciLoadedImage
          (tlci-loader-test-macro-loaded (& storage) base 1)]
        [bad-name : bool
          (tlci-loader-test-validation-error?
            (tlci_loader.tlci-loader-validate-macro-entries bad-name-loaded)
            "tlci loader: macro entry name outside mapped image")]
        [_bad-function : unit
          (tlci-loader-test-write-macro-entry! (&mut storage) 0 64 3 128 0)]
        [bad-function-loaded : tlci_loader.TlciLoadedImage
          (tlci-loader-test-macro-loaded (& storage) base 1)]
        [bad-function : bool
          (tlci-loader-test-validation-error?
            (tlci_loader.tlci-loader-validate-macro-entries bad-function-loaded)
            "tlci loader: macro entry function outside code section")]
        [unaligned-loaded : tlci_loader.TlciLoadedImage
          (tlci-loader-test-macro-loaded (& storage) (+ base 1) 1)]
        [unaligned : bool
          (tlci-loader-test-validation-error?
            (tlci_loader.tlci-loader-validate-macro-entries unaligned-loaded)
            "tlci loader: macro entry table must be 8-byte aligned")]
        [outside-loaded : tlci_loader.TlciLoadedImage
          (tlci-loader-test-macro-loaded (& storage) (+ base 112) 1)]
        [outside : bool
          (tlci-loader-test-validation-error?
            (tlci_loader.tlci-loader-validate-macro-entries outside-loaded)
            "tlci loader: macro entry table outside mapped image")]
        (and duplicate valid reserved bad-name bad-function unaligned outside)))))

(define (tlci-loader-test-resolved-function?
  [loaded : (& loaded tlci_loader.TlciLoadedImage)]
  [resolved : tlci_loader.TlciResolvedMacroEntry]
  [expected : i64]) : bool
  (match (tlci_loader.tlci-loader-resolved-macro-entry loaded resolved)
    [(tlci_loader.ResultTlciMacroEntry.Err _) false]
    [(tlci_loader.ResultTlciMacroEntry.Ok entry)
      (= entry.function-addr expected)]))

(define (tlci-loader-test-foreign-handle-error?
  [loaded : (& loaded tlci_loader.TlciLoadedImage)]
  [resolved : tlci_loader.TlciResolvedMacroEntry]) : bool
  (match (tlci_loader.tlci-loader-resolved-macro-entry loaded resolved)
    [(tlci_loader.ResultTlciMacroEntry.Ok _) false]
    [(tlci_loader.ResultTlciMacroEntry.Err message)
      (string.eq
        message
        "tlci loader: macro entry handle belongs to another catalog")]))

(define (tlci-loader-test-invalid-handle-error?
  [loaded : (& loaded tlci_loader.TlciLoadedImage)]
  [generation : i64]) : bool
  (match (tlci_loader.tlci-loader-resolved-macro-entry
    loaded
    (tlci_loader.TlciResolvedMacroEntry generation loaded.macro-entry-count))
    [(tlci_loader.ResultTlciMacroEntry.Ok _) false]
    [(tlci_loader.ResultTlciMacroEntry.Err message)
      (string.eq message "tlci loader: macro entry handle is invalid")]))

(define (tlci-loader-test-macro-entry-index-state-ok?) : bool
  (let
    [storage : (__tl_dyn-array u8) (__tl_make-array u8 128)]
    [base : i64 (tlci_loader.tlci-loader-u8-array-addr storage)]
    (begin
      (tlci-loader-test-put-string! (&mut storage) 64 "one")
      (tlci-loader-test-put-string! (&mut storage) 72 "two")
      (tlci-loader-test-write-macro-entry! (&mut storage) 0 64 3 96 0)
      (tlci-loader-test-write-macro-entry! (&mut storage) 32 72 3 104 0)
      (match (tlci_loader.tlci-loader-index-macro-entries
        (tlci-loader-test-macro-loaded (& storage) base 2))
        [(tlci_loader.ResultTlciLoadedImage.Err _) false]
        [(tlci_loader.ResultTlciLoadedImage.Ok indexed)
          (match (tlci_loader.tlci-loader-resolve-macro-entry (& indexed) "one")
            [(tlci_loader.TlciMacroEntryLookup.Resolved first)
              (let
                [first-function-ok : bool
                  (tlci-loader-test-resolved-function?
                    (& indexed)
                    first
                    (+ base 96))]
                [second-ok : bool
                  (match (tlci_loader.tlci-loader-resolve-macro-entry
                    (& indexed)
                    "two")
                    [(tlci_loader.TlciMacroEntryLookup.Resolved _) true]
                    [_ false])]
                [missing-ok : bool
                  (match (tlci_loader.tlci-loader-resolve-macro-entry
                    (& indexed)
                    "missing")
                    [(tlci_loader.TlciMacroEntryLookup.Missing) true]
                    [_ false])]
                [invalid-handle-ok : bool
                  (tlci-loader-test-invalid-handle-error?
                    (& indexed)
                    first.catalog-generation)]
                [_tamper : unit
                  (tlci_loader.tlci-loader-write-mapped-i64!
                    (+ base tlci.tlci-macro-entry-function-offset)
                    (+ base 112))]
                [cached-after-tamper-ok : bool
                  (tlci-loader-test-resolved-function?
                    (& indexed)
                    first
                    (+ base 96))]
                (and
                  first-function-ok
                  second-ok
                  missing-ok
                  invalid-handle-ok
                  cached-after-tamper-ok
                  (match (tlci_loader.tlci-loader-mark-macro-entry-shell!
                    (& indexed)
                    first)
                    [(tlci_loader.ResultTlciLoaderUnit.Err _) false]
                    [(tlci_loader.ResultTlciLoaderUnit.Ok)
                      (let
                        [shell-ok : bool
                          (match (tlci_loader.tlci-loader-resolve-macro-entry
                            (& indexed)
                            "one")
                            [(tlci_loader.TlciMacroEntryLookup.Shell shell)
                              (and
                                (=
                                  shell.catalog-generation
                                  first.catalog-generation)
                                (= shell.entry-index first.entry-index))]
                            [_ false])]
                        (and
                          shell-ok
                          (match (tlci_loader.tlci-loader-index-macro-entries
                            (tlci-loader-test-macro-loaded (& storage) base 2))
                            [(tlci_loader.ResultTlciLoadedImage.Err _) false]
                            [(tlci_loader.ResultTlciLoadedImage.Ok remapped)
                              (match (tlci_loader.tlci-loader-resolve-macro-entry
                                (& remapped)
                                "one")
                                [(tlci_loader.TlciMacroEntryLookup.Resolved
                                    second)
                                  (and
                                    (not
                                      (=
                                        first.catalog-generation
                                        second.catalog-generation))
                                    (tlci-loader-test-resolved-function?
                                      (& remapped)
                                      second
                                      (+ base 112))
                                    (tlci-loader-test-foreign-handle-error?
                                      (& remapped)
                                      first))]
                                [_ false])])))])))]
            [_ false])]))))

(define (tlci-loader-test-u64-record [value : i64]) : (__tl_dyn-array u8)
  (let
    [out : (__tl_dyn-array u8)
      (__tl_make-array u8 tlci.tlci-section-fixup-record-size)]
    (begin
      (tlci.tlci-set-u64! (&mut out) 0 value)
      out)))

(define (tlci-loader-test-entry-record
  [name-offset : i64]
  [name-len : i64]
  [code-offset : i64]) : (__tl_dyn-array u8)
  (let
    [out : (__tl_dyn-array u8)
      (__tl_make-array u8 tlci.tlci-section-entry-record-size)]
    (begin
      (tlci.tlci-set-u64!
        (&mut out)
        tlci_loader.tlci-loader-entry-name-offset
        name-offset)
      (tlci.tlci-set-u64!
        (&mut out)
        tlci_loader.tlci-loader-entry-name-len-offset
        name-len)
      (tlci.tlci-set-u64!
        (&mut out)
        tlci_loader.tlci-loader-entry-code-offset
        code-offset)
      out)))

(define (tlci-loader-test-symbol-bytes) : (__tl_dyn-array u8)
  (let
    [out : (__tl_dyn-array u8)
      (__tl_make-array u8 tlci.tlci-section-symbol-record-size)]
    (begin
      (tlci-loader-test-put-string!
        (&mut out)
        0
        (tlci.tlci-image-entry-symbol-shared-view))
      out)))

(define (tlci-loader-test-set-byte!
  [bytes : (&mut bytes (__tl_dyn-array u8))]
  [offset : i64]
  [value : i64]) : unit
  (set! (array-ref bytes offset) (tlci.tlci-byte value)))

(define (tlci-loader-test-success-code-for-target
  [reg-direct-modrm : i64]
  [reg-disp-modrm : i64]
  [context-modrm : i64]) : (__tl_dyn-array u8)
  (let
    [out : (__tl_dyn-array u8) (__tl_make-array u8 36)]
    (begin
      (tlci-loader-test-set-byte! (&mut out) 0 0x48)
      (tlci-loader-test-set-byte! (&mut out) 1 0xb8)
      (tlci.tlci-set-u64! (&mut out) 2 tlci.tlci-image-registration-magic)
      (tlci-loader-test-set-byte! (&mut out) 10 0x48)
      (tlci-loader-test-set-byte! (&mut out) 11 0x89)
      (tlci-loader-test-set-byte! (&mut out) 12 reg-direct-modrm)
      (tlci-loader-test-set-byte! (&mut out) 13 0x48)
      (tlci-loader-test-set-byte! (&mut out) 14 0xc7)
      (tlci-loader-test-set-byte! (&mut out) 15 reg-disp-modrm)
      (tlci-loader-test-set-byte! (&mut out) 16 0x08)
      (tlci-loader-test-set-byte! (&mut out) 17 tlci.tlci-host-abi-version)
      (tlci-loader-test-set-byte! (&mut out) 18 0x00)
      (tlci-loader-test-set-byte! (&mut out) 19 0x00)
      (tlci-loader-test-set-byte! (&mut out) 20 0x00)
      (tlci-loader-test-set-byte! (&mut out) 21 0x48)
      (tlci-loader-test-set-byte! (&mut out) 22 0xc7)
      (tlci-loader-test-set-byte! (&mut out) 23 reg-disp-modrm)
      (tlci-loader-test-set-byte! (&mut out) 24 0x10)
      (tlci-loader-test-set-byte! (&mut out) 25 0x40)
      (tlci-loader-test-set-byte! (&mut out) 26 0x00)
      (tlci-loader-test-set-byte! (&mut out) 27 0x00)
      (tlci-loader-test-set-byte! (&mut out) 28 0x00)
      (tlci-loader-test-set-byte! (&mut out) 29 0x48)
      (tlci-loader-test-set-byte! (&mut out) 30 0x89)
      (tlci-loader-test-set-byte! (&mut out) 31 context-modrm)
      (tlci-loader-test-set-byte! (&mut out) 32 0x18)
      (tlci-loader-test-set-byte! (&mut out) 33 0x31)
      (tlci-loader-test-set-byte! (&mut out) 34 0xc0)
      (tlci-loader-test-set-byte! (&mut out) 35 0xc3)
      out)))

(define (tlci-loader-test-success-code-bytes) : (__tl_dyn-array u8)
  (cfg
    windows
    (tlci-loader-test-success-code-for-target 0x02 0x42 0x4a)
    (tlci-loader-test-success-code-for-target 0x06 0x46 0x7e)))

(define (tlci-loader-test-status-code-bytes [status : i64]) : (__tl_dyn-array
    u8)
  (let
    [out : (__tl_dyn-array u8) (__tl_make-array u8 6)]
    (begin
      (tlci-loader-test-set-byte! (&mut out) 0 0xb8)
      (tlci-loader-test-set-byte! (&mut out) 1 status)
      (tlci-loader-test-set-byte! (&mut out) 2 0x00)
      (tlci-loader-test-set-byte! (&mut out) 3 0x00)
      (tlci-loader-test-set-byte! (&mut out) 4 0x00)
      (tlci-loader-test-set-byte! (&mut out) 5 0xc3)
      out)))

(define (tlci-loader-test-bad-registration-code-bytes) : (__tl_dyn-array u8)
  (let
    [out : (__tl_dyn-array u8) (__tl_make-array u8 3)]
    (begin
      (tlci-loader-test-set-byte! (&mut out) 0 0x31)
      (tlci-loader-test-set-byte! (&mut out) 1 0xc0)
      (tlci-loader-test-set-byte! (&mut out) 2 0xc3)
      out)))

(define (tlci-loader-test-rodata-bytes) : (__tl_dyn-array u8)
  (let
    [out : (__tl_dyn-array u8) (__tl_make-array u8 8)]
    (begin
      (tlci.tlci-set-u64! (&mut out) 0 0)
      out)))

(define (tlci-loader-test-image-with-code-and-imports
  [fixup-offset : i64]
  [code : (__tl_dyn-array u8)]
  [imports : (__tl_dyn-array u8)]) : tlci.TlciImage
  (tlci.tlci-make-image
    (tlci.tlci-build-host-platform)
    tlci.tlci-callback-abi-version
    "abcdef0"
    (tlci_core_tests.tlci-test-metadata)
    (tlci-loader-test-rodata-bytes)
    code
    (tlci-loader-test-u64-record fixup-offset)
    (tlci-loader-test-entry-record
      0
      (tlci.tlci-string-length (tlci.tlci-image-entry-symbol-shared-view))
      0)
    (tlci-loader-test-symbol-bytes)
    imports))

(define (tlci-loader-test-image-with-code
  [fixup-offset : i64]
  [code : (__tl_dyn-array u8)]) : tlci.TlciImage
  (tlci-loader-test-image-with-code-and-imports
    fixup-offset
    code
    (tlci.tlci-empty-bytes)))

(define (tlci-loader-test-image [fixup-offset : i64]) : tlci.TlciImage
  (tlci-loader-test-image-with-code
    fixup-offset
    (tlci-loader-test-success-code-bytes)))

(define (tlci-loader-test-emit-with-code [code : (__tl_dyn-array u8)]) : tlci.ResultTlciBytes
  (match (tlci.tlci-emit-image (tlci-loader-test-image-with-code 0 code))
    [(tlci.ResultTlciBytes.Err message) (tlci.ResultTlciBytes.Err message)]
    [(tlci.ResultTlciBytes.Ok bytes)
      (let
        [rodata-offset : i64 (tlci.tlci-read-u64 bytes 72)]
        [fixups-offset : i64 (tlci.tlci-read-u64 bytes 104)]
        (begin
          (tlci.tlci-set-u64! (&mut bytes) fixups-offset rodata-offset)
          (tlci.tlci-set-u64!
            (&mut bytes)
            tlci.tlci-hash-field-offset
            (tlci.tlci-content-hash bytes))
          (tlci.ResultTlciBytes.Ok bytes)))]))

(define (tlci-loader-test-emit-with-real-fixup) : tlci.ResultTlciBytes
  (match (tlci.tlci-emit-image (tlci-loader-test-image 0))
    [(tlci.ResultTlciBytes.Err message) (tlci.ResultTlciBytes.Err message)]
    [(tlci.ResultTlciBytes.Ok bytes)
      (let
        [rodata-offset : i64 (tlci.tlci-read-u64 bytes 72)]
        [fixups-offset : i64 (tlci.tlci-read-u64 bytes 104)]
        (begin
          (tlci.tlci-set-u64! (&mut bytes) fixups-offset rodata-offset)
          (tlci.tlci-set-u64!
            (&mut bytes)
            tlci.tlci-hash-field-offset
            (tlci.tlci-content-hash bytes))
          (tlci.ResultTlciBytes.Ok bytes)))]))

(define (tlci-loader-test-imports [name : String]) : (__tl_dyn-array u8)
  (let
    [name-len : i64 (tlci.tlci-string-length name)]
    [name-offset : i64
      (+
        tlci.tlci-section-import-header-size
        tlci.tlci-section-import-record-size)]
    [out : (__tl_dyn-array u8) (__tl_make-array u8 (+ name-offset name-len))]
    (begin
      (tlci.tlci-set-u64! (&mut out) 0 1)
      (tlci.tlci-set-u64! (&mut out) tlci.tlci-section-import-header-size 0)
      (tlci.tlci-set-u64!
        (&mut out)
        (+ tlci.tlci-section-import-header-size 8)
        name-offset)
      (tlci.tlci-set-u64!
        (&mut out)
        (+ tlci.tlci-section-import-header-size 16)
        name-len)
      (tlci-loader-test-put-string! (&mut out) name-offset name)
      out)))

(define (tlci-loader-test-host-table [name : String] [address : i64]) : tlci.TlciHostCallbackTable
  (tlci.TlciHostCallbackTable
    tlci.tlci-host-callback-table-magic
    tlci.tlci-host-abi-version
    tlci.tlci-host-callback-table-size
    0
    0
    0
    0
    1
    (__tl_make-array name)
    (__tl_make-array address)
    1))

(define (tlci-loader-test-emit-with-import [name : String]) : tlci.ResultTlciBytes
  (match (tlci.tlci-emit-image
    (tlci-loader-test-image-with-code-and-imports
      0
      (tlci-loader-test-success-code-bytes)
      (tlci-loader-test-imports name)))
    [(tlci.ResultTlciBytes.Err message) (tlci.ResultTlciBytes.Err message)]
    [(tlci.ResultTlciBytes.Ok bytes)
      (let
        [rodata-offset : i64 (tlci.tlci-read-u64 bytes 72)]
        [fixups-offset : i64 (tlci.tlci-read-u64 bytes 104)]
        [imports-offset : i64 (tlci.tlci-read-u64 bytes 152)]
        (begin
          (tlci.tlci-set-u64! (&mut bytes) fixups-offset rodata-offset)
          (tlci.tlci-set-u64!
            (&mut bytes)
            (+ imports-offset tlci.tlci-section-import-header-size)
            rodata-offset)
          (tlci.tlci-set-u64!
            (&mut bytes)
            tlci.tlci-hash-field-offset
            (tlci.tlci-content-hash bytes))
          (tlci.ResultTlciBytes.Ok bytes)))]))

;: Owner arena for the loader's own self-test loads. Every one of them either
;: rejects the image or releases it before returning, so the arena that is
;: current at the load already outlives the image. Named once here so the call
;: sites below still have to state an owner without repeating the reason.
(define (tlci-loader-test-owner-arena) : i64
  (arena.tl_arena_current))

(define (tlci-loader-test-named-imports-status) : i64
  (match (tlci-loader-test-emit-with-import "fuel-check")
    [(tlci.ResultTlciBytes.Err _) 1]
    [(tlci.ResultTlciBytes.Ok bytes)
      (let
        [bound : bool
          (match (tlci_loader.tlci-loader-load-from-bytes-with-host
            (tlci-loader-test-owner-arena)
            (owned_view.compiler-owned-shared-view bytes)
            (tlci-loader-test-host-table "fuel-check" 4096))
            [(tlci_loader.ResultTlciLoadedImage.Err _) false]
            [(tlci_loader.ResultTlciLoadedImage.Ok loaded)
              (let
                [ok : bool
                  (=
                    (tlci_loader.tlci-loader-read-mapped-i64 loaded.rodata-addr)
                    4096)]
                (match (tlci_loader.tlci-loader-release loaded)
                  [(tlci_loader.ResultTlciLoaderUnit.Ok) ok]
                  [(tlci_loader.ResultTlciLoaderUnit.Err _) false]))])]
        [missing : bool
          (tlci-loader-test-rejects?
            (tlci_loader.tlci-loader-load-from-bytes-with-host
              (tlci-loader-test-owner-arena)
              (owned_view.compiler-owned-shared-view bytes)
              (tlci-loader-test-host-table "other" 8192))
            "tlci loader: image `demo@0.1.0` has unresolved host import `fuel-check`")]
        [bad-slot-bytes : (__tl_dyn-array u8) (tlci.tlci-copy-bytes bytes)]
        [imports-offset : i64 (tlci.tlci-read-u64 bad-slot-bytes 152)]
        [_bad-slot : unit
          (begin
            (tlci.tlci-set-u64!
              (&mut bad-slot-bytes)
              (+ imports-offset tlci.tlci-section-import-header-size)
              8)
            (tlci.tlci-set-u64!
              (&mut bad-slot-bytes)
              tlci.tlci-hash-field-offset
              (tlci.tlci-content-hash bad-slot-bytes)))]
        [bad-slot : bool
          (tlci-loader-test-rejects?
            (tlci_loader.tlci-loader-load-from-bytes-with-host
              (tlci-loader-test-owner-arena)
              bad-slot-bytes
              (tlci-loader-test-host-table "fuel-check" 4096))
            "tlci loader: import slot outside loadable sections: 8")]
        (cond [(not bound) 2] [(not missing) 3] [(not bad-slot) 4] [else 0]))]))

(define (tlci-loader-test-loads-and-fixes-up-status) : i64
  (match (tlci-loader-test-emit-with-real-fixup)
    [(tlci.ResultTlciBytes.Err _) 10]
    [(tlci.ResultTlciBytes.Ok bytes)
      (match (tlci_loader.tlci-loader-load-from-bytes-with-host
        (tlci-loader-test-owner-arena)
        bytes
        (tlci_core_tests.tlci-test-host-callback-table))
        [(tlci_loader.ResultTlciLoadedImage.Err _) 11]
        [(tlci_loader.ResultTlciLoadedImage.Ok loaded)
          (let
            [image-base : i64 loaded.image-region-addr]
            [slot : i64
              (tlci_loader.tlci-loader-read-mapped-i64 loaded.rodata-addr)]
            [entry-ok : bool (= loaded.entry-addr loaded.code-addr)]
            [counts-ok : bool
              (and
                (= loaded.fixup-count 1)
                (= loaded.entry-count 1)
                (= loaded.symbol-count 1))]
            [registration-ok : bool
              (and
                (> loaded.host-table-addr 0)
                (> loaded.registration-addr 0)
                (= loaded.image-context loaded.host-table-addr)
                (= loaded.macro-entry-table 0)
                (= loaded.macro-entry-count 0)
                (=
                  (tlci_loader.tlci-loader-read-mapped-i64
                    loaded.registration-addr)
                  tlci.tlci-image-registration-magic)
                (=
                  (tlci_loader.tlci-loader-read-mapped-i64
                    loaded.host-table-addr)
                  tlci.tlci-host-callback-table-magic))]
            [release-ok : bool
              (match (tlci_loader.tlci-loader-release loaded)
                [(tlci_loader.ResultTlciLoaderUnit.Ok) true]
                [(tlci_loader.ResultTlciLoaderUnit.Err _) false])]
            (cond
              [(not (= slot image-base)) 12]
              [(not entry-ok) 13]
              [(not counts-ok) 14]
              [(not registration-ok) 15]
              [(not release-ok) 16]
              [else 0]))])]))

(define (tlci-loader-test-rejects?
  [result : tlci_loader.ResultTlciLoadedImage]
  [expected : String]) : bool
  (match result
    [(tlci_loader.ResultTlciLoadedImage.Err message)
      (string.eq message expected)]
    [(tlci_loader.ResultTlciLoadedImage.Ok loaded)
      (match (tlci_loader.tlci-loader-release loaded)
        [(tlci_loader.ResultTlciLoaderUnit.Ok) false]
        [(tlci_loader.ResultTlciLoaderUnit.Err _) false])]))

(define (tlci-loader-test-registration-rejections-ok?) : bool
  (match (tlci-loader-test-emit-with-code
    (tlci-loader-test-status-code-bytes
      tlci.tlci-host-callback-status-bad-request))
    [(tlci.ResultTlciBytes.Err _) false]
    [(tlci.ResultTlciBytes.Ok status-bytes)
      (match (tlci-loader-test-emit-with-code
        (tlci-loader-test-bad-registration-code-bytes))
        [(tlci.ResultTlciBytes.Err _) false]
        [(tlci.ResultTlciBytes.Ok bad-registration-bytes)
          (and
            (tlci-loader-test-rejects?
              (tlci_loader.tlci-loader-load-from-bytes-with-host
                (tlci-loader-test-owner-arena)
                status-bytes
                (tlci_core_tests.tlci-test-host-callback-table))
              "tlci loader: tlci_image_entry returned status 4")
            (tlci-loader-test-rejects?
              (tlci_loader.tlci-loader-load-from-bytes-with-host
                (tlci-loader-test-owner-arena)
                bad-registration-bytes
                (tlci_core_tests.tlci-test-host-callback-table))
              (str_cat.str-cat
                "tlci loader: invalid image registration: "
                "tlci host ABI: bad image registration magic")))])]))

(define (tlci-loader-test-rejections-ok?) : bool
  (match (tlci-loader-test-emit-with-real-fixup)
    [(tlci.ResultTlciBytes.Err _) false]
    [(tlci.ResultTlciBytes.Ok bytes)
      (let
        [bad-fixup : (__tl_dyn-array u8) (tlci.tlci-copy-bytes bytes)]
        [fixups-offset : i64 (tlci.tlci-read-u64 bytes 104)]
        (begin
          (tlci.tlci-set-u64! (&mut bad-fixup) fixups-offset 8)
          (tlci.tlci-set-u64!
            (&mut bad-fixup)
            tlci.tlci-hash-field-offset
            (tlci.tlci-content-hash bad-fixup))
          (and
            (tlci-loader-test-rejects?
              (tlci_loader.tlci-loader-load-from-bytes
                (tlci.tlci-slice-bytes bytes 0 20))
              "tlci: truncated header")
            (tlci-loader-test-rejects?
              (tlci_loader.tlci-loader-load-from-bytes bad-fixup)
              "tlci loader: fixup offset outside loadable sections: 8")
            (tlci-loader-test-rejects?
              (tlci_loader.tlci-loader-load-from-bytes-with-host
                (tlci-loader-test-owner-arena)
                bytes
                (tlci.TlciHostCallbackTable
                  tlci.tlci-host-callback-table-magic
                  (+ tlci.tlci-host-abi-version 1)
                  tlci.tlci-host-callback-table-size
                  0
                  0
                  0
                  1
                  1
                  (__tl_make-array String 0)
                  (__tl_make-array i64 0)
                  0))
              "tlci host ABI: unsupported callback ABI version 3"))))]))

(define (tlci-loader-test-platform-admission-ok?) : bool
  (let
    [host-platform : i64 (tlci.tlci-build-host-platform)]
    [other-platform : i64
      (if (= host-platform tlci.tlci-host-platform-x86-64-windows)
        tlci.tlci-host-platform-x86-64-linux
        tlci.tlci-host-platform-x86-64-windows)]
    (match (tlci.tlci-emit-image
      (tlci_core_tests.tlci-test-platform-image other-platform true))
      [(tlci.ResultTlciBytes.Err _) false]
      [(tlci.ResultTlciBytes.Ok mismatch-bytes)
        (match (tlci.tlci-emit-image-v2-legacy-compatible
          (tlci_core_tests.tlci-test-platform-image
            tlci.tlci-host-platform-x86-64-legacy
            true))
          [(tlci.ResultTlciBytes.Err _) false]
          [(tlci.ResultTlciBytes.Ok legacy-bytes)
            (match (tlci.tlci-emit-image
              (tlci_core_tests.tlci-test-platform-image other-platform false))
              [(tlci.ResultTlciBytes.Err _) false]
              [(tlci.ResultTlciBytes.Ok metadata-bytes)
                (and
                  (tlci-loader-test-rejects?
                    (tlci_loader.tlci-loader-load-from-bytes mismatch-bytes)
                    (str_cat.str-cat
                      "tlci: package `demo` code-bearing image host platform mismatch: image="
                      (tlci.tlci-host-platform-name other-platform)
                      ", host="
                      (tlci.tlci-host-platform-name host-platform)))
                  (tlci-loader-test-rejects?
                    (tlci_loader.tlci-loader-load-from-bytes legacy-bytes)
                    "tlci: package `demo` code-bearing image uses legacy/ambiguous host platform")
                  (tlci-loader-test-rejects?
                    (tlci_loader.tlci-loader-load-from-bytes metadata-bytes)
                    "tlci loader: image has no code section"))])])])))

;; R3-P2d regression. The retained host callback table and registration block
;; must belong to `owner-arena`, NOT to the arena that happened to be current
;; when the image was mapped -- so an image loaded from inside a transient
;; arena keeps working after that arena is destroyed. This test is the compiler
;; failure in miniature: map the image with a transient arena current, destroy
;; the transient arena, then perform exactly the read
;; `tlci-loader-dispatch-macro` performs on every dispatch.
;;
;; Without the owner parameter this reads unmapped pages and the smoke dies on
;; SIGSEGV rather than returning a status.
(define (tlci-loader-test-retained-storage-outlives-load-arena-status) : i64
  (match (tlci-loader-test-emit-with-real-fixup)
    [(tlci.ResultTlciBytes.Err _) 70]
    [(tlci.ResultTlciBytes.Ok bytes)
      (let
        [owner : i64 (arena.tl_arena_current)]
        [transient : i64 (arena.tl_arena_make)]
        [_enter : unit
          (unsafe
            ;; lint-allow: raw-arena-op -- moved from the audited tlci_loader module.
            (arena.tl_arena_set transient))]
        [loaded-result : tlci_loader.ResultTlciLoadedImage
          (tlci_loader.tlci-loader-load-from-bytes-with-host
            owner
            bytes
            (tlci_core_tests.tlci-test-host-callback-table))]
        [_leave : unit
          (unsafe
            ;; lint-allow: raw-arena-op -- moved from the audited tlci_loader module.
            (arena.tl_arena_set owner))]
        [_drop : unit
          (unsafe
            ;; lint-allow: raw-arena-op -- moved from the audited tlci_loader module.
            (arena.tl_arena_destroy transient))]
        (match loaded-result
          [(tlci_loader.ResultTlciLoadedImage.Err _) 71]
          [(tlci_loader.ResultTlciLoadedImage.Ok loaded)
            (let
              ;; The dispatch-path read, after the load arena is gone.
              [host-magic : i64
                (tlci_loader.tlci-loader-read-mapped-i64 loaded.host-table-addr)]
              [host-context : i64
                (tlci_loader.tlci-loader-read-mapped-i64
                  (+
                    loaded.host-table-addr
                    tlci.tlci-host-callback-table-host-context-offset))]
              [registration-magic : i64
                (tlci_loader.tlci-loader-read-mapped-i64
                  loaded.registration-addr)]
              [released : bool
                (match (tlci_loader.tlci-loader-release loaded)
                  [(tlci_loader.ResultTlciLoaderUnit.Ok) true]
                  [(tlci_loader.ResultTlciLoaderUnit.Err _) false])]
              (cond
                [(not (= host-magic tlci.tlci-host-callback-table-magic)) 72]
                [(not (= host-context 1234)) 73]
                [(not (= registration-magic tlci.tlci-image-registration-magic))
                  74]
                [(not released) 75]
                [else 0]))]))]))

(cfg
  test
  (define (tlci-loader-test-rollback-case?
    [bytes : (__tl_dyn-array u8)]
    [host-table : tlci.TlciHostCallbackTable]
    [copy? : bool]
    [data-protect? : bool]
    [code-protect? : bool]
    [release? : bool]
    [index? : bool]
    [expected : String]) : bool
    (let
      [_inject : unit
        (pages.tlci-pages-test-inject!
          copy?
          code-protect?
          data-protect?
          release?)]
      [_index : unit (tlci_loader.tlci-loader-test-hooks-set! index? false)]
      [result : tlci_loader.ResultTlciLoadedImage
        (tlci_loader.tlci-loader-load-from-bytes-with-host
          (tlci-loader-test-owner-arena)
          bytes
          host-table)]
      [attempts : i64 pages.tlci-pages-test-release-attempts]
      [index-destroys : i64 tlci_loader.tlci-loader-test-index-arena-destroys]
      [_reset : unit
        (begin
          (pages.tlci-pages-test-inject! false false false false)
          (tlci_loader.tlci-loader-test-hooks-set! false false))]
      (and
        (= attempts 1)
        (= index-destroys 0)
        (match result
          [(tlci_loader.ResultTlciLoadedImage.Err message)
            (string.eq message expected)]
          [(tlci_loader.ResultTlciLoadedImage.Ok loaded)
            (match (tlci_loader.tlci-loader-release loaded)
              [(tlci_loader.ResultTlciLoaderUnit.Ok) false]
              [(tlci_loader.ResultTlciLoaderUnit.Err _) false])])))))

(cfg
  test
  (define (tlci-loader-test-rollback-faults?) : bool
    (match (tlci-loader-test-emit-with-real-fixup)
      [(tlci.ResultTlciBytes.Err _) false]
      [(tlci.ResultTlciBytes.Ok bytes)
        (and
          (tlci-loader-test-rollback-case?
            (owned_view.compiler-owned-shared-view bytes)
            (tlci_core_tests.tlci-test-host-callback-table)
            true
            false
            false
            false
            false
            "tlci pages: injected copy failure")
          (tlci-loader-test-rollback-case?
            (owned_view.compiler-owned-shared-view bytes)
            (tlci_core_tests.tlci-test-host-callback-table)
            true
            false
            false
            true
            false
            "tlci pages: injected copy failure; cleanup/release: tlci pages: page release failed")
          (tlci-loader-test-rollback-case?
            (owned_view.compiler-owned-shared-view bytes)
            (tlci_core_tests.tlci-test-host-callback-table)
            false
            true
            false
            true
            false
            "tlci pages: data page protection failed; cleanup/release: tlci pages: page release failed")
          (tlci-loader-test-rollback-case?
            (owned_view.compiler-owned-shared-view bytes)
            (tlci_core_tests.tlci-test-host-callback-table)
            false
            false
            true
            true
            false
            "tlci pages: code page protection failed; cleanup/release: tlci pages: page release failed")
          (tlci-loader-test-rollback-case?
            (owned_view.compiler-owned-shared-view bytes)
            (tlci_core_tests.tlci-test-host-callback-table)
            false
            false
            false
            true
            true
            "tlci loader: injected macro index failure; cleanup/release: tlci pages: page release failed")
          (match (tlci-loader-test-emit-with-import "fuel-check")
            [(tlci.ResultTlciBytes.Err _) false]
            [(tlci.ResultTlciBytes.Ok import-bytes)
              (tlci-loader-test-rollback-case?
                import-bytes
                (tlci-loader-test-host-table "other" 8192)
                false
                false
                false
                true
                false
                "tlci loader: image `demo@0.1.0` has unresolved host import `fuel-check`; cleanup/release: tlci pages: page release failed")])
          (match (tlci-loader-test-emit-with-code
            (tlci-loader-test-status-code-bytes
              tlci.tlci-host-callback-status-bad-request))
            [(tlci.ResultTlciBytes.Err _) false]
            [(tlci.ResultTlciBytes.Ok status-bytes)
              (tlci-loader-test-rollback-case?
                status-bytes
                (tlci_core_tests.tlci-test-host-callback-table)
                false
                false
                false
                true
                false
                "tlci loader: tlci_image_entry returned status 4; cleanup/release: tlci pages: page release failed")])
          (match (tlci-loader-test-emit-with-code
            (tlci-loader-test-bad-registration-code-bytes))
            [(tlci.ResultTlciBytes.Err _) false]
            [(tlci.ResultTlciBytes.Ok bad-registration-bytes)
              (tlci-loader-test-rollback-case?
                bad-registration-bytes
                (tlci_core_tests.tlci-test-host-callback-table)
                false
                false
                false
                true
                false
                "tlci loader: invalid image registration: tlci host ABI: bad image registration magic; cleanup/release: tlci pages: page release failed")]))])))

(test
  tlci-loader-rollback-fault-matrix
  (if (tlci-loader-test-rollback-faults?)
    unit
    (io.panic "tlci loader: injected rollback failed")))

(cfg
  test
  (define (tlci-loader-test-explicit-release-revokes? [release-fails? : bool]) : bool
    (match (tlci-loader-test-emit-with-real-fixup)
      [(tlci.ResultTlciBytes.Err _) false]
      [(tlci.ResultTlciBytes.Ok bytes)
        (match (tlci_loader.tlci-loader-load-from-bytes-with-host
          (tlci-loader-test-owner-arena)
          bytes
          (tlci_core_tests.tlci-test-host-callback-table))
          [(tlci_loader.ResultTlciLoadedImage.Err _) false]
          [(tlci_loader.ResultTlciLoadedImage.Ok loaded)
            (let
              [stale : tlci_loader.TlciLoadedImage
                (owned_view.compiler-owned-shared-view loaded)]
              [_inject : unit
                (pages.tlci-pages-test-inject! false false false release-fails?)]
              [result : tlci_loader.ResultTlciLoaderUnit
                (tlci_loader.tlci-loader-release loaded)]
              [dispatch : tlci_loader.ResultTlciMacroDispatch
                (tlci_loader.tlci-loader-dispatch-macro
                  (& stale)
                  "missing"
                  0
                  (__tl_make-array i64 0)
                  0)]
              [second : tlci_loader.ResultTlciLoaderUnit
                (tlci_loader.tlci-loader-release stale)]
              [attempts : i64 pages.tlci-pages-test-release-attempts]
              [_reset : unit
                (pages.tlci-pages-test-inject! false false false false)]
              (and
                (= attempts 1)
                (match result
                  [(tlci_loader.ResultTlciLoaderUnit.Ok) (not release-fails?)]
                  [(tlci_loader.ResultTlciLoaderUnit.Err message)
                    (and
                      release-fails?
                      (string.eq message "tlci pages: page release failed"))])
                (match dispatch
                  [(tlci_loader.ResultTlciMacroDispatch.Ok _) false]
                  [(tlci_loader.ResultTlciMacroDispatch.Err message)
                    (string.eq message "tlci loader: image has been released")])
                (match second
                  [(tlci_loader.ResultTlciLoaderUnit.Ok) false]
                  [(tlci_loader.ResultTlciLoaderUnit.Err message)
                    (string.eq message "tlci loader: image already released")])))])])))

(test
  tlci-loader-explicit-release-revokes-copied-handles
  (if (and
    (tlci-loader-test-explicit-release-revokes? true)
    (tlci-loader-test-explicit-release-revokes? false))
    unit
    (io.panic "tlci loader: explicit release did not revoke copies")))

(cfg
  test
  (define (tlci-loader-test-index-arena-rollback?) : bool
    (let
      [storage : (__tl_dyn-array u8) (__tl_make-array u8 128)]
      [base : i64 (tlci_loader.tlci-loader-u8-array-addr storage)]
      [_entry : unit
        (begin
          (tlci-loader-test-put-string! (&mut storage) 64 "one")
          (tlci-loader-test-write-macro-entry! (&mut storage) 0 64 3 96 0))]
      [loaded : tlci_loader.TlciLoadedImage
        (tlci-loader-test-macro-loaded (& storage) base 1)]
      [_inject : unit
        (begin
          (tlci_loader.tlci-loader-test-index-arena-destroys-reset!)
          (tlci_loader.tlci-loader-test-hooks-set! false true)
          (pages.tlci-pages-test-inject! false false false true))]
      [indexed : tlci_loader.ResultTlciLoadedImage
        (tlci_loader.tlci-loader-index-macro-entries
          (owned_view.compiler-owned-shared-view loaded))]
      [result : tlci_loader.ResultTlciLoadedImage
        (match indexed
          [(tlci_loader.ResultTlciLoadedImage.Err message)
            (tlci_loader.tlci-loader-rollback-loaded loaded message)]
          [(tlci_loader.ResultTlciLoadedImage.Ok value)
            (tlci_loader.tlci-loader-rollback-loaded
              value
              "unexpected index success")])]
      [attempts : i64 pages.tlci-pages-test-release-attempts]
      [destroys : i64 tlci_loader.tlci-loader-test-index-arena-destroys]
      [_reset : unit
        (begin
          (tlci_loader.tlci-loader-test-hooks-set! false false)
          (pages.tlci-pages-test-inject! false false false false))]
      (and
        (= attempts 1)
        (= destroys 1)
        (match result
          [(tlci_loader.ResultTlciLoadedImage.Err message)
            (string.eq
              message
              "tlci loader: injected macro index failure; cleanup/release: tlci pages: page release failed")]
          [(tlci_loader.ResultTlciLoadedImage.Ok _) false])))))

(test
  tlci-loader-index-arena-rollback-on-release-failure
  (if (tlci-loader-test-index-arena-rollback?)
    unit
    (io.panic "tlci loader: index arena rollback was not exact-once")))

(cfg
  test
  (define (tlci-loader-test-index-arena-release?) : bool
    (let
      [storage : (__tl_dyn-array u8) (__tl_make-array u8 128)]
      [base : i64 (tlci_loader.tlci-loader-u8-array-addr storage)]
      [_entry : unit
        (begin
          (tlci-loader-test-put-string! (&mut storage) 64 "one")
          (tlci-loader-test-write-macro-entry! (&mut storage) 0 64 3 96 0))]
      [loaded : tlci_loader.TlciLoadedImage
        (tlci-loader-test-macro-loaded (& storage) base 1)]
      (match (tlci_loader.tlci-loader-index-macro-entries loaded)
        [(tlci_loader.ResultTlciLoadedImage.Err _) false]
        [(tlci_loader.ResultTlciLoadedImage.Ok indexed)
          (let
            [stale : tlci_loader.TlciLoadedImage
              (owned_view.compiler-owned-shared-view indexed)]
            [_inject : unit
              (begin
                (tlci_loader.tlci-loader-test-index-arena-destroys-reset!)
                (pages.tlci-pages-test-inject! false false false true))]
            [result : tlci_loader.ResultTlciLoaderUnit
              (tlci_loader.tlci-loader-release indexed)]
            [second : tlci_loader.ResultTlciLoaderUnit
              (tlci_loader.tlci-loader-release stale)]
            [attempts : i64 pages.tlci-pages-test-release-attempts]
            [destroys : i64 tlci_loader.tlci-loader-test-index-arena-destroys]
            [_reset : unit
              (pages.tlci-pages-test-inject! false false false false)]
            (and
              (= attempts 1)
              (= destroys 1)
              (match result
                [(tlci_loader.ResultTlciLoaderUnit.Ok) false]
                [(tlci_loader.ResultTlciLoaderUnit.Err message)
                  (string.eq message "tlci pages: page release failed")])
              (match second
                [(tlci_loader.ResultTlciLoaderUnit.Ok) false]
                [(tlci_loader.ResultTlciLoaderUnit.Err message)
                  (string.eq message "tlci loader: image already released")])))]))))

(test
  tlci-loader-index-arena-destroyed-on-explicit-release-failure
  (if (tlci-loader-test-index-arena-release?)
    unit
    (io.panic "tlci loader: failed release destroyed index arena twice")))

(cfg
  test
  (define (tlci-loader-test-native-index-rollback?) : bool
    (match (tlci-loader-test-emit-with-real-fixup)
      [(tlci.ResultTlciBytes.Err _) false]
      [(tlci.ResultTlciBytes.Ok bytes)
        (match (tlci.tlci-parse-image
          (owned_view.compiler-owned-shared-view bytes))
          [(tlci.ResultTlciImage.Err _) false]
          [(tlci.ResultTlciImage.Ok parsed)
            (let
              [table : tlci.TlciHostCallbackTable
                (tlci_core_tests.tlci-test-host-callback-table)]
              (match (tlci_loader.tlci-loader-load-parsed
                (tlci-loader-test-owner-arena)
                bytes
                parsed
                (& table))
                [(tlci_loader.ResultTlciLoadedImage.Err _) false]
                [(tlci_loader.ResultTlciLoadedImage.Ok loaded)
                  (let
                    [_inject : unit
                      (begin
                        (pages.tlci-pages-test-inject! false false false true)
                        (tlci_loader.tlci-loader-test-hooks-set! true false))]
                    [result : tlci_loader.ResultTlciLoadedImage
                      (tlci_loader.tlci-loader-install-native-table
                        (tlci-loader-test-owner-arena)
                        bytes
                        loaded
                        table
                        0)]
                    [attempts : i64 pages.tlci-pages-test-release-attempts]
                    [_reset : unit
                      (begin
                        (pages.tlci-pages-test-inject! false false false false)
                        (tlci_loader.tlci-loader-test-hooks-set! false false))]
                    (and
                      (= attempts 1)
                      (match result
                        [(tlci_loader.ResultTlciLoadedImage.Err message)
                          (string.eq
                            message
                            "tlci loader: injected macro index failure; cleanup/release: tlci pages: page release failed")]
                        [(tlci_loader.ResultTlciLoadedImage.Ok _) false])))]))])])))

(test
  tlci-loader-native-table-index-rollback
  (if (tlci-loader-test-native-index-rollback?)
    unit
    (io.panic "tlci loader: native table rollback lost release failure")))

(define (tlci-loader-self-test-status) : i64
  (let
    [load-status : i64 (tlci-loader-test-loads-and-fixes-up-status)]
    [retained-status : i64
      (tlci-loader-test-retained-storage-outlives-load-arena-status)]
    (cond
      [(not (= load-status 0)) load-status]
      [(not (= retained-status 0)) retained-status]
      [(not (tlci-loader-test-rejections-ok?)) 2]
      [(not (tlci-loader-test-registration-rejections-ok?)) 3]
      [(not (tlci-loader-test-macro-entry-validation-ok?)) 4]
      [(not (tlci-loader-test-macro-entry-index-state-ok?)) 5]
      [(not (tlci-loader-test-platform-admission-ok?)) 6]
      [(not (= (tlci-loader-test-named-imports-status) 0))
        (+ 50 (tlci-loader-test-named-imports-status))]
      [else 0])))

(define (tlci-loader-self-test-ok?) : bool
  (= (tlci-loader-self-test-status) 0))

(define (tlci-loader-self-test) : i64
  (if (tlci-loader-self-test-ok?)
    42
    (tlci-loader-self-test-status)))