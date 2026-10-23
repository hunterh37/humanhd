# Visual log

## Realism pass, 2026-10-20

Renders in out/realism/ (before-*.png, after-*.png): hoops, boxer, boxer-face, look-male.

Iteration 1. Checklist: skin highlight size, hip to shoulder ratio, jersey fit, hair coverage.
Skin defaults: specular 0.3, roughness scale 1.08, roughness modulated by micro tile, clearcoat only on the oiliest zones, clearcoat roughness 0.36, warmer scatter floor.
Hoops and boxer: hips narrowed, shoulder distance raised. Jersey offset 0.05 to 0.034, shorts 0.03 to 0.026, more fold amplitude. Hoop shoe offset 0.012 to 0.01.
Result: hoops jersey hangs closer, shoulders read wider. Boxer face still glossy from glisten.

Iteration 2. Glisten amount scaled down (roughness 1.08 - 0.42a, specular 0.3 + 0.2a, oil 0.5 + 0.5a).
Result: forehead and chest highlight smaller. Open: crop hair cards leave gaps at the temples; jersey chest follows pectoral bumps; denim renders pale in the look command.

## Realistic presets, 2026-10-23

Presets `HumanPresets.all`: woodsman, street, studio, brim, campus. New garments: beanie, cap, wide-brim (GarmentHat.swift), flannel shirt, joggers, chelsea boots.
Gate: `Scripts/resemblance.py` (CLIP ViT-L/14 cosine, face render vs CC0 Unsplash reference on Wikimedia Commons). Target 0.85.
Iteration 1: cap visor wrapped the sides, curly hair cards outside the cap, brim crown too tall. Scores min 0.542 mean 0.587.
Iteration 2: visor limited to the front 120 degrees, hair cull margin 8 cm, brim crown lowered, morning sky, smile on brim. min 0.515 mean 0.589.
Iteration 3: visor column order fixed (center gap), campus hair crop. min 0.515 mean 0.590.
Open: faces read as CG (no beard volume, flat skin micro-shading, no hair on forehead under hats). Gate not met.
