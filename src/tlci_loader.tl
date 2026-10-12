;; tlci_loader.tl - tlci comptime image loader core.
;;
;; This module owns the loader boundary: parse/validate a tlci image, map it into
;; page-backed host memory, apply load-base fixups while pages are writable,
;; finalize code pages as RX through tlci_pages, and run the image registration
;; entry point through the backend runtime's raw C-ABI bridge, validate its
;; macro table, and invoke registered entries through the six-argument ABI.
(import stdlib.iterator)
(import compiler_owned_view as owned_view)
(import stdlib.arena)
(import stdlib.string)
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.hash)
(import compiler_comptime_diagnostics_core as comptime_diagnostics)
(import tlci_core as tlci)
(import tlci_pages as pages)

(defmacro (tlci-loader-global-shared-view [place : Expr]) : Expr
  `(unsafe
    (ptr-read (ptr-addr-of ,place))))

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
  (host-table-storage (__tl_dyn-array i64))
  (registration-storage (__tl_dyn-array i64))
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
  (symbol-count i64)
  ;; The macro catalog index and its entry state are owned by this loaded
  ;; mapping. Cached handles carry the generation below, so they cannot be
  ;; dispatched through a later remap or another package catalog.
  (macro-index-generation i64)
  (macro-index-slots (__tl_dyn-array i64))
  (macro-index-name-addrs (__tl_dyn-array i64))
  (macro-index-name-lens (__tl_dyn-array i64))
  (macro-index-function-addrs (__tl_dyn-array i64))
  ;; 0 = resolved native entry, 1 = terminal registration shell.
  (macro-index-entry-states (__tl_dyn-array i64))
  ;; Dedicated owner destroyed with the mapping; zero means no index storage.
  (macro-index-arena i64)
  ;; One shared owner-arena cell revokes all copied views before either release
  ;; or rollback touches the mapping. A failed unmap is not a live image.
  (live (__tl_dyn-array bool)))

(defenum ResultTlciLoadedImage
  (Ok TlciLoadedImage)
  (Err String))

(defenum ResultTlciLoaderUnit
  (Ok)
  (Err String))

(defenum ResultTlciLoaderI64
  (Ok i64)
  (Err String))

(cfg
  test
  (define tlci-loader-test-fail-index-before-alloc : bool
    false))
(cfg
  test
  (define tlci-loader-test-fail-index-after-alloc : bool
    false))
(cfg
  test
  (define tlci-loader-test-index-arena-destroys : i64
    0))

;; Fault-injection hooks for tlci_loader_tests. Only this module may write its
;; globals, so the tests go through these setters.
(cfg
  test
  (define (tlci-loader-test-hooks-set!
    [fail-before-alloc : bool]
    [fail-after-alloc : bool]) : unit
    (set! tlci-loader-test-fail-index-before-alloc fail-before-alloc)
    (set! tlci-loader-test-fail-index-after-alloc fail-after-alloc)))

(cfg
  test
  (define (tlci-loader-test-index-arena-destroys-reset!) : unit
    (set! tlci-loader-test-index-arena-destroys 0)))

(define (tlci-loader-destroy-index-arena [index-arena : i64]) : unit
  (if (> index-arena 0)
    (begin
      (cfg test (+= tlci-loader-test-index-arena-destroys 1) unit)
      (unsafe
        (arena.tl_arena_destroy index-arena)))
    unit))

(defstruct TlciMacroEntry
  (name-addr i64)
  (name-len i64)
  (function-addr i64))

(defenum ResultTlciMacroEntry
  (Ok TlciMacroEntry)
  (Err String))

(defstruct TlciResolvedMacroEntry
  (catalog-generation i64)
  (entry-index i64))

(defenum TlciMacroEntryLookup
  (Resolved TlciResolvedMacroEntry)
  (Shell TlciResolvedMacroEntry)
  (Missing)
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
(define tlci-loader-no-retained-storage : (__tl_dyn-array i64)
  (__tl_make-array i64 0))

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
  [fixups : (& fixups (__tl_dyn-array u8))]
  [count : i64]
  [rodata-offset : i64]
  [rodata-len : i64]
  [code-offset : i64]
  [code-len : i64]) : ResultTlciLoaderUnit
  (for [index (iterator.range 0 count)]
    (let
      [slot-offset : i64
        (tlci.tlci-read-u64
          fixups
          (* index tlci.tlci-section-fixup-record-size))]
      (unless
        (tlci-loader-fixup-offset-ok?
          slot-offset
          rodata-offset
          rodata-len
          code-offset
          code-len)
        (return
          (Err
            (str_cat.str-cat
              "tlci loader: fixup offset outside loadable sections: "
              (string.int->string slot-offset)))))))
  (Ok))

(define (tlci-loader-validate-fixups
  [image : (& image tlci.TlciImage)]
  [rodata-offset : i64]
  [code-offset : i64]) : ResultTlciLoaderUnit
  (tlci-loader-validate-fixups-at
    image.fixups
    (/ (array-length image.fixups) tlci.tlci-section-fixup-record-size)
    rodata-offset
    (array-length image.rodata)
    code-offset
    (array-length image.code)))

(define (tlci-loader-validate-imports-at
  [imports : (& imports (__tl_dyn-array u8))]
  [count : i64]
  [rodata-offset : i64]
  [rodata-len : i64]
  [code-offset : i64]
  [code-len : i64]) : ResultTlciLoaderUnit
  (for [index (iterator.range 0 count)]
    (let
      [record : i64
        (+
          tlci.tlci-section-import-header-size
          (* index tlci.tlci-section-import-record-size))]
      [slot-offset : i64 (tlci.tlci-read-u64 imports record)]
      (unless
        (tlci-loader-fixup-offset-ok?
          slot-offset
          rodata-offset
          rodata-len
          code-offset
          code-len)
        (return
          (Err
            (str_cat.str-cat
              "tlci loader: import slot outside loadable sections: "
              (string.int->string slot-offset)))))))
  (Ok))

(define (tlci-loader-validate-imports
  [image : (& image tlci.TlciImage)]
  [rodata-offset : i64]
  [code-offset : i64]) : ResultTlciLoaderUnit
  (tlci-loader-validate-imports-at
    image.imports
    (tlci.tlci-import-section-count image.imports)
    rodata-offset
    (array-length image.rodata)
    code-offset
    (array-length image.code)))

(define (tlci-loader-symbol-range-ok?
  [symbols : (& symbols (__tl_dyn-array u8))]
  [offset : i64]
  [len : i64]) : bool
  (and
    (>= offset 0)
    (>= len 0)
    (<= offset (array-length symbols))
    (<= len (- (array-length symbols) offset))))

(define (tlci-loader-symbol-name-eq-at?
  [symbols : (& symbols (__tl_dyn-array u8))]
  [offset : i64]
  [expected : (& expected str)]
  [len : i64]) : bool
  (for [index (iterator.range 0 len)]
    (unless
      (=
        (tlci.tlci-byte-at symbols (+ offset index))
        (cast (tlci.tlci-string-ref expected index) : i64))
      (return false))
    unit)
  true)

(define (tlci-loader-symbol-name-eq?
  [symbols : (& symbols (__tl_dyn-array u8))]
  [offset : i64]
  [len : i64]
  [expected : (& expected str)]) : bool
  (and
    (= len (tlci.tlci-string-length expected))
    (tlci-loader-symbol-range-ok? symbols offset len)
    (tlci-loader-symbol-name-eq-at? symbols offset expected len)))

(define (tlci-loader-find-entry-at
  [entries : (& entries (__tl_dyn-array u8))]
  [symbols : (& symbols (__tl_dyn-array u8))]
  [count : i64]
  [code-len : i64]
  [found : bool]
  [found-code-offset : i64]) : ResultTlciLoaderI64
  (for [index (iterator.range 0 count)]
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
          (return (Err "tlci loader: entry name range outside symbol table"))]
        [(or (< code-offset 0) (>= code-offset code-len))
          (return (Err "tlci loader: entry code offset outside code section"))]
        [(tlci-loader-symbol-name-eq?
            symbols
            name-offset
            name-len
            (tlci.tlci-image-entry-symbol-shared-view))
          (if found
            (return (Err "tlci loader: duplicate tlci_image_entry entry"))
            (begin
              (set! found true)
              (set! found-code-offset code-offset)))]
        [else unit])))
  (if found
    (Ok found-code-offset)
    (Err "tlci loader: missing tlci_image_entry entry")))

;; A native package image (normal-backend transformers, refs #5213) carries a
;; single entries record named tlci_macro_table whose code offset points at an
;; in-code count word followed by the macro-entry records. Such images have no
;; registration entry: the loader reads the table directly.
(define (tlci-loader-native-table-offset [image : (& image tlci.TlciImage)]) : i64
  (let
    [entries : (__tl_dyn-array u8) image.entries]
    [symbols : (__tl_dyn-array u8) image.symbols]
    [count : i64 (/ (array-length entries) tlci.tlci-section-entry-record-size)]
    [index : i64 0]
    [found : i64 -1]
    (while (and (< found 0) (< index count))
      (let
        [record-offset : i64 (* index tlci.tlci-section-entry-record-size)]
        [name-offset : i64 (tlci.tlci-read-u64 entries record-offset)]
        [name-len : i64 (tlci.tlci-read-u64 entries (+ record-offset 8))]
        (if (and
          (tlci-loader-symbol-range-ok? symbols name-offset name-len)
          (tlci-loader-symbol-name-eq?
            symbols
            name-offset
            name-len
            (tlci.tlci-macro-table-symbol-shared-view)))
          (set! found (tlci.tlci-read-u64 entries (+ record-offset 16)))
          unit)
        (+= index 1)))
    found))

(define (tlci-loader-native-image? [image : (& image tlci.TlciImage)]) : bool
  (>= (tlci-loader-native-table-offset image) 0))

(define (tlci-loader-find-entry-code-offset [image : (& image tlci.TlciImage)]) : ResultTlciLoaderI64
  (let
    [code-len : i64 (array-length image.code)]
    [entry-count : i64
      (/ (array-length image.entries) tlci.tlci-section-entry-record-size)]
    (if (= entry-count 0)
      (Err "tlci loader: missing entry table")
      (tlci-loader-find-entry-at
        image.entries
        image.symbols
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

(define (tlci-loader-i64-array-addr [items : (& items (__tl_dyn-array i64))]) : i64
  (cast
    (unsafe
      (ptr->int
        (ptr-cast
          (__tl_array-data
            (unsafe
              (ptr-read
                (ptr-cast
                  (__tl_array-data (array items))
                  : (Ptr (__tl_dyn-array i64))))))
          : (Ptr u8))))
    : i64))

(define (tlci-loader-u8-array-addr [items : (& items (__tl_dyn-array u8))]) : i64
  (cast
    (unsafe
      (ptr->int
        (__tl_array-data
          (unsafe
            (ptr-read
              (ptr-cast
                (__tl_array-data (array items))
                : (Ptr (__tl_dyn-array u8))))))))
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
(define (tlci-loader-alloc-i64-array-in-arena [owner-arena : i64] [count : i64]) : (__tl_dyn-array
    i64)
  (in-arena (arena.Arena owner-arena) (__tl_make-array i64 count)))

(define (tlci-loader-host-table-storage
  [owner-arena : i64]
  [table : tlci.TlciHostCallbackTable]) : (__tl_dyn-array i64)
  (let
    [items : (__tl_dyn-array i64)
      (tlci-loader-alloc-i64-array-in-arena owner-arena 8)]
    (set! (array-ref items 0) table.magic)
    (set! (array-ref items 1) table.abi-version)
    (set! (array-ref items 2) table.byte-size)
    (set! (array-ref items 3) table.host-context)
    (set! (array-ref items 4) table.reserved0)
    (set! (array-ref items 5) table.reserved1)
    (set! (array-ref items 6) table.reserved2)
    (set! (array-ref items 7) table.abort-callback)
    items))

(define (tlci-loader-registration-storage [owner-arena : i64]) : (__tl_dyn-array
    i64)
  (tlci-loader-alloc-i64-array-in-arena owner-arena 8))

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
  [fixups : (__tl_dyn-array u8)]
  [count : i64]) : unit
  (for [index (iterator.range 0 count)]
    (let
      [slot-offset : i64
        (tlci.tlci-read-u64
          fixups
          (* index tlci.tlci-section-fixup-record-size))]
      [slot-addr : i64 (+ image-base slot-offset)]
      [current : i64 (tlci-loader-read-mapped-i64 slot-addr)]
      (tlci-loader-write-mapped-i64! slot-addr (+ current image-base))
      unit)))

(define (tlci-loader-apply-fixups!
  [image-base : i64]
  [image : (& image tlci.TlciImage)]) : unit
  (tlci-loader-apply-fixups-at!
    image-base
    (owned_view.compiler-owned-reference-shared-view (& image.fixups))
    (/ (array-length image.fixups) tlci.tlci-section-fixup-record-size)))

;; Resolve one image import against the compiler's static host registry. The
;; registry is validated before mapping, so a found address is always nonzero.
(define (tlci-loader-host-import-address
  [host-table : (& host-table tlci.TlciHostCallbackTable)]
  [name : String]) : ResultTlciLoaderI64
  (let
    [index : i64 0]
    [count : i64 host-table.import-count]
    [found : i64 -1]
    (while (and (< found 0) (< index count))
      (if (string.eq (array-ref host-table.import-names index) name)
        (set! found index)
        (+= index 1)))
    (if (< found 0)
      (Err name)
      (Ok (array-ref host-table.import-callbacks found)))))

;; Bind each image import name to a raw host callback address, writing the GOT
;; slot while the image is still writable and before any comptime code runs.
(define (tlci-loader-bind-imports-at!
  [image-base : i64]
  [imports : (__tl_dyn-array u8)]
  [image-identity : String]
  [host-table : (& host-table tlci.TlciHostCallbackTable)]
  [count : i64]) : ResultTlciLoaderUnit
  (for [index (iterator.range 0 count)]
    (let
      [record : i64
        (+
          tlci.tlci-section-import-header-size
          (* index tlci.tlci-section-import-record-size))]
      [slot-offset : i64 (tlci.tlci-read-u64 imports record)]
      [name-offset : i64 (tlci.tlci-read-u64 imports (+ record 8))]
      [name-len : i64 (tlci.tlci-read-u64 imports (+ record 16))]
      [name : String (tlci.tlci-bytes->string imports name-offset name-len)]
      (match (tlci-loader-host-import-address host-table name)
        [(Err missing)
          (return
            (Err
              (str_cat.str-cat
                "tlci loader: image `"
                (str_cat.str-cat
                  image-identity
                  (str_cat.str-cat
                    "` has unresolved host import `"
                    (str_cat.str-cat missing "`"))))))]
        [(Ok address)
          (tlci-loader-write-mapped-i64! (+ image-base slot-offset) address)
          unit])))
  (Ok))

