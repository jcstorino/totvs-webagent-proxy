import Foundation
import Security
import Darwin
import Network

let listenPort: UInt16 = 21021
let agentPort: UInt16 = 21022
let tlsPort: UInt16 = 21023
let shutdownDelay: TimeInterval = 60
let agentPath = "/Applications/web-agent.app/Contents/MacOS/web-agent"
let certPath = "/Applications/web-agent.app/Contents/MacOS/totvs_certificate.crt"
let keyPath = "/Applications/web-agent.app/Contents/MacOS/totvs_certificate_key.pem"
let logPath = NSHomeDirectory() + "/Library/Logs/totvs-webagent-proxy.log"
let proxyVersion = "0.1.0"

func log(_ message: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) [proxy] \(message)\n"
    FileHandle.standardOutput.write(line.data(using: .utf8)!)
    if let handle = FileHandle(forWritingAtPath: logPath) { handle.seekToEndOfFile(); handle.write(line.data(using: .utf8)!); handle.closeFile() }
}

func portOpen(_ port: UInt16) -> Bool {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var timeout = timeval(tv_sec: 0, tv_usec: 200_000)
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
    return withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 } }
}

func printHelp() {
    print("""
Uso: totvs-webagent-proxy <comando>

Comandos:
  start             inicia o proxy em primeiro plano
  status            mostra o estado das portas 21021 e 21022
  log               acompanha o log em tempo real
  version, -v       mostra a versão instalada
  help, -h          mostra esta ajuda
""")
}

switch CommandLine.arguments.dropFirst().first {
case "status":
    let proxyRunning = portOpen(listenPort)
    print("Proxy 21021: \(proxyRunning ? "running" : "stopped")")
    print("WebAgent 21022: \(portOpen(agentPort) ? "running" : "stopped")")
    exit(proxyRunning ? 0 : 1)
case "log":
    let tail = Process()
    tail.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
    tail.arguments = ["-f", logPath]
    tail.standardOutput = FileHandle.standardOutput
    tail.standardError = FileHandle.standardError
    try? tail.run()
    tail.waitUntilExit()
    exit(tail.terminationStatus)
case "version", "--version", "-v":
    print("totvs-webagent-proxy \(proxyVersion)")
    exit(0)
case "help", "--help", "-h":
    printHelp()
    exit(0)
case nil, "start":
    break
default:
    printHelp()
    exit(64)
}

final class AgentManager {
    private let lock = NSLock()
    private var process: Process?
    private var active = 0
    private var generation = 0

    func ensure(_ completion: @escaping (Bool) -> Void) {
        lock.lock()
        if portOpen(agentPort) { lock.unlock(); completion(true); return }
        if process?.isRunning == true { lock.unlock(); wait(completion); return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: agentPath)
        process.arguments = ["--tray", "--port", String(agentPort), "--locallog", "1"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            self.process = process
            log("WebAgent iniciado (PID \(process.processIdentifier))")
            lock.unlock()
            wait(completion)
        } catch {
            lock.unlock()
            log("Falha ao iniciar WebAgent: \(error)")
            completion(false)
        }
    }

    private func wait(_ completion: @escaping (Bool) -> Void) {
        DispatchQueue.global().async {
            for _ in 0..<100 {
                if portOpen(agentPort) { completion(true); return }
                usleep(50_000)
            }
            completion(false)
        }
    }

    func opened() { lock.lock(); active += 1; generation += 1; let count = active; lock.unlock(); log("Conexões ativas: \(count)") }
    func closed() {
        lock.lock(); active = max(0, active - 1); let count = active
        guard count == 0 else { lock.unlock(); log("Conexões ativas: \(count)"); return }
        generation += 1; let token = generation; lock.unlock()
        log("Conexões ativas: 0; shutdown em 60s")
        DispatchQueue.global().asyncAfter(deadline: .now() + shutdownDelay) { [weak self] in self?.shutdown(token) }
    }
    private func shutdown(_ token: Int) {
        lock.lock()
        guard active == 0, generation == token, let process, process.isRunning else { lock.unlock(); return }
        self.process = nil
        lock.unlock()
        log("Encerrando WebAgent (PID \(process.processIdentifier))")
        process.terminate()
    }
}

func pemData(_ path: String) -> Data? {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
    return Data(base64Encoded: text.split(separator: "\n").filter { !$0.hasPrefix("-") }.joined())
}

func tlsIdentity() -> SecIdentity? {
    guard let certificateData = pemData(certPath), let keyData = pemData(keyPath), let certificate = SecCertificateCreateWithData(nil, certificateData as CFData) else { return nil }
    let attributes = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeyClass as String: kSecAttrKeyClassPrivate] as CFDictionary
    guard let key = SecKeyCreateWithData(keyData as CFData, attributes, nil) else { return nil }
    return SecIdentityCreate(nil, certificate, key)
}

func sendAll(_ fd: Int32, _ data: UnsafeRawPointer, _ length: Int) -> Bool {
    var sent = 0
    while sent < length {
        let result = send(fd, data.advanced(by: sent), length - sent, 0)
        if result <= 0 { return false }
        sent += result
    }
    return true
}

