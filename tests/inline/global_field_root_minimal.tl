(import stdlib.io)

(defstruct FieldRootState
  (value i64))

(define field-root-storage : FieldRootState
  (FieldRootState 42))

(define (field-root-answer) : i64
  field-root-storage.value)

(test
  global-field-root-retained
  (unless
    (= (field-root-answer) 42)
    (io.panic "inline test lost its global field value")))

(define (main) : i64
  (field-root-answer))