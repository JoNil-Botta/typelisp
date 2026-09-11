;; compiler_sframe_v3.tl - bounded canonical GNU SFrame v3 codec.
;;
;; This module deliberately owns only the binary and semantic SFrame layer.  It
;; does not parse ELF, interpret relocations, choose live functions, or assign
;; final executable layout.  Callers supply the .sframe section address and
;; final function addresses.  The supported dialect is pinned below.
(import compiler_owned_view as owned_view)
(import stdlib.byte_buf_core)

(define compiler-sframe-v3-magic : i64
  0xdee2)
(define compiler-sframe-v3-version : i64
  3)
(define compiler-sframe-v3-abi-amd64-le : i64
  3)
(define compiler-sframe-v3-header-size : i64
  28)
(define compiler-sframe-v3-index-size : i64
  16)
(define compiler-sframe-v3-attribute-size : i64
  5)
(define compiler-sframe-v3-flag-sorted : i64
  0x1)
(define compiler-sframe-v3-flag-field-pcrel : i64
  0x4)
(define compiler-sframe-v3-supported-flags : i64
  0x5)
(define compiler-sframe-v3-dwarf-rbp : i64
  6)
(define compiler-sframe-v3-dwarf-rsp : i64
  7)

;; Stable public error categories.  New diagnostics get new codes; callers do
;; not need to compare prose.
(define compiler-sframe-v3-error-invalid-limits : i64
  1)
(define compiler-sframe-v3-error-input-limit : i64
  2)
(define compiler-sframe-v3-error-truncated : i64
  3)
(define compiler-sframe-v3-error-preamble : i64
  4)
(define compiler-sframe-v3-error-layout : i64
  5)
(define compiler-sframe-v3-error-function-limit : i64
  6)
(define compiler-sframe-v3-error-row-limit : i64
  7)
(define compiler-sframe-v3-error-allocation-limit : i64
  8)
(define compiler-sframe-v3-error-work-limit : i64
  9)
(define compiler-sframe-v3-error-function : i64
  10)
(define compiler-sframe-v3-error-attribute : i64
  11)
(define compiler-sframe-v3-error-row : i64
  12)
(define compiler-sframe-v3-error-address : i64
  13)
(define compiler-sframe-v3-error-output-limit : i64
  14)
(define compiler-sframe-v3-error-dialect : i64
  15)

(define (compiler-sframe-v3-dialect) : String
  "gnu-sframe-v3-binutils-2.47-amd64-le-v1")

;; Callers persist the textual dialect id in toolchain capabilities and pass
;; this compact policy revision at the codec boundary.  Unknown future
;; revisions fail closed instead of being interpreted as today's v3 profile.
(defstruct CompilerSframeV3Policy
  (dialect-revision i64))

(define (compiler-sframe-v3-policy) : CompilerSframeV3Policy
  (CompilerSframeV3Policy 1))

(define (compiler-sframe-v3-policy-valid?
  [policy : (& policy CompilerSframeV3Policy)]) : bool
  (= policy.dialect-revision 1))

;; All limits are caller-owned and checked before the corresponding allocation
;; or work.  `max-owned-bytes` is a conservative upper bound, not an arena
;; allocator accounting value.
(defstruct CompilerSframeV3Limits
  (max-input-bytes i64)
  (max-output-bytes i64)
  (max-functions i64)
  (max-rows i64)
  (max-owned-bytes i64)
  (max-work i64))

(define (compiler-sframe-v3-default-limits) : CompilerSframeV3Limits
  (CompilerSframeV3Limits 16777216 16777216 65535 1048576 134217728 8388608))

(defstruct CompilerSframeV3Error
  (code i64)
  (byte-offset i64)
  (message String))

;; A recovery rule is already semantic: fixed header rules and unavailable
;; values occupy no row data words; implicit rules are based on the CFA;
;; register rules name an AMD64 DWARF general-purpose register.  `deref?`
;; preserves the v3 flexible-control dereference bit.
(defenum CompilerSframeV3Rule
  (Unavailable)
  (Fixed i64)
  (Implicit bool i64)
  (Register i64 bool i64))

(defstruct CompilerSframeV3Row
  (start-offset i64)
  (outermost? bool)
  (cfa-register i64)
  (cfa-deref? bool)
  (cfa-offset i64)
  (ra-rule CompilerSframeV3Rule)
  (fp-rule CompilerSframeV3Rule))

(defstruct CompilerSframeV3Function
  ;; Absolute address supplied by the caller, or reconstructed at decode time.
  (start-address i64)
  (size i64)
  (mask-pc? bool)
  (repetition-size i64)
  (signal-frame? bool)
  (flex? bool)
  ;; Decode provenance needed by the linker to pair an input relocation with
  ;; its exact field.  Canonical encoding recomputes and ignores these fields.
  (index-byte-offset i64)
  (raw-start-addend i64)
  ;; Half-open span in CompilerSframeV3Image.rows.  A zero-length span on a
  ;; default increment FDE is the specified outermost-frame marker.
  (row-start i64)
  (row-count i64))

(defstruct CompilerSframeV3Image
  (fixed-fp-offset i64)
  (fixed-ra-offset i64)
  (sorted? bool)
  ;; Records whether the decoded input used field-PC-relative starts.  The
  ;; canonical encoder always writes true regardless of this value.
  (decoded-field-pcrel? bool)
  (functions (__tl_dyn-array CompilerSframeV3Function))
  ;; Rows are flat and image-owned.  This avoids borrowed or nested dynamic
  ;; array descriptors and makes allocation O(1) plus the two record arrays.
  (rows (__tl_dyn-array CompilerSframeV3Row)))

(defstruct CompilerSframeV3Plan
  (function-count i64)
  (row-count i64)
  (fre-bytes i64)
  (total-bytes i64))

(defenum ResultCompilerSframeV3Image
  (Err CompilerSframeV3Error)
  (Ok CompilerSframeV3Image))

(defenum ResultCompilerSframeV3Plan
  (Err CompilerSframeV3Error)
  (Ok CompilerSframeV3Plan))

(defenum ResultCompilerSframeV3Bytes
  (Err CompilerSframeV3Error)
  (Ok (__tl_dyn-array u8)))

(defenum ResultCompilerSframeV3Rule
  (Err CompilerSframeV3Error)
  (Ok CompilerSframeV3Rule))

(defenum ResultCompilerSframeV3RowIndex
  (Err CompilerSframeV3Error)
  (Ok i64))

(define (compiler-sframe-v3-error
  [code : i64]
  [offset : i64]
  [message : String]) : CompilerSframeV3Error
  (CompilerSframeV3Error code offset message))

(define (compiler-sframe-v3-limits-valid?
  [limits : (& limits CompilerSframeV3Limits)]) : bool
  (and
    (>= limits.max-input-bytes 0)
    (>= limits.max-output-bytes 0)
    (>= limits.max-functions 0)
    (>= limits.max-rows 0)
    (>= limits.max-owned-bytes 0)
    (>= limits.max-work 0)))

(define (compiler-sframe-v3-range-present?
  [length : i64]
  [start : i64]
  [count : i64]) : bool
  (and (>= start 0) (>= count 0) (<= start length) (<= count (- length start))))

(define (compiler-sframe-v3-read-u8
  [bytes : (& bytes (__tl_dyn-array u8))]
  [offset : i64]) : i64
  (cast (array-ref bytes offset) : i64))

(define (compiler-sframe-v3-read-u16
  [bytes : (& bytes (__tl_dyn-array u8))]
  [offset : i64]) : i64
  (+
    (compiler-sframe-v3-read-u8 bytes offset)
    (shl (compiler-sframe-v3-read-u8 bytes (+ offset 1)) 8)))

(define (compiler-sframe-v3-read-u32
  [bytes : (& bytes (__tl_dyn-array u8))]
  [offset : i64]) : i64
  (+
    (compiler-sframe-v3-read-u16 bytes offset)
    (shl (compiler-sframe-v3-read-u16 bytes (+ offset 2)) 16)))

(define (compiler-sframe-v3-read-i64
  [bytes : (& bytes (__tl_dyn-array u8))]
  [offset : i64]) : i64
  (let
    [value : u64 (cast 0 : u64)]
    [index : i64 0]
    (begin
      (while (< index 8)
        (begin
          (set!
            value
            (bit-or
              value
              (shl
                (cast (compiler-sframe-v3-read-u8 bytes (+ offset index)) : u64)
                (* index 8))))
          (set! index (+ index 1))))
      (cast value : i64))))

(define (compiler-sframe-v3-sign-extend [value : i64] [width : i64]) : i64
  (cond
    [(= width 1)
      (if (>= value 128)
        (- value 256)
        value)]
    [(= width 2)
      (if (>= value 32768)
        (- value 65536)
        value)]
    [(= width 4)
      (if (>= value 2147483648)
        (- value 4294967296)
        value)]
    [else value]))

