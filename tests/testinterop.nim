import options, tables
import unittest
import chronos, chronicles
import ../libp2p/[daemon/daemonapi,
                  protobuf/minprotobuf,
                  vbuffer,
                  multiaddress,
                  multicodec,
                  cid,
                  varint,
                  multihash,
                  peer,
                  peerinfo,
                  switch,
                  connection,
                  stream/lpstream,
                  muxers/muxer,
                  crypto/crypto,
                  muxers/mplex/mplex,
                  muxers/muxer,
                  muxers/mplex/types,
                  protocols/protocol,
                  protocols/identify,
                  transports/transport,
                  transports/tcptransport,
                  protocols/secure/secure,
                  protocols/secure/secio,
                  protocols/pubsub/pubsub,
                  protocols/pubsub/gossipsub,
                  protocols/pubsub/floodsub]

type
  # TODO: Unify both PeerInfo structs
  NativePeerInfo = peerinfo.PeerInfo
  DaemonPeerInfo = daemonapi.PeerInfo

proc writeLp*(s: StreamTransport, msg: string | seq[byte]): Future[int] {.gcsafe.} =
  ## write lenght prefixed
  var buf = initVBuffer()
  buf.writeSeq(msg)
  buf.finish()
  result = s.write(buf.buffer)

proc readLp*(s: StreamTransport): Future[seq[byte]] {.async, gcsafe.} =
  ## read lenght prefixed msg
  var
    size: uint
    length: int
    res: VarintStatus
  result = newSeq[byte](10)
  try:
    for i in 0..<len(result):
      await s.readExactly(addr result[i], 1)
      res = LP.getUVarint(result.toOpenArray(0, i), length, size)
      if res == VarintStatus.Success:
        break
    if res != VarintStatus.Success or size > DefaultReadSize:
      raise newInvalidVarintException()
    result.setLen(size)
    if size > 0.uint:
      await s.readExactly(addr result[0], int(size))
  except LPStreamIncompleteError, LPStreamReadError:
      trace "remote connection ended unexpectedly", exc = getCurrentExceptionMsg()

proc createNode*(privKey: Option[PrivateKey] = none(PrivateKey), 
                 address: string = "/ip4/127.0.0.1/tcp/0",
                 triggerSelf: bool = false,
                 gossip: bool = false): Switch =
  var seckey = privKey
  if privKey.isNone:
    seckey = some(PrivateKey.random(RSA))

  var peerInfo = NativePeerInfo.init(seckey.get(), @[Multiaddress.init(address)])
  proc createMplex(conn: Connection): Muxer = newMplex(conn)
  let mplexProvider = newMuxerProvider(createMplex, MplexCodec)
  let transports = @[Transport(newTransport(TcpTransport))]
  let muxers = [(MplexCodec, mplexProvider)].toTable()
  let identify = newIdentify(peerInfo)
  let secureManagers = [(SecioCodec, Secure(newSecio(seckey.get())))].toTable()
  
  var pubSub: Option[PubSub]
  if gossip:
    pubSub = some(PubSub(newPubSub(GossipSub, peerInfo, triggerSelf)))
  else:
    pubSub = some(PubSub(newPubSub(FloodSub, peerInfo, triggerSelf)))

  result = newSwitch(peerInfo,
                     transports,
                     identify,
                     muxers,
                     secureManagers = secureManagers,
                     pubSub = pubSub)

proc testPubSubDaemonPublish(gossip: bool = false): Future[bool] {.async.} =
  var pubsubData = "TEST MESSAGE"
  var testTopic = "test-topic"
  var msgData = cast[seq[byte]](pubsubData)

  var flags = {PSFloodSub}
  if gossip:
    flags = {PSGossipSub}

  let daemonNode = await newDaemonApi(flags)
  let daemonPeer = await daemonNode.identity()
  let nativeNode = createNode(gossip = gossip)
  let awaiters = nativeNode.start()
  let nativePeer = nativeNode.peerInfo

  var handlerFuture = newFuture[bool]()
  proc nativeHandler(topic: string, data: seq[byte]) {.async.} =
    let smsg = cast[string](data)
    check smsg == pubsubData
    handlerFuture.complete(true)

  await nativeNode.subscribeToPeer(NativePeerInfo.init(daemonPeer.peer,
                                                       daemonPeer.addresses))
  await sleepAsync(1.seconds)
  await daemonNode.connect(nativePeer.peerId, nativePeer.addrs)
  
  proc pubsubHandler(api: DaemonAPI,
                     ticket: PubsubTicket,
                     message: PubSubMessage): Future[bool] {.async.} = 
    result = true # don't cancel subscription

  asyncDiscard daemonNode.pubsubSubscribe(testTopic, pubsubHandler)
  await nativeNode.subscribe(testTopic, nativeHandler)
  await sleepAsync(1.seconds)
  await daemonNode.pubsubPublish(testTopic, msgData)

  result = await handlerFuture
  await nativeNode.stop()
  await allFutures(awaiters)
  await daemonNode.close()

