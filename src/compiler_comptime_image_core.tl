;; compiler_comptime_image_core.tl - Focused native-comptime lowering proof.
;;
;; This is deliberately narrower than general macro-source lowering: it gives
;; the first code-bearing tlci image a real compiler-owned program model and an
;; explicit callback-probe instruction. Automatic call/backedge probe insertion
;; and general stdlib/package macro lowering build on this status convention.
(import stdlib.byte_buf_core)
(import stdlib.io)
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

;; Host-comptime lowering is intentionally separate from ordinary source/runtime
;; lowering. These modes select only the host C ABI used by a mapped tlci image.
(defenum CompilerComptimeLowerMode
  (LinuxX64)
  (WindowsX64))

;; Every status-capable native helper receives these three opaque contexts in
;; this order. Keeping the positions explicit gives later automatic fuel probes
;; one insertion primitive without adding state to the image.
(defstruct CompilerComptimeContextParams
  (image i64)
  (host i64)
  (session i64))

(defstruct CompilerComptimeStatusProbe
  (operation i64))

(defstruct CompilerComptimeHelperIr
  (contexts CompilerComptimeContextParams)
  (probe CompilerComptimeStatusProbe)
  (success-result-handle i64))

(defstruct CompilerComptimeMacroIr
  (mode CompilerComptimeLowerMode)
  (macro-name String)
  (session-cookie i64)
  (contexts CompilerComptimeContextParams)
  (helper CompilerComptimeHelperIr))

(defstruct CompilerComptimeRelativePatch
  (displacement i64)
  (rip-after i64))

(define (compiler-comptime-context-params) : CompilerComptimeContextParams
  (CompilerComptimeContextParams 0 1 2))

;; Explicit call/backedge insertion boundary for #2656. Automatic placement is
;; deliberately out of scope; callers choose the catalog operation here.
(define (compiler-comptime-status-probe [operation : i64]) : CompilerComptimeStatusProbe
  (CompilerComptimeStatusProbe operation))

(define (compiler-comptime-program-to-host-ir
  [program : CompilerComptimeMacroProgram]
  [windows-target : bool]) : CompilerComptimeMacroIr
  (let
    [contexts : CompilerComptimeContextParams
      (compiler-comptime-context-params)]
    [operation : i64
      (match (struct-get program probe)
        [(CompilerComptimeProbe.ExplicitCallback value) value])]
    (CompilerComptimeMacroIr
      (if windows-target
        (CompilerComptimeLowerMode.WindowsX64)
        (CompilerComptimeLowerMode.LinuxX64))
      (struct-get program macro-name)
      (struct-get program session-cookie)
      contexts
      (CompilerComptimeHelperIr
        contexts
        (compiler-comptime-status-probe operation)
        (struct-get program success-result-handle)))))

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

(define (compiler-comptime-emit-byte!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [value : i64]) : unit
  (byte_buf_core.byte-buf-builder-push out (cast (bit-and value 0xff) : u8)))

(define (compiler-comptime-emit-bytes!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [values : (Array i64)]) : unit
  (let
    [index : i64 0]
    (begin
      (while (< index (array-length values))
        (begin
          (compiler-comptime-emit-byte! out (array-ref values index))
          (set! index (+ index 1))))
      unit)))

(define (compiler-comptime-emit-u32!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [value : i64]) : unit
  (begin
    (compiler-comptime-emit-byte! out value)
    (compiler-comptime-emit-byte! out (shr value 8))
    (compiler-comptime-emit-byte! out (shr value 16))
    (compiler-comptime-emit-byte! out (shr value 24))))

(define (compiler-comptime-emit-u64!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [value : i64]) : unit
  (begin
    (compiler-comptime-emit-u32! out value)
    (compiler-comptime-emit-u32! out (shr value 32))))

(define (compiler-comptime-emit-name!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [name : String]) : unit
  (let
    [index : i64 0]
    (begin
      (while (< index (string.string-length name))
        (begin
          (byte_buf_core.byte-buf-builder-push
            out
            (cast (string.string-ref name index) : u8))
          (set! index (+ index 1))))
      unit)))

