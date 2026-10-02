;; compiler_eh_frame.tl - bounded Linux x86-64 DWARF32 .eh_frame and
;; .eh_frame_hdr codec.
;;
;; This module owns only the exception-frame format: splitting raw section
;; bytes into CIE and FDE records, validating the admitted profile, canonical
;; record encoding for caller-selected FDEs at caller-supplied final addresses,
;; and the version-1 search header.  It does not parse ELF, bind relocations,
;; decide liveness, or choose layout.
;;
;; Admitted profile (#7388): DWARF32 records ending at clean section EOF or a
;; zero terminator; CIE version 1 with augmentation "zR" and FDE pointer
;; encoding pcrel|sdata4; FDE augmentation data empty; CFA programs of
;; non-expression opcodes with bounded LEB operands.  DWARF64, other versions,
;; augmentations and pointer encodings, DW_CFA_set_loc, expression opcodes and
;; unknown opcodes fail closed.
(import stdlib.byte_buf_core)
(import stdlib.byte_le)
(import stdlib.leb128)
(import stdlib.string)

(define compiler-eh-frame-pe-udata4 : i64
  0x03)
(define compiler-eh-frame-pe-pcrel-sdata4 : i64
  0x1b)
(define compiler-eh-frame-pe-datarel-sdata4 : i64
  0x3b)
(define compiler-eh-frame-header-version : i64
  1)
(define compiler-eh-frame-header-size : i64
  12)
(define compiler-eh-frame-record-alignment : i64
  8)

;; DWARF register numbers admitted in CFA operands.  x86-64 assigns 0-16 to
;; the general registers and RIP and higher numbers to vector, x87, segment and
;; mask registers; anything past this bound is not a register of the target.
(define compiler-eh-frame-max-register : i64
  130)

;; Stable error categories.  New diagnostics get new codes; callers do not
;; compare prose.
(define compiler-eh-frame-error-invalid-limits : i64
  1)
(define compiler-eh-frame-error-input-limit : i64
  2)
(define compiler-eh-frame-error-truncated : i64
  3)
(define compiler-eh-frame-error-dwarf64 : i64
  4)
(define compiler-eh-frame-error-record : i64
  5)
(define compiler-eh-frame-error-record-limit : i64
  6)
(define compiler-eh-frame-error-cie-reference : i64
  7)
(define compiler-eh-frame-error-cie : i64
  8)
(define compiler-eh-frame-error-fde : i64
  9)
(define compiler-eh-frame-error-cfa : i64
  10)
(define compiler-eh-frame-error-leb : i64
  11)
(define compiler-eh-frame-error-work-limit : i64
  12)
(define compiler-eh-frame-error-selection : i64
  13)
(define compiler-eh-frame-error-address : i64
  14)
(define compiler-eh-frame-error-output-limit : i64
  15)
(define compiler-eh-frame-error-header : i64
  16)
(define compiler-eh-frame-error-header-order : i64
  17)

;; Caller-owned limits, each checked before the corresponding allocation or
;; work.  `max-program-bytes` bounds one record's CFA program.
(defstruct CompilerEhFrameLimits
  (max-input-bytes i64)
  (max-output-bytes i64)
  (max-records i64)
  (max-program-bytes i64)
  (max-state-depth i64)
  (max-work i64))

(define (compiler-eh-frame-default-limits) : CompilerEhFrameLimits
  (CompilerEhFrameLimits 67108864 67108864 1048576 65536 64 268435456))

;; `input` is the caller's identity for the section being decoded (-1 when the
;; error is not about one input), `record` the offset of the record in it (-1
;; when none), and `offset` the byte offset of the problem in that section.
(defstruct CompilerEhFrameError
  (code i64)
  (input i64)
  (record i64)
  (offset i64)
  (message String))

;; A decoded CIE.  Its CFA program is `program-length` bytes at
;; `program-start` in the image's `programs`, without trailing DW_CFA_nop
;; padding; encoding pads again.
(defstruct CompilerEhFrameCie
  (input i64)
  (offset i64)
  (code-alignment i64)
  (data-alignment i64)
  (return-register i64)
  (pointer-encoding i64)
  (program-start i64)
  (program-length i64))

;; A decoded FDE.  `cie` indexes the image's `cies`.  The initial location is
;; the `location-width`-byte field at `location-offset` in the input section;
;; `location-raw` is its signed stored value, so a relocatable input exposes
;; the addend an R_X86_64_PC32 relocation at that offset combines with, and a
;; linked input resolves through compiler-eh-frame-fde-initial-location.
(defstruct CompilerEhFrameFde
  (input i64)
  (offset i64)
  (cie i64)
  (location-offset i64)
  (location-width i64)
  (location-raw i64)
  (range i64)
  (program-start i64)
  (program-length i64))

(defstruct CompilerEhFrameImage
  (input i64)
  (cies (__tl_dyn-array CompilerEhFrameCie))
  (fdes (__tl_dyn-array CompilerEhFrameFde))
  ;; Image-owned CFA programs; only the first `program-bytes` bytes are used.
  (programs (__tl_dyn-array u8))
  (program-bytes i64)
  (terminated? bool))

;; One FDE the caller keeps, and the final address of the code it covers.
(defstruct CompilerEhFrameSelection
  (image i64)
  (fde i64)
  (initial-location i64))

;; One searchable FDE in final layout.
(defstruct CompilerEhFrameRow
  (initial-location i64)
  (range i64)
  (fde-address i64))

(defstruct CompilerEhFrameOutput
  (bytes (__tl_dyn-array u8))
  (rows (__tl_dyn-array CompilerEhFrameRow)))

(defstruct CompilerEhFrameHeader
  (eh-frame-address i64)
  (rows (__tl_dyn-array CompilerEhFrameRow)))

(defenum ResultCompilerEhFrameImage
  (Err CompilerEhFrameError)
  (Ok CompilerEhFrameImage))

(defenum ResultCompilerEhFrameOutput
  (Err CompilerEhFrameError)
  (Ok CompilerEhFrameOutput))

;; An empty selection has no header: the linker publishes neither
;; .eh_frame_hdr nor PT_GNU_EH_FRAME.
(defenum ResultCompilerEhFrameHeaderBytes
  (Err CompilerEhFrameError)
  (NoHeader)
  (Ok (__tl_dyn-array u8)))

(defenum ResultCompilerEhFrameHeader
  (Err CompilerEhFrameError)
  (Ok CompilerEhFrameHeader))

(defenum ResultCompilerEhFrameRows
  (Err CompilerEhFrameError)
  (Ok (__tl_dyn-array CompilerEhFrameRow)))

(define (compiler-eh-frame-error
  [code : i64]
  [input : i64]
  [record : i64]
  [offset : i64]
  [message : String]) : CompilerEhFrameError
  (CompilerEhFrameError code input record offset message))

(define (compiler-eh-frame-limits-valid?
  [limits : (& limits CompilerEhFrameLimits)]) : bool
  (and
    (>= limits.max-input-bytes 0)
    (>= limits.max-output-bytes 0)
    (>= limits.max-records 0)
    (>= limits.max-program-bytes 0)
    (>= limits.max-state-depth 0)
    (>= limits.max-work 0)))

(define (compiler-eh-frame-read-i32
  [bytes : (& bytes (__tl_dyn-array u8))]
  [offset : i64]) : i64
  (let
    [value : i64 (byte_le.read-u32 bytes offset)]
    (if (>= value 2147483648)
      (- value 4294967296)
      value)))

(define (compiler-eh-frame-i32? [value : i64]) : bool
  (and (>= value -2147483648) (<= value 2147483647)))

;; Addresses stay away from the signed endpoints, so the sums and differences
;; of two of them never overflow.
(define (compiler-eh-frame-address? [value : i64]) : bool
  (and (>= value (- 0 4611686018427387904)) (<= value 4611686018427387903)))

(define (compiler-eh-frame-push-u8!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [value : i64]) : unit
  (byte_buf_core.byte-buf-builder-push out (cast (bit-and value 255) : u8)))

;; --- LEB128 ------------------------------------------------------------------
;; The admitted LEB128 operand at `offset`: `stdlib.leb128`'s decode, further
;; limited to nine bytes and to [0, 2^62) unsigned or [-2^62, 2^62) signed, far
;; beyond any admitted operand, so later arithmetic on it cannot overflow.
;; `ok?` is false for a truncated, overlong or out-of-range encoding.
(define (compiler-eh-frame-leb
  [bytes : (& bytes (__tl_dyn-array u8))]
  [offset : i64]
  [end : i64]
  [signed? : bool]) : leb128.Decoded
  (let
    [decoded : leb128.Decoded
      (if signed?
        (leb128.decode-signed bytes offset end)
        (leb128.decode-unsigned bytes offset end))]
    (if (and
      decoded.ok?
      (<= (- decoded.next offset) 9)
      (>=
        decoded.value
        (if signed?
          (- 0 4611686018427387904)
          0))
      (<= decoded.value 4611686018427387903))
      decoded
      (leb128.Decoded false 0 decoded.next))))

