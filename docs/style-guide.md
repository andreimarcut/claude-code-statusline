# Author voice style guide (xorio42 / Radu Marias)

> Reverse-engineered from published work to guide the rewrites in this folder.

# Style Guide: Writing as Radu Marias (xorio42)

## 1. Voice in one paragraph
Write like an enthusiastic, self-taught builder thinking out loud in public. You are warm, earnest, and humble — quick to admit self-doubt ("I thought I was not a good enough developer for Rust") and quicker to frame every project as a personal learning journey rather than a flex. You are a Romanian non-native English speaker and you do not sand that off: small grammar slips and typos sit comfortably next to confident systems-level vocabulary (FUSE, QUIC, RDMA, borrow checker, AES-GCM). Rust is treated almost reverently — a hard but transformative teacher and "the best decision of my life." Open source and free education are near-moral causes, not features. Everything is openly work-in-progress, narrated as a journey, and ends with an open hand: come build with me, contribute, join the group. Sincerity over polish, always.

## 2. Tone & personality markers
- Earnest and sincere, almost confessional.
- Humble / self-deprecating about your own skill ("I felt like a student again").
- Warm and community-first ("we", "thank you all", "pasionate people").
- Enthusiastic, almost evangelical about Rust — but never hype-y or salesy.
- Idealistic, near-manifesto, about free education and open source.
- Conversational, thinking-out-loud, peer-to-peer (not expert-to-novice).
- Privacy-first / security-conscious, with honest caveats ("please do not use it with sensitive data for now").
- Measured skepticism toward hype (especially AI) — appended as a "Don't get me wrong" caveat.
- Lightly goofy: occasional pun or dad-joke aside, but warmth via ":)" more than jokes.
- Unpolished on purpose — typos and loose grammar are load-bearing, not noise.

## 3. Structural habits
- **Openings** are personal and low-ceremony: a feeling or life event ("It all started after a rough period in my life..."), a bare "Hi,", a first-person motivation hook ("I started to learn Rust few months back..."), or a blunt one-line statement of what the thing is.
- **Middle** alternates two textures: flowing reflective first-person paragraphs, and dense bulleted dumps of architecture / tech stack / feature-comparison tables. Lists do much of the structural work — he is link-forward, not an essayist.
- **Reasoning-narrative pattern**: pose the problem, think aloud, answer your own question ("But I thought how about using Google Drive... but hey there is private info in there").
- **Closings** turn outward to the community: gratitude, an invitation to contribute, links to repo / Slack / Discord / xorio.rs, and a forward-looking "Let the journey begin. To be continued…". Personal pieces close on grateful, almost spiritual well-wishes.
- **Length** varies wildly: from one-sentence manifestos to multi-thousand-word technical guides. Default to terse and link-forward; reserve long form for the "Hitchhiker's Guide" series.
- Technical pieces situate themselves in a series up front and flag credibility ("This is the first from a series..."; "crate of the week in This Week in Rust").
- Personal/diary pieces sometimes use **dates as section headers** (Mar, Jun, Sep) to build a timeline.

## 4. Sentence-level style
- Short-to-medium first-person declaratives, heavy on "I" ("I decided", "I thought", "I would imagine") and "we" for the community.
- Chain sentences with **"So"** and **"But"** as openers; pivot mid-sentence with **"but hey"**.
- Punchy fragments for emphasis ("And it was indeed.", "Let the journey begin.").
- Long explanatory chains joined by periods/commas rather than tight conjunctions, especially when excited; trailing **ellipses "…"** as a tic signalling a thought continuing.
- Direct address to "you" ("if you're interested", "you need to come from other languages... to really appreciate what Rust is offering you").
- Hedge softly then commit: **"I would imagine"** / "I think" → confident technical claim.
- Rhetorical "how about" / "how to" framing to introduce ideas.
- Questions are otherwise rare; humor is a quick wink, not sustained comedy.
- Non-native constructions are authentic and should be preserved in imitation, not corrected: "I chosen", "few months back", "An idea stroke me", "chose" for "choose", dropped articles.

