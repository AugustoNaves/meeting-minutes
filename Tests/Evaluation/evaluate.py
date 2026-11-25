#!/usr/bin/env python3
"""
Prosa evaluation: how well dictation and meeting recording do, with numbers.

It synthesizes speech with known text (macOS `say`, Luciana voice), feeds it to the app's
command-line test modes (the same code the app runs), and measures:

  Dictation   word error rate (raw / + glossary / + AI), names spelled right, how long the
              first word takes to appear while speaking, how long the final text takes
              after you stop, and whether the AI removed hesitations and self-corrections.
  Meetings    word error rate per speaker, whether each line got the right speaker,
              echo lines (other people's words labeled as you), processing time, and
              whether the minutes contain the expected decisions and tasks.

Usage:
  python3 Tests/Evaluation/evaluate.py            # no AI: on-device steps only
  python3 Tests/Evaluation/evaluate.py --ai       # also the AI chosen in Prosa's menu
  python3 Tests/Evaluation/evaluate.py --only d02,m01

Real recordings: put `name.m4a` (or .wav) next to `name.txt` (what was said) in
Tests/Evaluation/real/ and they run as extra dictation cases. Synthetic speech is easier
than real people, so real recordings give the more honest numbers.

Nothing touches your own minutes, glossary or history: everything runs in a temporary folder.
"""
import argparse, array, json, math, os, random, re, shutil, subprocess, sys, tempfile, time, unicodedata, wave
from datetime import datetime, timedelta, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
RATE = 16000

# ---------------------------------------------------------------- audio helpers

def run(cmd, **kw):
    return subprocess.run(cmd, check=True, capture_output=True, text=True, **kw)

def read_wav(path):
    with wave.open(path, "rb") as w:
        assert w.getnchannels() == 1 and w.getsampwidth() == 2, path
        return array.array("h", w.readframes(w.getnframes()))

def write_wav(path, samples):
    with wave.open(path, "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(RATE)
        w.writeframes(samples.tobytes())

def synth(text, path, voice, rate=None, work=None):
    aiff = path + ".aiff"
    cmd = ["say", "-v", voice, "-o", aiff]
    if rate: cmd += ["-r", str(rate)]
    run(cmd + [text])
    run(["ffmpeg", "-loglevel", "error", "-y", "-i", aiff, "-ar", str(RATE), "-ac", "1", "-sample_fmt", "s16", path])
    os.remove(aiff)
    return read_wav(path)

def silence(seconds):
    return array.array("h", bytes(2 * int(seconds * RATE)))

def rms(samples):
    if not samples: return 0.0
    return math.sqrt(sum(s * s for s in samples) / len(samples))

def add_noise(samples, snr_db, seed=7):
    rnd = random.Random(seed)
    voiced = [s for s in samples if abs(s) > 300] or list(samples)
    noise_rms = rms(voiced) / (10 ** (snr_db / 20))
    return array.array("h", (max(-32768, min(32767, int(s + rnd.gauss(0, noise_rms)))) for s in samples))

def mix(a, b, gain_b=1.0):
    n = max(len(a), len(b))
    out = array.array("h", bytes(2 * n))
    for i in range(n):
        v = (a[i] if i < len(a) else 0) + gain_b * (b[i] if i < len(b) else 0)
        out[i] = max(-32768, min(32767, int(v)))
    return out

def place(track, samples, start):
    i0 = int(start * RATE)
    missing = i0 + len(samples) - len(track)
    if missing > 0:
        track.extend(array.array("h", bytes(2 * missing)))
    for i, s in enumerate(samples):
        track[i0 + i] = max(-32768, min(32767, track[i0 + i] + s))

def telephone(path):
    tmp = path + ".tel.wav"
    run(["ffmpeg", "-loglevel", "error", "-y", "-i", path, "-af", "highpass=f=300,lowpass=f=3400", "-ar", "8000", tmp])
    run(["ffmpeg", "-loglevel", "error", "-y", "-i", tmp, "-ar", str(RATE), "-ac", "1", "-sample_fmt", "s16", path])
    os.remove(tmp)

def to_caf(wav_path, caf_path):
    run(["afconvert", "-f", "caff", "-d", f"LEI16@{RATE}", wav_path, caf_path])

# ---------------------------------------------------------------- text metrics

NUMBERS = {"zero": "0", "um": "1", "uma": "1", "dois": "2", "duas": "2", "tres": "3", "quatro": "4", "cinco": "5",
           "seis": "6", "sete": "7", "oito": "8", "nove": "9", "dez": "10", "onze": "11", "doze": "12", "treze": "13",
           "catorze": "14", "quatorze": "14", "quinze": "15", "dezesseis": "16", "dezessete": "17", "dezoito": "18",
           "dezenove": "19", "vinte": "20", "trinta": "30", "primeiro": "1"}

def normalize(text):
    text = unicodedata.normalize("NFD", text.lower())
    text = "".join(c for c in text if unicodedata.category(c) != "Mn")
    text = re.sub(r"(\d)h(\d)", r"\1 \2", text)
    text = re.sub(r"(\d)\s*h\b", r"\1", text)
    text = re.sub(r"[^\w\s]", " ", text)
    return [NUMBERS.get(w, w) for w in text.split()]

def wer(reference, hypothesis):
    r, h = normalize(reference), normalize(hypothesis)
    if not r: return 0.0 if not h else 1.0
    prev = list(range(len(h) + 1))
    for i in range(1, len(r) + 1):
        cur = [i] + [0] * len(h)
        for j in range(1, len(h) + 1):
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (r[i - 1] != h[j - 1]))
        prev = cur
    return prev[-1] / len(r)

