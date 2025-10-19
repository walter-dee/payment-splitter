;; ------------------------------------------------------------
;; Payment Splitter - Clarity v2
;; ------------------------------------------------------------

;; Define SIP-010 token trait
(define-trait ft-trait
  ((transfer (uint principal principal) (response bool uint))))
;; - Owner sets payees and their shares (sum of shares > 0).
;; - Owner cannot change payees after first deposit (prevents abuse).
;; - Anyone can deposit STX via deposit().
;; - Anyone can deposit SIP-010 token via deposit-token(token, amount).
;; - Payees call release(payee) or release-token(token, payee) to claim owed funds.
;; - Accounting:
;;     owed = floor(totalReceived * shares / totalShares) - alreadyReleased
;; - Safe state updates: update released counters BEFORE doing transfers.
;; ------------------------------------------------------------

;; ---------- Errors ----------
(define-constant ERR-UNAUTHORIZED (err u100))
(define-constant ERR-BAD-ARGS     (err u101))
(define-constant ERR-NOT-FOUND   (err u102))
(define-constant ERR-ALREADY     (err u103))
(define-constant ERR-INSUFFICIENT (err u104))
(define-constant ERR-NO-FUNDS    (err u105))
(define-constant ERR-PAUSED      (err u106))

;; ---------- Config / State ----------
(define-data-var owner principal tx-sender) ;; set at deploy
(define-data-var initialized bool false)    ;; true once at least one payee added
(define-data-var locked bool false)         ;; locked when first deposit happens (no more payee changes)

;; total shares (sum of all payee shares)
(define-data-var total-shares uint u0)

;; payees map -> { shares: uint }
(define-map payees
  { who: principal }
  { shares: uint })

;; ---------- STX accounting ----------
(define-data-var total-received-stx uint u0)
(define-data-var total-released-stx uint u0)
(define-map released-stx
  { who: principal }
  { amount: uint })

;; ---------- Token accounting (per SIP-010 token principal) ----------
;; total received per token: token -> { amount }
(define-map total-received-token
  { token: principal }
  { amount: uint })

;; released per (token, payee)
(define-map released-token
  { token: principal, who: principal }
  { amount: uint })

;; ---------- Helpers ----------
(define-read-only (is-owner (p principal)) (is-eq p (var-get owner)))

;; safe mul/div
(define-read-only (mul-div (x uint) (num uint) (den uint))
  (if (is-eq den u0) u0 (/ (* x num) den)))

;; ---------- Owner functions ----------
;; Add a payee with shares. Only allowed while unlocked (before first deposit).
(define-public (add-payee (who principal) (shares uint))
  (begin
    (asserts! (is-owner tx-sender) ERR-UNAUTHORIZED)
    (asserts! (not (var-get locked)) ERR-ALREADY) ;; lock prevents changes after deposits
    (asserts! (and (> shares u0) (<= shares u340282366920938463463374607431768211455)) ERR-BAD-ARGS)
    (asserts! (is-none (map-get? payees { who: who })) ERR-ALREADY)
    (asserts! (<= (+ (var-get total-shares) shares) u340282366920938463463374607431768211455) ERR-BAD-ARGS)
    (let ((payee-entry { who: who }))
      (map-set payees payee-entry { shares: shares }))
    (var-set total-shares (+ (var-get total-shares) shares))
    (var-set initialized true)
    (ok true)))

;; Remove a payee (only possible before locked)
(define-public (remove-payee (who principal))
  (begin
    (asserts! (is-owner tx-sender) ERR-UNAUTHORIZED)
    (asserts! (not (var-get locked)) ERR-ALREADY)
    (let ((p (unwrap! (map-get? payees { who: who }) ERR-NOT-FOUND)))
      (let ((s (get shares p))
            (payee-entry { who: who }))
        (map-delete payees payee-entry)
        (var-set total-shares (- (var-get total-shares) s))
        (ok true)))))

;; ---------- Deposits ----------
;; Deposit STX into contract for distribution.
(define-public (deposit)
  (let ((amt (stx-get-balance tx-sender)))
    (begin
      (asserts! (> amt u0) ERR-BAD-ARGS)
      ;; lock payee configuration on first deposit
      (if (not (var-get locked)) 
          (var-set locked true)
          true)
      ;; update total received
      (var-set total-received-stx (+ (var-get total-received-stx) amt))
      (ok (var-get total-received-stx)))))

;; Deposit SIP-010 token: pulls tokens from tx-sender into contract and credits that token pool
(define-public (deposit-token (token <ft-trait>) (amount uint))
  (begin
    (asserts! (> amount u0) ERR-BAD-ARGS)
    ;; call token.transfer(amount, tx-sender, as-contract tx-sender)
    (asserts! (is-ok (contract-call? token transfer amount tx-sender (as-contract tx-sender))) ERR-INSUFFICIENT)
    ;; lock payee config
    (if (not (var-get locked))
        (var-set locked true)
        true)
    ;; update total received for this token
    (let ((prev (default-to u0 (get amount (map-get? total-received-token { token: (contract-of token) })))))
      (map-set total-received-token { token: (contract-of token) } { amount: (+ prev amount) })
      (ok (map-get? total-received-token { token: (contract-of token) })))))