;; --- CFA programs ------------------------------------------------------------
;; The result of checking one CFA program: `end` is the offset just past its
;; last non-nop instruction (the canonical program end), `work` the number of
;; instructions visited.  `message` is empty on success.
(defstruct CompilerEhFrameProgramCheck
  (message String)
  (offset i64)
  (end i64)
  (work i64))

(define (compiler-eh-frame-program-fail [message : String] [offset : i64]) : CompilerEhFrameProgramCheck
  (CompilerEhFrameProgramCheck message offset offset 0))

;; Validate the CFA program `bytes[start .. end)`.  A CIE program (`range` < 0)
;; only establishes the initial rules: it may not advance the location or refer
;; to the initial state.  An FDE program's location advances, scaled by
;; `code-alignment`, stay within `range`, and every DW_CFA_restore_state pops
;; a remembered state.
(define (compiler-eh-frame-check-program
  [bytes : (& bytes (__tl_dyn-array u8))]
  [start : i64]
  [end : i64]
  [code-alignment : i64]
  [range : i64]
  [max-depth : i64]) : CompilerEhFrameProgramCheck
  (let
    [at : i64 start]
    [canonical-end : i64 start]
    [location : i64 0]
    [depth : i64 0]
    [work : i64 0]
    [message : String ""]
    [fail-at : i64 start]
    [cie? : bool (< range 0)]
    (begin
      (while (and (< at end) (string.eq message ""))
        (let
          [op-at : i64 at]
          [op : i64 (byte_le.byte-le-at bytes at)]
          [high : i64 (shr op 6)]
          [low : i64 (bit-and op 63)]
          ;; -1: no advance; otherwise the unscaled delta.
          [advance : i64 -1]
          ;; Registers named by this instruction, or -1.
          [register-a : i64 -1]
          [register-b : i64 -1]
          [ok : bool true]
          (begin
            (set! at (+ at 1))
            (set! work (+ work 1))
            (cond
              [(= high 1) (set! advance low)]
              [(= high 2)
                (let
                  [operand : leb128.Decoded
                    (compiler-eh-frame-leb bytes at end false)]
                  (begin
                    (set! register-a low)
                    (set! ok operand.ok?)
                    (set! at operand.next)))]
              [(= high 3)
                (if cie?
                  (set! message "cfa: DW_CFA_restore in a CIE program")
                  (set! register-a low))]
              [(= op 0x00) unit]
              [(= op 0x01)
                (set!
                  message
                  "cfa: address-bearing DW_CFA_set_loc is not admitted")]
              [(= op 0x02)
                (if (> (+ at 1) end)
                  (set! ok false)
                  (begin
                    (set! advance (byte_le.byte-le-at bytes at))
                    (set! at (+ at 1))))]
              [(= op 0x03)
                (if (> (+ at 2) end)
                  (set! ok false)
                  (begin
                    (set! advance (byte_le.read-u16 bytes at))
                    (set! at (+ at 2))))]
              [(= op 0x04)
                (if (> (+ at 4) end)
                  (set! ok false)
                  (begin
                    (set! advance (byte_le.read-u32 bytes at))
                    (set! at (+ at 4))))]
              ;; register, operand: offset_extended, register, def_cfa,
              ;; val_offset (both ULEB) and the _sf forms (SLEB second).
              [(or
                  (= op 0x05)
                  (= op 0x09)
                  (= op 0x0c)
                  (= op 0x11)
                  (= op 0x12)
                  (= op 0x14)
                  (= op 0x15))
                (let
                  [first : leb128.Decoded
                    (compiler-eh-frame-leb bytes at end false)]
                  [second : leb128.Decoded
                    (compiler-eh-frame-leb
                      bytes
                      first.next
                      end
                      (or (= op 0x11) (= op 0x12) (= op 0x15)))]
                  (begin
                    (set! ok (and first.ok? second.ok?))
                    (set! register-a first.value)
                    (when (= op 0x09) (set! register-b second.value))
                    (set! at second.next)))]
              ;; One register operand: restore_extended, undefined,
              ;; same_value, def_cfa_register.
              [(or (= op 0x06) (= op 0x07) (= op 0x08) (= op 0x0d))
                (let
                  [operand : leb128.Decoded
                    (compiler-eh-frame-leb bytes at end false)]
                  (if (and cie? (= op 0x06))
                    (set!
                      message
                      "cfa: DW_CFA_restore_extended in a CIE program")
                    (begin
                      (set! ok operand.ok?)
                      (set! register-a operand.value)
                      (set! at operand.next))))]
              ;; One offset operand: def_cfa_offset (ULEB), def_cfa_offset_sf
              ;; (SLEB), GNU_args_size (ULEB).
              [(or (= op 0x0e) (= op 0x13) (= op 0x2e))
                (let
                  [operand : leb128.Decoded
                    (compiler-eh-frame-leb bytes at end (= op 0x13))]
                  (if (and cie? (= op 0x2e))
                    (set! message "cfa: DW_CFA_GNU_args_size in a CIE program")
                    (begin
                      (set! ok operand.ok?)
                      (set! at operand.next))))]
              [(= op 0x0a)
                (cond
                  [cie?
                    (set! message "cfa: DW_CFA_remember_state in a CIE program")]
                  [(>= depth max-depth)
                    (set! message "cfa: remembered state depth limit exceeded")]
                  [else (set! depth (+ depth 1))])]
              [(= op 0x0b)
                (cond
                  [cie?
                    (set! message "cfa: DW_CFA_restore_state in a CIE program")]
                  [(= depth 0)
                    (set!
                      message
                      "cfa: DW_CFA_restore_state without a remembered state")]
                  [else (set! depth (- depth 1))])]
              [(or (= op 0x0f) (= op 0x10) (= op 0x16))
                (set!
                  message
                  "cfa: DWARF expression instructions are not admitted")]
              [else (set! message "cfa: unknown or unadmitted CFA opcode")])
            (cond
              [(not (string.eq message "")) (set! fail-at op-at)]
              [(not ok)
                (begin
                  (set!
                    message
                    "cfa: truncated or out-of-range instruction operand")
                  (set! fail-at op-at))]
              [(or
                  (> register-a compiler-eh-frame-max-register)
                  (> register-b compiler-eh-frame-max-register))
                (begin
                  (set!
                    message
                    "cfa: register operand outside the x86-64 DWARF register set")
                  (set! fail-at op-at))]
              [(>= advance 0)
                (if cie?
                  (begin
                    (set! message "cfa: location advance in a CIE program")
                    (set! fail-at op-at))
                  (begin
                    ;; delta < 2^32 and code-alignment < 2^32, so the product
                    ;; and the sum stay far below 2^63.
                    (set! location (+ location (* advance code-alignment)))
                    (when
                      (> location range)
                      (begin
                        (set!
                          message
                          "cfa: location advance past the FDE range")
                        (set! fail-at op-at)))))]
              [else unit])
            (when
              (and (string.eq message "") (!= op 0x00))
              (set! canonical-end at)))))
      (if (string.eq message "")
        (CompilerEhFrameProgramCheck "" at canonical-end work)
        (compiler-eh-frame-program-fail message fail-at)))))

;; --- decoding ----------------------------------------------------------------
;; Record boundaries of `bytes`: the number of CIEs and FDEs and whether the
;; section ends with an explicit zero terminator, or the first framing error.
(defstruct CompilerEhFrameFraming
  (error-code i64)
  (error-record i64)
  (error-offset i64)
  (error-message String)
  (cies i64)
  (fdes i64)
  (terminated? bool))

