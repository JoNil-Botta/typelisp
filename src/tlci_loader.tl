;; tlci_loader.tl - Dormant tlci comptime image loader core.
;;
;; General package/stdlib macro dispatch lands in later slices. This module
;; owns the loader boundary: parse/validate a tlci image, map it into
;; page-backed host memory, apply load-base fixups while pages are writable,
;; finalize code pages as RX through tlci_pages, and run the image registration
;; entry point through the backend runtime's raw C-ABI bridge, validate its
;; macro table, and invoke registered entries through the six-argument ABI.
(import stdlib.string)
(import stdlib.str_cat_runtime as str_cat)
(import compiler_comptime_diagnostics_core as comptime_diagnostics)
(import tlci_core as tlci)
(import tlci_pages as pages)

(unsafe
  (extern (tlci-loader-call-image-entry-raw
    [entry-addr : i64]
    [host-table-addr : i64]
    [registration-addr : i64]) : i64 (:symbol "tl_tlci_call_image_entry")))

(unsafe
  (extern (tlci-loader-call-macro-entry-raw
    [entry-addr : i64]
    [image-context : i64]
    [host-context : i64]
    [session-context : i64]
    [operands-addr : i64]
    [operand-count : i64]
    [result-addr : i64]) : i64 (:symbol "tl_tlci_call_macro_entry")))

(defstruct TlciLoadedImage
  ;; Keep the page region flattened at this cross-module boundary. The
  ;; published stage0 predates imported nominal aggregate layout resolution,
  ;; while this loader must remain directly buildable by that seed compiler.
  ;; Reconstruct the pages-owned value only at its release call.
  (image-region-addr i64)
  (image-region-size i64)
  (image-region-code bool)
  (image-region-writable bool)
  (image-region-executable bool)
  (entry-addr i64)
  (host-table-storage (Array i64))
  (registration-storage (Array i64))
  (host-table-addr i64)
  (registration-addr i64)
  (image-context i64)
  (macro-entry-table i64)
  (macro-entry-count i64)
  (rodata-addr i64)
  (rodata-len i64)
  (code-addr i64)
  (code-len i64)
  (fixup-count i64)
  (entry-count i64)
  (symbol-count i64))

(defenum ResultTlciLoadedImage
  (Ok TlciLoadedImage)
  (Err String))

(defenum ResultTlciLoaderUnit
  (Ok)
  (Err String))

(defenum ResultTlciLoaderI64
  (Ok i64)
  (Err String))

(defstruct TlciMacroEntry
  (name-addr i64)
  (name-len i64)
  (function-addr i64))

(defenum ResultTlciMacroEntry
  (Ok TlciMacroEntry)
  (Err String))

(defstruct TlciMacroDispatch
  (status i64)
  (result-handle i64))

(defenum ResultTlciMacroDispatch
  (Ok TlciMacroDispatch)
  (Err String))

(define tlci-loader-entry-name-offset : i64
  0)
(define tlci-loader-entry-name-len-offset : i64
  8)
(define tlci-loader-entry-code-offset : i64
  16)

(define (tlci-loader-section-contains-slot?
  [slot-offset : i64]
  [section-offset : i64]
  [section-len : i64]) : bool
  (and
    (> section-len 0)
    (>= slot-offset section-offset)
    (<= (+ slot-offset 8) (+ section-offset section-len))))

(define (tlci-loader-fixup-offset-ok?
  [slot-offset : i64]
  [rodata-offset : i64]
  [rodata-len : i64]
  [code-offset : i64]
  [code-len : i64]) : bool
  (and
    (= (% slot-offset 8) 0)
    (or
      (tlci-loader-section-contains-slot? slot-offset rodata-offset rodata-len)
      (tlci-loader-section-contains-slot? slot-offset code-offset code-len))))

(define (tlci-loader-validate-fixups-at
  [fixups : (Array u8)]
  [index : i64]
  [count : i64]
  [rodata-offset : i64]
  [rodata-len : i64]
  [code-offset : i64]
  [code-len : i64]) : ResultTlciLoaderUnit
  (if (>= index count)
    (ResultTlciLoaderUnit.Ok)
    (let
      [slot-offset : i64
        (tlci.tlci-read-u64
          fixups
          (* index tlci.tlci-section-fixup-record-size))]
      (if (tlci-loader-fixup-offset-ok?
        slot-offset
        rodata-offset
        rodata-len
        code-offset
        code-len)
        (tlci-loader-validate-fixups-at
          fixups
          (+ index 1)
          count
          rodata-offset
          rodata-len
          code-offset
          code-len)
        (ResultTlciLoaderUnit.Err
          (str_cat.str-cat
            "tlci loader: fixup offset outside loadable sections: "
            (string.int->string slot-offset)))))))

(define (tlci-loader-validate-fixups
  [image : tlci.TlciImage]
  [rodata-offset : i64]
  [code-offset : i64]) : ResultTlciLoaderUnit
  (tlci-loader-validate-fixups-at
    (struct-get image fixups)
    0
    (/
      (array-length (struct-get image fixups))
      tlci.tlci-section-fixup-record-size)
    rodata-offset
    (array-length (struct-get image rodata))
    code-offset
    (array-length (struct-get image code))))

(define (tlci-loader-symbol-range-ok?
  [symbols : (Array u8)]
  [offset : i64]
  [len : i64]) : bool
  (and
    (>= offset 0)
    (>= len 0)
    (<= offset (array-length symbols))
    (<= len (- (array-length symbols) offset))))

(define (tlci-loader-symbol-name-eq-at?
  [symbols : (Array u8)]
  [offset : i64]
  [expected : String]
  [index : i64]
  [len : i64]) : bool
  (if (>= index len)
    true
    (and
      (=
        (tlci.tlci-byte-at symbols (+ offset index))
        (cast (tlci.tlci-string-ref expected index) : i64))
      (tlci-loader-symbol-name-eq-at? symbols offset expected (+ index 1) len))))

(define (tlci-loader-symbol-name-eq?
  [symbols : (Array u8)]
  [offset : i64]
  [len : i64]
  [expected : String]) : bool
  (and
    (= len (tlci.tlci-string-length expected))
    (tlci-loader-symbol-range-ok? symbols offset len)
    (tlci-loader-symbol-name-eq-at? symbols offset expected 0 len)))

