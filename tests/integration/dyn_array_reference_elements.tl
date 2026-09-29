;; Private dynamic arrays of shared references: a borrowed element is one
;; pointer word, so init, push through several reallocations, element reads and
;; writes, length, struct storage, parameter and return passing, and copying
;; into a fresh array behave as for any other one-word element.
(import stdlib.string)

(defstruct Views
  (:lifetimes text)
  (items (__tl_dyn-array (& text str)))
  (len i64))

;; Append in place only when this value is the backing array's frontier;
;; otherwise copy the live prefix so a retained shorter value never sees it.
(define (views-push [views : (Views text)] [value : (& text str)]) : (Views
    text)
  (let
    [items : (__tl_dyn-array (& text str)) views.items]
    [len : i64 views.len]
    (if (= (array-length items) len)
      (begin
        (__tl_array-push! items value)
        (Views items (+ len 1)))
      (let
        [fresh : (__tl_dyn-array (& text str))
          (init : (__tl_dyn-array (& text str)))]
        [index : i64 0]
        (begin
          (while (< index len)
            (begin
              (__tl_array-push! fresh (array-ref items index))
              (set! index (+ index 1))))
          (__tl_array-push! fresh value)
          (Views fresh (+ len 1)))))))

(define (total-length [views : (& views (Views text))]) : i64
  (let
    [index : i64 0]
    [total : i64 0]
    (begin
      (while (< index views.len)
        (begin
          (set!
            total
            (+ total (string.string-length (array-ref views.items index))))
          (set! index (+ index 1))))
      total)))

(define (pick-refs [a : (& cell i64)] [b : (& cell i64)]) : (__tl_dyn-array
    (& cell i64))
  (let
    [refs : (__tl_dyn-array (& cell i64))
      (init : (__tl_dyn-array (& cell i64)))]
    (begin
      (__tl_array-push! refs a)
      (__tl_array-push! refs a)
      (set! (array-ref refs 1) b)
      refs)))

(define (main) : i64
  (let
    [owner : String "abcdefghijklmnopqrstuvwxyz"]
    [empty : (Views owner) (Views (init : (__tl_dyn-array (& owner str))) 0)]
    [grown : (Views owner) (Views (init : (__tl_dyn-array (& owner str))) 0)]
    [index : i64 0]
    [y : i64 2]
    [z : i64 40]
    (begin
      ;; 26 one-byte views force the backing array through several reallocations.
      (while (< index 26)
        (begin
          (set!
            grown
            (views-push grown (string.substring-view (& owner) index 1)))
          (set! index (+ index 1))))
      (let
        [grown-ok : bool
          (and
            (= empty.len 0)
            (= (array-length empty.items) 0)
            (= grown.len 26)
            (= (array-length grown.items) 26)
            (= (total-length (& grown)) 26)
            (string.eq (array-ref grown.items 0) "a")
            (string.eq (array-ref grown.items 25) "z"))]
        [prefix : (Views owner) (Views grown.items 3)]
        ;; `prefix` is not the frontier, so this push copies into fresh storage
        ;; and the shared backing array keeps "d" at index 3.
        [branch : (Views owner)
          (views-push prefix (string.substring-view (& owner) 10 16))]
        [refs (pick-refs (& y) (& z))]
        (if (and
          grown-ok
          (= branch.len 4)
          (string.eq (array-ref branch.items 2) "c")
          (string.eq (array-ref branch.items 3) "klmnopqrstuvwxyz")
          (= (array-length refs) 2)
          (= (+ (deref (array-ref refs 0)) (deref (array-ref refs 1))) 42))
          42
          1)))))