(define (compiler-eh-frame-framing
  [bytes : (& bytes (__tl_dyn-array u8))]
  [limits : (& limits CompilerEhFrameLimits)]) : CompilerEhFrameFraming
  (let
    [length : i64 (array-length bytes)]
    [at : i64 0]
    [cies : i64 0]
    [fdes : i64 0]
    [terminated : bool false]
    [code : i64 0]
    [record : i64 -1]
    [offset : i64 0]
    [message : String ""]
    (begin
      (while (and (< at length) (= code 0))
        (let
          [record-length : i64
            (if (> (+ at 4) length)
              -1
              (byte_le.read-u32 bytes at))]
          (cond
            [(< record-length 0)
              (begin
                (set! code compiler-eh-frame-error-truncated)
                (set! record at)
                (set! offset at)
                (set! message "eh_frame: truncated record length"))]
            [(= record-length 0)
              (if (= (+ at 4) length)
                (begin
                  (set! terminated true)
                  (set! at length))
                (begin
                  (set! code compiler-eh-frame-error-record)
                  (set! record at)
                  (set! offset (+ at 4))
                  (set! message "eh_frame: bytes after the zero terminator")))]
            [(= record-length 4294967295)
              (begin
                (set! code compiler-eh-frame-error-dwarf64)
                (set! record at)
                (set! offset at)
                (set! message "eh_frame: DWARF64 records are not admitted"))]
            [(> record-length (- length (+ at 4)))
              (begin
                (set! code compiler-eh-frame-error-truncated)
                (set! record at)
                (set! offset at)
                (set! message "eh_frame: record extends past the section"))]
            [(< record-length 4)
              (begin
                (set! code compiler-eh-frame-error-record)
                (set! record at)
                (set! offset at)
                (set! message "eh_frame: record too short for its CIE id"))]
            [(>= (+ cies fdes) limits.max-records)
              (begin
                (set! code compiler-eh-frame-error-record-limit)
                (set! record at)
                (set! offset at)
                (set! message "eh_frame: record limit exceeded"))]
            [else
              (begin
                (if (= (byte_le.read-u32 bytes (+ at 4)) 0)
                  (set! cies (+ cies 1))
                  (set! fdes (+ fdes 1)))
                (set! at (+ at (+ 4 record-length))))])))
      (CompilerEhFrameFraming code record offset message cies fdes terminated))))

;; Index of the CIE decoded at `offset`, or -1.  CIEs are decoded in offset
;; order, so the first `count` entries are sorted.
(define (compiler-eh-frame-cie-at
  [cies : (& cies (__tl_dyn-array CompilerEhFrameCie))]
  [count : i64]
  [offset : i64]) : i64
  (let
    [low : i64 0]
    [high : i64 count]
    (begin
      (while (< low high)
        (let
          [middle : i64 (+ low (/ (- high low) 2))]
          (if (< (array-ref cies middle).offset offset)
            (set! low (+ middle 1))
            (set! high middle))))
      (if (and (< low count) (= (array-ref cies low).offset offset))
        low
        -1))))

(define (compiler-eh-frame-copy-program!
  [programs : (&mut programs (__tl_dyn-array u8))]
  [at : i64]
  [bytes : (& bytes (__tl_dyn-array u8))]
  [start : i64]
  [count : i64]) : unit
  (let
    [index : i64 0]
    (while (< index count)
      (begin
        (set!
          (array-ref programs (+ at index))
          (array-ref bytes (+ start index)))
        (set! index (+ index 1))))))

;; Decode the `.eh_frame` section `bytes`, which the caller identifies as
;; `input`.  Every record is checked against the admitted profile before any
;; of it is exposed.
(define (compiler-eh-frame-decode
  [bytes : (& bytes (__tl_dyn-array u8))]
  [input : i64]
  [limits : (& limits CompilerEhFrameLimits)]) : ResultCompilerEhFrameImage
  (let
    [length : i64 (array-length bytes)]
    (begin
      (when
        (not (compiler-eh-frame-limits-valid? limits))
        (return
          (ResultCompilerEhFrameImage.Err
            (compiler-eh-frame-error
              compiler-eh-frame-error-invalid-limits
              input
              -1
              0
              "eh_frame: invalid codec limits"))))
      (when
        (> length limits.max-input-bytes)
        (return
          (ResultCompilerEhFrameImage.Err
            (compiler-eh-frame-error
              compiler-eh-frame-error-input-limit
              input
              -1
              0
              "eh_frame: input byte limit exceeded"))))
      (let
        [framing : CompilerEhFrameFraming
          (compiler-eh-frame-framing bytes limits)]
        (begin
          (when
            (!= framing.error-code 0)
            (return
              (ResultCompilerEhFrameImage.Err
                (compiler-eh-frame-error
                  framing.error-code
                  input
                  framing.error-record
                  framing.error-offset
                  framing.error-message))))
          (let
            [cies : (__tl_dyn-array CompilerEhFrameCie)
              (__tl_make-array CompilerEhFrameCie framing.cies)]
            [fdes : (__tl_dyn-array CompilerEhFrameFde)
              (__tl_make-array CompilerEhFrameFde framing.fdes)]
            [programs : (__tl_dyn-array u8) (__tl_make-array u8 length)]
            [program-bytes : i64 0]
            [cie-count : i64 0]
            [fde-count : i64 0]
            [work : i64 0]
            [at : i64 0]
            (begin
              (while (< (+ cie-count fde-count) (+ framing.cies framing.fdes))
                (let
                  [record : i64 at]
                  [end : i64 (+ at (+ 4 (byte_le.read-u32 bytes at)))]
                  [id : i64 (byte_le.read-u32 bytes (+ at 4))]
                  (begin
                    (set! at end)
                    (if (= id 0)
                      (let
                        [parsed
                          (try
                            (compiler-eh-frame-decode-cie
                              bytes
                              input
                              record
                              end
                              limits))]
                        [check : CompilerEhFrameProgramCheck
                          (compiler-eh-frame-check-program
                            bytes
                            parsed.program-start
                            end
                            parsed.code-alignment
                            -1
                            limits.max-state-depth)]
                        [program-length : i64
                          (- check.end parsed.program-start)]
                        (begin
                          (when
                            (not (string.eq check.message ""))
                            (return
                              (ResultCompilerEhFrameImage.Err
                                (compiler-eh-frame-error
                                  compiler-eh-frame-error-cfa
                                  input
                                  record
                                  check.offset
                                  check.message))))
                          (set! work (+ work check.work))
                          (compiler-eh-frame-copy-program!
                            (&mut programs)
                            program-bytes
                            bytes
                            parsed.program-start
                            program-length)
                          (set!
                            (array-ref cies cie-count)
                            (CompilerEhFrameCie
                              input
                              record
                              parsed.code-alignment
                              parsed.data-alignment
                              parsed.return-register
                              compiler-eh-frame-pe-pcrel-sdata4
                              program-bytes
                              program-length))
                          (set! program-bytes (+ program-bytes program-length))
                          (set! cie-count (+ cie-count 1))))
                      (let
                        [cie-offset : i64 (- (+ record 4) id)]
                        [cie : i64
                          (if (< cie-offset 0)
                            -1
                            (compiler-eh-frame-cie-at
                              (& cies)
                              cie-count
                              cie-offset))]
                        (begin
                          (when
                            (< cie 0)
                            (return
                              (ResultCompilerEhFrameImage.Err
                                (compiler-eh-frame-error
                                  compiler-eh-frame-error-cie-reference
                                  input
                                  record
                                  (+ record 4)
                                  "eh_frame: FDE CIE pointer does not name a preceding CIE"))))
                          (when
                            (< (- end record) 17)
                            (return
                              (ResultCompilerEhFrameImage.Err
                                (compiler-eh-frame-error
                                  compiler-eh-frame-error-truncated
                                  input
                                  record
                                  (+ record 8)
                                  "eh_frame: FDE too short for its location, range and augmentation"))))
                          (let
                            [code-alignment : i64
                              (array-ref cies cie).code-alignment]
                            [raw : i64
                              (compiler-eh-frame-read-i32 bytes (+ record 8))]
                            [range : i64
                              (compiler-eh-frame-read-i32 bytes (+ record 12))]
                            [augmentation : leb128.Decoded
                              (compiler-eh-frame-leb
                                bytes
                                (+ record 16)
                                end
                                false)]
                            (begin
                              (when
                                (<= range 0)
                                (return
                                  (ResultCompilerEhFrameImage.Err
                                    (compiler-eh-frame-error
                                      compiler-eh-frame-error-fde
                                      input
                                      record
                                      (+ record 12)
                                      "eh_frame: FDE address range is not positive"))))
                              (when
                                (not augmentation.ok?)
                                (return
                                  (ResultCompilerEhFrameImage.Err
                                    (compiler-eh-frame-error
                                      compiler-eh-frame-error-leb
                                      input
                                      record
                                      (+ record 16)
                                      "eh_frame: malformed FDE augmentation length"))))
                              (when
                                (!= augmentation.value 0)
                                (return
                                  (ResultCompilerEhFrameImage.Err
                                    (compiler-eh-frame-error
                                      compiler-eh-frame-error-fde
                                      input
                                      record
                                      (+ record 16)
                                      "eh_frame: FDE augmentation data is not admitted for zR"))))
                              (when
                                (>
                                  (- end augmentation.next)
                                  limits.max-program-bytes)
                                (return
                                  (ResultCompilerEhFrameImage.Err
                                    (compiler-eh-frame-error
                                      compiler-eh-frame-error-cfa
                                      input
                                      record
                                      augmentation.next
                                      "eh_frame: CFA program byte limit exceeded"))))
                              (let
                                [check : CompilerEhFrameProgramCheck
                                  (compiler-eh-frame-check-program
                                    bytes
                                    augmentation.next
                                    end
                                    code-alignment
                                    range
                                    limits.max-state-depth)]
                                [program-length : i64
                                  (- check.end augmentation.next)]
                                (begin
                                  (when
                                    (not (string.eq check.message ""))
                                    (return
                                      (ResultCompilerEhFrameImage.Err
                                        (compiler-eh-frame-error
                                          compiler-eh-frame-error-cfa
                                          input
                                          record
                                          check.offset
                                          check.message))))
                                  (set! work (+ work check.work))
                                  (compiler-eh-frame-copy-program!
                                    (&mut programs)
                                    program-bytes
                                    bytes
                                    augmentation.next
                                    program-length)
                                  (set!
                                    (array-ref fdes fde-count)
                                    (CompilerEhFrameFde
                                      input
                                      record
                                      cie
                                      (+ record 8)
                                      4
                                      raw
                                      range
                                      program-bytes
                                      program-length))
                                  (set!
                                    program-bytes
                                    (+ program-bytes program-length))
                                  (set! fde-count (+ fde-count 1)))))))))
                    (when
                      (> work limits.max-work)
                      (return
                        (ResultCompilerEhFrameImage.Err
                          (compiler-eh-frame-error
                            compiler-eh-frame-error-work-limit
                            input
                            record
                            record
                            "eh_frame: work limit exceeded")))))))
              (ResultCompilerEhFrameImage.Ok
                (CompilerEhFrameImage
                  input
                  cies
                  fdes
                  programs
                  program-bytes
                  framing.terminated?)))))))))

