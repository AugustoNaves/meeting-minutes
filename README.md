# Prosa

*Prosa* is Brazilian Portuguese for a chat (“trocar uma prosa”) and also for written prose: speech that becomes text. The icon shows the waves of Copacabana's sidewalk.

A macOS menu bar app that records your meetings with one keyboard shortcut: **your voice** (microphone) and **everyone else** (the sound your Mac is playing). When you stop, it transcribes everything **on your Mac** and saves structured meeting minutes as a Markdown file.

```
⌘⇧R  →  record  →  ⌘⇧R  →  on-device transcription  →  AI writes the minutes  →  .md + notification
```

- Works with Google Meet, Zoom, Teams, Slack or anything else that plays audio.
- No BlackHole or virtual audio drivers: it uses the system audio tap built into macOS.
- Separates what **you** said from what the **other people** said, in chronological order.
- The audio never leaves your Mac. Only the transcript text goes to the AI you choose.
- Minutes in the language of the meeting (any language the macOS speech recognizer supports).
- **Dictation:** hold **⌥Space** and talk: the words are typed where your cursor is while you speak, then corrected and cleaned up by the AI.
- **A glossary the AI builds by itself** from your dictations and minutes, so names like “GitHub” or “TypeScript” come out right.

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
git clone https://github.com/AugustoNaves/prosa.git
```

```bash
cd prosa && ./scripts/install.sh
```

The script builds the app (about a minute the first time), copies it to `/Applications/Prosa.app` and opens it. No password or Apple developer account needed: the app is signed locally (ad-hoc).

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
2. Press **⌘⇧R**. A short sound confirms it, and the icon turns red with the elapsed time: `● 12:34`. If your voice or the other people's audio cannot be recorded, the icon turns into an orange **⚠︎** with a warning sound, and the menu says what is wrong.
3. Press **⌘⇧R** again to stop. Another sound confirms it.
4. The icon shows **⌛ Transcribing…** and then **Writing minutes…**. Keep using your Mac normally.
5. A **"Minutes ready ✓"** notification arrives. Click it to open the file.

Files are saved as `~/Documents/Meeting Minutes/YYYY-MM-DD_HH-MM_Meeting.md`.

The shortcut works with any app in front, including full-screen apps.

> **Heads-up:** in Chrome and Safari, ⌘⇧R is also "hard reload". While Prosa is running, the shortcut belongs to it. If you use that browser command a lot, pick another shortcut in the menu (**Shortcut:** ⌃⌥⌘R, ⌥⇧R or ⌃⇧M).

### Dictation (type by voice)

1. Put the cursor where the text should go (an email, Slack, a document, a form…).
2. **Hold ⌥Space** and talk. The words appear in the text field as you speak, about a second behind your voice. A small pill at the bottom of the screen (“Calçadão”: two stripes shaped like the waves of Copacabana's sidewalk) swells with your voice, flows slowly while the text is being finished, and disappears when it is done. A dot on its left means hands-free.
3. **Release** the keys. The text is corrected in place.

A **quick tap** on ⌥Space starts hands-free mode instead: talk as long as you want and tap again to finish (up to 10 minutes).

What happens to what you say:

1. **While you speak**, a quick on-device transcriber types the words that are settled; the last word, still changing, waits until the next word or until you pause. While you speak it only adds words and never deletes; if the recognizer revises a word already typed (common after a pause), it keeps typing the new words and fixes the old one at the end. At the same time, the accurate transcriber listens to the same audio.
2. **When you finish** (release, or tap again in hands-free), the accurate text is ready about 0.2 seconds later, whatever the length, and with the **glossary** (“guit rabe” → “GitHub”) it replaces the live text. Only the part that differs changes: a few characters are retyped, anything bigger is selected and replaced in one paste, so the text never flickers. Dictation is ready for the next one right away.
3. If **Clean Up Text with AI** is on (default), the AI then, in the background, fixes punctuation, removes “é…”, “tipo”, “né” and stutters (deliberate repetitions stay), keeps only the final version when you correct yourself (“na terça, não, na quarta” → “na quarta”) and uses the glossary for names it has never seen spelled wrong. It corrects, it does not rewrite. The text changes once more about 5 seconds later with Gemini or Claude Code (1 to 2 seconds with a Claude API key), and only if nothing happened meanwhile: if you typed, clicked, switched apps or started another dictation, the clean-up is dropped and your text stays as it is. Turn it off to have no late change at all.

Live typing is careful with your text:

- it does not type live where the focus is clearly not a text field (a button, a list of files, a web page outside any text box, where letters can be shortcuts); there, the text is pasted at the end. Apps that do not say what is focused (Claude, Slack and other Electron apps) are typed into;
- it only ever deletes characters it typed itself;
- if you click, type or switch apps during a dictation, it stops changing the text and leaves it as you edited it.

Turn off **Type as You Speak** to have the whole text pasted once, at the end.

Typing into other apps needs **Prosa** turned on in *Privacy & Security › Accessibility*. The first-launch setup asks for it, and so does the first dictation if it is still off; until it is on, the text goes to the clipboard and a notification asks you to press ⌘V. Every reinstall turns it off again (see section 6). The log says, for every dictation, whether it typed live and why not.

The shortcut can be changed (or dictation turned off) in the menu, under **Dictation**.

### The glossary

`~/Documents/Meeting Minutes/Glossary.md` lists names and terms spelled exactly as they must be written, and the phrases the recognizer gets wrong:

```markdown
## Terms
- GitHub
- TypeScript

