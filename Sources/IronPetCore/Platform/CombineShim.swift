// Linux has no Combine. These two names let classes that declare `ObservableObject` and `@Published` compile there. Nothing on
// Linux observes them, so they only hold values. Apple platforms use Combine's own types.
#if !canImport(Combine)
package protocol ObservableObject: AnyObject {}

@propertyWrapper
package struct Published<Value> {
    package var wrappedValue: Value

    package init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
}

extension Published: Sendable where Value: Sendable {}
#endif
