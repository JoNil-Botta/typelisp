(import stdlib.profile)

(defstruct Slot
  (text String)
  (items (__tl_dyn-array i64)))

;; These nested descriptors used to need their own initialization.
(define (fixed-zero-byte-count) : i64
  (let
    [items : (Array (Array Slot 4) 64) (make-array (Array Slot 4) 64)]
    [bytes : (Ptr u8)
      (unsafe
        (ptr-cast (__tl_array-data items) : (Ptr u8)))]
    [index : i64 0]
    [zeroes : i64 0]
    (while (< index (comptime (size-of (type (Array (Array Slot 4) 64)))))
      (when
        (=
          (unsafe
            (ptr-read (ptr-offset bytes index)))
          (cast 0 : u8))
        (set! zeroes (+ zeroes 1)))
      (set! index (+ index 1)))
    zeroes))

(define (zero-length [length : i64]) : i64
  (let
    [items : (__tl_dyn-array Slot) (__tl_make-array Slot length)]
    (array-length items)))

(define (main) : i64
  (let
    [before : i64 (profile.alloc-total)]
    [zeroes : i64 (fixed-zero-byte-count)]
    [after-fixed : i64 (profile.alloc-total)]
    [empty-size : i64 (zero-length 0)]
    [after-empty : i64 (profile.alloc-total)]
    [live : (__tl_dyn-array Slot) (__tl_make-array Slot 8)]
    [after-live : i64 (profile.alloc-total)]
    [fixed-size : i64 (comptime (size-of (type (Array (Array Slot 4) 64))))]
    ;; Windows rounds an arena allocation request of zero up to one word.
    [empty-charge : i64 (cfg windows 8 0)]
    [backing-size : i64 (* 8 (comptime (size-of (type Slot))))]
    (if (and
      (= zeroes fixed-size)
      (= after-fixed before)
      (= empty-size 0)
      (= (- after-empty after-fixed) empty-charge)
      (= (- after-live after-empty) backing-size)
      (= (length (array-ref live 7).text) 0)
      (= (length (array-ref live 7).items) 0))
      0
      1)))