(define (compiler-sframe-v3-read-unsigned-word
  [bytes : (& bytes (__tl_dyn-array u8))]
  [offset : i64]
  [width : i64]) : i64
  (cond
    [(= width 1) (compiler-sframe-v3-read-u8 bytes offset)]
    [(= width 2) (compiler-sframe-v3-read-u16 bytes offset)]
    [else (compiler-sframe-v3-read-u32 bytes offset)]))

(define (compiler-sframe-v3-read-signed-word
  [bytes : (& bytes (__tl_dyn-array u8))]
  [offset : i64]
  [width : i64]) : i64
  (compiler-sframe-v3-sign-extend
    (compiler-sframe-v3-read-unsigned-word bytes offset width)
    width))

(define (compiler-sframe-v3-i8 [value : i64]) : i64
  (compiler-sframe-v3-sign-extend value 1))

;; Keep address arithmetic away from the signed endpoints.  Real AMD64 image
;; addresses fit this domain; using it makes all three-term additions explicit
;; and portable through the bootstrap compiler.
(define (compiler-sframe-v3-safe-address? [value : i64]) : bool
  (and (>= value (- 0 4611686018427387904)) (<= value 4611686018427387903)))

(define (compiler-sframe-v3-safe-add? [left : i64] [right : i64]) : bool
  (and
    (compiler-sframe-v3-safe-address? left)
    (compiler-sframe-v3-safe-address? right)
    (if (>= right 0)
      (<= left (- 4611686018427387903 right))
      (>= left (- (- 0 4611686018427387904) right)))))

(define (compiler-sframe-v3-owned-estimate-ok?
  [function-count : i64]
  [row-count : i64]
  [limit : i64]) : bool
  ;; 192 and 128 are deliberately conservative upper bounds for each owned
  ;; function and row record, including array headers and alignment.
  (and
    (<= function-count (/ limit 192))
    (<= row-count (/ (- limit (* function-count 192)) 128))))

(define (compiler-sframe-v3-supported-register? [register : i64]) : bool
  ;; AMD64 DWARF general-purpose registers plus RIP.  Vector/control registers
  ;; are intentionally outside this linker's unwind contract.
  (and (>= register 0) (<= register 16)))

(define (compiler-sframe-v3-fallback-rule [fixed : i64]) : CompilerSframeV3Rule
  (if (= fixed 0)
    (CompilerSframeV3Rule.Unavailable)
    (CompilerSframeV3Rule.Fixed fixed)))

(define (compiler-sframe-v3-rule-is-register?
  [rule : (& rule CompilerSframeV3Rule)]) : bool
  (match (owned_view.compiler-owned-reference-shared-view rule)
    [(CompilerSframeV3Rule.Register _ _ _) true]
    [_ false]))

(define (compiler-sframe-v3-decode-flex-rule
  [control : i64]
  [offset : i64]
  [byte-offset : i64]) : ResultCompilerSframeV3Rule
  (let
    [register-present? : bool (!= (bit-and control 1) 0)]
    [deref? : bool (!= (bit-and control 2) 0)]
    [register : i64 (shr control 3)]
    (cond
      [(= control 0)
        (ResultCompilerSframeV3Rule.Err
          (compiler-sframe-v3-error
            compiler-sframe-v3-error-row
            byte-offset
            "sframe v3: zero flexible control is padding, not a rule"))]
      [(!= (bit-and control 4) 0)
        (ResultCompilerSframeV3Rule.Err
          (compiler-sframe-v3-error
            compiler-sframe-v3-error-row
            byte-offset
            "sframe v3: reserved flexible control bit is set"))]
      [(and (not register-present?) (!= register 0))
        (ResultCompilerSframeV3Rule.Err
          (compiler-sframe-v3-error
            compiler-sframe-v3-error-row
            byte-offset
            "sframe v3: implicit flexible rule names a register"))]
      [(and
          register-present?
          (not (compiler-sframe-v3-supported-register? register)))
        (ResultCompilerSframeV3Rule.Err
          (compiler-sframe-v3-error
            compiler-sframe-v3-error-row
            byte-offset
            "sframe v3: unsupported AMD64 DWARF register"))]
      [register-present?
        (ResultCompilerSframeV3Rule.Ok
          (CompilerSframeV3Rule.Register register deref? offset))]
      [else
        (ResultCompilerSframeV3Rule.Ok
          (CompilerSframeV3Rule.Implicit deref? offset))])))

(define (compiler-sframe-v3-row-start-width [function-size : i64]) : i64
  (cond [(< function-size 256) 1] [(< function-size 65536) 2] [else 4]))

(define (compiler-sframe-v3-type-for-width [width : i64]) : i64
  (cond [(= width 1) 0] [(= width 2) 1] [else 2]))

(define (compiler-sframe-v3-width-for-type [fre-type : i64]) : i64
  (cond [(= fre-type 0) 1] [(= fre-type 1) 2] [else 4]))

(define (compiler-sframe-v3-data-width [min-value : i64] [max-value : i64]) : i64
  (cond
    [(and (>= min-value -128) (<= max-value 127)) 1]
    [(and (>= min-value -32768) (<= max-value 32767)) 2]
    [else 4]))

(define (compiler-sframe-v3-byte [value : i64]) : u8
  (cast (bit-and value 255) : u8))

(define (compiler-sframe-v3-push-u8!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [value : i64]) : unit
  (byte_buf_core.byte-buf-builder-push out (compiler-sframe-v3-byte value)))

(define (compiler-sframe-v3-push-u16!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [value : i64]) : unit
  (begin
    (compiler-sframe-v3-push-u8! out value)
    (compiler-sframe-v3-push-u8! out (shr value 8))))

(define (compiler-sframe-v3-push-u32!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [value : i64]) : unit
  (begin
    (compiler-sframe-v3-push-u16! out value)
    (compiler-sframe-v3-push-u16! out (shr value 16))))

(define (compiler-sframe-v3-push-i64!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [value : i64]) : unit
  (let
    [bits : u64 (cast value : u64)]
    [index : i64 0]
    (while (< index 8)
      (begin
        (compiler-sframe-v3-push-u8!
          out
          (cast (bit-and (shr bits (* index 8)) (cast 255 : u64)) : i64))
        (set! index (+ index 1))))))

(define (compiler-sframe-v3-push-word!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [value : i64]
  [width : i64]) : unit
  (let
    [index : i64 0]
    (while (< index width)
      (begin
        (compiler-sframe-v3-push-u8! out (shr value (* index 8)))
        (set! index (+ index 1))))))

(define (compiler-sframe-v3-rule-control [rule : (& rule CompilerSframeV3Rule)]) : i64
  (match (owned_view.compiler-owned-reference-shared-view rule)
    [(CompilerSframeV3Rule.Implicit deref? _)
      (if deref?
        2
        0)]
    [(CompilerSframeV3Rule.Register register deref? _)
      (+
        (shl register 3)
        (+
          (if deref?
            2
            0)
          1))]
    [_ 0]))

(define (compiler-sframe-v3-rule-offset [rule : (& rule CompilerSframeV3Rule)]) : i64
  (match (owned_view.compiler-owned-reference-shared-view rule)
    [(CompilerSframeV3Rule.Implicit _ offset) offset]
    [(CompilerSframeV3Rule.Register _ _ offset) offset]
    [(CompilerSframeV3Rule.Fixed offset) offset]
    [_ 0]))

(define (compiler-sframe-v3-rule-omitted-valid?
  [rule : (& rule CompilerSframeV3Rule)]
  [fixed : i64]) : bool
  (match (owned_view.compiler-owned-reference-shared-view rule)
    [(CompilerSframeV3Rule.Unavailable) (= fixed 0)]
    [(CompilerSframeV3Rule.Fixed value) (and (!= fixed 0) (= value fixed))]
    [_ false]))

