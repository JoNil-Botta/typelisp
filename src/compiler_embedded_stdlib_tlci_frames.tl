;; Indexed TLCH v2 deployment: one model, a surface, and independent native images.
;; Each decoded frame is an ordinary TLCI image with its own integrity checks.
(import stdlib.iterator)
(import stdlib.string)
(import stdlib.byte_buf_core as buf)
(import compiler_owned_view as view)
(import compiler_embedded_stdlib_tlci_codec as codec)
(import tlci_core as tlci)

(defstruct CompilerEmbeddedStdlibTlciFrames
  (raw-len i64)
  (count i64)
  (index-end i64))

(defenum ResultCompilerEmbeddedStdlibTlciFrames
  (Err String)
  (Ok CompilerEmbeddedStdlibTlciFrames))

(define (compiler-embedded-stdlib-tlci-frames-prefix) : String
  "__typelisp_embedded_stdlib_tlch_v2__")

(define (compiler-embedded-stdlib-tlci-frames-directory) : i64
  4437)

(define (compiler-embedded-stdlib-tlci-frames-record [index : i64]) : i64
  (+ (compiler-embedded-stdlib-tlci-frames-directory) (* index 48)))

;; Authenticate the complete index, including lengths, names and the shared
;; model, before allocation or lookup. Bodies are checked independently on use.
(define (compiler-embedded-stdlib-tlci-frames-index-hash
  [payload : (& payload (__tl_dyn-array u8))]
  [end : i64]) : i64
  (let
    [hash : i64 (tlci.tlci-hash-extend payload 1 0 60)]
    (for [_i (iterator.range 0 8)]
      (set! hash (% (* hash 131) 2147483647)))
    (tlci.tlci-hash-extend payload hash 68 end)))

(define (compiler-embedded-stdlib-tlci-frames-name-compare
  [payload : (& payload (__tl_dyn-array u8))]
  [left : i64]
  [left-len : i64]
  [right : i64]
  [right-len : i64]) : i64
  (let
    [i : i64 0]
    [order : i64 0]
    (while (and (= order 0) (< i left-len) (< i right-len))
      (set!
        order
        (-
          (cast (array-ref payload (+ left i)) : i64)
          (cast (array-ref payload (+ right i)) : i64)))
      (+= i 1))
    (if (= order 0)
      (- left-len right-len)
      order)))

(define (compiler-embedded-stdlib-tlci-frames-parse
  [payload : (& payload (__tl_dyn-array u8))]
  [raw-limit : i64]) : ResultCompilerEmbeddedStdlibTlciFrames
  (let
    [len : i64 (array-length payload)]
    (when
      (or
        (< raw-limit 0)
        (< len (compiler-embedded-stdlib-tlci-frames-directory)))
      (return
        (Err "embedded stdlib tlci frames: truncated header or invalid limit")))
    (unless
      (codec.compiler-embedded-stdlib-tlci-codec-prefix?
        payload
        (compiler-embedded-stdlib-tlci-frames-prefix))
      (return (Err "embedded stdlib tlci frames: bad prefix or version")))
    (let
      [raw-len : i64 (tlci.tlci-read-u64 payload 36)]
      [index-end : i64 (tlci.tlci-read-u64 payload 44)]
      [count : i64 (tlci.tlci-read-u64 payload 52)]
      [expected-hash : i64 (tlci.tlci-read-u64 payload 60)]
      ;; Division bounds every later record multiplication before it happens.
      (when
        (or
          (< raw-len 0)
          (> raw-len raw-limit)
          (< count 1)
          (< index-end (compiler-embedded-stdlib-tlci-frames-directory))
          (> index-end len)
          (>
            count
            (/
              (- index-end (compiler-embedded-stdlib-tlci-frames-directory))
              48)))
        (return (Err "embedded stdlib tlci frames: invalid index bounds")))
      (unless
        (=
          expected-hash
          (compiler-embedded-stdlib-tlci-frames-index-hash payload index-end))
        (return (Err "embedded stdlib tlci frames: index hash mismatch")))
      (let
        [name-cursor : i64 (compiler-embedded-stdlib-tlci-frames-record count)]
        [body-cursor : i64 index-end]
        [total : i64 0]
        [previous-name : i64 0]
        [previous-len : i64 0]
        (for [index (iterator.range 0 count)]
          (let
            [record : i64 (compiler-embedded-stdlib-tlci-frames-record index)]
            [name : i64 (tlci.tlci-read-u64 payload record)]
            [name-len : i64 (tlci.tlci-read-u64 payload (+ record 8))]
            [body : i64 (tlci.tlci-read-u64 payload (+ record 16))]
            [raw : i64 (tlci.tlci-read-u64 payload (+ record 24))]
            [bits : i64 (tlci.tlci-read-u64 payload (+ record 32))]
            [checksum : i64 (tlci.tlci-read-u64 payload (+ record 40))]
            (when
              (or
                (!= name name-cursor)
                (< name-len 0)
                (> name-len (- index-end name-cursor))
                (if (= index 0)
                  (!= name-len 0)
                  (= name-len 0))
                (< raw tlci.tlci-header-size)
                (> raw (- raw-limit total))
                (<= bits 0)
                (< checksum 0)
                (> checksum 2147483647)
                (!= body body-cursor))
              (return (Err "embedded stdlib tlci frames: invalid frame bounds")))
            (when
              (and
                (> index 1)
                (>=
                  (compiler-embedded-stdlib-tlci-frames-name-compare
                    payload
                    previous-name
                    previous-len
                    name
                    name-len)
                  0))
              (return
                (Err
                  "embedded stdlib tlci frames: unsorted or duplicate identity")))
            (let
              [bytes : i64
                (+
                  (/ bits 8)
                  (if (= (% bits 8) 0)
                    0
                    1))]
              (when
                (> bytes (- len body-cursor))
                (return
                  (Err "embedded stdlib tlci frames: truncated bitstream")))
              (when
                (and
                  (> bytes 0)
                  (!= (% bits 8) 0)
                  (!=
                    (bit-and
                      (cast
                        (array-ref payload (+ body-cursor (- bytes 1)))
                        : i64)
                      (- (shl 1 (- 8 (% bits 8))) 1))
                    0))
                (return
                  (Err "embedded stdlib tlci frames: nonzero padding bits")))
              (+= body-cursor bytes))
            (+= total raw)
            (+= name-cursor name-len)
            (set! previous-name name)
            (set! previous-len name-len)))
        (unless
          (and (= name-cursor index-end) (= body-cursor len) (= total raw-len))
          (return
            (Err
              "embedded stdlib tlci frames: trailing bytes or raw length mismatch")))
        (Ok (CompilerEmbeddedStdlibTlciFrames raw-len count index-end))))))