(define (tlci-loader-find-entry-at
  [entries : (Array u8)]
  [symbols : (Array u8)]
  [index : i64]
  [count : i64]
  [code-len : i64]
  [found : bool]
  [found-code-offset : i64]) : ResultTlciLoaderI64
  (if (>= index count)
    (if found
      (ResultTlciLoaderI64.Ok found-code-offset)
      (ResultTlciLoaderI64.Err "tlci loader: missing tlci_image_entry entry"))
    (let
      [record-offset : i64 (* index tlci.tlci-section-entry-record-size)]
      [name-offset : i64
        (tlci.tlci-read-u64
          entries
          (+ record-offset tlci-loader-entry-name-offset))]
      [name-len : i64
        (tlci.tlci-read-u64
          entries
          (+ record-offset tlci-loader-entry-name-len-offset))]
      [code-offset : i64
        (tlci.tlci-read-u64
          entries
          (+ record-offset tlci-loader-entry-code-offset))]
      (cond
        [(not (tlci-loader-symbol-range-ok? symbols name-offset name-len))
          (ResultTlciLoaderI64.Err
            "tlci loader: entry name range outside symbol table")]
        [(or (< code-offset 0) (>= code-offset code-len))
          (ResultTlciLoaderI64.Err
            "tlci loader: entry code offset outside code section")]
        [(tlci-loader-symbol-name-eq?
            symbols
            name-offset
            name-len
            tlci.tlci-image-entry-symbol)
          (if found
            (ResultTlciLoaderI64.Err
              "tlci loader: duplicate tlci_image_entry entry")
            (tlci-loader-find-entry-at
              entries
              symbols
              (+ index 1)
              count
              code-len
              true
              code-offset))]
        [else
          (tlci-loader-find-entry-at
            entries
            symbols
            (+ index 1)
            count
            code-len
            found
            found-code-offset)]))))

(define (tlci-loader-find-entry-code-offset [image : tlci.TlciImage]) : ResultTlciLoaderI64
  (let
    [code-len : i64 (array-length (struct-get image code))]
    [entry-count : i64
      (/
        (array-length (struct-get image entries))
        tlci.tlci-section-entry-record-size)]
    (if (= entry-count 0)
      (ResultTlciLoaderI64.Err "tlci loader: missing entry table")
      (tlci-loader-find-entry-at
        (struct-get image entries)
        (struct-get image symbols)
        0
        entry-count
        code-len
        false
        0))))

(define (tlci-loader-read-mapped-i64 [addr : i64]) : i64
  (unsafe
    (ptr-read (ptr-cast (pages.tlci-pages-addr->ptr-u8 addr) : (Ptr i64)))))

(define (tlci-loader-write-mapped-i64! [addr : i64] [value : i64]) : unit
  (unsafe
    (ptr-write!
      (ptr-cast (pages.tlci-pages-addr->mut-u8 addr) : (MutPtr i64))
      value)))

(define (tlci-loader-i64-array-addr [items : (Array i64)]) : i64
  (cast
    (unsafe
      (ptr->int (ptr-cast (array-data items) : (Ptr u8))))
    : i64))

(define (tlci-loader-u8-array-addr [items : (Array u8)]) : i64
  (cast
    (unsafe
      (ptr->int (array-data items)))
    : i64))

(define (tlci-loader-host-table-storage [table : tlci.TlciHostCallbackTable]) : (Array
    i64)
  (make-array
    (struct-get table magic)
    (struct-get table abi-version)
    (struct-get table byte-size)
    (struct-get table host-context)
    (struct-get table reserved0)
    (struct-get table reserved1)
    (struct-get table invoke-callback)
    (struct-get table abort-callback)))

(define (tlci-loader-registration-storage) : (Array i64)
  (make-array i64 8))

(define (tlci-loader-read-registration [addr : i64]) : tlci.TlciImageRegistration
  (tlci.TlciImageRegistration
    (tlci-loader-read-mapped-i64
      (+ addr tlci.tlci-image-registration-magic-offset))
    (tlci-loader-read-mapped-i64
      (+ addr tlci.tlci-image-registration-abi-version-offset))
    (tlci-loader-read-mapped-i64
      (+ addr tlci.tlci-image-registration-byte-size-offset))
    (tlci-loader-read-mapped-i64
      (+ addr tlci.tlci-image-registration-image-context-offset))
    (tlci-loader-read-mapped-i64
      (+ addr tlci.tlci-image-registration-reserved0-offset))
    (tlci-loader-read-mapped-i64
      (+ addr tlci.tlci-image-registration-reserved1-offset))
    (tlci-loader-read-mapped-i64
      (+ addr tlci.tlci-image-registration-macro-entry-table-offset))
    (tlci-loader-read-mapped-i64
      (+ addr tlci.tlci-image-registration-macro-entry-count-offset))))

(define (tlci-loader-apply-fixups-at!
  [image-base : i64]
  [fixups : (Array u8)]
  [index : i64]
  [count : i64]) : unit
  (if (>= index count)
    unit
    (let
      [slot-offset : i64
        (tlci.tlci-read-u64
          fixups
          (* index tlci.tlci-section-fixup-record-size))]
      [slot-addr : i64 (+ image-base slot-offset)]
      [current : i64 (tlci-loader-read-mapped-i64 slot-addr)]
      (begin
        (tlci-loader-write-mapped-i64! slot-addr (+ current image-base))
        (tlci-loader-apply-fixups-at! image-base fixups (+ index 1) count)))))

(define (tlci-loader-apply-fixups! [image-base : i64] [image : tlci.TlciImage]) : unit
  (tlci-loader-apply-fixups-at!
    image-base
    (struct-get image fixups)
    0
    (/
      (array-length (struct-get image fixups))
      tlci.tlci-section-fixup-record-size)))

(define (tlci-loader-protect-rodata
  [image-base : i64]
  [rodata-offset : i64]
  [rodata-len : i64]) : ResultTlciLoaderUnit
  (if (= rodata-len 0)
    (ResultTlciLoaderUnit.Ok)
    (match (pages.tlci-pages-protect-data-readonly
      (pages.TlciPageRegion
        (+ image-base rodata-offset)
        (pages.tlci-pages-round-size rodata-len)
        false
        true
        false))
      [(pages.ResultTlciPageRegion.Ok _) (ResultTlciLoaderUnit.Ok)]
      [(pages.ResultTlciPageRegion.Err message)
        (ResultTlciLoaderUnit.Err message)])))

