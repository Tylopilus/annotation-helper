---
name: annotation-helper
description: See the user's screen and let them point at things, via the annotation-helper MCP tools (list_sessions, get_session, get_image, annotate_screen). Use when the user mentions a recording, a session, a screenshot, "what I showed you", "look at my screen" or "let me show you"; when the task is about anything visible (UI, layout, styling, a web page, a desktop app, an error dialog); whenever you are about to ask the user which or where something on screen is (ask with annotate_screen instead of in text); and after changing something visible, to let the user mark what is still wrong.
---

# Working with the user's screen

The `annotation-helper` MCP server connects you to the user's Windows screen. The user records
**sessions**: they talk while drawing numbered annotations (`#N` boxes, ellipses, arrows,
highlights) on screenshots of any app. You can also ask them a question **on their screen** and
get back what they drew and said.

## 1. The user recorded something

Triggers: "my recording", "the session", "what I showed you", "I recorded the bug", or the user
starts a task that a recent recording obviously belongs to.

1. `get_session` without `session_id` loads the latest session (`list_sessions` if they mean an
   older one). It returns a timeline: the user's narration `[mm:ss]` interleaved with the
   annotated screenshots.
2. Read it as one explanation. "This", "here" or "that one" refers to the annotation drawn at
   about the same time; `#N` in the narration is annotation N. Arrows point from → to and
   usually express a relation ("this value should come from there").
3. Each annotation names the UI element under it (role, name, app, window title, text). Use
   those strings to find the code: search the repo for the label text, automation id, class
   name or route. For code editors and canvases the element is generic; trust the image.
4. Images: the session includes annotated frames and zoomed crops (`frame-NN-aMM.png`). Fetch
   more with `get_image` only if you need them (e.g. `frame-NN-clean.png`, the same screen
   without drawings, or a higher `max_edge` to read small text).
5. The transcript is offline speech recognition and can contain wrong words; interpret it in
   context and ask if something important is unclear.

If the work clearly needs a repository you don't have, ask which one; a session can also be the
whole task (a bug report, a spec, a review comment) without any code.

## 2. Ask on the screen instead of in text

Call `annotate_screen` when the answer is **a place on the screen**:

- "Which button do you mean?" / "Circle the element that should change."
- "Mark where the layout breaks." / "Highlight the text that is wrong."
- "Draw an arrow from the field to where its value should come from."

`prompt` is one short, concrete question; it appears in a banner on their screen. Keep
`voice` on (default) so they can explain while drawing. The call blocks until they press Esc
(up to 10 minutes). If they cancel, you get an error; then ask in text instead.

Don't use it for questions that words answer just as well (yes/no, names, preferences), for
things you can find out yourself from code or logs, or several times in a row: one question,
then work with the answer.

## 3. After a visible change

When you changed something the user can see running (a page, a dialog, a component), you may
ask: `annotate_screen` with "Mark anything that still looks wrong, or press Esc if it's fine."

## Notes

- `annotate_screen` exists only when the server runs as the Windows app; if the tool is missing,
  fall back to text questions.
- Results give paths both as Windows (`C:\...`) and WSL (`/mnt/c/...`) paths; use the one that
  matches your environment if you open files directly.
