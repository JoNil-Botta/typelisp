;# Arena-aware text buffer utilities for incremental string construction.
;#
;# `TextBuf` is a byte-oriented text builder backed by persistent snapshots.
;# Empty and one-chunk values stay inline; later appends use chronological
;# String prefixes with copy-on-write snapshots. Mutable `append!` helpers
;# update a latest snapshot in place, and `render` is the single operation
;# that materializes an owned `String` in the active arena.
;#
;# The owned and borrowed TextBuf declaration bodies are generated from
;# `stdlib/text_buf_family.tl`. This module keeps the owned compatibility
;# namespace and the public mutable macro shims; the borrowed-chunk companion
;# surface lives in `stdlib/text_buf_borrowed.tl`.
;#
;# Usage: `(import stdlib.text_buf)`
;#
;# ```typelisp
;# (import stdlib.text_buf)
;# (import stdlib.string)
;# (define (main) : i64
;#   (let [buf : text_buf.TextBuf
;#     (text_buf.append-int
;#       (text_buf.append (text_buf.empty) "n=")
;#       7)]
;#     (if (string.eq (text_buf.render buf) "n=7") 42 1)))
;# ```
;#
;# The buffer and rendered strings allocate in the active arena: the default
;# program-lifetime arena outside `(with-arena ...)`, or the scoped arena inside
;# one.
;; lint-allow: unused-import

;; lint-allow: unused-import
(import stdlib.arena)

;; lint-allow: unused-import
(import stdlib.byte_buf)
(import stdlib.comptime)

;; lint-allow: unused-import
(import stdlib.io)
(import stdlib.string)
(import stdlib.text_buf_family)

;# Emit the complete owned family in one declaration splice.
(text_buf_family.owned)

;: Mutably append `chunk` to the owned `buf` place without rendering its prefix.
(defmacro (append! [buf : comptime.Expr] [chunk : String]) : unit
  `(let
    [text-buf-append-chunk : String ,chunk]
    (set! ,buf (append ,buf text-buf-append-chunk))))

;: Mutably append one char byte to `buf`.
(defmacro (append-char! [buf : comptime.Expr] [c : char]) : unit
  `(append! ,buf (char-string ,c)))

;: Mutably append the decimal text for `value` to `buf`.
(defmacro (append-int! [buf : comptime.Expr] [value : i64]) : unit
  `(append! ,buf (int-string ,value)))

;: Mutably clear the owned `buf` place, leaving it ready for reuse.
(defmacro (clear! [buf : comptime.Expr]) : unit
  `(clear-ref! (&mut ,buf)))