(define (tlci-loader-protect-code
  [image-base : i64]
  [code-offset : i64]
  [code-len : i64]) : ResultTlciLoaderUnit
  (match (pages.tlci-pages-protect-code-executable
    (pages.TlciPageRegion
      (+ image-base code-offset)
      (pages.tlci-pages-round-size code-len)
      true
      true
      false))
    [(pages.ResultTlciPageRegion.Ok _) (ResultTlciLoaderUnit.Ok)]
    [(pages.ResultTlciPageRegion.Err message)
      (ResultTlciLoaderUnit.Err message)]))

(define (tlci-loader-loaded-image-region [loaded : TlciLoadedImage]) : pages.TlciPageRegion
  (pages.TlciPageRegion
    (struct-get loaded image-region-addr)
    (struct-get loaded image-region-size)
    (struct-get loaded image-region-code)
    (struct-get loaded image-region-writable)
    (struct-get loaded image-region-executable)))

(define (tlci-loader-release [loaded : TlciLoadedImage]) : ResultTlciLoaderUnit
  (match (pages.tlci-pages-release (tlci-loader-loaded-image-region loaded))
    [(pages.ResultTlciPageUnit.Ok) (ResultTlciLoaderUnit.Ok)]
    [(pages.ResultTlciPageUnit.Err message) (ResultTlciLoaderUnit.Err message)]))

(define (tlci-loader-loaded-image
  [image-region : pages.TlciPageRegion]
  [image-base : i64]
  [rodata-offset : i64]
  [rodata-len : i64]
  [code-offset : i64]
  [code-len : i64]
  [entry-code-offset : i64]
  [fixup-count : i64]
  [entry-count : i64]
  [symbol-count : i64]) : TlciLoadedImage
  (TlciLoadedImage
    (struct-get image-region addr)
    (struct-get image-region size)
    (struct-get image-region code)
    (struct-get image-region writable)
    (struct-get image-region executable)
    (+ image-base (+ code-offset entry-code-offset))
    (make-array i64 0)
    (make-array i64 0)
    0
    0
    0
    0
    0
    (+ image-base rodata-offset)
    rodata-len
    (+ image-base code-offset)
    code-len
    fixup-count
    entry-count
    symbol-count))

(define (tlci-loader-loaded-image-with-registration
  [loaded : TlciLoadedImage]
  [host-table-storage : (Array i64)]
  [registration-storage : (Array i64)]
  [host-table-addr : i64]
  [registration-addr : i64]
  [registration : tlci.TlciImageRegistration]) : TlciLoadedImage
  (TlciLoadedImage
    (struct-get loaded image-region-addr)
    (struct-get loaded image-region-size)
    (struct-get loaded image-region-code)
    (struct-get loaded image-region-writable)
    (struct-get loaded image-region-executable)
    (struct-get loaded entry-addr)
    host-table-storage
    registration-storage
    host-table-addr
    registration-addr
    (struct-get registration image-context)
    (struct-get registration macro-entry-table)
    (struct-get registration macro-entry-count)
    (struct-get loaded rodata-addr)
    (struct-get loaded rodata-len)
    (struct-get loaded code-addr)
    (struct-get loaded code-len)
    (struct-get loaded fixup-count)
    (struct-get loaded entry-count)
    (struct-get loaded symbol-count)))

(define (tlci-loader-registration-status-error [status : i64]) : String
  (str_cat.str-cat
    "tlci loader: tlci_image_entry returned status "
    (string.int->string status)))

(define (tlci-loader-registration-error [message : String]) : String
  (str_cat.str-cat "tlci loader: invalid image registration: " message))

(define (tlci-loader-load-from-bytes-with-registration
  [bytes : (Array u8)]
  [host-table : tlci.TlciHostCallbackTable]) : ResultTlciLoadedImage
  (match (tlci-loader-load-from-bytes bytes)
    [(ResultTlciLoadedImage.Err message) (ResultTlciLoadedImage.Err message)]
    [(ResultTlciLoadedImage.Ok loaded)
      (let
        [host-storage : (Array i64) (tlci-loader-host-table-storage host-table)]
        [registration-storage : (Array i64) (tlci-loader-registration-storage)]
        [host-table-addr : i64 (tlci-loader-i64-array-addr host-storage)]
        [registration-addr : i64
          (tlci-loader-i64-array-addr registration-storage)]
        [status : i64
          (unsafe
            (tlci-loader-call-image-entry-raw
              (struct-get loaded entry-addr)
              host-table-addr
              registration-addr))]
        (if (not (= status tlci.tlci-image-entry-success))
          (begin
            (tlci-loader-release loaded)
            (ResultTlciLoadedImage.Err
              (tlci-loader-registration-status-error status)))
          (let
            [registration : tlci.TlciImageRegistration
              (tlci-loader-read-registration registration-addr)]
            (match (tlci.tlci-validate-image-registration registration)
              [(tlci.ResultTlciHostAbi.Err message)
                (begin
                  (tlci-loader-release loaded)
                  (ResultTlciLoadedImage.Err
                    (tlci-loader-registration-error message)))]
              [(tlci.ResultTlciHostAbi.Ok)
                (let
                  [registered : TlciLoadedImage
                    (tlci-loader-loaded-image-with-registration
                      loaded
                      host-storage
                      registration-storage
                      host-table-addr
                      registration-addr
                      registration)]
                  (match (tlci-loader-validate-macro-entries (& registered))
                    [(ResultTlciLoaderUnit.Err message)
                      (begin
                        (tlci-loader-release registered)
                        (ResultTlciLoadedImage.Err message))]
                    [(ResultTlciLoaderUnit.Ok)
                      (ResultTlciLoadedImage.Ok registered)]))]))))]))