;; ---------- Release (STX) ----------
;; payee or anyone can trigger release for a payee
(define-public (release (who principal))
  (begin
    (asserts! (var-get initialized) ERR-BAD-ARGS)
    (let ((p (unwrap! (map-get? payees { who: who }) ERR-NOT-FOUND)))
      (let ((shares (get shares p))
            (total (var-get total-shares)))
        (asserts! (> total u0) ERR-BAD-ARGS)
        (let ((total-recv (var-get total-received-stx))
              (already (default-to u0 (get amount (map-get? released-stx { who: who }))))
              (entitled (mul-div total-recv shares total))
              (payment (if (>= entitled already) (- entitled already) u0)))
          (asserts! (> payment u0) ERR-NO-FUNDS)
          (map-set released-stx { who: who } { amount: (+ already payment) })
          (var-set total-released-stx (+ (var-get total-released-stx) payment))
          (asserts! (is-ok (stx-transfer? payment (as-contract tx-sender) who)) ERR-INSUFFICIENT)
          (ok payment))))))

;; ---------- Release (token) ----------
(define-public (release-token (token <ft-trait>) (who principal))
  (begin
    (asserts! (var-get initialized) ERR-BAD-ARGS)
    (let ((p (unwrap! (map-get? payees { who: who }) ERR-NOT-FOUND)))
      (let ((shares (get shares p))
            (total (var-get total-shares)))
        (asserts! (> total u0) ERR-BAD-ARGS)
        (let ((tr (default-to u0 (get amount (map-get? total-received-token { token: (contract-of token) }))))
              (already (default-to u0 (get amount (map-get? released-token { token: (contract-of token), who: who }))))
              (entitled (mul-div tr shares total))
              (payment (if (>= entitled already) (- entitled already) u0)))
          (asserts! (> payment u0) ERR-NO-FUNDS)
          ;; update BEFORE transfer
          (map-set released-token { token: (contract-of token), who: who } { amount: (+ already payment) })
          ;; execute token transfer from contract to payee
          (asserts! (is-ok (contract-call? token transfer payment (as-contract tx-sender) who)) ERR-INSUFFICIENT)
          (ok payment))))))

;; ---------- Read-only views ----------
(define-read-only (shares-of (who principal))
  (ok (default-to u0 (get shares (map-get? payees { who: who })))))

(define-read-only (get-total-shares) (ok (var-get total-shares)))

(define-read-only (get-total-received-stx) (ok (var-get total-received-stx)))
(define-read-only (get-total-released-stx) (ok (var-get total-released-stx)))
(define-read-only (released-stx-of (who principal)) (ok (default-to u0 (get amount (map-get? released-stx { who: who })))))

(define-read-only (get-total-received-token (token <ft-trait>))
  (ok (default-to u0 (get amount (map-get? total-received-token { token: (contract-of token) })))))

(define-read-only (released-token-of (token <ft-trait>) (who principal))
  (ok (default-to u0 (get amount (map-get? released-token { token: (contract-of token), who: who })))))

;; pending STX for payee
(define-read-only (pending (who principal))
  (let ((p (unwrap! (map-get? payees { who: who }) ERR-NOT-FOUND)))
    (let ((shares (get shares p))
          (total (var-get total-shares))
          (total-rec (var-get total-received-stx))
          (already (default-to u0 (get amount (map-get? released-stx { who: who })))))
      (ok (if (> total u0) 
              (let ((entitled (mul-div total-rec shares total))) 
                (if (>= entitled already) 
                    (- entitled already) 
                    u0)) 
              u0)))))

;; pending token for payee
(define-read-only (pending-token (token <ft-trait>) (who principal))
  (let ((p (unwrap! (map-get? payees { who: who }) ERR-NOT-FOUND)))
    (let ((shares (get shares p))
          (total (var-get total-shares))
          (tr (default-to u0 (get amount (map-get? total-received-token { token: (contract-of token) }))))
          (already (default-to u0 (get amount (map-get? released-token { token: (contract-of token), who: who })))))
      (ok (if (> total u0) 
              (let ((entitled (mul-div tr shares total))) 
                (if (>= entitled already) 
                    (- entitled already) 
                    u0)) 
              u0)))))

;; ---------- Admin convenience: emergency withdraw (owner) ----------
;; In case of emergency the owner can withdraw leftover STX (not recommended)
(define-public (emergency-withdraw-stx (amount uint) (to principal))
  (begin
    (asserts! (is-owner tx-sender) ERR-UNAUTHORIZED)
    (asserts! (>= (stx-get-balance (as-contract tx-sender)) amount) ERR-INSUFFICIENT)
    (asserts! (is-ok (stx-transfer? amount (as-contract tx-sender) to)) ERR-INSUFFICIENT)
    (ok true)))
