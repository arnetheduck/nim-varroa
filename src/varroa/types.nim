import
  std/[sequtils, strutils, times],
  chronicles,
  chronos,
  chronos/timer,
  stew/[byteutils, endians2, objects, results],
  stint,
  libp2p/[multicodec, multiaddress, peerid],
  nimcrypto/keccak

export byteutils, stint, results, timer, peerid

const
  networkID* = 1'u64
  maxPO* = 31

  refreshRate* = i256(4500000)
  lightFactor* = 10
  lightRefreshRate* = refreshRate div i256(lightFactor)
  basePrice = i256(10000)
  minPaymentThreshold* = i256(2) * refreshRate
  paymentThreshold* = i256(13500000)
  maxPaymentThreshold* = i256(24) * refreshRate
  earlyPaymentPercent* = i256(50)

  paymentTolerance* = i256(25)
  disconnectLimit* =
    ((i256(100) + paymentTolerance) * paymentThreshold) div i256(100)

type
  Account* = object

  SwarmAddress* = object
    data*: array[32, byte]

  BzzAddress* = object
    overlay*: SwarmAddress
    underlay*: MultiAddress

  LastPayment* = object
    timestamp*: int64
    checkTimestamp*: int64
    total*: Int256

  Peer* = object
    peerId*: PeerId
    adds*: BzzAddress
    fullNode*: bool

    earlyPayment*: Int256
    reservedBalance*: Int256
    shadowReservedBalance*: Int256
    ghostBalance*: Int256

    refreshOngoing*: bool
    refreshReservedBalance*: Int256

    paymentThreshold*: Int256
    paymentThresholdForPeer*: Int256
    refreshTimestamp*: Time

    # Balances that should be stored in db
    balance*: Int256
    surplusBalance*: Int256
    originatedBalance*: Int256

    settlementReceived*: Int256

    pseudoSettle*: LastPayment

    refreshReceivedTimestamp*: int64

  BucketTable* = object
    base*: SwarmAddress
    buckets*: array[maxPO+1, seq[ref Peer]]

  PeerEntry* = object
    ma*: MultiAddress
    nextAttempt*: Moment

  PeerStore* = object
    known*: BucketTable
    connected*: BucketTable

    addresses*: seq[PeerEntry]

  Chunk* = object
    data*: seq[byte]
    stamp*: seq[byte]

  SendChunk* = proc(chunk: Chunk): Future[void] {.async.}
  LookupAndSendChunk* = proc(
    peer: ref Peer, refs: SwarmAddress, sendChunk: SendChunk): Future[void] {.async.}

  LookupPeer* = proc(peerId: PeerId): ref Peer {.gcsafe, raises: [].}

proc getIncreasedExpectedDebt(peer: Peer, price: Int256): (Int256, Int256) =
  let
    nextReserved = peer.reservedBalance + price
    currentBalance = peer.balance
    currentDebt = max(i256"0", -currentBalance)
    expectedDebt = currentDebt + nextReserved
    additionalDebt = peer.surplusBalance

  (expectedDebt + additionalDebt, currentBalance)

proc prepareCredit*(peer: var Peer, price: Int256): bool =
  let
    threshold = peer.earlyPayment
    (increasedExpectedDebt, currentBalance) = getIncreasedExpectedDebt(peer, price)
    increasedExpectedDebtReduced = increasedExpectedDebt - peer.shadowReservedBalance

  if increasedExpectedDebtReduced >= threshold and currentBalance < i256(0):
    warn "Need to settle",
      increasedExpectedDebtReduced, threshold, currentBalance

  let
    timeElapsed = min(initDuration(seconds = 1), getTime() - peer.refreshTimestamp)
    refreshDue = i256(timeElapsed.inSeconds) * refreshRate
    overdraftLimit = peer.paymentThreshold + refreshDue

  if increasedExpectedDebt > overdraftLimit:
    notice "Overdraft", peer, increasedExpectedDebt, overdraftLimit
    return false

  peer.reservedBalance += peer.reservedBalance + price

  info "Prepared credit", peer, reservedBalance = peer.reservedBalance, price

  true