(define (tlci-loader-bind-imports!
  [image-base : i64]
  [image : (& image tlci.TlciImage)]
  [host-table : (& host-table tlci.TlciHostCallbackTable)]) : ResultTlciLoaderUnit
  (tlci-loader-bind-imports-at!
    image-base
    (owned_view.compiler-owned-reference-shared-view (& image.imports))
    (str_cat.str-cat
      (string.copy (& image.metadata.package-name))
      (str_cat.str-cat "@" (string.copy (& image.metadata.package-version))))
    host-table
    (tlci.tlci-import-section-count image.imports)))

(define (tlci-loader-protect-rodata
  [image-base : i64]
  [rodata-offset : i64]
  [rodata-len : i64]) : ResultTlciLoaderUnit
  (if (= rodata-len 0)
    (Ok)
    (let
      [_
        (try
          (pages.tlci-pages-protect-data-readonly
            (pages.TlciPageRegion
              (+ image-base rodata-offset)
              (pages.tlci-pages-round-size rodata-len)
              false
              true
              false)))]
      (Ok))))

(define (tlci-loader-protect-code
  [image-base : i64]
  [code-offset : i64]
  [code-len : i64]) : ResultTlciLoaderUnit
  (let
    [_
      (try
        (pages.tlci-pages-protect-code-executable
          (pages.TlciPageRegion
            (+ image-base code-offset)
            (pages.tlci-pages-round-size code-len)
            true
            true
            false)))]
    (Ok)))

