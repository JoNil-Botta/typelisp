;: A lambda cannot turn a nested non-Copy global into an owned result.
(defstruct GlobalNestedOwner
  (text String))

(define global-owner : GlobalNestedOwner
  (GlobalNestedOwner "owned"))

(define (make-reader) : (-> GlobalNestedOwner)
  (lambda () : GlobalNestedOwner
    global-owner))

(define (main) : i64
  42)