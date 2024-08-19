# beacon_chain
# Copyright (c) 2018-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import std/[sequtils, strutils]
import chronos, chronicles
import
  ../spec/datatypes/[phase0, deneb],
  ../spec/[forks, network, eip7594_helpers],
  ../networking/eth2_network,
  ../consensus_object_pools/block_quarantine,
  ../consensus_object_pools/blob_quarantine,
  ../consensus_object_pools/data_column_quarantine,
  "."/sync_protocol, "."/sync_manager,
  ../gossip_processing/block_processor

from ../beacon_clock import GetBeaconTimeFn
export block_quarantine, sync_manager

logScope:
  topics = "requman"

const
  SYNC_MAX_REQUESTED_BLOCKS* = 32 # Spec allows up to MAX_REQUEST_BLOCKS.
    ## Maximum number of blocks which will be requested in each
    ## `beaconBlocksByRoot` invocation.
  PARALLEL_REQUESTS* = 2
    ## Number of peers we using to resolve our request.
  
  PARALLEL_REQUESTS_DATA_COLUMNS* = 8

  BLOB_GOSSIP_WAIT_TIME_NS* = 2 * 1_000_000_000
    ## How long to wait for blobs to arrive over gossip before fetching.

  DATA_COLUMN_GOSSIP_WAIT_TIME_NS* =  4 * 1_000_000_000

  POLL_INTERVAL = 1.seconds

type
  BlockVerifierFn* = proc(
      signedBlock: ForkedSignedBeaconBlock,
      maybeFinalized: bool
  ): Future[Result[void, VerifierError]] {.async: (raises: [CancelledError]).}

  BlockLoaderFn* = proc(
      blockRoot: Eth2Digest
  ): Opt[ForkedTrustedSignedBeaconBlock] {.gcsafe, raises: [].}

  BlobLoaderFn* = proc(
      blobId: BlobIdentifier): Opt[ref BlobSidecar] {.gcsafe, raises: [].}

  DataColumnLoaderFn* = proc(
      columnId: DataColumnIdentifier
  ): Opt[ref DataColumnSidecar] {.gcsafe, raises: [].}

  InhibitFn* = proc: bool {.gcsafe, raises: [].}

  RequestManager* = object
    network*: Eth2Node
    supernode: bool
    getBeaconTime: GetBeaconTimeFn
    inhibit: InhibitFn
    quarantine: ref Quarantine
    blobQuarantine: ref BlobQuarantine
    dataColumnQuarantine: ref DataColumnQuarantine
    blockVerifier: BlockVerifierFn
    blockLoader: BlockLoaderFn
    blobLoader: BlobLoaderFn
    dataColumnLoader: DataColumnLoaderFn
    blockLoopFuture: Future[void].Raising([CancelledError])
    blobLoopFuture: Future[void].Raising([CancelledError])
    dataColumnLoopFuture: Future[void].Raising([CancelledError])

func shortLog*(x: seq[Eth2Digest]): string =
  "[" & x.mapIt(shortLog(it)).join(", ") & "]"

func shortLog*(x: seq[FetchRecord]): string =
  "[" & x.mapIt(shortLog(it.root)).join(", ") & "]"

proc init*(T: type RequestManager, network: Eth2Node,
              supernode: bool,
              denebEpoch: Epoch,
              getBeaconTime: GetBeaconTimeFn,
              inhibit: InhibitFn,
              quarantine: ref Quarantine,
              blobQuarantine: ref BlobQuarantine,
              dataColumnQuarantine: ref DataColumnQuarantine,
              blockVerifier: BlockVerifierFn,
              blockLoader: BlockLoaderFn = nil,
              blobLoader: BlobLoaderFn = nil,
              dataColumnLoader: DataColumnLoaderFn = nil): RequestManager =
  RequestManager(
    network: network,
    supernode: supernode,
    getBeaconTime: getBeaconTime,
    inhibit: inhibit,
    quarantine: quarantine,
    blobQuarantine: blobQuarantine,
    dataColumnQuarantine: dataColumnQuarantine,
    blockVerifier: blockVerifier,
    blockLoader: blockLoader,
    blobLoader: blobLoader,
    dataColumnLoader: dataColumnLoader)

