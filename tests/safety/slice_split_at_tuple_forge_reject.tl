(define (forge [view : (&mut source (Slice i64))]) : (Tuple
    (&mut source (Slice i64))
    (&mut source (Slice i64)))
  (tuple view view))

(define (main) : i64
  (let
    [items : (Array i64 2) (array 1 2)]
    [view : (&mut items (Slice i64)) (slice-mut-view items 0 2)]
    [halves (forge view)]
    (+ (array-ref (tuple-ref halves 0) 0) (array-ref (tuple-ref halves 1) 0))))