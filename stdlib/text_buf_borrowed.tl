;# Borrowed text buffer companion surface.
;#
;# `TextBufBorrowed` stores `(& text str)` chunks without copying at append
;# time, plus owned chunks for explicit copy boundaries. Rendering copies
;# borrowed chunks at the materialization boundary, then delegates final ordered
;# chunk rendering to `text_buf.tl`.
;#
;# The borrowed and owned TextBuf declaration bodies are generated from
;# `stdlib/text_buf_family.tl`; this module keeps the flat borrowed
;# compatibility namespace and inline test surface.
;; lint-allow: unused-import
(import stdlib.array)
(import stdlib.string)

;; lint-allow: unused-import
(import stdlib.io)

;; lint-allow: unused-import
(import stdlib.text_buf)
(import stdlib.text_buf_family)

(text_buf_family.borrowed)

;: Inline test helper that forces a borrowed text buffer test failure.
(define (test-fail) : unit
  (begin
    (/ 1 0)
    unit))

;: Inline test helper that exercises borrowed text buffer rendering.
(define (test-render [text : String] [chunk : String]) : String
  (let
    [left : (TextBufBorrowed text) (append-owned (single (& text)) "-")]
    [right : (TextBufBorrowed text) (append (empty-like (& text)) (& text))]
    [joined : (TextBufBorrowed text) (append-buffer left right)]
    [copied : (TextBufBorrowed text) (append-copy joined (& chunk))]
    (render copied)))

(test
  text-buf-borrowed-api
  (let
    [text : String "alpha"]
    [chunk : String "tail"]
    [empty : (TextBufBorrowed text) (empty-like (& text))]
    [rendered : String (test-render text chunk)]
    [sliced-source : String "alpha\nbeta"]
    [sliced-empty : (TextBufBorrowed sliced-source)
      (empty-like (& sliced-source))]
    [sliced-zero : (TextBufBorrowed sliced-source)
      (append-slice sliced-empty (& sliced-source) 3 0)]
    [sliced-one : (TextBufBorrowed sliced-source)
      (append-slice sliced-zero (& sliced-source) 0 6)]
    [sliced-two : (TextBufBorrowed sliced-source)
      (append-slice sliced-one (& sliced-source) 6 4)]
    [mixed : (TextBufBorrowed sliced-source)
      (append-char (append-owned sliced-two "-") '!')]
    [mixed-rendered : String (render mixed)]
    (begin
      (if (empty? empty)
        unit
        (test-fail))
      (if (= (length empty) 0)
        unit
        (test-fail))
      (if (string.eq rendered "alpha-alphatail")
        unit
        (test-fail))
      (if (= (chunk-count sliced-zero) 0)
        unit
        (test-fail))
      (if (= (chunk-count sliced-two) 1)
        unit
        (test-fail))
      (if (= (length sliced-two) (string-length sliced-source))
        unit
        (test-fail))
      (if (string.eq (render sliced-two) sliced-source)
        unit
        (test-fail))
      (if (= (chunk-count mixed) 3)
        unit
        (test-fail))
      (if (string.eq mixed-rendered "alpha\nbeta-!")
        unit
        (test-fail)))))