(define (compiler-embedded-stdlib-tlci-frames-name
  [payload : (& payload (__tl_dyn-array u8))]
  [index : i64]) : String
  (let
    [record : i64 (compiler-embedded-stdlib-tlci-frames-record index)]
    (tlci.tlci-bytes->string
      payload
      (tlci.tlci-read-u64 payload record)
      (tlci.tlci-read-u64 payload (+ record 8)))))

(define (compiler-embedded-stdlib-tlci-frames-find
  [payload : (& payload (__tl_dyn-array u8))]
  [catalog : CompilerEmbeddedStdlibTlciFrames]
  [name : (& name str)]) : i64
  (let
    [lo : i64 1]
    [hi : i64 catalog.count]
    [len : i64 (string.string-length name)]
    (while (< lo hi)
      (let
        [mid : i64 (+ lo (/ (- hi lo) 2))]
        [record : i64 (compiler-embedded-stdlib-tlci-frames-record mid)]
        [offset : i64 (tlci.tlci-read-u64 payload record)]
        [name-len : i64 (tlci.tlci-read-u64 payload (+ record 8))]
        [index : i64 0]
        [order : i64 0]
        (while (and (= order 0) (< index name-len) (< index len))
          (set!
            order
            (-
              (cast (array-ref payload (+ offset index)) : i64)
              (cast (string.string-ref name index) : i64)))
          (+= index 1))
        (when (= order 0) (set! order (- name-len len)))
        (cond
          [(= order 0) (return mid)]
          [(< order 0) (set! lo (+ mid 1))]
          [else (set! hi mid)])))
    -1))

(define (compiler-embedded-stdlib-tlci-frames-decode
  [payload : (& payload (__tl_dyn-array u8))]
  [catalog : CompilerEmbeddedStdlibTlciFrames]
  [index : i64]
  [tables
    : (& tables (__tl_dyn-array codec.CompilerEmbeddedStdlibTlciHuffmanTable))]) : codec.CompilerEmbeddedStdlibTlciCodecBytes
  (when
    (or (< index 0) (>= index catalog.count) (!= (array-length tables) 3))
    (return (Err "embedded stdlib tlci frames: invalid frame or model index")))
  (let
    [record : i64 (compiler-embedded-stdlib-tlci-frames-record index)]
    [raw : i64 (tlci.tlci-read-u64 payload (+ record 24))]
    [bits : i64 (tlci.tlci-read-u64 payload (+ record 32))]
    [body : (__tl_dyn-array u8)
      (tlci.tlci-slice-bytes
        payload
        (tlci.tlci-read-u64 payload (+ record 16))
        (+
          (/ bits 8)
          (if (= (% bits 8) 0)
            0
            1)))]
    (match (codec.compiler-embedded-stdlib-tlci-codec-decode-with-tables
      (& body)
      raw
      bits
      0
      (> (array-ref payload (+ 68 256)) (cast 0 : u8))
      (view.compiler-owned-reference-shared-view (& (array-ref tables 0)))
      (view.compiler-owned-reference-shared-view (& (array-ref tables 1)))
      (view.compiler-owned-reference-shared-view (& (array-ref tables 2))))
      [(Err message) (Err message)]
      [(Ok bytes)
        (if (=
          (tlci.tlci-read-u64 (& bytes) 48)
          (tlci.tlci-read-u64 payload (+ record 40)))
          (Ok bytes)
          (Err "embedded stdlib tlci frames: frame checksum identity mismatch"))])))

