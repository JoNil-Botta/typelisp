(import stdlib.arena)
(import stdlib.clone)
(import stdlib.comptime)
(import stdlib.string)
(import clone_deep_expression_owner as owner)

(defenum Selection
  (Empty)
  (Selected (__tl_dyn-array owner.HTTPItem)))

(clone.gen-clone Selection)

(defmacro (clone-family [T : type]) : Module
  (let
    [name : comptime.Expr
      (comptime.expr-var
        (comptime.string-append "generated.clone_family." (type-key T)))]
    `(begin
      (module ,name)
      (import clone_deep_expression_owner)
      (define (copy [source : ,T]) : ,T
        (stdlib.clone.deep source)))))

(import (clone-family i64) as numbers)
(import (clone-family String) as strings)
(import (clone-family owner.HTTPItem) as items)

(define (one-item [label : (& label str)]) : (__tl_dyn-array owner.HTTPItem)
  (__tl_make-array (owner.HTTPItem (string.copy label) 7)))

(define (record-once [calls : (&mut calls i64)]) : (__tl_dyn-array
    owner.HTTPItem)
  (set! (deref calls) (+ (deref calls) 1))
  (one-item "once"))

(define (copy-item [item : (& item owner.HTTPItem)]) : owner.HTTPItem
  (clone.deep (deref item)))

(define (choose [flag : bool] [left : (& left str)] [right : (& right str)]) : String
  (if flag
    (clone.deep (string.copy left))
    (clone.deep (string.copy right))))

(define (selections-independent?) : bool
  (let
    [source : Selection (Selected (one-item "item"))]
    [copy : Selection (clone.deep source)]
    (match copy
      [(Selected selected) (set! (array-ref selected 0).count 99)]
      [(Empty) unit])
    (match (& source)
      [(Selected selected) (= (array-ref selected 0).count 7)]
      [(Empty) false])))

(define (copy-outlives-scratch?) : bool
  (let
    [destination (arena.make)]
    [copy : (in destination (__tl_dyn-array String))
      (with-arena
        scratch
        (let
          [source : (in scratch (__tl_dyn-array String))
            (__tl_make-array (string.copy "from scratch"))]
          (in-arena destination (clone.deep source))))]
    [intact? : bool (string.eq (array-ref copy 0) "from scratch")]
    (arena.destroy-safe! destination)
    intact?))

(define (main) : i64
  (let
    [source (tuple (array (box (one-item "nested"))) 8)]
    [copy (clone.deep source)]
    [calls : i64 0]
    [temporary (clone.deep (record-once (&mut calls)))]
    [text : String (choose true "original" "other")]
    [text-copy : String (clone.deep text)]
    [number : i64 (clone.deep 21)]
    [item : owner.HTTPItem (owner.HTTPItem "family" 7)]
    [family-item : owner.HTTPItem (items.copy (copy-item item))]
    [family-text : String (strings.copy (string.copy text))]
    (set! (array-ref (deref (array-ref (tuple-ref copy 0) 0)) 0).count 99)
    (set! (array-ref temporary 0).label "changed")
    (set! family-item.label "changed")
    (if (and
      (= (array-ref (deref (array-ref (tuple-ref source 0) 0)) 0).count 7)
      (= (array-ref (deref (array-ref (tuple-ref copy 0) 0)) 0).count 99)
      (= (tuple-ref copy 1) 8)
      (= calls 1)
      (string.eq (array-ref temporary 0).label "changed")
      (string.eq family-text "original")
      (string.eq text-copy "original")
      (unsafe
        (!= (ptr->int (string-data text)) (ptr->int (string-data text-copy))))
      (string.eq item.label "family")
      (string.eq family-item.label "changed")
      (copy-outlives-scratch?)
      (selections-independent?))
      (+ number (numbers.copy number))
      1)))