;; refs #6053: an explicit input lifetime is a signature-local binder even
;; when its spelling differs from the parameter name. It remains available to
;; local scalar and aggregate reborrows without becoming a value binding.
(import stdlib.array)

(defstruct SignatureAliasRec
  (value i64))

(defstruct SignatureAliasStored
  (field i64)
  (pair (Tuple i64 i64))
  (fixed (Array i64 1)))

(define (signature-alias-touch!
  [items : (&mut source (Array SignatureAliasRec))]
  [index : i64]) : unit
  (let
    [item : (&mut source SignatureAliasRec) (&mut (array-ref items index))]
    (begin
      (set! item.value (+ item.value 1))
      unit)))

(define (signature-alias-read-copy [value : (& source i64)]) : unit
  (let
    [copy : (& source i64) value]
    unit))

(define (signature-alias-project [stored : (& source SignatureAliasStored)]) : unit
  (let
    [field : (& source i64) (& (struct-get stored field))]
    [tuple-item : (& source i64) (& (tuple-ref (struct-get stored pair) 0))]
    [array-item : (& source i64) (& (array-ref (struct-get stored fixed) 0))]
    unit))

(define (signature-alias-same-input
  [left : (& same i64)]
  [right : (& same i64)]) : unit
  (let
    [left-copy : (& same i64) left]
    [right-copy : (& same i64) right]
    unit))

(define (signature-alias-value-lookup [item : (& source i64)] [source : i64]) : i64
  (let
    [copy : (& source i64) item]
    source))

(define (main) : i64
  (let
    [items : (Array SignatureAliasRec) (array.make-array SignatureAliasRec 1)]
    [stored : SignatureAliasStored
      (SignatureAliasStored 7 (tuple 8 9) (array 10))]
    [value : i64 11]
    (begin
      (array-set! items 0 (SignatureAliasRec 20))
      (signature-alias-touch! (&mut items) 0)
      (signature-alias-read-copy (& value))
      (signature-alias-project (& stored))
      (signature-alias-same-input (& value) (& value))
      (if (= (struct-get (array-ref items 0) value) 21)
        (signature-alias-value-lookup (& value) 42)
        0))))