(define (tlci-loader-load-mapped-region
  [bytes : (Array u8)]
  [image : tlci.TlciImage]
  [image-region : pages.TlciPageRegion]
  [entry-code-offset : i64]
  [rodata-offset : i64]
  [code-offset : i64]) : ResultTlciLoadedImage
  (let
    [image-base : i64 (struct-get image-region addr)]
    [rodata-len : i64 (array-length (struct-get image rodata))]
    [code-len : i64 (array-length (struct-get image code))]
    [fixup-count : i64
      (/
        (array-length (struct-get image fixups))
        tlci.tlci-section-fixup-record-size)]
    [entry-count : i64
      (/
        (array-length (struct-get image entries))
        tlci.tlci-section-entry-record-size)]
    [symbol-count : i64
      (/
        (array-length (struct-get image symbols))
        tlci.tlci-section-symbol-record-size)]
    (begin
      (match (pages.tlci-pages-copy-from-array! image-region bytes)
        [(pages.ResultTlciPageUnit.Err message)
          (begin
            (pages.tlci-pages-release image-region)
            (return (ResultTlciLoadedImage.Err message)))]
        [(pages.ResultTlciPageUnit.Ok) unit])
      (tlci-loader-apply-fixups! image-base image)
      (match (tlci-loader-protect-rodata image-base rodata-offset rodata-len)
        [(ResultTlciLoaderUnit.Err message)
          (begin
            (pages.tlci-pages-release image-region)
            (return (ResultTlciLoadedImage.Err message)))]
        [(ResultTlciLoaderUnit.Ok) unit])
      (match (tlci-loader-protect-code image-base code-offset code-len)
        [(ResultTlciLoaderUnit.Err message)
          (begin
            (pages.tlci-pages-release image-region)
            (return (ResultTlciLoadedImage.Err message)))]
        [(ResultTlciLoaderUnit.Ok) unit])
      (ResultTlciLoadedImage.Ok
        (tlci-loader-loaded-image
          image-region
          image-base
          rodata-offset
          rodata-len
          code-offset
          code-len
          entry-code-offset
          fixup-count
          entry-count
          symbol-count)))))

(define (tlci-loader-load-parsed [bytes : (Array u8)] [image : tlci.TlciImage]) : ResultTlciLoadedImage
  (let
    [rodata-offset : i64 (tlci.tlci-read-u64 bytes 72)]
    [code-offset : i64 (tlci.tlci-read-u64 bytes 88)]
    [code-len : i64 (array-length (struct-get image code))]
    (if (= code-len 0)
      (ResultTlciLoadedImage.Err "tlci loader: image has no code section")
      (match (tlci-loader-find-entry-code-offset image)
        [(ResultTlciLoaderI64.Err message) (ResultTlciLoadedImage.Err message)]
        [(ResultTlciLoaderI64.Ok entry-code-offset)
          (match (tlci-loader-validate-fixups image rodata-offset code-offset)
            [(ResultTlciLoaderUnit.Err message)
              (ResultTlciLoadedImage.Err message)]
            [(ResultTlciLoaderUnit.Ok)
              (match (pages.tlci-pages-allocate-data (array-length bytes))
                [(pages.ResultTlciPageRegion.Err message)
                  (ResultTlciLoadedImage.Err message)]
                [(pages.ResultTlciPageRegion.Ok image-region)
                  (tlci-loader-load-mapped-region
                    bytes
                    image
                    image-region
                    entry-code-offset
                    rodata-offset
                    code-offset)])])]))))

(define (tlci-loader-load-from-bytes [bytes : (Array u8)]) : ResultTlciLoadedImage
  (match (tlci.tlci-parse-image bytes)
    [(tlci.ResultTlciImage.Err message) (ResultTlciLoadedImage.Err message)]
    [(tlci.ResultTlciImage.Ok image) (tlci-loader-load-parsed bytes image)]))

(define (tlci-loader-load-from-bytes-with-host
  [bytes : (Array u8)]
  [host-table : tlci.TlciHostCallbackTable]) : ResultTlciLoadedImage
  (match (tlci.tlci-validate-host-callback-table host-table)
    [(tlci.ResultTlciHostAbi.Err message) (ResultTlciLoadedImage.Err message)]
    [(tlci.ResultTlciHostAbi.Ok)
      (tlci-loader-load-from-bytes-with-registration bytes host-table)]))

(define (tlci-loader-address-range-contained?
  [addr : i64]
  [len : i64]
  [base : i64]
  [size : i64]) : bool
  (and (>= addr base) (>= len 0) (>= size len) (<= addr (+ base (- size len)))))

(define (tlci-loader-image-range-contained?
  [loaded : (& loaded TlciLoadedImage)]
  [addr : i64]
  [len : i64]) : bool
  (tlci-loader-address-range-contained?
    addr
    len
    (struct-get loaded image-region-addr)
    (struct-get loaded image-region-size)))

(define (tlci-loader-code-address?
  [loaded : (& loaded TlciLoadedImage)]
  [addr : i64]) : bool
  (tlci-loader-address-range-contained?
    addr
    1
    (struct-get loaded code-addr)
    (struct-get loaded code-len)))

(define (tlci-loader-mapped-name-eq-at?
  [addr : i64]
  [expected : String]
  [index : i64]
  [len : i64]) : bool
  (if (>= index len)
    true
    (and
      (=
        (cast
          (unsafe
            (ptr-read (ptr-offset (pages.tlci-pages-addr->ptr-u8 addr) index)))
          : i64)
        (cast (tlci.tlci-string-ref expected index) : i64))
      (tlci-loader-mapped-name-eq-at? addr expected (+ index 1) len))))

(define (tlci-loader-mapped-name-eq?
  [loaded : (& loaded TlciLoadedImage)]
  [addr : i64]
  [len : i64]
  [expected : String]) : bool
  (and
    (= len (tlci.tlci-string-length expected))
    (tlci-loader-image-range-contained? loaded addr len)
    (tlci-loader-mapped-name-eq-at? addr expected 0 len)))

