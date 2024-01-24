#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// libc's `uname` wrapper
struct UnixName {
  let release: String
  let machine: String

  init(info: utsname) {
    var info = info

    func cloneCString<CString>(_ value: inout CString) -> String {
      withUnsafePointer(to: &value) {
        String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
      }
    }
    self.release = cloneCString(&info.release)
    self.machine = cloneCString(&info.machine)
  }

  static let current: UnixName! = {
    var info = utsname()
    guard uname(&info) == 0 else { return nil }
    return UnixName(info: info)
  }()
}