;; The fixed CIE fields and where its program starts.
(defstruct CompilerEhFrameCieParse
  (code-alignment i64)
  (data-alignment i64)
  (return-register i64)
  (program-start i64))

(defenum ResultCompilerEhFrameCieParse
  (Err CompilerEhFrameError)
  (Ok CompilerEhFrameCieParse))

(define (compiler-eh-frame-decode-cie
  [bytes : (& bytes (__tl_dyn-array u8))]
  [input : i64]
  [record : i64]
  [end : i64]
  [limits : (& limits CompilerEhFrameLimits)]) : ResultCompilerEhFrameCieParse
  (let
    [at : i64 (+ record 8)]
    (begin
      ;; version, "zR\0", then at least one byte for each of the three
      ;; alignment/register fields, the augmentation length and data.
      (when
        (> (+ at 9) end)
        (return
          (ResultCompilerEhFrameCieParse.Err
            (compiler-eh-frame-error
              compiler-eh-frame-error-truncated
              input
              record
              at
              "eh_frame: CIE too short for its fixed fields"))))
      (when
        (!= (byte_le.byte-le-at bytes at) 1)
        (return
          (ResultCompilerEhFrameCieParse.Err
            (compiler-eh-frame-error
              compiler-eh-frame-error-cie
              input
              record
              at
              "eh_frame: only CIE version 1 is admitted"))))
      (when
        (or
          (!= (byte_le.byte-le-at bytes (+ at 1)) 122)
          (!= (byte_le.byte-le-at bytes (+ at 2)) 82)
          (!= (byte_le.byte-le-at bytes (+ at 3)) 0))
        (return
          (ResultCompilerEhFrameCieParse.Err
            (compiler-eh-frame-error
              compiler-eh-frame-error-cie
              input
              record
              (+ at 1)
              "eh_frame: only CIE augmentation \"zR\" is admitted"))))
      (let
        [code : leb128.Decoded (compiler-eh-frame-leb bytes (+ at 4) end false)]
        [data : leb128.Decoded (compiler-eh-frame-leb bytes code.next end true)]
        (begin
          (when
            (or (not code.ok?) (not data.ok?))
            (return
              (ResultCompilerEhFrameCieParse.Err
                (compiler-eh-frame-error
                  compiler-eh-frame-error-leb
                  input
                  record
                  (+ at 4)
                  "eh_frame: malformed CIE alignment factor"))))
          ;; Factors scale advances and offsets; bounding them keeps every
          ;; scaled operand representable.
          (when
            (or
              (< code.value 1)
              (> code.value 4294967295)
              (= data.value 0)
              (< data.value -4294967296)
              (> data.value 4294967295))
            (return
              (ResultCompilerEhFrameCieParse.Err
                (compiler-eh-frame-error
                  compiler-eh-frame-error-cie
                  input
                  record
                  (+ at 4)
                  "eh_frame: CIE alignment factor outside the admitted range"))))
          (when
            (> (+ data.next 3) end)
            (return
              (ResultCompilerEhFrameCieParse.Err
                (compiler-eh-frame-error
                  compiler-eh-frame-error-truncated
                  input
                  record
                  data.next
                  "eh_frame: CIE too short for its augmentation data"))))
          (let
            [return-register : i64 (byte_le.byte-le-at bytes data.next)]
            [augmentation : leb128.Decoded
              (compiler-eh-frame-leb bytes (+ data.next 1) end false)]
            (begin
              (when
                (> return-register compiler-eh-frame-max-register)
                (return
                  (ResultCompilerEhFrameCieParse.Err
                    (compiler-eh-frame-error
                      compiler-eh-frame-error-cie
                      input
                      record
                      data.next
                      "eh_frame: CIE return address register outside the x86-64 DWARF register set"))))
              (when
                (or
                  (not augmentation.ok?)
                  (!= augmentation.value 1)
                  (>= augmentation.next end))
                (return
                  (ResultCompilerEhFrameCieParse.Err
                    (compiler-eh-frame-error
                      compiler-eh-frame-error-cie
                      input
                      record
                      (+ data.next 1)
                      "eh_frame: \"zR\" CIE augmentation data must be one pointer-encoding byte"))))
              (when
                (!=
                  (byte_le.byte-le-at bytes augmentation.next)
                  compiler-eh-frame-pe-pcrel-sdata4)
                (return
                  (ResultCompilerEhFrameCieParse.Err
                    (compiler-eh-frame-error
                      compiler-eh-frame-error-cie
                      input
                      record
                      augmentation.next
                      "eh_frame: only the pcrel|sdata4 FDE pointer encoding is admitted"))))
              (when
                (> (- end (+ augmentation.next 1)) limits.max-program-bytes)
                (return
                  (ResultCompilerEhFrameCieParse.Err
                    (compiler-eh-frame-error
                      compiler-eh-frame-error-cfa
                      input
                      record
                      (+ augmentation.next 1)
                      "eh_frame: CFA program byte limit exceeded"))))
              (ResultCompilerEhFrameCieParse.Ok
                (CompilerEhFrameCieParse
                  code.value
                  data.value
                  return-register
                  (+ augmentation.next 1))))))))))

;; The final address an FDE of a linked section at `section-address` covers.
(define (compiler-eh-frame-fde-initial-location
  [fde : (& fde CompilerEhFrameFde)]
  [section-address : i64]) : i64
  (+ (+ section-address fde.location-offset) fde.location-raw))

;; --- canonical encoding ------------------------------------------------------
(define (compiler-eh-frame-selected-fde
  [images : (& images (__tl_dyn-array CompilerEhFrameImage))]
  [selection : (& selection CompilerEhFrameSelection)]) : CompilerEhFrameFde
  (array-ref (array-ref images selection.image).fdes selection.fde))

(define (compiler-eh-frame-selected-cie
  [images : (& images (__tl_dyn-array CompilerEhFrameImage))]
  [selection : (& selection CompilerEhFrameSelection)]) : CompilerEhFrameCie
  (array-ref
    (array-ref images selection.image).cies
    (array-ref (array-ref images selection.image).fdes selection.fde).cie))

(define (compiler-eh-frame-compare-i64 [left : i64] [right : i64]) : i64
  (cond [(< left right) -1] [(> left right) 1] [else 0]))

