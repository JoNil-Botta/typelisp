;# Cryptographically secure operating-system random bytes.
;#
;# `fill-random!` fills an exact caller-owned mutable `bytes` view. Linux uses
;# the x86-64 `getrandom` syscall with flags zero in 256-byte requests. Windows
;# resolves `BCryptGenRandom` from the system `bcrypt.dll` through kernel32 at
;# runtime, so binaries retain the audited kernel32/ntdll import boundary.
;#
;# Every host result is checked. Failures wipe the complete valid output view
;# before returning a structured error, and no deterministic generator, clock,
;# identifier, device file, or other fallback is used. A zero-length view
;# succeeds without invoking the host. `stdlib.random`, including
;# `random.from-system`, remains noncryptographic and must never supply keys,
;# nonces, challenges, blinding values, or protocol secrets.
;#
;# Usage: `(import stdlib.crypto_random)`
;#
;# ```typelisp
;# (import stdlib.byte_buf)
;# (import stdlib.crypto_random)
;# (define (main) : i64
;#   (let
;#     [buf : byte_buf.ByteBuf
;#       (byte_buf.from-array (__tl_make-array u8 32))]
;#     (match (crypto_random.fill-random! (byte_buf.as-mut-bytes (&mut buf)))
;#       [(crypto_random.OkFillRandom) 42]
;#       [(crypto_random.ErrFillRandom _) 1])))
;# ```
(import stdlib.byte_buf)
(cfg test (import stdlib.test))

;: Distinct failures returned by cryptographic random-byte fills.
(defenum CryptoRandomError
  (CryptoRandomInvalidLength i64)
  (CryptoRandomInvalidChunkLimit i64)
  (CryptoRandomPointerOverflow i64)
  (CryptoRandomLinuxSystemError i64)
  (CryptoRandomInterruptionExhausted i64)
  (CryptoRandomImpossiblePartial i64 i64)
  (CryptoRandomWindowsLibraryUnavailable u32)
  (CryptoRandomWindowsSymbolUnavailable u32)
  (CryptoRandomWindowsStatus i32)
  (CryptoRandomWindowsUnloadError u32))

;: Result of filling a complete mutable byte range from a cryptographic source.
(defenum ResultFillRandom
  (OkFillRandom)
  (ErrFillRandom CryptoRandomError))

;: One response from the checked low-level fill adapter.
;:
;: This surface lets deterministic tests exercise the completion loop without
;: turning deterministic randomness into a mode of the production OS API.
(defenum CryptoRandomHostStep
  (CryptoRandomHostFilled i64)
  (CryptoRandomHostInterrupted)
  (CryptoRandomHostFailure CryptoRandomError))

;: Maximum consecutive/total interruptions accepted for one fill operation.
(define (interruption-limit) : i64
  128)

;: Overwrite every byte in a valid caller-designated view with zero.
(define (wipe! [out : (&mut out bytes)]) : unit
  (let
    [n : i64 (byte_buf.bytes-mut-length out)]
    [index : i64 0]
    (begin
      (while (< index n)
        (begin
          (byte_buf.bytes-set! out index (cast 0 : u8))
          (set! index (+ index 1))))
      unit)))

;: Wipe a valid output view and return `error`.
(define (fill-failure! [out : (&mut out bytes)] [error : CryptoRandomError]) : ResultFillRandom
  (begin
    (wipe! out)
    (ErrFillRandom error)))

;: Check that pointer offsets for the complete nonempty view cannot wrap.
(define (pointer-range-valid? [data : (MutPtr u8)] [length : i64]) : bool
  (if (<= length 0)
    (= length 0)
    (let
      [base : u64
        (unsafe
          (ptr->int (ptr-cast data : (Ptr u8))))]
      [last-offset : u64 (cast (- length 1) : u64)]
      (and (!= base (cast 0 : u64)) (<= last-offset (- (cast -1 : u64) base))))))