def terms_found(terms, text):
    return sum(1 for t in terms if re.search(r"(?<!\w)" + re.escape(t) + r"(?!\w)", text))

def contains_word(text, word):
    return re.search(r"(?<!\w)" + re.escape(word) + r"(?!\w)", text, re.IGNORECASE) is not None

# ---------------------------------------------------------------- the app

class App:
    def __init__(self, binary, work, use_ai):
        self.binary, self.work, self.use_ai = binary, work, use_ai
        self.data = os.path.join(work, "data")
        self.minutes = os.path.join(work, "minutes")
        os.makedirs(self.data, exist_ok=True); os.makedirs(self.minutes, exist_ok=True)
        shutil.copy(os.path.join(HERE, "glossary.md"), os.path.join(self.minutes, "Glossary.md"))

    def args(self, extra=()):
        a = ["-dataFolder", self.data, "-minutesFolderPath", self.minutes]
        if not self.use_ai: a += ["-dictationCleanUp", "NO", "-minutesProvider", "none"]
        else: a += ["-dictationCleanUp", "YES"]
        return a + list(extra)

    def dictate_live(self, wav):
        out = subprocess.run([self.binary, "--dictate-live", wav] + self.args(), capture_output=True, text=True, timeout=900).stdout
        result = {"first_word": None, "final_latency": None, "heard": "", "final": "", "polished": None}
        for line in out.splitlines():
            m = re.match(r"\s*([\d.]+)s\s+types:", line)
            if m and result["first_word"] is None: result["first_word"] = float(m.group(1))
            m = re.search(r"final text ready ([\d.]+) s", line)
            if m: result["final_latency"] = float(m.group(1))
            if line.startswith("Heard:"): result["heard"] = line[6:].strip()
            if line.startswith("Final:"): result["final"] = line[6:].strip()
            if line.startswith("Polished:"): result["polished"] = line[9:].strip()
        return result

    def process(self, session):
        start = time.time()
        out = subprocess.run([self.binary, "--process", session] + self.args(), capture_output=True, text=True, timeout=1800).stdout
        elapsed = time.time() - start
        path = next((l.split("Minutes:", 1)[1].strip() for l in out.splitlines() if l.startswith("Minutes:")), None)
        return path, elapsed

# ---------------------------------------------------------------- dictation cases

def build_dictation(case, cases_by_id, voice, folder):
    base = cases_by_id.get(case.get("from")) if case.get("from") else case
    wav = os.path.join(folder, case["id"] + ".wav")
    if "parts" in base:
        samples = array.array("h")
        for i, part in enumerate(base["parts"]):
            samples += synth(part, wav, voice, case.get("rate"))
            if i < len(base["parts"]) - 1: samples += silence(base.get("pause", 2.0))
        text = " ".join(base["parts"])
    else:
        samples = synth(base["text"], wav, voice, case.get("rate"))
        text = base["text"]
    samples = silence(0.3) + samples + silence(0.8)
    if case.get("snr") is not None: samples = add_noise(samples, case["snr"])
    write_wav(wav, samples)
    if case.get("telephone"): telephone(wav)
    merged = dict(base); merged.update(case); merged["text"] = text
    return wav, merged

