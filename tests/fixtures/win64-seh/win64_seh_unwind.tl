;; win64_seh_unwind.tl - Windows virtual unwind through described prologues.
;;
;; scripts/verify-win64-seh-unwind.sh compiles this module for
;; windows-x86_64 at --opt-level 2 and links it with driver.s.in. Each driver
;; entry saves every nonvolatile register, loads a distinct seed into each,
;; records its own %rsp and return address, and calls a victim below. The
;; victim keeps its own values in callee-saved registers across a call to
;; `seh-probe`, which captures its context and virtually unwinds until it
;; reaches the driver's return address. The recovered nonvolatile registers,
;; %rsp and %rip must then equal what the driver held at the call. That only
;; holds if every victim save is described by its unwind program.
;;
;; `seh-victim-framed` keeps the rbp frame (a Win64 XMM save with an even
;; number of GP saves is not frame-pointer omitted), so its GP saves are the
;; `.seh_savereg` rows of #7564. `seh-victim-fpo` is the push-prologue control.
(cfg windows (import stdlib.io))

(cfg
  windows
  (unsafe
    (extern (seh-rtl-capture-context [context : i64]) : unit (:symbol "RtlCaptureContext"))))

(cfg
  windows
  (unsafe
    (extern (seh-rtl-lookup-function-entry
      [pc : i64]
      [image-base : i64]
      [history : i64]) : i64 (:symbol "RtlLookupFunctionEntry"))))

(cfg
  windows
  (unsafe
    (extern (seh-rtl-virtual-unwind
      [handler-type : i32]
      [image-base : i64]
      [pc : i64]
      [function-entry : i64]
      [context : i64]
      [handler-data : i64]
      [establisher-frame : i64]
      [context-pointers : i64]) : i64 (:symbol "RtlVirtualUnwind"))))

(cfg
  windows
  (unsafe
    (extern (seh-virtual-alloc
      [address : i64]
      [size : i64]
      [allocation-type : i32]
      [protect : i32]) : i64 (:symbol "VirtualAlloc"))))

;; The driver's %rsp (0) and return address (1) at the victim call.
(cfg
  windows
  (unsafe
    (extern (seh-driver-recorded [which : i64]) : i64 (:symbol "tl_seh_driver_recorded"))))

(cfg
  windows
  (unsafe
    (extern (seh-drive-framed [x : i64]) : i64 (:symbol "tl_seh_drive_framed"))))

(cfg
  windows
  (unsafe
    (extern (seh-drive-fpo [x : i64]) : i64 (:symbol "tl_seh_drive_fpo"))))

;; The seed the driver loads into Windows register number REG (rbx 3, rbp 5,
;; rsi 6, rdi 7, r12..r15 12..15); XMM register N gets low 0x100 + N and high
;; 0x200 + N.
(cfg
  windows
  (define (seh-seed [reg : i64]) : i64
    (+ 0x5eed000000000000 reg)))

;; -1 until a probe ran, then the mismatch bits of its comparison.
(cfg
  windows
  (define seh-mismatch : i64
    -1))

(cfg
  windows
  (define (seh-read [address : i64]) : i64
    (unsafe
      (ptr-read (int->ptr (cast address : u64) : (Ptr i64))))))

;; CONTEXT offsets: Rsp 0x98, Rip 0xF8, Xmm0 0x1A0 (16 bytes per register).
(cfg
  windows
  (define (seh-expect [context : i64] [offset : i64] [value : i64] [bit : i64]) : i64
    (if (= (seh-read (+ context offset)) value)
      0
      (shl 1 bit))))

