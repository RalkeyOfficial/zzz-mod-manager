# Writing conventions

How to write anything meant for a person to read: code comments, this directory's docs, `CHANGELOG.md` entries, commit messages, and a chat reply describing finished work.

## Write the present tense. Git holds the history.

No prose anywhere describes how the code got this way. Not code comments, not this directory, not a checked-off item.
This applies to every file except `CHANGELOG.md`, whose whole subject is what changed.

Delete on sight:

- what the code used to do — "this used to…", "the old flow…", "previously…", "N corrections to what this doc assumed";
- who or what found something — "a review found", "reported after the first use", "found by pressing it", "verified against the old code";
- the order things happened in — "then", "afterwards", "a fifth correction".

Keep the durable half, which is usually already in the same paragraph: the rule, the constraint, the measurement, the rejected alternative and why it loses.
"`<appData>/downloads` is shared, so delete the file and never the directory" is worth a comment forever. "This used to delete the parent recursively" is a commit message.

Two things that look like history and are not, so keep them:

- What is verified and what is not ("not yet run on Windows") — that is current state, and the reader needs it.
- A hazard that is still live ("two transfers of one file share a `.part`") — the fact is present tense even if a bug is what taught it.

## Report finished work as user experience, never as code

When telling the user what shipped, describe what they can see, click and test. Not the functions added or the files touched — a function name isn't testable.
It is the `CHANGELOG.md` rule applied to the terminal. An identifier appears only where the user would type or read it themselves: a menu item, a file on disk, a command.

In this order: what is different when using the app (the screen, the wording, what it now does); what did not change where they'd expect it to, since an omission found by trying it reads as a bug;
what to test, as numbered steps in the running app, including the ones that must produce nothing; then test counts and analyzer numbers, in a line — evidence, not the report.

State a limit as the behaviour the user will meet, never as the reason in the code: "a patch dragged in has no mod page, so only the mod it went into is checked for updates", not "that layer carries a null `mod_id`".
The reasoning is not dropped, it moves — decisions and rejected alternatives still go in this directory, in full.