proc checkResponse(roots: openArray[Eth2Digest],
                   blocks: openArray[ref ForkedSignedBeaconBlock]): bool =
  ## This procedure checks peer's response.
  var checks = @roots
  if len(blocks) > len(roots):
    return false
  for blk in blocks:
    let res = checks.find(blk[].root)
    if res == -1:
      return false
    else:
      checks.del(res)
  true

proc checkResponse(idList: seq[BlobIdentifier],
                   blobs: openArray[ref BlobSidecar]): bool =
  if len(blobs) > len(idList):
    return false
  for blob in blobs:
    let block_root = hash_tree_root(blob.signed_block_header.message)
    var found = false
    for id in idList:
      if id.block_root == block_root and id.index == blob.index:
        found = true
        break
    if not found:
      return false
    blob[].verify_blob_sidecar_inclusion_proof().isOkOr:
      return false
  true

proc checkResponse(colIdList: seq[DataColumnIdentifier],
                   columns: openArray[ref DataColumnSidecar]): bool =
  if len(columns) > len(colIdList):
    return false
  for column in columns:
    let block_root = hash_tree_root(column.signed_block_header.message)
    var found = false
    for id in colIdList:
      if id.block_root == block_root and id.index == column.index:
        found = true
        break
    if not found:
      return false
    column[].verify_data_column_sidecar_inclusion_proof().isOkOr:
      return false
  true

proc requestBlocksByRoot(rman: RequestManager, items: seq[Eth2Digest]) {.async: (raises: [CancelledError]).} =
  var peer: Peer
  try:
    peer = await rman.network.peerPool.acquire()
    debug "Requesting blocks by root", peer = peer, blocks = shortLog(items),
                                       peer_score = peer.getScore()

    let blocks = (await beaconBlocksByRoot_v2(peer, BlockRootsList items))

    if blocks.isOk:
      let ublocks = blocks.get()
      if checkResponse(items, ublocks.asSeq()):
        var
          gotGoodBlock = false
          gotUnviableBlock = false

        for b in ublocks:
          let ver = await rman.blockVerifier(b[], false)
          if ver.isErr():
            case ver.error()
            of VerifierError.MissingParent:
              # Ignoring because the order of the blocks that
              # we requested may be different from the order in which we need
              # these blocks to apply.
              discard
            of VerifierError.Duplicate:
              # Ignoring because these errors could occur due to the
              # concurrent/parallel requests we made.
              discard
            of VerifierError.UnviableFork:
              # If they're working a different fork, we'll want to descore them
              # but also process the other blocks (in case we can register the
              # other blocks as unviable)
              gotUnviableBlock = true
            of VerifierError.Invalid:
              # We stop processing blocks because peer is either sending us
              # junk or working a different fork
              notice "Received invalid block",
                peer = peer, blocks = shortLog(items),
                peer_score = peer.getScore()
              peer.updateScore(PeerScoreBadValues)

              return # Stop processing this junk...
          else:
            gotGoodBlock = true

        if gotUnviableBlock:
          notice "Received blocks from an unviable fork",
            peer = peer, blocks = shortLog(items),
            peer_score = peer.getScore()
          peer.updateScore(PeerScoreUnviableFork)
        elif gotGoodBlock:
          debug "Request manager got good block",
            peer = peer, blocks = shortLog(items), ublocks = len(ublocks)

          # We reward peer only if it returns something.
          peer.updateScore(PeerScoreGoodValues)

      else:
        debug "Mismatching response to blocks by root",
          peer = peer, blocks = shortLog(items), ublocks = len(ublocks)
        peer.updateScore(PeerScoreBadResponse)
    else:
      debug "Blocks by root request failed",
        peer = peer, blocks = shortLog(items), err = blocks.error()
      peer.updateScore(PeerScoreNoValues)

  finally:
    if not(isNil(peer)):
      rman.network.peerPool.release(peer)