proc closeReservedCredit*(peer: var Peer, price: Int256, originated: bool, apply: bool) =
  if not apply:
    if price > peer.reservedBalance:
      warn "not enough reserved balance to go around",
        peer, reservedBalance = peer.reservedBalance, price
      peer.reservedBalance = i256(0)
    else:
      peer.reservedBalance = peer.reservedBalance - price

    info "Closed credit without applying",
      peer, reservedBalance = peer.reservedBalance, price

    return

  var
    (increasedExpectedDebt, currentBalance) = peer.getIncreasedExpectedDebt(price)
    nextBalance = currentBalance - price

  peer.balance = nextBalance

  if price > peer.reservedBalance:
    warn "not enough reserved balance to go around",
      peer, reservedBalance = peer.reservedBalance, price
    peer.reservedBalance = i256(0)
  else:
    peer.reservedBalance = peer.reservedBalance - price

  if not originated:
    let increasedExpectedDebtReduced =
      increasedExpectedDebt - peer.shadowReservedBalance
    if increasedExpectedDebtReduced > peer.earlyPayment:
      warn "TODO: settle", peer, increasedExpectedDebtReduced

    return

  var
    originBalance = peer.originatedBalance
    nextOriginBalance = originBalance - price

  if nextBalance > i256(0):
    nextBalance = i256(0)

  if nextOriginBalance < nextBalance:
    nextOriginBalance = nextBalance

  peer.originatedBalance = nextOriginBalance

  let increasedExpectedDebtReduced = increasedExpectedDebt - peer.shadowReservedBalance
  if increasedExpectedDebtReduced > peer.earlyPayment:
    warn "TODO: settle", peer, increasedExpectedDebtReduced

  info "Closed credit",
    peer, reservedBalance = peer.reservedBalance, price

proc prepareDebit*(peer: var Peer, price: Int256): bool =
  peer.shadowReservedBalance = peer.shadowReservedBalance + price

  if peer.refreshOngoing:
    peer.refreshReservedBalance = peer.refreshReservedBalance + price

  info "Prepared debit",
    peer, shadowReservedBalance = peer.shadowReservedBalance, price

  true

proc increaseBalance(peer: var Peer, price: Int256): Int256 =
  let
    surplusBalance = peer.surplusBalance

  if surplusBalance >= price:
    let
      newSurplusBalance = surplusBalance - price
    peer.surplusBalance = newSurplusBalance
    return peer.balance

  let
    debitIncrease = price - surplusBalance

  peer.surplusBalance = i256(0)

  let
    currentBalance = peer.balance
    nextBalance = currentBalance - debitIncrease

  peer.balance = nextBalance

  # TODO decreaseOriginatedBalance

  nextBalance

