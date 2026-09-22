#!/usr/bin/env python3
"""Build a local, self-contained listening comparison. Never changes app resources.

Requires ffmpeg. Sources: design/audio-auditions/sources/lichess and the existing
wood/felt candidates. Run: python3 scripts/make-sound-gallery.py
"""
import base64
import io
import json
import math
from pathlib import Path
import struct
import subprocess
import wave

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "design/audio-auditions"
RATE = 44100
EVENTS = ["move", "capture", "check"]
SETS = [
    ("wood", "Recorded wood", "The current choice", "Real wooden chess pieces. A short landing, fuller capture, and double tap for check.", "CC0 · el_boss"),
    ("muted", "Muted wood", "Deeper & softer", "The same recording with a lower pitch and less high-frequency bite.", "CC0 · adapted from el_boss"),
    ("felt", "Soft felt", "Light & subdued", "Synthesized damped taps, with a faint mallet note for check.", "Original · Chess TV"),
    ("piano", "Lichess Piano", "Musical", "Lichess’s piano set: compare the notes and their longer decay.", "AGPLv3+ · Enigmahack / Lichess"),
    ("nes", "Lichess NES", "Retro", "Lichess’s NES set, for a more electronic, game-like character.", "AGPLv3+ · Enigmahack / Lichess"),
    ("sfx", "Lichess SFX", "Expressive", "Lichess’s SFX set. Hear how its move, capture, and check cues differ.", "AGPLv3+ · Enigmahack / Lichess"),
]


def clip(path, filters="anull"):
    raw = subprocess.run([
        "ffmpeg", "-v", "error", "-i", str(path), "-af", filters,
        "-ac", "1", "-ar", str(RATE), "-f", "f32le", "pipe:1",
    ], check=True, capture_output=True).stdout
    frames = list(struct.unpack(f"<{len(raw)//4}f", raw))
    # Level-match short-event energy while preserving the original timbre and decay.
    energy = math.sqrt(sum(x*x for x in frames) / (RATE * .2))
    gain = min(.045 / max(energy, 1e-9), .50 / max(max(map(abs, frames)), 1e-9))
    samples = [round(x * gain * 32767) for x in frames]
    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as output:
        output.setparams((1, 2, RATE, 0, "NONE", "not compressed"))
        output.writeframes(struct.pack(f"<{len(samples)}h", *samples))
    return buffer.getvalue(), len(samples) / RATE


