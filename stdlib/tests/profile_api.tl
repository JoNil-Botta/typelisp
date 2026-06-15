(import stdlib.test)

(import stdlib.profile)

(define (profile-test-allocation) : String
  (string-append "profile" "-test"))

(define (main) : i64
  (begin
    (test.assert-true (>= (profile.profile-now-ms) 0) "profile-now-ms is non-negative")
    (profile.profile-alloc-reset-peak)
    (let
      [before-total : i64 (profile.profile-alloc-total)]
      [before-live : i64 (profile.profile-alloc-live)]
      [text : String (profile-test-allocation)]
      [after-total : i64 (profile.profile-alloc-total)]
      [after-live : i64 (profile.profile-alloc-live)]
      [peak : i64 (profile.profile-alloc-peak)]
      (begin
        (test.assert-true
          (= (string-length (& text)) 12)
          "profile test allocation content is usable")
        (test.assert-true
          (>= after-total before-total)
          "profile total allocation counter is monotonic")
        (test.assert-true
          (>= after-live before-live)
          "profile live allocation counter is monotonic within the test")
        (test.assert-true (>= peak after-live) "profile peak covers current live")
        42))))