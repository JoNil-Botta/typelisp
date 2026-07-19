;; compiler_comptime_image_core.tl - Focused native-comptime lowering proof.
;;
;; This is deliberately narrower than general macro-source body lowering: it
;; gives code-bearing tlci images a compiler-owned program model, explicit
;; host-call and loop-backedge instructions, and deterministic single/multiple
;; macro layouts. Fuel instrumentation is inserted over that IR before
;; host-native emission; general macro lowering builds on the same convention.
(import stdlib.array)
(import stdlib.byte_buf_core)
(import stdlib.io)
(import stdlib.string)

(defenum CompilerComptimeOperation
  ;; A status-returning call through the host callback table.
  (HostCall i64)
  ;; A call carrying three immediate scalar arguments.
  (HostCallArgs i64 i64 i64 i64)
  ;; A call whose first argument is the address of a pooled name and whose
  ;; second argument is its byte length: operation, name-pool index.
  (HostCallName i64 i64)
  ;; A control-flow edge from a loop latch to its header.
  (LoopBackedge))

(defstruct CompilerComptimeMacroProgram
  (macro-name String)
  (operations (Array CompilerComptimeOperation))
  (names (Array String))
  (session-cookie i64)
  (success-result-handle i64))

(defstruct CompilerComptimeImagePayload
  (code (Array u8))
  (macro-entry-offset i64)
  (macro-table-offset i64)
  (macro-name-offset i64))

(defstruct CompilerComptimePackageMacroLayout
  (macro-entry-offset i64)
  (macro-name-offset i64))

(defstruct CompilerComptimePackageImagePayload
  (code (Array u8))
  (macro-table-offset i64)
  (macros (Array CompilerComptimePackageMacroLayout)))

(defenum ResultCompilerComptimeImagePayload
  (Ok CompilerComptimeImagePayload)
  (Err String))

(defenum ResultCompilerComptimePackageImagePayload
  (Ok CompilerComptimePackageImagePayload)
  (Err String))

;; Host-comptime lowering is intentionally separate from ordinary source/runtime
;; lowering. These modes select only the host C ABI used by a mapped tlci image.
(defenum CompilerComptimeLowerMode
  (LinuxX64)
  (WindowsX64))

;; Every status-capable native helper receives these three opaque contexts in
;; this order. Keeping the positions explicit gives automatic fuel probes one
;; insertion primitive without adding state to the image.
(defstruct CompilerComptimeContextParams
  (image i64)
  (host i64)
  (session i64))

(defstruct CompilerComptimeStatusProbe
  (operation i64)
  (arg-a i64)
  (arg-b i64)
  (arg-c i64)
  (name-index i64))

