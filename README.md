# Meeting Minutes

A macOS menu bar app that records your meetings with one keyboard shortcut: **your voice** (microphone) and **everyone else** (the sound your Mac is playing). When you stop, it transcribes everything **on your Mac** and saves structured meeting minutes as a Markdown file.

```
⌘⇧R  →  record  →  ⌘⇧R  →  on-device transcription  →  AI writes the minutes  →  .md + notification
```

- Works with Google Meet, Zoom, Teams, Slack or anything else that plays audio.
- No BlackHole or virtual audio drivers: it uses the system audio tap built into macOS.
- Separates what **you** said from what the **other people** said, in chronological order.
- The audio never leaves your Mac. Only the transcript text goes to the AI you choose.
- Minutes in the language of the meeting (any language the macOS speech recognizer supports).

Example output: [docs/example-minutes.md](docs/example-minutes.md).

---

## 1. Requirements

| What | Why |
|---|---|
| Mac with Apple Silicon (M1 or newer) | On-device transcription runs on the Neural Engine |
| **macOS 26 (Tahoe) or newer** | The speech recognizer used (SpeechAnalyzer) only exists from macOS 26 |
| Apple Command Line Tools | To build the app. The full Xcode is not needed |
| One of these, to write the minutes: **Claude Code** (logged in), **Antigravity CLI** (`agy`, Gemini, logged in) or a **Claude API key** | You choose which one in the menu |

If the Command Line Tools are missing, install them with:

```bash
xcode-select --install
```

Without any of the three minutes writers, the app still works, but the `.md` only contains the transcript.

---

## 2. Install

Clone the repository and run the installer:

```bash
git clone https://github.com/AugustoNaves/meeting-minutes.git
```

```bash
cd meeting-minutes && ./scripts/install.sh
```

The script builds the app (about a minute the first time), copies it to `/Applications/Meeting Minutes.app` and opens it. No password or Apple developer account needed: the app is signed locally (ad-hoc).

### First launch

The app walks you through a short series of windows, explaining each step:

1. **Microphone**: click *Allow*. Then a **microphone test**: say a sentence and the app checks that it heard your voice. If it only hears noise (common with headphones that have no microphone), it offers to switch to the Mac's microphone.
2. **System audio** ("System Audio Recording"): click *Allow*. The app plays a short sound to check that it is capturing.
3. **Minutes folder**: access to `~/Documents/Meeting Minutes`.
4. **Notifications**: macOS shows a small prompt in the top-right corner; click *Allow*. If notifications stay off, "Minutes ready" shows on the menu bar icon instead, with a sound.
5. **Meeting language**: defaults to your Mac's language. macOS downloads the speech model for it once, if needed.
6. **Who writes the minutes**: Claude Code, Gemini (through Antigravity) or a Claude API key. Only the options installed on your Mac are shown.
7. **Open at login**: recommended, so the shortcut is always ready.

If a permission gets denied by mistake, use **Check Permissions…** in the app menu.

---

## 3. Use

1. Join your meeting.
2. Press **⌘⇧R**. A short sound confirms it, and the icon turns red with the elapsed time: `● 12:34`.
3. Press **⌘⇧R** again to stop. Another sound confirms it.
4. The icon shows **⌛ Transcribing…** and then **Writing minutes…**. Keep using your Mac normally.
5. A **"Minutes ready ✓"** notification arrives. Click it to open the file.

Files are saved as `~/Documents/Meeting Minutes/YYYY-MM-DD_HH-MM_Meeting.md`.

The shortcut works with any app in front, including full-screen apps.

> **Heads-up:** in Chrome and Safari, ⌘⇧R is also "hard reload". While Meeting Minutes is running, the shortcut belongs to it. If you use that browser command a lot, pick another shortcut in the menu (**Shortcut:** ⌃⌥⌘R, ⌥⇧R or ⌃⇧M).

### The minutes file

```markdown
# Meeting Minutes - November 23, 2026 at 5:58 PM

## Executive Summary
## Key Topics Discussed
## Decisions Made
## Next Steps / Action Items
- [ ] Send the sales figures by Thursday. — **Owner:** Maria

---

## Full Transcript
**[00:00:05] [You]:** Morning. I brought the numbers from last quarter.
**[00:00:11] [Meeting]:** Great. We still need to decide who presents on Friday.
```

The headings and the `[You]` / `[Meeting]` labels follow the meeting language (built-in translations for English, Portuguese, Spanish, French, German and Italian; other languages get English headings with the content in the meeting language).

### The menu