;; Emit Intel-recommended multi-byte NOPs for the only alignment gaps used by
;; this compact host-comptime image. Other sizes fall back to one-byte NOPs.
(define (compiler-comptime-emit-nops!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [count : i64]) : unit
  (match count
    [2 (compiler-comptime-emit-bytes! out (make-array 0x66 0x90))]
    [4 (compiler-comptime-emit-bytes! out (make-array 0x0f 0x1f 0x40 0x00))]
    [6
      (compiler-comptime-emit-bytes!
        out
        (make-array 0x66 0x0f 0x1f 0x44 0x00 0x00))]
    [9
      (compiler-comptime-emit-bytes!
        out
        (make-array 0x66 0x0f 0x1f 0x84 0x00 0x00 0x00 0x00 0x00))]
    [_
      (let
        [index : i64 0]
        (begin
          (while (< index count)
            (begin
              (compiler-comptime-emit-byte! out 0x90)
              (set! index (+ index 1))))
          unit))]))

(define (compiler-comptime-align-code!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [alignment : i64]) : unit
  (let
    [len : i64 (struct-get out len)]
    [remainder : i64 (% len alignment)]
    (if (= remainder 0)
      unit
      (compiler-comptime-emit-nops! out (- alignment remainder)))))

;; Lower the image registration entry. The single RIP-relative table address is
;; patched after code/data layout is complete.
(define (compiler-comptime-emit-registration!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [mode : CompilerComptimeLowerMode]) : CompilerComptimeRelativePatch
  (begin
    ;; rax = "TLCIIMAG"; registration.magic = rax.
    (compiler-comptime-emit-bytes! out (make-array 0x48 0xb8))
    (compiler-comptime-emit-u64! out 0x47414d4949434c54)
    (match mode
      [(CompilerComptimeLowerMode.LinuxX64)
        (begin
          (compiler-comptime-emit-bytes! out (make-array 0x48 0x89 0x06))
          (compiler-comptime-emit-bytes! out (make-array 0x48 0xc7 0x46 0x08))
          (compiler-comptime-emit-u32! out 1)
          (compiler-comptime-emit-bytes! out (make-array 0x48 0xc7 0x46 0x10))
          (compiler-comptime-emit-u32! out 64)
          ;; Preserve the callback-table pointer as the opaque image context.
          (compiler-comptime-emit-bytes! out (make-array 0x48 0x89 0x7e 0x18))
          (compiler-comptime-emit-bytes! out (make-array 0x48 0xc7 0x46 0x20))
          (compiler-comptime-emit-u32! out 0)
          (compiler-comptime-emit-bytes! out (make-array 0x48 0xc7 0x46 0x28))
          (compiler-comptime-emit-u32! out 0))]
      [(CompilerComptimeLowerMode.WindowsX64)
        (begin
          (compiler-comptime-emit-bytes! out (make-array 0x48 0x89 0x02))
          (compiler-comptime-emit-bytes! out (make-array 0x48 0xc7 0x42 0x08))
          (compiler-comptime-emit-u32! out 1)
          (compiler-comptime-emit-bytes! out (make-array 0x48 0xc7 0x42 0x10))
          (compiler-comptime-emit-u32! out 64)
          (compiler-comptime-emit-bytes! out (make-array 0x48 0x89 0x4a 0x18))
          (compiler-comptime-emit-bytes! out (make-array 0x48 0xc7 0x42 0x20))
          (compiler-comptime-emit-u32! out 0)
          (compiler-comptime-emit-bytes! out (make-array 0x48 0xc7 0x42 0x28))
          (compiler-comptime-emit-u32! out 0))])
    (compiler-comptime-emit-bytes! out (make-array 0x48 0x8d 0x05))
    (let
      [displacement : i64 (struct-get out len)]
      (begin
        (compiler-comptime-emit-u32! out 0)
        (match mode
          [(CompilerComptimeLowerMode.LinuxX64)
            (compiler-comptime-emit-bytes! out (make-array 0x48 0x89 0x46 0x30))]
          [(CompilerComptimeLowerMode.WindowsX64)
            (compiler-comptime-emit-bytes! out (make-array 0x48 0x89 0x42 0x30))])
        (match mode
          [(CompilerComptimeLowerMode.LinuxX64)
            (compiler-comptime-emit-bytes! out (make-array 0x48 0xc7 0x46 0x38))]
          [(CompilerComptimeLowerMode.WindowsX64)
            (compiler-comptime-emit-bytes! out (make-array 0x48 0xc7 0x42 0x38))])
        (compiler-comptime-emit-u32! out 1)
        (compiler-comptime-emit-bytes! out (make-array 0x31 0xc0 0xc3))
        (compiler-comptime-align-code! out 16)
        (CompilerComptimeRelativePatch displacement (+ displacement 4))))))

