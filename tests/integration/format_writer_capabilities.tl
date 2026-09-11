(import stdlib.byte_buf)
(import stdlib.format)
(import stdlib.format_writer_core)
(import stdlib.string)
(import stdlib.text_buf)
(import stdlib.thread)
(import (thread.handle i64) as thread_i64)

(defstruct RetainedHook
  (value i64))

(define (retained-writer-default [_context : i64] [_data : String]) : i64
  99)

(define retained-writer-callback : (-> i64 String i64)
  retained-writer-default)
(define retained-writer-context : i64
  0)

;; A safe direct-format hook may inspect and retain the callback. The opaque
;; context must become useless as soon as the enclosing writer macro returns.
(define (format-write
  [_value : (& value RetainedHook)]
  [formatter : (&mut formatter format.Formatter)]) : unit
  (begin
    (set! retained-writer-callback formatter.write-raw)
    (set! retained-writer-context formatter.context)
    (format.formatter-write-string! formatter "hook")))

(define (format-ok? [result : format.FormatResult]) : bool
  (match result
    [(format.FormatOk) true]
    [(format.FormatErr _) false]))

(define (main) : i64
  (let
    [buf : byte_buf.ByteBuf (byte_buf.new)]
    [cell : (Array byte_buf.ByteBuf 1) (array buf)]
    [address : i64
      (unsafe
        (cast (ptr->int (ptr-cast (__tl_array-data cell) : (Ptr u8))) : i64))]
    [callback : (-> i64 String i64) byte_buf.format-write-capability]
    [first-token : i64
      (unsafe
        (format_writer_core.format-writer-register
          address
          (format_writer_core.format-writer-key byte_buf.ByteBuf)))]
    [first-valid : i64 (callback first-token "first")]
    [_first-unregistered : unit
      (unsafe
        (format_writer_core.format-writer-unregister first-token))]
    [hook-buf : byte_buf.ByteBuf (byte_buf.new)]
    [hook-result : format.FormatResult
      (format.write! hook-buf "{}" (RetainedHook 7))]
    [retained-stale : i64
      (retained-writer-callback retained-writer-context "late")]
    [hook-rendered : String (byte_buf.to-string hook-buf)]
    [index : i64 0]
    (begin
      ;; Cycle through every other slot so slot zero is reused at a newer
      ;; generation. The retained first callback must remain invalid.
      (while (< index (- format_writer_core.format-writer-registry-capacity 1))
        (let
          [intermediate-token : i64
            (unsafe
              (format_writer_core.format-writer-register
                address
                (format_writer_core.format-writer-key byte_buf.ByteBuf)))]
          (begin
            (unsafe
              (format_writer_core.format-writer-unregister intermediate-token))
            (set! index (+ index 1)))))
      (let
        [current-token : i64
          (unsafe
            (format_writer_core.format-writer-register
              address
              (format_writer_core.format-writer-key byte_buf.ByteBuf)))]
        [stale-after-reuse : i64 (callback first-token "stale")]
        [wrong-writer : i64
          (text_buf.format-write-capability current-token "wrong")]
        [leased-address : i64
          (unsafe
            (format_writer_core.format-writer-acquire-address
              current-token
              (format_writer_core.format-writer-key byte_buf.ByteBuf)))]
        [busy-callback : i64 (callback current-token "busy")]
        [thread-busy : i64
          (match (thread_i64.spawn
            (lambda () : i64
              (byte_buf.format-write-capability current-token "thread")))
            [(thread_i64.I64SpawnErr _) -1]
            [(thread_i64.I64SpawnOk worker)
              (match (thread_i64.join worker)
                [(thread_i64.I64JoinErr _) -2]
                [(thread_i64.I64JoinOk status) status])])]
        [_released : unit
          (unsafe
            (format_writer_core.format-writer-release current-token))]
        [current-valid : i64 (callback current-token "current")]
        [teardown-address : i64
          (unsafe
            (format_writer_core.format-writer-acquire-address
              current-token
              (format_writer_core.format-writer-key byte_buf.ByteBuf)))]
        [teardown-spawn
          (thread_i64.spawn
            (lambda () : i64
              (begin
                (unsafe
                  (format_writer_core.format-writer-unregister current-token))
                91)))]
        [_teardown-released : unit
          (unsafe
            (format_writer_core.format-writer-release current-token))]
        [teardown-status : i64
          (match teardown-spawn
            [(thread_i64.I64SpawnErr _) -3]
            [(thread_i64.I64SpawnOk worker)
              (match (thread_i64.join worker)
                [(thread_i64.I64JoinErr _) -4]
                [(thread_i64.I64JoinOk status) status])])]
        [stale-after-unregister : i64 (callback current-token "late")]
        [forged : i64 (callback 1 "forged")]
        [finished : byte_buf.ByteBuf (array-ref cell 0)]
        [rendered : String (byte_buf.to-string finished)]
        (if (and
          (= first-valid 0)
          (format-ok? hook-result)
          (= retained-stale format_writer_core.invalid-context-status)
          (string.eq (& hook-rendered) "hook")
          (!= first-token current-token)
          (= stale-after-reuse format_writer_core.invalid-context-status)
          (= wrong-writer format_writer_core.invalid-context-status)
          (!= leased-address 0)
          (= busy-callback format_writer_core.invalid-context-status)
          (= thread-busy format_writer_core.invalid-context-status)
          (= current-valid 0)
          (!= teardown-address 0)
          (= teardown-status 91)
          (= stale-after-unregister format_writer_core.invalid-context-status)
          (= forged format_writer_core.invalid-context-status)
          (string.eq (& rendered) "firstcurrent"))
          42
          1)))))