;: Fill a range through an injected checked host adapter.
;:
;: `max-request` bounds every adapter call. The adapter must write at most the
;: returned positive count starting at `data`; the driver validates that count,
;: advances only after valid progress, bounds interruptions, and wipes on every
;: failure. This is the low-level deterministic test/provider seam; production
;: callers normally use `fill-random!`.
(define (fill-random-with!
  [out : (&mut out bytes)]
  [max-request : i64]
  [fill-chunk : (-> (MutPtr u8) i64 CryptoRandomHostStep)]) : ResultFillRandom
  (let
    [length : i64 (byte_buf.bytes-mut-length out)]
    (cond
      [(< length 0) (fill-failure! out (CryptoRandomInvalidLength length))]
      [(<= max-request 0)
        (fill-failure! out (CryptoRandomInvalidChunkLimit max-request))]
      [(= length 0) (OkFillRandom)]
      [else
        (let
          [data : (MutPtr u8)
            (unsafe
              (byte_buf.bytes-mut-data out))]
          (if (not (pointer-range-valid? data length))
            (fill-failure! out (CryptoRandomPointerOverflow length))
            (let
              [offset : i64 0]
              [interruptions : i64 0]
              [done : bool false]
              [result : ResultFillRandom (OkFillRandom)]
              (while (not done)
                (let
                  [remaining : i64 (- length offset)]
                  [requested : i64
                    (if (> remaining max-request)
                      max-request
                      remaining)]
                  [target : (MutPtr u8)
                    (unsafe
                      (ptr-offset data offset))]
                  (match (fill-chunk target requested)
                    [(CryptoRandomHostFilled count)
                      (if (or (<= count 0) (> count requested))
                        (begin
                          (set!
                            result
                            (fill-failure!
                              out
                              (CryptoRandomImpossiblePartial count requested)))
                          (set! done true))
                        (begin
                          (set! offset (+ offset count))
                          (if (= offset length)
                            (set! done true)
                            unit)))]
                    [(CryptoRandomHostInterrupted)
                      (begin
                        (set! interruptions (+ interruptions 1))
                        (if (>= interruptions (interruption-limit))
                          (begin
                            (set!
                              result
                              (fill-failure!
                                out
                                (CryptoRandomInterruptionExhausted
                                  interruptions)))
                            (set! done true))
                          unit))]
                    [(CryptoRandomHostFailure error)
                      (begin
                        (set! result (fill-failure! out error))
                        (set! done true))])))
              result)))])))

;: Linux x86-64 `getrandom` adapter preserving raw negative `-errno` status.
(cfg
  (not windows)
  (define (linux-random-step [data : (MutPtr u8)] [requested : i64]) : CryptoRandomHostStep
    (let
      [status : i64
        (unsafe
          (syscall
            318
            (cast (ptr->int (ptr-cast data : (Ptr u8))) : i64)
            requested
            0))]
      (cond
        [(= status -4) (CryptoRandomHostInterrupted)]
        [(< status 0)
          (CryptoRandomHostFailure (CryptoRandomLinuxSystemError status))]
        [else (CryptoRandomHostFilled status)]))))

;: Windows kernel32 dynamic-library loader.
(cfg
  windows
  (extern (windows-load-library [name : (Ptr u8)]) : i64 (:symbol "LoadLibraryA")))

;: Windows kernel32 exported-symbol resolver used for null validation.
(cfg
  windows
  (extern (windows-get-proc-address-address [module : i64] [name : (Ptr u8)]) : i64 (:symbol "GetProcAddress")))

;: Typed C-function-pointer view of the Windows exported-symbol resolver.
;:
;: This second declaration uses the same kernel32 symbol after the integer
;: address lookup has proved it non-null. A direct C-ABI extern call returning a
;: function type preserves raw C-function-pointer provenance in the compiler.
(cfg
  windows
  (extern (windows-get-proc-address-function [module : i64] [name : (Ptr u8)]) : (->
    i64
    (MutPtr u8)
    u32
    u32
    i32) (:symbol "GetProcAddress")))

