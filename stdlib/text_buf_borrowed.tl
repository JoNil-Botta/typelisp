;# Borrowed text buffer companion surface.
;#
;# `TextBufBorrowed` stores `(& text str)` chunks without copying at append
;# time, plus owned chunks for explicit copy boundaries. Empty and one-chunk
;# values stay inline; dense values reuse the owned TextBufChunkList as their
;# committed prefix and carry one clone-visible String tail plus a bool merge
;# flag. Borrowed tails are String view headers retained by the lifetime
;# anchor; rendering materializes independent output bytes.
;# Rendering and `chunks-to-owned` delegate to the owned TextBuf machinery;
;# rendering materializes ordered bytes, while `chunks-to-owned` copies at the
;# explicit ownership boundary.
;#
;# The borrowed and owned TextBuf declaration bodies are generated from
;# `stdlib/text_buf_family.tl`; this module keeps the borrowed compatibility
;# namespace and small inline API test surface.
;; lint-allow: unused-import
;; lint-allow: unused-import
(import stdlib.arena)
(import stdlib.string)

;; lint-allow: unused-import
(import stdlib.io)

;; lint-allow: unused-import
(import stdlib.text_buf)
(import stdlib.text_buf_family)
(cfg test (import stdlib.test))

;# Emit the complete borrowed family in one declaration splice.
(text_buf_family.borrowed)

;: Inline test helper that forces a borrowed text buffer test failure.
(define (test-fail) : unit
  (/ 1 0)
  unit)

;: Inline test helper that exercises borrowed text buffer rendering.
(define (test-render [text : (& text str)] [chunk : (& chunk str)]) : String
  (let
    [left : (TextBufBorrowed text) (append-owned (single text) "-")]
    [right : (TextBufBorrowed text) (append (empty-like text) text)]
    [joined : (TextBufBorrowed text) (append-buffer left right)]
    [copied : (TextBufBorrowed text) (append-copy joined chunk)]
    (render copied)))

;: Inline test helper: two adjacent slices of `source` merged into one tail.
(cfg
  test
  (define (test-sliced-one [source : (& text str)]) : (TextBufBorrowed text)
    (append-slice (append-slice (empty-like source) source 3 0) source 0 6)))

;: Inline test helper: `test-sliced-one` extended over the rest of `source`.
(cfg
  test
  (define (test-sliced-two [source : (& text str)]) : (TextBufBorrowed text)
    (append-slice (test-sliced-one source) source 6 4)))

;: Inline test helper: a sliced buffer joined with a sliced, owned and char
;: tail buffer.
(cfg
  test
  (define (test-mixed-joined [source : (& text str)]) : (TextBufBorrowed text)
    (append-buffer
      (append-slice (empty-like source) source 0 2)
      (append-char
        (append-owned (append-slice (empty-like source) source 2 1) "-")
        '!'))))

(test
  text-buf-borrowed-api
  (let
    [text : String "alpha"]
    [chunk : String "tail"]
    [empty : (TextBufBorrowed text) (empty-like (& text))]
    [rendered : String (test-render text chunk)]
    [sliced-source : String "alpha\nbeta"]
    [sliced-zero : (TextBufBorrowed sliced-source)
      (append-slice (empty-like (& sliced-source)) (& sliced-source) 3 0)]
    [sliced-two : (TextBufBorrowed sliced-source)
      (test-sliced-two (& sliced-source))]
    [mixed : (TextBufBorrowed sliced-source)
      (append-char (append-owned (test-sliced-two (& sliced-source)) "-") '!')]
    [mixed-count : i64 (chunk-count mixed)]
    [mixed-rendered : String (render mixed)]
    (test.assert-true (empty? empty) "text-buf-borrowed-api: (empty? empty)")
    (test.assert-true
      (= (length empty) 0)
      "text-buf-borrowed-api: (= (length empty) 0)")
    (test.assert-true
      (string.eq rendered "alpha-alphatail")
      "text-buf-borrowed-api: (string.eq rendered \"alpha-alphatail\")")
    (test.assert-true
      (= (chunk-count sliced-zero) 0)
      "text-buf-borrowed-api: (= (chunk-count sliced-zero) 0)")
    (test.assert-true
      (= (chunk-count sliced-two) 1)
      "text-buf-borrowed-api: (= (chunk-count sliced-two) 1)")
    (test.assert-true
      (= (length sliced-two) (string-length sliced-source))
      "text-buf-borrowed-api: (= (length sliced-two) (string-length sliced-source))")
    (test.assert-true
      (string.eq (render sliced-two) sliced-source)
      "text-buf-borrowed-api: (string.eq (render sliced-two) sliced-source)")
    (test.assert-true
      (string.eq (render (test-sliced-one (& sliced-source))) "alpha\n")
      "text-buf-borrowed-api: (string.eq (render sliced-one) \"alpha\\n\")")
    (test.assert-true
      (= mixed-count 3)
      "text-buf-borrowed-api: (= (chunk-count mixed) 3)")
    (test.assert-true
      (string.eq mixed-rendered "alpha\nbeta-!")
      "text-buf-borrowed-api: (string.eq mixed-rendered \"alpha\\nbeta-!\")")
    (let
      [many-source : String "x"]
      [many : (TextBufBorrowed many-source) (empty-like (& many-source))]
      [many-index : i64 0]
      (while (< many-index 40)
        (set! many (append many (& many-source)))
        (set! many-index (+ many-index 1)))
      (test.assert-true
        (= (chunk-count many) 40)
        "text-buf-borrowed-api: (= (chunk-count many) 40)")
      (test.assert-true
        (= (length many) 40)
        "text-buf-borrowed-api: (= (length many) 40)")
      (test.assert-true
        (string.eq (render many) "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx")
        "text-buf-borrowed-api: (string.eq (render many) \"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx..."))
    (let
      [branch-source : String "branch"]
      [branch-base : (TextBufBorrowed branch-source)
        (empty-like (& branch-source))]
      [branch-left : (TextBufBorrowed branch-source)
        (append-char (empty-like (& branch-source)) '!')]
      [branch-right : (TextBufBorrowed branch-source)
        (append-owned (empty-like (& branch-source)) "?")]
      (test.assert-true
        (= (chunk-count branch-base) 0)
        "text-buf-borrowed-api: (= (chunk-count branch-base) 0)")
      (test.assert-true
        (string.eq (render branch-left) "!")
        "text-buf-borrowed-api: (string.eq (render branch-left) \"!\")")
      (test.assert-true
        (string.eq (render branch-right) "?")
        "text-buf-borrowed-api: (string.eq (render branch-right) \"?\")"))
    (let
      [mixed-source : String "abc"]
      [owned-rendered : String
        (match (test-mixed-joined (& mixed-source))
          [(TextBufBorrowed joined-chunks joined-len)
            (let
              [owned : text_buf.TextBuf
                (text_buf.TextBuf (chunks-to-owned joined-chunks) joined-len)]
              (text_buf.render owned))])]
      [joined-rendered : String (render (test-mixed-joined (& mixed-source)))]
      (test.assert-true
        (string.eq joined-rendered "abc-!")
        "text-buf-borrowed-api: (string.eq (render joined) \"abc-!\")")
      (test.assert-true
        (string.eq owned-rendered joined-rendered)
        "text-buf-borrowed-api: (string.eq owned-rendered (render joined))"))))