## Corrections
- guit rabe → GitHub
- taipe script → TypeScript
```

You do not have to write it. With **Learn Glossary Automatically** on (default), the AI reads your recent dictations (what the recognizer heard next to the corrected text) and your recent minutes (where names are spelled from context), and adds only what is new and clear. It never removes what you wrote. It learns after each meeting and after every 15 dictations, or right away with **Update Glossary Now**. You can edit the file at any time (**Open Glossary**); a wrong entry can simply be deleted.

The glossary is used by dictation and by the meeting minutes: corrections fix the transcript, and the terms go to the AI that writes the minutes.

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
| Dictation | The dictation shortcut (⌥Space, ⌃⌥Space, ⌥⇧D, ⌃⇧D or off), **Type as You Speak**, **Clean Up Text with AI**, **Learn Glossary Automatically**, **Update Glossary Now** and **Open Glossary** |
| Microphone | Which microphone records your voice (system default, the Mac's microphone, a headset…), plus **Test Microphone…** |
| Shortcut | Changes the key combination |
| Change Minutes Folder… | Saves the minutes somewhere else |
| Sound on Start and Stop | Turns the confirmation sounds on or off |
| Keep Meeting Audio | Also saves the audio in `Audio/` inside the minutes folder (`.m4a`, about 15 MB per hour). A recording where almost nothing was recognized is always kept, even with this off |
| Open at Login | Opens the app when you log in |
| Check Permissions… | Repeats the first-launch setup |
| Show Log | Opens `~/Library/Logs/MeetingMinutes.log` |

You can also control it with links (macOS Shortcuts, Raycast, Stream Deck): `meetingminutes://toggle`, `meetingminutes://start`, `meetingminutes://stop`.

---

## 4. How it works

