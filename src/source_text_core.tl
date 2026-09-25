;; source_text_core.tl - Text helpers the tooling shares over raw source text.
;;
;; `starts-with?`, `ends-with?` and the `line-end` / `next-line-start` walk
;; belong in stdlib.string, but a new stdlib.string function is emitted into
;; every program that keeps the whole module, which changes generated code;
;; they live here until a codegen-changing change moves them.
(import stdlib.io)
(import stdlib.string)

;; True if `text` begins with `prefix`.
(define (starts-with? [text : (& text str)] [prefix : (& prefix str)]) : bool
  (string.is-string-prefix-at text prefix 0))

;; True if `text` ends with `suffix`.
(define (ends-with? [text : (& text str)] [suffix : (& suffix str)]) : bool
  (string.is-string-prefix-at
    text
    suffix
    (- (string.string-length text) (string.string-length suffix))))

;; End of the line starting at `start`: the index of the next `\n` or `\r`, or
;; the length of `text` when the last line is unterminated.
(define (line-end [text : (& text str)] [start : i64]) : i64
  (let
    [n : i64 (string.string-length text)]
    [i : i64 start]
    (begin
      (while (and
        (< i n)
        (not (= (string.string-ref text i) '\n'))
        (not (= (string.string-ref text i) '\r')))
        (set! i (+ i 1)))
      i)))

;; Start of the line after the one `line-end` ended at `end`, consuming one
;; `\n`, `\r` or `\r\n` break. At the end of `text` it returns `end`.
(define (next-line-start [text : (& text str)] [end : i64]) : i64
  (let
    [n : i64 (string.string-length text)]
    (cond
      [(>= end n) end]
      [(and
          (= (string.string-ref text end) '\r')
          (< (+ end 1) n)
          (= (string.string-ref text (+ end 1)) '\n'))
        (+ end 2)]
      [else (+ end 1)])))

(test
  source-text-prefix-suffix-and-line-helpers
  (unless
    (and
      (starts-with? "typelisp" "type")
      (starts-with? "typelisp" "")
      (not (starts-with? "type" "typelisp"))
      (ends-with? "stdlib/io.tl" ".tl")
      (ends-with? "io.tl" "")
      (not (ends-with? ".tl" "io.tl"))
      (not (ends-with? "io.tl" ".tlx"))
      (= (line-end "ab\r\ncd" 0) 2)
      (= (line-end "ab\ncd" 3) 5)
      (= (next-line-start "ab\r\ncd" 2) 4)
      (= (next-line-start "ab\rcd" 2) 3)
      (= (next-line-start "ab\n" 2) 3)
      (= (next-line-start "ab" 2) 2))
    (io.panic "source-text prefix/suffix/line helpers changed")))