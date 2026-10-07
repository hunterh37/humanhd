# vision-optimize 2026-10-07 (HumanHD package)

Applied
- Sources/HumanCore/Anim/Animator.swift plantFeet: perf. Skips the dead `p.world(s)` FK recompute after the last foot (one full-skeleton FK + array alloc per frame per character).
- Sources/HumanCore/Rig/Skeleton.swift DualQuat.blend: bug. All-zero weights divided by 0 and produced NaN vertices; now returns q[0].

Skipped RISKY
- Animator.swift update: `Pose(boneCount:)` allocated per frame; reuse needs reset semantics review.
- Animator.swift update: `expression.units.mapValues` and `Set(exprWeights.keys)` allocate per frame at LOD 0.
- Skeleton.swift Pose.skinning: `rest.inverse` per bone per frame; caching needs a Skeleton field (API change).
- HumanKit/HumanCharacter.swift, GPUSkinner.swift, HumanCore/Anim/Anatomy.swift: uncommitted user work; not touched.

Architecture notes
- Cache inverse-rest transforms on Skeleton; reuse world/skinning buffers per character.
- Profile with RealityKit Trace: target 90 fps, < 11 ms frame, zero steady-state allocations in HumanSystem.

Build: clean before/after. Warnings: 1 pre-existing (Motion.swift:27 Sendable). Tests: swift test, 14 XCTest pass.
