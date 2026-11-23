(defstruct Token
  (:cleanup cleanup-token)
  (id i64))

(defstruct Tok2
  (:cleanup cleanup-tok2)
  (a i64)
  (b i64))

(defstruct TokF
  (:cleanup cleanup-tokf)
  (v f64))

(defstruct Holder
  (:cleanup cleanup-holder)
  (token Token (:owned))
  (other i64))

(defstruct Outer
  (:cleanup cleanup-outer)
  (holder Holder (:owned))
  (extra i64))

(defstruct Holder2
  (:cleanup cleanup-holder2)
  (tok2 Tok2 (:owned))
  (pad i64))

(defstruct HolderF
  (:cleanup cleanup-holderf)
  (tokf TokF (:owned))
  (pad i64))

(defenum PairChoice
  (:cleanup cleanup-pair-choice)
  (Left Token (:owned) i64)
  (Right i64 Token (:owned)))

(defstruct PairHolder
  (:cleanup cleanup-pair-holder)
  (pair PairChoice (:owned))
  (pad i64))

(defenum MaybeToken
  (:cleanup cleanup-maybe-token)
  (Just Token (:owned))
  (None))

(defenum OuterEnum
  (:cleanup cleanup-outer-enum)
  (Wrap MaybeToken (:owned) i64)
  (Empty))

(defstruct OuterEnumHolder
  (:cleanup cleanup-outer-enum-holder)
  (outer OuterEnum (:owned))
  (pad i64))

(define (bump-id [token : (&mut Token)]) : unit
  (set! token.id (+ token.id 10)))

(define (write-token [view : (&mut Holder)]) : unit
  (match view.token
    [token (set! token.id 10)]))

(define (write-holder [view : (&mut Outer)]) : i64
  (let
    [value
      (match view.holder
        [(fields token)
          (bump-id (&mut token))
          token.id])]
    (+ value 2)))

(define (write-tok2 [view : (&mut Holder2)]) : unit
  (match view.tok2
    [t
      (set! t.a 10)
      (set! t.b 20)]))

(define (write-tokf [view : (&mut HolderF)]) : unit
  (match view.tokf
    [t
      (set! t.v 3.0)
      (set! t.v 7.0)]))

(define (write-pair [view : (&mut PairHolder)]) : unit
  (match view.pair
    [(or (PairChoice.Left t 1) (PairChoice.Right 1 t)) (set! t.id 9)]
    [_ unit]))

(define (write-nested-enum [view : (&mut OuterEnumHolder)]) : unit
  (match view.outer
    [(OuterEnum.Wrap (MaybeToken.Just t) delta) (set! t.id (+ t.id delta))]
    [_ unit]))

(define (pair-id [pair : (& PairChoice)]) : i64
  (match pair
    [(PairChoice.Left t _) t.id]
    [(PairChoice.Right _ t) t.id]))

(define (outer-enum-id [outer : (& OuterEnum)]) : i64
  (match outer
    [(OuterEnum.Wrap (MaybeToken.Just t) _) t.id]
    [_ -1]))

(define (main) : i64
  (let
    [outer (Outer (Holder (Token 2) 0) 0)]
    [_write (write-token (&mut outer.holder))]
    [value (write-holder (&mut outer))]
    [stored : i64 outer.holder.token.id]
    [holder2 (Holder2 (Tok2 1 2) 0)]
    [_write2 (write-tok2 (&mut holder2))]
    [tok2-ok : bool (and (= holder2.tok2.a 10) (= holder2.tok2.b 20))]
    [holderf (HolderF (TokF 1.0) 0)]
    [_writef (write-tokf (&mut holderf))]
    [tokf-ok : bool (= holderf.tokf.v 7.0)]
    [left-holder (PairHolder (PairChoice.Left (Token 2) 1) 0)]
    [_write-left (write-pair (&mut left-holder))]
    [right-holder (PairHolder (PairChoice.Right 1 (Token 3)) 0)]
    [_write-right (write-pair (&mut right-holder))]
    [pair-ok : bool
      (and
        (= (pair-id (& left-holder.pair)) 9)
        (= (pair-id (& right-holder.pair)) 9))]
    [nested-holder
      (OuterEnumHolder (OuterEnum.Wrap (MaybeToken.Just (Token 4)) 5) 0)]
    [_write-nested (write-nested-enum (&mut nested-holder))]
    [nested-ok : bool (= (outer-enum-id (& nested-holder.outer)) 9)]
    (cleanup-outer outer)
    (cleanup-holder2 holder2)
    (cleanup-holderf holderf)
    (cleanup-pair-holder left-holder)
    (cleanup-pair-holder right-holder)
    (cleanup-outer-enum-holder nested-holder)
    (if (and tok2-ok tokf-ok pair-ok nested-ok)
      (+ value stored)
      1)))