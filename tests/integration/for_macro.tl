;; Scalar `for` selects the iterator protocol from source ownership, evaluates
;; every source once, and stops at the shortest source when clauses are zipped.
(import stdlib.iterator)
(import stdlib.string)
(import stdlib.vector)

(defstruct ForCounter
  (value i64))

(import (vector.vector ForCounter) as counters)

(define for-cleanup-total : i64
  0)

(define (record-for-cleanup [value : i64]) : unit
  (set! for-cleanup-total (+ for-cleanup-total value)))

(defstruct ForCleanupToken
  (:cleanup cleanup-for-cleanup-token)
  (value i64 (:cleanup record-for-cleanup)))

(import (vector.vector ForCleanupToken) as cleanup_tokens)

(define for-source-evaluations : i64
  0)

(define (counted-range [start : i64] [end : i64]) : iterator.I64Range
  (begin
    (set! for-source-evaluations (+ for-source-evaluations 1))
    (iterator.range start end)))

(define (counter-vec [first : i64] [second : i64]) : counters.Vec
  (let
    [items : counters.Vec (counters.new)]
    (begin
      (counters.push-ref! (&mut items) (ForCounter first))
      (counters.push-ref! (&mut items) (ForCounter second))
      items)))

(define (cleanup-token-vec) : cleanup_tokens.Vec
  (cleanup_tokens.push-owned
    (cleanup_tokens.push-owned
      (cleanup_tokens.push-owned (cleanup_tokens.new) (ForCleanupToken 1))
      (ForCleanupToken 10))
    (ForCleanupToken 100)))

(define (reset-for-cleanup-total!) : unit
  (set! for-cleanup-total 0))

(define (consume-native-for-string [value : String]) : i64
  (string.string-length value))

(define (sum-native-array [items : (& source (Array i64 3))]) : i64
  (let
    [total : i64 0]
    (begin
      (for [item items] (set! total (+ total (deref item))))
      total)))

(define (bump-native-array! [items : (&mut source (Array i64 3))]) : unit
  (for [item items] (set! (deref item) (+ (deref item) 10))))

(define (sum-native-slice [items : (& source (Slice i64))]) : i64
  (let
    [total : i64 0]
    (begin
      (for [item items] (set! total (+ total (deref item))))
      total)))

(define (bump-native-slice! [items : (&mut source (Slice i64))]) : unit
  (for [item items] (set! (deref item) (+ (deref item) 10))))

(define (native-for-return) : i64
  (begin
    (for [item (array (ann 42 : i64) (ann 99 : i64))] (return item))
    0))

(define (native-for-ok?) : bool
  (let
    [copy-items : (Array i64 3) (array 1 2 3)]
    [borrowed-items : (Array i64 3) (array 1 2 3)]
    [slice-items : (Array i64 4) (array 1 2 3 100)]
    [strings : (Array String 3) (array "a" "bc" "def")]
    [empty-items : (Array i64 0) (array)]
    [zip-left : (Array i64 3) (array 1 2 3)]
    [zip-right : (Array i64 2) (array 10 20)]
    [break-items : (Array i64 3) (array 1 2 3)]
    [grid : (Array (Array i64 2) 2) (array (array 1 2) (array 3 4))]
    [owned-total : i64 0]
    [string-total : i64 0]
    [zip-total : i64 0]
    [nested-total : i64 0]
    [empty-visits : i64 0]
    [break-visits : i64 0]
    (begin
      (for [item copy-items] (set! owned-total (+ owned-total item)))
      (for
        [item : String strings]
        (set! string-total (+ string-total (consume-native-for-string item))))
      (for
        [left zip-left]
        [right zip-right]
        (set! zip-total (+ zip-total (+ left right))))
      (for
        [row grid]
        (for [item row] (set! nested-total (+ nested-total item))))
      (for [item empty-items] (set! empty-visits (+ empty-visits item)))
      (for [item break-items] (set! break-visits (+ break-visits item)) (break))
      (let
        [array-before : i64 (sum-native-array (& borrowed-items))]
        (begin
          (bump-native-array! (&mut borrowed-items))
          (let
            [array-after : i64 (sum-native-array (& borrowed-items))]
            [slice-before : i64
              (sum-native-slice (slice-view (& slice-items) 0 3))]
            (begin
              (bump-native-slice! (slice-mut-view (&mut slice-items) 0 3))
              (and
                (= (+ owned-total (array-ref copy-items 0)) 7)
                (= string-total 6)
                (= zip-total 33)
                (= nested-total 10)
                (= empty-visits 0)
                (= break-visits 1)
                (= (+ array-before array-after) 42)
                (=
                  (+
                    slice-before
                    (sum-native-slice (slice-view (& slice-items) 0 3)))
                  42)
                (= (array-ref slice-items 3) 100)
                (= (native-for-return) 42)))))))))