proc testPubSubNodePublish(gossip: bool = false): Future[bool] {.async.} =
  var pubsubData = "TEST MESSAGE"
  var testTopic = "test-topic"
  var msgData = cast[seq[byte]](pubsubData)

  var flags = {PSFloodSub}
  if gossip:
    flags = {PSGossipSub}

  let daemonNode = await newDaemonApi(flags)
  let daemonPeer = await daemonNode.identity()
  let nativeNode = createNode(gossip = gossip)
  let awaiters = nativeNode.start()
  let nativePeer = nativeNode.peerInfo

  var handlerFuture = newFuture[bool]()
  await nativeNode.subscribeToPeer(NativePeerInfo.init(daemonPeer.peer,
                                                       daemonPeer.addresses))

  await sleepAsync(1.seconds)
  await daemonNode.connect(nativePeer.peerId, nativePeer.addrs)
  
  proc pubsubHandler(api: DaemonAPI,
                     ticket: PubsubTicket,
                     message: PubSubMessage): Future[bool] {.async.} = 
    let smsg = cast[string](message.data)
    check smsg == pubsubData
    handlerFuture.complete(true)
    result = true # don't cancel subscription

  asyncDiscard daemonNode.pubsubSubscribe(testTopic, pubsubHandler)
  await sleepAsync(1.seconds)
  await nativeNode.publish(testTopic, msgData)

  result = await handlerFuture
  await nativeNode.stop()
  await allFutures(awaiters)
  await daemonNode.close()