;: Windows kernel32 module-reference release.
(cfg
  windows
  (extern (windows-free-library [module : i64]) : i32 (:symbol "FreeLibrary")))

;: Windows kernel32 last-error reader for loader failures.
(cfg windows (extern (windows-get-last-error) : u32 (:symbol "GetLastError")))

;: Return a stack-owned NUL-terminated `bcrypt.dll` spelling.
(cfg
  windows
  (define (windows-bcrypt-library-name) : (Array u8 11)
    (array
      (cast 'b' : u8)
      (cast 'c' : u8)
      (cast 'r' : u8)
      (cast 'y' : u8)
      (cast 'p' : u8)
      (cast 't' : u8)
      (cast '.' : u8)
      (cast 'd' : u8)
      (cast 'l' : u8)
      (cast 'l' : u8)
      (cast '\0' : u8))))

;: Return a stack-owned NUL-terminated `BCryptGenRandom` spelling.
(cfg
  windows
  (define (windows-bcrypt-symbol-name) : (Array u8 16)
    (array
      (cast 'B' : u8)
      (cast 'C' : u8)
      (cast 'r' : u8)
      (cast 'y' : u8)
      (cast 'p' : u8)
      (cast 't' : u8)
      (cast 'G' : u8)
      (cast 'e' : u8)
      (cast 'n' : u8)
      (cast 'R' : u8)
      (cast 'a' : u8)
      (cast 'n' : u8)
      (cast 'd' : u8)
      (cast 'o' : u8)
      (cast 'm' : u8)
      (cast '\0' : u8))))

;: Windows `BCryptGenRandom` adapter with one live DLL reference per call.
(cfg
  windows
  (define (windows-random-step [data : (MutPtr u8)] [requested : i64]) : CryptoRandomHostStep
    (let
      [library-name : (Array u8 11) (windows-bcrypt-library-name)]
      [module : i64
        (windows-load-library
          (unsafe
            (ptr-cast (__tl_array-data library-name) : (Ptr u8))))]
      [result : CryptoRandomHostStep
        (if (= module 0)
          (CryptoRandomHostFailure
            (CryptoRandomWindowsLibraryUnavailable (windows-get-last-error)))
          (let
            [symbol-name : (Array u8 16) (windows-bcrypt-symbol-name)]
            [address : i64
              (windows-get-proc-address-address
                module
                (unsafe
                  (ptr-cast (__tl_array-data symbol-name) : (Ptr u8))))]
            (if (= address 0)
              (let
                [error : u32 (windows-get-last-error)]
                [_released : i32 (windows-free-library module)]
                (CryptoRandomHostFailure
                  (CryptoRandomWindowsSymbolUnavailable error)))
              (let
                [bcrypt-gen-random : (-> i64 (MutPtr u8) u32 u32 i32)
                  (windows-get-proc-address-function
                    module
                    (unsafe
                      (ptr-cast (__tl_array-data symbol-name) : (Ptr u8))))]
                [status : i32
                  (bcrypt-gen-random
                    0
                    data
                    (cast requested : u32)
                    (cast 2 : u32))]
                [released : i32 (windows-free-library module)]
                (cond
                  [(!= status (cast 0 : i32))
                    (CryptoRandomHostFailure (CryptoRandomWindowsStatus status))]
                  [(= released (cast 0 : i32))
                    (CryptoRandomHostFailure
                      (CryptoRandomWindowsUnloadError (windows-get-last-error)))]
                  [else (CryptoRandomHostFilled requested)])))))]
      result)))

;: Fill every byte in `out` from the platform cryptographic random source.
;:
;: Linux issues requests of at most 256 bytes, the documented small-buffer
;: completion boundary. Windows issues requests of at most `ULONG_MAX`, avoiding
;: truncation at the `BCryptGenRandom` ABI. Zero bytes succeeds without a host
;: call. Success means the complete view was filled; every failure wipes it.
(define (fill-random! [out : (&mut out bytes)]) : ResultFillRandom
  (cfg
    windows
    (fill-random-with! out 4294967295 windows-random-step)
    (fill-random-with! out 256 linux-random-step)))