(define (compiler-embedded-stdlib-tlci-frames-expand
  [payload : (& payload (__tl_dyn-array u8))]
  [raw-limit : i64]) : tlci.ResultTlciBytes
  (let
    [catalog
      (try (compiler-embedded-stdlib-tlci-frames-parse payload raw-limit))]
    [tables : (__tl_dyn-array codec.CompilerEmbeddedStdlibTlciHuffmanTable)
      (__tl_make-array codec.CompilerEmbeddedStdlibTlciHuffmanTable 3)]
    [images : (__tl_dyn-array (__tl_dyn-array u8))
      (__tl_make-array (__tl_dyn-array u8) catalog.count)]
    [names : (__tl_dyn-array String)
      (__tl_make-array String (- catalog.count 1))]
    (for [index (iterator.range 0 3)]
      (let
        [table
          (try
            (codec.compiler-embedded-stdlib-tlci-codec-build-table
              payload
              (+ 68 (cond [(= index 0) 0] [(= index 1) 257] [else 4353]))
              (cond [(= index 0) 257] [(= index 1) 4096] [else 16])))]
        (set! (array-ref tables index) table)))
    (for [index (iterator.range 0 catalog.count)]
      (let
        [bytes
          (try
            (compiler-embedded-stdlib-tlci-frames-decode
              payload
              catalog
              index
              (& tables)))]
        (set! (array-ref images index) bytes))
      (when
        (> index 0)
        (set!
          (array-ref names (- index 1))
          (compiler-embedded-stdlib-tlci-frames-name payload index))))
    (compiler-embedded-stdlib-tlci-frames-aggregate (& images) (& names))))