;; Lower the public six-argument macro entry. Normal invocations forward all
;; three contexts and the result slot to the helper. The <=4 path is the
;; proof-only self-callback adapter used by the host smoke to return statuses
;; (including fuel status 2) without committing the public result slot.
(define (compiler-comptime-emit-macro-entry!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [mode : CompilerComptimeLowerMode]
  [session-cookie : i64]) : CompilerComptimeRelativePatch
  (begin
    (match mode
      [(CompilerComptimeLowerMode.LinuxX64)
        (begin
          (compiler-comptime-emit-bytes!
            out
            (make-array 0x48 0x83 0xff 0x04 0x76 0x11 0x4c 0x89 0xc9))
          (compiler-comptime-emit-bytes! out (make-array 0x48 0x83 0xec 0x08)))]
      [(CompilerComptimeLowerMode.WindowsX64)
        (begin
          (compiler-comptime-emit-bytes!
            out
            (make-array 0x48 0x83 0xf9 0x04 0x76 0x13 0x4c 0x8b 0x4c 0x24 0x30))
          (compiler-comptime-emit-bytes! out (make-array 0x48 0x83 0xec 0x28)))])
    (compiler-comptime-emit-byte! out 0xe8)
    (let
      [displacement : i64 (struct-get out len)]
      (begin
        (compiler-comptime-emit-u32! out 0)
        (match mode
          [(CompilerComptimeLowerMode.LinuxX64)
            (compiler-comptime-emit-bytes!
              out
              (make-array 0x48 0x83 0xc4 0x08 0xc3 0x48 0x81 0xfe))]
          [(CompilerComptimeLowerMode.WindowsX64)
            (compiler-comptime-emit-bytes!
              out
              (make-array 0x48 0x83 0xc4 0x28 0xc3 0x48 0x81 0xfa))])
        (compiler-comptime-emit-u32! out session-cookie)
        (compiler-comptime-emit-bytes! out (make-array 0x75 0x04))
        (match mode
          [(CompilerComptimeLowerMode.LinuxX64)
            (compiler-comptime-emit-bytes! out (make-array 0x48 0x89 0xf8 0xc3))]
          [(CompilerComptimeLowerMode.WindowsX64)
            (compiler-comptime-emit-bytes! out (make-array 0x48 0x89 0xc8 0xc3))])
        (compiler-comptime-emit-byte! out 0xb8)
        (compiler-comptime-emit-u32! out 4)
        (compiler-comptime-emit-byte! out 0xc3)
        (compiler-comptime-align-code! out 16)
        (CompilerComptimeRelativePatch displacement (+ displacement 4))))))

