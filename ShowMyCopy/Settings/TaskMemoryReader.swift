// `mach_task_self_` is a C global that Swift 6 treats as shared mutable state. It is set once when the process
// starts and only read here; Apple DTS suggests this import for it.
@preconcurrency import Darwin

/// Reads the app's memory footprint from the kernel: `phys_footprint` of `TASK_VM_INFO`, the number Activity
/// Monitor shows as Memory. Unlike the resident size, it counts compressed and swapped-out memory the app owns
/// and leaves out shared pages of system frameworks.
struct TaskMemoryReader: MemoryUsageReading {
    func residentBytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { words in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), words, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            return nil
        }
        return info.phys_footprint
    }
}