(defstruct CompilerComptimeHelperIr
  (contexts CompilerComptimeContextParams)
  (probes (Array CompilerComptimeStatusProbe))
  (names (Array String))
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

(define (compiler-comptime-status-probe [operation : i64]) : CompilerComptimeStatusProbe
  (CompilerComptimeStatusProbe operation 0 0 0 -1))

(define (compiler-comptime-instrumented-probe-count
  [operations : (Array CompilerComptimeOperation)]) : i64
  (let
    [index : i64 0]
    [count : i64 0]
    (begin
      (while (< index (array-length operations))
        (begin
          (set!
            count
            (+
              count
              (match (array-ref operations index)
                [(CompilerComptimeOperation.HostCall _) 2]
                [(CompilerComptimeOperation.HostCallArgs _ _ _ _) 2]
                [(CompilerComptimeOperation.HostCallName _ _) 2]
                [(CompilerComptimeOperation.LoopBackedge) 1])))
          (set! index (+ index 1))))
      count)))

;; Fuel is host-owned, so every semantic call and loop backedge becomes an
;; operation-1 status probe. Calls retain their original callback immediately
;; after the fuel check. A nonzero status unwinds before the following probe.
(define (compiler-comptime-instrument-operations
  [operations : (Array CompilerComptimeOperation)]) : (Array
    CompilerComptimeStatusProbe)
  (let
    [probes : (Array CompilerComptimeStatusProbe)
      (array.make-array
        CompilerComptimeStatusProbe
        (compiler-comptime-instrumented-probe-count operations))]
    [operation-index : i64 0]
    [probe-index : i64 0]
    (begin
      (while (< operation-index (array-length operations))
        (begin
          (array-set! probes probe-index (compiler-comptime-status-probe 1))
          (set! probe-index (+ probe-index 1))
          (match (array-ref operations operation-index)
            [(CompilerComptimeOperation.HostCall operation)
              (begin
                (array-set!
                  probes
                  probe-index
                  (compiler-comptime-status-probe operation))
                (set! probe-index (+ probe-index 1)))]
            [(CompilerComptimeOperation.HostCallArgs operation a b c)
              (begin
                (array-set!
                  probes
                  probe-index
                  (CompilerComptimeStatusProbe operation a b c -1))
                (set! probe-index (+ probe-index 1)))]
            [(CompilerComptimeOperation.HostCallName operation name-index)
              (begin
                (array-set!
                  probes
                  probe-index
                  (CompilerComptimeStatusProbe operation 0 0 0 name-index))
                (set! probe-index (+ probe-index 1)))]
            [(CompilerComptimeOperation.LoopBackedge) unit])
          (set! operation-index (+ operation-index 1))))
      probes)))

(define (compiler-comptime-program-to-host-ir
  [program : CompilerComptimeMacroProgram]
  [windows-target : bool]) : CompilerComptimeMacroIr
  (let
    [contexts : CompilerComptimeContextParams
      (compiler-comptime-context-params)]
    [probes : (Array CompilerComptimeStatusProbe)
      (compiler-comptime-instrument-operations (struct-get program operations))]
    (CompilerComptimeMacroIr
      (if windows-target
        (CompilerComptimeLowerMode.WindowsX64)
        (CompilerComptimeLowerMode.LinuxX64))
      (struct-get program macro-name)
      (struct-get program session-cookie)
      contexts
      (CompilerComptimeHelperIr
        contexts
        probes
        (struct-get program names)
        (struct-get program success-result-handle)))))

(define (compiler-comptime-probe-program) : CompilerComptimeMacroProgram
  (CompilerComptimeMacroProgram
    "native-probe"
    (make-array
      (CompilerComptimeOperation.HostCall 4)
      (CompilerComptimeOperation.LoopBackedge))
    (array.make-array String 0)
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
  [mode : CompilerComptimeLowerMode]
  [macro-count : i64]) : CompilerComptimeRelativePatch
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
        (compiler-comptime-emit-u32! out macro-count)
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

;; All probe exits share the same 13-byte register/stack unwind sequence.
(define (compiler-comptime-emit-helper-unwind!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [mode : CompilerComptimeLowerMode]) : unit
  (begin
    (match mode
      [(CompilerComptimeLowerMode.LinuxX64)
        (compiler-comptime-emit-bytes! out (make-array 0x48 0x83 0xc4 0x08))]
      [(CompilerComptimeLowerMode.WindowsX64)
        (compiler-comptime-emit-bytes! out (make-array 0x48 0x83 0xc4 0x38))])
    (compiler-comptime-emit-bytes!
      out
      (make-array 0x41 0x5f 0x41 0x5e 0x41 0x5d 0x41 0x5c 0xc3))))

;; The zero-status short branch skips the inline unwind; nonzero status remains
;; in rax and returns immediately. Callback arguments beyond host/session are
;; immediates or a RIP-relative pooled-name reference, so image and result
;; state stay in callee-saved registers across every probe. A name reference
;; returns the position of its four displacement bytes for the payload
;; assembler to patch; argument probes return -1.
(define (compiler-comptime-emit-instrumented-probe!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [mode : CompilerComptimeLowerMode]
  [probe : CompilerComptimeStatusProbe]
  [names : (Array String)]) : i64
  (match probe
    [(CompilerComptimeStatusProbe operation arg-a arg-b arg-c name-index)
      (let
        [name-len : i64
          (if (>= name-index 0)
            (string.string-length (array-ref names name-index))
            0)]
        [patch : i64 -1]
        (begin
          (match mode
            [(CompilerComptimeLowerMode.LinuxX64)
              (begin
                (compiler-comptime-emit-bytes!
                  out
                  (make-array
                    0x49
                    0x8b
                    0x45
                    0x30
                    0x4c
                    0x89
                    0xf7
                    0x4c
                    0x89
                    0xfe
                    0xba))
                (compiler-comptime-emit-u32! out operation)
                (if (>= name-index 0)
                  (begin
                    (compiler-comptime-emit-bytes!
                      out
                      (make-array 0x48 0x8d 0x0d))
                    (set! patch (struct-get out len))
                    (compiler-comptime-emit-u32! out 0)
                    (compiler-comptime-emit-bytes!
                      out
                      (make-array 0x49 0xc7 0xc0))
                    (compiler-comptime-emit-u32! out name-len)
                    (compiler-comptime-emit-bytes!
                      out
                      (make-array 0x45 0x31 0xc9)))
                  (if (and (= arg-a 0) (= arg-b 0) (= arg-c 0))
                    (compiler-comptime-emit-bytes!
                      out
                      (make-array 0x31 0xc9 0x45 0x31 0xc0 0x45 0x31 0xc9))
                    (begin
                      (compiler-comptime-emit-bytes!
                        out
                        (make-array 0x48 0xc7 0xc1))
                      (compiler-comptime-emit-u32! out arg-a)
                      (compiler-comptime-emit-bytes!
                        out
                        (make-array 0x49 0xc7 0xc0))
                      (compiler-comptime-emit-u32! out arg-b)
                      (compiler-comptime-emit-bytes!
                        out
                        (make-array 0x49 0xc7 0xc1))
                      (compiler-comptime-emit-u32! out arg-c))))
                (compiler-comptime-emit-bytes! out (make-array 0xff 0xd0)))]
            [(CompilerComptimeLowerMode.WindowsX64)
              (begin
                (compiler-comptime-emit-bytes!
                  out
                  (make-array
                    0x49
                    0x8b
                    0x45
                    0x30
                    0x4c
                    0x89
                    0xf1
                    0x4c
                    0x89
                    0xfa
                    0x41
                    0xb8))
                (compiler-comptime-emit-u32! out operation)
                (if (>= name-index 0)
                  (begin
                    (compiler-comptime-emit-bytes!
                      out
                      (make-array 0x4c 0x8d 0x0d))
                    (set! patch (struct-get out len))
                    (compiler-comptime-emit-u32! out 0)
                    (compiler-comptime-emit-bytes!
                      out
                      (make-array 0x48 0xc7 0x44 0x24 0x20))
                    (compiler-comptime-emit-u32! out name-len)
                    (compiler-comptime-emit-bytes!
                      out
                      (make-array 0x48 0xc7 0x44 0x24 0x28))
                    (compiler-comptime-emit-u32! out 0))
                  (begin
                    (if (= arg-a 0)
                      (compiler-comptime-emit-bytes!
                        out
                        (make-array 0x45 0x31 0xc9))
                      (begin
                        (compiler-comptime-emit-bytes!
                          out
                          (make-array 0x49 0xc7 0xc1))
                        (compiler-comptime-emit-u32! out arg-a)))
                    (compiler-comptime-emit-bytes!
                      out
                      (make-array 0x48 0xc7 0x44 0x24 0x20))
                    (compiler-comptime-emit-u32! out arg-b)
                    (compiler-comptime-emit-bytes!
                      out
                      (make-array 0x48 0xc7 0x44 0x24 0x28))
                    (compiler-comptime-emit-u32! out arg-c)))
                (compiler-comptime-emit-bytes! out (make-array 0xff 0xd0)))])
          (compiler-comptime-emit-bytes!
            out
            (make-array 0x48 0x85 0xc0 0x74 0x0d))
          (compiler-comptime-emit-helper-unwind! out mode)
          patch))]))

;; Emit the instrumented stream and commit the result only after every probe
;; succeeds. The Windows frame reserves shadow space and both stack arguments;
;; the SysV frame supplies the required 16-byte pre-call alignment.
(define (compiler-comptime-emit-instrumented-helper!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [mode : CompilerComptimeLowerMode]
  [helper : CompilerComptimeHelperIr]
  [patch-displacements : (Array i64)]
  [patch-name-indices : (Array i64)]
  [cursor : i64]) : i64
  (let
    [result : i64 (struct-get helper success-result-handle)]
    [probes : (Array CompilerComptimeStatusProbe) (struct-get helper probes)]
    [names : (Array String) (struct-get helper names)]
    [patch-cursor : i64 cursor]
    [index : i64 0]
    (begin
      (compiler-comptime-emit-bytes!
        out
        (make-array 0x41 0x54 0x41 0x55 0x41 0x56 0x41 0x57))
      (match mode
        [(CompilerComptimeLowerMode.LinuxX64)
          (compiler-comptime-emit-bytes!
            out
            (make-array
              0x49
              0x89
              0xcc
              0x49
              0x89
              0xfd
              0x49
              0x89
              0xf6
              0x49
              0x89
              0xd7
              0x48
              0x83
              0xec
              0x08))]
        [(CompilerComptimeLowerMode.WindowsX64)
          (compiler-comptime-emit-bytes!
            out
            (make-array
              0x4d
              0x89
              0xcc
              0x49
              0x89
              0xcd
              0x49
              0x89
              0xd6
              0x4d
              0x89
              0xc7
              0x48
              0x83
              0xec
              0x38))])
      (while (< index (array-length probes))
        (let
          [probe : CompilerComptimeStatusProbe (array-ref probes index)]
          [patch : i64
            (compiler-comptime-emit-instrumented-probe! out mode probe names)]
          (begin
            (if (>= patch 0)
              (match probe
                [(CompilerComptimeStatusProbe _ _ _ _ name-index)
                  (begin
                    (array-set! patch-displacements patch-cursor patch)
                    (array-set! patch-name-indices patch-cursor name-index)
                    (set! patch-cursor (+ patch-cursor 1)))])
              unit)
            (set! index (+ index 1)))))
      (compiler-comptime-emit-bytes! out (make-array 0x49 0xc7 0x04 0x24))
      (compiler-comptime-emit-u32! out result)
      (compiler-comptime-emit-bytes! out (make-array 0x31 0xc0))
      (compiler-comptime-emit-helper-unwind! out mode)
      patch-cursor)))

(define (compiler-comptime-emit-name-pool!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [names : (Array String)]) : (Array i64)
  (let
    [offsets : (Array i64) (make-array i64 (array-length names))]
    [index : i64 0]
    (begin
      (while (< index (array-length names))
        (begin
          (array-set! offsets index (struct-get out len))
          (compiler-comptime-emit-name! out (array-ref names index))
          (set! index (+ index 1))))
      offsets)))

(define (compiler-comptime-program-name-call-count
  [program : CompilerComptimeMacroProgram]) : i64
  (let
    [operations : (Array CompilerComptimeOperation)
      (struct-get program operations)]
    [index : i64 0]
    [count : i64 0]
    (begin
      (while (< index (array-length operations))
        (begin
          (match (array-ref operations index)
            [(CompilerComptimeOperation.HostCallName _ _)
              (set! count (+ count 1))]
            [_ unit])
          (set! index (+ index 1))))
      count)))

(define (compiler-comptime-u32-value? [value : i64]) : bool
  (and (>= value 0) (<= value 0xffffffff)))

(define (compiler-comptime-nonnegative-i32-value? [value : i64]) : bool
  (and (>= value 0) (<= value 0x7fffffff)))

(define (compiler-comptime-probes-valid?
  [probes : (Array CompilerComptimeStatusProbe)]
  [names : (Array String)]) : bool
  (let
    [index : i64 0]
    [valid : bool true]
    (begin
      (while (and valid (< index (array-length probes)))
        (begin
          (match (array-ref probes index)
            [(CompilerComptimeStatusProbe operation a b c name-index)
              (set!
                valid
                (and
                  (> operation 0)
                  (compiler-comptime-u32-value? operation)
                  (compiler-comptime-nonnegative-i32-value? a)
                  (compiler-comptime-nonnegative-i32-value? b)
                  (compiler-comptime-nonnegative-i32-value? c)
                  (>= name-index -1)
                  (< name-index (array-length names))
                  (or
                    (< name-index 0)
                    (compiler-comptime-nonnegative-i32-value?
                      (string.string-length (array-ref names name-index))))))])
          (set! index (+ index 1))))
      valid)))

(define (compiler-comptime-host-ir-valid? [ir : CompilerComptimeMacroIr]) : bool
  (let
    [helper : CompilerComptimeHelperIr (struct-get ir helper)]
    [probes : (Array CompilerComptimeStatusProbe) (struct-get helper probes)]
    [contexts : CompilerComptimeContextParams (struct-get ir contexts)]
    [helper-contexts : CompilerComptimeContextParams
      (struct-get helper contexts)]
    (and
      (> (string.string-length (struct-get ir macro-name)) 0)
      (compiler-comptime-nonnegative-i32-value? (struct-get ir session-cookie))
      (> (array-length probes) 0)
      (compiler-comptime-probes-valid? probes (struct-get helper names))
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
        (compiler-comptime-emit-registration! (&mut out) (struct-get ir mode) 1)]
      [macro-entry-offset : i64 (byte_buf_core.byte-buf-builder-len (& out))]
      [helper-patch : CompilerComptimeRelativePatch
        (compiler-comptime-emit-macro-entry!
          (&mut out)
          (struct-get ir mode)
          (struct-get ir session-cookie))]
      [helper-offset : i64 (byte_buf_core.byte-buf-builder-len (& out))]
      [helper-names : (Array String) (struct-get (struct-get ir helper) names)]
      [patch-displacements : (Array i64)
        (make-array i64 (array-length helper-names))]
      [patch-name-indices : (Array i64)
        (make-array i64 (array-length helper-names))]
      [patch-count : i64
        (compiler-comptime-emit-instrumented-helper!
          (&mut out)
          (struct-get ir mode)
          (struct-get ir helper)
          patch-displacements
          patch-name-indices
          0)]
      [name-pool-offsets : (Array i64)
        (compiler-comptime-emit-name-pool! (&mut out) helper-names)]
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
        (let
          [pindex : i64 0]
          (while (< pindex patch-count)
            (let
              [displacement : i64 (array-ref patch-displacements pindex)]
              [name-index : i64 (array-ref patch-name-indices pindex)]
              (begin
                (compiler-comptime-set-u32!
                  code
                  displacement
                  (-
                    (array-ref name-pool-offsets name-index)
                    (+ displacement 4)))
                (set! pindex (+ pindex 1))))))
        (ResultCompilerComptimeImagePayload.Ok
          (CompilerComptimeImagePayload
            code
            macro-entry-offset
            macro-table-offset
            macro-name-offset))))))