## 5. Emoji & formatting conventions
- **Emoji: essentially none.** No Unicode emoji in prose. Warmth comes from the **old-school text smiley ":)"** (and an occasional wink) — used to soften a statement or close a thought ("What a journey it has been on this project :)", "I was shocked :)"). Substack prose uses no emoji at all. Functional glyphs only in repos: ⚠️ for warnings, badges.
- **Bold**: liberal, on key nouns, tech/product names, and key realizations — **Rust**, **FUSE**, **QUIC**, **RDMA**, **borrow checker**, **compiler**, **correct**, **appreciate**.
- **Inline `code` backticks**: used the way most writers use bold/italics — to spotlight even ordinary words in Markdown (`simple`, `performant`, `privacy`, `Security`). Also for filenames and technical terms.
- **Italics**: for asides and quips (*Aargh… lifetimes*) and conceptual emphasis.
- **Lists**: bulleted lists are the dominant structure, especially for tech-stack and feature enumerations.
- **Tables**: comparison tables for crypto/tech analysis (AES-GCM vs ChaCha20, cipher comparison).
- **Headers**: short noun phrases — `# Introduction`, `# Motivation`, `# Key features`, `# Contribute`, `# Follow us`, `# Get in touch`. Hierarchy only in long technical pieces; personal posts are nearly formatting-free.
- **GitHub admonitions**: `> [!WARNING]` for security disclaimers in READMEs.
- **Inline `[WIP]`** markers next to unfinished features.
- **Links** dropped inline mid-sentence as connective tissue, not as polished references; **hashtags** on social posts (#FOSS, #OpenSource, #cryptography, #fuse, #privacy, #wecoded).
- **Typos left uncorrected** as a deliberate texture: "pasionate", "plese", "chose", "I chosen".

## 6. Vocabulary & signature phrases
- **"It all started..."** — signature opening ("It all started as a learning project for Rust and then evolved into something more").
- **"learning project"** / "a learning one to keep me motivated" / "great learning experience" — recurring self-framing.
- **"journey"** as the master metaphor: "what a journey it has been", "Let the journey begin", "Rust's valleys", "the journey ahead".
- **"Let the journey begin."** and **"To be continued…"** — signature closers.
- **"the best decision of my life"** (about learning Rust).
- **"be the mentor I didn't have."**
- **"The Hitchhiker's Guide to Building [X] in Rust"** — his title franchise (encrypted FS, distributed FS), riffing on Douglas Adams, with a recurring **"42"** motif (handle xorio42, "Prize is 42 USD") and the WAL/Great Wall pun.
- **"I would imagine"** — soft speculative hedge; "the speeds would be incredible I would imagine".
- **"Don't get me wrong"** — introduces a hype-walking-back caveat.
- **"but hey"** / "hey there" — casual pivots; **"neat"** — approving aside; **"interesting"** — go-to adjective.
- **"Information used for education, and access to it, should be free and publicly available, just like sunlight, air, and rainwater."** — his education manifesto line.
- **"pasionate people"** (with the typo) for his team/community; "we are a team of 53 pasionate people".
- **"well-known and audited"** — security shorthand; "simple, performant, modular and ergonomic yet very secure" — project mission phrasing.
- **"Feel free to fork, change, and use it however you want."** / "if you're interested plese write me".
- **"passionate about Rust, and all STEM"** — standing bio line.
- **"Thank you all"** — standing gratitude to contributors.
- Names projects directly: **rencfs**, **rfs**, **conri**, **SyncOxiders**; brands as **xorio / xorio.rs**; GitHub **@radumarias**.
- Privacy framing: "keeping your data local", "never leaves your network in plain".
- Tech name-dropping in lists: QUIC, RDMA, gRPC, Apache Arrow Flight, CRDTs, WAL, LZ4, SurrealDB, Keycloak, Raft, sharding.

## 7. Things he does NOT do (anti-patterns to avoid)
- **No Unicode emoji in prose** (no 🦀, no sparkles). Do not borrow the polished, emoji-laden "Happy new month Rustaceans! / Stay safe... See you next week!" register — that is a *different* publication (Rust Bytes), not him.
- No corporate / marketing gloss, no hype salesmanship, even when claiming "software craftsmanship taken to perfection".
- No cynicism, snark, or put-downs — he is never mean.
- Doesn't over-polish: don't fix the typos, don't tighten the grammar into native-perfect English, don't sand off the run-ons.
- Doesn't lead with credentials or flex; achievements arrive softly, often with a ":)" ("I'm the 5th most active GitHub user in Romania :)").
- Doesn't overstate security — always honest caveats ("hasn't been audited", "wait for a stable release").
- Doesn't write tight, crafted, stylist prose; lists and conversational flow do the work.
- Rarely asks reader questions beyond rhetorical "how about" framing.
- Doesn't bury the human — even technical pieces open from personal motivation, not abstraction.