proc fetchBlobsFromNetwork(self: RequestManager,
                           idList: seq[BlobIdentifier])
                           {.async: (raises: [CancelledError]).} =
  var peer: Peer

  try:
    peer = await self.network.peerPool.acquire()
    debug "Requesting blobs by root", peer = peer, blobs = shortLog(idList),
                                             peer_score = peer.getScore()

    let blobs = await blobSidecarsByRoot(peer, BlobIdentifierList idList)

    if blobs.isOk:
      let ublobs = blobs.get()
      if not checkResponse(idList, ublobs.asSeq()):
        debug "Mismatched response to blobs by root",
          peer = peer, blobs = shortLog(idList), ublobs = len(ublobs)
        peer.updateScore(PeerScoreBadResponse)
        return

      for b in ublobs:
        self.blobQuarantine[].put(b)
      var curRoot: Eth2Digest
      for b in ublobs:
        let block_root = hash_tree_root(b.signed_block_header.message)
        if block_root != curRoot:
          curRoot = block_root
          if (let o = self.quarantine[].popBlobless(curRoot); o.isSome):
            let b = o.unsafeGet()
            discard await self.blockVerifier(b, false)
            # TODO:
            # If appropriate, return a VerifierError.InvalidBlob from
            # verification, check for it here, and penalize the peer accordingly
    else:
      debug "Blobs by root request failed",
        peer = peer, blobs = shortLog(idList), err = blobs.error()
      peer.updateScore(PeerScoreNoValues)

  finally:
    if not(isNil(peer)):
      self.network.peerPool.release(peer)

proc lookupCscFromPeer(peer: Peer):
                                            uint64 =
  # Fetches the custody column count from a remote peer
  # if the peer advertises their custody column count 
  # via the `csc` ENR field. If the peer does NOT, then
  # the default value is assume, i.e, CUSTODY_REQUIREMENT

  let enrOpt = peer.enr
  if enrOpt.isNone:
    debug "Could not get ENR from peer",
      peer_id = peer.peerId
    return 0

  else:
    let
      enr = enrOpt.get
      enrFieldOpt = 
          enr.get(enrCustodySubnetCountField, uint64)

    if not enrFieldOpt.isOk:
      debug "Issue with fetching `csc` field from ENR",
        enr = enr
    else:
      return(enrFieldOpt.get)

proc constructValidCustodyPeers(rman: RequestManager,
                                peers: openArray[Peer]):
                                seq[Peer] =
  let localCustodySubnetCount =
    if rman.supernode:
      DATA_COLUMN_SIDECAR_SUBNET_COUNT.uint64
    else:
      CUSTODY_REQUIREMENT

  # Fetching the local cusotrdy columns
  let
    localNodeId = rman.network.nodeId
    localCustodyColumns =
      localNodeId.get_custody_columns(localCustodySubnetCount).get
  
  var validPeers: seq[Peer]

  for peer in peers:
    # Get the custody subnet count of the remote peer
    let remoteCustodySubnetCount =
      peer.lookupCscFromPeer()
    
    # Extract remote peer's nodeID from peerID
    # Fetch custody columns from remote peer
    let
      remoteNodeId = getNodeIdFromPeer(peer)
      remoteCustodyColumns =
        remoteNodeId.get_custody_columns(remoteCustodySubnetCount).get
    
    # If the remote peer custodies less columns than
    # our local node
    # We skip it
    if remoteCustodyColumns.len < localCustodyColumns.len:
      continue

    # If the remote peer custodies all the possible columns
    if remoteCustodyColumns.len == NUMBER_OF_COLUMNS:
      validPeers.add(peer)
    
    # Filtering out the inval;id peers
    for column in localCustodyColumns:
      if column notin remoteCustodyColumns:
        continue

    # Otherwise add the peer to the set of valid peers
    validPeers.add(peer)
  validPeers

