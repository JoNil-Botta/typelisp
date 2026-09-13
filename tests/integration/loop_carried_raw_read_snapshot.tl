;; Refs #7418: retain the original dynamic-array/enum cursor reproducer.
;; The raw snapshot is stored before cursor is rebound; its offsets are 0123.
(defstruct L
  (slots (__tl_dyn-array i64))
  (offset i64)
  (len i64)
  (prependable bool))

(defenum LStep
  (Nil)
  (Cons i64 L))

(defmacro (place-shared-view [place : Expr]) : Expr
  `(unsafe
    (ptr-read (ptr-addr-of ,place))))

(define (l-step [items : L]) : LStep
  (let
    [len : i64 items.len]
    [offset : i64 items.offset]
    (if (<= len 0)
      (LStep.Nil)
      (LStep.Cons
        (unsafe
          (ptr-read (ptr-offset (__tl_array-data items.slots) offset)))
        (L (place-shared-view items.slots) (+ offset 1) (- len 1) false)))))

(define (probe) : i64
  (let
    [slots : (__tl_dyn-array i64) (__tl_make-array i64 4)]
    [fill : i64 0]
    [sources : (__tl_dyn-array L) (__tl_make-array L 4)]
    [heads : (__tl_dyn-array i64) (__tl_make-array i64 4)]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< fill 4)
        (begin
          (set! (array-ref slots fill) (+ fill 10))
          (set! fill (+ fill 1))))
      (let
        [cursor : L (L (place-shared-view slots) 0 4 true)]
        (begin
          (while (< index 4)
            (match (l-step (place-shared-view cursor))
              [(LStep.Nil) (set! index 4)]
              [(LStep.Cons head rest)
                (begin
                  (set! (array-ref sources index) (place-shared-view cursor))
                  (set! (array-ref heads index) head)
                  (set! cursor rest)
                  (set! index (+ index 1)))]))
          (set! index 0)
          (while (< index 4)
            (begin
              (set!
                acc
                (+
                  (* acc 10)
                  (unsafe
                    (ptr-read (ptr-offset (__tl_array-data sources) index))).offset))
              (set! index (+ index 1))))
          acc)))))

(define (main) : i64
  (if (= (probe) 123)
    42
    1))