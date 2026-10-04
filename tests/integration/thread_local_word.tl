(import stdlib.thread)
(import (thread.handle i64) as task)
(import stdlib.arena)
(import stdlib.string)

;; The raw address stays in its owning thread. Only scalar results cross join.
(unsafe
  (extern (storage) : (MutPtr i64) (:symbol "tl_thread_local_word_addr")))

(define ready : i64
  0)
(define released : i64
  0)

(define (read-word) : i64
  (unsafe
    (ptr-read (ptr-cast (storage) : (Ptr i64)))))

(define (write-word [value : i64]) : unit
  (unsafe
    (ptr-write! (storage) value)))

(define (arena-stable? [value : i64]) : bool
  (let
    [before : u64
      (unsafe
        (ptr->int (storage)))]
    [owner : arena.Arena (arena.make)]
    [in-owner : bool
      (in-arena
        owner
        (with-arena
          scratch
          (let
            [text : String (string.append "scratch" "-allocation")]
            (and
              (= (string.string-length text) 18)
              (= (read-word) value)
              (=
                (unsafe
                  (ptr->int (storage)))
                before)))))]
    (arena.destroy-safe! owner)
    (and
      in-owner
      (= (read-word) value)
      (=
        (unsafe
          (ptr->int (storage)))
        before))))

(define (live-worker [value : i64]) : i64
  (let
    [fresh : bool (= (read-word) 0)]
    (write-word value)
    (unsafe
      (atomic-fetch-add! (ptr-addr-of ready) 1))
    (while (=
      (unsafe
        (atomic-load (ptr-addr-of released)))
      0)
      unit)
    (if (and fresh (= (read-word) value) (arena-stable? value))
      42
      1)))

(define (join-value [handle : task.Handle]) : i64
  (match (task.join handle)
    [(task.I64JoinOk value) value]
    [(task.I64JoinErr _) -1]))

(define (release!) : unit
  (unsafe
    (atomic-store! (ptr-addr-of released) 1)))

(define (two-live) : bool
  (match (task.spawn
    (lambda () : i64
      (live-worker 11)))
    [(task.I64SpawnErr _) false]
    [(task.I64SpawnOk first)
      (match (task.spawn
        (lambda () : i64
          (live-worker 23)))
        [(task.I64SpawnErr _)
          (release!)
          (join-value first)
          false]
        [(task.I64SpawnOk second)
          (while (<
            (unsafe
              (atomic-load (ptr-addr-of ready)))
            2)
            unit)
          (let
            [parent-ok : bool (= (read-word) 37)]
            (release!)
            (let
              [first-value : i64 (join-value first)]
              [second-value : i64 (join-value second)]
              (and
                parent-ok
                (= first-value 42)
                (= second-value 42)
                (= (read-word) 37))))])]))

(define (fresh-worker) : i64
  (let
    [fresh : bool (= (read-word) 0)]
    (write-word 53)
    (if (and fresh (arena-stable? 53))
      42
      1)))

(define (main) : i64
  (if (not (= (read-word) 0))
    1
    (begin
      (write-word 37)
      (if (not (two-live))
        2
        (let
          [round : i64 0]
          [ok : bool (arena-stable? 37)]
          (while (and ok (< round 32))
            (match (task.spawn
              (lambda () : i64
                (fresh-worker)))
              [(task.I64SpawnErr _) (set! ok false)]
              [(task.I64SpawnOk handle) (set! ok (= (join-value handle) 42))])
            (set! round (+ round 1)))
          (if (and ok (= (read-word) 37))
            42
            3))))))