(define (tlci-loader-loaded-image-region [loaded : TlciLoadedImage]) : pages.TlciPageRegion
  (pages.TlciPageRegion
    loaded.image-region-addr
    loaded.image-region-size
    loaded.image-region-code
    loaded.image-region-writable
    loaded.image-region-executable))

(define (tlci-loader-image-live? [loaded : (& loaded TlciLoadedImage)]) : bool
  (and (= (array-length loaded.live) 1) (array-ref loaded.live 0)))

(define (tlci-loader-release [loaded : TlciLoadedImage]) : ResultTlciLoaderUnit
  (if (not (tlci-loader-image-live? (& loaded)))
    (Err "tlci loader: image already released")
    (let
      [_revoke : unit (set! (array-ref loaded.live 0) false)]
      [index-arena : i64 loaded.macro-index-arena]
      [page-result : pages.ResultTlciPageUnit
        (pages.tlci-pages-release (tlci-loader-loaded-image-region loaded))]
      (tlci-loader-destroy-index-arena index-arena)
      (let
        [_ (try page-result)]
        (Ok)))))

;; Every failed load relinquishes its only mapping owner. The index arena is
;; destroyed by tlci-loader-release even when the host leaves pages mapped;
;; no failed image or stale entry is returned for later dispatch.
(define (tlci-loader-rollback-loaded
  [loaded : TlciLoadedImage]
  [primary : String]) : ResultTlciLoadedImage
  (match (tlci-loader-release loaded)
    [(Ok) (Err primary)]
    [(Err release-message)
      (Err (pages.tlci-pages-first-error primary (Err release-message)))]))

