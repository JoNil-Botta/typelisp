(import stdlib.byte_buf)
(import stdlib.format)
(import stdlib.string)

(defstruct FailingWriter
  (bytes byte_buf.ByteBuf)
  (remaining i64)
  (calls i64))

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
    (if (and
      (error-77? result)
      (string.eq (& rendered) "ab4")
      (= writer.calls 2))
      42
      1)))