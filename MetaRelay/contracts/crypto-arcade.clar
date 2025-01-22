;; CryptoArcade Game Contract
;; Implements gasless gaming mechanics using meta-transaction relay

;; Constants
(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u100))
(define-constant err-insufficient-balance (err u101))
(define-constant err-game-not-found (err u102))
(define-constant err-invalid-bet (err u103))
(define-constant err-game-in-progress (err u104))
(define-constant err-not-player (err u105))

;; Data Variables
(define-data-var game-nonce uint u0)
(define-data-var min-bet uint u100)     ;; in micro-STX
(define-data-var max-bet uint u1000000) ;; in micro-STX

;; Data Maps
(define-map PlayerStats
    principal
    {
        total-games: uint,
        wins: uint,
        losses: uint,
        total-wagered: uint,
        last-played: uint,
        high-score: uint
    }
)

(define-map ActiveGames
    uint  ;; game-id
    {
        player: principal,
        bet-amount: uint,
        game-type: (string-ascii 20),
        start-time: uint,
        status: (string-ascii 10),
        score: uint,
        seed: (buff 32),
        relay-tx: uint  ;; reference to relay transaction
    }
)

(define-map GameTypes
    (string-ascii 20)
    {
        min-bet: uint,
        max-bet: uint,
        active: bool,
        multiplier: uint
    }
)

;; Read-only functions
(define-read-only (get-player-stats (player principal))
    (default-to 
        {
            total-games: u0,
            wins: u0,
            losses: u0,
            total-wagered: u0,
            last-played: u0,
            high-score: u0
        }
        (map-get? PlayerStats player)
    )
)

(define-read-only (get-game-details (game-id uint))
    (map-get? ActiveGames game-id)
)

(define-read-only (get-game-type-info (game-type (string-ascii 20)))
    (map-get? GameTypes game-type)
)

;; Private functions
(define-private (update-player-stats 
    (player principal) 
    (won bool) 
    (bet-amount uint)
    (score uint))
    (let (
        (current-stats (get-player-stats player))
        (current-high-score (get high-score current-stats)))
        (map-set PlayerStats
            player
            {
                total-games: (+ (get total-games current-stats) u1),
                wins: (+ (get wins current-stats) (if won u1 u0)),
                losses: (+ (get losses current-stats) (if won u0 u1)),
                total-wagered: (+ (get total-wagered current-stats) bet-amount),
                last-played: block-height,
                high-score: (if (> score current-high-score) 
                              score 
                              current-high-score)
            }
        )
    )
)

;; Public functions

;; Game Management
(define-public (register-game-type
    (game-type (string-ascii 20))
    (min-bet-amount uint)
    (max-bet-amount uint)
    (multiplier uint))
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (ok (map-set GameTypes
            game-type
            {
                min-bet: min-bet-amount,
                max-bet: max-bet-amount,
                active: true,
                multiplier: multiplier
            }
        ))
    )
)

;; Game Actions
(define-public (start-game 
    (game-type (string-ascii 20)) 
    (bet-amount uint)
    (relay-tx uint))
    (let (
        (game-id (var-get game-nonce))
        (game-config (unwrap! (get-game-type-info game-type) err-game-not-found))
        (seed (unwrap-panic (get-block-info? id-header-hash (- block-height u1))))
    )
        ;; Validate bet amount
        (asserts! (and 
            (>= bet-amount (get min-bet game-config))
            (<= bet-amount (get max-bet game-config))) 
            err-invalid-bet)
        
        ;; Create new game
        (var-set game-nonce (+ game-id u1))
        (ok (map-set ActiveGames
            game-id
            {
                player: tx-sender,
                bet-amount: bet-amount,
                game-type: game-type,
                start-time: block-height,
                status: "active",
                score: u0,
                seed: seed,
                relay-tx: relay-tx
            }
        ))
    )
)

(define-public (end-game
    (game-id uint)
    (final-score uint))
    (let (
        (game (unwrap! (get-game-details game-id) err-game-not-found))
        (player (get player game))
        (game-type-info (unwrap! (get-game-type-info (get game-type game)) err-game-not-found))
        (winning-threshold (* (get bet-amount game) (get multiplier game-type-info))))
        
        ;; Verify player
        (asserts! (is-eq tx-sender player) err-not-player)
        ;; Verify game status
        (asserts! (is-eq (get status game) "active") err-game-in-progress)
        
        ;; Update game status
        (map-set ActiveGames
            game-id
            (merge game {
                status: "completed",
                score: final-score
            })
        )
        
        ;; Update player stats
        (update-player-stats 
            player 
            (>= final-score winning-threshold)
            (get bet-amount game)
            final-score)
        
        (ok true)
    )
)

;; Initialize contract
(begin
    ;; Register initial game types
    (try! (register-game-type "arcade" u100 u1000000 u2))
    (try! (register-game-type "puzzle" u100 u500000 u3))
    (ok true)
)