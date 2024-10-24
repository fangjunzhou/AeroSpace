import Foundation
import AppKit
import Common

class ThreadSafeValue<T> {
    private var _value: T
    private let lock = NSLock()

    init(_ value: T) {
        self._value = value
    }

    var value: T {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _value
        }
        set {
            lock.lock()
            _value = newValue
            lock.unlock()
        }
    }
}

class TimeoutDetector {
    var didTimeout: Bool = false
    var semaphore: DispatchSemaphore = DispatchSemaphore(value: 0)

    func run(task: @escaping (TimeoutDetector) -> Void, onFinish: @escaping (TimeoutDetector) -> Void = {td in}) {
        DispatchQueue.global(qos: .userInteractive).async {
            task(self)
            self.semaphore.signal()
            onFinish(self)
        }
    }

    func wait(timeout: TimeInterval = 0.1) {
        if timeout == 0 {
            self.semaphore.wait()
            return
        }

        let result = self.semaphore.wait(timeout: .now() + timeout)
        if result == .timedOut {
            self.didTimeout = true
        }
    }
}

class Debouncer {
    private var workItem: DispatchWorkItem?
    private let queue: DispatchQueue

    init(queue: DispatchQueue = .main) {
        self.queue = queue
    }

    func debounce(delay: Double, action: @escaping () -> Void) {
        // Cancel any existing work item
        workItem?.cancel()

        // Create a new work item
        workItem = DispatchWorkItem(block: action)

        // Schedule the new work item after the delay
        if let workItem = workItem {
            queue.asyncAfter(deadline: .now() + delay, execute: workItem)
        }
    }
}
