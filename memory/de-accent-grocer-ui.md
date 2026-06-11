---
name: de-accent-grocer-ui
description: User dislikes over-use of the app accent/tint color on Grocer iOS controls
metadata:
  type: feedback
---

In the Grocer iOS app, the user does not want the green app accent/tint applied to most controls (buttons, labels). Default new buttons/labels to neutral (`.foregroundStyle(.primary)` + `.tint(.primary)`), not the app tint.

**Why:** They repeatedly asked to de-accent — first the "History" floating button label, then the per-row "Add" button in the History pane. They find blanket accenting visually noisy.

**How to apply:** When adding glass/standard buttons in views like [AddItemView.swift](apps/ios/Grocer/Views/AddItemView.swift), keep them neutral by default. Reserve the green tint for genuinely primary/confirming actions (e.g. the main "Add to List" button) or where the surrounding code already establishes it. The `tint` passed to `QuantityStepperField` is an existing app-wide pattern — leave it unless told otherwise. Ask/lean neutral rather than accenting "to be safe."
