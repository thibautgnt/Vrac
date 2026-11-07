import Darwin
import Foundation

/// Listening TCP and bound UDP sockets read through libproc. Only processes the
/// user may inspect are listed; the others fail with EPERM and are skipped.
nonisolated enum PortSampler {
    static func listeningPorts() -> [ListeningPort] {
        var entries: [SocketEntry] = []
        for pid in MonitorSampler.allPIDs() {
            let sockets = sockets(of: pid)
            guard !sockets.isEmpty else { continue }
            let name = MonitorSampler.name(of: pid, path: MonitorSampler.path(of: pid))
            entries += sockets.map { SocketEntry(pid: pid, processName: name, proto: $0.proto, port: $0.port, address: $0.address) }
        }
        return ListeningPort.group(entries)
    }

    private static func sockets(of pid: Int32) -> [(proto: PortProtocol, port: UInt16, address: String)] {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return [] }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.stride)
        let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * MemoryLayout<proc_fdinfo>.stride))
        guard filled > 0 else { return [] }
        var result: [(PortProtocol, UInt16, String)] = []
        for fd in fds.prefix(Int(filled) / MemoryLayout<proc_fdinfo>.stride) where fd.proc_fdtype == PROX_FDTYPE_SOCKET {
            var info = socket_fdinfo()
            let read = proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, Int32(MemoryLayout<socket_fdinfo>.size))
            guard read == MemoryLayout<socket_fdinfo>.size else { continue }
            let socket = info.psi
            if socket.soi_kind == SOCKINFO_TCP, socket.soi_proto.pri_tcp.tcpsi_state == TSI_S_LISTEN {
                let ini = socket.soi_proto.pri_tcp.tcpsi_ini
                result.append((.tcp, port(ini.insi_lport), address(ini)))
            } else if socket.soi_kind == SOCKINFO_IN, socket.soi_protocol == IPPROTO_UDP {
                let ini = socket.soi_proto.pri_in
                // A connected UDP socket is a client, not a service waiting for others.
                guard ini.insi_fport == 0, port(ini.insi_lport) != 0 else { continue }
                result.append((.udp, port(ini.insi_lport), address(ini)))
            }
        }
        return result
    }

    private static func port(_ raw: Int32) -> UInt16 {
        UInt16(bigEndian: UInt16(truncatingIfNeeded: raw))
    }

    private static func address(_ ini: in_sockinfo) -> String {
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        if ini.insi_vflag & UInt8(INI_IPV4) != 0, ini.insi_vflag & UInt8(INI_IPV6) == 0 {
            var addr = ini.insi_laddr.ina_46.i46a_addr4
            inet_ntop(AF_INET, &addr, &buffer, socklen_t(buffer.count))
        } else {
            var addr = ini.insi_laddr.ina_6
            inet_ntop(AF_INET6, &addr, &buffer, socklen_t(buffer.count))
        }
        return String(cString: buffer)
    }
}