proc fetchDataColumnsFromNetwork(rman: RequestManager,
                                 colIdList: seq[DataColumnIdentifier])
                                 {.async: (raises: [CancelledError]).} =
  var peer: Peer
  var peers: seq[Peer]
  try:
    peer = await rman.network.peerPool.acquire()

    # # Create a peer list, which shall be later trimmed off as to which
    # # of the peers have the valid custody columns
    # peers.add(peer)
    # let validPeers = rman.constructValidCustodyPeers(peers)
    # if peer in validPeers:
    debug "Requesting data columns by root", peer = peer, columns = shortLog(colIdList),
                                                    peer_score = peer.getScore()
    let columns = await dataColumnSidecarsByRoot(peer, DataColumnIdentifierList colIdList)

    if columns.isOk:
      let ucolumns = columns.get()
      if not checkResponse(colIdList, ucolumns.asSeq()):
        debug "Mismatched response to data columns by root",
          peer = peer, columns = shortLog(colIdList), ucolumns = len(ucolumns)
        # peer.updateScore(PeerScoreBadResponse)
        return

      for col in ucolumns:
        rman.dataColumnQuarantine[].put(col)
      var curRoot: Eth2Digest
      for col in ucolumns:
        let block_root = hash_tree_root(col.signed_block_header.message)
        if block_root != curRoot:
          curRoot = block_root
          if (let o = rman.quarantine[].popColumnless(curRoot); o.isSome):
            let col = o.unsafeGet()
            discard await rman.blockVerifier(col, false)
    else:
      debug "Data columns by root request failed",
        peer = peer, columns = shortLog(colIdList), err = columns.error()
      # peer.updateScore(PeerScoreNoValues)

  finally:
    if not(isNil(peer)):
      rman.network.peerPool.release(peer)

proc requestManagerBlockLoop(
    rman: RequestManager) {.async: (raises: [CancelledError]).} =
  while true:
    # TODO This polling could be replaced with an AsyncEvent that is fired
    #      from the quarantine when there's work to do
    await sleepAsync(POLL_INTERVAL)

    if rman.inhibit():
      continue

    let missingBlockRoots =
      rman.quarantine[].checkMissing(SYNC_MAX_REQUESTED_BLOCKS).mapIt(it.root)
    if missingBlockRoots.len == 0:
      continue

    # TODO This logic can be removed if the database schema is extended
    # to store non-canonical heads on top of the canonical head!
    # If that is done, the database no longer contains extra blocks
    # that have not yet been assigned a `BlockRef`
    var blockRoots: seq[Eth2Digest]
    if rman.blockLoader == nil:
      blockRoots = missingBlockRoots
    else:
      var verifiers:
        seq[Future[Result[void, VerifierError]].Raising([CancelledError])]
      for blockRoot in missingBlockRoots:
        let blck = rman.blockLoader(blockRoot).valueOr:
          blockRoots.add blockRoot
          continue
        debug "Loaded orphaned block from storage", blockRoot
        verifiers.add rman.blockVerifier(
          blck.asSigned(), maybeFinalized = false)
      try:
        await allFutures(verifiers)
      except CancelledError as exc:
        var futs = newSeqOfCap[Future[void].Raising([])](verifiers.len)
        for verifier in verifiers:
          futs.add verifier.cancelAndWait()
        await noCancel allFutures(futs)
        raise exc

    if blockRoots.len == 0:
      continue

    debug "Requesting detected missing blocks", blocks = shortLog(blockRoots)
    let start = SyncMoment.now(0)

    var workers:
      array[PARALLEL_REQUESTS, Future[void].Raising([CancelledError])]

    for i in 0 ..< PARALLEL_REQUESTS:
      workers[i] = rman.requestBlocksByRoot(blockRoots)

    await allFutures(workers)

    let finish = SyncMoment.now(uint64(len(blockRoots)))

    debug "Request manager block tick", blocks = shortLog(blockRoots),
                                        sync_speed = speed(start, finish)

proc getMissingBlobs(rman: RequestManager): seq[BlobIdentifier] =
  let
    wallTime = rman.getBeaconTime()
    wallSlot = wallTime.slotOrZero()
    delay = wallTime - wallSlot.start_beacon_time()
    waitDur = TimeDiff(nanoseconds: BLOB_GOSSIP_WAIT_TIME_NS)

  var
    fetches: seq[BlobIdentifier]
    ready: seq[Eth2Digest]
  for blobless in rman.quarantine[].peekBlobless():
    withBlck(blobless):
      when consensusFork >= ConsensusFork.Deneb:
        # give blobs a chance to arrive over gossip
        if forkyBlck.message.slot == wallSlot and delay < waitDur:
          debug "Not handling missing blobs early in slot"
          continue

        if not rman.blobQuarantine[].hasBlobs(forkyBlck):
          let missing = rman.blobQuarantine[].blobFetchRecord(forkyBlck)
          if len(missing.indices) == 0:
            warn "quarantine missing blobs, but missing indices is empty",
             blk=blobless.root,
             commitments=len(forkyBlck.message.body.blob_kzg_commitments)
          for idx in missing.indices:
            let id = BlobIdentifier(block_root: blobless.root, index: idx)
            if id notin fetches:
              fetches.add(id)
        else:
          # this is a programming error should it occur.
          warn "missing blob handler found blobless block with all blobs",
             blk=blobless.root,
             commitments=len(forkyBlck.message.body.blob_kzg_commitments)
          ready.add(blobless.root)

  for root in ready:
    let blobless = rman.quarantine[].popBlobless(root).valueOr:
      continue
    discard rman.blockVerifier(blobless, false)
  fetches

