# Italian Flashcards

A Quizlet-style flashcard app for your Italian vocabulary. No installs needed beyond the Python 3 that's already on your Mac.

## Run it

```
python3 server.py
```

…or double-click `start.command` in Finder. It opens http://127.0.0.1:8000 in your browser. Keep the terminal window open while you study; press Ctrl+C to stop.

## Flashcards

- Tick the categories you want in the left panel (**All** / **None** for quick selection).
- Click the card or press **Space** to flip it. **←/→** move between cards, **P** pronounces the Italian.
- The speaker button on the Italian side reads the term aloud. Pick a different Italian voice from the menu under the categories.
- **Front** chooses whether you see Italian or English first. **Shuffle** randomizes the deck; **Restart** goes back to card 1.

## Learn

Quizlet-style typing practice using the same category selection.

- **Answer with** Italian, English, or Both (mixed). Accent buttons (à è é ì ò ù) appear when answering in Italian.
- Answers ignore capitals, punctuation and extra spaces. Either part of an answer like `hi/bye` counts, notes like `(male)` are optional, and English answers can skip "the/a/to". A missing accent is accepted with a reminder.
- **Wrong?** You'll see the right answer. Click **Override: I was right** if your answer should count, or type the correct answer to continue. Missed terms come back in the next round.
- Terms come in rounds of 7. You get a summary after each round, and a results screen (with a "practice the ones I missed" option) once every term is mastered.
- **Auto-play audio** reads the Italian aloud as it appears.

## Manage terms

- **Add a term**: fill in Italian, English and a category. To create a new category, just type a new name.
- **Edit / delete**: use the pencil and trash icons on each row. Deleting shows an **Undo** button for a few seconds.
- **Move many at once**: tick rows, type a category in the bar that appears, and click **Move**.
- **Categories panel**: rename a category (renaming onto an existing name merges them) or delete it (keep its terms as Uncategorized, or delete them too).

## Data

Everything lives in `data/terms.csv` (columns `term,definition,category`), which you can also edit in Excel/Numbers. Changes in the app save there immediately. Your original 2-column file is kept as `data/terms_original.csv`.

## Cloud sync (GitHub)

This folder is the GitHub repo [c-rothschild/italian-flashcards](https://github.com/c-rothschild/italian-flashcards). Whenever you change cards on the website, `server.py` commits `data/terms.csv` and pushes it to GitHub a few seconds later. The Manage tab shows whether the last change synced. Only the CSV is committed automatically, never your other files. If you're offline, the push is retried after your next change and when the server starts. Use `python3 server.py --no-sync` to turn this off.

## iPhone app

`ios/` contains a native SwiftUI app (**Italiano**) with Flashcards, Learn and a category picker. It downloads the latest `terms.csv` from GitHub each time it opens. Pull down on the Categories tab to check again. It keeps a copy, so it also works offline. Cards are edited on the website, not in the app.

**Install it on your iPhone:**

1. Connect your iPhone to the Mac with a cable, then open `ios/ItalianFlashcards.xcodeproj` in Xcode.
2. Click the **ItalianFlashcards** project → **ItalianFlashcards** target → **Signing & Capabilities**. Under **Team**, choose your Apple ID (**Add an Account…** if it isn't listed). A free Apple ID works.
3. Choose your iPhone at the top of the Xcode window and press **Run** (▶).
4. On the iPhone, the first time only:
   - turn on **Settings › Privacy & Security › Developer Mode**
   - trust the app under **Settings › General › VPN & Device Management**

With a free Apple ID, the installed app stops opening after 7 days. Plug in and press Run again to renew it. A paid Apple Developer account ($99/year) removes that limit and allows TestFlight.

**Developing:** the Xcode project is generated from `ios/project.yml`. After adding or removing files, run `cd ios && xcodegen`. Tests: `xcodebuild -project ios/ItalianFlashcards.xcodeproj -scheme ItalianFlashcards -destination 'platform=iOS Simulator,name=iPhone 18 Pro' test`.

For more natural pronunciation, download an Enhanced or Premium Italian voice on the iPhone under **Settings › Accessibility › Spoken Content › Voices › Italian**, then pick it in the app's Categories tab.
