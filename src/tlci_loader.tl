;; tlci_loader.tl - Dormant tlci comptime image loader core.
;;
;; General package/stdlib macro dispatch lands in later slices. This module
;; owns the loader boundary: parse/validate a tlci image, map it into
;; page-backed host memory, apply load-base fixups while pages are writable,
;; finalize code pages as RX through tlci_pages, and run the image registration
;; entry point through the backend runtime's raw C-ABI bridge, validate its
;; macro table, and invoke registered entries through the six-argument ABI.
(import stdlib.arena)
(import stdlib.string)
(import stdlib.str_cat_runtime as str_cat)
(import compiler_comptime_diagnostics_core as comptime_diagnostics)
(import "tlci_core.tl")
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

;: The retained-storage slots of an image that has not been through
;: registration yet. A process-global empty array, not a per-load allocation:
;: an unregistered image must not hold a reference into the arena that
;: happened to be current when it was mapped, even one nothing dereferences.
;: Registration replaces the slots it actually uses with owner-arena storage.
(define tlci-loader-no-retained-storage : (Array i64)
  (make-array i64 0))

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
        (tlci-read-u64 fixups (* index tlci-section-fixup-record-size))]
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
  [image : TlciImage]
  [rodata-offset : i64]
  [code-offset : i64]) : ResultTlciLoaderUnit
  (tlci-loader-validate-fixups-at
    (struct-get image fixups)
    0
    (/ (array-length (struct-get image fixups)) tlci-section-fixup-record-size)
    rodata-offset
    (array-length (struct-get image rodata))
    code-offset
    (array-length (struct-get image code))))

(define (tlci-loader-validate-imports-at
  [imports : (Array u8)]
  [index : i64]
  [count : i64]
  [rodata-offset : i64]
  [rodata-len : i64]
  [code-offset : i64]
  [code-len : i64]) : ResultTlciLoaderUnit
  (if (>= index count)
    (ResultTlciLoaderUnit.Ok)
    (let
      [record : i64
        (+
          tlci-section-import-header-size
          (* index tlci-section-import-record-size))]
      [slot-offset : i64 (tlci-read-u64 imports record)]
      (if (tlci-loader-fixup-offset-ok?
        slot-offset
        rodata-offset
        rodata-len
        code-offset
        code-len)
        (tlci-loader-validate-imports-at
          imports
          (+ index 1)
          count
          rodata-offset
          rodata-len
          code-offset
          code-len)
        (ResultTlciLoaderUnit.Err
          (str_cat.str-cat
            "tlci loader: import slot outside loadable sections: "
            (string.int->string slot-offset)))))))

(define (tlci-loader-validate-imports
  [image : TlciImage]
  [rodata-offset : i64]
  [code-offset : i64]) : ResultTlciLoaderUnit
  (tlci-loader-validate-imports-at
    (struct-get image imports)
    0
    (tlci-import-section-count (struct-get image imports))
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
        (tlci-byte-at symbols (+ offset index))
        (cast (tlci-string-ref expected index) : i64))
      (tlci-loader-symbol-name-eq-at? symbols offset expected (+ index 1) len))))