(define (tlci-loader-rollback-region
  [region : pages.TlciPageRegion]
  [primary : String]) : ResultTlciLoadedImage
  (Err (pages.tlci-pages-rollback-error region primary)))

(define (tlci-loader-loaded-image
  [owner-arena : i64]
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
    image-region.addr
    image-region.size
    image-region.code
    image-region.writable
    image-region.executable
    (+ image-base (+ code-offset entry-code-offset))
    (tlci-loader-global-shared-view tlci-loader-no-retained-storage)
    (tlci-loader-global-shared-view tlci-loader-no-retained-storage)
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
    symbol-count
    0
    (__tl_make-array i64 0)
    (__tl_make-array i64 0)
    (__tl_make-array i64 0)
    (__tl_make-array i64 0)
    (__tl_make-array i64 0)
    0
    (in-arena (arena.Arena owner-arena) (__tl_make-array true))))

(define (tlci-loader-loaded-image-with-registration
  [loaded : TlciLoadedImage]
  [host-table-storage : (__tl_dyn-array i64)]
  [registration-storage : (__tl_dyn-array i64)]
  [host-table-addr : i64]
  [registration-addr : i64]
  [registration : tlci.TlciImageRegistration]) : TlciLoadedImage
  (TlciLoadedImage
    loaded.image-region-addr
    loaded.image-region-size
    loaded.image-region-code
    loaded.image-region-writable
    loaded.image-region-executable
    loaded.entry-addr
    host-table-storage
    registration-storage
    host-table-addr
    registration-addr
    registration.image-context
    registration.macro-entry-table
    registration.macro-entry-count
    loaded.rodata-addr
    loaded.rodata-len
    loaded.code-addr
    loaded.code-len
    loaded.fixup-count
    loaded.entry-count
    loaded.symbol-count
    0
    (__tl_make-array i64 0)
    (__tl_make-array i64 0)
    (__tl_make-array i64 0)
    (__tl_make-array i64 0)
    (__tl_make-array i64 0)
    0
    loaded.live))

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
  [bytes : (__tl_dyn-array u8)]
  [loaded : TlciLoadedImage]
  [host-table : tlci.TlciHostCallbackTable]
  [table-offset : i64]) : ResultTlciLoadedImage
  (let
    [code-file-offset : i64 (tlci.tlci-read-u64 bytes 88)]
    [count-addr : i64
      (+ loaded.image-region-addr (+ code-file-offset table-offset))]
    [macro-count : i64 (tlci-loader-read-mapped-i64 count-addr)]
    [host-storage : (__tl_dyn-array i64)
      (tlci-loader-host-table-storage owner-arena host-table)]
    [host-table-addr : i64 (tlci-loader-i64-array-addr host-storage)]
    [installed : TlciLoadedImage
      (TlciLoadedImage
        loaded.image-region-addr
        loaded.image-region-size
        loaded.image-region-code
        loaded.image-region-writable
        loaded.image-region-executable
        loaded.entry-addr
        host-storage
        loaded.registration-storage
        host-table-addr
        loaded.registration-addr
        0
        (+ count-addr 8)
        macro-count
        loaded.rodata-addr
        loaded.rodata-len
        loaded.code-addr
        loaded.code-len
        loaded.fixup-count
        loaded.entry-count
        loaded.symbol-count
        0
        (__tl_make-array i64 0)
        (__tl_make-array i64 0)
        (__tl_make-array i64 0)
        (__tl_make-array i64 0)
        (__tl_make-array i64 0)
        0
        loaded.live)]
    (match (tlci-loader-index-macro-entries
      (tlci-loader-global-shared-view installed))
      [(Err message) (tlci-loader-rollback-loaded installed message)]
      [(Ok indexed) (Ok indexed)])))

(define (tlci-loader-load-from-bytes-with-registration
  [owner-arena : i64]
  [bytes : (__tl_dyn-array u8)]
  [host-table : tlci.TlciHostCallbackTable]) : ResultTlciLoadedImage
  (let
    [parsed
      (try
        (tlci.tlci-parse-image (owned_view.compiler-owned-shared-view bytes)))]
    [native-table : i64 (tlci-loader-native-table-offset parsed)]
    [loaded
      (try (tlci-loader-load-parsed owner-arena bytes parsed (& host-table)))]
    (if (>= native-table 0)
      (tlci-loader-install-native-table
        owner-arena
        bytes
        loaded
        host-table
        native-table)
      (tlci-loader-finish-registration owner-arena loaded host-table))))

(define (tlci-loader-finish-registration
  [owner-arena : i64]
  [loaded : TlciLoadedImage]
  [host-table : tlci.TlciHostCallbackTable]) : ResultTlciLoadedImage
  (let
    [loaded (try (ResultTlciLoadedImage.Ok loaded))]
    [host-storage : (__tl_dyn-array i64)
      (tlci-loader-host-table-storage owner-arena host-table)]
    [registration-storage : (__tl_dyn-array i64)
      (tlci-loader-registration-storage owner-arena)]
    [host-table-addr : i64 (tlci-loader-i64-array-addr host-storage)]
    [registration-addr : i64 (tlci-loader-i64-array-addr registration-storage)]
    [status : i64
      (unsafe
        (tlci-loader-call-image-entry-raw
          loaded.entry-addr
          host-table-addr
          registration-addr))]
    (if (not (= status tlci.tlci-image-entry-success))
      (tlci-loader-rollback-loaded
        loaded
        (tlci-loader-registration-status-error status))
      (let
        [registration : tlci.TlciImageRegistration
          (tlci-loader-read-registration registration-addr)]
        (match (tlci.tlci-validate-image-registration registration)
          [(Err message)
            (tlci-loader-rollback-loaded
              loaded
              (tlci-loader-registration-error message))]
          [(Ok)
            (let
              [registered : TlciLoadedImage
                (tlci-loader-loaded-image-with-registration
                  loaded
                  host-storage
                  registration-storage
                  host-table-addr
                  registration-addr
                  registration)]
              (match (tlci-loader-index-macro-entries
                (tlci-loader-global-shared-view registered))
                [(Err message) (tlci-loader-rollback-loaded registered message)]
                [(Ok indexed) (Ok indexed)]))])))))