func relayPlain(_ client: Int32, _ upstream: Int32) {
    DispatchQueue.global().async {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true { let count = recv(client, &buffer, buffer.count, 0); if count <= 0 || !buffer.withUnsafeBytes({ sendAll(upstream, $0.baseAddress!, count) }) { break } }
        shutdown(upstream, SHUT_WR)
    }
    var buffer = [UInt8](repeating: 0, count: 65_536)
    while true { let count = recv(upstream, &buffer, buffer.count, 0); if count <= 0 || !buffer.withUnsafeBytes({ sendAll(client, $0.baseAddress!, count) }) { break } }
    shutdown(client, SHUT_WR)
}

func connectUpstream() -> Int32? {
    let upstream = socket(AF_INET, SOCK_STREAM, 0)
    guard upstream >= 0 else { return nil }
    var target = sockaddr_in()
    target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    target.sin_family = sa_family_t(AF_INET)
    target.sin_port = agentPort.bigEndian
    inet_pton(AF_INET, "127.0.0.1", &target.sin_addr)
    guard withUnsafePointer(to: &target, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(upstream, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }) == 0 else { close(upstream); return nil }
    log("Conexão upstream 127.0.0.1:\(agentPort)")
    return upstream
}

func receiveTLS(_ connection: NWConnection, _ upstream: Int32) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { content, _, complete, error in
        if let content, !content.isEmpty { _ = content.withUnsafeBytes { sendAll(upstream, $0.baseAddress!, content.count) } }
        if complete || error != nil { shutdown(upstream, SHUT_WR); return }
        receiveTLS(connection, upstream)
    }
}

func handleTLSConnection(_ connection: NWConnection) {
    var upstream: Int32 = -1
    connection.stateUpdateHandler = { state in
        switch state {
        case .ready:
            log("Handshake TLS concluído")
            guard upstream < 0, let socket = connectUpstream() else { connection.cancel(); return }
            upstream = socket
            receiveTLS(connection, socket)
            DispatchQueue.global().async {
                var buffer = [UInt8](repeating: 0, count: 65_536)
                while true {
                    let count = recv(socket, &buffer, buffer.count, 0)
                    if count <= 0 { break }
                    connection.send(content: Data(buffer[0..<count]), completion: .contentProcessed { error in if let error { log("Erro TLS: \(error)") } })
                }
                close(socket)
                connection.cancel()
            }
        case .failed(let error): log("Erro TLS: \(error)")
        default: break
        }
    }
    connection.start(queue: .global())
}

func startTLSListener() throws {
    guard let identity = tlsIdentity() else { throw NSError(domain: "WebAgentProxy", code: 1, userInfo: [NSLocalizedDescriptionKey: "Não foi possível carregar a identidade TLS"]) }
    guard let protocolIdentity = sec_identity_create(identity) else { throw NSError(domain: "WebAgentProxy", code: 2, userInfo: [NSLocalizedDescriptionKey: "Não foi possível converter a identidade TLS"]) }
    let tls = NWProtocolTLS.Options()
    sec_protocol_options_set_local_identity(tls.securityProtocolOptions, protocolIdentity)
    let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: tlsPort)!)
    let listener = try NWListener(using: parameters)
    listener.newConnectionHandler = handleTLSConnection
    listener.stateUpdateHandler = { state in if case .failed(let error) = state { log("Listener TLS falhou: \(error)") } }
    listener.start(queue: .global())
    log("Identidade TLS carregada; listener WSS interno em 127.0.0.1:\(tlsPort)")
    tlsListener = listener
}

var tlsListener: NWListener?

do { try startTLSListener() } catch { fatalError("TLS indisponível: \(error.localizedDescription)") }
let manager = AgentManager()
let server = socket(AF_INET, SOCK_STREAM, 0)
guard server >= 0 else { fatalError("Não foi possível criar o listener") }
var yes: Int32 = 1
setsockopt(server, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
var address = sockaddr_in()
address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
address.sin_family = sa_family_t(AF_INET)
address.sin_port = listenPort.bigEndian
inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
guard withUnsafePointer(to: &address, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(server, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }) == 0 else { fatalError("Porta 21021 já está em uso") }
guard listen(server, 128) == 0 else { fatalError("Não foi possível escutar a porta 21021") }
FileManager.default.createFile(atPath: logPath, contents: nil)
log("Escutando 127.0.0.1:\(listenPort)")

while true {
    var peer = sockaddr()
    var length = socklen_t(MemoryLayout<sockaddr>.size)
    let client = accept(server, &peer, &length)
    if client < 0 { continue }
    DispatchQueue.global().async {
        manager.ensure { available in
            guard available else { log("WebAgent não respondeu na 21022"); close(client); return }
            manager.opened()
            defer { close(client); manager.closed() }
            var prefix = [UInt8](repeating: 0, count: 2)
            let received = recv(client, &prefix, prefix.count, MSG_PEEK)
            let tls = received == 2 && prefix[0] == 0x16 && prefix[1] == 0x03
            let upstream = socket(AF_INET, SOCK_STREAM, 0)
            guard upstream >= 0 else { return }
            defer { close(upstream) }
            var target = sockaddr_in()
            target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            target.sin_family = sa_family_t(AF_INET)
            target.sin_port = (tls ? tlsPort : agentPort).bigEndian
            inet_pton(AF_INET, "127.0.0.1", &target.sin_addr)
            guard withUnsafePointer(to: &target, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(upstream, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }) == 0 else { log("Falha conectando ao \(tls ? "listener TLS" : "WebAgent")"); return }
            if tls { log("WSS detectado"); relayPlain(client, upstream) } else { log("WS detectado"); log("Conexão upstream 127.0.0.1:\(agentPort)"); relayPlain(client, upstream) }
        }
    }
}