;: Decode one exact `.sframe` section into caller-independent owned records.
(define (compiler-sframe-v3-decode
  [bytes : (& bytes (__tl_dyn-array u8))]
  [section-address : i64]
  [limits : (& limits CompilerSframeV3Limits)]) : ResultCompilerSframeV3Image
  (let
    [length : i64 (array-length bytes)]
    (begin
      (when
        (not (compiler-sframe-v3-limits-valid? limits))
        (return
          (ResultCompilerSframeV3Image.Err
            (compiler-sframe-v3-error
              compiler-sframe-v3-error-invalid-limits
              0
              "sframe v3: invalid decoder limits"))))
      (when
        (> length limits.max-input-bytes)
        (return
          (ResultCompilerSframeV3Image.Err
            (compiler-sframe-v3-error
              compiler-sframe-v3-error-input-limit
              0
              "sframe v3: input byte limit exceeded"))))
      (when
        (< length compiler-sframe-v3-header-size)
        (return
          (ResultCompilerSframeV3Image.Err
            (compiler-sframe-v3-error
              compiler-sframe-v3-error-truncated
              length
              "sframe v3: truncated header"))))
      (when
        (or
          (!= (compiler-sframe-v3-read-u16 bytes 0) compiler-sframe-v3-magic)
          (!= (compiler-sframe-v3-read-u8 bytes 2) compiler-sframe-v3-version))
        (return
          (ResultCompilerSframeV3Image.Err
            (compiler-sframe-v3-error
              compiler-sframe-v3-error-preamble
              0
              "sframe v3: unsupported magic or version"))))
      (let
        [flags : i64 (compiler-sframe-v3-read-u8 bytes 3)]
        [abi : i64 (compiler-sframe-v3-read-u8 bytes 4)]
        [fixed-fp : i64
          (compiler-sframe-v3-i8 (compiler-sframe-v3-read-u8 bytes 5))]
        [fixed-ra : i64
          (compiler-sframe-v3-i8 (compiler-sframe-v3-read-u8 bytes 6))]
        [aux-length : i64 (compiler-sframe-v3-read-u8 bytes 7)]
        [function-count : i64 (compiler-sframe-v3-read-u32 bytes 8)]
        [declared-row-count : i64 (compiler-sframe-v3-read-u32 bytes 12)]
        [fre-bytes : i64 (compiler-sframe-v3-read-u32 bytes 16)]
        [fde-offset : i64 (compiler-sframe-v3-read-u32 bytes 20)]
        [fre-offset : i64 (compiler-sframe-v3-read-u32 bytes 24)]
        [index-bytes : i64 (* function-count compiler-sframe-v3-index-size)]
        [fde-start : i64 (+ compiler-sframe-v3-header-size fde-offset)]
        [fre-start : i64 (+ compiler-sframe-v3-header-size fre-offset)]
        (begin
          (when
            (!=
              (bit-and flags (bit-xor compiler-sframe-v3-supported-flags 255))
              0)
            (return
              (ResultCompilerSframeV3Image.Err
                (compiler-sframe-v3-error
                  compiler-sframe-v3-error-preamble
                  3
                  "sframe v3: unsupported header flags"))))
          (when
            (!= abi compiler-sframe-v3-abi-amd64-le)
            (return
              (ResultCompilerSframeV3Image.Err
                (compiler-sframe-v3-error
                  compiler-sframe-v3-error-preamble
                  4
                  "sframe v3: unsupported ABI or byte order"))))
          (when
            (!= aux-length 0)
            (return
              (ResultCompilerSframeV3Image.Err
                (compiler-sframe-v3-error
                  compiler-sframe-v3-error-preamble
                  7
                  "sframe v3: auxiliary headers are outside the pinned dialect"))))
          (when
            (> function-count limits.max-functions)
            (return
              (ResultCompilerSframeV3Image.Err
                (compiler-sframe-v3-error
                  compiler-sframe-v3-error-function-limit
                  8
                  "sframe v3: function count limit exceeded"))))
          (when
            (> declared-row-count limits.max-rows)
            (return
              (ResultCompilerSframeV3Image.Err
                (compiler-sframe-v3-error
                  compiler-sframe-v3-error-row-limit
                  12
                  "sframe v3: row count limit exceeded"))))
          (when
            (or
              (> function-count limits.max-work)
              (> declared-row-count (/ (- limits.max-work function-count) 8)))
            (return
              (ResultCompilerSframeV3Image.Err
                (compiler-sframe-v3-error
                  compiler-sframe-v3-error-work-limit
                  8
                  "sframe v3: decode work limit exceeded"))))
          (when
            (not
              (compiler-sframe-v3-owned-estimate-ok?
                function-count
                declared-row-count
                limits.max-owned-bytes))
            (return
              (ResultCompilerSframeV3Image.Err
                (compiler-sframe-v3-error
                  compiler-sframe-v3-error-allocation-limit
                  8
                  "sframe v3: owned allocation limit exceeded"))))
          ;; The pinned canonical dialect has no auxiliary bytes or padding:
          ;; index and FRE subsections are adjacent and consume the section.
          (when
            (or
              (!= fde-offset 0)
              (!= fre-offset index-bytes)
              (not
                (compiler-sframe-v3-range-present? length fde-start index-bytes))
              (not
                (compiler-sframe-v3-range-present? length fre-start fre-bytes))
              (!= (+ fre-start fre-bytes) length))
            (return
              (ResultCompilerSframeV3Image.Err
                (compiler-sframe-v3-error
                  compiler-sframe-v3-error-layout
                  20
                  "sframe v3: non-canonical or out-of-range subsection layout"))))
          (when
            (or
              (< section-address 0)
              (not (compiler-sframe-v3-safe-address? section-address)))
            (return
              (ResultCompilerSframeV3Image.Err
                (compiler-sframe-v3-error
                  compiler-sframe-v3-error-address
                  0
                  "sframe v3: section address is outside the supported range"))))
          (let
            [functions : (__tl_dyn-array CompilerSframeV3Function)
              (__tl_make-array CompilerSframeV3Function function-count)]
            [rows : (__tl_dyn-array CompilerSframeV3Row)
              (__tl_make-array CompilerSframeV3Row declared-row-count)]
            [function-index : i64 0]
            [fre-cursor : i64 0]
            [decoded-rows : i64 0]
            [previous-function-start : i64 0]
            [field-pcrel? : bool
              (!= (bit-and flags compiler-sframe-v3-flag-field-pcrel) 0)]
            [sorted? : bool
              (!= (bit-and flags compiler-sframe-v3-flag-sorted) 0)]
            (begin
              (while (< function-index function-count)
                (let
                  [index-offset : i64
                    (+
                      fde-start
                      (* function-index compiler-sframe-v3-index-size))]
                  [raw-start : i64
                    (compiler-sframe-v3-read-i64 bytes index-offset)]
                  [function-size : i64
                    (compiler-sframe-v3-read-u32 bytes (+ index-offset 8))]
                  [function-fre-offset : i64
                    (compiler-sframe-v3-read-u32 bytes (+ index-offset 12))]
                  [start-base-offset : i64
                    (if field-pcrel?
                      index-offset
                      fde-start)]
                  (begin
                    (when
                      (!= function-fre-offset fre-cursor)
                      (return
                        (ResultCompilerSframeV3Image.Err
                          (compiler-sframe-v3-error
                            compiler-sframe-v3-error-layout
                            (+ index-offset 12)
                            "sframe v3: function FRE intervals do not tile the subsection"))))
                    (when
                      (= function-size 0)
                      (return
                        (ResultCompilerSframeV3Image.Err
                          (compiler-sframe-v3-error
                            compiler-sframe-v3-error-function
                            (+ index-offset 8)
                            "sframe v3: zero-sized function"))))
                    (when
                      (or
                        (not
                          (compiler-sframe-v3-safe-add?
                            section-address
                            start-base-offset))
                        (not
                          (compiler-sframe-v3-safe-add?
                            (+ section-address start-base-offset)
                            raw-start)))
                      (return
                        (ResultCompilerSframeV3Image.Err
                          (compiler-sframe-v3-error
                            compiler-sframe-v3-error-address
                            index-offset
                            "sframe v3: function start address overflows"))))
                    (let
                      [function-start : i64
                        (+ (+ section-address start-base-offset) raw-start)]
                      [attribute-offset : i64 (+ fre-start fre-cursor)]
                      (begin
                        (when
                          (or
                            (< function-start 0)
                            (not
                              (compiler-sframe-v3-safe-add?
                                function-start
                                function-size)))
                          (return
                            (ResultCompilerSframeV3Image.Err
                              (compiler-sframe-v3-error
                                compiler-sframe-v3-error-address
                                index-offset
                                "sframe v3: function address interval overflows"))))
                        (when
                          (and
                            sorted?
                            (> function-index 0)
                            (<= function-start previous-function-start))
                          (return
                            (ResultCompilerSframeV3Image.Err
                              (compiler-sframe-v3-error
                                compiler-sframe-v3-error-function
                                index-offset
                                "sframe v3: sorted function starts are not strictly increasing"))))
                        (when
                          (not
                            (compiler-sframe-v3-range-present?
                              (+ fre-start fre-bytes)
                              attribute-offset
                              compiler-sframe-v3-attribute-size))
                          (return
                            (ResultCompilerSframeV3Image.Err
                              (compiler-sframe-v3-error
                                compiler-sframe-v3-error-truncated
                                attribute-offset
                                "sframe v3: truncated function attributes"))))
                        (let
                          [function-row-count : i64
                            (compiler-sframe-v3-read-u16 bytes attribute-offset)]
                          [info : i64
                            (compiler-sframe-v3-read-u8
                              bytes
                              (+ attribute-offset 2))]
                          [info2 : i64
                            (compiler-sframe-v3-read-u8
                              bytes
                              (+ attribute-offset 3))]
                          [repetition-size : i64
                            (compiler-sframe-v3-read-u8
                              bytes
                              (+ attribute-offset 4))]
                          [fre-type : i64 (bit-and info 15)]
                          [mask-pc? : bool (!= (bit-and info 16) 0)]
                          [signal-frame? : bool (!= (bit-and info 128) 0)]
                          [fde-type : i64 (bit-and info2 31)]
                          [flex? : bool (= fde-type 1)]
                          (begin
                            (when
                              (>
                                function-row-count
                                (- declared-row-count decoded-rows))
                              (return
                                (ResultCompilerSframeV3Image.Err
                                  (compiler-sframe-v3-error
                                    compiler-sframe-v3-error-row-limit
                                    attribute-offset
                                    "sframe v3: function row count disagrees with the header"))))
                            (when
                              (or
                                (> fre-type 2)
                                (!= (bit-and info 96) 0)
                                (> fde-type 1)
                                (!= (bit-and info2 224) 0))
                              (return
                                (ResultCompilerSframeV3Image.Err
                                  (compiler-sframe-v3-error
                                    compiler-sframe-v3-error-attribute
                                    (+ attribute-offset 2)
                                    "sframe v3: reserved or unsupported function attributes"))))
                            (when
                              (if mask-pc?
                                (or
                                  (= repetition-size 0)
                                  (> repetition-size function-size))
                                (!= repetition-size 0))
                              (return
                                (ResultCompilerSframeV3Image.Err
                                  (compiler-sframe-v3-error
                                    compiler-sframe-v3-error-attribute
                                    (+ attribute-offset 4)
                                    "sframe v3: invalid repetition size for function PC type"))))
                            (when
                              (and (= function-row-count 0) (or flex? mask-pc?))
                              (return
                                (ResultCompilerSframeV3Image.Err
                                  (compiler-sframe-v3-error
                                    compiler-sframe-v3-error-attribute
                                    attribute-offset
                                    "sframe v3: only an increment/default FDE may be an outermost zero-FRE marker"))))
                            (let
                              [row-index : i64 0]
                              [row-cursor : i64
                                (+ fre-cursor compiler-sframe-v3-attribute-size)]
                              [previous-row-start : i64 0]
                              [start-width : i64
                                (compiler-sframe-v3-width-for-type fre-type)]
                              (begin
                                (while (< row-index function-row-count)
                                  (let
                                    [row-byte-offset : i64
                                      (+ fre-start row-cursor)]
                                    (begin
                                      (when
                                        (not
                                          (compiler-sframe-v3-range-present?
                                            (+ fre-start fre-bytes)
                                            row-byte-offset
                                            (+ start-width 1)))
                                        (return
                                          (ResultCompilerSframeV3Image.Err
                                            (compiler-sframe-v3-error
                                              compiler-sframe-v3-error-truncated
                                              row-byte-offset
                                              "sframe v3: truncated frame row header"))))
                                      (let
                                        [row-start : i64
                                          (compiler-sframe-v3-read-unsigned-word
                                            bytes
                                            row-byte-offset
                                            start-width)]
                                        [row-info : i64
                                          (compiler-sframe-v3-read-u8
                                            bytes
                                            (+ row-byte-offset start-width))]
                                        [word-count : i64
                                          (bit-and (shr row-info 1) 15)]
                                        [word-type : i64
                                          (bit-and (shr row-info 5) 3)]
                                        [word-width : i64
                                          (if (= (bit-and (shr row-info 5) 3) 0)
                                            1
                                            (if (=
                                              (bit-and (shr row-info 5) 3)
                                              1)
                                              2
                                              4))]
                                        [data-offset : i64
                                          (+ row-byte-offset (+ start-width 1))]
                                        (begin
                                          (when
                                            (or
                                              (= word-type 3)
                                              (!= (bit-and row-info 128) 0))
                                            (return
                                              (ResultCompilerSframeV3Image.Err
                                                (compiler-sframe-v3-error
                                                  compiler-sframe-v3-error-row
                                                  (+
                                                    row-byte-offset
                                                    start-width)
                                                  "sframe v3: unsupported frame row info bits"))))
                                          (when
                                            (not
                                              (compiler-sframe-v3-range-present?
                                                (+ fre-start fre-bytes)
                                                data-offset
                                                (* word-count word-width)))
                                            (return
                                              (ResultCompilerSframeV3Image.Err
                                                (compiler-sframe-v3-error
                                                  compiler-sframe-v3-error-truncated
                                                  data-offset
                                                  "sframe v3: truncated frame row data words"))))
                                          (when
                                            (or
                                              (and
                                                (= row-index 0)
                                                (!= row-start 0))
                                              (and
                                                (> row-index 0)
                                                (<=
                                                  row-start
                                                  previous-row-start)))
                                            (return
                                              (ResultCompilerSframeV3Image.Err
                                                (compiler-sframe-v3-error
                                                  compiler-sframe-v3-error-row
                                                  row-byte-offset
                                                  "sframe v3: row starts are not strictly increasing from zero"))))
                                          (when
                                            (if mask-pc?
                                              (>= row-start repetition-size)
                                              (>= row-start function-size))
                                            (return
                                              (ResultCompilerSframeV3Image.Err
                                                (compiler-sframe-v3-error
                                                  compiler-sframe-v3-error-row
                                                  row-byte-offset
                                                  "sframe v3: row start is outside its lookup interval"))))
                                          (let
                                            [outermost? : bool false]
                                            [cfa-register : i64 0]
                                            [cfa-deref? : bool false]
                                            [cfa-offset : i64 0]
                                            [ra-rule : CompilerSframeV3Rule
                                              (compiler-sframe-v3-fallback-rule
                                                fixed-ra)]
                                            [fp-rule : CompilerSframeV3Rule
                                              (compiler-sframe-v3-fallback-rule
                                                fixed-fp)]
                                            (begin
                                              (if flex?
                                                (begin
                                                  (when
                                                    (or
                                                      (!=
                                                        (bit-and row-info 1)
                                                        0)
                                                      (not
                                                        (or
                                                          (= word-count 2)
                                                          (= word-count 4)
                                                          (= word-count 5)
                                                          (= word-count 6))))
                                                    (return
                                                      (ResultCompilerSframeV3Image.Err
                                                        (compiler-sframe-v3-error
                                                          compiler-sframe-v3-error-row
                                                          (+
                                                            row-byte-offset
                                                            start-width)
                                                          "sframe v3: invalid flexible row shape"))))
                                                  (let
                                                    [cfa-control : i64
                                                      (compiler-sframe-v3-read-unsigned-word
                                                        bytes
                                                        data-offset
                                                        word-width)]
                                                    [cfa-data : i64
                                                      (compiler-sframe-v3-read-signed-word
                                                        bytes
                                                        (+
                                                          data-offset
                                                          word-width)
                                                        word-width)]
                                                    (match (compiler-sframe-v3-decode-flex-rule
                                                      cfa-control
                                                      cfa-data
                                                      data-offset)
                                                      [(ResultCompilerSframeV3Rule.Err
                                                          error)
                                                        (return
                                                          (ResultCompilerSframeV3Image.Err
                                                            error))]
                                                      [(ResultCompilerSframeV3Rule.Ok
                                                          rule)
                                                        (match rule
                                                          [(CompilerSframeV3Rule.Register
                                                              register
                                                              deref?
                                                              offset)
                                                            (begin
                                                              (set!
                                                                cfa-register
                                                                register)
                                                              (set!
                                                                cfa-deref?
                                                                deref?)
                                                              (set!
                                                                cfa-offset
                                                                offset))]
                                                          [_
                                                            (return
                                                              (ResultCompilerSframeV3Image.Err
                                                                (compiler-sframe-v3-error
                                                                  compiler-sframe-v3-error-row
                                                                  data-offset
                                                                  "sframe v3: flexible CFA rule must name a register")))])]))
                                                  (when
                                                    (or
                                                      (= word-count 4)
                                                      (= word-count 6))
                                                    (match (compiler-sframe-v3-decode-flex-rule
                                                      (compiler-sframe-v3-read-unsigned-word
                                                        bytes
                                                        (+
                                                          data-offset
                                                          (* 2 word-width))
                                                        word-width)
                                                      (compiler-sframe-v3-read-signed-word
                                                        bytes
                                                        (+
                                                          data-offset
                                                          (* 3 word-width))
                                                        word-width)
                                                      (+
                                                        data-offset
                                                        (* 2 word-width)))
                                                      [(ResultCompilerSframeV3Rule.Err
                                                          error)
                                                        (return
                                                          (ResultCompilerSframeV3Image.Err
                                                            error))]
                                                      [(ResultCompilerSframeV3Rule.Ok
                                                          rule)
                                                        (set! ra-rule rule)]))
                                                  (when
                                                    (= word-count 5)
                                                    (begin
                                                      (when
                                                        (!=
                                                          (compiler-sframe-v3-read-unsigned-word
                                                            bytes
                                                            (+
                                                              data-offset
                                                              (* 2 word-width))
                                                            word-width)
                                                          0)
                                                        (return
                                                          (ResultCompilerSframeV3Image.Err
                                                            (compiler-sframe-v3-error
                                                              compiler-sframe-v3-error-row
                                                              (+
                                                                data-offset
                                                                (* 2 word-width))
                                                              "sframe v3: nonzero flexible RA padding"))))
                                                      (match (compiler-sframe-v3-decode-flex-rule
                                                        (compiler-sframe-v3-read-unsigned-word
                                                          bytes
                                                          (+
                                                            data-offset
                                                            (* 3 word-width))
                                                          word-width)
                                                        (compiler-sframe-v3-read-signed-word
                                                          bytes
                                                          (+
                                                            data-offset
                                                            (* 4 word-width))
                                                          word-width)
                                                        (+
                                                          data-offset
                                                          (* 3 word-width)))
                                                        [(ResultCompilerSframeV3Rule.Err
                                                            error)
                                                          (return
                                                            (ResultCompilerSframeV3Image.Err
                                                              error))]
                                                        [(ResultCompilerSframeV3Rule.Ok
                                                            rule)
                                                          (set! fp-rule rule)])))
                                                  (when
                                                    (= word-count 6)
                                                    (match (compiler-sframe-v3-decode-flex-rule
                                                      (compiler-sframe-v3-read-unsigned-word
                                                        bytes
                                                        (+
                                                          data-offset
                                                          (* 4 word-width))
                                                        word-width)
                                                      (compiler-sframe-v3-read-signed-word
                                                        bytes
                                                        (+
                                                          data-offset
                                                          (* 5 word-width))
                                                        word-width)
                                                      (+
                                                        data-offset
                                                        (* 4 word-width)))
                                                      [(ResultCompilerSframeV3Rule.Err
                                                          error)
                                                        (return
                                                          (ResultCompilerSframeV3Image.Err
                                                            error))]
                                                      [(ResultCompilerSframeV3Rule.Ok
                                                          rule)
                                                        (set! fp-rule rule)])))
                                                (if (= word-count 0)
                                                  (begin
                                                    (when
                                                      (!= row-info 0)
                                                      (return
                                                        (ResultCompilerSframeV3Image.Err
                                                          (compiler-sframe-v3-error
                                                            compiler-sframe-v3-error-row
                                                            (+
                                                              row-byte-offset
                                                              start-width)
                                                            "sframe v3: non-canonical outermost marker"))))
                                                    (set! outermost? true)
                                                    (set!
                                                      ra-rule
                                                      (CompilerSframeV3Rule.Unavailable))
                                                    (set!
                                                      fp-rule
                                                      (CompilerSframeV3Rule.Unavailable)))
                                                  (begin
                                                    (when
                                                      (or
                                                        (> word-count 2)
                                                        (= fixed-ra 0))
                                                      (return
                                                        (ResultCompilerSframeV3Image.Err
                                                          (compiler-sframe-v3-error
                                                            compiler-sframe-v3-error-row
                                                            (+
                                                              row-byte-offset
                                                              start-width)
                                                            "sframe v3: invalid AMD64 default row shape"))))
                                                    (set!
                                                      cfa-register
                                                      (if (=
                                                        (bit-and row-info 1)
                                                        0)
                                                        compiler-sframe-v3-dwarf-rbp
                                                        compiler-sframe-v3-dwarf-rsp))
                                                    (set!
                                                      cfa-offset
                                                      (compiler-sframe-v3-read-signed-word
                                                        bytes
                                                        data-offset
                                                        word-width))
                                                    (when
                                                      (= word-count 2)
                                                      (set!
                                                        fp-rule
                                                        (CompilerSframeV3Rule.Implicit
                                                          true
                                                          (compiler-sframe-v3-read-signed-word
                                                            bytes
                                                            (+
                                                              data-offset
                                                              word-width)
                                                            word-width)))))))
                                              (set!
                                                (array-ref
                                                  rows
                                                  (+ decoded-rows row-index))
                                                (CompilerSframeV3Row
                                                  row-start
                                                  outermost?
                                                  cfa-register
                                                  cfa-deref?
                                                  cfa-offset
                                                  ra-rule
                                                  fp-rule))
                                              (set!
                                                previous-row-start
                                                row-start)
                                              (set!
                                                row-cursor
                                                (+
                                                  row-cursor
                                                  (+
                                                    (+ start-width 1)
                                                    (* word-count word-width))))
                                              (set! row-index (+ row-index 1)))))))))
                                (set! fre-cursor row-cursor)
                                (set!
                                  (array-ref functions function-index)
                                  (CompilerSframeV3Function
                                    function-start
                                    function-size
                                    mask-pc?
                                    repetition-size
                                    signal-frame?
                                    flex?
                                    index-offset
                                    raw-start
                                    decoded-rows
                                    function-row-count))
                                (set!
                                  decoded-rows
                                  (+ decoded-rows function-row-count)))))
                          (set! previous-function-start function-start)))
                      (set! function-index (+ function-index 1))))))
              (when
                (or
                  (!= decoded-rows declared-row-count)
                  (!= fre-cursor fre-bytes))
                (return
                  (ResultCompilerSframeV3Image.Err
                    (compiler-sframe-v3-error
                      compiler-sframe-v3-error-layout
                      (+ fre-start fre-cursor)
                      "sframe v3: FRE records do not exactly tile the subsection"))))
              (ResultCompilerSframeV3Image.Ok
                (CompilerSframeV3Image
                  fixed-fp
                  fixed-ra
                  sorted?
                  field-pcrel?
                  functions
                  rows)))))))))

