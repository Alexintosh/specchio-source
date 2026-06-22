struct TreeDiff {
    let added: [AccessibilityElement]
    let removed: [AccessibilityElement]
    let changed: [(old: AccessibilityElement, new: AccessibilityElement)]
    let unchanged: Int

    var hasChanges: Bool { !added.isEmpty || !removed.isEmpty || !changed.isEmpty }
}

class AccessibilityTreeDiffer {
    func diff(old: AccessibilityElement, new: AccessibilityElement) -> TreeDiff {
        var added: [AccessibilityElement] = []
        var removed: [AccessibilityElement] = []
        var changed: [(AccessibilityElement, AccessibilityElement)] = []
        var unchanged = 0

        diffRecursive(old: old, new: new,
                      added: &added, removed: &removed,
                      changed: &changed, unchanged: &unchanged)

        return TreeDiff(added: added, removed: removed, changed: changed, unchanged: unchanged)
    }

    private func diffRecursive(old: AccessibilityElement, new: AccessibilityElement,
                                added: inout [AccessibilityElement],
                                removed: inout [AccessibilityElement],
                                changed: inout [(AccessibilityElement, AccessibilityElement)],
                                unchanged: inout Int) {
        if old.label != new.label || old.value != new.value || old.frame != new.frame {
            changed.append((old, new))
        } else {
            unchanged += 1
        }

        let oldChildren = old.children
        let newChildren = new.children
        let maxCount = max(oldChildren.count, newChildren.count)
        for i in 0..<maxCount {
            if i >= oldChildren.count {
                added.append(newChildren[i])
            } else if i >= newChildren.count {
                removed.append(oldChildren[i])
            } else {
                diffRecursive(old: oldChildren[i], new: newChildren[i],
                              added: &added, removed: &removed,
                              changed: &changed, unchanged: &unchanged)
            }
        }
    }
}
