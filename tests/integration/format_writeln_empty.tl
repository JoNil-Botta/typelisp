;; Writer-only `(format.writeln! writer)` (#6985): exactly one LF through the
;; normal writer adapter, `FormatOk` on success, no allocation into a
;; preallocated destination, and the same first `FormatErr` as the
;; template-bearing form when the writer fails.
(import stdlib.byte_buf)
(import stdlib.format)
(import stdlib.format_writer_core)
(import stdlib.profile)
(import stdlib.string)
(import stdlib.text_buf)

(defstruct FailingWriter
  (bytes byte_buf.ByteBuf)
  (remaining i64)
  (calls i64))

(define (format-writer-cell [writer : FailingWriter]) : (Array FailingWriter 1)
  (array writer))

; Accepts `remaining` bytes in total and reports status 77 for the first call
; it cannot take completely.
(unsafe
  (define (format-write-raw [address : i64] [data : String]) : i64
    (let
      [contents : (& data bytes) (byte_buf.str-as-bytes (& data))]
      [count : i64 (byte_buf.bytes-length contents)]
      [slot : (MutPtr FailingWriter)
        (unsafe
          (int->ptr (cast address : u64) : (MutPtr FailingWriter)))]
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
              (byte_buf.push writer.bytes (byte_buf.bytes-ref contents index)))
            (set! index (+ index 1))))
        (set! writer.remaining (- writer.remaining accepted))
        (set! writer.calls (+ writer.calls 1))
        (unsafe
          (ptr-write! slot writer))
        (if (= accepted count)
          0
          77)))))

(define (format-write-capability [context : i64] [data : String]) : i64
  (let
    [address : i64
      (unsafe
        (format_writer_core.format-writer-acquire-address
          context
          (format_writer_core.format-writer-key FailingWriter)))]
    (if (= address 0)
      format_writer_core.invalid-context-status
      (let
        [status : i64
          (unsafe
            (format-write-raw address data))]
        (begin
          (unsafe
            (format_writer_core.format-writer-release context))
          status)))))

(define (ok? [result : format.FormatResult]) : bool
  (match result
    [(format.FormatOk) true]
    [(format.FormatErr _) false]))

(define (error-77? [result : format.FormatResult]) : bool
  (match result
    [(format.FormatOk) false]
    [(format.FormatErr status) (= status 77)]))

(define (main) : i64
  (let
    [bytes : byte_buf.ByteBuf (byte_buf.with-capacity 16)]
    [before-empty : i64 (profile.alloc-total)]
    [empty-result : format.FormatResult (format.writeln! bytes)]
    [empty-allocations : i64 (- (profile.alloc-total) before-empty)]
    [mixed : byte_buf.ByteBuf (byte_buf.with-capacity 16)]
    [mixed-first : format.FormatResult
      (format.writeln! mixed "a{}" (cast 1 : i64))]
    [mixed-second : format.FormatResult (format.writeln! mixed)]
    [mixed-third : format.FormatResult (format.write! mixed "z")]
    [text : text_buf.TextBuf (text_buf.empty)]
    [text-result : format.FormatResult (format.writeln! text)]
    [text-again : format.FormatResult (format.writeln! text)]
    ;; A writer that can take nothing: the single LF is the failing call.
    [closed : FailingWriter (FailingWriter (byte_buf.new) 0 0)]
    [closed-result : format.FormatResult (format.writeln! closed)]
    [closed-templated : FailingWriter (FailingWriter (byte_buf.new) 0 0)]
    [closed-templated-result : format.FormatResult
      (format.writeln! closed-templated "")]
    ;; A writer with room for exactly the LF succeeds once and fails next time.
    [one : FailingWriter (FailingWriter (byte_buf.new) 1 0)]
    [one-first : format.FormatResult (format.writeln! one)]
    [one-second : format.FormatResult (format.writeln! one)]
    [after-empty : String (byte_buf.to-string bytes)]
    [after-mixed : String (byte_buf.to-string mixed)]
    [rendered-text : String (text_buf.render text)]
    [closed-rendered : String (byte_buf.to-string closed.bytes)]
    [one-rendered : String (byte_buf.to-string one.bytes)]
    (if (and
      (ok? empty-result)
      (= empty-allocations 0)
      (= (string.string-length (& after-empty)) 1)
      (string.eq (& after-empty) "\n")
      (ok? mixed-first)
      (ok? mixed-second)
      (ok? mixed-third)
      (string.eq (& after-mixed) "a1\n\nz")
      (ok? text-result)
      (ok? text-again)
      (string.eq (& rendered-text) "\n\n")
      (error-77? closed-result)
      (error-77? closed-templated-result)
      (= closed.calls 1)
      (= closed.calls closed-templated.calls)
      (string.eq (& closed-rendered) "")
      (ok? one-first)
      (error-77? one-second)
      (= one.calls 2)
      (string.eq (& one-rendered) "\n"))
      42
      1)))