(defstruct CompilerSframeV3RowPlan
  (word-count i64)
  (word-width i64)
  (encoded-size i64))

(defenum ResultCompilerSframeV3RowPlan
  (Err CompilerSframeV3Error)
  (Ok CompilerSframeV3RowPlan))

(define (compiler-sframe-v3-signed-word-width [value : i64]) : i64
  (cond
    [(and (>= value -128) (<= value 127)) 1]
    [(and (>= value -32768) (<= value 32767)) 2]
    [(and (>= value -2147483648) (<= value 2147483647)) 4]
    [else 0]))

(define (compiler-sframe-v3-unsigned-word-width [value : i64]) : i64
  (cond
    [(and (>= value 0) (<= value 255)) 1]
    [(<= value 65535) 2]
    [(<= value 4294967295) 4]
    [else 0]))

(define (compiler-sframe-v3-max [left : i64] [right : i64]) : i64
  (if (> left right)
    left
    right))

(define (compiler-sframe-v3-rule-data-width
  [rule : (& rule CompilerSframeV3Rule)]) : i64
  (match (owned_view.compiler-owned-reference-shared-view rule)
    [(CompilerSframeV3Rule.Implicit _ offset)
      (compiler-sframe-v3-max
        (compiler-sframe-v3-unsigned-word-width
          (compiler-sframe-v3-rule-control rule))
        (compiler-sframe-v3-signed-word-width offset))]
    [(CompilerSframeV3Rule.Register register _ offset)
      (if (not (compiler-sframe-v3-supported-register? register))
        0
        (compiler-sframe-v3-max
          (compiler-sframe-v3-unsigned-word-width
            (compiler-sframe-v3-rule-control rule))
          (compiler-sframe-v3-signed-word-width offset)))]
    [_ 0]))