def main():
    sounds = {}
    manifest = {}
    for key, *_ in SETS:
        sounds[key] = {}
        for event in EVENTS:
            filters = "anull"
            if key in ("wood", "muted"):
                source = ROOT / "Apps/ChessTV/Resources/Sounds" / f"{event}.wav"
                if key == "muted":
                    filters = "asetrate=39690,aresample=44100,lowpass=f=1800"
            elif key == "felt":
                source = OUT / "B-felt" / f"{event}.wav"
            else:
                source = OUT / "sources/lichess" / key / f"{event.title()}.mp3"
            data, duration = clip(source, filters)
            path = OUT / "comparison" / key / f"{event}.wav"
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
            sounds[key][event] = "data:audio/wav;base64," + base64.b64encode(data).decode()
            manifest[f"{key}/{event}"] = {"duration": round(duration, 3), "source": str(source.relative_to(ROOT)), "filter": filters}
    (OUT / "comparison/manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    cards = []
    for i, (key, title, subtitle, description, credit) in enumerate(SETS, 1):
        buttons = "".join(f'<button data-set="{key}" data-event="{event}" aria-label="{title}: {event}"><span>▶</span> {event.title()}</button>' for event in EVENTS)
        cards.append(f'''<article id="card-{key}">
<div class="cardtop"><span class="number">0{i}</span><span class="tag">{subtitle}</span></div>
<h2>{title}</h2><p class="description">{description}</p><div class="buttons">{buttons}</div>
<div class="secondary"><button data-set="{key}" data-mode="sequence">Play all three</button><button data-set="{key}" data-mode="loop">Repeat move ×6</button></div>
<small>{credit}</small></article>''')
    html = '''<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>Chess TV · Sound comparison</title>
<style>
:root{color-scheme:dark;--bg:#141812;--panel:#20261e;--line:#384230;--text:#efeee5;--muted:#b3bca9;--accent:#d2e1a7}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font:16px/1.5 system-ui,-apple-system,sans-serif}
main{max-width:1060px;margin:auto;padding:38px 28px 60px}.eyebrow{font-size:12px;letter-spacing:.15em;color:var(--accent);font-weight:700;text-transform:uppercase}
h1{font-size:clamp(32px,5vw,48px);letter-spacing:-.045em;line-height:1.1;margin:14px 0}header>p{color:var(--muted);max-width:660px;margin:0 0 24px}
.toolbar{display:flex;flex-wrap:wrap;align-items:center;gap:12px;background:#1b2118;border:1px solid var(--line);border-radius:16px;padding:16px;margin:24px 0}
button{font:inherit;color:var(--text);border:1px solid #546245;background:#303b29;border-radius:9px;padding:10px 13px;cursor:pointer;white-space:nowrap}
button:hover{background:#455338}button:focus-visible,a:focus-visible,input:focus-visible{outline:3px solid var(--accent);outline-offset:4px}button span{font-size:11px;color:var(--accent)}
.primary{background:var(--accent);color:#202719;font-weight:650}.primary:hover{background:#e0edbd}.stop{background:transparent}
.volume{display:flex;align-items:center;gap:10px;font-size:13px;color:var(--muted);margin-left:auto}input{width:110px;accent-color:var(--accent)}
.status{min-height:30px;font-size:14px;color:var(--accent);margin:0 0 12px}.grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:18px}
article{background:var(--panel);border:1px solid var(--line);border-radius:18px;padding:24px;transition:border-color .15s,box-shadow .15s}article.playing{border-color:var(--accent);box-shadow:0 0 0 1px var(--accent)}
.cardtop{display:flex;align-items:center;justify-content:space-between}.number{font-size:13px;color:var(--muted);font-variant-numeric:tabular-nums}.tag{font-size:12px;color:var(--accent);border:1px solid #4b583c;border-radius:20px;padding:3px 9px}
h2{font-size:25px;letter-spacing:-.025em;margin:14px 0 5px}.description{color:var(--muted);font-size:14px;min-height:44px;margin:0 0 20px}.buttons{display:grid;grid-template-columns:repeat(3,1fr);gap:8px}
.secondary{display:flex;gap:8px;margin:10px 0 20px}.secondary button{font-size:13px;background:transparent;padding:8px 11px;color:#d2d8c8}small{font-size:11px;color:#a8b29e}
footer{margin-top:26px;font-size:13px;color:var(--muted)}a{color:var(--accent)}details{margin-top:18px}summary{cursor:pointer}details p{max-width:780px}
@media(max-width:640px){main{padding:24px 16px}.grid{grid-template-columns:1fr}.volume{margin-left:0;width:100%}article{padding:20px}.description{min-height:0}}
</style></head><body><main>
<header><div class="eyebrow">Chess TV / Listening room</div><h1>Find the right sound.</h1>
<p>Six directions, side by side. Start with the move comparison, then try each capture and check. Click any button to listen.</p></header>
<div class="toolbar"><button class="primary" id="compare">▶ Compare all move sounds</button><button class="stop" id="stop">■ Stop</button>
<label class="volume">Volume <input id="volume" aria-label="Preview volume" type="range" min="0" max="1" step=".05" value=".75"></label></div>
<p class="status" id="status" role="status" aria-live="polite">Ready · No audio plays until you press a button.</p>
<section class="grid">''' + "".join(cards) + '''</section>
<footer>Preview only. Choosing a playback button does not change the app. Clips are level-matched for comparison.
<details><summary>Sources &amp; licensing</summary><p>Wood recordings: <a href="https://freesound.org/people/el_boss/packs/30764/">el_boss / Freesound</a>, CC0. Muted wood lowers the pitch and filters the high end. Soft felt is synthesized for Chess TV.</p>
<p>Piano, NES and SFX: Enigmahack / Lichess, AGPLv3+. These are separate sets from Lichess’s default Standard set.
<a href="sources/lichess/COPYING.md">Upstream credits</a> · <a href="sources/lichess/LICENSE">License</a> · <a href="sources/lichess/manifest.json">Original source files</a>.</p></details></footer>
</main><script>
const clips = __CLIPS__;
const sets = __SETS__;
let active = null, pending = null, resolvePlay = null, token = 0;
const status = document.getElementById('status');
const volume = document.getElementById('volume');
function cancel(){
  token++;
  if(active){active.onended = active.onerror = null;active.pause();active = null;}
  if(pending !== null){clearTimeout(pending);pending = null;}
  if(resolvePlay){resolvePlay();resolvePlay = null;}
  document.querySelectorAll('article.playing').forEach(el=>el.classList.remove('playing'));
}
function wait(ms, t){return new Promise(resolve=>{if(t!==token)return resolve();resolvePlay=resolve;pending=setTimeout(()=>{pending=null;resolvePlay=null;resolve();},ms);});}
function sound(key,event,t){return new Promise((resolve,reject)=>{
  if(t!==token)return resolve();
  document.querySelectorAll('article.playing').forEach(el=>el.classList.remove('playing'));
  document.getElementById('card-'+key).classList.add('playing');
  status.textContent=sets.find(s=>s[0]===key)[1]+' · '+event.charAt(0).toUpperCase()+event.slice(1);
  const audio=new Audio(clips[key][event]);active=audio;audio.volume=Number(volume.value);resolvePlay=resolve;
  audio.onended=()=>{resolvePlay=null;resolve();};
  audio.onerror=()=>reject(new Error('Audio could not be loaded.'));
  audio.play().catch(reject);
});}
async function run(items){
  cancel();const t=token;
  try{
    for(let i=0;i<items.length;i++){
      if(t!==token)return;
      await sound(items[i][0],items[i][1],t);
      if(i<items.length-1)await wait(500,t);
    }
    if(t===token){cancel();status.textContent='Finished · Try another set or repeat a move.';}
  }catch(error){if(t===token){cancel();status.textContent='Playback failed. Try another button or reopen this page.';}}
}
document.querySelectorAll('[data-set]').forEach(button=>button.addEventListener('click',()=>{
  const {set,event,mode}=button.dataset;
  run(event?[[set,event]]:mode==='loop'?Array.from({length:6},()=>[set,'move']):['move','capture','check'].map(e=>[set,e]));
}));
document.getElementById('compare').addEventListener('click',()=>run(sets.flatMap(s=>[[s[0],'move'],[s[0],'move']])));
document.getElementById('stop').addEventListener('click',()=>{cancel();status.textContent='Stopped · Choose any sound to listen.';});
volume.addEventListener('input',()=>{if(active)active.volume=Number(volume.value);});
window.addEventListener('pagehide',cancel);
</script></body></html>'''
    html = html.replace('__CLIPS__', json.dumps(sounds)).replace('__SETS__', json.dumps(SETS))
    (OUT / "compare.html").write_text(html)
    print(f"Built 6 sets / 18 clips and {OUT / 'compare.html'}")


if __name__ == '__main__':
    main()
