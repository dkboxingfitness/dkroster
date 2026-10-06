# DK Boxing Fitness — Setup Guide

## What's in this folder

| Folder / file | What it is |
|---|---|
| `website/` | **The app.** This is the only folder you upload to Netlify. |
| `website/index.html`, `styles.css`, `app.js` | The app itself |
| `website/config.js` | Your Supabase address and public key (already filled in) |
| `website/vendor/` | `supabase.js` (talks to the database) and `qrcode.js` (draws the check-in QR) |
| `website/manifest.json`, `sw.js`, `icons/`, `logo.png` | What makes it installable on a phone, plus the DK logo |
| `database/` | The database scripts, run in Supabase (Part 1). Never upload these to Netlify. |
| `SETUP.md` | This guide |

---

## Part 1 — Database (Supabase)

For each file below: open Supabase, go to **SQL Editor → New query**, paste the whole file, and click **Run**. If Supabase shows a "Row Level Security" warning, choose **Run and enable RLS**.

1. **`1_remove_old_version.sql`** deletes the very first version's tables. Only for a brand-new setup; never run it on the live club database.
2. **`2_create_database.sql`** creates the tables, security rules, and the private receipt storage. Safe to run again.
3. **Create the coach's login.** Go to **Authentication → Users → Add user → Create new user**. Enter his email and a password, and tick **Auto Confirm User**.
4. **`3_make_coach.sql`**: change `coach@example.com` to his email, then run it. The result should show one row with his email.
5. **`7_qr_checkin.sql`** adds QR self check-in. Safe to run again.
6. **Turn off public sign-ups.** Go to **Authentication → Sign In / Providers** and switch off **Allow new users to sign up**.

Scripts 4, 5 and 6 were one-time jobs (importing the first members and waiving their admission fee). They're already done and aren't needed again.

## Part 2 — Put it online (Netlify, free)

1. Sign up at **netlify.com**.
2. Go to **Sites** and drag the **`website`** folder onto the upload area.
3. To get a nicer name, go to **Site configuration → Change site name** (e.g. `dkboxing.netlify.app`).
4. Back in Supabase, go to **Authentication → URL Configuration** and set **Site URL** to that link.

## Part 3 — Install on the coach's phone

Open the link on his phone and sign in with the **Coach** button once.

- **Android (Chrome):** tap **Install app** on the dashboard, or use the **⋮** menu and choose **Add to Home screen**.
- **iPhone (Safari):** tap the **Share** button, then **Add to Home Screen**.

## Part 4 — Share with members

Send the link in the club's WhatsApp group. Members see the roster and each boxer's ratings and session notes. They never see fees, attendance, or personal details.

## Part 5 — QR check-in

Do this on the **website**, not inside the Android app.

1. Dashboard → **Attendance → ⚙︎ Settings**. Stand inside the gym and tap **Use my current location**. Check the days and hours, then **Save**.
2. Tap **Print QR**, then **Print** (or **Download QR image**), and stick it on the door.
3. Members scan it. The first time, they pick their name and enter the last 4 digits of their phone number.

New phones appear at the top of the Attendance tab with **Approve** / **Reject**.

**Door screen (optional, later):** make a separate login for a tablet by following the steps at the bottom of `7_qr_checkin.sql`, sign in with it on the tablet, and switch Check-in settings to **Door screen only**.

---

## Everyday use (for the coach)

- **New member:** **Members → + Add member**. Their admission fee shows as due until it's recorded.
- **Attendance:** members check in with the QR, or tap **Mark present**. Use the date box to fix a past day.
- **Fees:** tap **Mark paid**. A receipt photo is optional. Tap **Remove** in a member's payment history to undo a mistake.
- **Progress:** pick a boxer, change the ratings that moved, write a note, then tap **Save session**.
- **Someone leaves:** use **Archive** instead of delete. Their history stays and you can restore them later.
- **Prices change:** tap **⚙︎ Fees** on the dashboard. Payments already recorded keep their old amounts.

## Updating the app later

Change the files in `website/`, then in Netlify go to **Deploys** and drag the `website` folder in again. Phones pick up the new version the next time the app opens.

**Android app:** copy everything inside `website/` into `C:\dk-boxing-android\www`, run `npx cap copy android` in that folder, then press **Run** in Android Studio.
