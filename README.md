# Better Narrator

A Mac menu-bar app that reads text aloud (usually Claude replies) with a natural local voice, highlights each word as it's spoken, and gives you real playback controls on the Touch Bar.

Everything runs on your Mac and works offline. The voice is [Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M), which is free and open source (Apache 2.0).

## Using it

1. Open **Better Narrator** from Applications or Spotlight. Its home window opens, and its icon (lines of text with one word lit up) appears in the menu bar. The voice engine takes a few seconds to warm up.
2. **Highlight** text in any app (once Accessibility is allowed, see below), or **copy** it with Claude's Copy button or ⌘C. A blue **Read** button appears on the right of the Touch Bar for 10 seconds. Clicking away from a highlight removes it again.
3. Press **Read**. It starts talking a few seconds later, once enough audio is ready. No window opens: use the Touch Bar controls, or choose **Show Reading Window** from the menu-bar icon to follow the blue highlight. To have the window open every time, tick **Open Window When Reading Starts** in that menu.

Use the **On/Off** switch in the home window (or *Turn Off Better Narrator* in the menu-bar icon) when you don't need it. Off stops the voice engine and stops watching copies and highlights, so it uses no CPU. Quitting (⌘Q) does the same.

### Controls

| | Touch Bar | Window | Keyboard |
|---|---|---|---|
| Play / Pause | ⏯ | big blue button | Space, ⌘P, or the ⏯ key |
| Back 15 s | ↺15 | ↺15 | ← or ⌘[ |
| Forward 15 s | ↻15 | ↻15 | → or ⌘] |
| Jump to Live | — | button that appears when you scroll away | ⌘L |
| Show or hide the text | page button (lit while the text is in front; if it's behind another window, one press brings it back) | close button | ⌘W |
| End the reading | ✕ | menu-bar icon → Stop Reading | |
| Speed, 1× to 5× in steps of 0.1 | slide the wheel | slide or scroll the wheel | |
| Voice | — | voice menu (bottom left) | — |

- **Click any word** to jump the audio there.
- **Progress bar:** blue is what you've heard, grey is audio that's ready. Drag to scrub through the ready part.
- **History:** the home window keeps the last five readings, so you can play them again after they've left the clipboard. They're stored only on this Mac, in `~/Library/Application Support/Better Narrator/history.json`.
- **Links** are spoken as the site's name ("anthropic dot com"), with no https, www, slashes or path.
- **Touch Bar:** Read appears at the far right when there is something to read. Once pressed it goes away, and the play button shows the percentage until talking starts. ✕ ends every open reading, and is disabled during that wait. If [Touch Bar Pet](https://github.com/Ben-Elsom/touch-bar-pet) is running, its cat appears live at the far left, because macOS shows only one app's bar at a time (`CatMirrorView.swift` is copied from that project).
- **Several readings** open as tabs. Copying during a reading adds a Read button next to the controls.
- The **menu-bar icon** also has *Read Clipboard Aloud*, *Read Selected Text* (⌃⌥R), the voice and speed, and *Show Touch Bar Controls* if they ever disappear.
- **Highlights keep their formatting:** pressing Read on a highlight copies it (then puts your clipboard back), so headings, lists, paragraphs and code come through. Better Narrator doesn't ask web-based apps like Claude to turn on their extra accessibility data, which would cost them CPU.
- **When Read is offered:** in apps that don't say what's highlighted, such as Claude, a drag or double-click only counts if the text cursor showed, and Shift only counts with an arrow, Home, End, Page Up or Page Down. If an app rewrites the clipboard with the same text, Read stays away unless you clicked or pressed ⌘C or ⌘X in the last 2 seconds.
- **Text clean-up:** Markdown symbols aren't read out, code blocks are announced as "Code snippet", and passwords copied from a password manager are ignored.

### Permissions

- **Highlight to Read** and **⌃⌥R** need *Accessibility* permission (System Settings → Privacy & Security → Accessibility → Better Narrator). The home window has a button that opens the right page. Builds are signed with a local self-signed certificate ("Better Narrator Local Signing", kept in its own `better-narrator-signing` keychain), so the permission survives rebuilds. Without that certificate the build script signs ad hoc, and the permission needs re-enabling after each build.
- Copy-then-Read needs no permissions.
- Dictation apps such as Wispr Flow pause whatever is playing while you dictate, and that includes Better Narrator.

## Limitations

- On an Intel Mac, Kokoro makes speech roughly 1.5 to 2.5 times faster than it plays. At 1.5× or 2× speed, or when skipping far ahead in a long reply, the app may need to wait ("Catching up…").
- The Touch Bar controls use unofficial macOS features (the same ones Pock and MTMR use). They work on macOS 15.8, but a future macOS update could break them. Better Narrator leaves the keyboard's ⏯ key and the Now Playing controls to your other apps, so music keeps its own controls. A reading only pauses from its own buttons.
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

The app accepts `betternarrator://` URLs, which is handy for scripted tests: `read-clipboard`, `play`, `pause`, `toggle`, `skip?by=15`, `seek?t=30`, `speed?x=1.5`, `dismiss`, `toggle-window`, `history?i=0`, `state` (writes to `~/Library/Logs/BetterNarrator.log`) and `snapshot` (saves a picture of the reading window).