def real_cases(folder):
    real = os.path.join(HERE, "real")
    if not os.path.isdir(real): return []
    found = []
    for name in sorted(os.listdir(real)):
        stem, ext = os.path.splitext(name)
        if ext.lower() in (".m4a", ".wav", ".aiff", ".mp3") and os.path.exists(os.path.join(real, stem + ".txt")):
            wav = os.path.join(folder, "real-" + stem + ".wav")
            run(["ffmpeg", "-loglevel", "error", "-y", "-i", os.path.join(real, name), "-ar", str(RATE), "-ac", "1", "-sample_fmt", "s16", wav])
            text = open(os.path.join(real, stem + ".txt"), encoding="utf-8").read().strip()
            found.append((wav, {"id": "real-" + stem, "name": f"Gravação real: {stem}", "text": text}))
    return found

# ---------------------------------------------------------------- meeting cases

def build_meeting(case, cases_by_id, voice, folder):
    base = cases_by_id.get(case.get("from")) if case.get("from") else case
    session = os.path.join(folder, case["id"])
    os.makedirs(session, exist_ok=True)
    you, meeting = array.array("h"), array.array("h")
    turns_out = []
    if case.get("silence"):
        word = synth(case.get("word", "Oi."), os.path.join(session, "w.wav"), voice)
        meeting = silence(5) + word
        total = case["silence"]
        meeting += silence(max(0, total - len(meeting) / RATE)); you = silence(total)
    else:
        turns = base["turns"] * case.get("repeat", 1)
        t = 0.5
        prev_end = 0.0
        for index, (speaker, text) in enumerate(turns):
            samples = synth(text, os.path.join(session, "t.wav"), voice, 175 if speaker == "you" else 195)
            start = t
            if case.get("overlap") and index == 3:
                start = max(0.5, prev_end - case["overlap"])
            place(you if speaker == "you" else meeting, samples, start)
            duration = len(samples) / RATE
            turns_out.append({"speaker": speaker, "text": text, "start": start, "end": start + duration})
            prev_end = start + duration
            t = start + duration + 0.7
        total = t + 1.0
        for track in (you, meeting):
            missing = int(total * RATE) - len(track)
            if missing > 0: track.extend(array.array("h", bytes(2 * missing)))
        if case.get("echo"): you = mix(you, meeting, case["echo"])
        if case.get("mic_snr") is not None: you = add_noise(you, case["mic_snr"])
    for name, track in (("you", you), ("meeting", meeting)):
        wav = os.path.join(session, name + ".wav")
        write_wav(wav, track); to_caf(wav, os.path.join(session, name + ".caf")); os.remove(wav)
    for leftover in ("t.wav", "w.wav"):
        p = os.path.join(session, leftover)
        if os.path.exists(p): os.remove(p)
    start_date = datetime.now(timezone.utc).replace(microsecond=0)
    meta = {"startDate": start_date.isoformat().replace("+00:00", "Z"),
            "endDate": (start_date + timedelta(seconds=len(you) / RATE)).isoformat().replace("+00:00", "Z"),
            "language": "pt_BR", "warnings": []}
    json.dump(meta, open(os.path.join(session, "meta.json"), "w"))
    merged = dict(base); merged.update(case)
    return session, merged, turns_out, len(you) / RATE

LINE = re.compile(r"^\*\*\[(\d\d):(\d\d):(\d\d)\] \[([^\]]+)\]:\*\* ?(.*)$")

def read_minutes(path):
    text = open(path, encoding="utf-8").read()
    lines = []
    for raw in text.splitlines():
        m = LINE.match(raw.strip())
        if m:
            h, mi, s, label, body = m.groups()
            lines.append({"t": int(h) * 3600 + int(mi) * 60 + int(s), "you": label in ("Você", "You"), "text": body})
    minutes_part = text.split("\n---\n")[0]
    sections, current = {}, None
    for raw in minutes_part.splitlines():
        if raw.startswith("## "): current = raw[3:].strip(); sections[current] = ""
        elif current: sections[current] += raw + "\n"
    return text, lines, sections

