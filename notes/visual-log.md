# Visual log

## Realism pass, 2026-10-20

Renders in out/realism/ (before-*.png, after-*.png): hoops, boxer, boxer-face, look-male.

Iteration 1. Checklist: skin highlight size, hip to shoulder ratio, jersey fit, hair coverage.
Skin defaults: specular 0.3, roughness scale 1.08, roughness modulated by micro tile, clearcoat only on the oiliest zones, clearcoat roughness 0.36, warmer scatter floor.
Hoops and boxer: hips narrowed, shoulder distance raised. Jersey offset 0.05 to 0.034, shorts 0.03 to 0.026, more fold amplitude. Hoop shoe offset 0.012 to 0.01.
Result: hoops jersey hangs closer, shoulders read wider. Boxer face still glossy from glisten.

Iteration 2. Glisten amount scaled down (roughness 1.08 - 0.42a, specular 0.3 + 0.2a, oil 0.5 + 0.5a).
Result: forehead and chest highlight smaller. Open: crop hair cards leave gaps at the temples; jersey chest follows pectoral bumps; denim renders pale in the look command.

## Face types and hair, 2026-10-27

Renders in out/faces/ (<type>-face.png, <type>-body.png, sheet0/1.png, bodies.png, ropes.png).
Types: eastAsianWoman/Man, blackWoman/Man, southAsianWoman/Man, latinaWoman, latinoMan, whiteWoman/Man, middleEasternWoman/Man (`look <type> [face]`, Sources/HumanCore/Body/FaceTypes.swift).
Checklist (0-10): face shape, eye shape + epicanthic fold, nose, lips, brow, hairline, hair density/shine, skin undertone, ear, jaw, eye gloss, age plausibility.

Iteration 1 scores (all types, typical): face shape 6, eyes/fold 5, nose 6, lips 6, brow 7, hairline 3, hair density/shine 5 (afro wiry, long hair thin cards), undertone 7, ear 7, jaw 6, eye gloss 6, age 7.
Top 3: hairline stair-step edge with temple gaps; afro spiky and sparse; type differences subtle.
Fixes: morph gain 1.5 (clamped to 1), epicanthus 0.9-1.0, scalpHair 0.55, root scalp mask 0.28 to 0.1.

Iteration 2: hairline 4, afro 6, eyes/fold 6, face shape 6.
Fixes: root acceptance ramps with interpolated scalp mask (smoothstep 0.1-0.42), afro density 30 / width 0.028 / curl 0.6 / volume 0.065.

Iteration 3: hairline 5 (edge still crisp at bangs, temples filled), afro 6, braids/locs 4 (render as straight long hair, no rope structure), eye gloss 6.
Fixes: card width near the hairline scaled to 0.4x.

Final: not all items >= 8. Open: hairline still jagged on triangle edges (needs a hairline-aware root band or a painted hairline in SkinFields), braids/locs need helical rope cards, eyes show sky reflection that reads grey on dark irises, face-type morph separation is moderate (modifiers clamp at 1).
Tests: FaceTypeTests (12 presets finite, new hair kinds finite) pass; CoreTests pass.

## Shoes, 2026-10-27

Renders in out/shoes/ (i1 to i4 = iteration 1 to 4 sets; `look <casual|smart|dress> feet az=0|45|90 size=1024`, `hoops views=0|45|90 fy=0.1 dist=1.1 scale=1.6`).
Files: Sources/HumanCore/Outfit/GarmentShoe.swift (rewritten), Wardrobe.swift (sneakers, boots, hoopShoes, new dressShoes, pumps, presets business and heels), Garment.swift (Cut.shoe), Render.swift (`feet`, `size=`), Tests/HumanHDTests/ShoeTests.swift.

Checklist (score 0-10, final = iteration 3 renders, i4):
1. Toe box shape: sneaker 7, boot 6, dress 8, pump 8, hoop 7 (round plan, truncated tip; front face still flat)
2. Heel counter: 7 (outward bump; no separate panel)
3. Midsole thickness and tread edge: 8 (two-tone outsole lip over foam band)
4. Laces and tongue: sneaker 7, hoop 6 (bars, eyestays, standing tongue; tongue is a flat panel)
5. Collar opening: 8 (padded piping hugging the ankle; open throat on loafer and pump)
6. Boot shaft and heel: 6 (shaft tube with lace bars, stacked heel; foot part bulbous)
7. No clipping into ankle or floor: 8 (leg and foot hidden under the shoe; sole on y=0 by test)
8. Size to foot: 8 (length within foot +0.03/+0.045 m by test)
9. Surface quality (no crumple, holes, dark shards): 8 after iteration 3
10. Silhouette read at 3 angles: sneaker 7, boot 6, dress 8, pump 8

Iteration 1 (baseline of rewrite, out/shoes/i1-*): dark slit at toe and heel tips (collapsed end rings), boxy toe, boot shaft detached, rectangular heel-counter patch, dark shards near tongue.
Fixes: toe dome from plan outline, minimum end width, patch removed, boot loft closed under the shaft.
Iteration 2 (i2-*): slit unchanged, toe still square, upper crumpled on hightop.
Fixes: stations stop at u 0.012 and 0.988 with fan caps, envelope smoothing, opening tightened to leg + 5 mm so piping sits on the ankle.
Iteration 3 (i3-*, i4-*): dark cap wedge (outsole role on cap), crumpled hightop upper.
Fixes: caps use the upper material, skinning by height blend of foot and shin bones instead of nearest vertex (cause of crumple), rounder cross section (exponent 2.3), boots drop vamp lace bars.
Open after iteration 3: boot items 1 and 6 and hoop laces score below 8; sneaker tongue is a flat panel; toe front face is a flat cap.

