(import stdlib.net)
(import stdlib.net.ip as ip)
(import stdlib.test)
(import stdlib.net_fake as fake)
(import stdlib.tests.net_conformance as conformance)

(define (fixture) : conformance.Fixture
  (conformance.Fixture
    (fake.adapter (fake.new))
    fake.script!
    fake.calls
    fake.set-clock!
    fake.queue!
    fake.last-token
    fake.max-wait
    fake.written-sum))

(define (main) : i64
  (test.assert-true
    (net.status-ok?
      (net.validate-address (net.V4 (net.SocketAddrV4 (ip.ipv4 127 0 0 1) 0))))
    "port zero is valid")
  (test.assert-true
    (not
      (net.status-ok?
        (net.validate-address
          (net.V4 (net.SocketAddrV4 (ip.ipv4 127 0 0 1) -1)))))
    "negative port rejected")
  (conformance.run fixture)
  42)