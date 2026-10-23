"""Resemblance gate: CLIP ViT-L/14 image cosine between each preset render and its reference photo.
usage: resemblance.py REFDIR RENDERDIR OUT.png [SUFFIX]  (files <name>.jpg / <name><SUFFIX>.png, SUFFIX default -face)
Lower body: resemblance.py out/refs-lower out/lower out/lower/sheet.png -lower"""
import sys, glob, os, torch, open_clip
from PIL import Image
refdir, rdir, out = sys.argv[1:4]
suffix = sys.argv[4] if len(sys.argv) > 4 else '-face'
m, _, pre = open_clip.create_model_and_transforms('ViT-L-14', pretrained='openai'); m.eval()
def emb(im):
    with torch.no_grad():
        e = m.encode_image(pre(im).unsqueeze(0)); return e / e.norm(dim=-1, keepdim=True)
def square(im):
    w, h = im.size; s = min(w, h); return im.crop(((w-s)//2, 0, (w-s)//2+s, s))
tiles, scores = [], []
for ref in sorted(glob.glob(os.path.join(refdir, '*.jpg'))):
    n = os.path.basename(ref)[:-4]; r = os.path.join(rdir, n + suffix + '.png')
    if not os.path.exists(r): continue
    a, b = square(Image.open(ref).convert('RGB')), square(Image.open(r).convert('RGB'))
    s = float((emb(a) @ emb(b).T).item()); scores.append(s); print(f"{n} {s:.3f}")
    t = Image.new('RGB', (1024, 512)); t.paste(a.resize((512, 512)), (0, 0)); t.paste(b.resize((512, 512)), (512, 0)); tiles.append(t)
sheet = Image.new('RGB', (1024, 512 * len(tiles)))
for i, t in enumerate(tiles): sheet.paste(t, (0, 512 * i))
sheet.save(out); print(f"min {min(scores):.3f} mean {sum(scores)/len(scores):.3f}")