(define (compiler-comptime-package-programs-valid?
  [programs : (Array CompilerComptimeMacroProgram)]
  [windows-target : bool]) : bool
  (let
    [index : i64 0]
    [valid : bool
      (and
        (> (array-length programs) 0)
        (compiler-comptime-nonnegative-i32-value? (array-length programs)))]
    (begin
      (while (and valid (< index (array-length programs)))
        (begin
          (set!
            valid
            (compiler-comptime-host-ir-valid?
              (compiler-comptime-program-to-host-ir
                (array-ref programs index)
                windows-target)))
          (set! index (+ index 1))))
      valid)))

;; Package images share one registration entry and contiguous macro table.
;; Each exported macro keeps its own wrapper/helper pair so later source
;; lowering can replace the helper IR independently without changing the tlci
;; registration or fixup contract established here.
(define (compiler-comptime-lower-package
  [programs : (Array CompilerComptimeMacroProgram)]
  [windows-target : bool]) : ResultCompilerComptimePackageImagePayload
  (if (not (compiler-comptime-package-programs-valid? programs windows-target))
    (ResultCompilerComptimePackageImagePayload.Err
      "native comptime package has no macros or invalid host IR")
    (let
      [count : i64 (array-length programs)]
      [mode : CompilerComptimeLowerMode
        (if windows-target
          (CompilerComptimeLowerMode.WindowsX64)
          (CompilerComptimeLowerMode.LinuxX64))]
      [out : byte_buf_core.ByteBufBuilder
        (byte_buf_core.byte-buf-builder-with-capacity (* count 384))]
      [registration-patch : CompilerComptimeRelativePatch
        (compiler-comptime-emit-registration! (&mut out) mode count)]
      [registration-displacement : i64
        (struct-get registration-patch displacement)]
      [registration-rip-after : i64 (struct-get registration-patch rip-after)]
      [layouts : (Array CompilerComptimePackageMacroLayout)
        (make-array CompilerComptimePackageMacroLayout count)]
      [helper-displacements : (Array i64) (make-array i64 count)]
      [helper-rip-afters : (Array i64) (make-array i64 count)]
      [helper-offsets : (Array i64) (make-array i64 count)]
      [total-name-patches : i64
        (let
          [scan : i64 0]
          [total : i64 0]
          (begin
            (while (< scan count)
              (begin
                (set!
                  total
                  (+
                    total
                    (compiler-comptime-program-name-call-count
                      (array-ref programs scan))))
                (set! scan (+ scan 1))))
            total))]
      [patch-displacements : (Array i64) (make-array i64 total-name-patches)]
      [patch-name-indices : (Array i64) (make-array i64 total-name-patches)]
      [patch-values : (Array i64) (make-array i64 total-name-patches)]
      [patch-cursor : i64 0]
      [index : i64 0]
      (begin
        (while (< index count)
          (let
            [ir : CompilerComptimeMacroIr
              (compiler-comptime-program-to-host-ir
                (array-ref programs index)
                windows-target)]
            [entry-offset : i64 (byte_buf_core.byte-buf-builder-len (& out))]
            [helper-patch : CompilerComptimeRelativePatch
              (compiler-comptime-emit-macro-entry!
                (&mut out)
                mode
                (struct-get ir session-cookie))]
            [helper-offset : i64 (byte_buf_core.byte-buf-builder-len (& out))]
            [start-cursor : i64 patch-cursor]
            [next-cursor : i64
              (compiler-comptime-emit-instrumented-helper!
                (&mut out)
                mode
                (struct-get ir helper)
                patch-displacements
                patch-name-indices
                patch-cursor)]
            [pool-offsets : (Array i64)
              (compiler-comptime-emit-name-pool!
                (&mut out)
                (struct-get (struct-get ir helper) names))]
            (begin
              (let
                [resolve : i64 start-cursor]
                (while (< resolve next-cursor)
                  (let
                    [displacement : i64 (array-ref patch-displacements resolve)]
                    [name-index : i64 (array-ref patch-name-indices resolve)]
                    (begin
                      (array-set!
                        patch-values
                        resolve
                        (-
                          (array-ref pool-offsets name-index)
                          (+ displacement 4)))
                      (set! resolve (+ resolve 1))))))
              (set! patch-cursor next-cursor)
              (array-set!
                layouts
                index
                (CompilerComptimePackageMacroLayout entry-offset 0))
              (array-set!
                helper-displacements
                index
                (struct-get helper-patch displacement))
              (array-set!
                helper-rip-afters
                index
                (struct-get helper-patch rip-after))
              (array-set! helper-offsets index helper-offset)
              (set! index (+ index 1)))))
        (compiler-comptime-align-code! (&mut out) 8)
        (let
          [macro-table-offset : i64
            (byte_buf_core.byte-buf-builder-len (& out))]
          (begin
            (set! index 0)
            (while (< index count)
              (begin
                (compiler-comptime-emit-u64! (&mut out) 0)
                (compiler-comptime-emit-u64!
                  (&mut out)
                  (string.string-length
                    (struct-get (array-ref programs index) macro-name)))
                (compiler-comptime-emit-u64! (&mut out) 0)
                (compiler-comptime-emit-u64! (&mut out) 0)
                (set! index (+ index 1))))
            (set! index 0)
            (while (< index count)
              (let
                [program : CompilerComptimeMacroProgram
                  (array-ref programs index)]
                [layout : CompilerComptimePackageMacroLayout
                  (array-ref layouts index)]
                [name-offset : i64 (byte_buf_core.byte-buf-builder-len (& out))]
                (begin
                  (compiler-comptime-emit-name!
                    (&mut out)
                    (struct-get program macro-name))
                  (array-set!
                    layouts
                    index
                    (CompilerComptimePackageMacroLayout
                      (struct-get layout macro-entry-offset)
                      name-offset))
                  (set! index (+ index 1)))))
            (let
              [code : (Array u8)
                (byte_buf_core.byte-buf-builder-finish-array (& out))]
              (begin
                (compiler-comptime-set-u32!
                  code
                  registration-displacement
                  (- macro-table-offset registration-rip-after))
                (set! index 0)
                (while (< index count)
                  (begin
                    (compiler-comptime-set-u32!
                      code
                      (array-ref helper-displacements index)
                      (-
                        (array-ref helper-offsets index)
                        (array-ref helper-rip-afters index)))
                    (set! index (+ index 1))))
                (set! index 0)
                (while (< index total-name-patches)
                  (begin
                    (compiler-comptime-set-u32!
                      code
                      (array-ref patch-displacements index)
                      (array-ref patch-values index))
                    (set! index (+ index 1))))
                (ResultCompilerComptimePackageImagePayload.Ok
                  (CompilerComptimePackageImagePayload
                    code
                    macro-table-offset
                    layouts))))))))))

