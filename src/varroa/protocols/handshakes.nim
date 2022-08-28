import
  stew/[byteutils, endians2, results],
  chronos,
  chronicles,
  libp2p/[protocols/protocol, stream/connection],
  eth/keys,
  ../types,
  protobuf_serialization

logScope:
  topics = "handshakes"

const
  handshakeCodec* = "/swarm/handshake/7.0.0/handshake"

type
  HandshakeHandler* =
    proc(
      peerId: PeerId, adds: BzzAddress, fullNode: bool,
      incoming: bool): Future[void] {.async.}

  HandshakeProto* = ref object of LPProtocol # declare a custom protocol
    overlay*: SwarmAddress
    nonce*: array[32, byte]
    onHandshake*: HandshakeHandler
    ack*: AckMsg

  SynMsg {.proto3.} = object
    observedUnderlay {.fieldNumber: 1.}: seq[byte]

  AckMsg {.proto3.} = object
    address {.fieldNumber: 1.}: BzzAddressMsg
    networkID {.fieldNumber: 2, pint.}: uint64
    fullNode {.fieldNumber: 3.}: bool
    nonce {.fieldNumber: 4.}: seq[byte]
    welcomeMessage {.fieldNumber: 99.}: string

  SynAckMsg {.proto3.} = object
    syn {.fieldNumber: 1.}: SynMsg
    ack {.fieldNumber: 2.}: AckMsg

  BzzAddressMsg {.proto3.} = object
    underlay {.fieldNumber: 1.}: seq[byte]
    signature {.fieldNumber: 2.}: seq[byte]
    overlay {.fieldNumber: 3.}: seq[byte]

proc signatureData(underlay: MultiAddress, overlay: SwarmAddress): seq[byte] =
  "bee-handshake-".toBytes() &
    underlay.data.buffer &
    @(overlay.data) &
    @(toBytesBE(networkID))

proc signEip191(key: keys.PrivateKey, data: openArray[byte]): keys.Signature =
  key.sign(toBytes("\x19Ethereum Signed Message:\n" & $data.len) & @data)

proc makeSyn(conn: Connection): SynMsg =
  SynMsg(
    observedUnderlay: conn.observedAddr.expect("remote address").concat(
      MultiAddress.init("/p2p/" & $conn.peerId).expect("valid")).expect("valid").data.buffer
  )

proc makeAck(
    overlay: SwarmAddress, key: keys.PrivateKey, local: PeerInfo,
    nonce: array[32, byte]): AckMsg =
  let
    underlay = local.listenAddrs[0].concat(
          MultiAddress.init("/p2p/" & $local.peerId).expect("valid")).expect("valid")
    signature = signEip191(key, signatureData(underlay, overlay))

  var
    sigBzz = @(signature.toRaw())
  sigBzz[64] = sigBzz[64] + 27  # ethereum sig encoding

  AckMsg(
    address: BzzAddressMsg(
      underlay: underlay.data.buffer,
      signature: @(sigBzz),
      overlay: @(overlay.data)
    ),
    networkID: networkID,
    fullNode: true,
    nonce: @(nonce),
    welcomeMessage: "hello"
  )

proc toBzzAddress(msg: BzzAddressMsg): Result[BzzAddress, string] =
  let
    overlay = SwarmAddress.init(msg.overlay).valueOr:
      return err("Invalid overlay: " & byteutils.toHex(msg.overlay))
    underlay = MultiAddress.init(msg.underlay).valueOr:
      return err("Invalid underlay: " & $error)

  # TODO Check signature
  ok BzzAddress(overlay: overlay, underlay: underlay)

proc send*(p: HandshakeProto, conn: Connection) {.async.} =
  debug "Sending", conn

  block: # Send syn
    let syn = makeSyn(conn)
    await conn.writeLp(Protobuf.encode(syn))

  let (observed, adds, fullNode) = block: # Read SynAck
    let
      bytes = await conn.readLp(10 * 1024)
      synack = Protobuf.decode(bytes, SynAckMsg)
      observed = MultiAddress.init(synack.syn.observedUnderlay).valueOr:
        debug "Invalid observed underlay"
        return
      adds = synack.ack.address.toBzzAddress().valueOr:
        debug "Invalid address", error
        return
    (observed, adds, synack.ack.fullNode)

  block: # Send ack
    await conn.writeLp(Protobuf.encode(p.ack))
  await conn.closeWithEOF()

  debug "Completed handshake", conn,
    observed,
    adds

  await p.onHandshake(
    conn.peerId, adds, fullNode, false)

proc handle(p: HandshakeProto, conn: Connection, proto: string) {.async.} =
  let observed = block:
    debug "Waiting for syn", conn
    let
      bytes = await conn.readLp(1024)
      syn = Protobuf.decode(bytes, SynMsg)
    MultiAddress.init(syn.observedUnderlay).valueOr:
        debug "Invalid observed underlay"
        return

  let (adds, fullNode) = block:
    let synack = SynAckMsg(
      syn: makeSyn(conn),
      ack: p.ack
    )
    await conn.writeLp(Protobuf.encode(synack))

    let
      ack = block:
        debug "Waiting for ack", conn
        let
          bytes = await conn.readLp(1024)
        Protobuf.decode(bytes, AckMsg)
      adds = ack.address.toBzzAddress().valueOr:
        debug "Invalid address", error
        return

    (adds, ack.fullNode)

  await conn.closeWithEOF()

  debug "Completed handshake", conn,
    observed,
    adds

  await p.onHandshake(conn.peerId, adds, fullNode, true)

proc init*(
    T: typedesc[HandshakeProto], overlay: SwarmAddress, key: keys.PrivateKey,
    local: PeerInfo, nonce: array[32, byte]): T =
  # every incoming connections will be in handled in this closure
  let p = T(
    ack: makeAck(overlay, key, local, nonce),
    codecs: @[handshakeCodec])

  p.handler = proc(conn: Connection, proto: string): Future[void] =
    p.handle(conn, proto)

  p
