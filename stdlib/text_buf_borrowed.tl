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

;# Emit the complete borrowed family in one declaration splice.
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
      (if (string.eq (render sliced-one) "alpha\n")
        unit
        (test-fail))
      (if (= (chunk-count mixed) 3)
        unit
        (test-fail))
      (if (string.eq mixed-rendered "alpha\nbeta-!")
        unit
        (test-fail))
      (let
        [many-source : String "x"]
        [many : (TextBufBorrowed many-source) (empty-like (& many-source))]
        [many-index : i64 0]
        (begin
          (while (< many-index 40)
            (begin
              (set! many (append many (& many-source)))
              (set! many-index (+ many-index 1))))
          (if (= (chunk-count many) 40)
            unit
            (test-fail))
          (if (= (length many) 40)
            unit
            (test-fail))
          (if (string.eq
            (render many)
            "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx")
            unit
            (test-fail))))
      (let
        [branch-source : String "branch"]
        [branch-base : (TextBufBorrowed branch-source)
          (empty-like (& branch-source))]
        [branch-left : (TextBufBorrowed branch-source)
          (append-char branch-base '!')]
        [branch-right : (TextBufBorrowed branch-source)
          (append-owned branch-base "?")]
        (begin
          (if (= (chunk-count branch-base) 0)
            unit
            (test-fail))
          (if (string.eq (render branch-left) "!")
            unit
            (test-fail))
          (if (string.eq (render branch-right) "?")
            unit
            (test-fail))))
      (let
        [mixed-source : String "abc"]
        [mixed-empty : (TextBufBorrowed mixed-source)
          (empty-like (& mixed-source))]
        [mixed-left : (TextBufBorrowed mixed-source)
          (append-slice mixed-empty (& mixed-source) 0 2)]
        [mixed-right : (TextBufBorrowed mixed-source)
          (append-char
            (append-owned (append-slice mixed-empty (& mixed-source) 2 1) "-")
            '!')]
        [joined : (TextBufBorrowed mixed-source)
          (append-buffer mixed-left mixed-right)]
        [owned-rendered : String
          (match joined
            [(TextBufBorrowed joined-chunks joined-len)
              (let
                [owned : text_buf.TextBuf
                  (text_buf.TextBuf (chunks-to-owned joined-chunks) joined-len)]
                (text_buf.render owned))])]
        (begin
          (if (string.eq (render joined) "abc-!")
            unit
            (test-fail))
          (if (string.eq owned-rendered (render joined))
            unit
            (test-fail)))))))