;; Lexicographic order of two programs, a proper prefix first.
(define (compiler-eh-frame-compare-programs
  [images : (& images (__tl_dyn-array CompilerEhFrameImage))]
  [left-image : i64]
  [left-start : i64]
  [left-length : i64]
  [right-image : i64]
  [right-start : i64]
  [right-length : i64]) : i64
  (let
    [index : i64 0]
    [result : i64 0]
    (begin
      (while (and (= result 0) (< index left-length) (< index right-length))
        (begin
          (set!
            result
            (compiler-eh-frame-compare-i64
              (cast
                (array-ref
                  (array-ref images left-image).programs
                  (+ left-start index))
                : i64)
              (cast
                (array-ref
                  (array-ref images right-image).programs
                  (+ right-start index))
                : i64)))
          (set! index (+ index 1))))
      (if (= result 0)
        (compiler-eh-frame-compare-i64 left-length right-length)
        result))))

;; Canonical CIE contract order: two CIEs compare equal exactly when their
;; encoded records are byte-identical.
(define (compiler-eh-frame-compare-cies
  [images : (& images (__tl_dyn-array CompilerEhFrameImage))]
  [left : (& left CompilerEhFrameSelection)]
  [right : (& right CompilerEhFrameSelection)]) : i64
  (let
    [a : CompilerEhFrameCie (compiler-eh-frame-selected-cie images left)]
    [b : CompilerEhFrameCie (compiler-eh-frame-selected-cie images right)]
    (cond
      [(!= a.code-alignment b.code-alignment)
        (compiler-eh-frame-compare-i64 a.code-alignment b.code-alignment)]
      [(!= a.data-alignment b.data-alignment)
        (compiler-eh-frame-compare-i64 a.data-alignment b.data-alignment)]
      [(!= a.return-register b.return-register)
        (compiler-eh-frame-compare-i64 a.return-register b.return-register)]
      [(!= a.pointer-encoding b.pointer-encoding)
        (compiler-eh-frame-compare-i64 a.pointer-encoding b.pointer-encoding)]
      [else
        (compiler-eh-frame-compare-programs
          images
          left.image
          a.program-start
          a.program-length
          right.image
          b.program-start
          b.program-length)])))

;; Stable input identity of a selection's CIE (`cie?`) or FDE.
(define (compiler-eh-frame-compare-identity
  [images : (& images (__tl_dyn-array CompilerEhFrameImage))]
  [left : (& left CompilerEhFrameSelection)]
  [right : (& right CompilerEhFrameSelection)]
  [cie? : bool]) : i64
  (let
    [a-input : i64
      (if cie?
        (compiler-eh-frame-selected-cie images left).input
        (compiler-eh-frame-selected-fde images left).input)]
    [b-input : i64
      (if cie?
        (compiler-eh-frame-selected-cie images right).input
        (compiler-eh-frame-selected-fde images right).input)]
    [a-offset : i64
      (if cie?
        (compiler-eh-frame-selected-cie images left).offset
        (compiler-eh-frame-selected-fde images left).offset)]
    [b-offset : i64
      (if cie?
        (compiler-eh-frame-selected-cie images right).offset
        (compiler-eh-frame-selected-fde images right).offset)]
    (if (!= a-input b-input)
      (compiler-eh-frame-compare-i64 a-input b-input)
      (compiler-eh-frame-compare-i64 a-offset b-offset))))

;; Sort orders over selection indexes.  CIE order is the canonical contract
;; with identity as the tie-break, so the first of each run of equal contracts
;; is the retained representative.  FDE order groups by retained CIE, then
;; orders by final location, range, program and identity.
(define (compiler-eh-frame-before?
  [images : (& images (__tl_dyn-array CompilerEhFrameImage))]
  [selections : (& selections (__tl_dyn-array CompilerEhFrameSelection))]
  [cie-ids : (& cie-ids (__tl_dyn-array i64))]
  [fde-order? : bool]
  [left : i64]
  [right : i64]) : bool
  (let
    [a : CompilerEhFrameSelection (array-ref selections left)]
    [b : CompilerEhFrameSelection (array-ref selections right)]
    [order : i64
      (if (not fde-order?)
        (let
          [contract : i64 (compiler-eh-frame-compare-cies images (& a) (& b))]
          (if (= contract 0)
            (compiler-eh-frame-compare-identity images (& a) (& b) true)
            contract))
        (let
          [fa : CompilerEhFrameFde
            (compiler-eh-frame-selected-fde images (& a))]
          [fb : CompilerEhFrameFde
            (compiler-eh-frame-selected-fde images (& b))]
          (cond
            [(!= (array-ref cie-ids left) (array-ref cie-ids right))
              (compiler-eh-frame-compare-i64
                (array-ref cie-ids left)
                (array-ref cie-ids right))]
            [(!= a.initial-location b.initial-location)
              (compiler-eh-frame-compare-i64
                a.initial-location
                b.initial-location)]
            [(!= fa.range fb.range)
              (compiler-eh-frame-compare-i64 fa.range fb.range)]
            [else
              (let
                [program : i64
                  (compiler-eh-frame-compare-programs
                    images
                    a.image
                    fa.program-start
                    fa.program-length
                    b.image
                    fb.program-start
                    fb.program-length)]
                (if (= program 0)
                  (compiler-eh-frame-compare-identity images (& a) (& b) false)
                  program))])))]
    (< order 0)))

(define (compiler-eh-frame-sift!
  [images : (& images (__tl_dyn-array CompilerEhFrameImage))]
  [selections : (& selections (__tl_dyn-array CompilerEhFrameSelection))]
  [cie-ids : (& cie-ids (__tl_dyn-array i64))]
  [fde-order? : bool]
  [order : (&mut order (__tl_dyn-array i64))]
  [start : i64]
  [count : i64]) : unit
  (let
    [node : i64 start]
    [done : bool false]
    (while (not done)
      (let
        [left : i64 (+ (* node 2) 1)]
        [right : i64 (+ (* node 2) 2)]
        [largest : i64 node]
        (begin
          (when
            (and
              (< left count)
              (compiler-eh-frame-before?
                images
                selections
                cie-ids
                fde-order?
                (array-ref order largest)
                (array-ref order left)))
            (set! largest left))
          (when
            (and
              (< right count)
              (compiler-eh-frame-before?
                images
                selections
                cie-ids
                fde-order?
                (array-ref order largest)
                (array-ref order right)))
            (set! largest right))
          (if (= largest node)
            (set! done true)
            (let
              [swap : i64 (array-ref order node)]
              (begin
                (set! (array-ref order node) (array-ref order largest))
                (set! (array-ref order largest) swap)
                (set! node largest)))))))))

;; Heapsort `order`, a permutation of selection indexes, in O(n log n)
;; comparisons without auxiliary storage.
(define (compiler-eh-frame-sort!
  [images : (& images (__tl_dyn-array CompilerEhFrameImage))]
  [selections : (& selections (__tl_dyn-array CompilerEhFrameSelection))]
  [cie-ids : (& cie-ids (__tl_dyn-array i64))]
  [fde-order? : bool]
  [order : (&mut order (__tl_dyn-array i64))]) : unit
  (let
    [count : i64 (array-length order)]
    [start : i64 (- (/ count 2) 1)]
    [end : i64 (- count 1)]
    (begin
      (while (>= start 0)
        (begin
          (compiler-eh-frame-sift!
            images
            selections
            cie-ids
            fde-order?
            order
            start
            count)
          (set! start (- start 1))))
      (while (> end 0)
        (let
          [swap : i64 (array-ref order 0)]
          (begin
            (set! (array-ref order 0) (array-ref order end))
            (set! (array-ref order end) swap)
            (compiler-eh-frame-sift!
              images
              selections
              cie-ids
              fde-order?
              order
              0
              end)
            (set! end (- end 1))))))))

(define (compiler-eh-frame-align [size : i64]) : i64
  (* (/ (+ size 7) 8) 8))

;; Encoded CIE record size: length, id, version, "zR\0", the two factors, the
;; return register, augmentation length and encoding byte, program, padding.
(define (compiler-eh-frame-cie-size [cie : (& cie CompilerEhFrameCie)]) : i64
  (compiler-eh-frame-align
    (+
      (+ 15 (leb128.unsigned-size cie.code-alignment))
      (+ (leb128.signed-size cie.data-alignment) cie.program-length))))

;; Encoded FDE record size: length, CIE pointer, location, range, empty
;; augmentation, program, padding.
(define (compiler-eh-frame-fde-size [fde : (& fde CompilerEhFrameFde)]) : i64
  (compiler-eh-frame-align (+ 17 fde.program-length)))