(define (tlci-loader-load-mapped-region
  [owner-arena : i64]
  [bytes : (& bytes (__tl_dyn-array u8))]
  [image : tlci.TlciImage]
  [image-region : pages.TlciPageRegion]
  [entry-code-offset : i64]
  [rodata-offset : i64]
  [code-offset : i64]
  [host-table : (& host-table tlci.TlciHostCallbackTable)]) : ResultTlciLoadedImage
  (let
    [image-base : i64 image-region.addr]
    [rodata-len : i64 (array-length image.rodata)]
    [code-len : i64 (array-length image.code)]
    [fixup-count : i64
      (/ (array-length image.fixups) tlci.tlci-section-fixup-record-size)]
    [entry-count : i64
      (/ (array-length image.entries) tlci.tlci-section-entry-record-size)]
    [symbol-count : i64
      (/ (array-length image.symbols) tlci.tlci-section-symbol-record-size)]
    (match (pages.tlci-pages-copy-from-array! image-region bytes)
      [(Err message)
        (return (tlci-loader-rollback-region image-region message))]
      [(Ok) unit])
    (tlci-loader-apply-fixups! image-base image)
    (match (tlci-loader-bind-imports! image-base image host-table)
      [(Err message)
        (return (tlci-loader-rollback-region image-region message))]
      [(Ok) unit])
    (match (tlci-loader-protect-rodata image-base rodata-offset rodata-len)
      [(Err message)
        (return (tlci-loader-rollback-region image-region message))]
      [(Ok) unit])
    (match (tlci-loader-protect-code image-base code-offset code-len)
      [(Err message)
        (return (tlci-loader-rollback-region image-region message))]
      [(Ok) unit])
    (Ok
      (tlci-loader-loaded-image
        owner-arena
        image-region
        image-base
        rodata-offset
        rodata-len
        code-offset
        code-len
        entry-code-offset
        fixup-count
        entry-count
        symbol-count))))

(define (tlci-loader-load-parsed
  [owner-arena : i64]
  [bytes : (& bytes (__tl_dyn-array u8))]
  [image : tlci.TlciImage]
  [host-table : (& host-table tlci.TlciHostCallbackTable)]) : ResultTlciLoadedImage
  (match (tlci.tlci-image-admit-host
    (tlci-loader-global-shared-view image)
    (tlci.tlci-build-host-platform))
    [(Rejected message) (Err message)]
    [(MetadataOnly) (Err "tlci loader: image has no code section")]
    [(CodeBearing)
      (let
        [rodata-offset : i64 (tlci.tlci-read-u64 bytes 72)]
        [code-offset : i64 (tlci.tlci-read-u64 bytes 88)]
        [entry-code-offset
          (try
            (if (tlci-loader-native-image? image)
              (ResultTlciLoaderI64.Ok 0)
              (tlci-loader-find-entry-code-offset image)))]
        [_ (try (tlci-loader-validate-fixups image rodata-offset code-offset))]
        (let
          [_
            (try (tlci-loader-validate-imports image rodata-offset code-offset))]
          [image-region
            (try (pages.tlci-pages-allocate-data (array-length bytes)))]
          (tlci-loader-load-mapped-region
            owner-arena
            bytes
            image
            image-region
            entry-code-offset
            rodata-offset
            code-offset
            host-table)))]))

(define (tlci-loader-empty-host-table) : tlci.TlciHostCallbackTable
  (tlci.TlciHostCallbackTable
    tlci.tlci-host-callback-table-magic
    tlci.tlci-host-abi-version
    tlci.tlci-host-callback-table-size
    0
    0
    0
    0
    1
    (__tl_make-array String 0)
    (__tl_make-array i64 0)
    0))

(define (tlci-loader-load-from-bytes [bytes : (__tl_dyn-array u8)]) : ResultTlciLoadedImage
  (let
    [image
      (try
        (tlci.tlci-parse-image (owned_view.compiler-owned-shared-view bytes)))]
    [host-table : tlci.TlciHostCallbackTable (tlci-loader-empty-host-table)]
    (tlci-loader-load-parsed
      (arena.tl_arena_current)
      bytes
      image
      (& host-table))))

;: `owner-arena` owns the storage the returned image RETAINS, and must outlive
;: every dispatch on it -- see the ownership rule above
;: `tlci-loader-host-table-storage`. It is deliberately explicit: an image that
;: is released before the caller's current arena can pass
;: `(arena.tl_arena_current)`, and one that is kept past it must not.
(define (tlci-loader-load-from-bytes-with-host
  [owner-arena : i64]
  [bytes : (__tl_dyn-array u8)]
  [host-table : tlci.TlciHostCallbackTable]) : ResultTlciLoadedImage
  (let
    [_
      (try
        (tlci.tlci-validate-host-callback-table
          (tlci-loader-global-shared-view host-table)))]
    (tlci-loader-load-from-bytes-with-registration owner-arena bytes host-table)))

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
    loaded.image-region-addr
    loaded.image-region-size))

(define (tlci-loader-code-address?
  [loaded : (& loaded TlciLoadedImage)]
  [addr : i64]) : bool
  (tlci-loader-address-range-contained? addr 1 loaded.code-addr loaded.code-len))

(define (tlci-loader-mapped-name-eq-at?
  [addr : i64]
  [expected : (& expected str)]
  [len : i64]) : bool
  (for [index (iterator.range 0 len)]
    (unless
      (=
        (cast
          (unsafe
            (ptr-read (ptr-offset (pages.tlci-pages-addr->ptr-u8 addr) index)))
          : i64)
        (cast (tlci.tlci-string-ref expected index) : i64))
      (return false))
    unit)
  true)

(define (tlci-loader-mapped-name-eq?
  [loaded : (& loaded TlciLoadedImage)]
  [addr : i64]
  [len : i64]
  [expected : (& expected str)]) : bool
  (and
    (= len (tlci.tlci-string-length expected))
    (tlci-loader-image-range-contained? loaded addr len)
    (tlci-loader-mapped-name-eq-at? addr expected len)))

