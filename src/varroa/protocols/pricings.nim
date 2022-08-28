import
  stew/[byteutils, endians2],
  chronicles,
  chronos,
  libp2p/[protocols/protocol, stream/connection],
  stint,
  protobuf_serialization,
  ./headers,
  ../types

logScope:
  topics = "pricings"

const
  pricingCodec* = "/swarm/pricing/1.0.0/pricing"

type
  PricingProto* = ref object of LPProtocol # declare a custom protocol

  AnnouncePaymentThresholdMsg* {.proto3.} = object
    paymentThreshold* {.fieldNumber: 1.}: seq[byte]

proc send*(p: PricingProto, conn: Connection, paymentThreshold: Int256) {.async.} =
  debug "Sending", conn, paymentThreshold

  block: # Headers
    let headers = await conn.exchangeHeaders(true)
    if headers.len > 0:
      debug "Headers", conn, headers

  block: # Send announce

    await conn.writeLp(Protobuf.encode(
      AnnouncePaymentThresholdMsg(
        paymentThreshold: @(stuint(paymentThreshold, 256).toBytesBE())
      )
    ))

  await conn.closeWithEOF()

proc handle(p: PricingProto, conn: Connection, proto: string, peer: ref Peer) {.async.} =
  logScope: conn
  trace "Handling", proto
  block: # Headers
    let headers = await conn.exchangeHeaders(false)
    if headers.len > 0:
      debug "Headers", headers

  let threshold = block:
    let
      bytes = await conn.readLp(1024)
      msg = Protobuf.decode(bytes, AnnouncePaymentThresholdMsg)

    stint(UInt256.fromBytesBE(msg.paymentThreshold), 256)

  await conn.closeWithEOF()

  if threshold < minPaymentThreshold:
    notice "Payment threshold too small", peer, threshold
  elif threshold > maxPaymentThreshold:
    # overflow protection..
    notice "Payment threshold too big", peer, threshold
  else:
    info "Peer payment threshold", peer, threshold

    peer.paymentThreshold = threshold
    peer.earlyPayment = (threshold * (i256(100) - earlyPaymentPercent)) div i256(100)

proc new*(T: typedesc[PricingProto], lookupPeer: LookupPeer): T =
  let p = T(codecs: @[pricingCodec])

  p.handler = proc(conn: Connection, proto: string): Future[void] =
    let peer = lookupPeer(conn.peerId)
    if peer == nil:
      debug "Unkown peer", peerId = conn.peerId
      return

    p.handle(conn, proto, peer)

  p