;: Inline-test adapter invocation count.
(cfg
  test
  (define test-host-call-count : i64
    0))

;: Reset the inline-test adapter state.
(cfg
  test
  (define (test-host-reset!) : unit
    (begin
      (set! test-host-call-count 0)
      unit)))

;: Write `count` deterministic bytes for inline adapter coverage.
(cfg
  test
  (define (test-host-write! [data : (MutPtr u8)] [count : i64] [base : i64]) : unit
    (let
      [index : i64 0]
      (begin
        (while (< index count)
          (begin
            (unsafe
              (ptr-write! (ptr-offset data index) (cast (+ base index) : u8)))
            (set! index (+ index 1))))
        unit))))

;: Inline-test adapter that completes one request in two partial writes.
(cfg
  test
  (define (test-host-partial [data : (MutPtr u8)] [requested : i64]) : CryptoRandomHostStep
    (let
      [count : i64
        (if (= test-host-call-count 0)
          (if (> requested 2)
            2
            requested)
          requested)]
      (begin
        (test-host-write! data count (+ 40 (* test-host-call-count 10)))
        (set! test-host-call-count (+ test-host-call-count 1))
        (CryptoRandomHostFilled count)))))

;: Inline-test adapter that is interrupted twice and then succeeds.
(cfg
  test
  (define (test-host-interrupt-then-fill [data : (MutPtr u8)] [requested : i64]) : CryptoRandomHostStep
    (begin
      (set! test-host-call-count (+ test-host-call-count 1))
      (if (<= test-host-call-count 2)
        (CryptoRandomHostInterrupted)
        (begin
          (test-host-write! data requested 70)
          (CryptoRandomHostFilled requested))))))

;: Inline-test adapter that never progresses.
(cfg
  test
  (define (test-host-always-interrupted
    [_data : (MutPtr u8)]
    [_requested : i64]) : CryptoRandomHostStep
    (begin
      (set! test-host-call-count (+ test-host-call-count 1))
      (CryptoRandomHostInterrupted))))

;: Inline-test adapter that reports an impossible zero-byte partial result.
(cfg
  test
  (define (test-host-zero-partial [_data : (MutPtr u8)] [_requested : i64]) : CryptoRandomHostStep
    (CryptoRandomHostFilled 0)))

;: Inline-test adapter for a missing Windows library result.
(cfg
  test
  (define (test-host-missing-library [_data : (MutPtr u8)] [_requested : i64]) : CryptoRandomHostStep
    (CryptoRandomHostFailure
      (CryptoRandomWindowsLibraryUnavailable (cast 126 : u32)))))

;: Inline-test adapter for a missing Windows symbol result.
(cfg
  test
  (define (test-host-missing-symbol [_data : (MutPtr u8)] [_requested : i64]) : CryptoRandomHostStep
    (CryptoRandomHostFailure
      (CryptoRandomWindowsSymbolUnavailable (cast 127 : u32)))))

;: Inline-test adapter for an exact `NTSTATUS` failure result.
(cfg
  test
  (define (test-host-windows-status [_data : (MutPtr u8)] [_requested : i64]) : CryptoRandomHostStep
    (CryptoRandomHostFailure
      (CryptoRandomWindowsStatus (cast -1073741811 : i32)))))

;: Inline-test adapter for an exact raw Linux `-errno` failure result.
(cfg
  test
  (define (test-host-linux-error [_data : (MutPtr u8)] [_requested : i64]) : CryptoRandomHostStep
    (CryptoRandomHostFailure (CryptoRandomLinuxSystemError -5))))