;; Lower one status/out-slot helper. It loads invoke from callback-table offset
;; 48, passes host/session contexts and an explicit operation, and returns every
;; nonzero status unchanged. Only status zero commits the helper result slot.
(define (compiler-comptime-emit-helper!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [mode : CompilerComptimeLowerMode]
  [helper : CompilerComptimeHelperIr]) : unit
  (let
    [operation : i64
      (match (struct-get helper probe)
        [(CompilerComptimeStatusProbe value) value])]
    [result : i64 (struct-get helper success-result-handle)]
    (begin
      (compiler-comptime-emit-bytes! out (make-array 0x41 0x54))
      (match mode
        [(CompilerComptimeLowerMode.LinuxX64)
          (begin
            (compiler-comptime-emit-bytes!
              out
              (make-array
                0x49
                0x89
                0xcc
                0x48
                0x8b
                0x47
                0x30
                0x48
                0x89
                0xf7
                0x48
                0x89
                0xd6
                0xba))
            (compiler-comptime-emit-u32! out operation)
            (compiler-comptime-emit-bytes!
              out
              (make-array 0x31 0xc9 0x45 0x31 0xc0 0x45 0x31 0xc9 0xff 0xd0)))]
        [(CompilerComptimeLowerMode.WindowsX64)
          (begin
            (compiler-comptime-emit-bytes!
              out
              (make-array
                0x4d
                0x89
                0xcc
                0x48
                0x8b
                0x41
                0x30
                0x48
                0x89
                0xd1
                0x4c
                0x89
                0xc2
                0x41
                0xb8))
            (compiler-comptime-emit-u32! out operation)
            (compiler-comptime-emit-bytes!
              out
              (make-array
                0x45
                0x31
                0xc9
                0x48
                0x83
                0xec
                0x30
                0x48
                0xc7
                0x44
                0x24
                0x20))
            (compiler-comptime-emit-u32! out 0)
            (compiler-comptime-emit-bytes!
              out
              (make-array 0x48 0xc7 0x44 0x24 0x28))
            (compiler-comptime-emit-u32! out 0)
            (compiler-comptime-emit-bytes!
              out
              (make-array 0xff 0xd0 0x48 0x83 0xc4 0x30)))])
      (compiler-comptime-emit-bytes! out (make-array 0x48 0x85 0xc0 0x75 0x08))
      (compiler-comptime-emit-bytes! out (make-array 0x49 0xc7 0x04 0x24))
      (compiler-comptime-emit-u32! out result)
      (compiler-comptime-emit-bytes! out (make-array 0x41 0x5c 0xc3))
      unit)))

(define (compiler-comptime-u32-value? [value : i64]) : bool
  (and (>= value 0) (<= value 0xffffffff)))

(define (compiler-comptime-nonnegative-i32-value? [value : i64]) : bool
  (and (>= value 0) (<= value 0x7fffffff)))

(define (compiler-comptime-host-ir-valid? [ir : CompilerComptimeMacroIr]) : bool
  (let
    [helper : CompilerComptimeHelperIr (struct-get ir helper)]
    [operation : i64
      (match (struct-get helper probe)
        [(CompilerComptimeStatusProbe value) value])]
    [contexts : CompilerComptimeContextParams (struct-get ir contexts)]
    [helper-contexts : CompilerComptimeContextParams
      (struct-get helper contexts)]
    (and
      (> (string.string-length (struct-get ir macro-name)) 0)
      (compiler-comptime-nonnegative-i32-value? (struct-get ir session-cookie))
      (> operation 0)
      (compiler-comptime-u32-value? operation)
      (compiler-comptime-nonnegative-i32-value?
        (struct-get helper success-result-handle))
      (= (struct-get contexts image) 0)
      (= (struct-get contexts host) 1)
      (= (struct-get contexts session) 2)
      (= (struct-get helper-contexts image) 0)
      (= (struct-get helper-contexts host) 1)
      (= (struct-get helper-contexts session) 2))))

(define (compiler-comptime-lower-host-ir [ir : CompilerComptimeMacroIr]) : ResultCompilerComptimeImagePayload
  (if (not (compiler-comptime-host-ir-valid? ir))
    (ResultCompilerComptimeImagePayload.Err
      "native comptime host IR has invalid contexts, operation, scalar, or name")
    (let
      [out : byte_buf_core.ByteBufBuilder
        (byte_buf_core.byte-buf-builder-with-capacity
          (+ 256 (string.string-length (struct-get ir macro-name))))]
      [registration-patch : CompilerComptimeRelativePatch
        (compiler-comptime-emit-registration! (&mut out) (struct-get ir mode))]
      [macro-entry-offset : i64 (byte_buf_core.byte-buf-builder-len (& out))]
      [helper-patch : CompilerComptimeRelativePatch
        (compiler-comptime-emit-macro-entry!
          (&mut out)
          (struct-get ir mode)
          (struct-get ir session-cookie))]
      [helper-offset : i64 (byte_buf_core.byte-buf-builder-len (& out))]
      [_helper : unit
        (compiler-comptime-emit-helper!
          (&mut out)
          (struct-get ir mode)
          (struct-get ir helper))]
      [_table-align : unit (compiler-comptime-align-code! (&mut out) 8)]
      [macro-table-offset : i64 (byte_buf_core.byte-buf-builder-len (& out))]
      [_table : unit
        (begin
          (compiler-comptime-emit-u64! (&mut out) 0)
          (compiler-comptime-emit-u64!
            (&mut out)
            (string.string-length (struct-get ir macro-name)))
          (compiler-comptime-emit-u64! (&mut out) 0)
          (compiler-comptime-emit-u64! (&mut out) 0))]
      [macro-name-offset : i64 (byte_buf_core.byte-buf-builder-len (& out))]
      [_name : unit
        (compiler-comptime-emit-name! (&mut out) (struct-get ir macro-name))]
      [code : (Array u8) (byte_buf_core.byte-buf-builder-finish-array (& out))]
      (begin
        (compiler-comptime-set-u32!
          code
          (struct-get registration-patch displacement)
          (- macro-table-offset (struct-get registration-patch rip-after)))
        (compiler-comptime-set-u32!
          code
          (struct-get helper-patch displacement)
          (- helper-offset (struct-get helper-patch rip-after)))
        (ResultCompilerComptimeImagePayload.Ok
          (CompilerComptimeImagePayload
            code
            macro-entry-offset
            macro-table-offset
            macro-name-offset))))))

