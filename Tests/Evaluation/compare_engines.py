#!/usr/bin/env python3
"""
Compare speech engines on the same audio: Apple's on-device recognizer (what Prosa uses on the
Mac) and Whisper (whisper.cpp, which also runs on Windows and Linux).

For every dictation case and both tracks of every meeting case it reports the word error rate,
names spelled right, and the processing time (and the real-time factor: seconds of processing
per second of audio; below 1 is faster than speech). Whisper also runs with the glossary as its
prompt, the "word memory" Apple's recognizer ignores.

Usage:
  brew install whisper-cpp
  # models from https://huggingface.co/ggerganov/whisper.cpp
  python3 Tests/Evaluation/compare_engines.py --models "~/Library/Application Support/WhisperModels"
"""
import argparse, json, os, re, shutil, subprocess, sys, tempfile, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import evaluate as ev  # noqa: E402

def glossary_terms():
    terms, section = [], None
    for line in open(os.path.join(ev.HERE, "glossary.md"), encoding="utf-8"):
        if line.startswith("## "): section = line[3:].strip().lower()
        elif line.startswith("- ") and section == "terms": terms.append(line[2:].strip())
    return terms

def apple(binary, wav, data):
    start = time.time()
    out = subprocess.run([binary, "--transcribe", wav, "-dataFolder", data], capture_output=True, text=True, timeout=900).stdout
    elapsed = time.time() - start
    text = " ".join(re.sub(r"^\*\*\[[^\]]*\] \[[^\]]*\]:\*\* ?", "", l).strip() for l in out.splitlines() if l.startswith("**["))
    reported = re.search(r"\(([\d.]+) s\)", out)
    return text, float(reported.group(1)) if reported else elapsed

def whisper(cli, model, wav, prompt=None):
    cmd = [cli, "-m", model, "-l", "pt", "-nt", "-t", "4", "-f", wav]
    if prompt: cmd += ["--prompt", prompt]
    run = subprocess.run(cmd, capture_output=True, text=True, timeout=1800)
    text = " ".join(l.strip() for l in run.stdout.splitlines() if l.strip())
    total = re.search(r"total time\s*=\s*([\d.]+) ms", run.stderr)
    load = re.search(r"load time\s*=\s*([\d.]+) ms", run.stderr)
    # The app would keep the model loaded, so loading is not counted.
    seconds = ((float(total.group(1)) - (float(load.group(1)) if load else 0)) / 1000) if total else None
    return text, seconds, (float(load.group(1)) / 1000 if load else None)

def duration(wav):
    return len(ev.read_wav(wav)) / ev.RATE