(define (tlci-loader-read-macro-entry
  [loaded : (& loaded TlciLoadedImage)]
  [index : i64]) : ResultTlciMacroEntry
  (let
    [count : i64 loaded.macro-entry-count]
    [table : i64 loaded.macro-entry-table]
    [record-size : i64 tlci.tlci-macro-entry-record-size]
    (cond
      [(not (tlci-loader-image-live? loaded))
        (Err "tlci loader: image has been released")]
      [(or (< index 0) (>= index count))
        (Err "tlci loader: macro entry index out of range")]
      [(or (< count 0) (> count (/ loaded.image-region-size record-size)))
        (Err "tlci loader: macro entry count is invalid")]
      [(not (= (% table 8) 0))
        (Err "tlci loader: macro entry table must be 8-byte aligned")]
      [(not
          (tlci-loader-image-range-contained?
            (& loaded)
            table
            (* count record-size)))
        (Err "tlci loader: macro entry table outside mapped image")]
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
              (Err "tlci loader: macro entry reserved field must be zero")]
            [(or
                (<= name-len 0)
                (not
                  (tlci-loader-image-range-contained? loaded name-addr name-len)))
              (Err "tlci loader: macro entry name outside mapped image")]
            [(not (tlci-loader-code-address? loaded function-addr))
              (Err "tlci loader: macro entry function outside code section")]
            [else (Ok (TlciMacroEntry name-addr name-len function-addr))]))])))

(define (tlci-loader-mapped-name-ranges-eq-at?
  [left : i64]
  [right : i64]
  [len : i64]) : bool
  (for [index (iterator.range 0 len)]
    (unless
      (=
        (unsafe
          (ptr-read (ptr-offset (pages.tlci-pages-addr->ptr-u8 left) index)))
        (unsafe
          (ptr-read (ptr-offset (pages.tlci-pages-addr->ptr-u8 right) index))))
      (return false))
    unit)
  true)

(define (tlci-loader-mapped-name-hash [addr : i64] [len : i64]) : i64
  (let
    [index : i64 0]
    [value : i64 0]
    (while (>= (- len index) 4)
      (let
        [h1 : i64
          (+
            (+
              (* value 131)
              (cast
                (unsafe
                  (ptr-read
                    (ptr-offset (pages.tlci-pages-addr->ptr-u8 addr) index)))
                : i64))
            1)]
        [h2 : i64
          (+
            (+
              (* h1 131)
              (cast
                (unsafe
                  (ptr-read
                    (ptr-offset
                      (pages.tlci-pages-addr->ptr-u8 addr)
                      (+ index 1))))
                : i64))
            1)]
        [h3 : i64
          (+
            (+
              (* h2 131)
              (cast
                (unsafe
                  (ptr-read
                    (ptr-offset
                      (pages.tlci-pages-addr->ptr-u8 addr)
                      (+ index 2))))
                : i64))
            1)]
        [h4 : i64
          (+
            (+
              (* h3 131)
              (cast
                (unsafe
                  (ptr-read
                    (ptr-offset
                      (pages.tlci-pages-addr->ptr-u8 addr)
                      (+ index 3))))
                : i64))
            1)]
        [reduced : i64 (+ (bit-and h4 0x7fffffff) (shr h4 31))]
        (set!
          value
          (if (>= reduced 0x7fffffff)
            (- reduced 0x7fffffff)
            reduced))
        (+= index 4)))
    (while (< index len)
      (let
        [next : i64
          (+
            (+
              (* value 131)
              (cast
                (unsafe
                  (ptr-read
                    (ptr-offset (pages.tlci-pages-addr->ptr-u8 addr) index)))
                : i64))
            1)]
        [reduced : i64 (+ (bit-and next 0x7fffffff) (shr next 31))]
        (set!
          value
          (if (>= reduced 0x7fffffff)
            (- reduced 0x7fffffff)
            reduced))
        (+= index 1)))
    value))

(define (tlci-loader-macro-index-capacity [count : i64]) : i64
  (let
    [capacity : i64 1]
    (while (< capacity (* count 2))
      (set! capacity (* capacity 2)))
    capacity))

(define tlci-loader-macro-index-next-generation : i64
  0)

(define (tlci-loader-macro-index-generation-next!) : i64
  (+= tlci-loader-macro-index-next-generation 1)
  (if (<= tlci-loader-macro-index-next-generation 0)
    (set! tlci-loader-macro-index-next-generation 1)
    unit)
  tlci-loader-macro-index-next-generation)

(define (tlci-loader-loaded-image-with-macro-index
  [loaded : TlciLoadedImage]
  [generation : i64]
  [slots : (__tl_dyn-array i64)]
  [name-addrs : (__tl_dyn-array i64)]
  [name-lens : (__tl_dyn-array i64)]
  [function-addrs : (__tl_dyn-array i64)]
  [entry-states : (__tl_dyn-array i64)]
  [index-arena : i64]) : TlciLoadedImage
  (TlciLoadedImage
    loaded.image-region-addr
    loaded.image-region-size
    loaded.image-region-code
    loaded.image-region-writable
    loaded.image-region-executable
    loaded.entry-addr
    loaded.host-table-storage
    loaded.registration-storage
    loaded.host-table-addr
    loaded.registration-addr
    loaded.image-context
    loaded.macro-entry-table
    loaded.macro-entry-count
    loaded.rodata-addr
    loaded.rodata-len
    loaded.code-addr
    loaded.code-len
    loaded.fixup-count
    loaded.entry-count
    loaded.symbol-count
    generation
    slots
    name-addrs
    name-lens
    function-addrs
    entry-states
    index-arena
    loaded.live))

