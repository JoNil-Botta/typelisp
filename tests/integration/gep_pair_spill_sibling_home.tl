(import stdlib.array)
(import stdlib.string)

;; Regression for paired constant-GEP loads under emergency scavenging.
;;
;; `String` is a two-word fat pointer. In the failing opt2 shape, the data word
;; spilled through a scratch register, while the length word was register-homed
;; and immediately used by a bounds check. The first load's scratch could
;; emergency-borrow the sibling length home; the pair-level restore then
;; overwrote the just-loaded length with an older loop index, tripping a false
;; string-ref bounds abort.
(define (make-entry [name : String] [value : String]) : (__tl_dyn-array u8)
  (let
    [nl : i64 (string.string-length name)]
    [vl : i64 (string.string-length value)]
    [buf : (__tl_dyn-array u8) (array.make-array u8 (+ (+ nl vl) 2))]
    [i : i64 0]
    (begin
      (while (< i nl)
        (begin
          (array-set! buf i (cast (string.string-ref name i) : u8))
          (set! i (+ i 1))))
      (array-set! buf nl (cast 61 : u8))
      (set! i 0)
      (while (< i vl)
        (begin
          (array-set!
            buf
            (+ (+ nl 1) i)
            (cast (string.string-ref value i) : u8))
          (set! i (+ i 1))))
      (array-set! buf (+ (+ nl 1) vl) (cast 0 : u8))
      buf)))

(define (main) : i64
  (let
    [bytes : (__tl_dyn-array u8)
      (make-entry "TYPELISP_STDLIB_TEST_VALUE" "env-value-854")]
    (if (= (array-length bytes) 41)
      42
      1)))