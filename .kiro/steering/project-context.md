# Project context

This is a modern multi-module Android project written in Kotlin and Jetpack Compose:
- `app`: phone/tablet application using Material 3 Compose.
- `wear`: standalone Wear OS application using `androidx.wear.compose`, designed for round and square screens.

## Conventions
- Use Kotlin official style and Kotlin DSL (`*.gradle.kts`).
- Keep dependency versions in `gradle/libs.versions.toml`.
- Prefer small, testable composables and state hoisting.
- Keep Android permissions minimal; do not add network or sensor access without a requirement.
- Preserve the Wear OS manifest feature and standalone metadata.
- Keep `.kiro/steering/` and other Kiro configuration under version control; ignore only generated caches.
