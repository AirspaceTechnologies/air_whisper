import AppKit
import AirWhisperCore

@MainActor
final class TextInsertion {
    struct ClipboardSnapshot {
        let items: [[NSPasteboard.PasteboardType: Data]]

        init?(_ pasteboard: NSPasteboard) {
            let originalCount = pasteboard.changeCount
            var saved: [[NSPasteboard.PasteboardType: Data]] = []
            for item in pasteboard.pasteboardItems ?? [] {
                var values: [NSPasteboard.PasteboardType: Data] = [:]
                for type in item.types {
                    // A promised/unreadable representation must not be silently discarded.
                    guard let data = item.data(forType: type) else { return nil }
                    values[type] = data
                }
                saved.append(values)
            }
            guard pasteboard.changeCount == originalCount else { return nil }
            items = saved
        }

        func restore(to pasteboard: NSPasteboard) {
            let objects = items.map { values in
                let item = NSPasteboardItem()
                for (type, data) in values { item.setData(data, forType: type) }
                return item
            }
            pasteboard.clearContents()
            if !objects.isEmpty { pasteboard.writeObjects(objects) }
        }
    }

    private var pendingRestore: (() -> Void)?
    private var restoreTask: Task<Void, Never>?

    func insert(_ text: String, target: InsertionTarget, mode: PasteMode, restoreDelay: TimeInterval) -> Bool {
        guard AXIsProcessTrusted() else {
            DictationDiagnostics.insertion.error("insertion_blocked accessibility_denied")
            return false
        }
        guard target.isStillFocused() else {
            DictationDiagnostics.insertion.notice("insertion_blocked focus_unavailable_or_changed")
            return false
        }
        restoreClipboardNow()
        if mode == .keystrokes { return type(text, target: target) }
        let pasteboard = NSPasteboard.general
        let originalCount = pasteboard.changeCount
        guard let saved = ClipboardSnapshot(pasteboard) else {
            DictationDiagnostics.insertion.notice("typing_fallback clipboard_snapshot_unavailable")
            return type(text, target: target)
        }
        // Reading promised clipboard data may run another process; recheck focus afterwards.
        guard target.isStillFocused() else {
            DictationDiagnostics.insertion.notice("insertion_blocked focus_changed_during_snapshot")
            return false
        }
        guard pasteboard.changeCount == originalCount else {
            DictationDiagnostics.insertion.notice("typing_fallback clipboard_changed_during_snapshot")
            return type(text, target: target)
        }
        let clearedCount = pasteboard.clearContents()
        guard pasteboard.changeCount == clearedCount else {
            DictationDiagnostics.insertion.notice("typing_fallback clipboard_ownership_lost")
            return type(text, target: target)
        }
        guard pasteboard.setString(text, forType: .string) else {
            DictationDiagnostics.insertion.error("clipboard_write_failed")
            // A failed write while we still own the empty generation must not erase the
            // user's snapshot. Another owner's newer generation is always left alone.
            if pasteboard.changeCount == clearedCount,
               pasteboard.string(forType: .string) == nil,
               (pasteboard.types ?? []).allSatisfy({ $0 == .string }) {
                saved.restore(to: pasteboard)
            }
            return false
        }
        let count = pasteboard.changeCount
        guard count == clearedCount, pasteboard.string(forType: .string) == text else {
            DictationDiagnostics.insertion.notice("insertion_blocked clipboard_changed_before_paste")
            return false
        }
        let restore: () -> Void = {
            guard pasteboard.changeCount == count, pasteboard.string(forType: .string) == text else {
                DictationDiagnostics.insertion.notice("clipboard_restore_skipped newer_contents")
                return
            }
            saved.restore(to: pasteboard)
            DictationDiagnostics.insertion.notice("clipboard_restored")
        }
        pendingRestore = restore
        guard target.isStillFocused(),
              let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            DictationDiagnostics.insertion.notice("insertion_blocked focus_changed_or_event_unavailable")
            restoreClipboardNow()
            return false
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        DictationDiagnostics.insertion.notice("paste_events_posted target_pid=\(target.processID) restore_delay=\(restoreDelay) delivery_unverified=true")
        restoreTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0.1, restoreDelay) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.restoreClipboardNow()
        }
        return true
    }

    func restoreClipboardNow() {
        restoreTask?.cancel()
        restoreTask = nil
        pendingRestore?()
        pendingRestore = nil
    }

    private func type(_ text: String, target: InsertionTarget) -> Bool {
        guard let source = CGEventSource(stateID: .privateState) else {
            DictationDiagnostics.insertion.error("typing_event_source_unavailable")
            return false
        }
        // Each event gets complete Unicode scalars, so a surrogate pair is never split.
        var chunk: [UniChar] = []
        func sendChunk() -> Bool {
            guard target.isStillFocused(),
                  let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                DictationDiagnostics.insertion.notice("typing_interrupted focus_changed_or_event_unavailable")
                return false
            }
            chunk.withUnsafeBufferPointer { buffer in
                down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress!)
                up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress!)
            }
            down.flags = []
            up.flags = []
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            chunk.removeAll(keepingCapacity: true)
            return true
        }
        for scalar in text.unicodeScalars {
            let units = Array(String(scalar).utf16)
            if chunk.count + units.count > 20, !sendChunk() { return false }
            chunk.append(contentsOf: units)
        }
        let posted = chunk.isEmpty || sendChunk()
        DictationDiagnostics.insertion.notice("typing_events_finished target_pid=\(target.processID) posted=\(posted) delivery_unverified=true")
        return posted
    }
}
