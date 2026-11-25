(import stdlib.eq)
(import stdlib.arena)
(import stdlib.clone)
(import stdlib.comptime)
(import stdlib.hashmap)
(import stdlib.string)
(import stdlib.vector)
(import clone_deep_expression_owner as owner)

(defstruct CopyCell
  (count i64))

(eq.gen CopyCell)

(defenum CopyChoice
  (Missing)
  (Present CopyCell))

(eq.gen CopyChoice)

(defstruct CopyPair
  (left CopyChoice)
  (right CopyChoice))

(eq.gen CopyPair)

(import (vector.vector CopyPair) as copy_vec)
(import (vector.vector String) as text_vec)
(import (hashmap.hashmap String String) as text_map)

(defenum Selection
  (Empty)
  (Selected (__tl_dyn-array owner.HTTPItem))
  (CollectionSnapshot text_vec.Vec text_map.Map CopyCell))

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
      [_ unit])
    (match (& source)
      [(Selected selected) (= (array-ref selected 0).count 7)]
      [_ false])))

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

(define (copy-nominal-elements?) : bool
  (let
    [items : copy_vec.Vec
      (copy_vec.from-slice
        (& (array (CopyPair (Present (CopyCell 42)) Missing))))]
    [copy : copy_vec.Vec (clone.deep items)]
    (match (copy_vec.get (& copy) 0 (CopyPair Missing Missing)).left
      [(Present cell) (= cell.count 42)]
      [(Missing) false])))

(define (collection-hooks-copy-storage?) : bool
  (let
    [items : text_vec.Vec (text_vec.with-capacity 9)]
    [entries : text_map.Map (text_map.with-capacity 16)]
    (text_vec.push! items "original")
    (text_map.insert! entries "live" "value")
    (text_map.insert! entries "removed" "other")
    (text_map.remove! entries "removed")
    (let
      [source : Selection (CollectionSnapshot items entries (CopyCell 42))]
      [copy : Selection (clone.deep source)]
      (match source
        [(CollectionSnapshot source-items source-entries _)
          (text_vec.set! source-items 0 "changed")
          (text_map.clear-ref! (&mut source-entries))]
        [_ unit])
      (match copy
        [(CollectionSnapshot copied-items copied-entries stamp)
          (and
            (= stamp.count 42)
            (= (text_vec.capacity (& copied-items)) 9)
            (string.eq (text_vec.get (& copied-items) 0 "") "original")
            (= (text_map.capacity (& copied-entries)) 16)
            (= (text_map.deleted (& copied-entries)) 1)
            (string.eq
              (text_map.lookup-value-or
                (text_map.get (& copied-entries) "live")
                "")
              "value"))]
        [_ false]))))

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
    [raw-copy : owner.RawBuf
      (clone.deep
        (owner.RawBuf
          (unsafe
            (int->ptr (cast 0 : u64) : (MutPtr u8)))
          7))]
    [stamp-copy : owner.CopyStamp (clone.deep (owner.CopyStamp 7))]
    (set! (array-ref (deref (array-ref (tuple-ref copy 0) 0)) 0).count 99)
    (set! (array-ref temporary 0).label "changed")
    (set! family-item.label "changed")
    (if (and
      (= (array-ref (deref (array-ref (tuple-ref source 0) 0)) 0).count 7)
      (= (array-ref (deref (array-ref (tuple-ref copy 0) 0)) 0).count 99)
      (= (tuple-ref copy 1) 8)
      (= raw-copy.count 8)
      (= stamp-copy.count 8)
      (= calls 1)
      (string.eq (array-ref temporary 0).label "changed")
      (string.eq family-text "original")
      (string.eq text-copy "original")
      (copy-nominal-elements?)
      (collection-hooks-copy-storage?)
      (unsafe
        (!= (ptr->int (string-data text)) (ptr->int (string-data text-copy))))
      (string.eq item.label "family")
      (string.eq family-item.label "changed")
      (copy-outlives-scratch?)
      (selections-independent?))
      (+ number (numbers.copy number))
      1)))