(define (compiler-comptime-windows-template-oracle) : (Array u8)
  (compiler-comptime-byte-array-from-hex
    "48b8544c4349494d414748890248c742080100000048c742104000000048894a1848c742200000000048c7422800000000488d05900000004889423048c742380100000031c0c3660f1f8400000000004883f90476134c8b4c24304883ec28e81c0000004883c428c34881fa5151000075044889c8c3b804000000c30f1f400041544d89cc488b41304889d14c89c241b8010000004531c94883ec3048c74424200000000048c744242800000000ffd04883c4304885c0750849c7042492100000415cc30f1f400000000000000000000c00000000000000000000000000000000000000000000006e61746976652d70726f6265"))

(define (compiler-comptime-linux-template-oracle) : (Array u8)
  (compiler-comptime-byte-array-from-hex
    "48b8544c4349494d414748890648c746080100000048c746104000000048897e1848c746200000000048c7462800000000488d05780000004889463048c746380100000031c0c3660f1f8400000000004883ff0476114c89c94883ec08e81e0000004883c408c34881fe5151000075044889f8c3b804000000c3660f1f44000041544989cc488b47304889f74889d6ba0100000031c94531c04531c9ffd04885c0750849c7042492100000415cc3669000000000000000000c000000000000000000000000000000000000000000000006e61746976652d70726f6265"))

(define (compiler-comptime-oracle-put-name!
  [bytes : (Array u8)]
  [offset : i64]
  [name : String]) : unit
  (let
    [index : i64 0]
    (begin
      (while (< index (string.string-length name))
        (begin
          (array-set!
            bytes
            (+ offset index)
            (cast (string.string-ref name index) : u8))
          (set! index (+ index 1))))
      unit)))

;; The former fixed producer is retained only as a bootstrap parity oracle.
(define (compiler-comptime-default-template-oracle [windows-target : bool]) : (Array
    u8)
  (let
    [code : (Array u8)
      (if windows-target
        (compiler-comptime-windows-template-oracle)
        (compiler-comptime-linux-template-oracle))]
    [name-offset : i64
      (if windows-target
        0xe8
        0xd0)]
    (begin
      (compiler-comptime-set-u32!
        code
        (if windows-target
          0x6c
          0x6a)
        0x5151)
      (compiler-comptime-set-u32!
        code
        (if windows-target
          0x91
          0x90)
        1)
      (compiler-comptime-set-u32!
        code
        (if windows-target
          0xbd
          0xa7)
        4242)
      (compiler-comptime-oracle-put-name! code name-offset "native-probe")
      code)))

(define (compiler-comptime-lower-probe
  [program : CompilerComptimeMacroProgram]
  [windows-target : bool]) : ResultCompilerComptimeImagePayload
  (compiler-comptime-lower-host-ir
    (compiler-comptime-program-to-host-ir program windows-target)))

(define (compiler-comptime-bytes-eq-from?
  [left : (Array u8)]
  [right : (Array u8)]
  [index : i64]) : bool
  (if (>= index (array-length left))
    true
    (if (= (array-ref left index) (array-ref right index))
      (compiler-comptime-bytes-eq-from? left right (+ index 1))
      false)))