proc requestManagerBlobLoop(
    rman: RequestManager) {.async: (raises: [CancelledError]).} =
  while true:
    # TODO This polling could be replaced with an AsyncEvent that is fired
    #      from the quarantine when there's work to do
    await sleepAsync(POLL_INTERVAL)
    if rman.inhibit():
      continue

    let missingBlobIds = rman.getMissingBlobs()
    if missingBlobIds.len == 0:
      continue

    # TODO This logic can be removed if the database schema is extended
    # to store non-canonical heads on top of the canonical head!
    # If that is done, the database no longer contains extra blocks
    # that have not yet been assigned a `BlockRef`
    var blobIds: seq[BlobIdentifier]
    if rman.blobLoader == nil:
      blobIds = missingBlobIds
    else:
      var
        blockRoots: seq[Eth2Digest]
        curRoot: Eth2Digest
      for blobId in missingBlobIds:
        if blobId.block_root != curRoot:
          curRoot = blobId.block_root
          blockRoots.add curRoot
        let blob_sidecar = rman.blobLoader(blobId).valueOr:
          blobIds.add blobId
          if blockRoots.len > 0 and blockRoots[^1] == curRoot:
            # A blob is missing, remove from list of fully available blocks
            discard blockRoots.pop()
          continue
        debug "Loaded orphaned blob from storage", blobId
        rman.blobQuarantine[].put(blob_sidecar)
      var verifiers = newSeqOfCap[
        Future[Result[void, VerifierError]]
          .Raising([CancelledError])](blockRoots.len)
      for blockRoot in blockRoots:
        let blck = rman.quarantine[].popBlobless(blockRoot).valueOr:
          continue
        verifiers.add rman.blockVerifier(blck, maybeFinalized = false)
      try:
        await allFutures(verifiers)
      except CancelledError as exc:
        var futs = newSeqOfCap[Future[void].Raising([])](verifiers.len)
        for verifier in verifiers:
          futs.add verifier.cancelAndWait()
        await noCancel allFutures(futs)
        raise exc

    if blobIds.len > 0:
      debug "Requesting detected missing blobs", blobs = shortLog(blobIds)
      let start = SyncMoment.now(0)
      var workers:
        array[PARALLEL_REQUESTS, Future[void].Raising([CancelledError])]
      for i in 0 ..< PARALLEL_REQUESTS:
        workers[i] = rman.fetchBlobsFromNetwork(blobIds)

      await allFutures(workers)
      let finish = SyncMoment.now(uint64(len(blobIds)))

      debug "Request manager blob tick",
            blobs_count = len(blobIds),
            sync_speed = speed(start, finish)

