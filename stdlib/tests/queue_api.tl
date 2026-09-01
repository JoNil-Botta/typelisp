;: Generated deques retain String and move-only aggregate behavior.
(import stdlib.queue)
(import stdlib.string)

(defstruct QueueApiLabel
  (text String))

(import (queue.deque String) as string_queue)
(import (queue.deque QueueApiLabel) as label_queue)

(define (queue-api-strings-ok?) : bool
  (let
    [items : string_queue.Deque (string_queue.with-capacity 2)]
    (begin
      (string_queue.push-back! items "alpha")
      (string_queue.push-back! items "beta")
      (match (string_queue.pop-front! items)
        [(string_queue.Pop.Empty) false]
        [(string_queue.Pop.Ok first)
          (if (string.eq (& first) "alpha")
            (begin
              (string_queue.push-back! items "gamma")
              (string_queue.push-back! items "delta")
              (let
                [item-0 : String (string_queue.get (& items) 0 "missing")]
                [item-1 : String (string_queue.get (& items) 1 "missing")]
                [item-2 : String (string_queue.get (& items) 2 "missing")]
                (and
                  (= (string_queue.len (& items)) 3)
                  (> (string_queue.capacity (& items)) 2)
                  (string.eq (& item-0) "beta")
                  (string.eq (& item-1) "gamma")
                  (string.eq (& item-2) "delta"))))
            false)]))))

(define (queue-api-labels-ok?) : bool
  (let
    [items : label_queue.Deque (label_queue.with-capacity 1)]
    (begin
      (label_queue.push-front! items (QueueApiLabel "second"))
      (label_queue.push-front! items (QueueApiLabel "first"))
      (let
        [front : QueueApiLabel
          (label_queue.get (& items) 0 (QueueApiLabel "missing"))]
        (if (string.eq (& front.text) "first")
          (match (label_queue.pop-back! items)
            [(label_queue.Pop.Empty) false]
            [(label_queue.Pop.Ok last)
              (and
                (string.eq (& last.text) "second")
                (= (label_queue.len (& items)) 1))])
          false)))))

(define (main) : i64
  (if (and (queue-api-strings-ok?) (queue-api-labels-ok?))
    42
    1))