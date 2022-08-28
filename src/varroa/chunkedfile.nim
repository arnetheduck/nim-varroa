import
  stew/[byteutils, endians2],
  ./types

type
  ChunkedFileRef* = ref object
    refs*: SwarmAddress
    span*: int64
    roots*: seq[SwarmAddress]
    children*: seq[ChunkedFileRef]
    data*: seq[byte]

func init*(T: type ChunkedFileRef, refs: SwarmAddress): T =
  ChunkedFileRef(refs: refs)

template loaded*(v: ChunkedFileRef): bool =
  v[].children.len > 0 or v[].roots.len > 0 or v.data.len > 0

func load*(v: ChunkedFileRef, data: seq[byte]) =
  v.span = int64(uint64.fromBytesLE(data)) # TODO int
  let
    dlen = data.len - 8
  if v.span > dlen:
    let
      refLen = v.refs.data.len
      totalChunks = (v.span + 4096 - 1) div 4096
      chunks = dlen div refLen
    if chunks > totalChunks:
      for i in 0..<chunks:
        v.children.add(
          ChunkedFileRef.init(SwarmAddress.init(
            data.toOpenArray(8 + i * refLen, 8 + (i+1) * refLen - 1)).expect("ok")))
    else:
      for i in 0..<chunks:
        v.roots.add(SwarmAddress.init(
          data.toOpenArray(8 + i * refLen, 8 + (i+1) * refLen - 1)).expect("ok"))
  else:
    v.data = data[8..data.high]

iterator walkChunkFiles*(v: ChunkedFileRef): ChunkedFileRef =
  var stack: seq[ChunkedFileRef]
  stack.add v

  while stack.len > 0:
    let c = stack.pop()
    yield c

    for i in 0..c.children.high:
      stack.add(c.children[c.children.high - i])

iterator walkDataRoots*(v: ChunkedFileRef): SwarmAddress =
  if v.data.len > 0:
    yield v.refs
  else:
    var stack: seq[ChunkedFileRef]
    stack.add v

    while stack.len > 0:
      let c = stack.pop()
      if c.data.len > 0:
        continue

      for i in 0..<c.roots.len:
        yield c.roots[i]

      for i in 0..c.children.high:
        stack.add(c.children[c.children.high - i])

when isMainModule:
  import os

  let node = ChunkedFileRef(refs: SwarmAddress.fromHex("f82983e2d40851fd3facc12f626dd4b49c4a8043dbe5adaba3d4595d8af0e5d1"))

  for n in node.walkChunkFiles:
    if n.loaded: continue
    let name = "/data/varroa/chunks/" & $n.refs
    if fileExists(name):
      let data = readFile(name).toBytes()
      load(n, data)
    else:
      debugEcho "want ", $n.refs
