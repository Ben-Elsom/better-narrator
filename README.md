# Better Narrator

A Mac menu-bar app that reads text aloud (usually Claude replies) with a natural local voice, highlights each word as it's spoken, and gives you real playback controls on the Touch Bar.

Everything runs on your Mac and works offline. The voice is [Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M), which is free and open source (Apache 2.0).

## Using it

1. Open **Better Narrator** from Applications or Spotlight. Its home window opens, and its icon (lines of text with one word lit up) appears in the menu bar. The voice engine takes a few seconds to warm up.
2. **Highlight** text in any app (once Accessibility is allowed, see below), or **copy** it with Claude's Copy button or ⌘C. A blue **Read** button appears on the right of the Touch Bar for 10 seconds. Clicking away from a highlight removes it again.
3. Press **Read**. The reading window opens, paused, while the audio is prepared. The play button fills in as audio gets ready.
4. Press **Start** on the Touch Bar or in the window.

Quit the app (⌘Q, or from the menu-bar icon) when you don't want copies to offer a Read button.

### Controls

| | Touch Bar | Window | Keyboard |
|---|---|---|---|
| Play / Pause | ⏯ | big blue button | Space, ⌘P, or the ⏯ key |
| Back 15 s | ↺15 | ↺15 | ← or ⌘[ |
| Forward 15 s | ↻15 | ↻15 | → or ⌘] |
| Jump to Live | — | button that appears when you scroll away | ⌘L |
| Dismiss reading | **Dismiss**, tap twice | close the tab | ⌘W |
| Speed | — | 1× menu (bottom right) | — |
| Voice | — | voice menu (bottom left) | — |

- **Click any word** to jump the audio there.
- **Progress bar:** blue is what you've heard, grey is audio that's ready. Drag to scrub through the ready part.
- **Several readings** open as tabs. Copying during a reading adds a Read button next to the controls.
- The **menu-bar icon** also has *Read Clipboard Aloud*, *Read Selected Text* (⌃⌥R), the voice and speed, and *Show Touch Bar Controls* if they ever disappear.
- **Text clean-up:** Markdown symbols aren't read out, code blocks are announced as "Code snippet", and passwords copied from a password manager are ignored.

### Permissions

- **Highlight to Read** and **⌃⌥R** need *Accessibility* permission (System Settings → Privacy & Security → Accessibility → Better Narrator). The home window has a button that opens the right page. Builds are signed with a local self-signed certificate ("Better Narrator Local Signing", kept in its own `better-narrator-signing` keychain), so the permission survives rebuilds. Without that certificate the build script signs ad hoc, and the permission needs re-enabling after each build.
- Copy-then-Read needs no permissions.
- Dictation apps such as Wispr Flow pause whatever is playing while you dictate, and that includes Better Narrator.

## Limitations

- On an Intel Mac, Kokoro makes speech roughly 1.5 to 2.5 times faster than it plays. At 1.5× or 2× speed, or when skipping far ahead in a long reply, the app may need to wait ("Catching up…").
- The Touch Bar controls use unofficial macOS features (the same ones Pock and MTMR use). They work on macOS 15.8, but a future macOS update could break them. The ⏯ key and Now Playing controls would still work.
- Images and diagrams aren't described.

## Building

Requires Apple's Command Line Tools, [uv](https://docs.astral.sh/uv/), and the Kokoro model files:

```bash
# one-time: download the model files into kokoro_test/models (git-ignored)
mkdir -p kokoro_test/models/timestamped
curl -L -o kokoro_test/models/timestamped/model.onnx https://huggingface.co/onnx-community/Kokoro-82M-v1.0-ONNX-timestamped/resolve/main/onnx/model.onnx
curl -L -o kokoro_test/models/voices-v1.0.bin https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/voices-v1.0.bin

# build and install to /Applications/Better_Narrator.app
scripts/build_app.sh
```

The script compiles the app with `swiftc`, draws the icons, bundles the model, sets up the voice engine's Python environment in `~/Library/Application Support/Better Narrator/engine-venv`, and installs the app.

### Layout

- `Sources/BetterNarrator/`: the Swift app (window, audio, Touch Bar, menu bar, clipboard)
- `Sources/TouchBarPrivate/`: the small Objective-C bridge to the unofficial Touch Bar calls
- `engine/narrator_engine.py`: the Kokoro speech engine. It streams audio sentence by sentence with word timings over stdin/stdout.
- `scripts/make_icons.swift`: draws the app and menu-bar icons
- `experiments/touchbar_test/`: the original Touch Bar takeover test

### Testing hooks

The app accepts `betternarrator://` URLs, which is handy for scripted tests: `read-clipboard`, `play`, `pause`, `toggle`, `skip?by=15`, `seek?t=30`, `speed?x=1.5`, `dismiss`, `state` (writes to `~/Library/Logs/BetterNarrator.log`) and `snapshot` (saves a picture of the reading window).