| Step | How | Why |
|---|---|---|
| Menu bar and shortcut | AppKit (`NSStatusItem`) + `RegisterEventHotKey` (Carbon) | Native and light, works in full screen, needs no Accessibility permission |
| Other people's audio | Core Audio *process tap* (`CATapDescription`) | Captures the Mac's sound before it reaches the headphones: works with headphones on and **needs no BlackHole** or driver. With a headset that has its own microphone (Bluetooth earbuds), only the system audio stream is read, and the capture follows the headset when it switches to call mode |
| Your voice | Core Audio, reading the chosen microphone directly | Does not depend on the sound output, so it also works with a Bluetooth headset in call mode. If you switch microphones or the audio format changes mid-meeting, capture restarts on its own |
| Recording | Two separate tracks (`you.caf` and `meeting.caf`, 16 kHz mono), aligned to the system clock | Separate tracks = knowing who spoke without guessing |
| Transcription | macOS 26 `SpeechAnalyzer` / `SpeechTranscriber`, on device | Free, private and fast: in testing, 16 minutes of audio in 6 seconds, using about 22 MB of memory in the app |
| [You] vs. [Meeting] | Every sentence comes with per-word timing; both tracks are interleaved in time order | The conversation timeline stays correct |
| No duplicated echo | On speakers, the microphone also picks up the other people. Stretches of the microphone track that repeat, at the same moment, the words of the system track are dropped, as are stray words that leak from headphones while others talk | The same sentence never appears twice |
| Minutes | Claude Code (`claude -p`), Antigravity (`agy -p`, Gemini) or the Claude API, always with the response validated by a JSON Schema | The `.md` format is always the same, whoever writes it |
| Dictation | Global shortcut with key-down and key-up events. While speaking, a second `SpeechTranscriber` with `fastResults` + `volatileResults` in an analyzer of its own; its words are typed as Unicode keystrokes. At the end, the accurate transcription of the recording replaces them with the fewest keystrokes (delete back to the first difference, type the rest) | Partial results arrive about a second behind the voice only with `fastResults` and only in a separate analyzer (both tested); the accurate pass keeps the final text as good as before |
| Dictation without live typing | Clipboard + a simulated ⌘V, then the clipboard is restored | Works in any app, also where typing is not possible |
| Dictation clean-up | The same minutes writer, with its smallest and quickest model (Claude Haiku 5.5, or a Gemini “flash” model at low effort) | Speed matters more than depth for a few sentences |
| Glossary | Corrections applied on the Mac to every dictation and transcript; terms sent to the AI that cleans up or writes the minutes; new entries proposed by the AI from your dictations and minutes | The macOS recognizer has no custom vocabulary (`AnalysisContext` was tested and has no effect on it), so names are fixed after recognition |

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

Dictation clean-up uses the smallest model (a few hundred tokens per dictation). Glossary learning sends recent dictations and up to 4 recent minutes (about 5,000–15,000 tokens) after each meeting and every 15 dictations.

Estimate for **one hour of meeting** (about 15,000 transcript tokens): Opus ≈ US$ 0.10; Sonnet ≈ US$ 0.04; Haiku ≈ US$ 0.003. The app calls Claude Code with no tools, no history and no prompt cache (for a single call the cache would only add cost), at "medium" effort, to keep usage low. Antigravity is an agent and adds about 10,000 tokens of its own instructions to every call; those come out of your Google allowance. Antigravity lists its models by codename (Gemini 4 Neon, Argon, Hydrogen, 3.8 Flash); on a Google AI Pro plan, **Gemini 4 Neon** is the most capable one available.

### Privacy

- **The audio never leaves your Mac.** Transcription is done by macOS itself, offline.
- Only the transcript **text** is sent to write the minutes: to Anthropic (Claude Code or API) or to Google (Gemini through Antigravity), depending on your choice in the menu, under the terms of the account you use.
- Raw audio is deleted once the minutes are saved, unless you turn on "Keep Meeting Audio" or almost nothing was recognized in a long recording (then it is kept in `Audio/`, so a meeting is never lost to a recording problem).
- **Dictation:** the audio never leaves your Mac either. The text goes to the AI only while **Clean Up Text with AI** is on.
- The last 300 dictations are kept on your Mac (`~/Library/Application Support/MeetingMinutes/dictations.jsonl`) for the glossary. When the glossary learns, recent dictations and minutes are sent to the AI you chose. Turn off **Learn Glossary Automatically** to stop that.
- The log records only events and errors, never what was said.

---

## 5. Troubleshooting