;: Fill a test buffer with a sentinel before failure-wipe assertions.
(cfg
  test
  (define (test-fill-sentinel! [buf : (&mut buf byte_buf.ByteBuf)]) : unit
    (let
      [view : (&mut buf bytes) (byte_buf.as-mut-bytes buf)]
      [index : i64 0]
      (while (< index (byte_buf.bytes-mut-length view))
        (begin
          (byte_buf.bytes-set! view index (cast 165 : u8))
          (set! index (+ index 1)))))))

;: Assert that every test-buffer byte equals `expected`.
(cfg
  test
  (define (test-assert-all-bytes
    [buf : (& buf byte_buf.ByteBuf)]
    [expected : i64]
    [message : String]) : unit
    (let
      [index : i64 0]
      (while (< index (byte_buf.len buf))
        (begin
          (test.assert-i64-eq
            (cast (byte_buf.ref buf index) : i64)
            expected
            (clone message))
          (set! index (+ index 1)))))))

;: Assert success from the checked fill driver.
(cfg
  test
  (define (test-assert-fill-ok [result : ResultFillRandom]) : unit
    (match result
      [(OkFillRandom) unit]
      [(ErrFillRandom _)
        (test.assert-true false "crypto random fill should succeed")])))

;: Assert the structured interruption-exhaustion result.
(cfg
  test
  (define (test-assert-interruption-error [result : ResultFillRandom]) : unit
    (match result
      [(ErrFillRandom (CryptoRandomInterruptionExhausted count))
        (test.assert-i64-eq count (interruption-limit) "interruption count")]
      [_ (test.assert-true false "expected interruption exhaustion")])))

;: Assert the structured impossible-partial result.
(cfg
  test
  (define (test-assert-impossible-partial [result : ResultFillRandom]) : unit
    (match result
      [(ErrFillRandom (CryptoRandomImpossiblePartial count requested))
        (begin
          (test.assert-i64-eq count 0 "impossible partial count")
          (test.assert-i64-eq requested 4 "impossible partial request"))]
      [_ (test.assert-true false "expected impossible partial result")])))

;: Assert invalid adapter limits and exact Linux status payloads.
(cfg
  test
  (define (test-assert-basic-error [result : ResultFillRandom] [kind : i64]) : unit
    (match result
      [(ErrFillRandom (CryptoRandomInvalidChunkLimit limit))
        (begin
          (test.assert-i64-eq kind 1 "invalid chunk kind")
          (test.assert-i64-eq limit 0 "invalid chunk limit"))]
      [(ErrFillRandom (CryptoRandomLinuxSystemError status))
        (begin
          (test.assert-i64-eq kind 2 "Linux error kind")
          (test.assert-i64-eq status -5 "exact Linux status"))]
      [_ (test.assert-true false "expected basic crypto-random error")])))

;: Assert injected Windows loader/status failures retain exact payloads.
(cfg
  test
  (define (test-assert-windows-error [result : ResultFillRandom] [kind : i64]) : unit
    (match result
      [(ErrFillRandom (CryptoRandomWindowsLibraryUnavailable code))
        (begin
          (test.assert-i64-eq kind 1 "library error kind")
          (test.assert-i64-eq (cast code : i64) 126 "library error code"))]
      [(ErrFillRandom (CryptoRandomWindowsSymbolUnavailable code))
        (begin
          (test.assert-i64-eq kind 2 "symbol error kind")
          (test.assert-i64-eq (cast code : i64) 127 "symbol error code"))]
      [(ErrFillRandom (CryptoRandomWindowsStatus status))
        (begin
          (test.assert-i64-eq kind 3 "status error kind")
          (test.assert-i64-eq (cast status : i64) -1073741811 "exact NTSTATUS"))]
      [_
        (test.assert-true false "expected injected Windows crypto-random error")])))

