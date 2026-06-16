(import "stdlib/test.tl")
(import "stdlib/profile.tl")

(define (profile-test-allocation) : String
  (string-append "profile" "-test"))

(define (main) : i64
  (begin
    (assert-true (>= (profile-now-ms) 0) "profile-now-ms is non-negative")
    (profile-alloc-reset-peak)
    (let
      [before-total : i64 (profile-alloc-total)]
      [before-live : i64 (profile-alloc-live)]
      [text : String (profile-test-allocation)]
      [after-total : i64 (profile-alloc-total)]
      [after-live : i64 (profile-alloc-live)]
      [peak : i64 (profile-alloc-peak)]
      (begin
        (assert-true
          (= (string-length (& text)) 12)
          "profile test allocation content is usable")
        (assert-true
          (>= after-total before-total)
          "profile total allocation counter is monotonic")
        (assert-true
          (>= after-live before-live)
          "profile live allocation counter is monotonic within the test")
        (assert-true (>= peak after-live) "profile peak covers current live")
        42))))