## Hair pass (afro, braids, locs), 2026-10-27
Renders in out/hair/it1-*, it2-*, it3-*, it3b-* (blackWoman, face + body, az 0/45/90, 900x1200). Debug build in /tmp/hhd-hair (release build of RealityHD exceeded 15 min twice and was killed).
Checklist (0-10): hairline, density, strand definition, shine, style accuracy, temple coverage.
Before: hairline 5, braids/locs 4 (straight long hair), afro 6.
Iteration 1: noisy soft hairline acceptance, baby hairs, braid plaits (3 helical strands, 27 mm period), loc ropes (4-blade twisted, tapered), coil frequency/amplitude, strand wave and width variation in StrandPainter.
Scores: hairline 6, density 7, strand definition 6, shine 5, style accuracy braids 7 / locs 6 / afro 6, temple 5.
Top 3: coily zigzag from 4 segs per turn; side/temple sheets from the face-clear x snap and shoulder x clamp; baby hairs too long and comb-like.
Iteration 2: 20 segs and lower coil frequency, coily skips x clamp, baby hairs 4-12 mm and fewer, crown ropes skipped, hairline cards shortened on short styles.
Scores: hairline 6, density 7, strand definition 7, shine 5, braids 8 / locs 7 / afro 7, temple 6.
Iteration 3: coily face-clear pushes x only (layered), locs 4 blades R 10.5 mm, baby hair direction jitter.
Final: hairline 6, density 7 (afro 7), strand definition 7, shine 5, style accuracy braids 8 / locs 7 / afro 7, temple 6. Gate not met.
Open: shine and rim sheen live in the hair material graph (HumanKit/Human.swift, out of scope); hairline edge of the scalp shell is a triangle edge from SkinFields scalp mask (out of scope); afro still shows flat dark card sheets beside the ears in the face crop; locs crown tuft remains.
Tests: HairTests (all presets finite, bounded < 450k verts, ropes hang) and FaceTypeTests pass.

## Waist and hips (skirts, dresses, jeans, shorts, leggings), 2026-10-27

Renders in out/waist/ (base-* before, i1..i6-* after; `look dress|heels|athletic|casual`, female and male, az 0/90/180, 2048px render cropped to 1024).
Checklist (0-10): waistband, hip silhouette, drape, poke-through, hem, symmetry, crotch, back, seams, fold realism.

Iteration 0 scores: waistband 1, hip silhouette 3 (flat cone from the hip joint, ledge at the top), drape 5, poke-through 6, hem 5, symmetry 6, crotch 6, back 4 (boxy shelf), seams 3, fold realism 4.
Top 3: no waistband and a stepped skirt top; flat cone skirt; skin/shell poking at the crotch rim under skirts.
Fixes: trousers, shorts, leggings and skirts route through the clipped path (exact waist line, trim band as raised waistband, 2.8 mm proud); skirt tube radius follows the garment shell over the hips (world-height bins, cumulative maximum), bell flare plus godet waves, pleats ramp in below the hips, folded rims at waist and hem, waistband rows in a darker fabric.

Iteration 1 scores: waistband 8, hip silhouette 8, drape 7, poke-through 7 (flap at the front crotch of skirts), hem 8, symmetry 8, crotch 6, back 7, seams 8, fold realism 7.
Top 3: crotch flap under skirts and the dress; tube following the shell at a different height than the morphed body; horizontal roll under the crotch on dresses.
Fixes: skirt shell dropped under the tube (dress shell cut 3 cm under the waist seam), tube heights hang from the shell's own top edge per angle, envelope smoothed vertically (fills outward only), fold floor raised to 35% of standoff, dress drape 14.

Iteration 2 scores: waistband 9, hip silhouette 8, drape 8, poke-through 9, hem 8, symmetry 8, crotch 8 (cream shaded patch on male trousers remains), back 8, seams 8, fold realism 8.
Open: waistbands of jeans, leggings and shorts sit under the tops in the casual and athletic presets; dress bodice shows rib and abdomen bumps; male trousers crotch patch tint.
Test: Tests/HumanHDTests/WaistTests.swift (waistband part present and topmost, no skin poke-through at the waist ring, flared skirt, no shell or skin through the tube).

## Hair pass 2 (shine, hairline, temple, afro, locs), 2026-10-27
Renders in out/hair/it4-* to it10-*, final-* (blackWoman face, az 0/45/90, 1024px, debug build /tmp/hhd-hair2).
Before: shine/rim 5, hairline 6, temple 6, afro 7 (flat sheets beside ears), locs 7 (crown tuft).
Iteration 1: cards shader highlight 0.3 to 0.9 plus rim sheen term (Human.swift); scalp mask fade widened (SkinFields); baby hairs 700 at 1.3 mm; coily temple cards narrowed. Afro sheets persisted.
Cause of sheets: coily front roots swept sideways (flow +-x) and radial strands had degenerate card normals, so ribbons faced the viewer as horizontal slats.
Iteration 2: coily front flow is r.n plus down (stands off scalp), card normal gets +0.07 up bias for coily, coil amplitude 0.0095, face-clear branch stops strand instead of pinning x. Sheets gone.
Iteration 3: locs crown flow gradient 0.9 over 4 cm, crown skip 4 cm, rope cap 330; highlight 0.3, rim 0.22 power 3 (cream/grey patches on ropes removed).
Final: shine/rim 8, hairline 8, temple 8, afro 8, locs 8 (two small grey blobs remain at top-left hairline in az 45).
Tests: HairTests and FaceTypeTests pass.