(cfg
  windows
  (define (seh-compare [context : i64]) : i64
    (let
      [gp : i64
        (bit-or
          (bit-or
            (bit-or
              (seh-expect context 0x90 (seh-seed 3) 0)
              (seh-expect context 0xa0 (seh-seed 5) 1))
            (bit-or
              (seh-expect context 0xa8 (seh-seed 6) 2)
              (seh-expect context 0xb0 (seh-seed 7) 3)))
          (bit-or
            (bit-or
              (seh-expect context 0xd8 (seh-seed 12) 4)
              (seh-expect context 0xe0 (seh-seed 13) 5))
            (bit-or
              (seh-expect context 0xe8 (seh-seed 14) 6)
              (seh-expect context 0xf0 (seh-seed 15) 7))))]
      [xmm : i64 0]
      [n : i64 6]
      (while (< n 16)
        (set!
          xmm
          (bit-or
            xmm
            (bit-or
              (seh-expect
                context
                (+ 0x1a0 (* 16 n))
                (seh-seed (+ 0x100 n))
                (+ 2 n))
              (seh-expect
                context
                (+ 0x1a8 (* 16 n))
                (seh-seed (+ 0x200 n))
                (+ 12 n)))))
        (set! n (+ n 1)))
      (bit-or
        (bit-or gp xmm)
        (bit-or
          (seh-expect
            context
            0x98
            (unsafe
              (seh-driver-recorded 0))
            28)
          (seh-expect
            context
            0xf8
            (unsafe
              (seh-driver-recorded 1))
            29))))))

;; Unwinds CONTEXT one frame; SCRATCH holds the image base, the handler data
;; and the establisher frame the unwinder writes.
(cfg
  windows
  (define (seh-unwind-frame [context : i64] [scratch : i64]) : bool
    (unsafe
      (let
        [pc : i64 (seh-read (+ context 0xf8))]
        [entry : i64 (seh-rtl-lookup-function-entry pc scratch 0)]
        (if (= entry 0)
          false
          (let
            [_handler : i64
              (seh-rtl-virtual-unwind
                0
                (seh-read scratch)
                pc
                entry
                context
                (+ scratch 8)
                (+ scratch 16)
                0)]
            true))))))

(cfg
  windows
  (define (seh-probe [x : i64]) : i64
    (unsafe
      (let
        ;; MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE; page alignment covers the
        ;; 16-byte CONTEXT requirement.
        [context : i64 (seh-virtual-alloc 0 8192 0x3000 4)]
        [scratch : i64 (+ context 4096)]
        [frames : i64 0]
        [found : bool false]
        (seh-rtl-capture-context context)
        (while (and (not found) (< frames 4) (seh-unwind-frame context scratch))
          (set! frames (+ frames 1))
          (set! found (= (seh-read (+ context 0xf8)) (seh-driver-recorded 1))))
        (set!
          seh-mismatch
          (if found
            (seh-compare context)
            (shl 1 30)))
        (+ x frames)))))

(cfg
  windows
  (define (seh-victim-framed [x : i64]) : i64
    (let
      [f : f64 (cast x : f64)]
      [a : i64 (seh-probe (* x 3))]
      [b : i64 (seh-probe (+ a 7))]
      (+ (+ a b) (+ x (cast (* f 2.5) : i64))))))

(cfg
  windows
  (define (seh-victim-fpo [x : i64]) : i64
    (let
      [a : i64 (seh-probe x)]
      [b : i64 (seh-probe (+ a x))]
      (+ (+ a b) x))))

;; The driver is the only caller; this table keeps both victims emitted.
(cfg
  windows
  (define seh-victims : (Array (-> i64 i64) 2)
    (array seh-victim-framed seh-victim-fpo)))

(cfg
  windows
  (define (seh-run [label : String] [result : i64]) : i64
    (io.print-format "{} mismatch={} result={}\n" label seh-mismatch result)
    seh-mismatch))

(cfg
  windows
  (define (seh-main) : i64
    (if (> (array-length seh-victims) 2)
      1
      (unsafe
        (let
          [framed : i64 (seh-run "framed" (seh-drive-framed 11))]
          [_reset : unit (set! seh-mismatch -1)]
          [fpo : i64 (seh-run "fpo" (seh-drive-fpo 13))]
          (if (and (= framed 0) (= fpo 0))
            0
            1))))))

(define (main) : i64
  (cfg windows (seh-main) 0))