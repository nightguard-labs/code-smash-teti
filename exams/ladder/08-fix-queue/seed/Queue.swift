struct Queue<T> {
    private var items: [T] = []

    mutating func enqueue(_ x: T) {
        items.append(x)
    }

    func dequeue() -> T? {
        if items.isEmpty { return nil }
        return items.removeLast()
    }

    func peek() -> T? {
        return items.first
    }

    var count: Int { items.count }
    var isEmpty: Bool { items.count == 0 }
}
