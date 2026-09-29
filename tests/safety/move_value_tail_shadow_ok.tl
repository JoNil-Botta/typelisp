;; A leaf that names a binding of the consumed value itself (a `let` or a match
;; pattern) does not move the outer variable of the same name.
(define (close-fd [_fd : i64]) : unit
  unit)

(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))

(defenum Holder
  (:cleanup cleanup-holder)
  (Has FileHandle (:owned))
  (Empty))

(define (consume [h : FileHandle]) : i64
  (let
    [fd : i64 h.fd]
    (begin
      (cleanup-file-handle h)
      fd)))

(define (consume-box [b : (Box FileHandle)]) : i64
  (consume (deref b)))

(define (from-let [x : (Box FileHandle)] [z : (Box FileHandle)]) : i64
  (let
    [first : i64
      (consume-box
        (let
          [x : (Box FileHandle) z]
          x))]
    (+ first (consume-box x))))

(define (from-match [x : FileHandle] [held : Holder] [w : FileHandle]) : i64
  (let
    [second : i64
      (consume
        (match held
          [(Holder.Has x) x]
          [(Holder.Empty) w]))]
    (+ second (consume x))))

(define (main) : i64
  (+
    (from-let (box (FileHandle 20)) (box (FileHandle 1)))
    (from-match (FileHandle 20) (Holder.Has (FileHandle 1)) (FileHandle 0))))