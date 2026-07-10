(import stdlib.string)
(import stdlib.vector)
(import (vector.vector i64) as i64vec)
(import (vector.vector String) as strvec)

(define (main) : i64
  (let
    [numbers : i64vec.Vec (i64vec.with-capacity 1)]
    [words : strvec.Vec (strvec.new)]
    (begin
      (i64vec.push (&mut numbers) 10)
      (i64vec.push (&mut numbers) 32)
      (i64vec.set (&mut numbers) 0 11)
      (i64vec.reverse! (&mut numbers))
      (strvec.push (&mut words) "alpha")
      (strvec.push (&mut words) "beta")
      (match (strvec.pop (&mut words))
        [(strvec.Pop.Ok word)
          (if (and
            (= (i64vec.len (& numbers)) 2)
            (= (i64vec.get (& numbers) 0 0) 32)
            (i64vec.contains? (& numbers) 11)
            (string.eq word "beta")
            (string.eq (strvec.get (& words) 0 "") "alpha"))
            42
            1)]
        [(strvec.Pop.Empty) 1]))))