(define (compiler-sframe-v3-rule-has-row-data?
  [rule : (& rule CompilerSframeV3Rule)]) : bool
  (match (owned_view.compiler-owned-reference-shared-view rule)
    [(CompilerSframeV3Rule.Implicit _ _) true]
    [(CompilerSframeV3Rule.Register _ _ _) true]
    [_ false]))

(define (compiler-sframe-v3-flex-data-rule-valid?
  [rule : (& rule CompilerSframeV3Rule)]) : bool
  (match (owned_view.compiler-owned-reference-shared-view rule)
    ;; Control zero is reserved for an omitted/padding word, so CFA-relative
    ;; rules carried as a control/offset pair must set the dereference bit.
    [(CompilerSframeV3Rule.Implicit deref? _) deref?]
    [(CompilerSframeV3Rule.Register register _ _)
      (compiler-sframe-v3-supported-register? register)]
    [_ false]))

(define (compiler-sframe-v3-row-plan
  [row : (& row CompilerSframeV3Row)]
  [flex? : bool]
  [fixed-fp : i64]
  [fixed-ra : i64]
  [start-width : i64]) : ResultCompilerSframeV3RowPlan
  (if flex?
    (let
      [ra-data? : bool (compiler-sframe-v3-rule-has-row-data? (& row.ra-rule))]
      [fp-data? : bool (compiler-sframe-v3-rule-has-row-data? (& row.fp-rule))]
      [cfa-control-width : i64
        (compiler-sframe-v3-unsigned-word-width
          (+
            (shl row.cfa-register 3)
            (+
              (if row.cfa-deref?
                2
                0)
              1)))]
      [cfa-offset-width : i64
        (compiler-sframe-v3-signed-word-width row.cfa-offset)]
      [ra-width : i64
        (if ra-data?
          (compiler-sframe-v3-rule-data-width (& row.ra-rule))
          1)]
      [fp-width : i64
        (if fp-data?
          (compiler-sframe-v3-rule-data-width (& row.fp-rule))
          1)]
      [width : i64
        (compiler-sframe-v3-max
          (compiler-sframe-v3-max cfa-control-width cfa-offset-width)
          (compiler-sframe-v3-max ra-width fp-width))]
      [word-count : i64
        (+
          2
          (+
            (if ra-data?
              2
              (if fp-data?
                1
                0))
            (if fp-data?
              2
              0)))]
      (cond
        [row.outermost?
          (ResultCompilerSframeV3RowPlan.Err
            (compiler-sframe-v3-error
              compiler-sframe-v3-error-row
              -1
              "sframe v3: flexible rows cannot use the default outermost marker"))]
        [(not (compiler-sframe-v3-supported-register? row.cfa-register))
          (ResultCompilerSframeV3RowPlan.Err
            (compiler-sframe-v3-error
              compiler-sframe-v3-error-row
              -1
              "sframe v3: unsupported flexible CFA register"))]
        [(and
            ra-data?
            (not (compiler-sframe-v3-flex-data-rule-valid? (& row.ra-rule))))
          (ResultCompilerSframeV3RowPlan.Err
            (compiler-sframe-v3-error
              compiler-sframe-v3-error-row
              -1
              "sframe v3: invalid flexible RA control"))]
        [(and
            fp-data?
            (not (compiler-sframe-v3-flex-data-rule-valid? (& row.fp-rule))))
          (ResultCompilerSframeV3RowPlan.Err
            (compiler-sframe-v3-error
              compiler-sframe-v3-error-row
              -1
              "sframe v3: invalid flexible FP control"))]
        [(and
            (not ra-data?)
            (not
              (compiler-sframe-v3-rule-omitted-valid? (& row.ra-rule) fixed-ra)))
          (ResultCompilerSframeV3RowPlan.Err
            (compiler-sframe-v3-error
              compiler-sframe-v3-error-row
              -1
              "sframe v3: invalid omitted flexible RA rule"))]
        [(and
            (not fp-data?)
            (not
              (compiler-sframe-v3-rule-omitted-valid? (& row.fp-rule) fixed-fp)))
          (ResultCompilerSframeV3RowPlan.Err
            (compiler-sframe-v3-error
              compiler-sframe-v3-error-row
              -1
              "sframe v3: invalid omitted flexible FP rule"))]
        [(= width 0)
          (ResultCompilerSframeV3RowPlan.Err
            (compiler-sframe-v3-error
              compiler-sframe-v3-error-row
              -1
              "sframe v3: flexible rule data does not fit four bytes"))]
        [else
          (ResultCompilerSframeV3RowPlan.Ok
            (CompilerSframeV3RowPlan
              word-count
              width
              (+ (+ start-width 1) (* word-count width))))]))
    (if row.outermost?
      (if (and
        (= row.cfa-register 0)
        (not row.cfa-deref?)
        (= row.cfa-offset 0)
        (match (owned_view.compiler-owned-reference-shared-view (& row.ra-rule))
          [(CompilerSframeV3Rule.Unavailable) true]
          [_ false])
        (match (owned_view.compiler-owned-reference-shared-view (& row.fp-rule))
          [(CompilerSframeV3Rule.Unavailable) true]
          [_ false]))
        (ResultCompilerSframeV3RowPlan.Ok
          (CompilerSframeV3RowPlan 0 1 (+ start-width 1)))
        (ResultCompilerSframeV3RowPlan.Err
          (compiler-sframe-v3-error
            compiler-sframe-v3-error-row
            -1
            "sframe v3: outermost marker carries recovery data")))
      (let
        [fp-data? : bool
          (compiler-sframe-v3-rule-has-row-data? (& row.fp-rule))]
        [cfa-width : i64 (compiler-sframe-v3-signed-word-width row.cfa-offset)]
        [fp-width : i64
          (if fp-data?
            (compiler-sframe-v3-rule-data-width (& row.fp-rule))
            1)]
        [width : i64 (compiler-sframe-v3-max cfa-width fp-width)]
        [word-count : i64
          (if fp-data?
            2
            1)]
        (cond
          [(or
              row.cfa-deref?
              (and
                (!= row.cfa-register compiler-sframe-v3-dwarf-rbp)
                (!= row.cfa-register compiler-sframe-v3-dwarf-rsp)))
            (ResultCompilerSframeV3RowPlan.Err
              (compiler-sframe-v3-error
                compiler-sframe-v3-error-row
                -1
                "sframe v3: invalid AMD64 default CFA rule"))]
          [(or
              (= fixed-ra 0)
              (not
                (compiler-sframe-v3-rule-omitted-valid?
                  (& row.ra-rule)
                  fixed-ra)))
            (ResultCompilerSframeV3RowPlan.Err
              (compiler-sframe-v3-error
                compiler-sframe-v3-error-row
                -1
                "sframe v3: AMD64 default row requires its fixed RA rule"))]
          [(if fp-data?
              (match (owned_view.compiler-owned-reference-shared-view
                (& row.fp-rule))
                [(CompilerSframeV3Rule.Implicit deref? _) (not deref?)]
                [_ true])
              (not
                (compiler-sframe-v3-rule-omitted-valid?
                  (& row.fp-rule)
                  fixed-fp)))
            (ResultCompilerSframeV3RowPlan.Err
              (compiler-sframe-v3-error
                compiler-sframe-v3-error-row
                -1
                "sframe v3: invalid AMD64 default FP rule"))]
          [(= width 0)
            (ResultCompilerSframeV3RowPlan.Err
              (compiler-sframe-v3-error
                compiler-sframe-v3-error-row
                -1
                "sframe v3: default row data does not fit four bytes"))]
          [else
            (ResultCompilerSframeV3RowPlan.Ok
              (CompilerSframeV3RowPlan
                word-count
                width
                (+ (+ start-width 1) (* word-count width))))])))))

