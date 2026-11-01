(import stdlib.net)
(import stdlib.net_fake as fake)

(define (main) : i64
  (net.publish (fake.adapter (fake.new)) (net.Stream) 4 0)
  42)