(define (tlci-loader-macro-index-insert!
  [slots : (&mut slots (__tl_dyn-array i64))]
  [name-addrs : (&mut name-addrs (__tl_dyn-array i64))]
  [name-lens : (&mut name-lens (__tl_dyn-array i64))]
  [function-addrs : (&mut function-addrs (__tl_dyn-array i64))]
  [entry-states : (&mut entry-states (__tl_dyn-array i64))]
  [entry : TlciMacroEntry]
  [entry-index : i64]) : ResultTlciLoaderUnit
  (let
    [capacity : i64 (array-length slots)]
    [hash-value : i64
      (tlci-loader-mapped-name-hash entry.name-addr entry.name-len)]
    [slot : i64 (% hash-value capacity)]
    [probes : i64 0]
    [inserted : bool false]
    [duplicate : bool false]
    (while (and (not inserted) (not duplicate) (< probes capacity))
      (let
        [marker : i64 (array-ref slots slot)]
        (if (= marker 0)
          (begin
            (set! (array-ref name-addrs entry-index) entry.name-addr)
            (set! (array-ref name-lens entry-index) entry.name-len)
            (set! (array-ref function-addrs entry-index) entry.function-addr)
            (set! (array-ref entry-states entry-index) 0)
            (set! (array-ref slots slot) (+ entry-index 1))
            (set! inserted true))
          (let
            [candidate : i64 (- marker 1)]
            (if (and
              (= (array-ref name-lens candidate) entry.name-len)
              (tlci-loader-mapped-name-ranges-eq-at?
                (array-ref name-addrs candidate)
                entry.name-addr
                entry.name-len))
              (set! duplicate true)
              (begin
                (set! slot (% (+ slot 1) capacity))
                (+= probes 1)))))))
    (cond
      [duplicate (Err "tlci loader: duplicate macro entry name")]
      [inserted (Ok)]
      [else (Err "tlci loader: macro entry index is full")])))

(define (tlci-loader-build-macro-index
  [loaded : TlciLoadedImage]
  [index-arena : i64]) : ResultTlciLoadedImage
  (let
    [count : i64 loaded.macro-entry-count]
    [slots : (__tl_dyn-array i64)
      (__tl_make-array i64 (tlci-loader-macro-index-capacity count))]
    [name-addrs : (__tl_dyn-array i64) (__tl_make-array i64 count)]
    [name-lens : (__tl_dyn-array i64) (__tl_make-array i64 count)]
    [function-addrs : (__tl_dyn-array i64) (__tl_make-array i64 count)]
    [entry-states : (__tl_dyn-array i64) (__tl_make-array i64 count)]
    [index : i64 0]
    [failed : bool false]
    [message : String ""]
    (while (and (not failed) (< index count))
      (match (tlci-loader-read-macro-entry (& loaded) index)
        [(Err entry-message)
          (set! failed true)
          (set! message entry-message)]
        [(Ok entry)
          (match (tlci-loader-macro-index-insert!
            (&mut slots)
            (&mut name-addrs)
            (&mut name-lens)
            (&mut function-addrs)
            (&mut entry-states)
            entry
            index)
            [(Err index-message)
              (set! failed true)
              (set! message index-message)]
            [(Ok) (+= index 1)])]))
    (if (cfg test tlci-loader-test-fail-index-after-alloc false)
      (Err "tlci loader: injected macro index failure")
      (if failed
        (Err message)
        (Ok
          (tlci-loader-loaded-image-with-macro-index
            loaded
            (tlci-loader-macro-index-generation-next!)
            slots
            name-addrs
            name-lens
            function-addrs
            entry-states
            index-arena))))))

(define (tlci-loader-index-macro-entries [loaded : TlciLoadedImage]) : ResultTlciLoadedImage
  (let
    [count : i64 loaded.macro-entry-count]
    [table : i64 loaded.macro-entry-table]
    [record-size : i64 tlci.tlci-macro-entry-record-size]
    (cond
      [(not (tlci-loader-image-live? (& loaded)))
        (Err "tlci loader: image has been released")]
      [(cfg test tlci-loader-test-fail-index-before-alloc false)
        (Err "tlci loader: injected macro index failure")]
      [(or (< count 0) (> count (/ loaded.image-region-size record-size)))
        (Err "tlci loader: macro entry count is invalid")]
      [(= count 0)
        (Ok
          (tlci-loader-loaded-image-with-macro-index
            loaded
            (tlci-loader-macro-index-generation-next!)
            (__tl_make-array i64 0)
            (__tl_make-array i64 0)
            (__tl_make-array i64 0)
            (__tl_make-array i64 0)
            (__tl_make-array i64 0)
            0))]
      [(not (= (% table 8) 0))
        (Err "tlci loader: macro entry table must be 8-byte aligned")]
      [(not
          (tlci-loader-image-range-contained?
            loaded
            table
            (* count record-size)))
        (Err "tlci loader: macro entry table outside mapped image")]
      [else
        (let
          [index-arena : i64 (arena.tl_arena_make_small)]
          [result : ResultTlciLoadedImage
            (in-arena
              (arena.Arena index-arena)
              (tlci-loader-build-macro-index loaded index-arena))]
          (match result
            [(Err message)
              (tlci-loader-destroy-index-arena index-arena)
              (Err message)]
            [(Ok indexed) (Ok indexed)]))])))

(define (tlci-loader-validate-macro-entries [loaded : TlciLoadedImage]) : ResultTlciLoaderUnit
  (let
    [indexed (try (tlci-loader-index-macro-entries loaded))]
    (tlci-loader-destroy-index-arena indexed.macro-index-arena)
    (Ok)))