(define (tlci-loader-symbol-name-eq?
  [symbols : (Array u8)]
  [offset : i64]
  [len : i64]
  [expected : String]) : bool
  (and
    (= len (tlci-string-length expected))
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
      [record-offset : i64 (* index tlci-section-entry-record-size)]
      [name-offset : i64
        (tlci-read-u64 entries (+ record-offset tlci-loader-entry-name-offset))]
      [name-len : i64
        (tlci-read-u64
          entries
          (+ record-offset tlci-loader-entry-name-len-offset))]
      [code-offset : i64
        (tlci-read-u64 entries (+ record-offset tlci-loader-entry-code-offset))]
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
            tlci-image-entry-symbol)
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

;; A native package image (normal-backend transformers, refs #5213) carries a
;; single entries record named tlci_macro_table whose code offset points at an
;; in-code count word followed by the macro-entry records. Such images have no
;; registration entry: the loader reads the table directly.
(define (tlci-loader-native-table-offset [image : TlciImage]) : i64
  (let
    [entries : (Array u8) (struct-get image entries)]
    [symbols : (Array u8) (struct-get image symbols)]
    [count : i64 (/ (array-length entries) tlci-section-entry-record-size)]
    [index : i64 0]
    [found : i64 -1]
    (begin
      (while (and (< found 0) (< index count))
        (let
          [record-offset : i64 (* index tlci-section-entry-record-size)]
          [name-offset : i64 (tlci-read-u64 entries record-offset)]
          [name-len : i64 (tlci-read-u64 entries (+ record-offset 8))]
          (begin
            (if (and
              (tlci-loader-symbol-range-ok? symbols name-offset name-len)
              (tlci-loader-symbol-name-eq?
                symbols
                name-offset
                name-len
                tlci-macro-table-symbol))
              (set! found (tlci-read-u64 entries (+ record-offset 16)))
              unit)
            (set! index (+ index 1)))))
      found)))

(define (tlci-loader-native-image? [image : TlciImage]) : bool
  (>= (tlci-loader-native-table-offset image) 0))

(define (tlci-loader-find-entry-code-offset [image : TlciImage]) : ResultTlciLoaderI64
  (let
    [code-len : i64 (array-length (struct-get image code))]
    [entry-count : i64
      (/
        (array-length (struct-get image entries))
        tlci-section-entry-record-size)]
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

;; OWNERSHIP RULE FOR RETAINED IMAGE STORAGE.
;;
;; The two i64 arrays a loaded image keeps -- the host callback table and the
;; registration block -- must be allocated in an arena that outlives the IMAGE,
;; never in "whatever arena is current" when the image happens to be loaded.
;; `host-table-addr` and `registration-addr` are RAW addresses into these
;; arrays: the addresses are handed to the image's own code at registration,
;; and `tlci-loader-dispatch-macro` re-reads the host table through
;; `host-table-addr` on EVERY later dispatch. A caller that maps an image while
;; a transient arena is current -- a macro-walk declaration generation, say --
;; and then keeps the image past that arena's destroy dispatches through freed
;; pages. That is exactly what R3-P2d found: the embedded stdlib image is
;; mapped lazily from inside a firing declaration's generation and dispatched
;; from every later declaration.
;;
;; The owner is therefore a required parameter with no default, so a load site
;; cannot inherit an owner by omission; the arity is the enforcement.
(define (tlci-loader-alloc-i64-array-in-arena [owner-arena : i64] [count : i64]) : (Array
    i64)
  (let
    [previous : i64 (arena.tl_arena_current)]
    [_enter : unit
      (unsafe
        (arena.tl_arena_set owner-arena))]
    [items : (Array i64) (make-array i64 count)]
    [_restore : unit
      (unsafe
        (arena.tl_arena_set previous))]
    items))

(define (tlci-loader-host-table-storage
  [owner-arena : i64]
  [table : TlciHostCallbackTable]) : (Array i64)
  (let
    [items : (Array i64) (tlci-loader-alloc-i64-array-in-arena owner-arena 8)]
    (begin
      (array-set! items 0 (struct-get table magic))
      (array-set! items 1 (struct-get table abi-version))
      (array-set! items 2 (struct-get table byte-size))
      (array-set! items 3 (struct-get table host-context))
      (array-set! items 4 (struct-get table reserved0))
      (array-set! items 5 (struct-get table reserved1))
      (array-set! items 6 (struct-get table reserved2))
      (array-set! items 7 (struct-get table abort-callback))
      items)))

(define (tlci-loader-registration-storage [owner-arena : i64]) : (Array i64)
  (tlci-loader-alloc-i64-array-in-arena owner-arena 8))

(define (tlci-loader-read-registration [addr : i64]) : TlciImageRegistration
  (TlciImageRegistration
    (tlci-loader-read-mapped-i64 (+ addr tlci-image-registration-magic-offset))
    (tlci-loader-read-mapped-i64
      (+ addr tlci-image-registration-abi-version-offset))
    (tlci-loader-read-mapped-i64
      (+ addr tlci-image-registration-byte-size-offset))
    (tlci-loader-read-mapped-i64
      (+ addr tlci-image-registration-image-context-offset))
    (tlci-loader-read-mapped-i64
      (+ addr tlci-image-registration-reserved0-offset))
    (tlci-loader-read-mapped-i64
      (+ addr tlci-image-registration-reserved1-offset))
    (tlci-loader-read-mapped-i64
      (+ addr tlci-image-registration-macro-entry-table-offset))
    (tlci-loader-read-mapped-i64
      (+ addr tlci-image-registration-macro-entry-count-offset))))

(define (tlci-loader-apply-fixups-at!
  [image-base : i64]
  [fixups : (Array u8)]
  [index : i64]
  [count : i64]) : unit
  (if (>= index count)
    unit
    (let
      [slot-offset : i64
        (tlci-read-u64 fixups (* index tlci-section-fixup-record-size))]
      [slot-addr : i64 (+ image-base slot-offset)]
      [current : i64 (tlci-loader-read-mapped-i64 slot-addr)]
      (begin
        (tlci-loader-write-mapped-i64! slot-addr (+ current image-base))
        (tlci-loader-apply-fixups-at! image-base fixups (+ index 1) count)))))

(define (tlci-loader-apply-fixups! [image-base : i64] [image : TlciImage]) : unit
  (tlci-loader-apply-fixups-at!
    image-base
    (struct-get image fixups)
    0
    (/ (array-length (struct-get image fixups)) tlci-section-fixup-record-size)))

;; Resolve one image import against the compiler's static host registry. The
;; registry is validated before mapping, so a found address is always nonzero.
(define (tlci-loader-host-import-address
  [host-table : (& host-table TlciHostCallbackTable)]
  [name : String]) : ResultTlciLoaderI64
  (let
    [index : i64 0]
    [count : i64 (struct-get host-table import-count)]
    [found : i64 -1]
    (begin
      (while (and (< found 0) (< index count))
        (if (string.eq
          (array-ref (struct-get host-table import-names) index)
          name)
          (set! found index)
          (set! index (+ index 1))))
      (if (< found 0)
        (ResultTlciLoaderI64.Err name)
        (ResultTlciLoaderI64.Ok
          (array-ref (struct-get host-table import-callbacks) found))))))

;; Bind each image import name to a raw host callback address, writing the GOT
;; slot while the image is still writable and before any comptime code runs.
(define (tlci-loader-bind-imports-at!
  [image-base : i64]
  [imports : (Array u8)]
  [image-identity : String]
  [host-table : (& host-table TlciHostCallbackTable)]
  [index : i64]
  [count : i64]) : ResultTlciLoaderUnit
  (if (>= index count)
    (ResultTlciLoaderUnit.Ok)
    (let
      [record : i64
        (+
          tlci-section-import-header-size
          (* index tlci-section-import-record-size))]
      [slot-offset : i64 (tlci-read-u64 imports record)]
      [name-offset : i64 (tlci-read-u64 imports (+ record 8))]
      [name-len : i64 (tlci-read-u64 imports (+ record 16))]
      [name : String (tlci-bytes->string imports name-offset name-len)]
      (match (tlci-loader-host-import-address host-table name)
        [(ResultTlciLoaderI64.Err missing)
          (ResultTlciLoaderUnit.Err
            (str_cat.str-cat
              "tlci loader: image `"
              (str_cat.str-cat
                image-identity
                (str_cat.str-cat
                  "` has unresolved host import `"
                  (str_cat.str-cat missing "`")))))]
        [(ResultTlciLoaderI64.Ok address)
          (begin
            (tlci-loader-write-mapped-i64! (+ image-base slot-offset) address)
            (tlci-loader-bind-imports-at!
              image-base
              imports
              image-identity
              host-table
              (+ index 1)
              count))]))))

(define (tlci-loader-bind-imports!
  [image-base : i64]
  [image : TlciImage]
  [host-table : (& host-table TlciHostCallbackTable)]) : ResultTlciLoaderUnit
  (tlci-loader-bind-imports-at!
    image-base
    (struct-get image imports)
    (str_cat.str-cat
      (struct-get (struct-get image metadata) package-name)
      (str_cat.str-cat
        "@"
        (struct-get (struct-get image metadata) package-version)))
    host-table
    0
    (tlci-import-section-count (struct-get image imports))))

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
    tlci-loader-no-retained-storage
    tlci-loader-no-retained-storage
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
  [registration : TlciImageRegistration]) : TlciLoadedImage
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

;; Install the code-resident macro table of a native package image: the count
;; word sits at table-offset in the code section, records follow it, and every
;; name/function slot was rebased by the fixup pass. Validation reuses the
;; same macro-entry checks the registration path applies.
(define (tlci-loader-install-native-table
  [owner-arena : i64]
  [bytes : (Array u8)]
  [loaded : TlciLoadedImage]
  [host-table : TlciHostCallbackTable]
  [table-offset : i64]) : ResultTlciLoadedImage
  (let
    [code-file-offset : i64 (tlci-read-u64 bytes 88)]
    [count-addr : i64
      (+
        (struct-get loaded image-region-addr)
        (+ code-file-offset table-offset))]
    [macro-count : i64 (tlci-loader-read-mapped-i64 count-addr)]
    [host-storage : (Array i64)
      (tlci-loader-host-table-storage owner-arena host-table)]
    [host-table-addr : i64 (tlci-loader-i64-array-addr host-storage)]
    [installed : TlciLoadedImage
      (TlciLoadedImage
        (struct-get loaded image-region-addr)
        (struct-get loaded image-region-size)
        (struct-get loaded image-region-code)
        (struct-get loaded image-region-writable)
        (struct-get loaded image-region-executable)
        (struct-get loaded entry-addr)
        host-storage
        (struct-get loaded registration-storage)
        host-table-addr
        (struct-get loaded registration-addr)
        0
        (+ count-addr 8)
        macro-count
        (struct-get loaded rodata-addr)
        (struct-get loaded rodata-len)
        (struct-get loaded code-addr)
        (struct-get loaded code-len)
        (struct-get loaded fixup-count)
        (struct-get loaded entry-count)
        (struct-get loaded symbol-count))]
    (match (tlci-loader-validate-macro-entries (& installed))
      [(ResultTlciLoaderUnit.Err message)
        (begin
          (tlci-loader-release installed)
          (ResultTlciLoadedImage.Err message))]
      [(ResultTlciLoaderUnit.Ok) (ResultTlciLoadedImage.Ok installed)])))

(define (tlci-loader-load-from-bytes-with-registration
  [owner-arena : i64]
  [bytes : (Array u8)]
  [host-table : TlciHostCallbackTable]) : ResultTlciLoadedImage
  (match (tlci-parse-image bytes)
    [(ResultTlciImage.Err message) (ResultTlciLoadedImage.Err message)]
    [(ResultTlciImage.Ok parsed)
      (let
        [native-table : i64 (tlci-loader-native-table-offset parsed)]
        (match (tlci-loader-load-parsed bytes parsed (& host-table))
          [(ResultTlciLoadedImage.Err message)
            (ResultTlciLoadedImage.Err message)]
          [(ResultTlciLoadedImage.Ok loaded)
            (if (>= native-table 0)
              (tlci-loader-install-native-table
                owner-arena
                bytes
                loaded
                host-table
                native-table)
              (tlci-loader-finish-registration owner-arena loaded host-table))]))]))

(define (tlci-loader-finish-registration
  [owner-arena : i64]
  [loaded : TlciLoadedImage]
  [host-table : TlciHostCallbackTable]) : ResultTlciLoadedImage
  (match (ResultTlciLoadedImage.Ok loaded)
    [(ResultTlciLoadedImage.Err message) (ResultTlciLoadedImage.Err message)]
    [(ResultTlciLoadedImage.Ok loaded)
      (let
        [host-storage : (Array i64)
          (tlci-loader-host-table-storage owner-arena host-table)]
        [registration-storage : (Array i64)
          (tlci-loader-registration-storage owner-arena)]
        [host-table-addr : i64 (tlci-loader-i64-array-addr host-storage)]
        [registration-addr : i64
          (tlci-loader-i64-array-addr registration-storage)]
        [status : i64
          (unsafe
            (tlci-loader-call-image-entry-raw
              (struct-get loaded entry-addr)
              host-table-addr
              registration-addr))]
        (if (not (= status tlci-image-entry-success))
          (begin
            (tlci-loader-release loaded)
            (ResultTlciLoadedImage.Err
              (tlci-loader-registration-status-error status)))
          (let
            [registration : TlciImageRegistration
              (tlci-loader-read-registration registration-addr)]
            (match (tlci-validate-image-registration registration)
              [(ResultTlciHostAbi.Err message)
                (begin
                  (tlci-loader-release loaded)
                  (ResultTlciLoadedImage.Err
                    (tlci-loader-registration-error message)))]
              [(ResultTlciHostAbi.Ok)
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
  [image : TlciImage]
  [image-region : pages.TlciPageRegion]
  [entry-code-offset : i64]
  [rodata-offset : i64]
  [code-offset : i64]
  [host-table : (& host-table TlciHostCallbackTable)]) : ResultTlciLoadedImage
  (let
    [image-base : i64 (struct-get image-region addr)]
    [rodata-len : i64 (array-length (struct-get image rodata))]
    [code-len : i64 (array-length (struct-get image code))]
    [fixup-count : i64
      (/
        (array-length (struct-get image fixups))
        tlci-section-fixup-record-size)]
    [entry-count : i64
      (/
        (array-length (struct-get image entries))
        tlci-section-entry-record-size)]
    [symbol-count : i64
      (/
        (array-length (struct-get image symbols))
        tlci-section-symbol-record-size)]
    (begin
      (match (pages.tlci-pages-copy-from-array! image-region bytes)
        [(pages.ResultTlciPageUnit.Err message)
          (begin
            (pages.tlci-pages-release image-region)
            (return (ResultTlciLoadedImage.Err message)))]
        [(pages.ResultTlciPageUnit.Ok) unit])
      (tlci-loader-apply-fixups! image-base image)
      (match (tlci-loader-bind-imports! image-base image host-table)
        [(ResultTlciLoaderUnit.Err message)
          (begin
            (pages.tlci-pages-release image-region)
            (return (ResultTlciLoadedImage.Err message)))]
        [(ResultTlciLoaderUnit.Ok) unit])
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

(define (tlci-loader-load-parsed
  [bytes : (Array u8)]
  [image : TlciImage]
  [host-table : (& host-table TlciHostCallbackTable)]) : ResultTlciLoadedImage
  (let
    [rodata-offset : i64 (tlci-read-u64 bytes 72)]
    [code-offset : i64 (tlci-read-u64 bytes 88)]
    [code-len : i64 (array-length (struct-get image code))]
    (if (= code-len 0)
      (ResultTlciLoadedImage.Err "tlci loader: image has no code section")
      (match (if (tlci-loader-native-image? image)
        (ResultTlciLoaderI64.Ok 0)
        (tlci-loader-find-entry-code-offset image))
        [(ResultTlciLoaderI64.Err message) (ResultTlciLoadedImage.Err message)]
        [(ResultTlciLoaderI64.Ok entry-code-offset)
          (match (tlci-loader-validate-fixups image rodata-offset code-offset)
            [(ResultTlciLoaderUnit.Err message)
              (ResultTlciLoadedImage.Err message)]
            [(ResultTlciLoaderUnit.Ok)
              (match (tlci-loader-validate-imports
                image
                rodata-offset
                code-offset)
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
                        code-offset
                        host-table)])])])]))))

(define (tlci-loader-empty-host-table) : TlciHostCallbackTable
  (TlciHostCallbackTable
    tlci-host-callback-table-magic
    tlci-host-abi-version
    tlci-host-callback-table-size
    0
    0
    0
    0
    1
    (array.make-array String 0)
    (array.make-array i64 0)
    0))

(define (tlci-loader-load-from-bytes [bytes : (Array u8)]) : ResultTlciLoadedImage
  (match (tlci-parse-image bytes)
    [(ResultTlciImage.Err message) (ResultTlciLoadedImage.Err message)]
    [(ResultTlciImage.Ok image)
      (let
        [host-table : TlciHostCallbackTable (tlci-loader-empty-host-table)]
        (tlci-loader-load-parsed bytes image (& host-table)))]))

;: `owner-arena` owns the storage the returned image RETAINS, and must outlive
;: every dispatch on it -- see the ownership rule above
;: `tlci-loader-host-table-storage`. It is deliberately explicit: an image that
;: is released before the caller's current arena can pass
;: `(arena.tl_arena_current)`, and one that is kept past it must not.
(define (tlci-loader-load-from-bytes-with-host
  [owner-arena : i64]
  [bytes : (Array u8)]
  [host-table : TlciHostCallbackTable]) : ResultTlciLoadedImage
  (match (tlci-validate-host-callback-table host-table)
    [(ResultTlciHostAbi.Err message) (ResultTlciLoadedImage.Err message)]
    [(ResultTlciHostAbi.Ok)
      (tlci-loader-load-from-bytes-with-registration
        owner-arena
        bytes
        host-table)]))

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
        (cast (tlci-string-ref expected index) : i64))
      (tlci-loader-mapped-name-eq-at? addr expected (+ index 1) len))))

(define (tlci-loader-mapped-name-eq?
  [loaded : (& loaded TlciLoadedImage)]
  [addr : i64]
  [len : i64]
  [expected : String]) : bool
  (and
    (= len (tlci-string-length expected))
    (tlci-loader-image-range-contained? loaded addr len)
    (tlci-loader-mapped-name-eq-at? addr expected 0 len)))

(define (tlci-loader-read-macro-entry
  [loaded : (& loaded TlciLoadedImage)]
  [index : i64]) : ResultTlciMacroEntry
  (let
    [count : i64 (struct-get loaded macro-entry-count)]
    [table : i64 (struct-get loaded macro-entry-table)]
    [record-size : i64 tlci-macro-entry-record-size]
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
              (+ record tlci-macro-entry-name-ptr-offset))]
          [name-len : i64
            (tlci-loader-read-mapped-i64
              (+ record tlci-macro-entry-name-len-offset))]
          [function-addr : i64
            (tlci-loader-read-mapped-i64
              (+ record tlci-macro-entry-function-offset))]
          [reserved0 : i64
            (tlci-loader-read-mapped-i64
              (+ record tlci-macro-entry-reserved0-offset))]
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
              tlci-host-callback-table-host-context-offset))]
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
  (if (= status tlci-host-callback-status-fuel-exhausted)
    (str_cat.str-cat
      (comptime_diagnostics.compiler-comptime-fuel-diagnostic-message)
      (str_cat.str-cat " in macro " name))
    (str_cat.str-cat
      "native comptime macro returned status "
      (str_cat.str-cat
        (string.int->string status)
        (str_cat.str-cat " for " name)))))

