# Realism v2 context (branch realism-v2)

Repo: /Users/hunter/Dev/HumanHD (SwiftPM). Build: `swift build -c release --product humanhd 2>&1 | grep -E "error:|warning:|BUILD|Build of" | head -40`.
Tests: `swift test 2>&1 | tail -15`. Never commit out/. Uncommitted pre-existing edits on the branch belong to the user; keep them.
Render: `.build/release/humanhd look [male] [outfit-preset] [hair=<preset>] [seed=N] [face] [az=deg] [out=...]` (Render.swift:231), PNG then Read it.
`humanhd hoops out=...`, `humanhd boxer`, `humanhd gate` exist. Outfit.presets and HairStyle.presets are the name tables.
File map:
- Outfit: Sources/HumanCore/Outfit/{Garment.swift (fit, skirtTube :542), GarmentClip.swift, GarmentShoe.swift, Wardrobe.swift}
- Body: Sources/HumanCore/Body/{BodyShape,Appearance,HumanSpec,SkinFields}.swift (ancestry sliders african/asian/caucasian)
- Hair: Sources/HumanCore/Hair/Hair.swift; HumanMaterials/{StrandPainter,EyePainter,SkinPainter}.swift
- Anim/face: Sources/HumanCore/Anim/Anatomy.swift, Motion.swift, Animator.swift
Visual gate: 1024px stills (look command), scored 0-10 against a written checklist in notes/visual-log.md.
Pass = every checklist item >= 8. Max 3 iterations per area, fix top 3 defects per iteration. Log each iteration in notes/visual-log.md under a heading for the area.
Ownership (disjoint): waist/skirt = Garment.swift+GarmentClip.swift; shoes = GarmentShoe.swift; faces/hair = Body/ and Hair/ and HumanMaterials/; expressions = Anim/.
If a build error is in a file owned by another agent, wait 60s and rebuild. Add a headless unit test per fix in Tests/HumanHDTests/.
Do not commit; the orchestrator commits. Final reply: one line, stat register.