(cfg
  test
  (test
    crypto-random-driver
    (begin
      (let
        [empty : byte_buf.ByteBuf (byte_buf.from-array (__tl_make-array u8 0))]
        (begin
          (test-host-reset!)
          (test-assert-fill-ok
            (fill-random-with!
              (byte_buf.as-mut-bytes (&mut empty))
              4
              test-host-partial))
          (test.assert-i64-eq test-host-call-count 0 "zero length no host call")))
      (let
        [buf : byte_buf.ByteBuf (byte_buf.from-array (__tl_make-array u8 6))]
        (begin
          (test-host-reset!)
          (test-assert-fill-ok
            (fill-random-with!
              (byte_buf.as-mut-bytes (&mut buf))
              4
              test-host-partial))
          (test.assert-i64-eq test-host-call-count 2 "partial fill call count")
          (test.assert-i64-eq
            (cast (byte_buf.ref buf 0) : i64)
            40
            "partial first byte")
          (test.assert-i64-eq
            (cast (byte_buf.ref buf 5) : i64)
            53
            "partial final byte")))
      (let
        [buf : byte_buf.ByteBuf (byte_buf.from-array (__tl_make-array u8 4))]
        (begin
          (test-host-reset!)
          (test-assert-fill-ok
            (fill-random-with!
              (byte_buf.as-mut-bytes (&mut buf))
              4
              test-host-interrupt-then-fill))
          (test.assert-i64-eq test-host-call-count 3 "interruption retry count")
          (test.assert-i64-eq
            (cast (byte_buf.ref buf 3) : i64)
            73
            "interruption retry output")))
      (let
        [buf : byte_buf.ByteBuf (byte_buf.from-array (__tl_make-array u8 4))]
        (begin
          (test-fill-sentinel! (&mut buf))
          (test-host-reset!)
          (test-assert-interruption-error
            (fill-random-with!
              (byte_buf.as-mut-bytes (&mut buf))
              4
              test-host-always-interrupted))
          (test-assert-all-bytes (& buf) 0 "interruption failure wipes")))
      (let
        [buf : byte_buf.ByteBuf (byte_buf.from-array (__tl_make-array u8 4))]
        (begin
          (test-fill-sentinel! (&mut buf))
          (test-assert-impossible-partial
            (fill-random-with!
              (byte_buf.as-mut-bytes (&mut buf))
              4
              test-host-zero-partial))
          (test-assert-all-bytes (& buf) 0 "impossible partial wipes")))
      (let
        [buf : byte_buf.ByteBuf (byte_buf.from-array (__tl_make-array u8 4))]
        (begin
          (test-fill-sentinel! (&mut buf))
          (test-host-reset!)
          (test-assert-basic-error
            (fill-random-with!
              (byte_buf.as-mut-bytes (&mut buf))
              0
              test-host-partial)
            1)
          (test.assert-i64-eq
            test-host-call-count
            0
            "invalid chunk no host call")
          (test-assert-all-bytes (& buf) 0 "invalid chunk wipes")
          (test-fill-sentinel! (&mut buf))
          (test-assert-basic-error
            (fill-random-with!
              (byte_buf.as-mut-bytes (&mut buf))
              4
              test-host-linux-error)
            2)
          (test-assert-all-bytes (& buf) 0 "Linux failure wipes")))
      (let
        [buf : byte_buf.ByteBuf (byte_buf.from-array (__tl_make-array u8 4))]
        (begin
          (test-fill-sentinel! (&mut buf))
          (test-assert-windows-error
            (fill-random-with!
              (byte_buf.as-mut-bytes (&mut buf))
              4
              test-host-missing-library)
            1)
          (test-assert-all-bytes (& buf) 0 "missing library wipes")
          (test-fill-sentinel! (&mut buf))
          (test-assert-windows-error
            (fill-random-with!
              (byte_buf.as-mut-bytes (&mut buf))
              4
              test-host-missing-symbol)
            2)
          (test-assert-all-bytes (& buf) 0 "missing symbol wipes")
          (test-fill-sentinel! (&mut buf))
          (test-assert-windows-error
            (fill-random-with!
              (byte_buf.as-mut-bytes (&mut buf))
              4
              test-host-windows-status)
            3)
          (test-assert-all-bytes (& buf) 0 "status failure wipes"))))))