(define (compiler-eh-frame-push-program!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [images : (& images (__tl_dyn-array CompilerEhFrameImage))]
  [image : i64]
  [start : i64]
  [length : i64]) : unit
  (let
    [index : i64 0]
    (while (< index length)
      (begin
        (byte_buf_core.byte-buf-builder-push
          out
          (array-ref (array-ref images image).programs (+ start index)))
        (set! index (+ index 1))))))

(define (compiler-eh-frame-push-padding!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [until : i64]) : unit
  (while (< (byte_buf_core.byte-buf-builder-len out) until)
    (compiler-eh-frame-push-u8! out 0)))

(define (compiler-eh-frame-encode-error [code : i64] [message : String]) : ResultCompilerEhFrameOutput
  (ResultCompilerEhFrameOutput.Err
    (compiler-eh-frame-error code -1 -1 -1 message)))

;; Canonically encode the selected FDEs, and the CIEs they use, as a final
;; `.eh_frame` at `section-address`.  Each retained CIE is followed by its FDEs;
;; CIEs whose records would be byte-identical are merged.  Every FDE's location
;; is relocated to its selection's final address, every CIE pointer is
;; recomputed, records are padded to 8 bytes with DW_CFA_nop, and a zero
;; terminator ends the section.  The rows give each FDE's final address for
;; the search header.
(define (compiler-eh-frame-encode
  [images : (& images (__tl_dyn-array CompilerEhFrameImage))]
  [selections : (& selections (__tl_dyn-array CompilerEhFrameSelection))]
  [section-address : i64]
  [limits : (& limits CompilerEhFrameLimits)]) : ResultCompilerEhFrameOutput
  (let
    [count : i64 (array-length selections)]
    [index : i64 0]
    (begin
      (when
        (not (compiler-eh-frame-limits-valid? limits))
        (return
          (compiler-eh-frame-encode-error
            compiler-eh-frame-error-invalid-limits
            "eh_frame: invalid codec limits")))
      (when
        (> count limits.max-records)
        (return
          (compiler-eh-frame-encode-error
            compiler-eh-frame-error-record-limit
            "eh_frame: record limit exceeded")))
      (when
        (not (compiler-eh-frame-address? section-address))
        (return
          (compiler-eh-frame-encode-error
            compiler-eh-frame-error-address
            "eh_frame: section address outside the supported range")))
      (while (< index count)
        (let
          [selection : CompilerEhFrameSelection (array-ref selections index)]
          (begin
            (when
              (or
                (< selection.image 0)
                (>= selection.image (array-length images))
                (< selection.fde 0)
                (>=
                  selection.fde
                  (array-length (array-ref images selection.image).fdes)))
              (return
                (compiler-eh-frame-encode-error
                  compiler-eh-frame-error-selection
                  "eh_frame: selection names no decoded FDE")))
            (when
              (or
                (not (compiler-eh-frame-address? selection.initial-location))
                (not
                  (compiler-eh-frame-address?
                    (+
                      selection.initial-location
                      (compiler-eh-frame-selected-fde images (& selection)).range))))
              (return
                (compiler-eh-frame-encode-error
                  compiler-eh-frame-error-address
                  "eh_frame: FDE code range outside the supported address range")))
            (set! index (+ index 1)))))
      (let
        [cie-order : (__tl_dyn-array i64) (__tl_make-array i64 count)]
        [fde-order : (__tl_dyn-array i64) (__tl_make-array i64 count)]
        [cie-ids : (__tl_dyn-array i64) (__tl_make-array i64 count)]
        [unique : i64 0]
        (begin
          (set! index 0)
          (while (< index count)
            (begin
              (set! (array-ref cie-order index) index)
              (set! (array-ref fde-order index) index)
              (set! index (+ index 1))))
          (compiler-eh-frame-sort!
            images
            selections
            (& cie-ids)
            false
            (&mut cie-order))
          ;; Number runs of equal contracts in contract order.
          (set! index 0)
          (while (< index count)
            (begin
              (when
                (and
                  (> index 0)
                  (!=
                    (compiler-eh-frame-compare-cies
                      images
                      (&
                        (array-ref selections (array-ref cie-order (- index 1))))
                      (& (array-ref selections (array-ref cie-order index))))
                    0))
                (set! unique (+ unique 1)))
              (set! (array-ref cie-ids (array-ref cie-order index)) unique)
              (set! index (+ index 1))))
          (compiler-eh-frame-sort!
            images
            selections
            (& cie-ids)
            true
            (&mut fde-order))
          ;; The same FDE selected twice, or two images claiming one identity.
          (set! index 1)
          (while (< index count)
            (let
              [previous : CompilerEhFrameSelection
                (array-ref selections (array-ref fde-order (- index 1)))]
              [current : CompilerEhFrameSelection
                (array-ref selections (array-ref fde-order index))]
              (begin
                (when
                  (=
                    (compiler-eh-frame-compare-identity
                      images
                      (& previous)
                      (& current)
                      false)
                    0)
                  (return
                    (compiler-eh-frame-encode-error
                      compiler-eh-frame-error-selection
                      "eh_frame: an FDE identity is selected more than once")))
                (set! index (+ index 1)))))
          (compiler-eh-frame-encode-layout
            images
            selections
            (& cie-order)
            (& fde-order)
            (& cie-ids)
            section-address
            limits))))))

