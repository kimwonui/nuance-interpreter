# NUA website

Product site for NUA: the concept film up front (a short silent loop, and the full 44-second film with its music on request), a "same meaning, different feel" comparison, a scroll story of two people talking over one phone, and an interactive 3D iPhone showing the app's real hands-free screen. English copy, light theme only.

Static HTML/CSS/JS. No dependencies, no build step, no analytics.

Live at https://nuatranslator.com (www redirects to it).

## Preview

```sh
cd website
npm run dev        # http://localhost:4173/ — reloads open pages when a file changes
npm run check      # syntax, links/assets, no network/mic/audio code, language list, copy rules
```

`index.html` also opens straight from disk (classic scripts, no modules). Only the Noto Sans web font is loaded from Google Fonts; without a connection it falls back to the system font.

Test switches: `?reduced` forces the reduced-motion version, `?lite` forces the low-power version.

The preview server answers byte-range requests, so the videos play in Safari locally the same way they do on the host.

## Deployment

- Host: Vercel project `nua-website` (Hobby), separate from the `nua-token` server project.
- Domain: `nuatranslator.com` (Namecheap BasicDNS). Records: `@` A `216.198.79.1`, `www` CNAME `41044c83b77ffb08.vercel-dns-017.com.`. `www` redirects to the apex (308). Certificate: Let's Encrypt, issued and renewed by Vercel.
- Only `index.html` and `assets/` are public (`npm run check` lists them and fails on anything unexpected); `.vercelignore` keeps `scripts/`, `README.md`, `package.json` and local `.env*` files out of the upload.
- Every production deploy needs the owner's explicit approval first. Run `npm run check`, then from `website/`: `vercel deploy --prod`.

## Layout

```
index.html                 sections: hero (film), meaning, how it works, demo, languages, FAQ, closing; film dialog
assets/css/styles.css      tokens from Theme.swift, CSS 3D device, app screen, page sections, film dialog
assets/film/               web versions of the concept film (see below)
assets/js/langs.js         14 languages and decorative flags (Models.swift, FlagPainter.swift)
assets/js/orb.js           orb drawing and easing (OrbView.swift / OrbDriver)
assets/js/phone.js         3D device + the split screen and its states (OrbHomeView.swift, SplitConversation.swift, LanguagePickerSheet.swift)
assets/js/main.js          page wiring: poses, scroll story, demo panel, languages grid, tone comparison
assets/js/film.js          hero loop (lazy, pausable) and the film dialog
scripts/serve.mjs          local preview server (127.0.0.1 only)
scripts/check.mjs          static checks
scripts/film.swift         makes the files in assets/film/ with AVFoundation (exact commands in its header)
```

## The film

Source: `nua-explainer-v2-music-B.mp4` (1920×1080, 30 fps, 44 s, H.264 + AAC music). It isn't stored here; the files below are made from it with `scripts/film.swift`, which only reads the source.

| File | What | Size |
|---|---|---|
| `hero-poster-480/740.jpg` | first frame of the hero loop, loaded with the page | 44 / 76 kB |
| `hero-loop-480/740.mp4` | 33.1–35.6 s, cropped to the phone, played forward then back, no audio track | 234 / 441 kB |
| `film-1080.mp4` | the full film, streams copied unchanged (metadata dropped) | 8.3 MB |
| `film-720.mp4` | the full film at 1280×720; the original AAC music is copied, not re-encoded | 5.6 MB |
| `film-poster.jpg` | the "Same meaning. Different feel." frame, shown in the dialog | 77 kB |

Loading: the page loads only the poster. The silent loop starts after the page has finished loading, plays only while it's on screen, and has a pause button; with reduced motion or Save-Data it never loads. The full film downloads only after "Watch the film" (720p on narrow screens or Save-Data), plays with sound because that click asked for it, and stays paused under reduced motion. Esc, the close button and the backdrop close it.

The hero loop is the one stretch of the film whose phone screen matches the current app (running state: Listen, Speaking English, Mute/Stop). Other parts of the film show an earlier build: a Start conversation button at the bottom and per-language test labels. There's no editable source for the film, so it is shown as it is, labeled as a concept film made with an earlier build, next to the interactive demo of the current screen. Don't draw corrected UI on top of the film; re-render it from its source instead.

## How the 3D works

The phone is CSS 3D, not WebGL: 16 stacked rounded layers form the titanium edge (8 in the low-power version), with front and back faces and a moving glare on the glass. The screen inside is live HTML, so the demo phone is fully interactive. The orb and the flag backgrounds are drawn on canvas with the same formulas as the SwiftUI code.

Motion is limited to things that explain the product: pointer and scroll tilt, the phone laying flat between two people, and the light that travels from the speaker's half through the orb to the listener's half. With reduced motion the page shows still frames and no tilt; low-power devices draw fewer layers at 30 fps, and nothing animates off screen.

## Source of truth

The screen copy, states and colors follow the iOS code, not older Figma frames:

- `ios/Interpreter/App/Theme.swift`: colors, CTA gradient, radii
- `ios/Interpreter/Views/OrbHomeView.swift`: split layout, orb states and status text, Two-way/One-way and Mute/Stop
- `ios/Interpreter/Views/SplitConversation.swift`: per-half cues and the flowing light
- `ios/Interpreter/Views/OrbView.swift`: orb motion
- `ios/Interpreter/Views/LanguagePickerSheet.swift`, `App/Models.swift`: languages, Arabic GPT-Live only

If the app changes, update these files in the same way.

## Copy rules

- The demo is illustrative and labeled that way. It never uses the microphone, plays audio, or makes network requests. The only sound on the page is the film's music, after someone presses "Watch the film".
- The tone comparison is example text written for the page (labeled "Example text"), not app output, and plays no audio.
- The film is a concept film made with an earlier build; say so wherever it's offered.
- No App Store links, sign-up forms, testimonials, user numbers or press logos. NUA is a development build.
- Interpretation quality is a goal, not a promise. All 14 languages are shown the same way, without Tried/Experimental labels (owner decision, 2026-10-25); Arabic runs on GPT-Live.
- One-way is in the current build but hasn't been tested in real conversations; say so wherever it's described.
- Data flow: with GPT-Live, audio goes between the phone and OpenAI; the NUA server helps set up the connection and gets numeric diagnostics only; History is kept in memory. Don't claim audio stays on the device or that providers keep nothing.

`npm run check` enforces the mechanical parts of these rules.