(define (compiler-comptime-lower-package-names
  [macro-names : (Array String)]
  [windows-target : bool]) : ResultCompilerComptimePackageImagePayload
  (let
    [count : i64 (array-length macro-names)]
    [programs : (Array CompilerComptimeMacroProgram)
      (make-array CompilerComptimeMacroProgram count)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (array-set!
            programs
            index
            (CompilerComptimeMacroProgram
              (array-ref macro-names index)
              (make-array (CompilerComptimeOperation.HostCall 4))
              (array.make-array String 0)
              0
              0))
          (set! index (+ index 1))))
      (compiler-comptime-lower-package programs windows-target))))

(define (compiler-comptime-windows-template-oracle) : (Array u8)
  (compiler-comptime-byte-array-from-hex
    "48b8544c4349494d414748890248c742080100000048c742104000000048894a1848c742200000000048c7422800000000488d05280100004889423048c742380100000031c0c3660f1f8400000000004883f90476134c8b4c24304883ec28e81c0000004883c428c34881fa5151000075044889c8c3b804000000c30f1f400041544155415641574d89cc4989cd4989d64d89c74883ec38498b45304c89f14c89fa41b8010000004531c948c74424200000000048c744242800000000ffd04885c0740d4883c438415f415e415d415cc3498b45304c89f14c89fa41b8040000004531c948c74424200000000048c744242800000000ffd04885c0740d4883c438415f415e415d415cc3498b45304c89f14c89fa41b8010000004531c948c74424200000000048c744242800000000ffd04885c0740d4883c438415f415e415d415cc349c704249210000031c04883c438415f415e415d415cc3660f1f44000000000000000000000c00000000000000000000000000000000000000000000006e61746976652d70726f6265"))

