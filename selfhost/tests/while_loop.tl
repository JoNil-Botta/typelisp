(let ((i 0))
  (let ((acc 0))
    (begin
      (while (< i 6)
        (begin
          (set! acc (+ acc 7))
          (set! i (+ i 1))))
      acc)))