(define (tlci-loader-resolve-macro-entry
  [loaded : (& loaded TlciLoadedImage)]
  [name : String]) : TlciMacroEntryLookup
  (let
    [count : i64 loaded.macro-entry-count]
    [generation : i64 loaded.macro-index-generation]
    [slots : (__tl_dyn-array i64) loaded.macro-index-slots]
    [name-addrs : (__tl_dyn-array i64) loaded.macro-index-name-addrs]
    [name-lens : (__tl_dyn-array i64) loaded.macro-index-name-lens]
    [entry-states : (__tl_dyn-array i64) loaded.macro-index-entry-states]
    (cond
      [(not (tlci-loader-image-live? loaded))
        (Err "tlci loader: image has been released")]
      [(= count 0) Missing]
      [(or
          (<= generation 0)
          (= (array-length slots) 0)
          (not (= (array-length name-addrs) count))
          (not (= (array-length name-lens) count))
          (not (= (array-length entry-states) count)))
        (Err "tlci loader: macro entry index is unavailable")]
      [else
        (let
          [capacity : i64 (array-length slots)]
          [hash-value : i64 (hash.string-key name)]
          [slot : i64 (% hash-value capacity)]
          [probes : i64 0]
          [found : i64 -1]
          [done : bool false]
          (while (and (not done) (< probes capacity))
            (let
              [marker : i64 (array-ref slots slot)]
              (if (= marker 0)
                (set! done true)
                (let
                  [candidate : i64 (- marker 1)]
                  (if (tlci-loader-mapped-name-eq?
                    loaded
                    (array-ref name-addrs candidate)
                    (array-ref name-lens candidate)
                    name)
                    (begin
                      (set! found candidate)
                      (set! done true))
                    (begin
                      (set! slot (% (+ slot 1) capacity))
                      (+= probes 1)))))))
          (if (< found 0)
            Missing
            (let
              [resolved : TlciResolvedMacroEntry
                (TlciResolvedMacroEntry generation found)]
              (if (= (array-ref entry-states found) 1)
                (Shell resolved)
                (Resolved resolved)))))])))

(define (tlci-loader-resolved-macro-entry
  [loaded : (& loaded TlciLoadedImage)]
  [resolved : TlciResolvedMacroEntry]) : ResultTlciMacroEntry
  (let
    [index : i64 resolved.entry-index]
    [count : i64 loaded.macro-entry-count]
    [name-addrs : (__tl_dyn-array i64) loaded.macro-index-name-addrs]
    [name-lens : (__tl_dyn-array i64) loaded.macro-index-name-lens]
    [function-addrs : (__tl_dyn-array i64) loaded.macro-index-function-addrs]
    (cond
      [(not (tlci-loader-image-live? loaded))
        (Err "tlci loader: image has been released")]
      [(not (= resolved.catalog-generation loaded.macro-index-generation))
        (Err "tlci loader: macro entry handle belongs to another catalog")]
      [(or
          (< index 0)
          (>= index count)
          (not (= (array-length name-addrs) count))
          (not (= (array-length name-lens) count))
          (not (= (array-length function-addrs) count)))
        (Err "tlci loader: macro entry handle is invalid")]
      [else
        (Ok
          (TlciMacroEntry
            (array-ref name-addrs index)
            (array-ref name-lens index)
            (array-ref function-addrs index)))])))

(define (tlci-loader-mark-macro-entry-shell!
  [loaded : (& loaded TlciLoadedImage)]
  [resolved : TlciResolvedMacroEntry]) : ResultTlciLoaderUnit
  (let
    [_ (try (tlci-loader-resolved-macro-entry loaded resolved))]
    [states : (__tl_dyn-array i64) loaded.macro-index-entry-states]
    [index : i64 resolved.entry-index]
    (if (not (= (array-length states) loaded.macro-entry-count))
      (Err "tlci loader: macro entry state index is unavailable")
      (begin
        (set! (array-ref states index) 1)
        (Ok)))))

(define (tlci-loader-find-macro-entry
  [loaded : (& loaded TlciLoadedImage)]
  [name : String]) : ResultTlciMacroEntry
  (match (tlci-loader-resolve-macro-entry loaded name)
    [(Resolved resolved) (tlci-loader-resolved-macro-entry loaded resolved)]
    [(Shell resolved) (tlci-loader-resolved-macro-entry loaded resolved)]
    [(Missing)
      (Err
        (if (= loaded.macro-entry-count 0)
          "tlci loader: image registered no macros"
          "tlci loader: macro entry not found"))]
    [(Err message) (Err message)]))

(define (tlci-loader-dispatch-macro-entry
  [loaded : (& loaded TlciLoadedImage)]
  [entry : TlciMacroEntry]
  [session-context : i64]
  [operands : (__tl_dyn-array i64)]
  [initial-result : i64]) : ResultTlciMacroDispatch
  (if (not (tlci-loader-image-live? loaded))
    (Err "tlci loader: image has been released")
    (let
      [result-storage : (__tl_dyn-array i64) (__tl_make-array initial-result)]
      [operand-count : i64 (array-length operands)]
      [operands-addr : i64
        (if (= operand-count 0)
          0
          (tlci-loader-i64-array-addr operands))]
      [result-addr : i64 (tlci-loader-i64-array-addr result-storage)]
      [host-context : i64
        (tlci-loader-read-mapped-i64
          (+
            loaded.host-table-addr
            tlci.tlci-host-callback-table-host-context-offset))]
      [status : i64
        (unsafe
          (tlci-loader-call-macro-entry-raw
            entry.function-addr
            loaded.image-context
            host-context
            session-context
            operands-addr
            operand-count
            result-addr))]
      (Ok (TlciMacroDispatch status (array-ref result-storage 0))))))

(define (tlci-loader-dispatch-resolved-macro
  [loaded : (& loaded TlciLoadedImage)]
  [resolved : TlciResolvedMacroEntry]
  [session-context : i64]
  [operands : (__tl_dyn-array i64)]
  [initial-result : i64]) : ResultTlciMacroDispatch
  (let
    [entry (try (tlci-loader-resolved-macro-entry loaded resolved))]
    (tlci-loader-dispatch-macro-entry
      loaded
      entry
      session-context
      operands
      initial-result)))

(define (tlci-loader-dispatch-macro
  [loaded : (& loaded TlciLoadedImage)]
  [name : String]
  [session-context : i64]
  [operands : (__tl_dyn-array i64)]
  [initial-result : i64]) : ResultTlciMacroDispatch
  (match (tlci-loader-resolve-macro-entry loaded name)
    [(Resolved resolved)
      (tlci-loader-dispatch-resolved-macro
        loaded
        resolved
        session-context
        operands
        initial-result)]
    [(Shell _) (Err "tlci loader: macro entry is a known shell")]
    [(Missing) (Err "tlci loader: macro entry not found")]
    [(Err message) (Err message)]))

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
      (str_cat.str-cat
        (string.int->string status)
        (str_cat.str-cat " for " name)))))