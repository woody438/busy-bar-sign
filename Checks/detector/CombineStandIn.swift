// Linux has no Combine. CallDetector only needs these two names from it, so
// the check builds this as a module called Combine. Never part of the app.
public protocol ObservableObject: AnyObject {}

@propertyWrapper
public struct Published<Value> {
    public var wrappedValue: Value
    public init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
}