(define (for-cleanup-later-done-ok?) : bool
  (let
    [visits : i64 0]
    (begin
      (reset-for-cleanup-total!)
      (for
        [token : ForCleanupToken (cleanup-token-vec)]
        [index (iterator.range 0 0)]
        (set! visits (+ visits (+ token.value index 1))))
      (and (= visits 0) (= for-cleanup-total 111)))))

(define (for-cleanup-body-consume-ok?) : bool
  (let
    [visits : i64 0]
    (begin
      (reset-for-cleanup-total!)
      (for
        [token : ForCleanupToken (cleanup-token-vec)]
        [index (iterator.range 0 1)]
        (set! visits (+ visits (+ index 1)))
        (cleanup-for-cleanup-token token))
      (and (= visits 1) (= for-cleanup-total 111)))))

(define (for-cleanup-break-ok?) : bool
  (let
    [visits : i64 0]
    (begin
      (reset-for-cleanup-total!)
      (for
        [token : ForCleanupToken (cleanup-token-vec)]
        [index (iterator.range 0 3)]
        (set! visits (+ visits (+ token.value index)))
        (break))
      (and (= visits 1) (= for-cleanup-total 111)))))

(define (for-cleanup-continue-ok?) : bool
  (let
    [visits : i64 0]
    (begin
      (reset-for-cleanup-total!)
      (for
        [token : ForCleanupToken (cleanup-token-vec)]
        [index (iterator.range 0 2)]
        (set! visits (+ visits (+ index 1)))
        (continue))
      (and (= visits 3) (= for-cleanup-total 111)))))

(define (for-cleanup-return-value) : i64
  (begin
    (for
      [token : ForCleanupToken (cleanup-token-vec)]
      [index (iterator.range 0 3)]
      (return (+ token.value index)))
    99))

(define (for-cleanup-return-ok?) : bool
  (begin
    (reset-for-cleanup-total!)
    (let
      [value : i64 (for-cleanup-return-value)]
      (and (= value 1) (= for-cleanup-total 111)))))

(define (main) : i64
  (let
    [borrowed : counters.Vec (counter-vec 4 5)]
    [owned : counters.Vec (counter-vec 7 8)]
    [total : i64 0]
    [empty-visits : i64 0]
    [cleanup-visits : i64 0]
    ;; These names deliberately resemble the macro's private temporaries.
    ;; lint-allow: local-name-case -- macro hygiene collision fixture
    [__for_source_0 : i64 1]
    ;; lint-allow: local-name-case -- macro hygiene collision fixture
    [__for_iterator_0 : i64 2]
    ;; lint-allow: local-name-case -- macro hygiene collision fixture
    [__for_done_0 : i64 4]
    (begin
      (for [item : i64 (counted-range 1 4)] (set! total (+ total item)))
      (for [item (& borrowed)] (set! total (+ total item.value)))
      (for [item (&mut borrowed)] (set! item.value (+ item.value 10)))
      (for [item (& borrowed)] (set! total (+ total item.value)))
      (for [item : ForCounter owned] (set! total (+ total item.value)))
      (for
        [left (iterator.range 0 3)]
        [right : i64 (iterator.range 10 11)]
        (set! total (+ total (+ left right))))
      (for
        [item (iterator.range 2 2)]
        (set! empty-visits (+ empty-visits (+ item 1))))
      (for [item (iterator.range 0 1)] (set! total (+ total item)))
      (for
        [item (iterator.range 0 1)]
        (set!
          total
          (+
            total
            (+ item (+ __for_source_0 (+ __for_iterator_0 __for_done_0))))))
      (for
        [token : ForCleanupToken (cleanup-token-vec)]
        (set! cleanup-visits (+ cleanup-visits 1))
        (cleanup-for-cleanup-token token)
        (break))
      (cond
        [(not (= total 76)) total]
        [(not (= empty-visits 0)) 2]
        [(not (= cleanup-visits 1)) 3]
        [(not (= for-source-evaluations 1)) 4]
        [(not (= for-cleanup-total 111)) for-cleanup-total]
        [(not (for-cleanup-later-done-ok?)) 5]
        [(not (for-cleanup-body-consume-ok?)) 6]
        [(not (for-cleanup-break-ok?)) 7]
        [(not (for-cleanup-continue-ok?)) 8]
        [(not (for-cleanup-return-ok?)) 9]
        [(not (native-for-ok?)) 10]
        [else 42]))))