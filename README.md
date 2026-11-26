# Gifjar

A native iOS library for images and GIFs. Paste or link something in, Apple Intelligence describes it on device, and you search it later by what it shows, the text inside it, or your own phrases and notes. Originals sync to Cloudflare R2 through a Worker.

```
ios/      SwiftUI app (iOS 27, Swift 6, SwiftData, Foundation Models, Vision)
worker/   Cloudflare Worker + R2 bucket (cf CLI)
```

## Worker

```sh
cd worker
npm install
cp .dev.vars.example .dev.vars      # local token
cf dev                              # http://localhost:8787

# production
cf auth login
cf r2 buckets create-by-name        # bucket name: gifjar-media
cf deploy
# then set the API_TOKEN secret (use `cf cli search "set worker secret"`); use a long random value
```

API (all routes need `Authorization: Bearer <API_TOKEN>`):

| Method | Path | |
|---|---|---|
| GET | `/v1/health` | auth check |
| GET | `/v1/items?since=<ms>` | changed metadata, including tombstones |
| PUT | `/v1/items/:id` | upsert metadata; `409` + server copy if the server's is newer |
| DELETE | `/v1/items/:id` | delete media, leave a tombstone |
| PUT/GET | `/v1/items/:id/media` | original bytes (GIF/PNG/JPEG/HEIC/WebP/APNG, ≤50 MB, ETag/304) |

## iOS app

```sh
cd ios
xcodegen generate
open Gifjar.xcodeproj    # set your Team on both the Gifjar and GifjarShare targets
```

Both targets share the App Group `group.dev.jusso.gifjar`. With automatic signing, Xcode registers it the first time you build for a device.

In the app: **Options ▸ Settings ▸ Cloud Storage**, enter the Worker URL and token, then **Test Connection**. The token is stored in the Keychain.

Adding items: the Paste button, ⌘V, drag and drop, **+ ▸ Add from Link** (direct image URLs, or pages such as GIPHY and Tenor), **+ ▸ Choose from Photos**, or the share sheet.

### Favorites

Double-tap any item in the grid to favourite it (or use the heart in its detail view, its context menu, or **Add to Favorites** in the share sheet). Favourites appear in a row above the library, most recently used first; one tap copies a favourite so you can paste it straight into Messages again. **See All** opens the Favorites filter.

### Share sheet

Choose **Gifjar** in the share sheet from Photos, Safari, Messages, GIPHY, Tenor, or Files. It accepts images and GIFs (up to 20 at once), links to images, links to pages that contain one, and text that contains a link. The sheet plays the GIF, fills in the page title, and lets you add a phrase before saving.

The extension writes each item to an inbox folder in the App Group. Gifjar files them into the library the next time it opens, then describes them with Apple Intelligence. If a link can't be fetched (for example, you're offline), the extension saves the link and the app tries again later. Sharing something you already have adds the new phrase to the existing item.

### iPhone Duo

The layout follows the hinge (`onHingeChange`, iOS 27.1+):

- **Folded (cover display):** single column; detail pushes.
- **Unfolded flat:** library and detail side by side.
- **Half-open:** the selected GIF plays large on one half and the library sits on the other, with a gutter so nothing crosses the crease.

### Apple Intelligence

Vision classifies the image and reads its text, from the middle frame plus the first frame for GIFs. The on-device Foundation Model then writes a title, a summary, tags, and reaction phrases. If the model can take images (`.vision`) it gets the frame directly; otherwise it works from Vision's labels. Without Apple Intelligence, items are still searchable by Vision labels and text. Nothing is sent off device for analysis.
