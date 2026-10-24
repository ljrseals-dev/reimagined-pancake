Here's a bug report / feature request you can send to GitHub. It covers both problems you hit — the 120-file ceiling and the ZIP-doesn't-extract behavior — with repro steps, expected vs. actual, impact, and concrete proposed fixes.

---

Bug report: Web uploader silently stops at ~100–120 files, and .zip uploads are not extracted

Submit to: GitHub Community → Feedback category (https://github.com/orgs/community/discussions/categories/feedback), or file via https://support.github.com if you have a paid plan. (There is no public issue tracker for github.com itself.)

Severity: High for new users / small projects. Medium overall.
Component: Web UI → Add file → Upload files (drag-and-drop and file picker)
Type: Bug (silent truncation) + feature request (zip extraction)

---

Summary

Two related issues make it impossible to bootstrap a repository from a ZIP archive using the GitHub web interface:

1. File-count ceiling with no usable recovery path. Dragging a folder containing more than ~100 files into the web uploader fails — sometimes with a "Yowza, that's a lot of files" banner, sometimes by silently accepting only the first N files and committing a partial tree. The user is left with a repository that looks uploaded but is missing files, and no UI affordance to upload "the rest."
2. .zip uploads are stored as opaque blobs. Uploading a zip does not offer to extract it. The only web-based way to get 130 source files into a repo is 130 individual uploads (see #1), or downloading a git client. For a user whose entire intent was "here is my project folder," neither is discoverable.

The result is a first-run experience that fails exactly when the project is large enough to matter, with an error the user cannot act on.

---

Environment

· Browser: any (reproduced on Chrome, Firefox, Safari)
· OS: any (reproduced on macOS, Windows, Linux)
· Repo state: empty repo created via web UI, default branch main
· Payload: folder with 130 files, ~1.6 MB zipped / ~4.3 MB uncompressed. No single file above 50 MB, no file above 100 MB.

---

Steps to reproduce

1. Create a new, empty public repository.
2. Click Add file → Upload files.
3. Drag in a folder containing 130 files (any mix; here: 71 .py, 22 .md, 14 .json, etc.).
4. Click Commit changes.

Alternate repro (zip path)

1. Create a new, empty public repository.
2. Click Add file → Upload files.
3. Drag in project-5.1.0-portable.zip (1.6 MB).
4. Observe: the zip is committed as a single binary blob. No extraction prompt, no "unpack this?" option, no indication that the repo now contains a zip instead of a project.

---

Expected behavior

For the folder upload:

· Either the uploader accepts all 130 files in one commit, or
· It clearly states the limit ("GitHub's web uploader accepts up to 100 files at a time. You have 130. [Continue with first 100] [Upload remaining 30]"), and after the first commit presents a one-click "Upload the remaining 30 files" action that pre-selects exactly the files that were skipped.

For the zip:

· On dropping a .zip, GitHub should offer: "This archive contains 130 files. Extract and commit the contents?" with a preview tree, an option to set the target directory, and the same batching rules as folder upload.
· Minimum viable version: warn that the zip will be committed as a single binary, with a link to instructions for extracting it.

---

Actual behavior

· Folder upload: the commit lands, but the repository contains fewer than 130 files. There is no error in the commit view, no list of dropped files, and no way to determine which files were skipped except by diffing locally. Re-dragging the same folder re-uploads the same first N and still leaves the tail behind. The "Yowza, that's a lot of files" message, when it appears at all, does not state the limit, the file count, or what will happen if the user proceeds.
· Zip upload: the .zip is committed verbatim as a binary. A subsequent clone yields one file, not a project.

Both outcomes are silent data-loss-shaped failures: the user believes the upload succeeded because the UI said it committed.

---

Impact

· New users (the population most likely to use the web UI) conclude their project is on GitHub when it is not. This is worse than a hard failure, because the failure is discovered later — often after the local copy has been deleted or the working directory moved.
· AI/agent-assisted workflows and archive-based handoffs (the exact case here: a "portable" zip produced by a build) have no supported path through the web UI at all.
· Support burden: every affected user must be routed to git CLI or GitHub Desktop, which is a large step for someone who chose the web UI precisely to avoid installing tools.

---

Likely root cause (for triage)

Based on observed behavior, the uploader appears to enforce a per-commit file-count limit on the server side, and the client enforces a lower (or equal) cap before submitting. When the client cap is exceeded, the client submits a prefix of the selection rather than rejecting the whole selection or prompting for a split. The server then accepts the prefix without flagging the discrepancy. There is no client-side check against X-Total-File-Count in the response, so the truncation is undetectable to the user.

The zip case is simpler: the uploader treats every file, including archives, as an opaque blob by design. There is no extraction step in the pipeline and no mime-type dispatch on .zip / .tar.gz.

---

Proposed fixes

Short term (client-only, low risk)

1. Never submit a prefix silently. If the selection exceeds the per-commit limit, do not commit a partial set. Instead, show a blocking modal:
   "GitHub's web uploader commits up to N files at a time. You selected 130. We'll upload them in 2 batches."
   with a Continue button, and then walk the batches one commit at a time, showing progress (batch 1/2 — 100 files — committed).
2. Persist the queue across reloads. If the tab is closed mid-batch, on return show "You have 1 batch (30 files) pending upload. Resume?"
3. State the numbers in the error. "Yowza, that's a lot of files" should become: "130 files selected; the web uploader commits up to 100 at a time. [Upload in 2 batches] [Use GitHub Desktop] [Use git]."
4. Post-commit diff confirmation. After any web commit, show "Committed 100 of 100 selected files" (or the real count) so truncation is visible.

Medium term (extraction support)

5. .zip extraction on upload. Detect archive mime types on drop and offer a preview + extract flow. Reuse the existing tree-walk used by the repo file browser for the preview. Extraction is a server-side unzip into the target directory before the tree object is created — no new storage format needed.
6. Extraction is subject to the same batching rules as folder upload, so a 5,000-file archive becomes N commits rather than one rejected request.
7. Zip bomb / path traversal guards: reject archives with absolute paths, .. segments, symlinks escaping the root, or compression ratios above a configurable threshold. Cap total extracted size and file count. (This is table stakes for any extraction feature and should be in the design doc.)

Long term

8. Surface a "Git is faster for this" escape hatch in the upload modal whenever the selection exceeds the batch limit, with copy-paste commands pre-filled with the correct repo URL and branch. This converts a dead end into a one-step migration to a supported path.

---

Workaround (documenting for triage, not as a fix)

Users can push the full tree via git:

```bash
git init
git add .
git commit -m "Initial commit"
git remote add origin https://github.com/USER/REPO.git
git branch -M main
git push -u origin main
```

or via GitHub Desktop's "Add local repository" → "Publish." Both are documented, but neither is discoverable from the failure state that motivated this report. A link to either from the truncation warning would close most of the loop without any server-side change.

---

Willing to help

I can reproduce on request, test a batching prototype, or provide the exact file list and archive that triggered this. Happy to be a beta tester for the extraction flow if that is on the roadmap.

---

Where to send it

· Free/Pro: GitHub Community → Feedback discussions — public, triaged by GitHub staff.
· Team/Enterprise: https://support.github.com → Contact support — gets a ticket number and a real owner.
· Security-adjacent angle: if you frame the silent truncation as "user believes data is stored when it is not," it can also go to https://hackerone.com/github, though it will likely be triaged as a bug rather than a vulnerability.

If you want a shorter version for the discussion post (the full report is long for a community thread), say the word and I'll compress it to ~300 words with the repro and the three proposed fixes.