**The minutes only have my lines (nobody else).**
The system audio permission is not active. Open *System Settings › Privacy & Security › Screen & System Audio Recording* and turn on **Prosa** under **System Audio Recording Only**, or use **Check Permissions…** in the menu, which tests it with a sound. The `.md` itself shows a warning at the top when the system track was completely silent.

**The minutes don't have my lines.**
It is almost always the wrong microphone. Wired headphones **without a microphone** make the Mac show an "External Microphone" that only picks up hiss, and it becomes the system default. In the app menu, open **Microphone › Test Microphone…**; if it does not hear your voice, pick the Mac's microphone in the same menu. Also check *System Settings › Privacy & Security › Microphone*.

**The `.md` only has the transcript, no summary.**
The reason is written in the file. Most often the tool is not logged in. Open Terminal, run `claude` (Claude Code) or `agy` (Gemini), log in, then use **Regenerate Minutes from .md…** in the menu. If the warning says the Gemini model no longer exists, use **Minutes Model › Refresh Model List** and pick another one.

**The icon turned orange (⚠︎) during a recording.**
Your voice or the other people's audio could not be recorded, or stopped and could not restart. Open the menu: the reason is written under the status line, and it also goes to the top of the `.md` and to the log (lines starting with "Recording problem").

**The minutes say almost nothing was recognized.**
When a recording of 2 minutes or more gives fewer than 5 words per minute, something went wrong with the audio, so the app keeps it in `Audio/` inside the minutes folder (`…_you.m4a` and `…_meeting.m4a`) and says so at the top of the `.md`. You can listen to it, or transcribe it from Terminal with `--transcribe` (see below).

**Dictation only copies the text (a notification says to press ⌘V).**
Prosa is not allowed to type into other apps yet. Open the menu › **Dictation** › **Allow Typing into Other Apps…** and turn on **Prosa** in *Privacy & Security › Accessibility*. After every reinstall it has to be turned on again.

**The dictation shortcut does nothing.**
Another app (Raycast, ChatGPT, Alfred…) already uses ⌥Space; the menu shows a warning. Pick another shortcut under **Dictation**.

**A name keeps coming out wrong.**
Open the glossary (**Dictation › Open Glossary**) and add it under *Terms*, or add what the recognizer hears under *Corrections* (`- what it hears → what it should be`).

**The transcript is in the wrong language.**
Set **Meeting Language** in the menu to the language spoken in the meeting.

**The shortcut does nothing.**
Another app already uses that combination; the menu shows a warning. Pick another shortcut in the menu.

**The app quit in the middle of a meeting.**
The recording is kept. Open the app and use **Process Pending Recordings**.

**Diagnostics from Terminal:**

```bash
"/Applications/Prosa.app/Contents/MacOS/MeetingMinutes" --diagnose
```

It shows the app's permissions, the meeting language, whether the speech model is installed, who writes the minutes and how many recordings are pending. The same binary also accepts `--transcribe <audio>`, `--process <folder>`, `--regenerate <file.md>`, `--dictate <audio>` (runs dictation on an audio file and prints each stage; nothing is typed), `--dictate-live <audio>` (plays an audio file into live dictation at real speed and prints what would be typed while speaking and at the end) and `--learn-glossary` (updates the glossary now).

---

## 6. Update, reinstall and uninstall

After changing the code (or pulling a new version), run `./scripts/install.sh` again. Because every build gets a new local signature, the installer resets the old permissions and the app asks for them again on launch (it is quick).

To uninstall:

```bash
osascript -e 'tell application id "local.meetingminutes" to quit'; rm -rf "/Applications/Prosa.app" ~/Library/Application\ Support/MeetingMinutes; tccutil reset All local.meetingminutes; defaults delete local.meetingminutes
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
  HotKey.swift                    Global shortcuts (recording, and hold-to-talk dictation)
  Dictation.swift                 Dictation: shortcut, live typing, the Calçadão indicator, clean-up, pasting, history
  LiveTranscription.swift         Words as you speak them (quick on-device transcriber)
  Glossary.swift                  Glossary.md: reading, applying, and learning new entries with the AI
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
