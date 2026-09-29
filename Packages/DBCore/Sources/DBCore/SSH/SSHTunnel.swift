import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import NIOSSH

public enum SSHTunnelError: Error, Sendable, LocalizedError {
    case authenticationFailed
    case hostKeyRejected
    case invalidData
    case connectionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .authenticationFailed: "SSH authentication failed."
        case .hostKeyRejected: "The SSH host key was rejected."
        case .invalidData: "Unexpected data on the SSH channel."
        case .connectionFailed(let reason): "SSH connection failed: \(reason)"
        }
    }
}

/// Decides whether to trust an SSH host key. Receives the host and the key in OpenSSH format.
public typealias SSHHostKeyValidator = @Sendable (_ host: String, _ openSSHKey: String) async -> Bool

/// Local port forward over SSH: listens on `127.0.0.1:<localPort>` and forwards each connection
/// through a `direct-tcpip` channel to `targetHost:targetPort` as seen from the SSH server.
///
/// Only password authentication is supported.
public final class SSHTunnel: Sendable {
    public let localPort: Int
    private let sshChannel: any Channel
    private let serverChannel: any Channel

    private init(localPort: Int, sshChannel: any Channel, serverChannel: any Channel) {
        self.localPort = localPort
        self.sshChannel = sshChannel
        self.serverChannel = serverChannel
    }

    public static func open(
        config: SSHTunnelConfig,
        password: String,
        targetHost: String,
        targetPort: Int,
        hostKeyValidator: @escaping SSHHostKeyValidator
    ) async throws -> SSHTunnel {
        let group = MultiThreadedEventLoopGroup.singleton
        let authState = NIOLockedValueBox<(any Error)?>(nil)
        let sshHost = config.host

        let sshChannel: any Channel
        do {
            sshChannel = try await ClientBootstrap(group: group)
                .connectTimeout(.seconds(10))
                .channelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        let handler = NIOSSHHandler(
                            role: .client(.init(
                                userAuthDelegate: PasswordDelegate(user: config.user, password: password, failure: authState),
                                serverAuthDelegate: HostKeyDelegate(host: sshHost, validator: hostKeyValidator, failure: authState)
                            )),
                            allocator: channel.allocator,
                            inboundChildChannelInitializer: nil
                        )
                        try channel.pipeline.syncOperations.addHandler(handler)
                        try channel.pipeline.syncOperations.addHandler(CloseOnErrorHandler())
                    }
                }
                .channelOption(.socketOption(.tcp_nodelay), value: 1)
                .connect(host: config.host, port: config.port)
                .get()
        } catch {
            throw SSHTunnelError.connectionFailed(String(describing: error))
        }

        // Everything runs on the SSH channel's loop so glue handlers never cross threads.
        let loop = sshChannel.eventLoop
        let serverChannel = try await ServerBootstrap(group: loop, childGroup: loop)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { inbound in
                sshChannel.pipeline.handler(type: NIOSSHHandler.self).flatMap { ssh in
                    let promise = inbound.eventLoop.makePromise(of: (any Channel).self)
                    let originator = inbound.remoteAddress ?? (try! SocketAddress(ipAddress: "127.0.0.1", port: 0))
                    let directTCPIP = SSHChannelType.DirectTCPIP(
                        targetHost: targetHost, targetPort: targetPort, originatorAddress: originator)
                    ssh.createChannel(promise, channelType: .directTCPIP(directTCPIP)) { child, _ in
                        child.eventLoop.makeCompletedFuture {
                            let (ours, theirs) = GlueHandler.matchedPair()
                            try child.pipeline.syncOperations.addHandler(SSHWrapperHandler())
                            try child.pipeline.syncOperations.addHandler(ours)
                            try child.pipeline.syncOperations.addHandler(CloseOnErrorHandler())
                            try inbound.pipeline.syncOperations.addHandler(theirs)
                            try inbound.pipeline.syncOperations.addHandler(CloseOnErrorHandler())
                        }
                    }
                    return promise.futureResult.map { _ in }
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()

        guard let port = serverChannel.localAddress?.port else {
            try? await serverChannel.close()
            try? await sshChannel.close()
            throw SSHTunnelError.connectionFailed("Could not bind a local port.")
        }

        // Wait for authentication to settle by opening (and closing) a session channel.
        do {
            let probe: any Channel = try await sshChannel.pipeline.handler(type: NIOSSHHandler.self).flatMap { ssh in
                let promise = loop.makePromise(of: (any Channel).self)
                ssh.createChannel(promise, channelType: .session) { child, _ in
                    child.eventLoop.makeSucceededVoidFuture()
                }
                return promise.futureResult
            }.get()
            try? await probe.close()
        } catch {
            try? await serverChannel.close()
            try? await sshChannel.close()
            throw authState.withLockedValue { $0 } ?? SSHTunnelError.connectionFailed(String(describing: error))
        }

        return SSHTunnel(localPort: port, sshChannel: sshChannel, serverChannel: serverChannel)
    }

    public func close() async {
        try? await serverChannel.close()
        try? await sshChannel.close()
    }
}

