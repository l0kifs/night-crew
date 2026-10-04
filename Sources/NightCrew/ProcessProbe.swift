import Darwin
import NightCrewCore

/// SPEC §5.1: the current user's processes via libproc and sysctl. Processes that cannot be read are skipped.
final class ProcessProbe: ProcessProbing {
    private let uid = getuid()
    private let timebase: mach_timebase_info_data_t = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return timebase
    }()
    /// One `KERN_ARGMAX`-sized buffer, reused for every `KERN_PROCARGS2` read.
    private var argumentBuffer: [UInt8] = {
        var argmax: Int32 = 0
        var size = MemoryLayout<Int32>.size
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        return [UInt8](repeating: 0, count: sysctl(&mib, 2, &argmax, &size, nil, 0) == 0 ? Int(argmax) : 1 << 20)
    }()

    func processes() -> [ProcessRecord] {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        guard capacity > 64 else { return [] }
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = pids.withUnsafeMutableBufferPointer {
            proc_listallpids($0.baseAddress, Int32($0.count * MemoryLayout<pid_t>.size))
        }
        return pids.prefix(Int(max(count, 0))).compactMap(record)
    }

    private func record(_ pid: pid_t) -> ProcessRecord? {
        guard pid > 0 else { return nil }
        var bsd = proc_bsdinfo()
        let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, bsdSize) == bsdSize, bsd.pbi_uid == uid else { return nil }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let pathLength = proc_pidpath(pid, &path, UInt32(path.count))
        return ProcessRecord(pid: pid, ppid: Int32(bsd.pbi_ppid),
                             executablePath: pathLength > 0 ? String(cString: path) : "",
                             arguments: arguments(of: pid), cwd: cwd(of: pid), cpuSeconds: cpuSeconds(of: pid))
    }

    private func cpuSeconds(of pid: pid_t) -> Double? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return nil }
        return MachTime.seconds(ticks: info.pti_total_user + info.pti_total_system,
                                numer: timebase.numer, denom: timebase.denom)
    }

    private func cwd(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return path.isEmpty ? nil : path
    }

    /// `KERN_PROCARGS2` layout: argc (Int32), exec path, NUL padding, then argc NUL-terminated strings.
    private func arguments(of pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = argumentBuffer.count
        guard sysctl(&mib, 3, &argumentBuffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        return argumentBuffer.withUnsafeBytes { raw in
            let argc = Int(raw.loadUnaligned(as: Int32.self))
            var index = MemoryLayout<Int32>.size
            while index < size && raw[index] != 0 { index += 1 }
            while index < size && raw[index] == 0 { index += 1 }
            var arguments: [String] = []
            while arguments.count < argc && index < size {
                let start = index
                while index < size && raw[index] != 0 { index += 1 }
                arguments.append(String(decoding: raw[start..<index], as: UTF8.self))
                index += 1
            }
            return arguments
        }
    }
}
