# NUA website

Product site for NUA: a 3D iPhone showing the app's real hands-free screen, a scroll story of how two people use one phone, and an interactive walkthrough of the orb states. English copy, light theme only.

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

## Deployment

- Host: Vercel project `nua-website` (Hobby), separate from the `nua-token` server project.
- Domain: `nuatranslator.com` (Namecheap BasicDNS). Records: `@` A `216.198.79.1`, `www` CNAME `41044c83b77ffb08.vercel-dns-017.com.`. `www` redirects to the apex (308). Certificate: Let's Encrypt, issued and renewed by Vercel.
- Only `index.html` and `assets/` are public; `.vercelignore` keeps `scripts/`, `README.md`, `package.json` and local `.env*` files out of the upload.
- Every production deploy needs the owner's explicit approval first. Run `npm run check`, then from `website/`: `vercel deploy --prod`.

## Layout

```
index.html                 sections: hero, how it works, meaning, demo, languages, FAQ, closing
assets/css/styles.css      tokens from Theme.swift, CSS 3D device, app screen, page sections
assets/js/langs.js         14 languages and decorative flags (Models.swift, FlagPainter.swift)
assets/js/orb.js           orb drawing and easing (OrbView.swift / OrbDriver)
assets/js/phone.js         3D device + the split screen and its states (OrbHomeView.swift, SplitConversation.swift, LanguagePickerSheet.swift)
assets/js/main.js          page wiring: poses, scroll story, demo panel, languages grid, waveform
scripts/serve.mjs          local preview server (127.0.0.1 only)
scripts/check.mjs          static checks
```

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

- The demo is illustrative and labeled that way. It never uses the microphone, plays audio, or makes network requests.
- No App Store links, sign-up forms, testimonials, user numbers or press logos. NUA is a development build.
- Interpretation quality is a goal, not a promise. All 14 languages are shown the same way, without Tried/Experimental labels (owner decision, 2026-10-25); Arabic runs on GPT-Live.
- One-way is in the current build but hasn't been tested in real conversations; say so wherever it's described.
- Data flow: with GPT-Live, audio goes between the phone and OpenAI; the NUA server helps set up the connection and gets numeric diagnostics only; History is kept in memory. Don't claim audio stays on the device or that providers keep nothing.

`npm run check` enforces the mechanical parts of these rules.