(define (compiler-comptime-bytes-eq? [left : (Array u8)] [right : (Array u8)]) : bool
  (and
    (= (array-length left) (array-length right))
    (compiler-comptime-bytes-eq-from? left right 0)))

(define (compiler-comptime-bytes-mismatch-from
  [left : (Array u8)]
  [right : (Array u8)]
  [index : i64]) : i64
  (cond
    [(>= index (array-length left))
      (if (= (array-length left) (array-length right))
        -1
        index)]
    [(>= index (array-length right)) index]
    [(= (array-ref left index) (array-ref right index))
      (compiler-comptime-bytes-mismatch-from left right (+ index 1))]
    [else index]))

(define (compiler-comptime-default-mismatch-index [windows-target : bool]) : i64
  (match (compiler-comptime-lower-probe
    (compiler-comptime-probe-program)
    windows-target)
    [(ResultCompilerComptimeImagePayload.Err _) -100]
    [(ResultCompilerComptimeImagePayload.Ok payload)
      (cond
        [(not (= (struct-get payload macro-entry-offset) 0x50)) -101]
        [windows-target
          (cond
            [(not (= (struct-get payload macro-table-offset) 0xc8)) -102]
            [(not (= (struct-get payload macro-name-offset) 0xe8)) -103]
            [else
              (compiler-comptime-bytes-mismatch-from
                (struct-get payload code)
                (compiler-comptime-default-template-oracle true)
                0)])]
        [else
          (cond
            [(not (= (struct-get payload macro-table-offset) 0xb0)) -102]
            [(not (= (struct-get payload macro-name-offset) 0xd0)) -103]
            [else
              (compiler-comptime-bytes-mismatch-from
                (struct-get payload code)
                (compiler-comptime-default-template-oracle false)
                0)])])]))

(define (compiler-comptime-default-oracle-parity? [windows-target : bool]) : bool
  (match (compiler-comptime-lower-probe
    (compiler-comptime-probe-program)
    windows-target)
    [(ResultCompilerComptimeImagePayload.Err _) false]
    [(ResultCompilerComptimeImagePayload.Ok payload)
      (and
        (= (struct-get payload macro-entry-offset) 0x50)
        (if windows-target
          (and
            (= (struct-get payload macro-table-offset) 0xc8)
            (= (struct-get payload macro-name-offset) 0xe8)
            (compiler-comptime-bytes-eq?
              (struct-get payload code)
              (compiler-comptime-default-template-oracle true)))
          (and
            (= (struct-get payload macro-table-offset) 0xb0)
            (= (struct-get payload macro-name-offset) 0xd0)
            (compiler-comptime-bytes-eq?
              (struct-get payload code)
              (compiler-comptime-default-template-oracle false)))))]))

(define (compiler-comptime-name-at?
  [bytes : (Array u8)]
  [offset : i64]
  [name : String]
  [index : i64]) : bool
  (if (>= index (string.string-length name))
    true
    (if (=
      (array-ref bytes (+ offset index))
      (cast (string.string-ref name index) : u8))
      (compiler-comptime-name-at? bytes offset name (+ index 1))
      false)))

(define (compiler-comptime-dynamic-name-layout? [windows-target : bool]) : bool
  (let
    [name : String "probe-with-dynamic-name"]
    [program : CompilerComptimeMacroProgram
      (CompilerComptimeMacroProgram
        name
        (CompilerComptimeProbe.ExplicitCallback 1)
        0x5151
        4242)]
    (match (compiler-comptime-lower-probe program windows-target)
      [(ResultCompilerComptimeImagePayload.Err _) false]
      [(ResultCompilerComptimeImagePayload.Ok payload)
        (let
          [code : (Array u8) (struct-get payload code)]
          [table : i64 (struct-get payload macro-table-offset)]
          [name-offset : i64 (struct-get payload macro-name-offset)]
          (and
            (= name-offset (+ table 32))
            (= (array-length code) (+ name-offset (string.string-length name)))
            (=
              (array-ref code (+ table 8))
              (cast (string.string-length name) : u8))
            (compiler-comptime-name-at? code name-offset name 0)))])))