suite "Interop":
  test "native -> daemon multiple reads and writes":
    proc runTests(): Future[bool] {.async.} =
      var protos = @["/test-stream"]

      let nativeNode = createNode()
      let awaiters = await nativeNode.start()
      let daemonNode = await newDaemonApi()
      let daemonPeer = await daemonNode.identity()

      var testFuture = newFuture[void]("test.future")
      proc daemonHandler(api: DaemonAPI, stream: P2PStream) {.async.} =
        check cast[string](await stream.transp.readLp()) == "test 1"
        asyncDiscard stream.transp.writeLp("test 2")
        
        await sleepAsync(10.millis)
        check cast[string](await stream.transp.readLp()) == "test 3"
        asyncDiscard stream.transp.writeLp("test 4")
        testFuture.complete()

      await daemonNode.addHandler(protos, daemonHandler)
      let conn = await nativeNode.dial(NativePeerInfo.init(daemonPeer.peer,
                                                           daemonPeer.addresses),
                                                           protos[0])
      await conn.writeLp("test 1")
      check "test 2" == cast[string]((await conn.readLp()))
      await sleepAsync(10.millis)

      await conn.writeLp("test 3")
      check "test 4" == cast[string]((await conn.readLp()))

      await wait(testFuture, 10.secs)
      await nativeNode.stop()
      await allFutures(awaiters)
      await daemonNode.close()
      result = true

    check:
      waitFor(runTests()) == true

  test "native -> daemon connection":
    proc runTests(): Future[bool] {.async.} =
      var protos = @["/test-stream"]
      var test = "TEST STRING"

      let nativeNode = createNode()
      let awaiters = await nativeNode.start()

      let daemonNode = await newDaemonApi()
      let daemonPeer = await daemonNode.identity()

      var testFuture = newFuture[string]("test.future")
      proc daemonHandler(api: DaemonAPI, stream: P2PStream) {.async.} =
        var line = await stream.transp.readLine()
        check line == test
        testFuture.complete(line)

      await daemonNode.addHandler(protos, daemonHandler)
      let conn = await nativeNode.dial(NativePeerInfo.init(daemonPeer.peer,
                                                           daemonPeer.addresses),
                                                           protos[0])
      await conn.writeLp(test & "\r\n")
      result = test == (await wait(testFuture, 10.secs))
      await nativeNode.stop()
      await allFutures(awaiters)
      await daemonNode.close()

    check:
      waitFor(runTests()) == true

  test "daemon -> native connection":
    proc runTests(): Future[bool] {.async.} =
      var protos = @["/test-stream"]
      var test = "TEST STRING"

      var testFuture = newFuture[string]("test.future")
      proc nativeHandler(conn: Connection, proto: string) {.async.} =
        var line = cast[string](await conn.readLp())
        check line == test
        testFuture.complete(line)
        await conn.close()

      # custom proto
      var proto = new LPProtocol
      proto.handler = nativeHandler
      proto.codec = protos[0] # codec

      let nativeNode = createNode()
      nativeNode.mount(proto)

      let awaiters = await nativeNode.start()
      let nativePeer = nativeNode.peerInfo

      let daemonNode = await newDaemonApi()
      await daemonNode.connect(nativePeer.peerId, nativePeer.addrs)
      var stream = await daemonNode.openStream(nativePeer.peerId, protos)
      discard await stream.transp.writeLp(test)

      result = test == (await wait(testFuture, 10.secs))
      await nativeNode.stop()
      await allFutures(awaiters)
      await daemonNode.close()

    check:
      waitFor(runTests()) == true

  test "daemon -> multiple reads and writes":
    proc runTests(): Future[bool] {.async.} =
      var protos = @["/test-stream"]

      var testFuture = newFuture[void]("test.future")
      proc nativeHandler(conn: Connection, proto: string) {.async.} =
        check "test 1" == cast[string](await conn.readLp())
        await conn.writeLp(cast[seq[byte]]("test 2"))

        check "test 3" == cast[string](await conn.readLp())
        await conn.writeLp(cast[seq[byte]]("test 4"))

        testFuture.complete()
        await conn.close()

      # custom proto
      var proto = new LPProtocol
      proto.handler = nativeHandler
      proto.codec = protos[0] # codec

      let nativeNode = createNode()
      nativeNode.mount(proto)

      let awaiters = await nativeNode.start()
      let nativePeer = nativeNode.peerInfo

      let daemonNode = await newDaemonApi()
      await daemonNode.connect(nativePeer.peerId, nativePeer.addrs)
      var stream = await daemonNode.openStream(nativePeer.peerId, protos)

      asyncDiscard stream.transp.writeLp("test 1")
      check "test 2" == cast[string](await stream.transp.readLp())

      asyncDiscard stream.transp.writeLp("test 3")
      check "test 4" == cast[string](await stream.transp.readLp())

      await wait(testFuture, 10.secs)

      result = true
      await nativeNode.stop()
      await allFutures(awaiters)
      await daemonNode.close()

    check:
      waitFor(runTests()) == true

  test "read write multiple":
    proc runTests(): Future[bool] {.async.} =
      var protos = @["/test-stream"]
      var test = "TEST STRING"

      var count = 0
      var testFuture = newFuture[int]("test.future")
      proc nativeHandler(conn: Connection, proto: string) {.async.} =
        while count < 10:
          var line = cast[string](await conn.readLp())
          check line == test
          await conn.writeLp(cast[seq[byte]](test))
          count.inc()

        testFuture.complete(count)
        await conn.close()

      # custom proto
      var proto = new LPProtocol
      proto.handler = nativeHandler
      proto.codec = protos[0] # codec

      let nativeNode = createNode()
      nativeNode.mount(proto)

      let awaiters = await nativeNode.start()
      let nativePeer = nativeNode.peerInfo

      let daemonNode = await newDaemonApi()
      await daemonNode.connect(nativePeer.peerId, nativePeer.addrs)
      var stream = await daemonNode.openStream(nativePeer.peerId, protos)

      while count < 10:
        discard await stream.transp.writeLp(test)
        let line = await stream.transp.readLp()
        check test == cast[string](line)

      result = 10 == (await wait(testFuture, 10.secs))
      await nativeNode.stop()
      await allFutures(awaiters)
      await daemonNode.close()

    check:
      waitFor(runTests()) == true

  test "floodsub: daemon publish":
    check:
      waitFor(testPubSubDaemonPublish()) == true

  test "gossipsub: daemon publish":
    check:
      waitFor(testPubSubDaemonPublish(true)) == true

  test "floodsub: node publish":
    check:
      waitFor(testPubSubNodePublish()) == true

  test "gossipsub: node publish":
    check:
      waitFor(testPubSubNodePublish(true)) == true