(define (compiler-comptime-linux-template-oracle) : (Array u8)
  (compiler-comptime-byte-array-from-hex
    "48b8544c4349494d414748890648c746080100000048c746104000000048897e1848c746200000000048c7462800000000488d05f80000004889463048c746380100000031c0c3660f1f8400000000004883ff0476114c89c94883ec08e81e0000004883c408c34881fe5151000075044889f8c3b804000000c3660f1f44000041544155415641574989cc4989fd4989f64989d74883ec08498b45304c89f74c89feba0100000031c94531c04531c9ffd04885c0740d4883c408415f415e415d415cc3498b45304c89f74c89feba0400000031c94531c04531c9ffd04885c0740d4883c408415f415e415d415cc3498b45304c89f74c89feba0100000031c94531c04531c9ffd04885c0740d4883c408415f415e415d415cc349c704249210000031c04883c408415f415e415d415cc300000000000000000c00000000000000000000000000000000000000000000006e61746976652d70726f6265"))

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
        0x180
        0x150)]
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
          0xdd
          0xce)
        4)
      (compiler-comptime-set-u32!
        code
        (if windows-target
          0x147
          0x11d)
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
            [(not (= (struct-get payload macro-table-offset) 0x160)) -102]
            [(not (= (struct-get payload macro-name-offset) 0x180)) -103]
            [else
              (compiler-comptime-bytes-mismatch-from
                (struct-get payload code)
                (compiler-comptime-default-template-oracle true)
                0)])]
        [else
          (cond
            [(not (= (struct-get payload macro-table-offset) 0x130)) -102]
            [(not (= (struct-get payload macro-name-offset) 0x150)) -103]
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
            (= (struct-get payload macro-table-offset) 0x160)
            (= (struct-get payload macro-name-offset) 0x180)
            (compiler-comptime-bytes-eq?
              (struct-get payload code)
              (compiler-comptime-default-template-oracle true)))
          (and
            (= (struct-get payload macro-table-offset) 0x130)
            (= (struct-get payload macro-name-offset) 0x150)
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
        (make-array (CompilerComptimeOperation.HostCall 4))
        (array.make-array String 0)
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
        (make-array (CompilerComptimeOperation.HostCall 128))
        (array.make-array String 0)
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
                  0xdd
                  0xce))
              128)
            (=
              (compiler-comptime-read-u32
                code
                (if windows-target
                  0x10e
                  0xf2))
              0x07654321)))])))

