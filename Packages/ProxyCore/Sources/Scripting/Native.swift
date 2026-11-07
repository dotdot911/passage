import Foundation
import JavaScriptCore

/// Moves bytes between Swift and JavaScript `Uint8Array`s.
enum Bytes {
    static func make(_ data: Data, in context: JSContext?) -> JSValue {
        guard let context else { fatalError("Bytes.make called outside a JavaScript call") }
        var exception: JSValueRef?
        guard let array = JSObjectMakeTypedArray(context.jsGlobalContextRef, kJSTypedArrayTypeUint8Array, data.count, &exception)
        else { return JSValue(undefinedIn: context) }
        if !data.isEmpty, let ptr = JSObjectGetTypedArrayBytesPtr(context.jsGlobalContextRef, array, &exception) {
            data.withUnsafeBytes { ptr.copyMemory(from: $0.baseAddress!, byteCount: data.count) }
        }
        return JSValue(jsValueRef: array, in: context)
    }

    /// The bytes of a `Uint8Array`; any other value reads as empty.
    static func read(_ value: JSValue?) -> Data {
        guard let value, let context = value.context, value.isObject else { return Data() }
        let ctx = context.jsGlobalContextRef
        var exception: JSValueRef?
        let ref = value.jsValueRef
        guard JSValueGetTypedArrayType(ctx, ref, &exception) == kJSTypedArrayTypeUint8Array,
              let object = JSValueToObject(ctx, ref, &exception) else { return Data() }
        let count = JSObjectGetTypedArrayByteLength(ctx, object, &exception)
        let offset = JSObjectGetTypedArrayByteOffset(ctx, object, &exception)
        // The pointer is the start of the underlying buffer, not of this view.
        guard count > 0, let ptr = JSObjectGetTypedArrayBytesPtr(ctx, object, &exception) else { return Data() }
        return Data(bytes: ptr + offset, count: count)
    }
}

/// `JSContextGroupSetExecutionTimeLimit` is exported by JavaScriptCore but missing from its public headers.
enum TimeLimit {
    private typealias ShouldTerminate = @convention(c) (JSContextRef?, UnsafeMutableRawPointer?) -> Bool
    private typealias SetLimit = @convention(c) (JSContextGroupRef, Double, ShouldTerminate?, UnsafeMutableRawPointer?) -> Void

    /// Stops any script of `context`'s group that runs longer than `seconds`. Returns false when unavailable.
    static func set(_ seconds: TimeInterval, on context: JSContext) -> Bool {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "JSContextGroupSetExecutionTimeLimit") else { return false }
        let setLimit = unsafeBitCast(symbol, to: SetLimit.self)
        setLimit(JSContextGetGroup(context.jsGlobalContextRef), seconds, { _, _ in true }, nil)
        return true
    }
}