| Item | What it does |
|---|---|
| Start / Stop Recording | Same as the shortcut |
| Open Minutes Folder | Opens the folder where the minutes are saved |
| Open Latest Minutes | Opens the last `.md` written |
| Regenerate Minutes from .md… | Sends the transcript of an existing `.md` to the AI again and rewrites the minutes part (useful if the internet dropped at the time) |
| Process Pending Recordings | Shows up only if a recording did not become minutes (app quit mid-way, error) |
| Meeting Language | The language spoken in your meetings: drives transcription and the language of the minutes |
| Minutes Written By | Claude Code (your Claude account), Gemini via Antigravity (your Google account) or Claude API (your own key) |
| Minutes Model | With Claude: Opus 5.5 (best quality, default), Sonnet 5.5 or Haiku 5.5 (most economical). With Gemini: Antigravity's default or any model from its list (with "Refresh Model List") |
| Set / Remove Claude API Key | The key is stored in the macOS Keychain |
| Microphone | Which microphone records your voice (system default, the Mac's microphone, a headset…), plus **Test Microphone…** |
| Shortcut | Changes the key combination |
| Change Minutes Folder… | Saves the minutes somewhere else |
| Sound on Start and Stop | Turns the confirmation sounds on or off |
| Keep Meeting Audio | Also saves the audio in `Audio/` inside the minutes folder (`.m4a`, about 15 MB per hour) |
| Open at Login | Opens the app when you log in |
| Check Permissions… | Repeats the first-launch setup |
| Show Log | Opens `~/Library/Logs/MeetingMinutes.log` |

You can also control it with links (macOS Shortcuts, Raycast, Stream Deck): `meetingminutes://toggle`, `meetingminutes://start`, `meetingminutes://stop`.

---

## 4. How it works

| Step | How | Why |
|---|---|---|
| Menu bar and shortcut | AppKit (`NSStatusItem`) + `RegisterEventHotKey` (Carbon) | Native and light, works in full screen, needs no Accessibility permission |
| Other people's audio | Core Audio *process tap* (`CATapDescription`) | Captures the Mac's sound before it reaches the headphones: works with headphones on and **needs no BlackHole** or driver |
| Your voice | `AVAudioEngine` on the chosen microphone | If you switch microphones or headphones mid-meeting, capture restarts on its own |
| Recording | Two separate tracks (`you.caf` and `meeting.caf`, 16 kHz mono), aligned to the system clock | Separate tracks = knowing who spoke without guessing |
| Transcription | macOS 26 `SpeechAnalyzer` / `SpeechTranscriber`, on device | Free, private and fast: in testing, 16 minutes of audio in 6 seconds, using about 22 MB of memory in the app |
| [You] vs. [Meeting] | Every sentence comes with per-word timing; both tracks are interleaved in time order | The conversation timeline stays correct |
| No duplicated echo | On speakers, the microphone also picks up the other people. Stretches of the microphone track that repeat, at the same moment, the words of the system track are dropped, as are stray words that leak from headphones while others talk | The same sentence never appears twice |
| Minutes | Claude Code (`claude -p`), Antigravity (`agy -p`, Gemini) or the Claude API, always with the response validated by a JSON Schema | The `.md` format is always the same, whoever writes it |

### Cost

| Part | Cost |
|---|---|
| Recording and transcription | **Free.** Everything runs on your Mac, offline |
| Minutes through **Claude Code** | No per-use charge: uses your Claude subscription's allowance, like one message with a long text pasted in |
| Minutes through **Gemini (Antigravity)** | No per-use charge: uses your Google account's allowance |
| Minutes through the **Claude API** (if you set a key) | Billed per token on your API account |

Measured on a short test meeting (about 1,600 input tokens):

| Model | API-equivalent cost | Time |
|---|---|---|
| Claude Opus 5.5 (default) | US$ 0.020 | 6 s |
| Claude Sonnet 5.5 | US$ 0.009 | 4 s |
| Claude Haiku 5.5 | US$ 0.0007 | 6 s |
| Gemini 4 Neon (Medium) | Google account allowance | 17–22 s |

Estimate for **one hour of meeting** (about 15,000 transcript tokens): Opus ≈ US$ 0.10; Sonnet ≈ US$ 0.04; Haiku ≈ US$ 0.003. The app calls Claude Code with no tools, no history and no prompt cache (for a single call the cache would only add cost), at "medium" effort, to keep usage low. Antigravity is an agent and adds about 10,000 tokens of its own instructions to every call; those come out of your Google allowance. Antigravity lists its models by codename (Gemini 4 Neon, Argon, Hydrogen, 3.8 Flash); on a Google AI Pro plan, **Gemini 4 Neon** is the most capable one available.

### Privacy

- **The audio never leaves your Mac.** Transcription is done by macOS itself, offline.
- Only the transcript **text** is sent to write the minutes: to Anthropic (Claude Code or API) or to Google (Gemini through Antigravity), depending on your choice in the menu, under the terms of the account you use.
- Raw audio is deleted once the minutes are saved, unless you turn on "Keep Meeting Audio".
- The log records only events and errors, never what was said.

---

## 5. Troubleshooting

**The minutes only have my lines (nobody else).**
The system audio permission is not active. Open *System Settings › Privacy & Security › Screen & System Audio Recording* and turn on **Meeting Minutes** under **System Audio Recording Only**, or use **Check Permissions…** in the menu, which tests it with a sound. The `.md` itself shows a warning at the top when the system track was completely silent.

**The minutes don't have my lines.**
It is almost always the wrong microphone. Wired headphones **without a microphone** make the Mac show an "External Microphone" that only picks up hiss, and it becomes the system default. In the app menu, open **Microphone › Test Microphone…**; if it does not hear your voice, pick the Mac's microphone in the same menu. Also check *System Settings › Privacy & Security › Microphone*.

**The `.md` only has the transcript, no summary.**
The reason is written in the file. Most often the tool is not logged in. Open Terminal, run `claude` (Claude Code) or `agy` (Gemini), log in, then use **Regenerate Minutes from .md…** in the menu. If the warning says the Gemini model no longer exists, use **Minutes Model › Refresh Model List** and pick another one.

**The transcript is in the wrong language.**
Set **Meeting Language** in the menu to the language spoken in the meeting.

**The shortcut does nothing.**
Another app already uses that combination; the menu shows a warning. Pick another shortcut in the menu.

**The app quit in the middle of a meeting.**
The recording is kept. Open the app and use **Process Pending Recordings**.

**Diagnostics from Terminal:**

```bash
"/Applications/Meeting Minutes.app/Contents/MacOS/MeetingMinutes" --diagnose
```

It shows the app's permissions, the meeting language, whether the speech model is installed, who writes the minutes and how many recordings are pending. The same binary also accepts `--transcribe <audio>`, `--process <folder>` and `--regenerate <file.md>`.

---

## 6. Update, reinstall and uninstall

After changing the code (or pulling a new version), run `./scripts/install.sh` again. Because every build gets a new local signature, the installer resets the old permissions and the app asks for them again on launch (it is quick).

To uninstall:

```bash
osascript -e 'tell application id "local.meetingminutes" to quit'; rm -rf "/Applications/Meeting Minutes.app" ~/Library/Application\ Support/MeetingMinutes; tccutil reset All local.meetingminutes; defaults delete local.meetingminutes
```

Your minutes in `~/Documents/Meeting Minutes` are not deleted.

---

## 7. Known limitations

- **[Meeting] groups everyone else.** The app separates you from the others, but does not tell the other participants apart. The minutes use names when they come up in the conversation.
- **Any sound your Mac plays counts as [Meeting]**, including a video or an alert playing during the recording.
- **If you and someone else talk at the same time with speakers on**, some of your words may be dropped as echo. With headphones this does not happen.
- Transcript timestamps are accurate to about one second.
- Transcription quality is that of the macOS speech recognizer: very good for clear speech, worse with noise or several people talking at once.
- The app is not notarized by Apple, so it is built from source on your Mac rather than distributed as a download.

---

## 8. Code layout

```
Package.swift                     Swift package (builds with the Command Line Tools only)
Resources/Info.plist              Name, icon, permissions, "no Dock icon", meetingminutes:// links
scripts/build.sh                  Builds and assembles the .app
scripts/install.sh                Installs in /Applications and opens it
scripts/make-icon.swift           Draws the icon
Sources/MeetingMinutes/
  main.swift                      App entry point + command-line mode (--diagnose etc.)
  AppDelegate.swift               Icon, menu, states, processing queue
  HotKey.swift                    Global shortcut
  AudioCapture.swift              System audio (tap) and microphone capture, microphone test
  TrackWriter.swift               Writes each track aligned to the recording clock
  Recorder.swift                  Connects captures to tracks; pending recordings
  Transcription.swift             On-device transcription (SpeechAnalyzer)
  MeetingLanguage.swift           Meeting language and the translated headings of the minutes
  TranscriptBuilder.swift         [You]/[Meeting], time order, echo removal
  MinutesGenerator.swift          Minutes through Claude Code, Gemini (Antigravity) or the Claude API
  Processing.swift                From audio to .md; regenerate minutes from an .md
  Onboarding.swift                First launch and permissions
  Notifier.swift                  Notifications
  Support.swift                   Log, folders, settings, Keychain, helpers
```

---

## License

[MIT](LICENSE)
