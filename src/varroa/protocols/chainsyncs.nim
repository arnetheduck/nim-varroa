import
  std/[strformat, times, typetraits],
  stew/[byteutils, leb128],
  chronicles,
  chronos,
  eth/common/eth_types_rlp as eth,
  stint, json_rpc/clients/httpclient,
  libp2p/[protocols/protocol, stream/connection],
  ./headers,
  protobuf_serialization,
  web3

logScope:
  topics = "chainsyncs"

type Hash256 = eth.Hash256

const
  chainSyncCodec* = "/swarm/chainsync/1.0.0/prove"

type
  ChainSyncProto* = ref object of LPProtocol # declare a custom protocol
    web3: string
    cache: seq[(uint64, seq[byte])]

  DescribeMsg {.proto3.} = object
    blockHeight {.fieldNumber: 1.}: seq[byte]

  ProofMsg {.proto3.} = object
    blockHash {.fieldNumber: 1.}: seq[byte]

proc send*(p: ChainSyncProto, conn: Connection) {.async.} =
  logScope: conn
  debug "Sending"
  block: # Headers
    let headers = await conn.exchangeHeaders(true)
    if headers.len > 0:
      debug "Headers", headers

  await conn.closeWithEOF()

proc handle(p: ChainSyncProto, conn: Connection, proto: string) {.async.} =
  logScope: conn
  trace "Handling", proto
  try:
    block: # Headers
      let headers = await conn.exchangeHeaders(false)
      if headers.len > 0:
        debug "Headers", headers

    let
      height = block:
        let
          bytes = await conn.readLp(16*1024)
          msg = Protobuf.decode(bytes, DescribeMsg)
        uint64.fromBytes(msg.blockHeight, Leb128)[0]

      hash = block:
        var ret: Opt[seq[byte]]
        for a, b in p.cache.items():
          if a == height:
            ret = Opt.some b
            break
        if ret.isNone:
          let
            web3 = block:
              let rpc = newRpcHttpClient()
              await rpc.connect(p.web3)
              rpc
            bc =
              try: await web3.eth_getBlockByNumber(&"0x{height:X}", false)
              finally: asyncSpawn web3.close()

            h = eth.BlockHeader(
              blockNumber: u256(distinctBase(bc.number)),
              parentHash : Hash256(data: distinctBase(bc.parentHash)),
              # nonce      : toBlockNonce(bc.nonce),
              ommersHash : Hash256(data: distinctBase(bc.sha3Uncles)),
              bloom      : BloomFilter bc.logsBloom,
              txRoot     : Hash256(data: distinctBase(bc.transactionsRoot)),
              stateRoot  : Hash256(data: distinctBase(bc.stateRoot)),
              receiptRoot: Hash256(data: distinctBase(bc.receiptsRoot)),
              coinbase   : distinctBase(bc.miner),
              difficulty : u256(distinctBase(bc.difficulty)),
              extraData  : seq[byte](bc.extraData),
              mixDigest  : Hash256(data: distinctBase(bc.mixHash)),
              gasLimit   : int64(bc.gasLimit), # TODO int64
              gasUsed    : int64(bc.gasUsed), # TODO int64
              timestamp  : initTime(int64(bc.timestamp), 0),
              fee: if bc.baseFeePerGas.isSome(): some bc.baseFeePerGas.get else: none UInt256
            )
          ret = Opt.some @(h.blockHash().data)
          while p.cache.len() > 9:
            p.cache.delete(0)
          p.cache.add((height, ret.get()))
        ret.get()

    debug "Sending proof", conn, height, hash = byteutils.toHex(hash)
    await conn.writeLp(Protobuf.encode(ProofMsg(blockHash: hash)))

    await conn.closeWithEOF()
  except CatchableError as exc:
    error "Could not send proof", msg = exc.msg

proc new*(T: typedesc[ChainSyncProto], web3: string): T =
  # every incoming connections will be in handled in this closure
  let p = T(
    web3: web3,
    codecs: @[chainSyncCodec])

  p.handler = proc(conn: Connection, proto: string): Future[void] =
    p.handle(conn, proto)

  p
