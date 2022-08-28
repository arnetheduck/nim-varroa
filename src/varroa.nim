import
  std/[sequtils, os],
  chronos,
  chronicles,
  presto,
  libp2p,
  libp2p/crypto/secp,
  libp2p/protocols/ping,
  stew/[byteutils, endians2],
  eth/keys,
  eth/common/eth_types,
  nimcrypto/keccak,
  ./varroa/protocols/[
    chainsyncs, handshakes, hives, pingpongs, pseudosettles, pricings,
    pullsyncs, pushsyncs, retrievals, swaps],
  ./varroa/[chunkedfile, chunkstore, manifest, types]

proc decodeString*(t: typedesc[SwarmAddress],
                   value: string): RestResult[SwarmAddress] =
  try:
    ok SwarmAddress.fromHex(value)
  except CatchableError:
    err("cannot decode address")

proc main(dataDir: string) {.async.} =
  let
    rng = keys.newRng()
    keyfile = dataDir & "swarm.key"
    key = if fileExists(keyfile):
      keys.PrivateKey.fromRaw(readFile(keyfile).toBytes()).get().toKeyPair()
    else:
      let kp = keys.KeyPair.random(rng[])
      writeFile(keyfile, string.fromBytes(kp.seckey.toRaw()))
      kp
    switch = newStandardSwitch(
      addrs = MultiAddress.init("/ip4/192.168.1.6/tcp/9999").get(),
      privKey = some libp2p.PrivateKey.init(SkPrivateKey(key.seckey())),
      rng=rng)
    address = key.pubkey.toCanonicalAddress()
    nonce = default(array[32, byte])
    overlay = SwarmAddress.init(address, networkID, nonce)
    peerStore = types.PeerStore.new(overlay)
    lookupPeer = proc(peerId: PeerId): ref Peer = peerStore[].lookupPeer(peerId)
    chunkStore = ChunkStore.new(dataDir)
    handshake = HandshakeProto.init(
      overlay, key.seckey, switch.peerInfo, nonce)
    ping = Ping.new(rng=rng)
    pingpong = PingpongProto.new()
    pricing = PricingProto.new(lookupPeer)
    hive = HiveProto.new(overlay)
    pseudoSettle = PseudoSettleProto.new(lookupPeer)
    swap = SwapProto.new()
    retrieval = RetrievalProto.new(lookupPeer)
    pushSync = PushSyncProto.new()
    pullSync = PullSyncProto.new()
    chainSync = ChainSyncProto.new("http://192.168.1.21:8545")
    restServer = RestServerRef.new(
      RestRouter.init(proc(a, b: string): int = 0),
      initTAddress("0.0.0.0", Port(1633))).expect("working rest server")

  switch.mount(ping)
  switch.mount(handshake)
  switch.mount(pingpong)
  switch.mount(hive)
  switch.mount(pricing)
  switch.mount(pseudoSettle)
  switch.mount(swap)
  switch.mount(retrieval)
  # switch.mount(pushSync)
  # switch.mount(pullSync)
  switch.mount(chainSync)

  proc onConnection(peerId: PeerId, event: ConnEvent) {.async.} =
    debug "Connecting", peerId, event
    if not event.incoming:
      block:
        let conn = await switch.dial(peerId, handshakeCodec)
        await handshake.send(conn)

  switch.addConnEventHandler(onConnection, ConnEventKind.Connected)

  proc onLeft(peerId: PeerId, event: PeerEvent) {.async.} =
    if peerStore[].connected.remove(peerId):
      debug "Disconnected", peerId, event
    else:
      debug "Left", peerId, event

  switch.addConnEventHandler(onConnection, ConnEventKind.Connected)

  switch.addPeerEventHandler(onLeft, PeerEventKind.Left)

  handshake[].onHandshake = proc(
      peerId: PeerId, adds: BzzAddress, fullNode: bool,
      incoming: bool) {.async.} =
    var peer = lookupPeer(peerId)
    if peer == nil:
      info "Previously unknown peer connected", peerId, adds, fullNode
      peer = Peer.new(adds, fullNode)
      peerStore[].known.add(peer)
    else:
      info "Peer connected", peer, adds, fullNode
      peer.fullNode = fullNode

    peerStore[].connected.add(peer)

    block:
      let conn = await switch.dial(peerId, pricingCodec)
      await pricing.send(conn, paymentThreshold)

  hive[].onPeer = proc(adds: BzzAddress) =
    let peerId = adds.underlay.toPeerId().valueOr:
      debug "Cannot extract peer id", adds
      return
    # TODO full node?
    if lookupPeer(peerId) == nil:
      info "Peer discovered", peerId, adds
      peerStore[].known.add(Peer.new(adds, false))

    # peerStore[].addresses.add(PeerEntry(peerId: peerId))

  for entry in [
    "/ip4/192.168.1.21/tcp/10634/p2p/16Uiu2HAmTaEoEpEFkrCKfU5srxYrgkgBz4e2LJDhdod4VwgH2DkC",
    "/ip4/192.168.1.21/tcp/38371/p2p/16Uiu2HAm4UQx1bkUY93sGKTVAdcEfnbLEdjbig6rDibSiQMibM6a",
    "/ip4/192.168.1.21/tcp/38372/p2p/16Uiu2HAmMgxhWWowfFK5NTqQmwnARo2wYDWo1AK2AZJ3fb2N5RMH",
    # "/ip4/192.168.1.21/tcp/38373/p2p/16Uiu2HAm6ekwaoY8UrpqHU9ZPTwAan4BFVZjhhAfWWDQmhz55pYm",
    # "/ip4/192.168.1.21/tcp/38374/p2p/16Uiu2HAm2ZjWG4NgKC1aLHCdHDQwNtcuYtGwADfg5AvRWt5zwWwM",
    # "/ip4/192.168.1.21/tcp/38375/p2p/16Uiu2HAm7neBk92RivkLr1tXY3WQeKTWaEyx5eCpxotCy3VibT4R",
    # "/ip4/192.168.1.21/tcp/38376/p2p/16Uiu2HAmJvpRgDPkpC2ucTDLJ3FGapiitJ8rvoGroWrLZfMgrgVC",
    # "/ip4/192.168.1.21/tcp/38377/p2p/16Uiu2HAm4C2bL1c9R11Xhfvu3bWw3GDfPzxEKGWwsBAr7iYTJkG5",
    # "/ip4/192.168.1.21/tcp/38378/p2p/16Uiu2HAmPrY9cPgeLG5shv95FYvXuDpkeiq39cmrDUnZGJ33WEoR",
    # "/ip4/192.168.1.21/tcp/38379/p2p/16Uiu2HAmQg8oLNeZi5auqX77RSF6Z28Ljjz4UbGnBotZmrFK5smE",
  ]:
    peerStore[].addresses.addPeerEntry(MultiAddress.init(entry).get())

  await switch.start()

  let local = switch.peerInfo
  notice "Listening",
    overlay, peerId = local.peerId, addrs = local.addrs,
    protocols = local.protocols, protoVersion = local.protoVersion,
    agentVersion = local.agentVersion

  proc loadChunk(refs, origin: SwarmAddress): Future[Chunk] {.async.} =
    debug "Loading chunk", refs

    return chunkStore[].load(refs).valueOr:
      var
        tested = @[origin]

      while true:
        let
          candidate = peerStore[].connected.closest(refs, tested)
        if candidate == nil:
          debug "No candidate peer for chunk", refs
          break
        if overlay.closer(refs, candidate[].adds.overlay) and origin != overlay:
          debug "No closer peer"
          break

        tested.add candidate[].adds.overlay

        let price = peerPrice(candidate[].adds.overlay, refs)

        debug "Asking peer", refs, overlay = candidate[].adds.overlay

        if not candidate[].prepareCredit(price):
          continue

        var apply = false
        try:
          let
            conn = await switch.dial(candidate[].peerId, retrievalCodec)
            chunk =
              try:
                await retrieval.send(conn, refs)
              except CatchableError as exc:
                debug "Chunk download failed",
                  error = exc.msg
                await conn.closeWithEOF()
                continue
          apply = true
          await conn.closeWithEOF()

          chunkStore[].store(refs, chunk.data, chunk.stamp)

          return chunk
        finally:
          candidate[].closeReservedCredit(price, origin == overlay, apply)

      raise (ref ValueError)(msg: "Chunk not found")

  retrieval.lookupAndSendChunk =
    proc(peer: ref Peer, refs: SwarmAddress, sendChunk: SendChunk): Future[void] {.async.} =
      let
        price = peerPrice(peer[].adds.overlay, refs)
        chunk = await loadChunk(refs, peer[].adds.overlay)

      if not peer[].prepareDebit(price):
        return

      var apply = false
      try:
        await sendChunk(chunk)
        apply = true
      finally:
        peer[].closeReservedDebit(price, apply)

  proc loadBzz(refs: SwarmAddress, path: string): Future[(seq[byte], Table[string, string])] {.async.} =
    let
      root = NodeRef(refs: refs)

    for prefix, node in root.walk():
      if not node.loaded:
        let chunk = await loadChunk(node.refs, overlay)
        if (let v = readMantaray(node, chunk.data); v.isErr):
          debug "Couldn't load mantaray", error = v.error()
          raise (ref ValueError)(msg: $v.error())

      debug "Loaded manifest entry", prefix, refs = $node.refs

    let index = root.lookupMetadata(rootPath, WebsiteIndexDocumentSuffixKey)
    if index.len > 0:
      debug "Looking up index", index
      let indexNode = root.lookupEntry(index)
      if indexNode != nil:
        debug "Found index entry", entry = $indexNode.entry

        let
          file = ChunkedFileRef.init(indexNode.entry)

        block:
          let
            chunk = await loadChunk(indexNode.entry, overlay)
          file.load(chunk.data)

        for node in file.walkChunkFiles():
          if not node.loaded:
            let chunk = await loadChunk(node.refs, overlay)
            node.load(chunk.data)

        let roots = toSeq(file.walkDataRoots())
        for root in roots:
          let tmp = await loadChunk(root, overlay)
          result[0].add(tmp.data.toOpenArray(8, tmp.data.high))
        result[1] = indexNode.metadata

  restServer[].router.api(MethodGet, "/chunks/{chunk_id}") do (chunk_id: SwarmAddress) -> RestApiResponse:
    let refs = chunk_id.valueOr:
      return RestApiResponse.response($error, Http400)

    let chunk = try:
      await loadChunk(refs, overlay)
    except CatchableError as exc:
      return RestApiResponse.response(exc.msg, Http400)

    return RestApiResponse.response(chunk.data, Http200)

  restServer[].router.api(MethodGet, "/bzz/{refs}") do (refs: SwarmAddress) -> RestApiResponse:
    let refs = refs.valueOr:
      return RestApiResponse.response($error, Http400)

    # TODO stream response
    let data = try:
      await loadBzz(refs, "")
    except CatchableError as exc:
      return RestApiResponse.response(exc.msg, Http400)

    var contentType = "application/octet-stream"
    let headers = block:
      var tmp: seq[RestKeyValueTuple]
      for k, v in data[1]:
        if k == EntryMetadataFilenameKey:
          tmp.add(("Content-Disposition", "inline; filename=\"" & extractFilename(v) & "\""))
        elif k == EntryMetadataContentTypeKey:
          contentType = v
      tmp
    return RestApiResponse.response(data[0], Http200, contentType, headers = headers)

  proc connector() {.async.} =
    var i: int
    while true:
      let now = Moment.now()

      var j: int
      while j < peerStore[].addresses.len:
        let idx = (i + j) mod peerStore[].addresses.len
        let peerId = peerStore[].addresses[idx].ma.toPeerId().valueOr:
          debug "Unsupported multiaddr", adds = peerStore[].addresses[idx].ma
          peerStore[].addresses.delete(idx)
          continue
        var mas = peerStore[].addresses[idx].ma.toString().get()
        mas.delete(mas.find("/p2p/")..mas.high)
        for k in peerStore[].connected:
          var found: bool
          if k.peerId == peerId:
            found = true
            break
          if found: continue

        if now < peerStore[].addresses[idx].nextAttempt:
          j += 1
          continue

        peerStore[].addresses[idx].nextAttempt = now + 1.minutes

        try:
          await switch.connect(peerId, @[MultiAddress.init(mas).get()])
        except CatchableError as exc:
          debug "Failed to connect",
            peerId, ma = peerStore[].addresses[idx].ma, error = exc.msg

        j += 1

      await sleepAsync(1.seconds)

  restServer.start()

  asyncSpawn connector()

  await waitSignal(SIGINT)

  notice "Stopped"

let
  dataDir = if paramCount() > 0: paramStr(1) else: "/data/varroa/"

waitFor main(dataDir)
