(import stdlib.byte_buf)
(import stdlib.format)
(import stdlib.string)

(defstruct FailingWriter
  (bytes byte_buf.ByteBuf)
  (remaining i64)
  (calls i64))

(defstruct HookValue
  (value i64))

(define fallback-hook-calls : i64
  0)

(define (to-string [_value : (& value HookValue)]) : String
  (begin
    (set! fallback-hook-calls (+ fallback-hook-calls 1))
    "fallback"))

(define (format-write
  [_value : (& value HookValue)]
  [formatter : (&mut formatter format.Formatter)]) : unit
  (begin
    (format.formatter-write-string! formatter "ho")
    ;; The formatter must skip this second hook write after the first error.
    (format.formatter-write-string! formatter "ok")))

(define (format-writer-cell [writer : FailingWriter]) : (Array FailingWriter 1)
  (array writer))

; The canonical adapter deliberately accepts a prefix of the failing call.
; Formatter must retain status 77 and skip every later plan piece.
(define (format-write-raw [context : i64] [data : (Ptr u8)] [count : i64]) : i64
  (let
    [slot : (MutPtr FailingWriter)
      (unsafe
        (int->ptr (cast context : u64) : (MutPtr FailingWriter)))]
    [writer : FailingWriter
      (unsafe
        (ptr-read (ptr-cast slot : (Ptr FailingWriter))))]
    [accepted : i64
      (if (< writer.remaining count)
        writer.remaining
        count)]
    [index : i64 0]
    (begin
      (while (< index accepted)
        (begin
          (set!
            writer.bytes
            (byte_buf.push
              writer.bytes
              (unsafe
                (ptr-read (ptr-offset data index)))))
          (set! index (+ index 1))))
      (set! writer.remaining (- writer.remaining accepted))
      (set! writer.calls (+ writer.calls 1))
      (unsafe
        (ptr-write! slot writer))
      (if (= accepted count)
        0
        77))))

(define (error-77? [result : format.FormatResult]) : bool
  (match result
    [(format.FormatOk) false]
    [(format.FormatErr status) (= status 77)]))

(define (main) : i64
  (let
    [writer : FailingWriter (FailingWriter (byte_buf.new) 3 0)]
    [result : format.FormatResult
      (format.write! writer "ab{}cd" (cast 42 : i64))]
    [rendered : String (byte_buf.to-string writer.bytes)]
    [hook-value : HookValue (HookValue 7)]
    [arguments (format.args "a{}z" hook-value)]
    [hook-writer : FailingWriter (FailingWriter (byte_buf.new) 2 0)]
    [hook-result : format.FormatResult (format.write! hook-writer arguments)]
    [hook-rendered : String (byte_buf.to-string hook-writer.bytes)]
    (if (and
      (error-77? result)
      (error-77? hook-result)
      (string.eq (& rendered) "ab4")
      (string.eq (& hook-rendered) "ah")
      (= writer.calls 2)
      (= hook-writer.calls 2)
      (= fallback-hook-calls 0)
      (= hook-value.value 7))
      42
      1)))