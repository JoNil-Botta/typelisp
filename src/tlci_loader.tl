;; tlci_loader.tl - Dormant tlci comptime image loader core.
;;
;; Native macro dispatch lands in later slices. This module owns the loader
;; boundary that is already specified: parse/validate a tlci image, map it into
;; page-backed host memory, apply load-base fixups while pages are writable, and
;; finalize code pages as RX through tlci_pages.
(import stdlib.string)
(import stdlib.str_cat_runtime as str_cat)
(import "tlci_core.tl")
(import "tlci_pages.tl")

(defstruct TlciLoadedImage
  (image-region TlciPageRegion)
  (entry-addr i64)
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
    (ptr-read (ptr-cast (tlci-pages-addr->ptr-u8 addr) : (Ptr i64)))))

(define (tlci-loader-write-mapped-i64! [addr : i64] [value : i64]) : unit
  (unsafe
    (ptr-write! (ptr-cast (tlci-pages-addr->mut-u8 addr) : (MutPtr i64)) value)))

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

(define (tlci-loader-protect-rodata
  [image-base : i64]
  [rodata-offset : i64]
  [rodata-len : i64]) : ResultTlciLoaderUnit
  (if (= rodata-len 0)
    (ResultTlciLoaderUnit.Ok)
    (match (tlci-pages-protect-data-readonly
      (TlciPageRegion
        (+ image-base rodata-offset)
        (tlci-pages-round-size rodata-len)
        false
        true
        false))
      [(ResultTlciPageRegion.Ok _) (ResultTlciLoaderUnit.Ok)]
      [(ResultTlciPageRegion.Err message) (ResultTlciLoaderUnit.Err message)])))

(define (tlci-loader-protect-code
  [image-base : i64]
  [code-offset : i64]
  [code-len : i64]) : ResultTlciLoaderUnit
  (match (tlci-pages-protect-code-executable
    (TlciPageRegion
      (+ image-base code-offset)
      (tlci-pages-round-size code-len)
      true
      true
      false))
    [(ResultTlciPageRegion.Ok _) (ResultTlciLoaderUnit.Ok)]
    [(ResultTlciPageRegion.Err message) (ResultTlciLoaderUnit.Err message)]))

(define (tlci-loader-release [loaded : TlciLoadedImage]) : ResultTlciLoaderUnit
  (match (tlci-pages-release (struct-get loaded image-region))
    [(ResultTlciPageUnit.Ok) (ResultTlciLoaderUnit.Ok)]
    [(ResultTlciPageUnit.Err message) (ResultTlciLoaderUnit.Err message)]))

(define (tlci-loader-loaded-image
  [image-region : TlciPageRegion]
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
    image-region
    (+ image-base (+ code-offset entry-code-offset))
    (+ image-base rodata-offset)
    rodata-len
    (+ image-base code-offset)
    code-len
    fixup-count
    entry-count
    symbol-count))

(define (tlci-loader-load-mapped-region
  [bytes : (Array u8)]
  [image : TlciImage]
  [image-region : TlciPageRegion]
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
      (match (tlci-pages-copy-from-array! image-region bytes)
        [(ResultTlciPageUnit.Err message)
          (begin
            (tlci-pages-release image-region)
            (return (ResultTlciLoadedImage.Err message)))]
        [(ResultTlciPageUnit.Ok) unit])
      (tlci-loader-apply-fixups! image-base image)
      (match (tlci-loader-protect-rodata image-base rodata-offset rodata-len)
        [(ResultTlciLoaderUnit.Err message)
          (begin
            (tlci-pages-release image-region)
            (return (ResultTlciLoadedImage.Err message)))]
        [(ResultTlciLoaderUnit.Ok) unit])
      (match (tlci-loader-protect-code image-base code-offset code-len)
        [(ResultTlciLoaderUnit.Err message)
          (begin
            (tlci-pages-release image-region)
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

(define (tlci-loader-load-parsed [bytes : (Array u8)] [image : TlciImage]) : ResultTlciLoadedImage
  (let
    [rodata-offset : i64 (tlci-read-u64 bytes 72)]
    [code-offset : i64 (tlci-read-u64 bytes 88)]
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
              (match (tlci-pages-allocate-data (array-length bytes))
                [(ResultTlciPageRegion.Err message)
                  (ResultTlciLoadedImage.Err message)]
                [(ResultTlciPageRegion.Ok image-region)
                  (tlci-loader-load-mapped-region
                    bytes
                    image
                    image-region
                    entry-code-offset
                    rodata-offset
                    code-offset)])])]))))