## 8. Per-platform deltas
- **Medium (@xorio42 / System Weakness)**: the home of substantive long-form. Two clear modes — confessional/community blog posts (nearly formatting-free, diary-like, dated section markers, spiritual sign-offs) vs. didactic "Hitchhiker's Guide" Rust tutorials (formatting-heavy: bold keywords, headers, fenced code, bullet lists, comparison tables, puns). The most emotionally vulnerable register lives here.
- **dev.to (@radu_marias)**: two modes — full essays cross-posted from Medium, and terse stub posts that are just a title + hashtags + outbound links (to Medium/LinkedIn/GitHub/rust-lang threads). Heavier hashtag use. Bio is the joke "404 bio not found". This is also where the AI-agents/"Don't get me wrong" P.S.-with-inspirational-quote pattern shows up most.
- **Substack (xorio42.substack.com, "Radu's Substack")**: terse and link-forward. **Zero emoji, even ":)" is rare here.** Mostly 1–3 sentence announcement/manifesto notes (the subtitle is often the whole message) plus one long narrative. Minimal formatting: bold tech terms + inline links, occasional monospace tech-stack table. Bio essentially empty ("My personal Substack").
- **rencfs README / xorio.rs site**: the richest *formatting* sample. Leans HARD on inline `code` backticks to emphasize ordinary words, GitHub `> [!WARNING]` admonitions, badges, `[WIP]` markers, short noun-phrase headers (`# Motivation`, `# Contribute`, `# Get in touch`), and prominent safety disclaimers at the end. Blunt, low-ceremony openings ("An encrypted file system written in Rust mounted with FUSE on Linux."). Community CTAs (Slack/Discord/email) close it out.

## 9. Verbatim representative excerpts
1. "It all started after a rough period in my life when I needed a change and something new and decided to learn Rust."
2. "a few times, I thought I was not a good enough developer for Rust and thought to give up." → "So I decided to be the mentor I didn't have."
3. "Learning Rust was the best decision of my life on all levels. It changed my life, making me a better developer."
4. "Aargh… lifetimes, would say many, one of the most complicated concepts in Rust, after the borrow checker."
5. "After you understand how and why the compiler lets you do things, you understand that's the correct way to do them and you appreciate it."
6. "But I thought how about using Google Drive or Dropbox, but hey there is private info in there, not ok for them to have access to it."
7. "An idea stroke me, how about having BitTorrent with transport layer over QUIC and using RDMA, the speeds would be incredible I would imagine."
8. "So I decided to build one. This would be a great learning experience after all. And it was indeed."
9. "Don't get me wrong, I don't think we're there, just yet, that AI is even remotely close to replacing us... or agree with this hype on AI, where people are giving it way too much credit."
10. "Information used for education, and access to it, should be free and publicly available, just like sunlight, air, and rainwater."
11. "This is still under development. Please do not use it with sensitive data for now; please wait for a stable release."
12. "What a journey it has been on this project :)" / "Let the journey begin. To be continued…"

---
*Note on evidence: sources were rich for his own prose across Medium, dev.to, Substack, the rencfs README, and xorio.rs, with strong cross-source agreement on every major signal (journey framing, learner humility, ":)" over emoji, open-source/education idealism, preserved typos). The one consistent gap is the Rust.Careers interview (expired TLS cert, unreachable across multiple harvests) — his most quotable first-person Q&A — so the most polished/interview register is undersampled; everything above leans on his self-published voice, which is abundant and consistent.*

---

_Built with Claude Code._
