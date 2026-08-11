;: Copy projections may be read, but an owning field cannot move out of a global.
(defstruct GlobalProjectionOwner
  (text String))

(define global-owner : GlobalProjectionOwner
  (GlobalProjectionOwner "owned"))

(define (main) : i64
  (let
    [_text : String global-owner.text]
    42))