;: Mutably reset `buf`, leaving it ready for reuse.
(defmacro (reset! [buf : comptime.Expr]) : unit
  `(clear-ref! (&mut ,buf)))

(test
  text-buf-scoped-arena-render-policy
  (let
    [fail : (-> unit)
      (lambda () : unit
        (begin
          (/ 1 0)
          unit))]
    [program-buf : TextBuf
      (stdlib.text_buf.append (stdlib.text_buf.empty) "scoped")]
    (with-arena
      outer
      (with-arena
        inner
        (let
          [rendered : String (stdlib.text_buf.render program-buf)]
          [expected : String "scoped"]
          (if (string.eq (& rendered) (& expected))
            unit
            (fail)))))))

;; Inline test coverage.
(cfg test (import stdlib.test))

(cfg
  test
  (define (text-buf-test-assert-owned-string-eq
    [actual : String]
    [expected : String]
    [message : String]) : unit
    (test.assert-string-eq (& actual) (& expected) message)))

(cfg
  test
  (define (text-buf-test-assert-text-buf
    [buf : TextBuf]
    [expected : String]
    [message : String]) : unit
    (let
      [actual-length : i64 buf.len]
      [expected-length : i64 (string-length expected)]
      (begin
        (test.assert-i64-eq
          actual-length
          expected-length
          (string.copy (& message)))
        (stdlib.text_buf.text-buf-test-assert-owned-string-eq
          (stdlib.text_buf.render buf)
          expected
          message)))))

(cfg
  test
  (define (text-buf-test-main) : i64
    (begin
      (let
        [empty-buf : TextBuf (stdlib.text_buf.empty)]
        (test.assert-true
          (stdlib.text_buf.empty? (& empty-buf))
          "empty buffer predicate"))
      (stdlib.text_buf.text-buf-test-assert-text-buf
        (stdlib.text_buf.empty)
        ""
        "empty buffer renders empty")
      (stdlib.text_buf.text-buf-test-assert-text-buf
        (stdlib.text_buf.append
          (stdlib.text_buf.append
            (stdlib.text_buf.append (stdlib.text_buf.empty) "alpha")
            " ")
          "beta")
        "alpha beta"
        "append order")
      (let
        [items : (__tl_dyn-array String) (__tl_make-array String 5)]
        (begin
          (set! (array-ref items 0) "skip")
          (set! (array-ref items 1) "alpha")
          (set! (array-ref items 2) "")
          (set! (array-ref items 3) "-beta")
          (set! (array-ref items 4) "skip")
          (stdlib.text_buf.text-buf-test-assert-owned-string-eq
            (stdlib.text_buf.chunks-render-array-range items 1 4)
            "alpha-beta"
            "array range render keeps order with empty chunks")))
      (let
        [buf : TextBuf (stdlib.text_buf.empty)]
        (begin
          (stdlib.text_buf.append! buf "")
          (stdlib.text_buf.text-buf-test-assert-text-buf
            (clone buf)
            ""
            "mutable empty append leaves buffer empty")
          (stdlib.text_buf.append! buf "alpha")
          (stdlib.text_buf.append! buf "")
          (stdlib.text_buf.append! buf " beta")
          (stdlib.text_buf.text-buf-test-assert-text-buf
            (clone buf)
            "alpha beta"
            "mutable append order")))
      (let
        [buf : TextBuf (stdlib.text_buf.empty)]
        [i : i64 0]
        (begin
          (while (< i 6)
            (begin
              (set! buf (stdlib.text_buf.append buf "ha"))
              (set! i (+ i 1))))
          (stdlib.text_buf.text-buf-test-assert-text-buf
            buf
            "hahahahahaha"
            "repeated append")))
      (let
        [buf : TextBuf (stdlib.text_buf.empty)]
        [i : i64 0]
        (begin
          (while (< i 6)
            (begin
              (stdlib.text_buf.append! buf "ha")
              (set! i (+ i 1))))
          (stdlib.text_buf.text-buf-test-assert-text-buf
            buf
            "hahahahahaha"
            "mutable repeated append")))
      (let
        [buf : TextBuf (stdlib.text_buf.empty)]
        [i : i64 0]
        (begin
          (while (< i 40)
            (begin
              (set! buf (stdlib.text_buf.append buf "x"))
              (set! i (+ i 1))))
          (stdlib.text_buf.text-buf-test-assert-text-buf
            (clone buf)
            "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
            "dense chunk order crosses capacity boundary")
          (test.assert-i64-eq
            (stdlib.text_buf.chunk-count buf.chunks 0)
            40
            "dense chunk count crosses capacity boundary")))
      (let
        [base : TextBuf (stdlib.text_buf.append (stdlib.text_buf.empty) "base")]
        [left : TextBuf (stdlib.text_buf.append (clone base) "-left")]
        [right : TextBuf (stdlib.text_buf.append (clone base) "-right")]
        (begin
          (stdlib.text_buf.text-buf-test-assert-text-buf
            base
            "base"
            "functional base snapshot remains unchanged")
          (stdlib.text_buf.text-buf-test-assert-text-buf
            left
            "base-left"
            "functional left branch remains independent")
          (stdlib.text_buf.text-buf-test-assert-text-buf
            right
            "base-right"
            "functional right branch remains independent")))
      (let
        [base : TextBuf (stdlib.text_buf.empty)]
        [i : i64 0]
        (begin
          (while (< i 32)
            (begin
              (set! base (stdlib.text_buf.append base "o"))
              (set! i (+ i 1))))
          (let
            [outer-arena (arena.make)]
            [child-ok : bool
              (with-escape
                outer-arena
                (let
                  [child : TextBuf
                    (stdlib.text_buf.append (clone base) "-inner")]
                  (string.eq
                    (stdlib.text_buf.render child)
                    "oooooooooooooooooooooooooooooooo-inner")))]
            [sibling-ok : bool
              (with-escape
                outer-arena
                (let
                  [sibling : TextBuf
                    (stdlib.text_buf.append (clone base) "-sibling")]
                  (string.eq
                    (stdlib.text_buf.render sibling)
                    "oooooooooooooooooooooooooooooooo-sibling")))]
            (begin
              (test.assert-true child-ok "nested arena child growth renders")
              (test.assert-true
                sibling-ok
                "nested arena retained snapshot growth renders")))))
      (stdlib.text_buf.text-buf-test-assert-text-buf
        (stdlib.text_buf.append
          (stdlib.text_buf.append
            (stdlib.text_buf.append
              (stdlib.text_buf.append
                (stdlib.text_buf.empty)
                "0123456789abcdefg")
              "a")
            "b")
          "0123456789abcdefg")
        "0123456789abcdefgab0123456789abcdefg"
        "mixed small and large chunks")
      (stdlib.text_buf.text-buf-test-assert-text-buf
        (stdlib.text_buf.append-int
          (stdlib.text_buf.append-char
            (stdlib.text_buf.append-char
              (stdlib.text_buf.append (stdlib.text_buf.empty) "A")
              '\n')
            '\t')
          -12)
        "A\n\t-12"
        "char and int append")
      (let
        [buf : TextBuf (stdlib.text_buf.empty)]
        (begin
          (stdlib.text_buf.append! buf "A")
          (stdlib.text_buf.append-char! buf '\n')
          (stdlib.text_buf.append-char! buf '\t')
          (stdlib.text_buf.append-int! buf (cast -12 : i64))
          (stdlib.text_buf.text-buf-test-assert-text-buf
            buf
            "A\n\t-12"
            "mutable char and int append")))
      (let
        [left : TextBuf
          (stdlib.text_buf.append
            (stdlib.text_buf.append (stdlib.text_buf.empty) "left")
            "-")]
        [right : TextBuf
          (stdlib.text_buf.append
            (stdlib.text_buf.append (stdlib.text_buf.empty) "right")
            "\n")]
        (begin
          (stdlib.text_buf.text-buf-test-assert-text-buf
            (stdlib.text_buf.append-buffer left right)
            "left-right\n"
            "append buffer")))
      (let
        [original : TextBuf
          (stdlib.text_buf.append (stdlib.text_buf.empty) "keep")]
        (begin
          (stdlib.text_buf.text-buf-test-assert-text-buf
            (stdlib.text_buf.clear (clone original))
            ""
            "clear returns empty")
          (stdlib.text_buf.text-buf-test-assert-text-buf
            (stdlib.text_buf.reset (clone original))
            ""
            "reset returns empty")
          (stdlib.text_buf.text-buf-test-assert-text-buf
            original
            "keep"
            "clear leaves original value")))
      (let
        [buf : TextBuf (stdlib.text_buf.append (stdlib.text_buf.empty) "drop")]
        (begin
          (stdlib.text_buf.clear! buf)
          (stdlib.text_buf.text-buf-test-assert-text-buf
            (clone buf)
            ""
            "mutable clear empties buffer")
          (stdlib.text_buf.append! buf "again")
          (stdlib.text_buf.text-buf-test-assert-text-buf
            (clone buf)
            "again"
            "mutable append after clear")
          (stdlib.text_buf.reset! buf)
          (stdlib.text_buf.text-buf-test-assert-text-buf
            buf
            ""
            "mutable reset empties buffer")))
      42)))

(cfg
  test
  (test
    text-buf-api
    (test.assert-i64-eq
      (stdlib.text_buf.text-buf-test-main)
      42
      "text-buf-api fixture result")))