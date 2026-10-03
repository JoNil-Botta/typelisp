;; Owned dynamic arrays are covariant in the lifetimes of their elements
;; (#8133): a dense list of borrowed text built from one string takes text from
;; shorter-lived strings after the list moves into a shorter-typed place
;; through a call and a struct field, an enum payload, and a let annotation.
(import stdlib.string)

(defstruct Words
  (:lifetimes text)
  (items (__tl_dyn-array (& text str))))

(defenum MaybeWords
  (:lifetimes text)
  (NoWords)
  (SomeWords (Words text)))

;; `_extra` fixes `text`, so the list shortens to its lifetime at the call.
(define (words-keep [words : (Words text)] [_extra : (& text str)]) : (Words
    text)
  words)

(define (total-length [words : (& view (Words text))]) : i64
  (let
    [i : i64 0]
    [sum : i64 0]
    (begin
      (while (< i (array-length words.items))
        (begin
          (set! sum (+ sum (string.string-length (array-ref words.items i))))
          (set! i (+ i 1))))
      sum)))

(define (main) : i64
  (let
    [first : String "echo"]
    [words : (Words first) (Words (init : (__tl_dyn-array (& first str))))]
    (begin
      (__tl_array-push! words.items (& first))
      (let
        [second : String "hello"]
        [longer : (Words second) (words-keep words (& second))]
        (begin
          (__tl_array-push! longer.items (& second))
          (let
            [third : String "world!"]
            [maybe : (MaybeWords third) (SomeWords longer)]
            (match maybe
              [(SomeWords held)
                (begin
                  (__tl_array-push! held.items (& third))
                  (let
                    [fourth : String "!"]
                    [items : (__tl_dyn-array (& fourth str)) held.items]
                    (begin
                      (__tl_array-push! items (& fourth))
                      (let
                        [all : (Words fourth) (Words items)]
                        (if (and
                          (= (array-length all.items) 4)
                          (= (total-length (& all)) 16))
                          42
                          1)))))]
              [(NoWords) 2])))))))