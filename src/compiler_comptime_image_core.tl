;; compiler_comptime_image_core.tl - Focused native-comptime lowering proof.
;;
;; This is deliberately narrower than general macro-source lowering: it gives
;; the first code-bearing tlci image a real compiler-owned program model and an
;; explicit callback-probe instruction. Automatic call/backedge probe insertion
;; and general stdlib/package macro lowering build on this status convention.
(import stdlib.byte_buf_core)
(import stdlib.string)

(defenum CompilerComptimeProbe
  (ExplicitCallback i64))

(defstruct CompilerComptimeMacroProgram
  (macro-name String)
  (probe CompilerComptimeProbe)
  (session-cookie i64)
  (success-result-handle i64))

(defstruct CompilerComptimeImagePayload
  (code (Array u8))
  (macro-entry-offset i64)
  (macro-table-offset i64)
  (macro-name-offset i64))

(defenum ResultCompilerComptimeImagePayload
  (Ok CompilerComptimeImagePayload)
  (Err String))

(define (compiler-comptime-probe-program) : CompilerComptimeMacroProgram
  (CompilerComptimeMacroProgram
    "native-probe"
    (CompilerComptimeProbe.ExplicitCallback 1)
    0x5151
    4242))

(define (compiler-comptime-hex-value [ch : char]) : i64
  (cond
    [(and (>= ch '0') (<= ch '9')) (- (cast ch : i64) (cast '0' : i64))]
    [(and (>= ch 'a') (<= ch 'f')) (+ 10 (- (cast ch : i64) (cast 'a' : i64)))]
    [(and (>= ch 'A') (<= ch 'F')) (+ 10 (- (cast ch : i64) (cast 'A' : i64)))]
    [else 0]))

(define (compiler-comptime-byte-array-from-hex [hex : String]) : (Array u8)
  (let
    [out : byte_buf_core.ByteBufBuilder (byte_buf_core.byte-buf-builder-new)]
    [index : i64 0]
    [count : i64 (string.string-length hex)]
    (begin
      (while (< (+ index 1) count)
        (begin
          (byte_buf_core.byte-buf-builder-push
            (&mut out)
            (cast
              (+
                (*
                  16
                  (compiler-comptime-hex-value (string.string-ref hex index)))
                (compiler-comptime-hex-value
                  (string.string-ref hex (+ index 1))))
              : u8))
          (set! index (+ index 2))))
      (byte_buf_core.byte-buf-builder-finish-array (& out)))))

(define (compiler-comptime-set-u32!
  [bytes : (Array u8)]
  [offset : i64]
  [value : i64]) : unit
  (begin
    (array-set! bytes offset (cast (bit-and value 0xff) : u8))
    (array-set! bytes (+ offset 1) (cast (bit-and (shr value 8) 0xff) : u8))
    (array-set! bytes (+ offset 2) (cast (bit-and (shr value 16) 0xff) : u8))
    (array-set! bytes (+ offset 3) (cast (bit-and (shr value 24) 0xff) : u8))))

(define (compiler-comptime-put-name!
  [bytes : (Array u8)]
  [offset : i64]
  [name : String]) : unit
  (let
    [index : i64 0]
    [count : i64 (string.string-length name)]
    (begin
      (while (< index count)
        (begin
          (array-set!
            bytes
            (+ offset index)
            (cast (string.string-ref name index) : u8))
          (set! index (+ index 1))))
      unit)))

(define (compiler-comptime-windows-template) : (Array u8)
  (compiler-comptime-byte-array-from-hex
    "48b8544c4349494d414748890248c742080100000048c742104000000048894a1848c742200000000048c7422800000000488d05900000004889423048c742380100000031c0c3660f1f8400000000004883f90476134c8b4c24304883ec28e81c0000004883c428c34881fa5151000075044889c8c3b804000000c30f1f400041544d89cc488b41304889d14c89c241b8010000004531c94883ec3048c74424200000000048c744242800000000ffd04883c4304885c0750849c7042492100000415cc30f1f400000000000000000000c00000000000000000000000000000000000000000000006e61746976652d70726f6265"))

(define (compiler-comptime-linux-template) : (Array u8)
  (compiler-comptime-byte-array-from-hex
    "48b8544c4349494d414748890648c746080100000048c746104000000048897e1848c746200000000048c7462800000000488d05780000004889463048c746380100000031c0c3660f1f8400000000004883ff0476114c89c94883ec08e81e0000004883c408c34881fe5151000075044889f8c3b804000000c3660f1f44000041544989cc488b47304889f74889d6ba0100000031c94531c04531c9ffd04885c0750849c7042492100000415cc3669000000000000000000c000000000000000000000000000000000000000000000006e61746976652d70726f6265"))

(define (compiler-comptime-lower-probe
  [program : CompilerComptimeMacroProgram]
  [windows-target : bool]) : ResultCompilerComptimeImagePayload
  (let
    [code : (Array u8)
      (if windows-target
        (compiler-comptime-windows-template)
        (compiler-comptime-linux-template))]
    [macro-entry-offset : i64 0x50]
    [macro-table-offset : i64
      (if windows-target
        0xc8
        0xb0)]
    [macro-name-offset : i64
      (if windows-target
        0xe8
        0xd0)]
    [session-immediate-offset : i64
      (if windows-target
        0x6c
        0x6a)]
    [callback-immediate-offset : i64
      (if windows-target
        0x91
        0x90)]
    [result-immediate-offset : i64
      (if windows-target
        0xbd
        0xa7)]
    [name : String (struct-get program macro-name)]
    [callback-op : i64
      (match (struct-get program probe)
        [(CompilerComptimeProbe.ExplicitCallback operation) operation])]
    ;; The v1 proof record reserves twelve bytes for the single macro name.
    ;; General symbol/data layout is part of package image emission.
    (if (not (= (string.string-length name) 12))
      (ResultCompilerComptimeImagePayload.Err
        "native comptime probe macro name must be 12 bytes")
      (begin
        (compiler-comptime-set-u32!
          code
          session-immediate-offset
          (struct-get program session-cookie))
        (compiler-comptime-set-u32! code callback-immediate-offset callback-op)
        (compiler-comptime-set-u32!
          code
          result-immediate-offset
          (struct-get program success-result-handle))
        (compiler-comptime-put-name! code macro-name-offset name)
        (ResultCompilerComptimeImagePayload.Ok
          (CompilerComptimeImagePayload
            code
            macro-entry-offset
            macro-table-offset
            macro-name-offset))))))