def evaluate_meeting(case, turns, lines, sections, text, use_ai):
    result = {}
    if case.get("silence"):
        result["audio_kept"] = "Only" in text and "Audio" in text
        return result
    for who in ("you", "meeting"):
        ref = " ".join(t["text"] for t in turns if t["speaker"] == who)
        hyp = " ".join(l["text"] for l in lines if l["you"] == (who == "you"))
        result[f"wer_{who}"] = wer(ref, hyp)
    # Speaker: each transcript line belongs to the turn that started closest to it (timestamps
    # are whole seconds, and turns are less than a second apart, so time windows would overlap).
    def closest_turn(line):
        # The recognizer dates a sentence up to ~2 s early (from the end of the silence before
        # it), so the nearest turn start is used rather than a fixed time window.
        return min(turns, key=lambda t: abs(t["start"] - line["t"])) if turns else None
    right = wrong = 0
    echo = 0
    for line in lines:
        turn = closest_turn(line)
        if not turn: continue
        n = len(normalize(line["text"]))
        if line["you"] == (turn["speaker"] == "you"): right += n
        else:
            wrong += n
            # Echo: the others' words labeled as you.
            if line["you"]: echo += 1
    result["speaker_ok"] = right / (right + wrong) if right + wrong else 0.0
    result["echo_lines"] = echo
    expect = case.get("minutes_expect")
    if expect and sections and use_ai:
        keys = list(sections.keys())
        decisions = sections.get(keys[2], "") if len(keys) > 3 else ""
        tasks = sections.get(keys[3], "") if len(keys) > 3 else ""
        found = 0; total = 0
        for group in expect.get("decisions", []):
            total += 1; found += all(k.lower() in decisions.lower() for k in group)
        for group in expect.get("tasks", []):
            total += 1; found += any(all(k.lower() in item.lower() for k in group) for item in tasks.splitlines())
        result["minutes_items"] = (found, total)
    return result

# ---------------------------------------------------------------- report

def pct(x): return "—" if x is None else f"{x * 100:.0f}%"
def sec(x): return "—" if x is None else f"{x:.2f} s"