proc getMissingDataColumns(rman: RequestManager): seq[DataColumnIdentifier] =
  let
    wallTime = rman.getBeaconTime()
    wallSlot = wallTime.slotOrZero()
    delay = wallTime - wallSlot.start_beacon_time()
  
  const waitDur = TimeDiff(nanoseconds: DATA_COLUMN_GOSSIP_WAIT_TIME_NS)

  var
    fetches: seq[DataColumnIdentifier]
    ready: seq[Eth2Digest]
  for columnless in rman.quarantine[].peekColumnless():
    withBlck(columnless):
      when consensusFork >= ConsensusFork.Deneb:
        # granting data columns a chance to arrive over gossip
        if forkyBlck.message.slot == wallSlot and delay < waitDur:
          debug "Not handling missing data columns early in slot"
          continue

        if not rman.dataColumnQuarantine[].hasDataColumns(forkyBlck):
          let missing = rman.dataColumnQuarantine[].dataColumnFetchRecord(forkyBlck)
          if len(missing.indices) == 0:
            warn "quarantine is missing data columns, but missing indices are empty",
             blk = columnless.root,
             commitments = len(forkyBlck.message.body.blob_kzg_commitments)
          for idx in missing.indices:
            let id = DataColumnIdentifier(block_root: columnless.root, index: idx)
            if id notin fetches:
              fetches.add(id)
        else:
          # this is a programming error and it not should occur
          warn "missing data column handler found columnless block with all data columns",
             blk = columnless.root,
             commitments=len(forkyBlck.message.body.blob_kzg_commitments)
          ready.add(columnless.root)
  
  for root in ready:
    let columnless = rman.quarantine[].popColumnless(root).valueOr:
      continue
    discard rman.blockVerifier(columnless, false)
  fetches

proc requestManagerDataColumnLoop(
    rman: RequestManager) {.async: (raises: [CancelledError]).} =
  while true:
    
    await sleepAsync(POLL_INTERVAL)
    if rman.inhibit():
      continue

    let missingColumnIds = rman.getMissingDataColumns()
    if missingColumnIds.len == 0:
      continue

    var columnIds: seq[DataColumnIdentifier]
    if rman.dataColumnLoader == nil:
      columnIds = missingColumnIds
    else:
      var
        blockRoots: seq[Eth2Digest]
        curRoot: Eth2Digest
      for columnId in missingColumnIds:
        if columnId.block_root != curRoot:
          curRoot = columnId.block_root
          blockRoots.add curRoot
        let data_column_sidecar = rman.dataColumnLoader(columnId).valueOr:
          columnIds.add columnId
          if blockRoots.len > 0 and blockRoots[^1] == curRoot:
            # A data column is missing, remove from list of fully available data columns
            discard blockRoots.pop()
          continue
        debug "Loaded orphaned data columns from storage", columnId
        rman.dataColumnQuarantine[].put(data_column_sidecar)
      var verifiers = newSeqOfCap[
        Future[Result[void, VerifierError]]  
          .Raising([CancelledError])](blockRoots.len)
      for blockRoot in blockRoots:
        let blck = rman.quarantine[].popColumnless(blockRoot).valueOr:
          continue
        verifiers.add rman.blockVerifier(blck, maybeFinalized = false)
      try:
        await allFutures(verifiers)
      except CancelledError as exc:
        var futs = newSeqOfCap[Future[void].Raising([])](verifiers.len)
        for verifier in verifiers:
          futs.add verifier.cancelAndWait()
        await noCancel allFutures(futs)
        raise exc
    if columnIds.len > 0:
      debug "Requesting detected missing data columns", columns = shortLog(columnIds)
      let start = SyncMoment.now(0)
      var workers:
        array[PARALLEL_REQUESTS_DATA_COLUMNS, Future[void].Raising([CancelledError])]
      for i in 0..<PARALLEL_REQUESTS_DATA_COLUMNS:
        workers[i] = rman.fetchDataColumnsFromNetwork(columnIds)
      
      await allFutures(workers)
      let finish = SyncMoment.now(uint64(len(columnIds)))

      debug "Request manager data column tick",
            data_columns_count = len(columnIds),
            sync_speed = speed(start, finish)
      

proc start*(rman: var RequestManager) =
  ## Start Request Manager's loops.
  rman.blockLoopFuture = rman.requestManagerBlockLoop()
  rman.dataColumnLoopFuture = rman.requestManagerDataColumnLoop()
  # rman.blobLoopFuture = rman.requestManagerBlobLoop()
  

proc stop*(rman: RequestManager) =
  ## Stop Request Manager's loop.
  if not(isNil(rman.blockLoopFuture)):
    rman.blockLoopFuture.cancelSoon()
  if not(isNil(rman.blobLoopFuture)):
    rman.blobLoopFuture.cancelSoon()
  if not(isNil(rman.dataColumnLoopFuture)):
    rman.dataColumnLoopFuture.cancelSoon()