(define (tlci-loader-read-macro-entry
  [loaded : (& loaded TlciLoadedImage)]
  [index : i64]) : ResultTlciMacroEntry
  (let
    [count : i64 (struct-get loaded macro-entry-count)]
    [table : i64 (struct-get loaded macro-entry-table)]
    [record-size : i64 tlci.tlci-macro-entry-record-size]
    (cond
      [(or (< index 0) (>= index count))
        (ResultTlciMacroEntry.Err "tlci loader: macro entry index out of range")]
      [(or
          (< count 0)
          (> count (/ (struct-get loaded image-region-size) record-size)))
        (ResultTlciMacroEntry.Err "tlci loader: macro entry count is invalid")]
      [(not (= (% table 8) 0))
        (ResultTlciMacroEntry.Err
          "tlci loader: macro entry table must be 8-byte aligned")]
      [(not
          (tlci-loader-image-range-contained?
            loaded
            table
            (* count record-size)))
        (ResultTlciMacroEntry.Err
          "tlci loader: macro entry table outside mapped image")]
      [else
        (let
          [record : i64 (+ table (* index record-size))]
          [name-addr : i64
            (tlci-loader-read-mapped-i64
              (+ record tlci.tlci-macro-entry-name-ptr-offset))]
          [name-len : i64
            (tlci-loader-read-mapped-i64
              (+ record tlci.tlci-macro-entry-name-len-offset))]
          [function-addr : i64
            (tlci-loader-read-mapped-i64
              (+ record tlci.tlci-macro-entry-function-offset))]
          [reserved0 : i64
            (tlci-loader-read-mapped-i64
              (+ record tlci.tlci-macro-entry-reserved0-offset))]
          (cond
            [(not (= reserved0 0))
              (ResultTlciMacroEntry.Err
                "tlci loader: macro entry reserved field must be zero")]
            [(or
                (<= name-len 0)
                (not
                  (tlci-loader-image-range-contained? loaded name-addr name-len)))
              (ResultTlciMacroEntry.Err
                "tlci loader: macro entry name outside mapped image")]
            [(not (tlci-loader-code-address? loaded function-addr))
              (ResultTlciMacroEntry.Err
                "tlci loader: macro entry function outside code section")]
            [else
              (ResultTlciMacroEntry.Ok
                (TlciMacroEntry name-addr name-len function-addr))]))])))

(define (tlci-loader-mapped-name-ranges-eq-at?
  [left : i64]
  [right : i64]
  [index : i64]
  [len : i64]) : bool
  (if (>= index len)
    true
    (and
      (=
        (unsafe
          (ptr-read (ptr-offset (pages.tlci-pages-addr->ptr-u8 left) index)))
        (unsafe
          (ptr-read (ptr-offset (pages.tlci-pages-addr->ptr-u8 right) index))))
      (tlci-loader-mapped-name-ranges-eq-at? left right (+ index 1) len))))

(define (tlci-loader-macro-entry-names-eq?
  [left : TlciMacroEntry]
  [right : TlciMacroEntry]) : bool
  (and
    (= (struct-get left name-len) (struct-get right name-len))
    (tlci-loader-mapped-name-ranges-eq-at?
      (struct-get left name-addr)
      (struct-get right name-addr)
      0
      (struct-get left name-len))))

(define (tlci-loader-macro-entry-duplicate-before?
  [loaded : (& loaded TlciLoadedImage)]
  [entry : TlciMacroEntry]
  [index : i64]) : ResultTlciLoaderUnit
  (if (<= index 0)
    (ResultTlciLoaderUnit.Ok)
    (match (tlci-loader-read-macro-entry loaded (- index 1))
      [(ResultTlciMacroEntry.Err message) (ResultTlciLoaderUnit.Err message)]
      [(ResultTlciMacroEntry.Ok previous)
        (if (tlci-loader-macro-entry-names-eq? entry previous)
          (ResultTlciLoaderUnit.Err "tlci loader: duplicate macro entry name")
          (tlci-loader-macro-entry-duplicate-before? loaded entry (- index 1)))])))

(define (tlci-loader-validate-macro-entry-at
  [loaded : (& loaded TlciLoadedImage)]
  [index : i64]) : ResultTlciLoaderUnit
  (if (>= index (struct-get loaded macro-entry-count))
    (ResultTlciLoaderUnit.Ok)
    (match (tlci-loader-read-macro-entry loaded index)
      [(ResultTlciMacroEntry.Err message) (ResultTlciLoaderUnit.Err message)]
      [(ResultTlciMacroEntry.Ok entry)
        (match (tlci-loader-macro-entry-duplicate-before? loaded entry index)
          [(ResultTlciLoaderUnit.Err message)
            (ResultTlciLoaderUnit.Err message)]
          [(ResultTlciLoaderUnit.Ok)
            (tlci-loader-validate-macro-entry-at loaded (+ index 1))])])))

(define (tlci-loader-validate-macro-entries
  [loaded : (& loaded TlciLoadedImage)]) : ResultTlciLoaderUnit
  (let
    [count : i64 (struct-get loaded macro-entry-count)]
    [table : i64 (struct-get loaded macro-entry-table)]
    (cond
      [(< count 0)
        (ResultTlciLoaderUnit.Err "tlci loader: macro entry count is invalid")]
      [(= count 0) (ResultTlciLoaderUnit.Ok)]
      [(not (= (% table 8) 0))
        (ResultTlciLoaderUnit.Err
          "tlci loader: macro entry table must be 8-byte aligned")]
      [else (tlci-loader-validate-macro-entry-at loaded 0)])))

(define (tlci-loader-find-macro-entry-at
  [loaded : (& loaded TlciLoadedImage)]
  [name : String]
  [index : i64]
  [found : bool]
  [found-entry : TlciMacroEntry]) : ResultTlciMacroEntry
  (if (>= index (struct-get loaded macro-entry-count))
    (if found
      (ResultTlciMacroEntry.Ok found-entry)
      (ResultTlciMacroEntry.Err "tlci loader: macro entry not found"))
    (match (tlci-loader-read-macro-entry loaded index)
      [(ResultTlciMacroEntry.Err message) (ResultTlciMacroEntry.Err message)]
      [(ResultTlciMacroEntry.Ok entry)
        (if (tlci-loader-mapped-name-eq?
          loaded
          (struct-get entry name-addr)
          (struct-get entry name-len)
          name)
          (if found
            (ResultTlciMacroEntry.Err "tlci loader: duplicate macro entry name")
            (tlci-loader-find-macro-entry-at loaded name (+ index 1) true entry))
          (tlci-loader-find-macro-entry-at
            loaded
            name
            (+ index 1)
            found
            found-entry))])))

(define (tlci-loader-find-macro-entry
  [loaded : (& loaded TlciLoadedImage)]
  [name : String]) : ResultTlciMacroEntry
  (if (= (struct-get loaded macro-entry-count) 0)
    (ResultTlciMacroEntry.Err "tlci loader: image registered no macros")
    (tlci-loader-find-macro-entry-at loaded name 0 false (TlciMacroEntry 0 0 0))))

