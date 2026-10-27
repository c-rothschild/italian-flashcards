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