(define (compiler-comptime-read-u32 [bytes : (Array u8)] [offset : i64]) : i64
  (+
    (cast (array-ref bytes offset) : i64)
    (+
      (shl (cast (array-ref bytes (+ offset 1)) : i64) 8)
      (+
        (shl (cast (array-ref bytes (+ offset 2)) : i64) 16)
        (shl (cast (array-ref bytes (+ offset 3)) : i64) 24)))))

(define (compiler-comptime-dynamic-scalars? [windows-target : bool]) : bool
  (let
    [program : CompilerComptimeMacroProgram
      (CompilerComptimeMacroProgram
        "dynamic-probe"
        (CompilerComptimeProbe.ExplicitCallback 4)
        0x12345678
        0x07654321)]
    (match (compiler-comptime-lower-probe program windows-target)
      [(ResultCompilerComptimeImagePayload.Err _) false]
      [(ResultCompilerComptimeImagePayload.Ok payload)
        (let
          [code : (Array u8) (struct-get payload code)]
          (and
            (=
              (compiler-comptime-read-u32
                code
                (if windows-target
                  0x6c
                  0x6a))
              0x12345678)
            (=
              (compiler-comptime-read-u32
                code
                (if windows-target
                  0x91
                  0x90))
              4)
            (=
              (compiler-comptime-read-u32
                code
                (if windows-target
                  0xbd
                  0xa7))
              0x07654321)))])))

(define (compiler-comptime-invalid-ir-rejected?) : bool
  (let
    [program : CompilerComptimeMacroProgram
      (CompilerComptimeMacroProgram
        ""
        (CompilerComptimeProbe.ExplicitCallback 0)
        0
        0)]
    (match (compiler-comptime-lower-probe program false)
      [(ResultCompilerComptimeImagePayload.Err message)
        (string.eq
          message
          "native comptime host IR has invalid contexts, operation, scalar, or name")]
      [(ResultCompilerComptimeImagePayload.Ok _) false])))

(define (compiler-comptime-host-ir-contract-ok?) : bool
  (let
    [ir : CompilerComptimeMacroIr
      (compiler-comptime-program-to-host-ir
        (compiler-comptime-probe-program)
        false)]
    [contexts : CompilerComptimeContextParams (struct-get ir contexts)]
    [helper : CompilerComptimeHelperIr (struct-get ir helper)]
    [helper-contexts : CompilerComptimeContextParams
      (struct-get helper contexts)]
    [operation : i64
      (match (struct-get helper probe)
        [(CompilerComptimeStatusProbe value) value])]
    (and
      (match (struct-get ir mode)
        [(CompilerComptimeLowerMode.LinuxX64) true]
        [_ false])
      (= (struct-get contexts image) 0)
      (= (struct-get contexts host) 1)
      (= (struct-get contexts session) 2)
      (= (struct-get helper-contexts image) 0)
      (= (struct-get helper-contexts host) 1)
      (= (struct-get helper-contexts session) 2)
      (= operation 1)
      (= (struct-get helper success-result-handle) 4242))))

(test
  compiler-comptime-host-ir-lowering
  (cond
    [(not (compiler-comptime-host-ir-contract-ok?))
      (io.panic "native comptime host IR contract self-test failed")]
    [(not (compiler-comptime-default-oracle-parity? false))
      (io.panic
        (string.append
          "native comptime Linux oracle parity mismatch at "
          (string.int->string (compiler-comptime-default-mismatch-index false))))]
    [(not (compiler-comptime-default-oracle-parity? true))
      (io.panic
        (string.append
          "native comptime Windows oracle parity mismatch at "
          (string.int->string (compiler-comptime-default-mismatch-index true))))]
    [(not (compiler-comptime-dynamic-name-layout? false))
      (io.panic "native comptime Linux dynamic-name self-test failed")]
    [(not (compiler-comptime-dynamic-name-layout? true))
      (io.panic "native comptime Windows dynamic-name self-test failed")]
    [(not (compiler-comptime-dynamic-scalars? false))
      (io.panic "native comptime Linux dynamic-scalar self-test failed")]
    [(not (compiler-comptime-dynamic-scalars? true))
      (io.panic "native comptime Windows dynamic-scalar self-test failed")]
    [(not (compiler-comptime-invalid-ir-rejected?))
      (io.panic "native comptime invalid-IR rejection self-test failed")]
    [else unit]))