(define (tlci-loader-dispatch-macro
  [loaded : (& loaded TlciLoadedImage)]
  [name : String]
  [session-context : i64]
  [operands : (Array i64)]
  [initial-result : i64]) : ResultTlciMacroDispatch
  (match (tlci-loader-find-macro-entry loaded name)
    [(ResultTlciMacroEntry.Err message) (ResultTlciMacroDispatch.Err message)]
    [(ResultTlciMacroEntry.Ok entry)
      (let
        [result-storage : (Array i64) (make-array initial-result)]
        [operand-count : i64 (array-length operands)]
        [operands-addr : i64
          (if (= operand-count 0)
            0
            (tlci-loader-i64-array-addr operands))]
        [result-addr : i64 (tlci-loader-i64-array-addr result-storage)]
        [host-context : i64
          (tlci-loader-read-mapped-i64
            (+
              (struct-get loaded host-table-addr)
              tlci.tlci-host-callback-table-host-context-offset))]
        [status : i64
          (unsafe
            (tlci-loader-call-macro-entry-raw
              (struct-get entry function-addr)
              (struct-get loaded image-context)
              host-context
              session-context
              operands-addr
              operand-count
              result-addr))]
        (ResultTlciMacroDispatch.Ok
          (TlciMacroDispatch status (array-ref result-storage 0))))]))

;; Translate native status 2 at the host boundary. The interpreted evaluator
;; uses the same leading message; the registered macro name supplies the native
;; symbol context until general source-span metadata is carried in tlci images.
(define (tlci-loader-macro-status-diagnostic [name : String] [status : i64]) : String
  (if (= status tlci.tlci-host-callback-status-fuel-exhausted)
    (str_cat.str-cat
      (comptime_diagnostics.compiler-comptime-fuel-diagnostic-message)
      (str_cat.str-cat " in macro " name))
    (str_cat.str-cat
      "native comptime macro returned status "
      (string.int->string status))))

;; Proof-only host harness: use the registered probe entry as the callback
;; dispatcher and select its return status through host context. Real compiler
;; callback registration remains owned by the later stdlib/package dispatch
;; slices; the image-side convention exercised here is identical.
(define (tlci-loader-probe-install-self-callback!
  [loaded : (& loaded TlciLoadedImage)]
  [name : String]) : ResultTlciLoaderUnit
  (match (tlci-loader-find-macro-entry loaded name)
    [(ResultTlciMacroEntry.Err message) (ResultTlciLoaderUnit.Err message)]
    [(ResultTlciMacroEntry.Ok entry)
      (begin
        (tlci-loader-write-mapped-i64!
          (+
            (struct-get loaded host-table-addr)
            tlci.tlci-host-callback-table-invoke-offset)
          (struct-get entry function-addr))
        (ResultTlciLoaderUnit.Ok))]))

(define (tlci-loader-probe-set-host-status!
  [loaded : (& loaded TlciLoadedImage)]
  [status : i64]) : unit
  (tlci-loader-write-mapped-i64!
    (+
      (struct-get loaded host-table-addr)
      tlci.tlci-host-callback-table-host-context-offset)
    status))

(define (tlci-loader-test-put-string!
  [bytes : (Array u8)]
  [offset : i64]
  [text : String]) : unit
  (let
    [i : i64 0]
    [n : i64 (tlci.tlci-string-length text)]
    (begin
      (while (< i n)
        (begin
          (array-set!
            bytes
            (+ offset i)
            (cast (tlci.tlci-string-ref text i) : u8))
          (set! i (+ i 1))))
      unit)))

(define (tlci-loader-test-macro-loaded
  [storage : (Array u8)]
  [table : i64]
  [count : i64]) : TlciLoadedImage
  (let
    [base : i64 (tlci-loader-u8-array-addr storage)]
    (TlciLoadedImage
      base
      (array-length storage)
      true
      true
      true
      (+ base 96)
      (make-array i64 0)
      (make-array i64 0)
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
      0)))

(define (tlci-loader-test-write-macro-entry!
  [storage : (Array u8)]
  [offset : i64]
  [name-offset : i64]
  [name-len : i64]
  [function-offset : i64]
  [reserved0 : i64]) : unit
  (let
    [base : i64 (tlci-loader-u8-array-addr storage)]
    [record : i64 (+ base offset)]
    (begin
      (tlci-loader-write-mapped-i64!
        (+ record tlci.tlci-macro-entry-name-ptr-offset)
        (+ base name-offset))
      (tlci-loader-write-mapped-i64!
        (+ record tlci.tlci-macro-entry-name-len-offset)
        name-len)
      (tlci-loader-write-mapped-i64!
        (+ record tlci.tlci-macro-entry-function-offset)
        (+ base function-offset))
      (tlci-loader-write-mapped-i64!
        (+ record tlci.tlci-macro-entry-reserved0-offset)
        reserved0))))

(define (tlci-loader-test-validation-error?
  [result : ResultTlciLoaderUnit]
  [expected : String]) : bool
  (match result
    [(ResultTlciLoaderUnit.Ok) false]
    [(ResultTlciLoaderUnit.Err message) (string.eq message expected)]))

(define (tlci-loader-test-macro-entry-validation-ok?) : bool
  (let
    [storage : (Array u8) (make-array u8 128)]
    [base : i64 (tlci-loader-u8-array-addr storage)]
    (begin
      (tlci-loader-test-put-string! storage 64 "dup")
      (tlci-loader-test-put-string! storage 72 "dup")
      (tlci-loader-test-write-macro-entry! storage 0 64 3 96 0)
      (tlci-loader-test-write-macro-entry! storage 32 72 3 96 0)
      (let
        [duplicate-loaded : TlciLoadedImage
          (tlci-loader-test-macro-loaded storage base 2)]
        [duplicate : bool
          (tlci-loader-test-validation-error?
            (tlci-loader-validate-macro-entries (& duplicate-loaded))
            "tlci loader: duplicate macro entry name")]
        [_distinct-name : unit (tlci-loader-test-put-string! storage 72 "two")]
        [valid-loaded : TlciLoadedImage
          (tlci-loader-test-macro-loaded storage base 2)]
        [valid : bool
          (match (tlci-loader-validate-macro-entries (& valid-loaded))
            [(ResultTlciLoaderUnit.Ok) true]
            [(ResultTlciLoaderUnit.Err _) false])]
        [_reserved : unit
          (tlci-loader-write-mapped-i64!
            (+ base tlci.tlci-macro-entry-reserved0-offset)
            1)]
        [reserved-loaded : TlciLoadedImage
          (tlci-loader-test-macro-loaded storage base 1)]
        [reserved : bool
          (tlci-loader-test-validation-error?
            (tlci-loader-validate-macro-entries (& reserved-loaded))
            "tlci loader: macro entry reserved field must be zero")]
        [unaligned-loaded : TlciLoadedImage
          (tlci-loader-test-macro-loaded storage (+ base 1) 1)]
        [unaligned : bool
          (tlci-loader-test-validation-error?
            (tlci-loader-validate-macro-entries (& unaligned-loaded))
            "tlci loader: macro entry table must be 8-byte aligned")]
        [outside-loaded : TlciLoadedImage
          (tlci-loader-test-macro-loaded storage (+ base 112) 1)]
        [outside : bool
          (tlci-loader-test-validation-error?
            (tlci-loader-validate-macro-entries (& outside-loaded))
            "tlci loader: macro entry table outside mapped image")]
        (and duplicate valid reserved unaligned outside)))))