(define (compiler-comptime-invalid-program-rejected?
  [program : CompilerComptimeMacroProgram]) : bool
  (match (compiler-comptime-lower-probe program false)
    [(ResultCompilerComptimeImagePayload.Err message)
      (string.eq
        message
        "native comptime host IR has invalid contexts, operation, scalar, or name")]
    [(ResultCompilerComptimeImagePayload.Ok _) false]))

(define (compiler-comptime-invalid-ir-rejected?) : bool
  (and
    (compiler-comptime-invalid-program-rejected?
      (CompilerComptimeMacroProgram
        ""
        (make-array (CompilerComptimeOperation.HostCall 4))
        (array.make-array String 0)
        0
        0))
    (compiler-comptime-invalid-program-rejected?
      (CompilerComptimeMacroProgram
        "bad-operation"
        (make-array (CompilerComptimeOperation.HostCall 0))
        (array.make-array String 0)
        0
        0))
    (compiler-comptime-invalid-program-rejected?
      (CompilerComptimeMacroProgram
        "empty-program"
        (make-array CompilerComptimeOperation 0)
        (array.make-array String 0)
        0
        0))))

(define (compiler-comptime-probe-operation?
  [probes : (Array CompilerComptimeStatusProbe)]
  [index : i64]
  [expected : i64]) : bool
  (match (array-ref probes index)
    [(CompilerComptimeStatusProbe operation _ _ _ _) (= operation expected)]))

