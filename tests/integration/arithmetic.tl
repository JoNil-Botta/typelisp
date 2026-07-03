(define (main) : i64
  (let
    [int-result : i64 (+ (* 2 3 4) (+ 1 2 3 4) 13)]
    [f64-ok : bool (and (= (+ 1.5 2.25 3.25) 7.0) (= (* 1.5 2.0 4.0) 12.0))]
    [f32-a : f32 (cast 1.5 : f32)]
    [f32-b : f32 (cast 2.25 : f32)]
    [f32-c : f32 (cast 3.25 : f32)]
    [f32-d : f32 (cast 2.0 : f32)]
    [f32-e : f32 (cast 4.0 : f32)]
    [f32-ok : bool
      (and
        (= (+ f32-a f32-b f32-c) (cast 7.0 : f32))
        (= (* f32-a f32-d f32-e) (cast 12.0 : f32)))]
    (if (and f64-ok f32-ok)
      int-result
      1)))