(define (tlci-loader-test-u64-record [value : i64]) : (Array u8)
  (let
    [out : (Array u8) (make-array u8 tlci.tlci-section-fixup-record-size)]
    (begin
      (tlci.tlci-set-u64! out 0 value)
      out)))

(define (tlci-loader-test-entry-record
  [name-offset : i64]
  [name-len : i64]
  [code-offset : i64]) : (Array u8)
  (let
    [out : (Array u8) (make-array u8 tlci.tlci-section-entry-record-size)]
    (begin
      (tlci.tlci-set-u64! out tlci-loader-entry-name-offset name-offset)
      (tlci.tlci-set-u64! out tlci-loader-entry-name-len-offset name-len)
      (tlci.tlci-set-u64! out tlci-loader-entry-code-offset code-offset)
      out)))

(define (tlci-loader-test-symbol-bytes) : (Array u8)
  (let
    [out : (Array u8) (make-array u8 tlci.tlci-section-symbol-record-size)]
    (begin
      (tlci-loader-test-put-string! out 0 tlci.tlci-image-entry-symbol)
      out)))

(define (tlci-loader-test-set-byte!
  [bytes : (Array u8)]
  [offset : i64]
  [value : i64]) : unit
  (array-set! bytes offset (tlci.tlci-byte value)))

(define (tlci-loader-test-success-code-for-target
  [reg-direct-modrm : i64]
  [reg-disp-modrm : i64]
  [context-modrm : i64]) : (Array u8)
  (let
    [out : (Array u8) (make-array u8 36)]
    (begin
      (tlci-loader-test-set-byte! out 0 0x48)
      (tlci-loader-test-set-byte! out 1 0xb8)
      (tlci.tlci-set-u64! out 2 tlci.tlci-image-registration-magic)
      (tlci-loader-test-set-byte! out 10 0x48)
      (tlci-loader-test-set-byte! out 11 0x89)
      (tlci-loader-test-set-byte! out 12 reg-direct-modrm)
      (tlci-loader-test-set-byte! out 13 0x48)
      (tlci-loader-test-set-byte! out 14 0xc7)
      (tlci-loader-test-set-byte! out 15 reg-disp-modrm)
      (tlci-loader-test-set-byte! out 16 0x08)
      (tlci-loader-test-set-byte! out 17 0x01)
      (tlci-loader-test-set-byte! out 18 0x00)
      (tlci-loader-test-set-byte! out 19 0x00)
      (tlci-loader-test-set-byte! out 20 0x00)
      (tlci-loader-test-set-byte! out 21 0x48)
      (tlci-loader-test-set-byte! out 22 0xc7)
      (tlci-loader-test-set-byte! out 23 reg-disp-modrm)
      (tlci-loader-test-set-byte! out 24 0x10)
      (tlci-loader-test-set-byte! out 25 0x40)
      (tlci-loader-test-set-byte! out 26 0x00)
      (tlci-loader-test-set-byte! out 27 0x00)
      (tlci-loader-test-set-byte! out 28 0x00)
      (tlci-loader-test-set-byte! out 29 0x48)
      (tlci-loader-test-set-byte! out 30 0x89)
      (tlci-loader-test-set-byte! out 31 context-modrm)
      (tlci-loader-test-set-byte! out 32 0x18)
      (tlci-loader-test-set-byte! out 33 0x31)
      (tlci-loader-test-set-byte! out 34 0xc0)
      (tlci-loader-test-set-byte! out 35 0xc3)
      out)))

(define (tlci-loader-test-success-code-bytes) : (Array u8)
  (cfg
    windows
    (tlci-loader-test-success-code-for-target 0x02 0x42 0x4a)
    (tlci-loader-test-success-code-for-target 0x06 0x46 0x7e)))

(define (tlci-loader-test-status-code-bytes [status : i64]) : (Array u8)
  (let
    [out : (Array u8) (make-array u8 6)]
    (begin
      (tlci-loader-test-set-byte! out 0 0xb8)
      (tlci-loader-test-set-byte! out 1 status)
      (tlci-loader-test-set-byte! out 2 0x00)
      (tlci-loader-test-set-byte! out 3 0x00)
      (tlci-loader-test-set-byte! out 4 0x00)
      (tlci-loader-test-set-byte! out 5 0xc3)
      out)))

(define (tlci-loader-test-bad-registration-code-bytes) : (Array u8)
  (let
    [out : (Array u8) (make-array u8 3)]
    (begin
      (tlci-loader-test-set-byte! out 0 0x31)
      (tlci-loader-test-set-byte! out 1 0xc0)
      (tlci-loader-test-set-byte! out 2 0xc3)
      out)))

(define (tlci-loader-test-rodata-bytes) : (Array u8)
  (let
    [out : (Array u8) (make-array u8 8)]
    (begin
      (tlci.tlci-set-u64! out 0 0)
      out)))

(define (tlci-loader-test-image-with-code
  [fixup-offset : i64]
  [code : (Array u8)]) : tlci.TlciImage
  (tlci.tlci-make-image
    tlci.tlci-host-arch-x86-64
    tlci.tlci-callback-abi-version
    "abcdef0"
    (tlci.tlci-test-metadata)
    (tlci-loader-test-rodata-bytes)
    code
    (tlci-loader-test-u64-record fixup-offset)
    (tlci-loader-test-entry-record
      0
      (tlci.tlci-string-length tlci.tlci-image-entry-symbol)
      0)
    (tlci-loader-test-symbol-bytes)))