;; Recreate a canonical ordinary TLCI catalog for inspection and byte parity.
;; Runtime macro lookup maps just one original frame, never this aggregate.
(define (compiler-embedded-stdlib-tlci-frames-aggregate
  [images : (& images (__tl_dyn-array (__tl_dyn-array u8)))]
  [names : (& names (__tl_dyn-array String))]) : tlci.ResultTlciBytes
  (unless
    (and
      (> (array-length images) 0)
      (= (array-length images) (+ (array-length names) 1)))
    (return (Err "embedded stdlib tlci frames: inconsistent image/name count")))
  (let
    [surface (try (tlci.tlci-parse-image (& (array-ref images 0))))]
    [count : i64 (array-length names)]
    [code : buf.ByteBufBuilder (buf.byte-buf-builder-new)]
    [fixups : buf.ByteBufBuilder (buf.byte-buf-builder-new)]
    [import-records : buf.ByteBufBuilder (buf.byte-buf-builder-new)]
    [import-names : buf.ByteBufBuilder (buf.byte-buf-builder-new)]
    [import-count : i64 0]
    [fixup-count : i64 0]
    [entries : (__tl_dyn-array i64) (__tl_make-array i64 count)]
    (unless
      (and
        (= (array-length surface.code) 0)
        (= (array-length surface.fixups) 0)
        (= (array-length surface.entries) 0)
        (= (array-length surface.symbols) 0)
        (= (array-length surface.imports) 0))
      (return
        (Err "embedded stdlib tlci frames: surface contains native sections")))
    (for [index (iterator.range 0 count)]
      (let
        [raw : (& images (__tl_dyn-array u8))
          (& (array-ref images (+ index 1)))]
        [image (try (tlci.tlci-parse-image raw))]
        [old-base : i64 (tlci.tlci-read-u64 raw 88)]
        [new-base : i64 code.len]
        [table : i64
          (if (=
            (array-length image.entries)
            tlci.tlci-section-entry-record-size)
            (tlci.tlci-read-u64 (& image.entries) 16)
            -1)]
        (unless
          (and
            (= image.host-platform surface.host-platform)
            (= image.callback-abi-version surface.callback-abi-version)
            (string.eq image.compiler-build-hash surface.compiler-build-hash)
            (string.eq image.metadata.version surface.metadata.version)
            (string.eq
              image.metadata.package-name
              surface.metadata.package-name)
            (string.eq
              image.metadata.package-version
              surface.metadata.package-version)
            (= (array-length image.rodata) 0)
            (= (array-length image.entries) tlci.tlci-section-entry-record-size)
            (>= table 0)
            (<= table (- (array-length image.code) 40))
            (= (tlci.tlci-read-u64 (& image.code) table) 1))
          (return
            (Err "embedded stdlib tlci frames: inconsistent native image")))
        (let
          [name-offset : i64
            (- (tlci.tlci-read-u64 (& image.code) (+ table 8)) old-base)]
          [name-len : i64 (tlci.tlci-read-u64 (& image.code) (+ table 16))]
          [function : i64
            (- (tlci.tlci-read-u64 (& image.code) (+ table 24)) old-base)]
          (unless
            (and
              (>= function 0)
              (< function (array-length image.code))
              (>= name-offset 0)
              (>= name-len 0)
              (<= name-offset (array-length image.code))
              (<= name-len (- (array-length image.code) name-offset))
              (string.eq
                (tlci.tlci-bytes->string (& image.code) name-offset name-len)
                (array-ref names index)))
            (return
              (Err "embedded stdlib tlci frames: native identity mismatch"))))
        (set!
          (array-ref entries index)
          (+
            new-base
            (- (tlci.tlci-read-u64 (& image.code) (+ table 24)) old-base)))
        (for [slot (iterator.range 0 (/ (array-length image.fixups) 8))]
          (let
            [old-slot : i64
              (- (tlci.tlci-read-u64 (& image.fixups) (* slot 8)) old-base)]
            (unless
              (and
                (>= old-slot 0)
                (<= old-slot (- (array-length image.code) 8)))
              (return
                (Err "embedded stdlib tlci frames: fixup outside native code")))
            (let
              [target : i64
                (- (tlci.tlci-read-u64 (& image.code) old-slot) old-base)]
              (unless
                (and (>= target 0) (< target (array-length image.code)))
                (return
                  (Err
                    "embedded stdlib tlci frames: fixup target outside native code")))
              (tlci.tlci-set-u64!
                (&mut image.code)
                old-slot
                (+ new-base target)))
            (tlci.tlci-push-u64! (&mut fixups) (+ new-base old-slot))
            (+= fixup-count 1)))
        (for [slot
          (iterator.range 0 (tlci.tlci-import-section-count (& image.imports)))]
          (let
            [record : i64 (+ 8 (* slot 24))]
            [offset : i64 (tlci.tlci-read-u64 (& image.imports) (+ record 8))]
            [len : i64 (tlci.tlci-read-u64 (& image.imports) (+ record 16))]
            (tlci.tlci-push-u64!
              (&mut import-records)
              (+
                new-base
                (- (tlci.tlci-read-u64 (& image.imports) record) old-base)))
            (tlci.tlci-push-u64! (&mut import-records) import-names.len)
            (tlci.tlci-push-u64! (&mut import-records) len)
            (buf.byte-buf-builder-append-array-range
              (&mut import-names)
              (& image.imports)
              offset
              len)
            (+= import-count 1)))
        (buf.byte-buf-builder-append-array-range
          (&mut code)
          (& image.code)
          0
          (array-length image.code))
        (while (!= (% code.len 8) 0)
          (buf.byte-buf-builder-push (&mut code) (cast 0 : u8)))))
    (let
      [imports : buf.ByteBufBuilder (buf.byte-buf-builder-new)]
      [records : (__tl_dyn-array u8)
        (buf.byte-buf-builder-to-array (& import-records))]
      (when
        (> import-count 0)
        (tlci.tlci-push-u64! (&mut imports) import-count)
        (for [index (iterator.range 0 import-count)]
          (let
            [record : i64 (* index 24)]
            (tlci.tlci-set-u64!
              (&mut records)
              (+ record 8)
              (+
                8
                (* import-count 24)
                (tlci.tlci-read-u64 (& records) (+ record 8))))))
        (buf.byte-buf-builder-append-array-range
          (&mut imports)
          (& records)
          0
          (array-length records))
        (buf.byte-buf-builder-append-array-range
          (&mut imports)
          (& import-names.slots)
          0
          import-names.len))
      (let
        [fixup-bytes : (__tl_dyn-array u8)
          (buf.byte-buf-builder-to-array (& fixups))]
        [offsets : (__tl_dyn-array i64) (__tl_make-array i64 fixup-count)]
        (for [index (iterator.range 0 fixup-count)]
          (set!
            (array-ref offsets index)
            (tlci.tlci-read-u64 (& fixup-bytes) (* index 8))))
        (tlci.tlci-emit-native-package-image
          (& surface.metadata)
          surface.compiler-build-hash
          surface.host-platform
          (&
            (tlci.TlciNativePackageInput
              surface.rodata
              (buf.byte-buf-builder-to-array (& code))
              (buf.byte-buf-builder-to-array (& imports))
              offsets
              fixup-count
              (clone (view.compiler-owned-reference-shared-view names))
              entries
              count)))))))