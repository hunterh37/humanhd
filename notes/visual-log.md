# Visual log

## Realism pass, 2026-10-20

Renders in out/realism/ (before-*.png, after-*.png): hoops, boxer, boxer-face, look-male.

Iteration 1. Checklist: skin highlight size, hip to shoulder ratio, jersey fit, hair coverage.
Skin defaults: specular 0.3, roughness scale 1.08, roughness modulated by micro tile, clearcoat only on the oiliest zones, clearcoat roughness 0.36, warmer scatter floor.
Hoops and boxer: hips narrowed, shoulder distance raised. Jersey offset 0.05 to 0.034, shorts 0.03 to 0.026, more fold amplitude. Hoop shoe offset 0.012 to 0.01.
Result: hoops jersey hangs closer, shoulders read wider. Boxer face still glossy from glisten.

Iteration 2. Glisten amount scaled down (roughness 1.08 - 0.42a, specular 0.3 + 0.2a, oil 0.5 + 0.5a).
Result: forehead and chest highlight smaller. Open: crop hair cards leave gaps at the temples; jersey chest follows pectoral bumps; denim renders pale in the look command.