def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--app", default="/Applications/Prosa.app/Contents/MacOS/MeetingMinutes")
    parser.add_argument("--ai", action="store_true", help="also measure the AI chosen in Prosa's menu")
    parser.add_argument("--only", help="comma-separated case ids")
    parser.add_argument("--out", default=os.path.join(HERE, "results"))
    parser.add_argument("--keep", action="store_true", help="keep the generated audio and minutes")
    args = parser.parse_args()
    if not os.path.exists(args.app): sys.exit(f"Prosa not found at {args.app} (use --app)")

    cases = json.load(open(os.path.join(HERE, "cases.json"), encoding="utf-8"))
    voice = cases["voice"]
    only = set(args.only.split(",")) if args.only else None
    work = tempfile.mkdtemp(prefix="prosa-eval-")
    app = App(args.app, work, args.ai)
    by_id = {c["id"]: c for c in cases["dictation"] + cases["meetings"]}
    print(f"Working in {work}  (AI: {'on' if args.ai else 'off'})", flush=True)

    dictation_rows = []
    targets = [(c) for c in cases["dictation"] if not only or c["id"] in only]
    built = [build_dictation(c, by_id, voice, work) for c in targets] + (real_cases(work) if not only else [])
    for wav, case in built:
        print(f"  dictation {case['id']}: {case['name']}…", flush=True)
        r = app.dictate_live(wav)
        terms = case.get("terms", [])
        row = {"id": case["id"], "name": case["name"],
               "wer_raw": wer(case["text"], r["heard"]), "wer_gloss": wer(case["text"], r["final"]),
               "wer_ai": wer(case["text"], r["polished"]) if r["polished"] is not None else None,
               "terms": (terms_found(terms, r["heard"]), terms_found(terms, r["final"]),
                         terms_found(terms, r["polished"]) if r["polished"] is not None else None, len(terms)),
               "first_word": r["first_word"], "final_latency": r["final_latency"],
               "heard": r["heard"], "final": r["final"], "polished": r["polished"], "reference": case["text"]}
        if r["polished"] is not None and (case.get("clean_expect_absent") or case.get("clean_expect_present")):
            ok = all(not contains_word(r["polished"], w) for w in case.get("clean_expect_absent", [])) and \
                 all(contains_word(r["polished"], w) for w in case.get("clean_expect_present", []))
            row["clean_ok"] = ok
        dictation_rows.append(row)

    meeting_rows = []
    for case in cases["meetings"]:
        if only and case["id"] not in only: continue
        print(f"  meeting {case['id']}: {case['name']}…", flush=True)
        session, merged, turns, duration = build_meeting(case, by_id, voice, work)
        path, elapsed = app.process(session)
        if not path:
            meeting_rows.append({"id": case["id"], "name": case["name"], "error": "no minutes file"}); continue
        text, lines, sections = read_minutes(path)
        row = {"id": case["id"], "name": case["name"], "duration": duration, "elapsed": elapsed}
        row.update(evaluate_meeting(merged, turns, lines, sections, text, args.ai))
        meeting_rows.append(row)

    # ---- write the report
    os.makedirs(args.out, exist_ok=True)
    stamp = datetime.now().strftime("%Y-%m-%d_%H-%M")
    report = [f"# Prosa evaluation — {stamp}", "", f"AI: {'on' if args.ai else 'off'} · voice: {voice} (synthetic) · app: `{args.app}`", ""]
    if dictation_rows:
        report += ["## Dictation", "", "Word error rate (lower is better) · names spelled right · first word while speaking · final text after stopping", "",
                   "| Case | WER raw | WER + glossary | WER + AI | Names (raw / gloss / AI) | First word | Final after stop | AI clean-up |",
                   "|---|---|---|---|---|---|---|---|"]
        for r in dictation_rows:
            t = r["terms"]
            names = "—" if t[3] == 0 else f"{t[0]}/{t[3]} · {t[1]}/{t[3]} · " + ("—" if t[2] is None else f"{t[2]}/{t[3]}")
            clean = {True: "ok", False: "missed"}.get(r.get("clean_ok"), "—")
            report.append(f"| {r['id']} {r['name']} | {pct(r['wer_raw'])} | {pct(r['wer_gloss'])} | {pct(r['wer_ai'])} | {names} | {sec(r['first_word'])} | {sec(r['final_latency'])} | {clean} |")
        avg = lambda k: sum(r[k] for r in dictation_rows if r[k] is not None) / max(1, sum(1 for r in dictation_rows if r[k] is not None))
        report += ["", f"Average WER: raw {pct(avg('wer_raw'))}, + glossary {pct(avg('wer_gloss'))}" + (f", + AI {pct(avg('wer_ai'))}" if args.ai else "") +
                   f". Average first word {sec(avg('first_word'))}, final text {sec(avg('final_latency'))} after stopping.", ""]
        report += ["### What was heard", ""]
        for r in dictation_rows:
            report += [f"**{r['id']}** reference: {r['reference']}  ", f"heard: {r['heard']}  ", f"final: {r['final']}  "]
            if r["polished"] is not None: report.append(f"AI: {r['polished']}  ")
            report.append("")
    if meeting_rows:
        report += ["## Meetings", "", "| Case | Length | Processing | WER you | WER others | Right speaker | Echo lines | Minutes items |", "|---|---|---|---|---|---|---|---|"]
        for r in meeting_rows:
            if "error" in r: report.append(f"| {r['id']} {r['name']} | error: {r['error']} |||||||"); continue
            if "audio_kept" in r:
                report.append(f"| {r['id']} {r['name']} | {r['duration']:.0f} s | {r['elapsed']:.1f} s | — | — | — | — | audio kept: {'yes' if r['audio_kept'] else 'NO'} |"); continue
            items = r.get("minutes_items"); items = "—" if not items else f"{items[0]}/{items[1]}"
            report.append(f"| {r['id']} {r['name']} | {r['duration']:.0f} s | {r['elapsed']:.1f} s | {pct(r['wer_you'])} | {pct(r['wer_meeting'])} | {pct(r['speaker_ok'])} | {r['echo_lines']} | {items} |")
        report.append("")
    path = os.path.join(args.out, f"report_{stamp}{'_ai' if args.ai else ''}.md")
    open(path, "w", encoding="utf-8").write("\n".join(report))
    print("\n".join(report))
    print(f"\nReport: {path}")
    if args.keep: print(f"Kept: {work}")
    else: shutil.rmtree(work, ignore_errors=True)

if __name__ == "__main__":
    main()