(define (tlci-loader-test-put-string!
  [bytes : (Array u8)]
  [offset : i64]
  [text : String]) : unit
  (let
    [i : i64 0]
    [n : i64 (tlci-string-length text)]
    (begin
      (while (< i n)
        (begin
          (array-set! bytes (+ offset i) (cast (tlci-string-ref text i) : u8))
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
        (+ record tlci-macro-entry-name-ptr-offset)
        (+ base name-offset))
      (tlci-loader-write-mapped-i64!
        (+ record tlci-macro-entry-name-len-offset)
        name-len)
      (tlci-loader-write-mapped-i64!
        (+ record tlci-macro-entry-function-offset)
        (+ base function-offset))
      (tlci-loader-write-mapped-i64!
        (+ record tlci-macro-entry-reserved0-offset)
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
            (+ base tlci-macro-entry-reserved0-offset)
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
    [out : (Array u8) (make-array u8 tlci-section-fixup-record-size)]
    (begin
      (tlci-set-u64! out 0 value)
      out)))

(define (tlci-loader-test-entry-record
  [name-offset : i64]
  [name-len : i64]
  [code-offset : i64]) : (Array u8)
  (let
    [out : (Array u8) (make-array u8 tlci-section-entry-record-size)]
    (begin
      (tlci-set-u64! out tlci-loader-entry-name-offset name-offset)
      (tlci-set-u64! out tlci-loader-entry-name-len-offset name-len)
      (tlci-set-u64! out tlci-loader-entry-code-offset code-offset)
      out)))

(define (tlci-loader-test-symbol-bytes) : (Array u8)
  (let
    [out : (Array u8) (make-array u8 tlci-section-symbol-record-size)]
    (begin
      (tlci-loader-test-put-string! out 0 tlci-image-entry-symbol)
      out)))

(define (tlci-loader-test-set-byte!
  [bytes : (Array u8)]
  [offset : i64]
  [value : i64]) : unit
  (array-set! bytes offset (tlci-byte value)))

(define (tlci-loader-test-success-code-for-target
  [reg-direct-modrm : i64]
  [reg-disp-modrm : i64]
  [context-modrm : i64]) : (Array u8)
  (let
    [out : (Array u8) (make-array u8 36)]
    (begin
      (tlci-loader-test-set-byte! out 0 0x48)
      (tlci-loader-test-set-byte! out 1 0xb8)
      (tlci-set-u64! out 2 tlci-image-registration-magic)
      (tlci-loader-test-set-byte! out 10 0x48)
      (tlci-loader-test-set-byte! out 11 0x89)
      (tlci-loader-test-set-byte! out 12 reg-direct-modrm)
      (tlci-loader-test-set-byte! out 13 0x48)
      (tlci-loader-test-set-byte! out 14 0xc7)
      (tlci-loader-test-set-byte! out 15 reg-disp-modrm)
      (tlci-loader-test-set-byte! out 16 0x08)
      (tlci-loader-test-set-byte! out 17 tlci-host-abi-version)
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
      (tlci-set-u64! out 0 0)
      out)))

(define (tlci-loader-test-image-with-code-and-imports
  [fixup-offset : i64]
  [code : (Array u8)]
  [imports : (Array u8)]) : TlciImage
  (tlci-make-image
    tlci-host-arch-x86-64
    tlci-callback-abi-version
    "abcdef0"
    (tlci-test-metadata)
    (tlci-loader-test-rodata-bytes)
    code
    (tlci-loader-test-u64-record fixup-offset)
    (tlci-loader-test-entry-record
      0
      (tlci-string-length tlci-image-entry-symbol)
      0)
    (tlci-loader-test-symbol-bytes)
    imports))

(define (tlci-loader-test-image-with-code
  [fixup-offset : i64]
  [code : (Array u8)]) : TlciImage
  (tlci-loader-test-image-with-code-and-imports
    fixup-offset
    code
    (tlci-empty-bytes)))

(define (tlci-loader-test-image [fixup-offset : i64]) : TlciImage
  (tlci-loader-test-image-with-code
    fixup-offset
    (tlci-loader-test-success-code-bytes)))

(define (tlci-loader-test-emit-with-code [code : (Array u8)]) : ResultTlciBytes
  (match (tlci-emit-image (tlci-loader-test-image-with-code 0 code))
    [(ResultTlciBytes.Err message) (ResultTlciBytes.Err message)]
    [(ResultTlciBytes.Ok bytes)
      (let
        [rodata-offset : i64 (tlci-read-u64 bytes 72)]
        [fixups-offset : i64 (tlci-read-u64 bytes 104)]
        (begin
          (tlci-set-u64! bytes fixups-offset rodata-offset)
          (tlci-set-u64! bytes tlci-hash-field-offset (tlci-content-hash bytes))
          (ResultTlciBytes.Ok bytes)))]))

(define (tlci-loader-test-emit-with-real-fixup) : ResultTlciBytes
  (match (tlci-emit-image (tlci-loader-test-image 0))
    [(ResultTlciBytes.Err message) (ResultTlciBytes.Err message)]
    [(ResultTlciBytes.Ok bytes)
      (let
        [rodata-offset : i64 (tlci-read-u64 bytes 72)]
        [fixups-offset : i64 (tlci-read-u64 bytes 104)]
        (begin
          (tlci-set-u64! bytes fixups-offset rodata-offset)
          (tlci-set-u64! bytes tlci-hash-field-offset (tlci-content-hash bytes))
          (ResultTlciBytes.Ok bytes)))]))

(define (tlci-loader-test-imports [name : String]) : (Array u8)
  (let
    [name-len : i64 (tlci-string-length name)]
    [name-offset : i64
      (+ tlci-section-import-header-size tlci-section-import-record-size)]
    [out : (Array u8) (make-array u8 (+ name-offset name-len))]
    (begin
      (tlci-set-u64! out 0 1)
      (tlci-set-u64! out tlci-section-import-header-size 0)
      (tlci-set-u64! out (+ tlci-section-import-header-size 8) name-offset)
      (tlci-set-u64! out (+ tlci-section-import-header-size 16) name-len)
      (tlci-loader-test-put-string! out name-offset name)
      out)))

(define (tlci-loader-test-host-table [name : String] [address : i64]) : TlciHostCallbackTable
  (TlciHostCallbackTable
    tlci-host-callback-table-magic
    tlci-host-abi-version
    tlci-host-callback-table-size
    0
    0
    0
    0
    1
    (make-array name)
    (make-array address)
    1))

(define (tlci-loader-test-emit-with-import [name : String]) : ResultTlciBytes
  (match (tlci-emit-image
    (tlci-loader-test-image-with-code-and-imports
      0
      (tlci-loader-test-success-code-bytes)
      (tlci-loader-test-imports name)))
    [(ResultTlciBytes.Err message) (ResultTlciBytes.Err message)]
    [(ResultTlciBytes.Ok bytes)
      (let
        [rodata-offset : i64 (tlci-read-u64 bytes 72)]
        [fixups-offset : i64 (tlci-read-u64 bytes 104)]
        [imports-offset : i64 (tlci-read-u64 bytes 152)]
        (begin
          (tlci-set-u64! bytes fixups-offset rodata-offset)
          (tlci-set-u64!
            bytes
            (+ imports-offset tlci-section-import-header-size)
            rodata-offset)
          (tlci-set-u64! bytes tlci-hash-field-offset (tlci-content-hash bytes))
          (ResultTlciBytes.Ok bytes)))]))

;: Owner arena for the loader's own self-test loads. Every one of them either
;: rejects the image or releases it before returning, so the arena that is
;: current at the load already outlives the image. Named once here so the seven
;: call sites below still have to state an owner without repeating the reason.
(define (tlci-loader-test-owner-arena) : i64
  (arena.tl_arena_current))

(define (tlci-loader-test-named-imports-status) : i64
  (match (tlci-loader-test-emit-with-import "fuel-check")
    [(ResultTlciBytes.Err _) 1]
    [(ResultTlciBytes.Ok bytes)
      (let
        [bound : bool
          (match (tlci-loader-load-from-bytes-with-host
            (tlci-loader-test-owner-arena)
            bytes
            (tlci-loader-test-host-table "fuel-check" 4096))
            [(ResultTlciLoadedImage.Err _) false]
            [(ResultTlciLoadedImage.Ok loaded)
              (let
                [ok : bool
                  (=
                    (tlci-loader-read-mapped-i64
                      (struct-get loaded rodata-addr))
                    4096)]
                (match (tlci-loader-release loaded)
                  [(ResultTlciLoaderUnit.Ok) ok]
                  [(ResultTlciLoaderUnit.Err _) false]))])]
        [missing : bool
          (tlci-loader-test-rejects?
            (tlci-loader-load-from-bytes-with-host
              (tlci-loader-test-owner-arena)
              bytes
              (tlci-loader-test-host-table "other" 8192))
            "tlci loader: image `demo@0.1.0` has unresolved host import `fuel-check`")]
        [bad-slot-bytes : (Array u8) (tlci-copy-bytes bytes)]
        [imports-offset : i64 (tlci-read-u64 bad-slot-bytes 152)]
        [_bad-slot : unit
          (begin
            (tlci-set-u64!
              bad-slot-bytes
              (+ imports-offset tlci-section-import-header-size)
              8)
            (tlci-set-u64!
              bad-slot-bytes
              tlci-hash-field-offset
              (tlci-content-hash bad-slot-bytes)))]
        [bad-slot : bool
          (tlci-loader-test-rejects?
            (tlci-loader-load-from-bytes-with-host
              (tlci-loader-test-owner-arena)
              bad-slot-bytes
              (tlci-loader-test-host-table "fuel-check" 4096))
            "tlci loader: import slot outside loadable sections: 8")]
        (cond [(not bound) 2] [(not missing) 3] [(not bad-slot) 4] [else 0]))]))

(define (tlci-loader-test-loads-and-fixes-up-status) : i64
  (match (tlci-loader-test-emit-with-real-fixup)
    [(ResultTlciBytes.Err _) 10]
    [(ResultTlciBytes.Ok bytes)
      (match (tlci-loader-load-from-bytes-with-host
        (tlci-loader-test-owner-arena)
        bytes
        (tlci-test-host-callback-table))
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
                  tlci-image-registration-magic)
                (=
                  (tlci-loader-read-mapped-i64
                    (struct-get loaded host-table-addr))
                  tlci-host-callback-table-magic))]
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
    (tlci-loader-test-status-code-bytes tlci-host-callback-status-bad-request))
    [(ResultTlciBytes.Err _) false]
    [(ResultTlciBytes.Ok status-bytes)
      (match (tlci-loader-test-emit-with-code
        (tlci-loader-test-bad-registration-code-bytes))
        [(ResultTlciBytes.Err _) false]
        [(ResultTlciBytes.Ok bad-registration-bytes)
          (and
            (tlci-loader-test-rejects?
              (tlci-loader-load-from-bytes-with-host
                (tlci-loader-test-owner-arena)
                status-bytes
                (tlci-test-host-callback-table))
              "tlci loader: tlci_image_entry returned status 4")
            (tlci-loader-test-rejects?
              (tlci-loader-load-from-bytes-with-host
                (tlci-loader-test-owner-arena)
                bad-registration-bytes
                (tlci-test-host-callback-table))
              (str_cat.str-cat
                "tlci loader: invalid image registration: "
                "tlci host ABI: bad image registration magic")))])]))

(define (tlci-loader-test-rejections-ok?) : bool
  (match (tlci-loader-test-emit-with-real-fixup)
    [(ResultTlciBytes.Err _) false]
    [(ResultTlciBytes.Ok bytes)
      (let
        [bad-fixup : (Array u8) (tlci-copy-bytes bytes)]
        [fixups-offset : i64 (tlci-read-u64 bytes 104)]
        (begin
          (tlci-set-u64! bad-fixup fixups-offset 8)
          (tlci-set-u64!
            bad-fixup
            tlci-hash-field-offset
            (tlci-content-hash bad-fixup))
          (and
            (tlci-loader-test-rejects?
              (tlci-loader-load-from-bytes (tlci-slice-bytes bytes 0 20))
              "tlci: truncated header")
            (tlci-loader-test-rejects?
              (tlci-loader-load-from-bytes bad-fixup)
              "tlci loader: fixup offset outside loadable sections: 8")
            (tlci-loader-test-rejects?
              (tlci-loader-load-from-bytes-with-host
                (tlci-loader-test-owner-arena)
                bytes
                (TlciHostCallbackTable
                  tlci-host-callback-table-magic
                  (+ tlci-host-abi-version 1)
                  tlci-host-callback-table-size
                  0
                  0
                  0
                  1
                  1
                  (array.make-array String 0)
                  (array.make-array i64 0)
                  0))
              "tlci host ABI: unsupported callback ABI version 3"))))]))

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
    [(ResultTlciBytes.Err _) 70]
    [(ResultTlciBytes.Ok bytes)
      (let
        [owner : i64 (arena.tl_arena_current)]
        [transient : i64 (arena.tl_arena_make)]
        [_enter : unit
          (unsafe
            (arena.tl_arena_set transient))]
        [loaded-result : ResultTlciLoadedImage
          (tlci-loader-load-from-bytes-with-host
            owner
            bytes
            (tlci-test-host-callback-table))]
        [_leave : unit
          (unsafe
            (arena.tl_arena_set owner))]
        [_drop : unit
          (unsafe
            (arena.tl_arena_destroy transient))]
        (match loaded-result
          [(ResultTlciLoadedImage.Err _) 71]
          [(ResultTlciLoadedImage.Ok loaded)
            (let
              ;; The dispatch-path read, after the load arena is gone.
              [host-magic : i64
                (tlci-loader-read-mapped-i64
                  (struct-get loaded host-table-addr))]
              [host-context : i64
                (tlci-loader-read-mapped-i64
                  (+
                    (struct-get loaded host-table-addr)
                    tlci-host-callback-table-host-context-offset))]
              [registration-magic : i64
                (tlci-loader-read-mapped-i64
                  (struct-get loaded registration-addr))]
              [released : bool
                (match (tlci-loader-release loaded)
                  [(ResultTlciLoaderUnit.Ok) true]
                  [(ResultTlciLoaderUnit.Err _) false])]
              (cond
                [(not (= host-magic tlci-host-callback-table-magic)) 72]
                [(not (= host-context 1234)) 73]
                [(not (= registration-magic tlci-image-registration-magic)) 74]
                [(not released) 75]
                [else 0]))]))]))

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
      [(not (= (tlci-loader-test-named-imports-status) 0))
        (+ 50 (tlci-loader-test-named-imports-status))]
      [else 0])))

(define (tlci-loader-self-test-ok?) : bool
  (= (tlci-loader-self-test-status) 0))

(define (tlci-loader-self-test) : i64
  (if (tlci-loader-self-test-ok?)
    42
    (tlci-loader-self-test-status)))