;: Validate semantic records and compute exact canonical size without a final VA.
(define (compiler-sframe-v3-plan
  [image : (& image CompilerSframeV3Image)]
  [limits : (& limits CompilerSframeV3Limits)]) : ResultCompilerSframeV3Plan
  (begin
    (when
      (not (compiler-sframe-v3-limits-valid? limits))
      (return
        (ResultCompilerSframeV3Plan.Err
          (compiler-sframe-v3-error
            compiler-sframe-v3-error-invalid-limits
            -1
            "sframe v3: invalid encoder limits"))))
    (when
      (or
        (< image.fixed-fp-offset -128)
        (> image.fixed-fp-offset 127)
        (< image.fixed-ra-offset -128)
        (> image.fixed-ra-offset 127))
      (return
        (ResultCompilerSframeV3Plan.Err
          (compiler-sframe-v3-error
            compiler-sframe-v3-error-preamble
            -1
            "sframe v3: fixed header offset does not fit i8"))))
    (let
      [function-count : i64 (array-length image.functions)]
      [function-index : i64 0]
      [row-count : i64 0]
      [fre-bytes : i64 0]
      [previous-function-start : i64 0]
      (begin
        (when
          (> function-count limits.max-functions)
          (return
            (ResultCompilerSframeV3Plan.Err
              (compiler-sframe-v3-error
                compiler-sframe-v3-error-function-limit
                -1
                "sframe v3: function count limit exceeded"))))
        (while (< function-index function-count)
          (let
            [function : (& image CompilerSframeV3Function)
              (& (array-ref image.functions function-index))]
            [function-row-count : i64 function.row-count]
            [start-width : i64
              (compiler-sframe-v3-row-start-width function.size)]
            [row-index : i64 0]
            [previous-row-start : i64 0]
            (begin
              (when
                (or
                  (<= function.size 0)
                  (> function.size 4294967295)
                  (< function.start-address 0)
                  (not
                    (compiler-sframe-v3-safe-add?
                      function.start-address
                      function.size)))
                (return
                  (ResultCompilerSframeV3Plan.Err
                    (compiler-sframe-v3-error
                      compiler-sframe-v3-error-function
                      -1
                      "sframe v3: invalid function address or size"))))
              (when
                (and
                  image.sorted?
                  (> function-index 0)
                  (<= function.start-address previous-function-start))
                (return
                  (ResultCompilerSframeV3Plan.Err
                    (compiler-sframe-v3-error
                      compiler-sframe-v3-error-function
                      -1
                      "sframe v3: sorted function starts are not strictly increasing"))))
              (when
                (or
                  (!= function.row-start row-count)
                  (< function-row-count 0)
                  (> function-row-count (- (array-length image.rows) row-count))
                  (> function-row-count 65535)
                  (and
                    (= function-row-count 0)
                    (or function.flex? function.mask-pc?)))
                (return
                  (ResultCompilerSframeV3Plan.Err
                    (compiler-sframe-v3-error
                      compiler-sframe-v3-error-row-limit
                      -1
                      "sframe v3: invalid or non-tiling function row span"))))
              (when
                (if function.mask-pc?
                  (or
                    (<= function.repetition-size 0)
                    (> function.repetition-size 255)
                    (> function.repetition-size function.size))
                  (!= function.repetition-size 0))
                (return
                  (ResultCompilerSframeV3Plan.Err
                    (compiler-sframe-v3-error
                      compiler-sframe-v3-error-attribute
                      -1
                      "sframe v3: invalid semantic repetition size"))))
              (when
                (> function-row-count (- limits.max-rows row-count))
                (return
                  (ResultCompilerSframeV3Plan.Err
                    (compiler-sframe-v3-error
                      compiler-sframe-v3-error-row-limit
                      -1
                      "sframe v3: row count limit exceeded"))))
              (set! fre-bytes (+ fre-bytes compiler-sframe-v3-attribute-size))
              (while (< row-index function-row-count)
                (let
                  [row : (& image CompilerSframeV3Row)
                    (& (array-ref image.rows (+ function.row-start row-index)))]
                  (begin
                    (when
                      (or
                        (and (= row-index 0) (!= row.start-offset 0))
                        (and
                          (> row-index 0)
                          (<= row.start-offset previous-row-start)))
                      (return
                        (ResultCompilerSframeV3Plan.Err
                          (compiler-sframe-v3-error
                            compiler-sframe-v3-error-row
                            -1
                            "sframe v3: row starts are not strictly increasing from zero"))))
                    (when
                      (if function.mask-pc?
                        (>= row.start-offset function.repetition-size)
                        (>= row.start-offset function.size))
                      (return
                        (ResultCompilerSframeV3Plan.Err
                          (compiler-sframe-v3-error
                            compiler-sframe-v3-error-row
                            -1
                            "sframe v3: row start is outside its lookup interval"))))
                    (match (compiler-sframe-v3-row-plan
                      row
                      function.flex?
                      image.fixed-fp-offset
                      image.fixed-ra-offset
                      start-width)
                      [(ResultCompilerSframeV3RowPlan.Err error)
                        (return (ResultCompilerSframeV3Plan.Err error))]
                      [(ResultCompilerSframeV3RowPlan.Ok row-plan)
                        (set! fre-bytes (+ fre-bytes row-plan.encoded-size))])
                    (set! previous-row-start row.start-offset)
                    (set! row-index (+ row-index 1)))))
              (set! row-count (+ row-count function-row-count))
              (set! previous-function-start function.start-address)
              (set! function-index (+ function-index 1)))))
        (when
          (or
            (!= row-count (array-length image.rows))
            (> row-count 4294967295)
            (> function-count limits.max-work)
            (> row-count (/ (- limits.max-work function-count) 8)))
          (return
            (ResultCompilerSframeV3Plan.Err
              (compiler-sframe-v3-error
                compiler-sframe-v3-error-work-limit
                -1
                "sframe v3: encode work limit exceeded"))))
        (when
          (not
            (compiler-sframe-v3-owned-estimate-ok?
              function-count
              row-count
              limits.max-owned-bytes))
          (return
            (ResultCompilerSframeV3Plan.Err
              (compiler-sframe-v3-error
                compiler-sframe-v3-error-allocation-limit
                -1
                "sframe v3: owned allocation limit exceeded"))))
        (let
          [total-bytes : i64
            (+
              compiler-sframe-v3-header-size
              (+ (* function-count compiler-sframe-v3-index-size) fre-bytes))]
          (if (> total-bytes limits.max-owned-bytes)
            (ResultCompilerSframeV3Plan.Err
              (compiler-sframe-v3-error
                compiler-sframe-v3-error-allocation-limit
                -1
                "sframe v3: encoded buffer allocation limit exceeded"))
            (if (> total-bytes limits.max-output-bytes)
              (ResultCompilerSframeV3Plan.Err
                (compiler-sframe-v3-error
                  compiler-sframe-v3-error-output-limit
                  -1
                  "sframe v3: output byte limit exceeded"))
              (ResultCompilerSframeV3Plan.Ok
                (CompilerSframeV3Plan
                  function-count
                  row-count
                  fre-bytes
                  total-bytes)))))))))

