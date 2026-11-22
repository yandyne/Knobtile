import Foundation
import IOKit
import IOKit.serial

/// POSIX serial port for the Core's USB CDC interface (VID 0x0483 / PID 0xA2C5).
public final class SerialPort {
    static let vendorID = 0x0483, productID = 0xA2C5

    /// Callout device path (/dev/cu.usbmodem…) of the first attached Core, if any.
    static func findCore() -> String? { find(vendor: vendorID, product: productID) }

    /// Callout device path of the first attached USB serial device with this vendor / product id.
    public static func find(vendor: Int, product: Int) -> String? {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(kIOSerialBSDServiceValue), &it) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(it) }
        while case let svc = IOIteratorNext(it), svc != 0 {
            defer { IOObjectRelease(svc) }
            func prop(_ key: String) -> Any? {
                IORegistryEntrySearchCFProperty(svc, kIOServicePlane, key as CFString, nil, IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents))
            }
            guard prop("idVendor") as? Int == vendor, prop("idProduct") as? Int == product,
                  let path = prop(kIOCalloutDeviceKey) as? String else { continue }
            return path
        }
        return nil
    }

    private let fd: Int32
    private let source: DispatchSourceRead
    public var onData: ((Data) -> Void)?
    public var onClose: (() -> Void)?

    public init(path: String, queue: DispatchQueue) throws {
        fd = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var t = termios()
        tcgetattr(fd, &t)
        cfmakeraw(&t)
        t.c_cflag |= tcflag_t(CLOCAL | CREAD)
        tcsetattr(fd, TCSANOW, &t)
        var speed: speed_t = 300000
        _ = ioctl(fd, 0x80045402, &speed) // IOSSIOSPEED (not imported in Swift); CDC ignores baud but the service sets it
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.setCancelHandler { [fd] in _ = Darwin.close(fd) }
        source.resume()
    }

    private func readAvailable() {
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = read(fd, &buf, buf.count)
        if n > 0 { onData?(Data(buf[0..<n])) }
        else if n == 0 || (errno != EAGAIN && errno != EINTR) { close() } // device unplugged
    }

    /// Writes run on their own queue: a screen image takes seconds to drain, and on the read queue it held back every button report behind it,
    /// so a short press's release arrived after the hold delay and opened the profile list (2026-11-16, "자주 그럼").
    /// Everything else goes ahead of a screen image's chunks, and a new image drops the rest of an unfinished one: switching profiles fast
    /// queued whole images (≈4 s each) and the LEDs waited behind them.
    private let writer = DispatchQueue(label: "corev2.write")
    private let lock = NSLock()
    private var urgent: [Data] = [], screen: [Data] = [], draining = false
    public func write(_ data: Data) { enqueue { urgent.append(data) } }
    func writeScreen(_ frames: [Data]) { enqueue { screen = frames } }
    private func enqueue(_ add: () -> Void) {
        lock.lock(); add(); let start = !draining; draining = true; lock.unlock()
        if start { writer.async { [self] in drain() } }
    }
    private func drain() {
        while true {
            lock.lock()
            let d = !urgent.isEmpty ? urgent.removeFirst() : !screen.isEmpty ? screen.removeFirst() : nil
            if d == nil { draining = false }
            lock.unlock()
            guard let d else { return }
            send(d)
        }
    }
    private func send(_ data: Data) {
        // The firmware wants ≤512-byte chunks with a short gap (see service's queueWrite).
        var off = 0
        while off < data.count, !source.isCancelled {
            let end = min(off + 512, data.count)
            // The port is non-blocking: a write can be partial or EAGAIN while the UART drains (115 KB screen ≈ 4 s at 300 kbaud).
            data[off..<end].withUnsafeBytes { buf in
                var sent = 0
                while sent < buf.count {
                    let n = Darwin.write(fd, buf.baseAddress! + sent, buf.count - sent)
                    if n > 0 { sent += n; continue }
                    if n < 0 && errno != EAGAIN { NSLog("serial write failed: %d", errno); return }
                    var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0); poll(&p, 1, 1000)
                }
            }
            off = end
            if off < data.count { usleep(1000) }
        }
    }

    public func close() {
        guard !source.isCancelled else { return }
        source.cancel()
        onClose?()
    }

    deinit { close() }
}
