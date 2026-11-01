;; Owner/control IR workload. Full assertion diagnostics run in the native suite.
(import stdlib.net)
(import stdlib.net_fake as fake)

(define (duplicate-case) : bool
  (let
    [context : i64 (fake.new)]
    (match (net.tcp-stream-connect
      (fake.adapter context)
      (net.empty-address)
      (net.default-limits))
      [(StreamOk stream)
        (with
          ([owner stream net.cleanup-tcp-stream])
          (match (net.tcp-stream-duplicate! (&mut owner))
            [(StreamOk duplicate)
              (with
                ([other duplicate net.cleanup-tcp-stream])
                (net.tcp-stream-close! (&mut owner))
                (let
                  [option : net.NetOptionResult
                    (net.tcp-stream-set-option! (&mut other) (net.NoDelay) 1)]
                  [address : net.SocketAddrResult
                    (net.tcp-stream-local-address! (&mut other))]
                  (fake.set-pending-error! context 111)
                  (let
                    [pending : net.NetPendingError
                      (net.tcp-stream-take-error! (&mut other))]
                    (and
                      (match option
                        [(Option value) (= value 1)]
                        [_ false])
                      (match address
                        [(Address _) true]
                        [_ false])
                      (match pending
                        [(SocketError failure) (= failure.code 111)]
                        [_ false])
                      (net.status-ok?
                        (net.tcp-stream-shutdown!
                          (&mut other)
                          (net.ShutdownWrite)))
                      (= (fake.calls context (net.Duplicate)) 1)
                      (= (fake.calls context (net.Close)) 1)))))]
            [_ false]))]
      [_ false])))

(define (accept-case) : bool
  (let
    [context : i64 (fake.new)]
    (match (net.tcp-listener-bind
      (fake.adapter context)
      (net.empty-address)
      (net.default-limits))
      [(ListenerOk listener)
        (with
          ([owner listener net.cleanup-tcp-listener])
          (fake.script! context (net.Accept) 0 -1)
          (fake.script! context (net.Accept) 1 0)
          (match (net.tcp-listener-accept! (&mut owner) (net.default-limits))
            [(AcceptOk stream peer)
              (with
                ([accepted stream net.cleanup-tcp-stream])
                (and
                  (net.status-ok? (net.validate-address peer))
                  (= (fake.calls context (net.Accept)) 2)
                  (= (fake.calls context (net.WaitRead)) 1)
                  (match (net.tcp-stream-peer-address! (&mut accepted))
                    [(Address _) true]
                    [_ false])))]
            [_ false]))]
      [_ false])))

(define (main) : i64
  (if (and (duplicate-case) (accept-case))
    42
    1))