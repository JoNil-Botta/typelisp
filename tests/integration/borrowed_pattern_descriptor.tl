;; A dynamic array payload stores a descriptor handle. Borrowing it must load
;; that handle; the address of its enum/tuple/array slot is not the descriptor.
(import stdlib.string)

(defenum DescriptorPayload
  (Empty)
  (Values (__tl_dyn-array i64))
  (Text String)
  (Boxed (Box i64))
  (Inline (Array i64 2)))

(defstruct DescriptorOuter
  (payload DescriptorPayload)
  (padding i64))

(define (descriptor-values) : (__tl_dyn-array i64)
  (__tl_make-array 19 23))

(define (descriptor-enum) : i64
  (let
    [outer : DescriptorOuter
      (DescriptorOuter (DescriptorPayload.Values (descriptor-values)) 999)]
    (match (& outer.payload)
      [(DescriptorPayload.Values values)
        (if (= (array-length values) 2)
          (+ (array-ref values 0) (array-ref values 1))
          1)]
      [_ 2])))

(define (descriptor-tuple) : i64
  (let
    [tuple : (Tuple (__tl_dyn-array i64) i64) (tuple (descriptor-values) 999)]
    (match (& tuple)
      [(tuple values _)
        (if (= (array-length values) 2)
          (+ (array-ref values 0) (array-ref values 1))
          1)])))

(define (descriptor-array) : i64
  (let
    [values : (Array (__tl_dyn-array i64) 1) (array (descriptor-values))]
    (match (& values)
      [(array inner)
        (if (= (array-length inner) 2)
          (+ (array-ref inner 0) (array-ref inner 1))
          1)])))

;; These controls distinguish each representation: String has its own borrowed
;; descriptor, Box borrows the handle slot, and inline arrays borrow storage.
(define (descriptor-other-enum-payloads) : bool
  (let
    [text : DescriptorPayload (DescriptorPayload.Text "forty two")]
    [boxed : DescriptorPayload (DescriptorPayload.Boxed (box 42))]
    [inline : DescriptorPayload (DescriptorPayload.Inline (array 19 23))]
    (and
      (match (& text)
        [(DescriptorPayload.Text value) (= (string.string-length value) 9)]
        [_ false])
      (match (& boxed)
        [(DescriptorPayload.Boxed value) (= (deref (& (deref value))) 42)]
        [_ false])
      (match (& inline)
        [(DescriptorPayload.Inline value)
          (= (+ (array-ref value 0) (array-ref value 1)) 42)]
        [_ false]))))

(define (descriptor-other-tuple-elements) : bool
  (let
    [values : (Tuple String (Box i64) (Array i64 2))
      (tuple "forty two" (box 42) (array 19 23))]
    (match (& values)
      [(tuple text boxed inline)
        (and
          (= (string.string-length text) 9)
          (= (deref (& (deref boxed))) 42)
          (= (+ (array-ref inline 0) (array-ref inline 1)) 42))])))

(define (descriptor-other-array-elements) : bool
  (let
    [texts : (Array String 1) (array "forty two")]
    [boxed : (Array (Box i64) 1) (array (box 42))]
    [inline : (Array (Array i64 2) 1) (array (array 19 23))]
    (and
      (match (& texts)
        [(array text) (= (string.string-length text) 9)])
      (match (& boxed)
        [(array value) (= (deref (& (deref value))) 42)])
      (match (& inline)
        [(array value) (= (+ (array-ref value 0) (array-ref value 1)) 42)]))))

(define (main) : i64
  (if (and
    (= (descriptor-enum) 42)
    (= (descriptor-tuple) 42)
    (= (descriptor-array) 42)
    (descriptor-other-enum-payloads)
    (descriptor-other-tuple-elements)
    (descriptor-other-array-elements))
    42
    1))