(define (tlci-loader-load-from-bytes [bytes : (Array u8)]) : ResultTlciLoadedImage
  (match (tlci-parse-image bytes)
    [(ResultTlciImage.Err message) (ResultTlciLoadedImage.Err message)]
    [(ResultTlciImage.Ok image) (tlci-loader-load-parsed bytes image)]))

(define (tlci-loader-load-from-bytes-with-host
  [bytes : (Array u8)]
  [host-table : TlciHostCallbackTable]) : ResultTlciLoadedImage
  (match (tlci-validate-host-callback-table host-table)
    [(ResultTlciHostAbi.Err message) (ResultTlciLoadedImage.Err message)]
    [(ResultTlciHostAbi.Ok) (tlci-loader-load-from-bytes bytes)]))

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

(define (tlci-loader-test-code-bytes) : (Array u8)
  (tlci-test-bytes3 195 144 144))

(define (tlci-loader-test-rodata-bytes) : (Array u8)
  (let
    [out : (Array u8) (make-array u8 8)]
    (begin
      (tlci-set-u64! out 0 0)
      out)))

(define (tlci-loader-test-image [fixup-offset : i64]) : TlciImage
  (TlciImage
    tlci-host-arch-x86-64
    tlci-callback-abi-version
    "abcdef0"
    (tlci-test-metadata)
    (tlci-loader-test-rodata-bytes)
    (tlci-loader-test-code-bytes)
    (tlci-loader-test-u64-record fixup-offset)
    (tlci-loader-test-entry-record
      0
      (tlci-string-length tlci-image-entry-symbol)
      0)
    (tlci-loader-test-symbol-bytes)))

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

(define (tlci-loader-test-loads-and-fixes-up-status) : i64
  (match (tlci-loader-test-emit-with-real-fixup)
    [(ResultTlciBytes.Err _) 10]
    [(ResultTlciBytes.Ok bytes)
      (match (tlci-loader-load-from-bytes-with-host
        bytes
        (tlci-test-host-callback-table))
        [(ResultTlciLoadedImage.Err _) 11]
        [(ResultTlciLoadedImage.Ok loaded)
          (let
            [image-base : i64
              (struct-get (struct-get loaded image-region) addr)]
            [slot : i64
              (tlci-loader-read-mapped-i64 (struct-get loaded rodata-addr))]
            [entry-ok : bool
              (= (struct-get loaded entry-addr) (struct-get loaded code-addr))]
            [counts-ok : bool
              (and
                (= (struct-get loaded fixup-count) 1)
                (= (struct-get loaded entry-count) 1)
                (= (struct-get loaded symbol-count) 1))]
            [release-ok : bool
              (match (tlci-loader-release loaded)
                [(ResultTlciLoaderUnit.Ok) true]
                [(ResultTlciLoaderUnit.Err _) false])]
            (cond
              [(not (= slot image-base)) 12]
              [(not entry-ok) 13]
              [(not counts-ok) 14]
              [(not release-ok) 15]
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
                bytes
                (TlciHostCallbackTable
                  tlci-host-callback-table-magic
                  (+ tlci-host-abi-version 1)
                  tlci-host-callback-table-size
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
      [else 0])))

(define (tlci-loader-self-test-ok?) : bool
  (= (tlci-loader-self-test-status) 0))

(define (tlci-loader-self-test) : i64
  (if (tlci-loader-self-test-ok?)
    42
    (tlci-loader-self-test-status)))