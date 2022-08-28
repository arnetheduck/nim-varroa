import
  std/os,
  stew/[byteutils, results, io2],
  chronicles,
  ./types

type
  ChunkStore* = object
    dataDir: string

proc chunkFile(dataDir: string, adds: SwarmAddress): string =
  chunkDir(dataDir) & byteutils.toHex(adds.data)

proc stampFile(dataDir: string, adds: SwarmAddress): string =
  stampDir(dataDir) & byteutils.toHex(adds.data)

proc contains*(store: ChunkStore, adds: SwarmAddress): bool =
  isFile(store.dataDir.chunkFile(adds)) and
    isFile(store.dataDir.stampFile(adds))

proc load*(store: var ChunkStore, adds: SwarmAddress): Result[Chunk, string] =
  ok Chunk(
    data: ? readAllBytes(store.dataDir.chunkFile(adds)).mapErr(ioErrorMsg),
    stamp: ? readAllBytes(store.dataDir.stampFile(adds)).mapErr(ioErrorMsg)
  )

proc store*(
    store: var ChunkStore, adds: SwarmAddress, data: openArray[byte],
    stamp: openArray[byte]) =
  let res =
    io2.writeFile(store.dataDir.chunkFile(adds), data) and
    io2.writeFile(store.dataDir.stampFile(adds), stamp)
  if res.isErr():
    warn "Couldn't store chunk",
      adds, data = data.len, stamp = stamp.len, error = $res.error()

proc new*(T: type ChunkStore, dataDir: string): ref ChunkStore =
  createDir(chunkDir(dataDir))
  createDir(stampDir(dataDir))

  (ref ChunkStore)(
    dataDir: dataDir,
  )