;; Lay out and emit records in FDE order.  The representative of each CIE run
;; is its first member in contract order, recorded in `cie-order`.
(define (compiler-eh-frame-encode-layout
  [images : (& images (__tl_dyn-array CompilerEhFrameImage))]
  [selections : (& selections (__tl_dyn-array CompilerEhFrameSelection))]
  [cie-order : (& cie-order (__tl_dyn-array i64))]
  [fde-order : (& fde-order (__tl_dyn-array i64))]
  [cie-ids : (& cie-ids (__tl_dyn-array i64))]
  [section-address : i64]
  [limits : (& limits CompilerEhFrameLimits)]) : ResultCompilerEhFrameOutput
  (let
    [count : i64 (array-length fde-order)]
    [unique-count : i64
      (if (= count 0)
        0
        (+ (array-ref cie-ids (array-ref cie-order (- count 1))) 1))]
    ;; Selection index of each retained CIE's representative.
    [representatives : (__tl_dyn-array i64) (__tl_make-array i64 unique-count)]
    [index : i64 0]
    [total : i64 4]
    [previous-id : i64 -1]
    (begin
      (while (< index count)
        (let
          [selection : i64 (array-ref cie-order index)]
          [id : i64 (array-ref cie-ids selection)]
          (begin
            (when
              (!= id previous-id)
              (begin
                (set! (array-ref representatives id) selection)
                (set! previous-id id)))
            (set! index (+ index 1)))))
      ;; Size every record before allocating the output.
      (set! index 0)
      (while (< index unique-count)
        (let
          [cie : CompilerEhFrameCie
            (compiler-eh-frame-selected-cie
              images
              (& (array-ref selections (array-ref representatives index))))]
          (begin
            (set! total (+ total (compiler-eh-frame-cie-size (& cie))))
            (set! index (+ index 1)))))
      (set! index 0)
      (while (< index count)
        (let
          [fde : CompilerEhFrameFde
            (compiler-eh-frame-selected-fde
              images
              (& (array-ref selections (array-ref fde-order index))))]
          (begin
            (set! total (+ total (compiler-eh-frame-fde-size (& fde))))
            (set! index (+ index 1)))))
      (when
        (> total limits.max-output-bytes)
        (return
          (compiler-eh-frame-encode-error
            compiler-eh-frame-error-output-limit
            "eh_frame: output byte limit exceeded")))
      (when
        (not (compiler-eh-frame-address? (+ section-address total)))
        (return
          (compiler-eh-frame-encode-error
            compiler-eh-frame-error-address
            "eh_frame: section end outside the supported address range")))
      (let
        [out : byte_buf_core.ByteBufBuilder
          (byte_buf_core.byte-buf-builder-with-capacity total)]
        [rows : (__tl_dyn-array CompilerEhFrameRow)
          (__tl_make-array CompilerEhFrameRow count)]
        [current-id : i64 -1]
        [cie-offset : i64 0]
        (begin
          (set! index 0)
          (while (< index count)
            (let
              [selection : CompilerEhFrameSelection
                (array-ref selections (array-ref fde-order index))]
              [fde : CompilerEhFrameFde
                (compiler-eh-frame-selected-fde images (& selection))]
              [id : i64 (array-ref cie-ids (array-ref fde-order index))]
              (begin
                (when
                  (!= id current-id)
                  (let
                    [representative : CompilerEhFrameSelection
                      (array-ref selections (array-ref representatives id))]
                    [cie : CompilerEhFrameCie
                      (compiler-eh-frame-selected-cie images (& representative))]
                    [size : i64 (compiler-eh-frame-cie-size (& cie))]
                    (begin
                      (set!
                        cie-offset
                        (byte_buf_core.byte-buf-builder-len (& out)))
                      (set! current-id id)
                      (byte_le.push-u32! (&mut out) (- size 4))
                      (byte_le.push-u32! (&mut out) 0)
                      (compiler-eh-frame-push-u8! (&mut out) 1)
                      (compiler-eh-frame-push-u8! (&mut out) 122)
                      (compiler-eh-frame-push-u8! (&mut out) 82)
                      (compiler-eh-frame-push-u8! (&mut out) 0)
                      (leb128.push-unsigned! (&mut out) cie.code-alignment)
                      (leb128.push-signed! (&mut out) cie.data-alignment)
                      (compiler-eh-frame-push-u8!
                        (&mut out)
                        cie.return-register)
                      (compiler-eh-frame-push-u8! (&mut out) 1)
                      (compiler-eh-frame-push-u8!
                        (&mut out)
                        cie.pointer-encoding)
                      (compiler-eh-frame-push-program!
                        (&mut out)
                        images
                        representative.image
                        cie.program-start
                        cie.program-length)
                      (compiler-eh-frame-push-padding!
                        (&mut out)
                        (+ cie-offset size)))))
                (let
                  [fde-offset : i64
                    (byte_buf_core.byte-buf-builder-len (& out))]
                  [size : i64 (compiler-eh-frame-fde-size (& fde))]
                  [field : i64 (+ (+ section-address fde-offset) 8)]
                  [location : i64 (- selection.initial-location field)]
                  [cie-pointer : i64 (- (+ fde-offset 4) cie-offset)]
                  (begin
                    (when
                      (not (compiler-eh-frame-i32? location))
                      (return
                        (compiler-eh-frame-encode-error
                          compiler-eh-frame-error-address
                          "eh_frame: FDE initial location displacement overflows sdata4")))
                    (when
                      (> cie-pointer 4294967295)
                      (return
                        (compiler-eh-frame-encode-error
                          compiler-eh-frame-error-address
                          "eh_frame: CIE pointer overflows its 32-bit field")))
                    (byte_le.push-u32! (&mut out) (- size 4))
                    (byte_le.push-u32! (&mut out) cie-pointer)
                    (byte_le.push-u32! (&mut out) location)
                    (byte_le.push-u32! (&mut out) fde.range)
                    (compiler-eh-frame-push-u8! (&mut out) 0)
                    (compiler-eh-frame-push-program!
                      (&mut out)
                      images
                      selection.image
                      fde.program-start
                      fde.program-length)
                    (compiler-eh-frame-push-padding!
                      (&mut out)
                      (+ fde-offset size))
                    (set!
                      (array-ref rows index)
                      (CompilerEhFrameRow
                        selection.initial-location
                        fde.range
                        (+ section-address fde-offset)))))
                (set! index (+ index 1)))))
          (byte_le.push-u32! (&mut out) 0)
          ;; Two FDEs claiming one code address leave an unwinder no way to
          ;; choose, whether or not a search header is built.
          (let
            [_ (try (compiler-eh-frame-sorted-rows (& rows)))]
            (ResultCompilerEhFrameOutput.Ok
              (CompilerEhFrameOutput
                (byte_buf_core.byte-buf-builder-finish-array (& out))
                rows))))))))

;; --- .eh_frame_hdr -----------------------------------------------------------
(define (compiler-eh-frame-header-error
  [code : i64]
  [offset : i64]
  [message : String]) : CompilerEhFrameError
  (compiler-eh-frame-error code -1 -1 offset message))

(define (compiler-eh-frame-row-before?
  [rows : (& rows (__tl_dyn-array CompilerEhFrameRow))]
  [left : i64]
  [right : i64]) : bool
  (let
    [a : CompilerEhFrameRow (array-ref rows left)]
    [b : CompilerEhFrameRow (array-ref rows right)]
    (cond
      [(!= a.initial-location b.initial-location)
        (< a.initial-location b.initial-location)]
      [(!= a.range b.range) (< a.range b.range)]
      [else (< a.fde-address b.fde-address)])))

;; Heap step over `order`, a permutation of row indexes.  Sorting indexes keeps
;; the rows themselves in place.
(define (compiler-eh-frame-row-sift!
  [rows : (& rows (__tl_dyn-array CompilerEhFrameRow))]
  [order : (&mut order (__tl_dyn-array i64))]
  [start : i64]
  [count : i64]) : unit
  (let
    [node : i64 start]
    [done : bool false]
    (while (not done)
      (let
        [left : i64 (+ (* node 2) 1)]
        [right : i64 (+ (* node 2) 2)]
        [largest : i64 node]
        (begin
          (when
            (and
              (< left count)
              (compiler-eh-frame-row-before?
                rows
                (array-ref order largest)
                (array-ref order left)))
            (set! largest left))
          (when
            (and
              (< right count)
              (compiler-eh-frame-row-before?
                rows
                (array-ref order largest)
                (array-ref order right)))
            (set! largest right))
          (if (= largest node)
            (set! done true)
            (let
              [swap : i64 (array-ref order node)]
              (begin
                (set! (array-ref order node) (array-ref order largest))
                (set! (array-ref order largest) swap)
                (set! node largest)))))))))

;; `rows` sorted by initial location, or the first row set a binary search
;; could not resolve: a range that is empty or leaves the address domain, two
;; rows at one location, or overlapping ranges.  Both the .eh_frame encoder
;; (for its own rows) and the header encoder apply it.
(define (compiler-eh-frame-sorted-rows
  [rows : (& rows (__tl_dyn-array CompilerEhFrameRow))]) : ResultCompilerEhFrameRows
  (let
    [count : i64 (array-length rows)]
    [order : (__tl_dyn-array i64) (__tl_make-array i64 count)]
    [sorted : (__tl_dyn-array CompilerEhFrameRow)
      (__tl_make-array CompilerEhFrameRow count)]
    [index : i64 0]
    (begin
      (while (< index count)
        (let
          [row : CompilerEhFrameRow (array-ref rows index)]
          (begin
            (when
              (or
                (<= row.range 0)
                (not (compiler-eh-frame-address? row.initial-location))
                (not
                  (compiler-eh-frame-address?
                    (+ row.initial-location row.range)))
                (not (compiler-eh-frame-address? row.fde-address)))
              (return
                (ResultCompilerEhFrameRows.Err
                  (compiler-eh-frame-header-error
                    compiler-eh-frame-error-address
                    -1
                    "eh_frame: FDE range or address outside the supported range"))))
            (set! (array-ref order index) index)
            (set! index (+ index 1)))))
      (set! index (- (/ count 2) 1))
      (while (>= index 0)
        (begin
          (compiler-eh-frame-row-sift! rows (&mut order) index count)
          (set! index (- index 1))))
      (set! index (- count 1))
      (while (> index 0)
        (let
          [swap : i64 (array-ref order 0)]
          (begin
            (set! (array-ref order 0) (array-ref order index))
            (set! (array-ref order index) swap)
            (compiler-eh-frame-row-sift! rows (&mut order) 0 index)
            (set! index (- index 1)))))
      (set! index 0)
      (while (< index count)
        (begin
          (set!
            (array-ref sorted index)
            (array-ref rows (array-ref order index)))
          (set! index (+ index 1))))
      (set! index 1)
      (while (< index count)
        (let
          [previous : CompilerEhFrameRow (array-ref sorted (- index 1))]
          [current : CompilerEhFrameRow (array-ref sorted index)]
          (begin
            (when
              (= previous.initial-location current.initial-location)
              (return
                (ResultCompilerEhFrameRows.Err
                  (compiler-eh-frame-header-error
                    compiler-eh-frame-error-header-order
                    -1
                    "eh_frame: two FDEs share an initial location"))))
            (when
              (>
                (+ previous.initial-location previous.range)
                current.initial-location)
              (return
                (ResultCompilerEhFrameRows.Err
                  (compiler-eh-frame-header-error
                    compiler-eh-frame-error-header-order
                    -1
                    "eh_frame: FDE code ranges overlap"))))
            (set! index (+ index 1)))))
      (ResultCompilerEhFrameRows.Ok sorted))))

