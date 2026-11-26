;; Recursive native layout crosses an explicit finite-size edge, never an
;; implicit box or pointer. A C-compatible (:repr c) struct models C recursion
;; with a raw pointer field, keeping the C layout and unsafe access rules. A
;; safe recursive struct uses an owning arena-backed Box edge, and the ordinary
;; recursive enum combines owned construction with checked borrowed traversal.
;; main yields 42 only if both layouts are finite and behave as declared.
(defstruct CNode
  (:repr c)
  (value i64)
  (next (Ptr CNode)))

(defenum ChainLink
  (ChainEnd)
  (ChainNode (Box Chain)))

(defstruct Chain
  (value i64)
  (next ChainLink))

(defenum BoxTree
  (Leaf i64)
  (Node (Box BoxTree) (Box BoxTree)))

(define (chain-sum [c : (& r Chain)]) : i64
  (match c.next
    [(ChainEnd) c.value]
    [(ChainNode next) (+ c.value (chain-sum (deref next)))]))

(define (tree-sum [t : (& r BoxTree)]) : i64
  (match t
    [(Leaf n) n]
    [(Node l r) (+ (tree-sum l) (tree-sum r))]))

(define (main) : i64
  (let
    [cnode : CNode (CNode 7 (ptr-null : (Ptr CNode)))]
    [chain : Chain (Chain 1 (ChainNode (box (Chain 2 (ChainEnd)))))]
    [tree : BoxTree (Node (box (Leaf 20)) (box (Leaf 22)))]
    (cond
      [(not (= (comptime (size-of (type CNode))) 16)) 1]
      [(not (= (comptime (offset-of (type CNode) next)) 8)) 2]
      [(not (ptr-null? cnode.next)) 3]
      [(not (= cnode.value 7)) 4]
      [(not (= (chain-sum (& chain)) 3)) 5]
      [(not (= (tree-sum (& tree)) 42)) 6]
      [else 42])))