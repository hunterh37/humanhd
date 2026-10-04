# Design

## Layers

HumanCore is pure Swift (RealCore from RealityHD for math and surfaces). `HM08` decodes one xz blob:
the hm08 quad mesh (19,158 vertices), 1,216 sparse morph targets stored as quantized family means plus
residuals (26 MB of targets in 3.2 MB), the 163-bone rig, top-4 weights, the eye mesh with its mhclo
fit and the face pose-unit BVH. `BodyShape` turns macro variables into target weights (multilinear in
gender, age, muscle, weight; height, proportions and breast families on top), `Skeleton` refits joints
as means of joint vertex rings, and `BodyTopology` holds the render topology per subdivision level as
stencils over base vertices, so a new shape only re-evaluates stencils.

HumanMaterials owns three Metal programs compiled at runtime: the skin painter, the eye painter and
strand textures. HumanKit maps everything to RealityKit: `SkinnedGPUMesh` (LowLevelMesh with a dynamic
and a static vertex stream), `GPUSkinner` (one compute kernel), `HumanCharacter`/`HumanSystem`, and
ShaderGraph materials emitted as USDA at runtime.

## Skin

The painter rasterizes the canonical body into an atlas (uv0 body layout, or a cylindrical face
projection) and evaluates the skin per fragment from the interpolated 3D position, normal, tangent and
20 anatomical fields. Fields come from the mesh: lips, nose, cheeks, ears, brows, chin, laugh lines,
navel and areola from the footprints of MakeHuman's regional targets; eyelids and lid margins from
the distance to the fitted eyeball; mouth interior and scalp from landmarks; palms and nails from the
hand bone frames. Noise is 3D, so both atlases paint the same skin and nothing seams. Normals come from
height differences along the tangent frame in 3D and are stored in the mesh's uv0 tangent space for
both atlases.

Textures hold relative pigment, not color: R melanin multiplier, G blood multiplier, B freckle pigment,
A hair coverage. The shader computes albedo = exp(-(melanin * M + blood * B + base)) with M, B and base
per character, fitted to skin albedos from very fair to very deep. One painted set serves every
character with the same `SkinDetail`.

## Skinning and LOD

Bones are rigid (no scale), so dual-quaternion skinning is exact and free of candy-wrapper collapse.
Per frame each character uploads 163 x 32 bytes of dual quaternions; the kernel blends four influences
and writes position, normal, tangent, bitangent and two crease values (bend angle between a vertex's two
main bones, used for joint darkening) into `replace(bufferIndex:using:)` of the LowLevelMesh. UVs are
written once into the second stream. All characters share one command buffer.

LOD: a hero mesh (Catmull-Clark level 1 skin) and a crowd mesh (level 0), switched by viewer distance;
animation LOD drops facial animation, then gaze, fingers and fine idle motion; distant characters
animate and skin every 2nd to 4th frame, staggered so the load stays flat.

## Clothing

A garment selects render-skin vertices by rules in canonical space (bone ownership, arm and leg
parameters, cut heights), offsets them along the skin normal, relaxes the shell with Laplacian passes
while keeping it outside a minimum standoff (drape), adds folds, smooths the opening, and adds a hem
rim. The shell keeps the skin vertices' weights, so it follows every pose without simulation. Skin two
rings inside the opening is hidden; inner layers lose triangles hidden by outer layers. Skirts are
separate tubes with weights shared between pelvis and thighs; shoes are re-projected onto a last.

## Animation

`CharacterAnimator` composes, in order: relaxed stance (from the hm08 A-pose), idle weight shift or
gait, breathing, clip layers, IK-planted feet, gaze and blinks, face units (expression, speech, raw
units), inertialization. `Anatomy` expresses rotations in rest model space (local = rest^-1 * R * rest)
and mirrors left-side descriptions onto the right, so poses are authored in anatomical terms.

## Limits and next steps

No cloth or hair simulation yet (spring bones for ponytails and skirts are the next step). Hair cards
are procedural; strand-quality grooms need a dedicated card layout tool. Teeth use the hm08 helper
geometry. Garment UVs wrap cylindrically with one seam at the back. Further work: quadric-decimated
crowd LOD (~5k triangles), vertex-animation-texture impostors for very large crowds, ASTC compression
of painted maps, wrinkle normal maps driven by the crease channel, ARKit face-tracking input.