(define (tlci-loader-test-image [fixup-offset : i64]) : tlci.TlciImage
  (tlci-loader-test-image-with-code
    fixup-offset
    (tlci-loader-test-success-code-bytes)))

(define (tlci-loader-test-emit-with-code [code : (Array u8)]) : tlci.ResultTlciBytes
  (match (tlci.tlci-emit-image (tlci-loader-test-image-with-code 0 code))
    [(tlci.ResultTlciBytes.Err message) (tlci.ResultTlciBytes.Err message)]
    [(tlci.ResultTlciBytes.Ok bytes)
      (let
        [rodata-offset : i64 (tlci.tlci-read-u64 bytes 72)]
        [fixups-offset : i64 (tlci.tlci-read-u64 bytes 104)]
        (begin
          (tlci.tlci-set-u64! bytes fixups-offset rodata-offset)
          (tlci.tlci-set-u64!
            bytes
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
          (tlci.tlci-set-u64! bytes fixups-offset rodata-offset)
          (tlci.tlci-set-u64!
            bytes
            tlci.tlci-hash-field-offset
            (tlci.tlci-content-hash bytes))
          (tlci.ResultTlciBytes.Ok bytes)))]))

(define (tlci-loader-test-loads-and-fixes-up-status) : i64
  (match (tlci-loader-test-emit-with-real-fixup)
    [(tlci.ResultTlciBytes.Err _) 10]
    [(tlci.ResultTlciBytes.Ok bytes)
      (match (tlci-loader-load-from-bytes-with-host
        bytes
        (tlci.tlci-test-host-callback-table))
        [(ResultTlciLoadedImage.Err _) 11]
        [(ResultTlciLoadedImage.Ok loaded)
          (let
            [image-base : i64 (struct-get loaded image-region-addr)]
            [slot : i64
              (tlci-loader-read-mapped-i64 (struct-get loaded rodata-addr))]
            [entry-ok : bool
              (= (struct-get loaded entry-addr) (struct-get loaded code-addr))]
            [counts-ok : bool
              (and
                (= (struct-get loaded fixup-count) 1)
                (= (struct-get loaded entry-count) 1)
                (= (struct-get loaded symbol-count) 1))]
            [registration-ok : bool
              (and
                (> (struct-get loaded host-table-addr) 0)
                (> (struct-get loaded registration-addr) 0)
                (=
                  (struct-get loaded image-context)
                  (struct-get loaded host-table-addr))
                (= (struct-get loaded macro-entry-table) 0)
                (= (struct-get loaded macro-entry-count) 0)
                (=
                  (tlci-loader-read-mapped-i64
                    (struct-get loaded registration-addr))
                  tlci.tlci-image-registration-magic)
                (=
                  (tlci-loader-read-mapped-i64
                    (struct-get loaded host-table-addr))
                  tlci.tlci-host-callback-table-magic))]
            [release-ok : bool
              (match (tlci-loader-release loaded)
                [(ResultTlciLoaderUnit.Ok) true]
                [(ResultTlciLoaderUnit.Err _) false])]
            (cond
              [(not (= slot image-base)) 12]
              [(not entry-ok) 13]
              [(not counts-ok) 14]
              [(not registration-ok) 15]
              [(not release-ok) 16]
              [else 0]))])]))

(define (tlci-loader-test-loads-and-fixes-up?) : bool
  (= (tlci-loader-test-loads-and-fixes-up-status) 0))

(define (tlci-loader-test-rejects?
  [result : ResultTlciLoadedImage]
  [expected : String]) : bool
  (match result
    [(ResultTlciLoadedImage.Err message) (string.eq message expected)]
    [(ResultTlciLoadedImage.Ok loaded)
      (begin
        (tlci-loader-release loaded)
        false)]))

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
              (tlci-loader-load-from-bytes-with-host
                status-bytes
                (tlci.tlci-test-host-callback-table))
              "tlci loader: tlci_image_entry returned status 4")
            (tlci-loader-test-rejects?
              (tlci-loader-load-from-bytes-with-host
                bad-registration-bytes
                (tlci.tlci-test-host-callback-table))
              (str_cat.str-cat
                "tlci loader: invalid image registration: "
                "tlci host ABI: bad image registration magic")))])]))

(define (tlci-loader-test-rejections-ok?) : bool
  (match (tlci-loader-test-emit-with-real-fixup)
    [(tlci.ResultTlciBytes.Err _) false]
    [(tlci.ResultTlciBytes.Ok bytes)
      (let
        [bad-fixup : (Array u8) (tlci.tlci-copy-bytes bytes)]
        [fixups-offset : i64 (tlci.tlci-read-u64 bytes 104)]
        (begin
          (tlci.tlci-set-u64! bad-fixup fixups-offset 8)
          (tlci.tlci-set-u64!
            bad-fixup
            tlci.tlci-hash-field-offset
            (tlci.tlci-content-hash bad-fixup))
          (and
            (tlci-loader-test-rejects?
              (tlci-loader-load-from-bytes (tlci.tlci-slice-bytes bytes 0 20))
              "tlci: truncated header")
            (tlci-loader-test-rejects?
              (tlci-loader-load-from-bytes bad-fixup)
              "tlci loader: fixup offset outside loadable sections: 8")
            (tlci-loader-test-rejects?
              (tlci-loader-load-from-bytes-with-host
                bytes
                (tlci.TlciHostCallbackTable
                  tlci.tlci-host-callback-table-magic
                  (+ tlci.tlci-host-abi-version 1)
                  tlci.tlci-host-callback-table-size
                  0
                  0
                  0
                  1
                  1))
              "tlci host ABI: unsupported callback ABI version 2"))))]))

(define (tlci-loader-self-test-status) : i64
  (let
    [load-status : i64 (tlci-loader-test-loads-and-fixes-up-status)]
    (cond
      [(not (= load-status 0)) load-status]
      [(not (tlci-loader-test-rejections-ok?)) 2]
      [(not (tlci-loader-test-registration-rejections-ok?)) 3]
      [(not (tlci-loader-test-macro-entry-validation-ok?)) 4]
      [else 0])))

(define (tlci-loader-self-test-ok?) : bool
  (= (tlci-loader-self-test-status) 0))

(define (tlci-loader-self-test) : i64
  (if (tlci-loader-self-test-ok?)
    42
    (tlci-loader-self-test-status)))