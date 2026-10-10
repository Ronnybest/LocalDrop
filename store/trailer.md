# Play Store trailer

A promo video for the store page (YouTube, public or unlisted, no ads, no age restriction). Play
shows it before the screenshots, muted until tapped: it has to work without sound.

## Shape

- 30–40 seconds, landscape 16:9 (1920×1080): Play shows a landscape video best.
- The app on screen in the first 3 seconds; no logo intro.
- Short captions instead of narration; quiet music.
- Real devices and real transfers, no mock-ups: Play rejects videos that show what the app
  doesn't do.
- English captions for the default listing; a Russian version later if the Russian page needs it.

## Storyboard

| Time | Shot | Caption |
|------|------|---------|
| 0–4 s | Phone, gallery: a photo, Share, the Mac in the share sheet, tap | Your Mac, right in the share sheet |
| 4–9 s | Split: phone progress notification ⇄ the photo appears on the Mac | Straight over your Wi-Fi |
| 9–15 s | Mac: drag a video from Finder, the phone slides in at the screen edge, drop | And back: drag to the edge |
| 15–20 s | Phone: Accept in the notification, wavy progress, Saved in Downloads | Accept on the phone |
| 20–25 s | Copy a link on the phone, tap Clipboard, paste on the Mac | Text and links, both ways |
| 25–30 s | Pairing: the same code on both screens | Paired once. Only your devices. |
| 30–35 s | Icon and name on the gradient, "Free for Mac at github.com/Ronnybest/LocalDrop" | Local Drop: Android ⇄ Mac |

## Recording

- Phone without a frame: `scrcpy --record phone.mp4 --no-audio --max-fps 60` (lossless enough, no
  touch circles: `--show-touches` off for the trailer).
- Mac: Cmd+Shift+5, a selected area at 1920×1080, menu bar visible; a clean desktop, Do Not Disturb
  on, Local Drop notifications allowed.
- Each shot separately, a few takes each; cut and caption in iMovie or Final Cut, or with ffmpeg.