(define (compiler-comptime-fuel-placement-ok?) : bool
  (let
    [probes : (Array CompilerComptimeStatusProbe)
      (compiler-comptime-instrument-operations
        (make-array
          (CompilerComptimeOperation.HostCall 100)
          (CompilerComptimeOperation.LoopBackedge)
          (CompilerComptimeOperation.HostCall 101)))]
    (and
      (= (array-length probes) 5)
      (compiler-comptime-probe-operation? probes 0 1)
      (compiler-comptime-probe-operation? probes 1 100)
      (compiler-comptime-probe-operation? probes 2 1)
      (compiler-comptime-probe-operation? probes 3 1)
      (compiler-comptime-probe-operation? probes 4 101))))

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
    [probes : (Array CompilerComptimeStatusProbe) (struct-get helper probes)]
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
      (= (array-length probes) 3)
      (match (array-ref probes 0)
        [(CompilerComptimeStatusProbe operation _ _ _ _) (= operation 1)])
      (match (array-ref probes 1)
        [(CompilerComptimeStatusProbe operation _ _ _ _) (= operation 4)])
      (match (array-ref probes 2)
        [(CompilerComptimeStatusProbe operation _ _ _ _) (= operation 1)])
      (= (struct-get helper success-result-handle) 4242))))

(define (compiler-comptime-package-scale-ok? [windows-target : bool]) : bool
  (let
    [count : i64 64]
    [programs : (Array CompilerComptimeMacroProgram)
      (make-array CompilerComptimeMacroProgram count)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (array-set!
            programs
            index
            (CompilerComptimeMacroProgram
              "package/scale-macro"
              (make-array (CompilerComptimeOperation.HostCall 4))
              (array.make-array String 0)
              0
              0))
          (set! index (+ index 1))))
      (match (compiler-comptime-lower-package programs windows-target)
        [(ResultCompilerComptimePackageImagePayload.Err _) false]
        [(ResultCompilerComptimePackageImagePayload.Ok payload)
          (let
            [code : (Array u8) (struct-get payload code)]
            [layouts : (Array CompilerComptimePackageMacroLayout)
              (struct-get payload macros)]
            [last : CompilerComptimePackageMacroLayout
              (array-ref layouts (- count 1))]
            (and
              (= (array-length layouts) count)
              (> (struct-get payload macro-table-offset) 0)
              (< (struct-get last macro-entry-offset) (array-length code))
              (< (struct-get last macro-name-offset) (array-length code))))]))))

(test
  compiler-comptime-host-ir-lowering
  (cond
    [(not (compiler-comptime-fuel-placement-ok?))
      (io.panic "native comptime call/backedge fuel placement self-test failed")]
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
    [(not (compiler-comptime-package-scale-ok? false))
      (io.panic "native comptime Linux package-scale self-test failed")]
    [(not (compiler-comptime-package-scale-ok? true))
      (io.panic "native comptime Windows package-scale self-test failed")]
    [else unit]))