(define (compiler-sframe-v3-write-row!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [row : (& row CompilerSframeV3Row)]
  [flex? : bool]
  [fixed-fp : i64]
  [fixed-ra : i64]
  [start-width : i64]) : ResultCompilerSframeV3RowPlan
  (match (compiler-sframe-v3-row-plan row flex? fixed-fp fixed-ra start-width)
    [(ResultCompilerSframeV3RowPlan.Err error)
      (ResultCompilerSframeV3RowPlan.Err error)]
    [(ResultCompilerSframeV3RowPlan.Ok plan)
      (let
        [base : i64
          (if (and
            (not flex?)
            (not row.outermost?)
            (= row.cfa-register compiler-sframe-v3-dwarf-rsp))
            1
            0)]
        [word-type : i64 (compiler-sframe-v3-type-for-width plan.word-width)]
        [info : i64 (+ (shl word-type 5) (+ (shl plan.word-count 1) base))]
        [ra-data? : bool
          (compiler-sframe-v3-rule-has-row-data? (& row.ra-rule))]
        [fp-data? : bool
          (compiler-sframe-v3-rule-has-row-data? (& row.fp-rule))]
        (begin
          (compiler-sframe-v3-push-word! out row.start-offset start-width)
          (compiler-sframe-v3-push-u8! out info)
          (when
            (> plan.word-count 0)
            (if flex?
              (begin
                (compiler-sframe-v3-push-word!
                  out
                  (+
                    (shl row.cfa-register 3)
                    (+
                      (if row.cfa-deref?
                        2
                        0)
                      1))
                  plan.word-width)
                (compiler-sframe-v3-push-word!
                  out
                  row.cfa-offset
                  plan.word-width)
                (if ra-data?
                  (begin
                    (compiler-sframe-v3-push-word!
                      out
                      (compiler-sframe-v3-rule-control (& row.ra-rule))
                      plan.word-width)
                    (compiler-sframe-v3-push-word!
                      out
                      (compiler-sframe-v3-rule-offset (& row.ra-rule))
                      plan.word-width))
                  (when
                    fp-data?
                    (compiler-sframe-v3-push-word! out 0 plan.word-width)))
                (when
                  fp-data?
                  (begin
                    (compiler-sframe-v3-push-word!
                      out
                      (compiler-sframe-v3-rule-control (& row.fp-rule))
                      plan.word-width)
                    (compiler-sframe-v3-push-word!
                      out
                      (compiler-sframe-v3-rule-offset (& row.fp-rule))
                      plan.word-width))))
              (begin
                (compiler-sframe-v3-push-word!
                  out
                  row.cfa-offset
                  plan.word-width)
                (when
                  fp-data?
                  (compiler-sframe-v3-push-word!
                    out
                    (compiler-sframe-v3-rule-offset (& row.fp-rule))
                    plan.word-width)))))
          (ResultCompilerSframeV3RowPlan.Ok plan)))]))

