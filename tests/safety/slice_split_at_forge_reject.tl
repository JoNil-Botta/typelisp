(defstruct ForgedSlicePair
  (:lifetimes source)
  (left (&mut source (Slice i64)))
  (right (&mut source (Slice i64))))

(define (forge [view : (&mut source (Slice i64))]) : (ForgedSlicePair source)
  (ForgedSlicePair view view))

(define (main) : i64
  (let
    [items : (Array i64 2) (array 1 2)]
    [view : (&mut items (Slice i64)) (slice-mut-view items 0 2)]
    [forged (forge view)]
    (+ (array-ref forged.left 0) (array-ref forged.right 0))))