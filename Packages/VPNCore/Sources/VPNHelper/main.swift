import Foundation
import VPNCore
import VPNHelperCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// Privileged helper of VPNforYou, started by launchd as root.
// See HelperProtocol for paths and the security model.

guard let arguments = HelperArguments.parse(CommandLine.arguments) else {
    FileHandle.standardError.write(Data("usage: vpnforyou-helper --allowed-uid <uid> [--socket path] [--core path] [--run-dir path]\n".utf8))
    exit(64)
}

umask(0o077)
let supervisor = CoreSupervisor(corePath: arguments.corePath, runDirectory: arguments.runDirectory)
let server = HelperServer(socketPath: arguments.socketPath, allowedUID: arguments.allowedUID,
                          handler: HelperHandler(supervisor: supervisor))
do {
    try server.open()
} catch {
    FileHandle.standardError.write(Data("vpnforyou-helper: \(error)\n".utf8))
    exit(1)
}

// Stop the core when launchd stops the helper (uninstall, shutdown).
signal(SIGTERM, SIG_IGN)
let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
termination.setEventHandler {
    supervisor.stop()
    unlink(arguments.socketPath)
    exit(0)
}
termination.resume()

FileHandle.standardError.write(Data("vpnforyou-helper \(HelperProtocol.version) ready\n".utf8))
Thread.detachNewThread {
    server.serve()
}
dispatchMain()