;: Canonically encode final records using field-PC-relative function starts.
(define (compiler-sframe-v3-encode
  [image : (& image CompilerSframeV3Image)]
  [section-address : i64]
  [limits : (& limits CompilerSframeV3Limits)]) : ResultCompilerSframeV3Bytes
  (match (compiler-sframe-v3-plan image limits)
    [(ResultCompilerSframeV3Plan.Err error)
      (ResultCompilerSframeV3Bytes.Err error)]
    [(ResultCompilerSframeV3Plan.Ok plan)
      (begin
        (when
          (or
            (< section-address 0)
            (not (compiler-sframe-v3-safe-address? section-address)))
          (return
            (ResultCompilerSframeV3Bytes.Err
              (compiler-sframe-v3-error
                compiler-sframe-v3-error-address
                -1
                "sframe v3: section address is outside the supported range"))))
        (let
          [out : byte_buf_core.ByteBufBuilder
            (byte_buf_core.byte-buf-builder-with-capacity plan.total-bytes)]
          [function-index : i64 0]
          [fre-cursor : i64 0]
          (begin
            (compiler-sframe-v3-push-u16! (&mut out) compiler-sframe-v3-magic)
            (compiler-sframe-v3-push-u8! (&mut out) compiler-sframe-v3-version)
            (compiler-sframe-v3-push-u8!
              (&mut out)
              (+
                compiler-sframe-v3-flag-field-pcrel
                (if image.sorted?
                  compiler-sframe-v3-flag-sorted
                  0)))
            (compiler-sframe-v3-push-u8!
              (&mut out)
              compiler-sframe-v3-abi-amd64-le)
            (compiler-sframe-v3-push-u8! (&mut out) image.fixed-fp-offset)
            (compiler-sframe-v3-push-u8! (&mut out) image.fixed-ra-offset)
            (compiler-sframe-v3-push-u8! (&mut out) 0)
            (compiler-sframe-v3-push-u32! (&mut out) plan.function-count)
            (compiler-sframe-v3-push-u32! (&mut out) plan.row-count)
            (compiler-sframe-v3-push-u32! (&mut out) plan.fre-bytes)
            (compiler-sframe-v3-push-u32! (&mut out) 0)
            (compiler-sframe-v3-push-u32!
              (&mut out)
              (* plan.function-count compiler-sframe-v3-index-size))
            ;; Index entries.  Planning each row again is bounded by max-work
            ;; and avoids mutable layout metadata in the caller's records.
            (while (< function-index plan.function-count)
              (let
                [function : (& image CompilerSframeV3Function)
                  (& (array-ref image.functions function-index))]
                [index-offset : i64
                  (+
                    compiler-sframe-v3-header-size
                    (* function-index compiler-sframe-v3-index-size))]
                (begin
                  (when
                    (not
                      (compiler-sframe-v3-safe-add?
                        section-address
                        index-offset))
                    (return
                      (ResultCompilerSframeV3Bytes.Err
                        (compiler-sframe-v3-error
                          compiler-sframe-v3-error-address
                          index-offset
                          "sframe v3: encoded index address overflows"))))
                  (let
                    [field-address : i64 (+ section-address index-offset)]
                    [raw-start : i64 (- function.start-address field-address)]
                    (begin
                      (when
                        (not (compiler-sframe-v3-safe-address? raw-start))
                        (return
                          (ResultCompilerSframeV3Bytes.Err
                            (compiler-sframe-v3-error
                              compiler-sframe-v3-error-address
                              index-offset
                              "sframe v3: field-PC-relative start does not fit i64"))))
                      (compiler-sframe-v3-push-i64! (&mut out) raw-start)))
                  (compiler-sframe-v3-push-u32! (&mut out) function.size)
                  (compiler-sframe-v3-push-u32! (&mut out) fre-cursor)
                  (let
                    [row-index : i64 0]
                    [start-width : i64
                      (compiler-sframe-v3-row-start-width function.size)]
                    (begin
                      (set!
                        fre-cursor
                        (+ fre-cursor compiler-sframe-v3-attribute-size))
                      (while (< row-index function.row-count)
                        (let
                          [row : (& image CompilerSframeV3Row)
                            (&
                              (array-ref
                                image.rows
                                (+ function.row-start row-index)))]
                          (match (compiler-sframe-v3-row-plan
                            row
                            function.flex?
                            image.fixed-fp-offset
                            image.fixed-ra-offset
                            start-width)
                            [(ResultCompilerSframeV3RowPlan.Err error)
                              (return (ResultCompilerSframeV3Bytes.Err error))]
                            [(ResultCompilerSframeV3RowPlan.Ok row-plan)
                              (set!
                                fre-cursor
                                (+ fre-cursor row-plan.encoded-size))])
                          (set! row-index (+ row-index 1)))))
                    (set! function-index (+ function-index 1))))))
            ;; Function attributes and rows.
            (set! function-index 0)
            (while (< function-index plan.function-count)
              (let
                [function : (& image CompilerSframeV3Function)
                  (& (array-ref image.functions function-index))]
                [start-width : i64
                  (compiler-sframe-v3-row-start-width function.size)]
                [fre-type : i64
                  (compiler-sframe-v3-type-for-width
                    (compiler-sframe-v3-row-start-width function.size))]
                [row-index : i64 0]
                (begin
                  (compiler-sframe-v3-push-u16! (&mut out) function.row-count)
                  (compiler-sframe-v3-push-u8!
                    (&mut out)
                    (+
                      fre-type
                      (+
                        (if function.mask-pc?
                          16
                          0)
                        (if function.signal-frame?
                          128
                          0))))
                  (compiler-sframe-v3-push-u8!
                    (&mut out)
                    (if function.flex?
                      1
                      0))
                  (compiler-sframe-v3-push-u8!
                    (&mut out)
                    function.repetition-size)
                  (while (< row-index function.row-count)
                    (let
                      [row : (& image CompilerSframeV3Row)
                        (&
                          (array-ref
                            image.rows
                            (+ function.row-start row-index)))]
                      (match (compiler-sframe-v3-write-row!
                        (&mut out)
                        row
                        function.flex?
                        image.fixed-fp-offset
                        image.fixed-ra-offset
                        start-width)
                        [(ResultCompilerSframeV3RowPlan.Err error)
                          (return (ResultCompilerSframeV3Bytes.Err error))]
                        [(ResultCompilerSframeV3RowPlan.Ok _) unit])
                      (set! row-index (+ row-index 1))))
                  (set! function-index (+ function-index 1)))))
            (if (!=
              (byte_buf_core.byte-buf-builder-len (& out))
              plan.total-bytes)
              (ResultCompilerSframeV3Bytes.Err
                (compiler-sframe-v3-error
                  compiler-sframe-v3-error-layout
                  -1
                  "sframe v3: internal encoder size-plan mismatch"))
              (ResultCompilerSframeV3Bytes.Ok
                (byte_buf_core.byte-buf-builder-finish-array (& out)))))))]))

;: Find the semantic row for an absolute PC.  MASK lookup first subtracts the
;; relocated function start and then applies general modulo, including for
;; non-power-of-two repetition sizes.
(define (compiler-sframe-v3-row-index-for-pc
  [function : (& function CompilerSframeV3Function)]
  [rows : (& rows (__tl_dyn-array CompilerSframeV3Row))]
  [pc : i64]) : ResultCompilerSframeV3RowIndex
  (if (or
    (< pc function.start-address)
    (not (compiler-sframe-v3-safe-add? function.start-address function.size))
    (>= pc (+ function.start-address function.size))
    (< function.row-start 0)
    (< function.row-count 0)
    (> function.row-start (array-length rows))
    (> function.row-count (- (array-length rows) function.row-start)))
    (ResultCompilerSframeV3RowIndex.Err
      (compiler-sframe-v3-error
        compiler-sframe-v3-error-address
        -1
        "sframe v3: PC is outside the function"))
    (let
      [relative : i64 (- pc function.start-address)]
      [lookup-offset : i64
        (if function.mask-pc?
          (if (> function.repetition-size 0)
            (% relative function.repetition-size)
            -1)
          relative)]
      [row-count : i64 function.row-count]
      [row-index : i64 0]
      [selected : i64 -1]
      (begin
        (while (< row-index row-count)
          (let
            [row : (& rows CompilerSframeV3Row)
              (& (array-ref rows (+ function.row-start row-index)))]
            (begin
              (if (<= row.start-offset lookup-offset)
                (set! selected row-index)
                (set! row-index row-count))
              (when (< row-index row-count) (set! row-index (+ row-index 1))))))
        (if (< selected 0)
          (ResultCompilerSframeV3RowIndex.Err
            (compiler-sframe-v3-error
              compiler-sframe-v3-error-row
              -1
              "sframe v3: function has no applicable row"))
          (ResultCompilerSframeV3RowIndex.Ok selected))))))

;: Decode through an explicit persisted dialect policy.
(define (compiler-sframe-v3-decode-with-policy
  [bytes : (& bytes (__tl_dyn-array u8))]
  [section-address : i64]
  [policy : (& policy CompilerSframeV3Policy)]
  [limits : (& limits CompilerSframeV3Limits)]) : ResultCompilerSframeV3Image
  (if (compiler-sframe-v3-policy-valid? policy)
    (compiler-sframe-v3-decode bytes section-address limits)
    (ResultCompilerSframeV3Image.Err
      (compiler-sframe-v3-error
        compiler-sframe-v3-error-dialect
        0
        "sframe v3: unsupported codec dialect policy"))))

;: Size-plan through an explicit persisted dialect policy.
(define (compiler-sframe-v3-plan-with-policy
  [image : (& image CompilerSframeV3Image)]
  [policy : (& policy CompilerSframeV3Policy)]
  [limits : (& limits CompilerSframeV3Limits)]) : ResultCompilerSframeV3Plan
  (if (compiler-sframe-v3-policy-valid? policy)
    (compiler-sframe-v3-plan image limits)
    (ResultCompilerSframeV3Plan.Err
      (compiler-sframe-v3-error
        compiler-sframe-v3-error-dialect
        -1
        "sframe v3: unsupported codec dialect policy"))))

;: Canonically encode through an explicit persisted dialect policy.
(define (compiler-sframe-v3-encode-with-policy
  [image : (& image CompilerSframeV3Image)]
  [section-address : i64]
  [policy : (& policy CompilerSframeV3Policy)]
  [limits : (& limits CompilerSframeV3Limits)]) : ResultCompilerSframeV3Bytes
  (if (compiler-sframe-v3-policy-valid? policy)
    (compiler-sframe-v3-encode image section-address limits)
    (ResultCompilerSframeV3Bytes.Err
      (compiler-sframe-v3-error
        compiler-sframe-v3-error-dialect
        -1
        "sframe v3: unsupported codec dialect policy"))))