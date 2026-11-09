public import struct Foundation.Data
public import Stoic
public import StoicXPC

/// The build both sides were compiled with.
public enum Build {
    public static let id = "integration-1"
}

extension Backend {
    public static let integration = Backend.system("xpc.integration")
}

/// The service's methods.
public enum IntegrationAPI {
    /// Answers with the service's pid.
    public static let pid = XPCMethod<XPCEmpty, Int32, Never>(Backend.integration.readOnly("pid"))
    /// Exits the process before answering: a crash mid-request.
    public static let crash = XPCMethod<XPCEmpty, XPCEmpty, Never>(Backend.integration.notRepeatable("crash"))
    /// Blocks its thread for the given seconds, ignoring cancellation.
    public static let block = XPCMethod<Int, XPCEmpty, Never>(Backend.integration.readOnly("block", length: .long))
    /// Waits, cooperatively, until cancelled; answers whether it was.
    public static let wait = XPCMethod<XPCEmpty, Bool, Never>(Backend.integration.readOnly("wait", length: .long))
    /// From now on the service does not exit when asked.
    public static let refuseToExit = XPCMethod<XPCEmpty, XPCEmpty, Never>(Backend.integration.idempotent("refuse_to_exit"))
    /// Answers with a megabyte, as `Data`.
    public static let blob = XPCMethod<Int, Data, Never>(Backend.integration.readOnly("blob"))
}
