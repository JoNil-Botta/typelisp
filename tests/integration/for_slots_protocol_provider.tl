;; A slots/len collection whose module defines its own shared iterator. `for`
;; must use this protocol rather than walking `slots` by index: the iterator
;; starts at `start` and wraps, so the visiting order shows which one ran.
(defstruct Ring
  (slots (__tl_dyn-array i64))
  (len i64)
  (start i64))

(defstruct RingIter
  (:lifetimes source)
  (ring (& source Ring))
  (step i64))

(defenum RingNext
  (:lifetimes source)
  (Done)
  (Item (& source i64)))

(define (iterator [ring : (& source Ring)]) : (RingIter source)
  (RingIter ring 0))

(define (next [state : (&mut state (RingIter source))]) : (RingNext source)
  (let
    [step : i64 state.step]
    [ring : (& source Ring) state.ring]
    (if (>= step ring.len)
      (RingNext.Done)
      (begin
        (set! state.step (+ step 1))
        (RingNext.Item
          (& (array-ref ring.slots (% (+ ring.start step) ring.len))))))))