def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--app", default="/Applications/Prosa.app/Contents/MacOS/MeetingMinutes")
    parser.add_argument("--models", default=os.path.expanduser("~/Library/Application Support/WhisperModels"))
    parser.add_argument("--whisper", default=shutil.which("whisper-cli") or "whisper-cli")
    parser.add_argument("--only", help="comma-separated case ids")
    parser.add_argument("--out", default=os.path.join(ev.HERE, "results"))
    args = parser.parse_args()
    models = {name: os.path.join(os.path.expanduser(args.models), f) for name, f in
              (("small", "ggml-small.bin"), ("turbo", "ggml-large-v3-turbo-q5_0.bin"))}
    models = {k: v for k, v in models.items() if os.path.exists(v)}
    if not models: sys.exit(f"No Whisper models in {args.models}")

    cases = json.load(open(os.path.join(ev.HERE, "cases.json"), encoding="utf-8"))
    by_id = {c["id"]: c for c in cases["dictation"] + cases["meetings"]}
    only = set(args.only.split(",")) if args.only else None
    work = tempfile.mkdtemp(prefix="prosa-engines-")
    data = os.path.join(work, "data"); os.makedirs(data)
    prompt = "Glossário: " + ", ".join(glossary_terms()) + "."
    engines = ["apple"] + [f"whisper-{m}" for m in models] + [f"whisper-{m}+prompt" for m in models]

    # Items: (id, name, wav, reference, terms)
    items = []
    for case in cases["dictation"]:
        if only and case["id"] not in only: continue
        wav, merged = ev.build_dictation(case, by_id, cases["voice"], work)
        items.append((case["id"], merged["name"], wav, merged["text"], merged.get("terms", [])))
    for case in cases["meetings"]:
        if (only and case["id"] not in only) or case.get("silence"): continue
        session, merged, turns, _ = ev.build_meeting(case, by_id, cases["voice"], work)
        for who, label in (("you", "you"), ("meeting", "others")):
            caf = os.path.join(session, f"{who}.caf"); wav = os.path.join(session, f"{who}.wav")
            ev.run(["ffmpeg", "-loglevel", "error", "-y", "-i", caf, "-ar", str(ev.RATE), "-ac", "1", "-sample_fmt", "s16", wav])
            ref = " ".join(t["text"] for t in turns if t["speaker"] == who)
            items.append((f"{case['id']}-{label}", f"{merged['name']} ({'you' if who == 'you' else 'others'})", wav, ref, []))

    rows, loads = [], {}
    for item_id, name, wav, ref, terms in items:
        print(f"  {item_id}…", flush=True)
        length = duration(wav)
        row = {"id": item_id, "name": name, "length": length, "results": {}}
        text, secs = apple(args.app, wav, data)
        row["results"]["apple"] = (ev.wer(ref, text), ev.terms_found(terms, text), secs, text)
        for m, path in models.items():
            for use_prompt in (False, True):
                text, secs, load = whisper(args.whisper, path, wav, prompt if use_prompt else None)
                loads[m] = load
                row["results"][f"whisper-{m}{'+prompt' if use_prompt else ''}"] = (ev.wer(ref, text), ev.terms_found(terms, text), secs, text)
        row["terms"] = len(terms)
        row["reference"] = ref
        rows.append(row)

    os.makedirs(args.out, exist_ok=True)
    stamp = time.strftime("%Y-%m-%d_%H-%M")
    lines = [f"# Speech engines compared — {stamp}", "",
             "Same synthetic audio (Luciana voice) through each engine. WER = word error rate (lower is better). "
             "RTF = processing seconds per second of audio (below 1 is faster than speech; Whisper's model loading is not counted, the app would keep it loaded).", ""]
    header = "| Case | Length | " + " | ".join(engines) + " |"
    lines += ["## Word error rate", "", header, "|---|---|" + "---|" * len(engines)]
    for r in rows:
        cells = [ev.pct(r["results"][e][0]) for e in engines]
        lines.append(f"| {r['id']} {r['name']} | {r['length']:.0f} s | " + " | ".join(cells) + " |")
    avg = {e: sum(r["results"][e][0] for r in rows) / len(rows) for e in engines}
    lines.append("| **Average** | | " + " | ".join(f"**{ev.pct(avg[e])}**" for e in engines) + " |")
    named = [r for r in rows if r["terms"]]
    if named:
        lines += ["", "## Names spelled right", "", header.replace("Length | ", ""), "|---|" + "---|" * len(engines)]
        for r in named:
            lines.append(f"| {r['id']} {r['name']} | " + " | ".join(f"{r['results'][e][1]}/{r['terms']}" for e in engines) + " |")
        total = sum(r["terms"] for r in named)
        lines.append("| **Total** | " + " | ".join(f"**{sum(r['results'][e][1] for r in named)}/{total}**" for e in engines) + " |")
    lines += ["", "## Speed (real-time factor)", "", header, "|---|---|" + "---|" * len(engines)]
    for r in rows:
        lines.append(f"| {r['id']} {r['name']} | {r['length']:.0f} s | " + " | ".join(
            "—" if r["results"][e][2] is None else f"{r['results'][e][2] / r['length']:.2f} ({r['results'][e][2]:.1f} s)" for e in engines) + " |")
    if loads:
        lines += ["", "Whisper model loading (once, not counted above): " + ", ".join(f"{m} {s:.1f} s" for m, s in loads.items() if s)]
    lines += ["", "## What each engine heard", ""]
    for r in rows:
        lines.append(f"**{r['id']}** reference: {r['reference']}  ")
        for e in engines: lines.append(f"{e}: {r['results'][e][3]}  ")
        lines.append("")
    path = os.path.join(args.out, f"engines_{stamp}.md")
    open(path, "w", encoding="utf-8").write("\n".join(lines))
    print("\n".join(lines[: lines.index("## What each engine heard")]))
    print(f"\nReport: {path}")
    shutil.rmtree(work, ignore_errors=True)

if __name__ == "__main__":
    main()
