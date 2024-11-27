;; Meta-Transaction Relay Contract
;; Enables gasless transactions through relay system

(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u100))
(define-constant err-invalid-signature (err u101))
(define-constant err-invalid-nonce (err u102))
(define-constant err-paused (err u103))
(define-constant err-invalid-relayer (err u104))

;; Data Variables
(define-data-var contract-paused bool false)
(define-map nonces principal uint)
(define-map relayers principal {reputation: uint, total-processed: uint})
(define-map transaction-queue 
    uint 
    {sender: principal, 
     action: (string-ascii 64),
     nonce: uint,
     timestamp: uint,
     signature: (buff 65),
     processed: bool})

(define-data-var queue-index uint u0)

;; Read-only functions
(define-read-only (get-nonce (user principal))
    (default-to u0 (map-get? nonces user)))

(define-read-only (is-paused)
    (var-get contract-paused))

(define-read-only (get-relayer-info (relayer principal))
    (map-get? relayers relayer))

(define-read-only (verify-signature (message (buff 256)) (signature (buff 65)) (signer principal))
    (is-eq (secp256k1-recover? message signature) (some signer)))

;; Private functions
(define-private (increment-nonce (user principal))
    (let ((current-nonce (get-nonce user)))
        (map-set nonces 
            user 
            (+ current-nonce u1))))

(define-private (update-relayer-stats (relayer principal))
    (let ((current-stats (unwrap-panic (get-relayer-info relayer))))
        (map-set relayers
            relayer
            {reputation: (+ (get reputation current-stats) u1),
             total-processed: (+ (get total-processed current-stats) u1)})))

;; Public functions
(define-public (register-relayer)
    (begin
        (asserts! (is-eq contract-owner tx-sender) err-owner-only)
        (ok (map-set relayers
            tx-sender
            {reputation: u0,
             total-processed: u0}))))

(define-public (toggle-pause)
    (begin
        (asserts! (is-eq contract-owner tx-sender) err-owner-only)
        (ok (var-set contract-paused (not (var-get contract-paused))))))

(define-public (submit-transaction 
    (action (string-ascii 64))
    (signature (buff 65)))
    (let
        ((sender tx-sender)
         (current-nonce (get-nonce sender))
         (message-hash (sha256 (concat (unwrap-panic (to-consensus-buff? action))
                                     (unwrap-panic (to-consensus-buff? current-nonce))))))
        (asserts! (not (var-get contract-paused)) err-paused)
        (asserts! (verify-signature message-hash signature sender) err-invalid-signature)
        (map-set transaction-queue
            (var-get queue-index)
            {sender: sender,
             action: action,
             nonce: current-nonce,
             timestamp: block-height,
             signature: signature,
             processed: false})
        (var-set queue-index (+ (var-get queue-index) u1))
        (ok true)))

(define-public (process-transaction (queue-id uint))
    (let ((tx (unwrap-panic (map-get? transaction-queue queue-id)))
          (relayer tx-sender))
        (asserts! (not (var-get contract-paused)) err-paused)
        (asserts! (is-some (get-relayer-info relayer)) err-invalid-relayer)
        (asserts! (not (get processed tx)) err-invalid-nonce)
        
        ;; Process the transaction
        (map-set transaction-queue
            queue-id
            (merge tx {processed: true}))
        
        ;; Update nonce and relayer stats
        (increment-nonce (get sender tx))
        (update-relayer-stats relayer)
        (ok true)))

;; Initialize contract
(begin
    ;; Register contract owner as first relayer
    (try! (register-relayer))
    ;; Contract successfully initialized
    (ok true))