;; Encode the version-1 search header at `header-address` for `rows` of a
;; final `.eh_frame` at `eh-frame-address`.  The eh_frame pointer is relative
;; to its own field (the header's fifth byte); both words of every table row
;; are relative to the header start.  Rows are sorted by initial location;
;; duplicate locations and overlapping ranges are ambiguous for a binary
;; search and rejected.  No rows means no header.
(define (compiler-eh-frame-encode-header
  [rows : (& rows (__tl_dyn-array CompilerEhFrameRow))]
  [header-address : i64]
  [eh-frame-address : i64]
  [limits : (& limits CompilerEhFrameLimits)]) : ResultCompilerEhFrameHeaderBytes
  (let
    [count : i64 (array-length rows)]
    [size : i64 (+ compiler-eh-frame-header-size (* count 8))]
    (begin
      (when
        (not (compiler-eh-frame-limits-valid? limits))
        (return
          (ResultCompilerEhFrameHeaderBytes.Err
            (compiler-eh-frame-header-error
              compiler-eh-frame-error-invalid-limits
              -1
              "eh_frame_hdr: invalid codec limits"))))
      (when (= count 0) (return ResultCompilerEhFrameHeaderBytes.NoHeader))
      (when
        (or (> count 4294967295) (> count limits.max-records))
        (return
          (ResultCompilerEhFrameHeaderBytes.Err
            (compiler-eh-frame-header-error
              compiler-eh-frame-error-record-limit
              -1
              "eh_frame_hdr: FDE count exceeds the header or record limit"))))
      (when
        (> size limits.max-output-bytes)
        (return
          (ResultCompilerEhFrameHeaderBytes.Err
            (compiler-eh-frame-header-error
              compiler-eh-frame-error-output-limit
              -1
              "eh_frame_hdr: output byte limit exceeded"))))
      (when
        (or
          (not (compiler-eh-frame-address? header-address))
          (not (compiler-eh-frame-address? eh-frame-address)))
        (return
          (ResultCompilerEhFrameHeaderBytes.Err
            (compiler-eh-frame-header-error
              compiler-eh-frame-error-address
              -1
              "eh_frame_hdr: section address outside the supported range"))))
      (match (compiler-eh-frame-sorted-rows rows)
        [(ResultCompilerEhFrameRows.Err error)
          (ResultCompilerEhFrameHeaderBytes.Err error)]
        [(ResultCompilerEhFrameRows.Ok sorted)
          (let
            [index : i64 0]
            [out : byte_buf_core.ByteBufBuilder
              (byte_buf_core.byte-buf-builder-with-capacity size)]
            [pointer : i64 (- eh-frame-address (+ header-address 4))]
            (begin
              (when
                (not (compiler-eh-frame-i32? pointer))
                (return
                  (ResultCompilerEhFrameHeaderBytes.Err
                    (compiler-eh-frame-header-error
                      compiler-eh-frame-error-address
                      4
                      "eh_frame_hdr: eh_frame pointer displacement overflows sdata4"))))
              (compiler-eh-frame-push-u8!
                (&mut out)
                compiler-eh-frame-header-version)
              (compiler-eh-frame-push-u8!
                (&mut out)
                compiler-eh-frame-pe-pcrel-sdata4)
              (compiler-eh-frame-push-u8!
                (&mut out)
                compiler-eh-frame-pe-udata4)
              (compiler-eh-frame-push-u8!
                (&mut out)
                compiler-eh-frame-pe-datarel-sdata4)
              (byte_le.push-u32! (&mut out) pointer)
              (byte_le.push-u32! (&mut out) count)
              (set! index 0)
              (while (< index count)
                (let
                  [row : CompilerEhFrameRow (array-ref sorted index)]
                  [location : i64 (- row.initial-location header-address)]
                  [fde : i64 (- row.fde-address header-address)]
                  (begin
                    (when
                      (or
                        (not (compiler-eh-frame-i32? location))
                        (not (compiler-eh-frame-i32? fde)))
                      (return
                        (ResultCompilerEhFrameHeaderBytes.Err
                          (compiler-eh-frame-header-error
                            compiler-eh-frame-error-address
                            (+ compiler-eh-frame-header-size (* index 8))
                            "eh_frame_hdr: table displacement overflows sdata4"))))
                    (byte_le.push-u32! (&mut out) location)
                    (byte_le.push-u32! (&mut out) fde)
                    (set! index (+ index 1)))))
              (ResultCompilerEhFrameHeaderBytes.Ok
                (byte_buf_core.byte-buf-builder-finish-array (& out)))))]))))

;; Decode a version-1 search header at `header-address`: the eh_frame pointer
;; against its own field, each row against the header start.  The table must
;; be strictly sorted by initial location and fill the section exactly.  A
;; decoded row's range is unknown to the header and reported as 0.
(define (compiler-eh-frame-decode-header
  [bytes : (& bytes (__tl_dyn-array u8))]
  [header-address : i64]
  [limits : (& limits CompilerEhFrameLimits)]) : ResultCompilerEhFrameHeader
  (let
    [length : i64 (array-length bytes)]
    (begin
      (when
        (not (compiler-eh-frame-limits-valid? limits))
        (return
          (ResultCompilerEhFrameHeader.Err
            (compiler-eh-frame-header-error
              compiler-eh-frame-error-invalid-limits
              -1
              "eh_frame_hdr: invalid codec limits"))))
      (when
        (> length limits.max-input-bytes)
        (return
          (ResultCompilerEhFrameHeader.Err
            (compiler-eh-frame-header-error
              compiler-eh-frame-error-input-limit
              0
              "eh_frame_hdr: input byte limit exceeded"))))
      (when
        (not (compiler-eh-frame-address? header-address))
        (return
          (ResultCompilerEhFrameHeader.Err
            (compiler-eh-frame-header-error
              compiler-eh-frame-error-address
              -1
              "eh_frame_hdr: section address outside the supported range"))))
      (when
        (< length compiler-eh-frame-header-size)
        (return
          (ResultCompilerEhFrameHeader.Err
            (compiler-eh-frame-header-error
              compiler-eh-frame-error-truncated
              length
              "eh_frame_hdr: truncated header"))))
      (when
        (or
          (!= (byte_le.byte-le-at bytes 0) compiler-eh-frame-header-version)
          (!= (byte_le.byte-le-at bytes 1) compiler-eh-frame-pe-pcrel-sdata4)
          (!= (byte_le.byte-le-at bytes 2) compiler-eh-frame-pe-udata4)
          (!= (byte_le.byte-le-at bytes 3) compiler-eh-frame-pe-datarel-sdata4))
        (return
          (ResultCompilerEhFrameHeader.Err
            (compiler-eh-frame-header-error
              compiler-eh-frame-error-header
              0
              "eh_frame_hdr: only version 1 with pcrel|sdata4, udata4 and datarel|sdata4 is admitted"))))
      (let
        [count : i64 (byte_le.read-u32 bytes 8)]
        (begin
          (when
            (> count limits.max-records)
            (return
              (ResultCompilerEhFrameHeader.Err
                (compiler-eh-frame-header-error
                  compiler-eh-frame-error-record-limit
                  8
                  "eh_frame_hdr: FDE count exceeds the record limit"))))
          (when
            (!= length (+ compiler-eh-frame-header-size (* count 8)))
            (return
              (ResultCompilerEhFrameHeader.Err
                (compiler-eh-frame-header-error
                  compiler-eh-frame-error-header
                  8
                  "eh_frame_hdr: table size does not match the FDE count"))))
          (let
            [rows : (__tl_dyn-array CompilerEhFrameRow)
              (__tl_make-array CompilerEhFrameRow count)]
            [index : i64 0]
            (begin
              (while (< index count)
                (let
                  [at : i64 (+ compiler-eh-frame-header-size (* index 8))]
                  [location : i64
                    (+ header-address (compiler-eh-frame-read-i32 bytes at))]
                  (begin
                    (when
                      (and
                        (> index 0)
                        (<=
                          location
                          (array-ref rows (- index 1)).initial-location))
                      (return
                        (ResultCompilerEhFrameHeader.Err
                          (compiler-eh-frame-header-error
                            compiler-eh-frame-error-header-order
                            at
                            "eh_frame_hdr: table is not strictly sorted by initial location"))))
                    (set!
                      (array-ref rows index)
                      (CompilerEhFrameRow
                        location
                        0
                        (+
                          header-address
                          (compiler-eh-frame-read-i32 bytes (+ at 4)))))
                    (set! index (+ index 1)))))
              (ResultCompilerEhFrameHeader.Ok
                (CompilerEhFrameHeader
                  (+ (+ header-address 4) (compiler-eh-frame-read-i32 bytes 4))
                  rows)))))))))