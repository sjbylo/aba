# Session State

## Current goal
Der Tippmeister -- APAC mini-tournament loaded, various improvements.

## Done this session
- Fixed blank/pink page issue: added **flask-compress** for gzip (95-96% size reduction)
- Optimized admin predictions grid: JS click handlers instead of `<a>` wraps
- Created `seed_apac.py` -- 8-team APAC tournament (16 matches, 7 days)
- Externalized secrets to `~/.tm.conf` (chmod 600), sourced by `start.sh`
- **Timezone auto-detect**: browser `Intl` API detects timezone on registration (auto-set), login (auto-set if empty), and profile page ("Detected: X, Use this" hint)

## Next steps
- Remaining features: "Next 3/7 days" filters, "My Tips" → "My Predictions" rename
- User testing the APAC mini-tournament

## Decisions / notes
- Timezone detect uses `Intl.DateTimeFormat().resolvedOptions().timeZone` (reliable in all modern browsers)
- Login auto-set only fires if user.timezone is empty/None (doesn't override existing choice)
- Profile hint only shows when detected != saved timezone