proc closeReservedDebit*(peer: var Peer, price: Int256, apply: bool) =
  if not apply:
    peer.shadowReservedBalance = peer.shadowReservedBalance - price
    peer.ghostBalance = peer.ghostBalance + price

    if peer.ghostBalance > disconnectLimit:
      warn "Ghost overdraw",
        peer, ghostBalance = peer.ghostBalance, limit = disconnectLimit
      discard # TODO

    info "Closed debit without applying",
      peer, shadowReservedBalance = peer.shadowReservedBalance, price

    return

  let
    nextBalance = peer.increaseBalance(price)

  peer.shadowReservedBalance = peer.shadowReservedBalance - price

  let
    timeElapsed = min(1'i64, getTime().toUnix() - peer.refreshReceivedTimestamp)
    refreshRate = if peer.fullNode: refreshRate else: lightRefreshRate
    refreshDue = i256(timeElapsed) * refreshRate
    disconnectLimit = disconnectLimit + refreshDue

  if nextBalance >= disconnectLimit:
    warn "TODO: Overdraw", peer, nextBalance, disconnectLimit

  info "Closed debit",
    peer, shadowReservedBalance = peer.shadowReservedBalance, price

const
  dataDir* = "/data/varroa/"

func toPeerId*(ma: MultiAddress): Opt[PeerId] =
  let ma = ma[multiCodec("p2p")].valueOr:
    return Opt.none(PeerId)

  var p2p = ma.toString().valueOr("")
  p2p.removePrefix("/p2p/")

  let pid = PeerId.init(p2p).valueOr:
    return Opt.none(PeerId)
  ok pid

func init*(T: type SwarmAddress, ethAddr: array[20, byte], networkID: uint64, nonce: array[32, byte]): SwarmAddress =
  SwarmAddress(data: keccak256.digest(
    @ethAddr & @(networkID.toBytesLE()) & @nonce).data)

func init*(T: type SwarmAddress, data: openArray[byte]): Opt[SwarmAddress] =
  if data.len >= 32:
    ok SwarmAddress(data: toArray(32, data))
  else:
    err()

func fromHex*(T: type SwarmAddress, data: string): T =
  T(data: hexToByteArray(data, 32))

func `$`*(v: SwarmAddress): string =
  byteutils.toHex(v.data)

func chunkDir*(dataDir: string): string = dataDir & "chunks/"

func stampDir*(dataDir: string): string = dataDir & "stamps/"

func distance*(a, b: SwarmAddress): UInt256 =
  var data: array[32, byte]
  for i in 0..<32:
    data[i] = a.data[i] xor b.data[i]
  UInt256.fromBytesBE(data)

func distanceCmp*(x, a, b: SwarmAddress): int =
  for i in 0..<x.data.len:
    let
      ax = x.data[i] xor a.data[i]
      bx = x.data[i] xor b.data[i]
    if ax < bx:
      return 1
    elif ax > bx:
      return -1

  0

func closer*(x, a, b: SwarmAddress): bool =
  distanceCmp(a, x, b) > 0

func proximity*(one, other: openArray[byte]): int =
  let b = min(min(maxPO div 8 + 1, len(one)), len(other))

  for i in 0..<b:
    let oxo = one[i] xor other[i]

    for j in 0..<8:
      if ((oxo shr (7-j)) and 1) != 0:
        return i*8 + j
  return maxPO

proc peerPrice*(peer, chunk: SwarmAddress): Int256 =
  i256(maxPO - proximity(peer.data, chunk.data)) * basePrice

func new*(T: type PeerStore, base: SwarmAddress): ref PeerStore =
  (ref T)(connected: BucketTable(base: base))

func new*(T: type Peer, adds: BzzAddress, fullNode: bool): ref Peer =
  let
    peerId = adds.underlay.toPeerId().expect("valid peerid")
  (ref Peer)(
    adds: adds,
    peerId: peerId,
    fullNode: fullNode,
    paymentThreshold: paymentThreshold,
    paymentThresholdForPeer: paymentThreshold,
  )

func add*(v: var BucketTable, peer: ref Peer) =
  let po = proximity(v.base.data, peer.adds.overlay.data)
  for p in v.buckets[po]:
    if p == peer:
      return

  v.buckets[po].add(peer)

func remove*(v: var BucketTable, peerId: PeerId): bool =
  for b in v.buckets.mitems():
    for i in 0 ..< b.len:
      if b[i].peerId == peerId:
        # TODO what if they're in multiple buckets
        b.delete(i)
        return true
  false

func addPeerEntry*(v: var seq[PeerEntry], ma: MultiAddress) =
  v.add(PeerEntry(ma: ma))

iterator items*(v: BucketTable): ref Peer =
  for i in 0..<v.buckets.len:
    for j in 0..<v.buckets[v.buckets.high - i].len:
      yield v.buckets[v.buckets.high - i][j]

iterator itemsRev*(v: BucketTable): ref Peer =
  for i in 0..<v.buckets.len:
    for j in 0..<v.buckets[i].len:
      yield v.buckets[v.buckets.high - i][j]

func `$`*(v: BzzAddress): string =
  $v.overlay & ":" & $v.underlay

func closest*(v: BucketTable, adds: SwarmAddress, skips: openArray[SwarmAddress]): ref Peer =
  var cur: ref Peer
  for i in 0..<v.buckets.len:
    for j in 0..<v.buckets[i].len:
      let candidate = v.buckets[i][j]
      if anyIt(skips, it == candidate[].adds.overlay): continue
      if cur == nil:
        cur = candidate
      else:
        if candidate[].adds.overlay.closer(adds, cur[].adds.overlay):
          cur = candidate
  cur

func lookupPeer*(store: PeerStore, peerId: PeerId): ref Peer =
  for bucket in store.known.buckets:
    for peer in bucket:
      if peer.peerId == peerId:
        return peer
  nil

func debt*(peer: Peer): Int256 =
  max(i256(0), peer.balance + peer.shadowReservedBalance)

chronicles.formatIt(Peer): $it.peerId
chronicles.formatIt(ref Peer):
  if it != nil: $it.peerId
  else: "Peer(nil)"

when isMainModule:
  import unittest2
  test "a":
    var x: SwarmAddress
    x.data[31] = 1

    check:
      distance(
        SwarmAddress.fromHex("9100000000000000000000000000000000000000000000000000000000000000"),
        SwarmAddress.fromHex("8200000000000000000000000000000000000000000000000000000000000000")) ==
          u256"8593944123082061379093159043613555660984881674403010612303492563087302590464"
      distanceCmp(
        SwarmAddress.fromHex("9100000000000000000000000000000000000000000000000000000000000000"),
        SwarmAddress.fromHex("8200000000000000000000000000000000000000000000000000000000000000"),
        SwarmAddress.fromHex("1200000000000000000000000000000000000000000000000000000000000000")) == 1
