# Real recordings

Put your own recordings here to test Prosa with real voices: synthetic speech is easier than
real people, so these give the more honest numbers.

For each recording, add two files with the same name:

- `something.m4a` (or `.wav`): you reading a sentence or a paragraph, recorded with QuickTime
  Player (File › New Audio Recording) or Voice Memos;
- `something.txt`: exactly what you said.

Then run `python3 Tests/Evaluation/evaluate.py` and they appear as extra dictation cases.

Recordings are personal: `.m4a`, `.wav` and `.txt` files in this folder are ignored by git.
