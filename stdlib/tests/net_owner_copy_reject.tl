(import stdlib.net)
(import stdlib.net_fake as fake)
(import stdlib.tests.net_conformance as c)

(define (main) : i64
  (with
    ([first
        (c.open-stream
          (c.Fixture
            (fake.adapter (fake.new))
            fake.script!
            fake.calls
            fake.set-clock!
            fake.queue!
            fake.last-token
            fake.max-wait
            fake.written-sum))
        net.cleanup-tcp-stream])
    (with
      ([second first net.cleanup-tcp-stream])
      (net.tcp-stream-close! (&mut first))
      42)))