// MARK: - Delegates

private final class PasswordDelegate: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    private let user: String
    private let password: String
    private let failure: NIOLockedValueBox<(any Error)?>
    private var attempted = false

    init(user: String, password: String, failure: NIOLockedValueBox<(any Error)?>) {
        self.user = user
        self.password = password
        self.failure = failure
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard !attempted, availableMethods.contains(.password) else {
            failure.withLockedValue { $0 = $0 ?? SSHTunnelError.authenticationFailed }
            nextChallengePromise.fail(SSHTunnelError.authenticationFailed)
            return
        }
        attempted = true
        nextChallengePromise.succeed(.init(username: user, serviceName: "", offer: .password(.init(password: password))))
    }
}

private final class HostKeyDelegate: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let host: String
    private let validator: SSHHostKeyValidator
    private let failure: NIOLockedValueBox<(any Error)?>

    init(host: String, validator: @escaping SSHHostKeyValidator, failure: NIOLockedValueBox<(any Error)?>) {
        self.host = host
        self.validator = validator
        self.failure = failure
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let key = String(openSSHPublicKey: hostKey)
        let host = self.host
        let validator = self.validator
        let failure = self.failure
        Task {
            if await validator(host, key) {
                validationCompletePromise.succeed(())
            } else {
                failure.withLockedValue { $0 = SSHTunnelError.hostKeyRejected }
                validationCompletePromise.fail(SSHTunnelError.hostKeyRejected)
            }
        }
    }
}

// MARK: - Handlers

private final class CloseOnErrorHandler: ChannelInboundHandler {
    typealias InboundIn = Any
    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        context.close(promise: nil)
    }
}

private final class SSHWrapperHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let data = unwrapInboundIn(data)
        guard case .channel = data.type, case .byteBuffer(let buffer) = data.data else {
            context.fireErrorCaught(SSHTunnelError.invalidData)
            return
        }
        context.fireChannelRead(wrapInboundOut(buffer))
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let wrapped = SSHChannelData(type: .channel, data: .byteBuffer(unwrapOutboundIn(data)))
        context.write(wrapOutboundOut(wrapped), promise: promise)
    }
}

/// Pipes two channels together with back-pressure (from the swift-nio-ssh examples).
private final class GlueHandler: ChannelDuplexHandler {
    typealias InboundIn = NIOAny
    typealias OutboundIn = NIOAny
    typealias OutboundOut = NIOAny

    private var partner: GlueHandler?
    private var context: ChannelHandlerContext?
    private var pendingRead = false

    static func matchedPair() -> (GlueHandler, GlueHandler) {
        let first = GlueHandler(), second = GlueHandler()
        first.partner = second
        second.partner = first
        return (first, second)
    }

    private func partnerWrite(_ data: NIOAny) { context?.write(data, promise: nil) }
    private func partnerFlush() { context?.flush() }
    private func partnerWriteEOF() { context?.close(mode: .output, promise: nil) }
    private func partnerCloseFull() { context?.close(promise: nil) }
    private func partnerBecameWritable() {
        if pendingRead {
            pendingRead = false
            context?.read()
        }
    }
    private var partnerWritable: Bool { context?.channel.isWritable ?? false }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
        if context.channel.isWritable { partner?.partnerBecameWritable() }
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
        partner = nil
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) { partner?.partnerWrite(data) }
    func channelReadComplete(context: ChannelHandlerContext) { partner?.partnerFlush() }
    func channelInactive(context: ChannelHandlerContext) { partner?.partnerCloseFull() }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let event = event as? ChannelEvent, case .inputClosed = event { partner?.partnerWriteEOF() }
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) { partner?.partnerCloseFull() }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable { partner?.partnerBecameWritable() }
    }

    func read(context: ChannelHandlerContext) {
        if let partner, partner.partnerWritable {
            context.read()
        } else {
            pendingRead = true
        }
    }
}
